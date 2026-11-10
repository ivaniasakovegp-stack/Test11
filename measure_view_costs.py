#!/usr/bin/env python3
"""Measure PostgreSQL/Greenplum planner execution cost for a list of views.

Reads view names from a text file (one per line: schema.name or name),
connects with explicit parameters (password may contain special characters),
runs EXPLAIN and prints Total Cost per view.

Example:
  python measure_view_costs.py \\
    --host db.example.com --port 5432 --dbname mydb --user reader \\
    --password 'p@$$w:ord!' \\
    --views-file views.txt \\
    --default-schema dm_ouod
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
from dataclasses import dataclass
from getpass import getpass
from typing import Any, Iterable, Optional, Sequence

IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
COST_RE = re.compile(r"cost=\s*[\d.]+\.\.([\d.]+)")


@dataclass(frozen=True)
class ViewRef:
    schema: Optional[str]
    name: str

    def qualified(self, default_schema: Optional[str] = None) -> str:
        schema = self.schema or default_schema
        if schema:
            return f"{quote_ident(schema)}.{quote_ident(self.name)}"
        return quote_ident(self.name)

    def display(self, default_schema: Optional[str] = None) -> str:
        schema = self.schema or default_schema
        if schema:
            return f"{schema}.{self.name}"
        return self.name


@dataclass
class CostRow:
    view: str
    total_cost: Optional[float]
    startup_cost: Optional[float]
    error: Optional[str] = None


def quote_ident(ident: str) -> str:
    if not IDENT_RE.match(ident):
        raise ValueError(f"Invalid SQL identifier: {ident!r}")
    return f'"{ident}"'


def parse_view_line(line: str, default_schema: Optional[str]) -> Optional[ViewRef]:
    text = line.strip()
    if not text or text.startswith("#"):
        return None
    # allow schema.name or just name; ignore trailing commas
    text = text.rstrip(",;").strip()
    if "." in text:
        schema, name = text.split(".", 1)
        schema, name = schema.strip(), name.strip()
        if not schema or not name:
            raise ValueError(f"Bad view reference: {line!r}")
        return ViewRef(schema=schema, name=name)
    return ViewRef(schema=default_schema, name=text)


def load_views(path: str, default_schema: Optional[str]) -> list[ViewRef]:
    views: list[ViewRef] = []
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            try:
                ref = parse_view_line(line, default_schema)
            except ValueError as exc:
                raise SystemExit(f"{path}:{lineno}: {exc}") from exc
            if ref is not None:
                views.append(ref)
    if not views:
        raise SystemExit(f"No views found in {path}")
    return views


def extract_costs_from_json(plan_json: Any) -> tuple[float, float]:
    """Return (startup_cost, total_cost) from EXPLAIN FORMAT JSON."""
    node = plan_json
    if isinstance(node, list):
        node = node[0]
    plan = node.get("Plan") if isinstance(node, dict) else None
    if not isinstance(plan, dict):
        raise ValueError(f"Unexpected EXPLAIN JSON shape: {plan_json!r}")
    startup = float(plan["Startup Cost"])
    total = float(plan["Total Cost"])
    return startup, total


def extract_total_cost_from_text(lines: Sequence[str]) -> float:
    for line in lines:
        match = COST_RE.search(line)
        if match:
            return float(match.group(1))
    raise ValueError("Could not parse cost from EXPLAIN text output")


def explain_cost(
    conn: Any,
    view: ViewRef,
    default_schema: Optional[str],
    use_json: bool,
) -> CostRow:
    label = view.display(default_schema)
    sql = f"EXPLAIN {'(FORMAT JSON) ' if use_json else ''}SELECT * FROM {view.qualified(default_schema)}"
    try:
        with conn.cursor() as cur:
            cur.execute(sql)
            rows = cur.fetchall()
        if use_json:
            payload = rows[0][0]
            if isinstance(payload, str):
                payload = json.loads(payload)
            startup, total = extract_costs_from_json(payload)
        else:
            text_lines = [str(r[0]) for r in rows]
            total = extract_total_cost_from_text(text_lines)
            startup = None
        return CostRow(view=label, total_cost=total, startup_cost=startup)
    except Exception as exc:  # noqa: BLE001 - report per-view and continue
        return CostRow(view=label, total_cost=None, startup_cost=None, error=str(exc))


def format_table(rows: Iterable[CostRow]) -> str:
    data = list(rows)
    headers = ("view", "startup_cost", "total_cost", "error")
    cells = [headers]
    for row in data:
        cells.append(
            (
                row.view,
                "" if row.startup_cost is None else f"{row.startup_cost:.2f}",
                "" if row.total_cost is None else f"{row.total_cost:.2f}",
                row.error or "",
            )
        )
    widths = [max(len(c[i]) for c in cells) for i in range(len(headers))]
    lines: list[str] = []
    for idx, cell in enumerate(cells):
        line = " | ".join(cell[i].ljust(widths[i]) for i in range(len(headers)))
        lines.append(line)
        if idx == 0:
            lines.append("-+-".join("-" * w for w in widths))
    return "\n".join(lines)


def write_csv(path: str, rows: Sequence[CostRow]) -> None:
    with open(path, "w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["view", "startup_cost", "total_cost", "error"])
        for row in rows:
            writer.writerow(
                [
                    row.view,
                    "" if row.startup_cost is None else f"{row.startup_cost:.6f}",
                    "" if row.total_cost is None else f"{row.total_cost:.6f}",
                    row.error or "",
                ]
            )


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Measure EXPLAIN Total Cost for PostgreSQL/Greenplum views.",
    )
    p.add_argument("--views-file", required=True, help="Text file: one view per line (schema.name or name)")
    p.add_argument("--default-schema", default=None, help="Schema for unqualified view names")
    p.add_argument("--host", default=os.environ.get("PGHOST", "localhost"))
    p.add_argument("--port", type=int, default=int(os.environ.get("PGPORT", "5432")))
    p.add_argument("--dbname", default=os.environ.get("PGDATABASE", "postgres"))
    p.add_argument("--user", default=os.environ.get("PGUSER", os.environ.get("USER", "postgres")))
    p.add_argument(
        "--password",
        default=None,
        help="DB password (prefer this or PGPASSWORD; special chars are fine). "
        "If omitted, uses PGPASSWORD or prompts.",
    )
    p.add_argument(
        "--password-file",
        default=None,
        help="Read password from file (entire contents, strip one trailing newline)",
    )
    p.add_argument(
        "--sslmode",
        default=os.environ.get("PGSSLMODE"),
        help="Optional libpq sslmode (e.g. require, prefer, disable)",
    )
    p.add_argument(
        "--text-explain",
        action="store_true",
        help="Use plain EXPLAIN text instead of FORMAT JSON (for older engines)",
    )
    p.add_argument("--csv", dest="csv_path", default=None, help="Also write results to CSV path")
    p.add_argument(
        "--fail-fast",
        action="store_true",
        help="Stop on first view error (default: continue and report)",
    )
    return p


def resolve_password(args: argparse.Namespace) -> str:
    if args.password_file:
        with open(args.password_file, encoding="utf-8") as fh:
            raw = fh.read()
        return raw[:-1] if raw.endswith("\n") else raw
    if args.password is not None:
        return args.password
    env = os.environ.get("PGPASSWORD")
    if env is not None:
        return env
    return getpass("Password: ")


def main(argv: Optional[Sequence[str]] = None) -> int:
    try:
        import psycopg
    except ImportError:  # pragma: no cover
        sys.stderr.write(
            "psycopg is required. Install with:\n"
            "  pip install 'psycopg[binary]>=3.1'\n"
        )
        return 1

    args = build_arg_parser().parse_args(argv)
    views = load_views(args.views_file, args.default_schema)
    password = resolve_password(args)

    # make_conninfo escapes special characters in password (:, @, /, %, etc.).
    conninfo_kwargs: dict[str, Any] = {
        "host": args.host,
        "port": args.port,
        "dbname": args.dbname,
        "user": args.user,
        "password": password,
    }
    if args.sslmode:
        conninfo_kwargs["sslmode"] = args.sslmode
    conn = psycopg.connect(psycopg.conninfo.make_conninfo(**conninfo_kwargs))

    results: list[CostRow] = []
    use_json = not args.text_explain
    try:
        with conn:
            # Prefer JSON; if engine rejects FORMAT JSON, retry in text mode once globally.
            if use_json:
                try:
                    with conn.cursor() as cur:
                        cur.execute("EXPLAIN (FORMAT JSON) SELECT 1")
                        cur.fetchall()
                except Exception:  # noqa: BLE001
                    use_json = False
                    sys.stderr.write("FORMAT JSON not supported; falling back to text EXPLAIN\n")

            for view in views:
                row = explain_cost(conn, view, args.default_schema, use_json=use_json)
                results.append(row)
                if row.error and args.fail_fast:
                    break
    finally:
        conn.close()

    print(format_table(results))
    if args.csv_path:
        write_csv(args.csv_path, results)
        print(f"\nCSV written to {args.csv_path}", file=sys.stderr)

    return 1 if any(r.error for r in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
