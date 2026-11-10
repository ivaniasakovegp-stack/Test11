-- PostgreSQL 9.4.26 / Greenplum 6.22
-- Логика: 02-1 Transform 1С КЛАД происшествия по КТ-55.qvs
--         03-1 PreCalc КЛАД 1С происшествия по КТ-55.qvs
-- QVD: cDataTier3/LinkTable.qvd
-- Представление читает только ods_pb1c_src_data. Другие представления не используются.
--
-- Не вошло в источник source.sql и поэтому не включено:
--   * Excel «Происшествия за 2020 год для LTIF» (история для скользящего LTIF);
--   * QVD Количество_ОД_ОУ (типы ОД, ОУ, «Происшествия без последствий ОД/ОУ»).
-- Общий расчёт до link_keys совпадает у proisshestviya_brd, aggr_kolichestvo_proisshestvij
-- и link_table. Иначе значения link_key разъедутся. Править эту часть нужно во всех трёх файлах
-- (или пересобрать их скриптом _gen_views.py).
--
-- Без WITH RECURSIVE: в GP6 рекурсивный обход структуры при инлайне CTE
-- даёт сотни slices (ошибка «at most 300 slices are allowed»). Для org_keys
-- иерархия не нужна — org_src и так ограничен фильтром БРД/ГПН-Снабжение,
-- обход шёл только внутри этого набора и не расширял множество ключей.

CREATE SCHEMA IF NOT EXISTS dm_ouod;

DROP VIEW IF EXISTS dm_ouod.link_table;

CREATE VIEW dm_ouod.link_table AS
WITH

org_keys AS (
    SELECT DISTINCT
        s.organizacionnayaedinica AS organizatsiya_key
    FROM ods_pb1c_src_data.strukturapredpriyatiya s
    WHERE (
            (
                s.polnoepredstavlenie ILIKE '%БРД%'
                AND s.gpnarhivnyj = FALSE
            )
            OR s.description ILIKE '%ГПН-Снабжение%'
          )
      AND s.organizacionnayaedinica IS NOT NULL
)
,

matrix_op AS (
    SELECT DISTINCT
        op.ref_key,
        op.posledstvie_key,
        op.elementmatricy_key
    FROM ods_pb1c_src_data.registraciyaproisshestviya_obshhieposledstviya op
),
matrix_lines AS (
    SELECT
        op.ref_key,
        mx.description AS matrica_klassifikaciya,
        ps.description AS matrica_opisanie,
        op.elementmatricy_key AS matrica_key,
        op.posledstvie_key
    FROM ods_pb1c_src_data.registraciyaproisshestviya_obshhieposledstviya op
    JOIN ods_pb1c_src_data.posledstviyaproisshestvij ps
      ON ps.ref_key = op.posledstvie_key
     AND ps.matricaocenkiriskovproisshestviya_key = op.elementmatricy_key
    JOIN ods_pb1c_src_data.matricaocenkiriskovproisshestvij mx
      ON mx.ref_key = op.elementmatricy_key
     AND mx.kategoriyascenariya_key = '2107194a-5569-11eb-348c-005056920bff'
    UNION
    SELECT
        v.ref_key,
        CASE WHEN mop.ref_key IS NOT NULL THEN mx.description END AS matrica_klassifikaciya,
        ps.description AS matrica_opisanie,
        ps.matricaocenkiriskovproisshestviya_key AS matrica_key,
        ps.ref_key AS posledstvie_key
    FROM ods_pb1c_src_data.registraciyaproisshestviya_postradavshie v
    JOIN ods_pb1c_src_data.posledstviyaproisshestvij ps
      ON ps.ref_key = v.posledstviedlyazdorovya_key
     AND ps.kategoriyascenariya_key = '2107194a-5569-11eb-348c-005056920bff'
    LEFT JOIN matrix_op mop
      ON mop.ref_key = v.ref_key
     AND mop.posledstvie_key = ps.ref_key
     AND mop.elementmatricy_key = ps.matricaocenkiriskovproisshestviya_key
    LEFT JOIN ods_pb1c_src_data.matricaocenkiriskovproisshestvij mx
      ON mx.ref_key = ps.matricaocenkiriskovproisshestviya_key
     AND mx.kategoriyascenariya_key = '2107194a-5569-11eb-348c-005056920bff'
     AND mop.ref_key IS NOT NULL
    WHERE v.ref_key IS NOT NULL
),
victim_cnt AS (
    SELECT
        p.ref_key,
        p.posledstviedlyazdorovya_key AS posledstvie_key,
        COUNT(p.postradavshij) AS postradavshie
    FROM ods_pb1c_src_data.registraciyaproisshestviya_postradavshie p
    WHERE p.podryadchiktretyastorona IS NULL
       OR p.podryadchiktretyastorona NOT ILIKE 'Третья%'
    GROUP BY p.ref_key, p.posledstviedlyazdorovya_key
),
svyaz_dim AS (
    SELECT DISTINCT
        p.ref_key,
        CASE
            WHEN p.svyazanosproizvodstvom IS TRUE THEN 'Да'
            ELSE 'Нет'
        END AS svyaz_temp
    FROM ods_pb1c_src_data.registraciyaproisshestviya_postradavshie p
),
inc_base AS (
    SELECT r.*
    FROM ods_pb1c_src_data.registraciyaproisshestviya r
    JOIN org_keys k
      ON k.organizatsiya_key = r.organizaciya_key
    WHERE r.posted IS TRUE
      AND r."date" >= TIMESTAMP '2021-01-01'
      AND r.scenarij_key IS DISTINCT FROM '0ed67f67-49ca-11eb-ab6c-00155d3c3025'
),
enriched_all AS (
    SELECT
        r.ref_key,
        r.nomerproisshestviya AS nomer,
        r."date"::date AS data_proisshestviya,
        date_trunc('month', r."date")::date AS data_aggr,
        EXTRACT(YEAR FROM r."date")::int AS god,
        EXTRACT(MONTH FROM r."date")::int AS mesyac,
        CASE
            WHEN ml.posledstvie_key = '15a8afc4-5c75-11eb-c19c-005056920bff'
                THEN 'Зона 1'
            WHEN r.zonavliyaniya IS NULL THEN NULL
            WHEN r.zonavliyaniya = trunc(r.zonavliyaniya)
                THEN 'Зона ' || trunc(r.zonavliyaniya)::bigint::text
            ELSE 'Зона ' || r.zonavliyaniya::text
        END AS zona,
        CASE
            WHEN r.kategoriya = 'БезПоследствий' THEN 'Без последствий'
            ELSE r.kategoriya
        END AS iznachalnaya,
        r.mezhdunarodnyjstandart AS pse,
        vd.vidproisshestviya AS vid,
        r."date"::time AS vremya,
        (r.kolichestvopogibshih
            + r.kolichestvopogibshihpodryadchikov
            + r.kolichestvopogibshihsubpodryadchikov) AS pogibshie_sotr,
        (r.kolichestvopostradavshihpodryadchikov
            + r.kolichestvopostradavshihrabotnikov
            + r.kolichestvopostradavshihsubpodryadchikov) AS postradavshie_sotr,
        r.kolichestvopostradavshihpodryadchikov,
        r.kolichestvopostradavshihrabotnikov,
        r.kolichestvopostradavshihsubpodryadchikov,
        r.kolichestvopogibshih,
        r.kolichestvopogibshihpodryadchikov,
        r.kolichestvopogibshihsubpodryadchikov,
        r.predotvratimoeproisshestvie AS predotvratimoe,
        vc.postradavshie,
        r.mestoproisshestviya AS mesto,
        r.organizaciya_key AS organizatsiya_key,
        r.funkciya_key,
        CASE
            WHEN r.podryadchik_key = '00000000-0000-0000-0000-000000000000' THEN 'ДО'
            ELSE 'ПО'
        END AS do_po,
        r.opisanieproisshestviya AS opisanie,
        r.vysokopotencialnoeproisshestvie AS hipo,
        ob.description AS oblast,
        gr.description AS gruppa,
        sc.description AS scenarij,
        r.oblast_key,
        r.gruppa_key,
        r.scenarij_key,
        r.posledstviescenariya_key,
        ml.matrica_klassifikaciya,
        ml.matrica_opisanie,
        ml.matrica_key,
        ml.posledstvie_key,
        r.podryadchik_key,
        sd.svyaz_temp
    FROM inc_base r
    LEFT JOIN matrix_lines ml
      ON ml.ref_key = r.ref_key
    LEFT JOIN victim_cnt vc
      ON vc.ref_key = r.ref_key
     AND vc.posledstvie_key = ml.posledstvie_key
    LEFT JOIN svyaz_dim sd
      ON sd.ref_key = r.ref_key
    LEFT JOIN ods_pb1c_src_data.registraciyaproisshestviya_klassifikaciyapozakonodatelstvu vd
      ON vd.ref_key = r.ref_key
    LEFT JOIN ods_pb1c_src_data.oblastiproisshestvij ob
      ON ob.ref_key = r.oblast_key
    LEFT JOIN ods_pb1c_src_data.gruppyproisshestvij gr
      ON gr.ref_key = r.gruppa_key
    LEFT JOIN ods_pb1c_src_data.scenariiproisshestvij sc
      ON sc.ref_key = r.scenarij_key
),
enriched AS (
    SELECT
        a.*,
        CASE
            WHEN a.iznachalnaya = 'Значительное' AND a.hipo IS TRUE
                THEN 'Значительное HIPO'
            ELSE a.iznachalnaya
        END AS znachimost,
        CASE
            WHEN a.iznachalnaya ILIKE 'Крупное'
              OR a.iznachalnaya ILIKE 'Значительное'
                THEN 1
            ELSE 0
        END AS uroven,
        CASE
            WHEN a.svyaz_temp = 'Да' THEN 'Да'
            ELSE 'Нет'
        END AS svyaz,
        CASE
            WHEN a.iznachalnaya = 'Крупное' THEN 1
            WHEN (
                    a.posledstvie_key IN (
                        'b8a1a762-ac0b-11ec-ab9b-005056920bff',
                        '31dfc9a8-49cc-11eb-ab6c-00155d3c3025',
                        '8920bb1d-49cb-11eb-ab6c-00155d3c3025'
                    )
                    AND a.svyaz_temp = 'Да'
                 )
              OR (
                    a.oblast_key = 'ce5c038d-445a-11eb-ab6c-00155d3c3025'
                    AND a.iznachalnaya IN ('Крупное', 'Значительное')
                 )
              OR (a.iznachalnaya = 'Значительное' AND a.hipo IS TRUE)
                THEN 2
            ELSE 3
        END AS uroven_vnimaniya,
        CASE
            WHEN a.iznachalnaya = 'Крупное'
              OR (
                    CASE
                        WHEN a.iznachalnaya = 'Значительное' AND a.hipo IS TRUE
                            THEN 'Значительное HIPO'
                        ELSE a.iznachalnaya
                    END
                 ) ILIKE 'Значительн%'
                THEN 1
        END AS uroven_znachimosti
    FROM enriched_all a
    WHERE (
        CASE
            WHEN a.posledstvie_key = '15a8afc4-5c75-11eb-c19c-005056920bff'
                THEN 'Зона 1'
            ELSE a.zona
        END
    ) = 'Зона 1'
),
-- kind=1 — классификация по матрице/последствию; kind=2 — по области/сценарию.
-- CROSS JOIN вместо UNION ALL двух сканов enriched: меньше slices при инлайне CTE в GP6.
tip_kind AS (
    SELECT 1 AS kind
    UNION ALL
    SELECT 2
),
typed AS (
    SELECT
        e.*,
        CASE
            WHEN k.kind = 1 THEN
                CASE
                    WHEN e.matrica_key IN (
                            'c5b6c60d-4130-11eb-8139-00155d3c2b05',
                            'c5b6c60c-4130-11eb-8139-00155d3c2b05'
                         )
                     AND e.posledstvie_key IN (
                            '8920bb1d-49cb-11eb-ab6c-00155d3c3025',
                            'd92ccc88-49cb-11eb-ab6c-00155d3c3025'
                         )
                     AND e.svyaz = 'Да'
                     AND e.znachimost IN ('Значительное', 'Крупное', 'Значительное HIPO')
                        THEN 'Смертельные на производстве, чел'
                    WHEN e.matrica_key IN (
                            'c5b6c60e-4130-11eb-8139-00155d3c2b05',
                            'c5b6c60c-4130-11eb-8139-00155d3c2b05'
                         )
                     AND e.posledstvie_key IN (
                            'b8a1a762-ac0b-11ec-ab9b-005056920bff',
                            '31dfc9a8-49cc-11eb-ab6c-00155d3c3025',
                            '8920bb1d-49cb-11eb-ab6c-00155d3c3025',
                            '09123500-5c75-11eb-c19c-005056920bff'
                         )
                     AND e.oblast_key IS DISTINCT FROM '0ed67f63-49ca-11eb-ab6c-00155d3c3025'
                     AND e.svyaz = 'Да'
                     AND e.znachimost IN ('Значительное', 'Крупное', 'Значительное HIPO')
                        THEN 'Травмы с ВПТ, чел'
                    WHEN e.posledstvie_key = 'd17b9ab8-678d-11eb-3184-005056920bff'
                     AND e.oblast_key = '0ed67f63-49ca-11eb-ab6c-00155d3c3025'
                        THEN 'Случай ограничения трудоспособности со здоровьем'
                    WHEN e.posledstvie_key = 'd17b9ab8-678d-11eb-3184-005056920bff'
                     AND e.oblast_key IS DISTINCT FROM '0ed67f63-49ca-11eb-ab6c-00155d3c3025'
                        THEN 'Случай ограничения трудоспособности без здоровья'
                    WHEN e.posledstvie_key = 'ba56dee3-49cc-11eb-ab6c-00155d3c3025'
                     AND e.oblast_key = '0ed67f63-49ca-11eb-ab6c-00155d3c3025'
                        THEN 'Первая помощь, случаи  со здоровьем'
                    WHEN e.posledstvie_key = 'ba56dee3-49cc-11eb-ab6c-00155d3c3025'
                     AND e.oblast_key IS DISTINCT FROM '0ed67f63-49ca-11eb-ab6c-00155d3c3025'
                        THEN 'Первая помощь, случаи без здоровья'
                    WHEN e.posledstvie_key = '8d6bf4ab-49cc-11eb-ab6c-00155d3c3025'
                     AND e.oblast_key = '0ed67f63-49ca-11eb-ab6c-00155d3c3025'
                        THEN 'Медицинская помощь, случаи  со здоровьем'
                    WHEN e.posledstvie_key = '8d6bf4ab-49cc-11eb-ab6c-00155d3c3025'
                     AND e.oblast_key IS DISTINCT FROM '0ed67f63-49ca-11eb-ab6c-00155d3c3025'
                        THEN 'Медицинская помощь, случаи без здоровья'
                    WHEN e.matrica_key = 'c5b6c60d-4130-11eb-8139-00155d3c2b05'
                     AND e.posledstvie_key = '15a8afc4-5c75-11eb-c19c-005056920bff'
                     AND e.znachimost IN ('Значительное', 'Крупное', 'Значительное HIPO')
                     AND e.data_proisshestviya < DATE '2023-01-01'
                        THEN 'Смертельные по здоровью, чел'
                    WHEN e.oblast_key = '0ed67f63-49ca-11eb-ab6c-00155d3c3025'
                     AND e.posledstviescenariya_key IN (
                            '6d0d460e-8ffd-11ed-93ae-005056928be7',
                            '3f2a5a1e-8ff9-11ed-93ae-005056928be7',
                            'd80c5a2a-8ffe-11ed-93ae-005056928be7',
                            '66c285d2-8ffa-11ed-93ae-005056928be7',
                            '48f05b72-8ff7-11ed-93ae-005056928be7',
                            'cc0b90a4-8ffb-11ed-93ae-005056928be7',
                            '80a779ce-8ffc-11ed-93ae-005056928be7'
                         )
                     AND e.znachimost IN ('Значительное', 'Крупное', 'Значительное HIPO')
                     AND e.data_proisshestviya >= DATE '2023-01-01'
                        THEN 'Смертельные по здоровью, чел'
                    WHEN e.posledstvie_key = '31dfc9a8-49cc-11eb-ab6c-00155d3c3025'
                     AND e.svyaz = 'Нет'
                     AND e.znachimost IN ('Значительное', 'Крупное', 'Значительное HIPO')
                        THEN 'Несчастный случай, не связанный с производством'
                    ELSE e.matrica_klassifikaciya
                END
            ELSE
                CASE
                    WHEN e.scenarij_key IN (
                            '0ed67e8d-49ca-11eb-ab6c-00155d3c3025',
                            '0ed67e8b-49ca-11eb-ab6c-00155d3c3025',
                            'db366dc9-445b-11eb-ab6c-00155d3c3025',
                            'db366dc7-445b-11eb-ab6c-00155d3c3025',
                            '0ed67e85-49ca-11eb-ab6c-00155d3c3025',
                            'db366dc8-445b-11eb-ab6c-00155d3c3025',
                            '0ed67e80-49ca-11eb-ab6c-00155d3c3025',
                            '0ed67e90-49ca-11eb-ab6c-00155d3c3025',
                            '5768271e-1d71-11ed-9bb4-005056928be7'
                         )
                     AND e.predotvratimoe IS TRUE
                     AND e.znachimost IN ('Значительное', 'Крупное', 'Значительное HIPO')
                        THEN 'ДТП, случаи'
                    WHEN e.scenarij_key IN (
                            '0ed67e8d-49ca-11eb-ab6c-00155d3c3025',
                            '0ed67e8b-49ca-11eb-ab6c-00155d3c3025',
                            'db366dc9-445b-11eb-ab6c-00155d3c3025',
                            'db366dc7-445b-11eb-ab6c-00155d3c3025',
                            '0ed67e85-49ca-11eb-ab6c-00155d3c3025',
                            'db366dc8-445b-11eb-ab6c-00155d3c3025',
                            '0ed67e80-49ca-11eb-ab6c-00155d3c3025',
                            '0ed67e90-49ca-11eb-ab6c-00155d3c3025',
                            '5768271e-1d71-11ed-9bb4-005056928be7'
                         )
                     AND e.predotvratimoe IS TRUE
                     AND e.znachimost = 'Незначительное'
                        THEN 'ДТП незначительные, случаи'
                    WHEN e.oblast_key = 'ce5c038e-445a-11eb-ab6c-00155d3c3025'
                        THEN 'Авиа, случаи'
                    WHEN e.oblast_key IN (
                            '0ed67f40-49ca-11eb-ab6c-00155d3c3025',
                            '0ed67f90-49ca-11eb-ab6c-00155d3c3025',
                            '0ed67fe7-49ca-11eb-ab6c-00155d3c3025',
                            '0ed67ffc-49ca-11eb-ab6c-00155d3c3025',
                            '0ed67f1a-49ca-11eb-ab6c-00155d3c3025',
                            '0ed68050-49ca-11eb-ab6c-00155d3c3025',
                            '0ed6806c-49ca-11eb-ab6c-00155d3c3025',
                            '0ed67eee-49ca-11eb-ab6c-00155d3c3025'
                         )
                        THEN 'Происшествия с оборудованием'
                    WHEN e.oblast_key = '0ed67f63-49ca-11eb-ab6c-00155d3c3025'
                     AND e.scenarij_key IS DISTINCT FROM '0ed67f7c-49ca-11eb-ab6c-00155d3c3025'
                     AND e.gruppa_key IS DISTINCT FROM '0ed67f64-49ca-11eb-ab6c-00155d3c3025'
                     AND e.znachimost IN ('Значительное', 'Значительное HIPO', 'Крупное')
                     AND e.kolichestvopogibshih <= 0
                     AND e.kolichestvopogibshihpodryadchikov <= 0
                     AND e.kolichestvopogibshihsubpodryadchikov <= 0
                     AND e.data_proisshestviya < DATE '2023-01-01'
                        THEN 'Здоровье (без смертельных), случаи'
                    WHEN e.oblast_key = '0ed67f63-49ca-11eb-ab6c-00155d3c3025'
                     AND e.scenarij_key <> '0ed67f7c-49ca-11eb-ab6c-00155d3c3025'
                     AND e.gruppa_key IS DISTINCT FROM '0ed67f64-49ca-11eb-ab6c-00155d3c3025'
                     AND e.posledstviescenariya_key IN (
                            '9fe6270a-9005-11ed-93ae-005056928be7',
                            'be86c250-9005-11ed-93ae-005056928be7',
                            '9cb42f34-8ff9-11ed-93ae-005056928be7',
                            '93ebe4c0-8ffc-11ed-93ae-005056928be7',
                            '7646b646-8ff9-11ed-93ae-005056928be7',
                            '091f68e6-8fff-11ed-93ae-005056928be7',
                            'ed022e00-8ffe-11ed-93ae-005056928be7',
                            'c6eb0588-8ffa-11ed-93ae-005056928be7',
                            'a22c6712-8ffc-11ed-93ae-005056928be7',
                            '8001a5c8-8ffa-11ed-93ae-005056928be7',
                            '91cf8892-8ffa-11ed-93ae-005056928be7',
                            'fb9951fa-8ffe-11ed-93ae-005056928be7',
                            'b0932f36-8ffa-11ed-93ae-005056928be7',
                            'dc3ccd1c-8ffb-11ed-93ae-005056928be7',
                            '42b4107a-8fff-11ed-93ae-005056928be7',
                            'fb98a9ce-8ffb-11ed-93ae-005056928be7'
                         )
                     AND e.znachimost IN ('Значительное', 'Значительное HIPO', 'Крупное')
                     AND e.kolichestvopogibshih <= 0
                     AND e.kolichestvopogibshihpodryadchikov <= 0
                     AND e.kolichestvopogibshihsubpodryadchikov <= 0
                     AND e.data_proisshestviya >= DATE '2023-01-01'
                        THEN 'Здоровье (без смертельных), случаи'
                    WHEN e.scenarij_key = '0ed67f7c-49ca-11eb-ab6c-00155d3c3025'
                     AND e.znachimost IN ('Значительное', 'Крупное', 'Значительное HIPO')
                        THEN 'Алкоголь, случаи'
                    WHEN e.scenarij_key = '0ed68041-49ca-11eb-ab6c-00155d3c3025'
                     AND e.znachimost IN ('Значительное', 'Крупное', 'Значительное HIPO')
                        THEN 'Загрязнение атмосферного воздуха'
                    ELSE 'Прочее'
                END
        END AS tip
    FROM enriched e
    CROSS JOIN tip_kind k
),
block1 AS (
    SELECT
        t.data_aggr,
        t.do_po,
        t.tip,
        t.organizatsiya_key,
        SUM(CASE WHEN t.hipo IS TRUE THEN 1 WHEN t.hipo IS FALSE THEN 0 END)::numeric AS hipo,
        CASE
            WHEN t.tip IN ('Травмы с ВПТ, чел', 'Смертельные на производстве, чел')
                THEN SUM(t.postradavshie)::numeric
            ELSE COUNT(DISTINCT t.nomer)::numeric
        END AS qty
    FROM typed t
    WHERE t.znachimost IN ('Значительное', 'Крупное', 'Значительное HIPO', 'Незначительное')
      AND (
            t.tip IS NULL
         OR t.tip NOT IN (
                'Первая помощь, случаи без здоровья',
                'Медицинская помощь, случаи без здоровья',
                'Случай ограничения трудоспособности без здоровья'
            )
          )
    GROUP BY t.tip, t.data_aggr, t.do_po, t.organizatsiya_key
),
block2 AS (
    SELECT
        t.data_aggr,
        t.do_po,
        'КП с оборудованием'::text AS tip,
        t.organizatsiya_key,
        NULL::numeric AS hipo,
        COUNT(DISTINCT t.nomer)::numeric AS qty
    FROM typed t
    WHERE t.tip = 'Происшествия с оборудованием'
      AND t.znachimost = 'Крупное'
    GROUP BY t.do_po, t.organizatsiya_key, t.data_aggr
),
block3 AS (
    SELECT
        t.data_aggr,
        t.do_po,
        t.tip,
        t.organizatsiya_key,
        SUM(CASE WHEN t.hipo IS TRUE THEN 1 WHEN t.hipo IS FALSE THEN 0 END)::numeric AS hipo,
        SUM(t.postradavshie)::numeric AS qty
    FROM typed t
    WHERE t.tip IN (
            'Первая помощь, случаи без здоровья',
            'Медицинская помощь, случаи без здоровья',
            'Случай ограничения трудоспособности без здоровья'
          )
    GROUP BY t.do_po, t.organizatsiya_key, t.data_aggr, t.tip
),
block4 AS (
    SELECT
        t.data_aggr,
        t.do_po,
        'Происшествия без последствий'::text AS tip,
        t.organizatsiya_key,
        SUM(CASE WHEN t.hipo IS TRUE THEN 1 WHEN t.hipo IS FALSE THEN 0 END)::numeric AS hipo,
        COUNT(DISTINCT t.nomer)::numeric AS qty
    FROM typed t
    WHERE t.matrica_opisanie = 'Происшествие без последствий'
      AND (
            t.oblast IS NULL
         OR t.oblast NOT ILIKE 'Происшествия со здоровьем человека'
          )
    GROUP BY t.do_po, t.organizatsiya_key, t.data_aggr
),
pok_header AS (
    SELECT
        v.ref_key,
        date_trunc('month', v."date")::date AS data_aggr,
        v.organizaciya_key AS organizatsiya_key,
        CASE
            WHEN v.vidotcheta ILIKE '%ДО%' THEN 'ДО'
            ELSE 'ПО'
        END AS do_po
    FROM ods_pb1c_src_data.vvodezhemesyachnyhpokazatelejpb_gpn v
    JOIN org_keys k
      ON k.organizatsiya_key = v.organizaciya_key
    WHERE v.posted IS TRUE
      AND (
            v.vidotcheta ILIKE 'ДанныеПоПО%'
         OR v.vidotcheta ILIKE 'ДанныеПоДО%'
          )
      AND v."date" >= TIMESTAMP '2020-01-01'
),
pok_month AS (
    SELECT
        h.data_aggr,
        h.do_po,
        CASE e.pokazatel_key
            WHEN '9c65a02d-9bf3-11e9-a9b9-1c4d70e70f44'
                THEN 'Количество отработанных человеко-часов'
            WHEN '9c65a02e-9bf3-11e9-a9b9-1c4d70e70f44'
                THEN 'Пробег транспортных средств'
        END AS tip,
        h.organizatsiya_key,
        SUM(e.znachenie) AS qty
    FROM pok_header h
    LEFT JOIN ods_pb1c_src_data.ezhemesyachnyepokazatelipb_recordtype e
      ON e.recorder_key = h.ref_key
     AND e.pokazatel_key IN (
            '9c65a02d-9bf3-11e9-a9b9-1c4d70e70f44',
            '9c65a02e-9bf3-11e9-a9b9-1c4d70e70f44'
         )
    GROUP BY h.data_aggr, h.do_po, h.organizatsiya_key,
        CASE e.pokazatel_key
            WHEN '9c65a02d-9bf3-11e9-a9b9-1c4d70e70f44'
                THEN 'Количество отработанных человеко-часов'
            WHEN '9c65a02e-9bf3-11e9-a9b9-1c4d70e70f44'
                THEN 'Пробег транспортных средств'
        END
),
pok_months AS (
    SELECT DISTINCT h.data_aggr
    FROM pok_header h
    WHERE h.data_aggr IS NOT NULL
),
temp_aggr AS (
    SELECT p.data_aggr, p.do_po, p.tip, p.organizatsiya_key, p.qty
    FROM pok_month p
    UNION ALL
    SELECT b.data_aggr, b.do_po, b.tip, b.organizatsiya_key, b.qty
    FROM block1 b
    WHERE b.tip IN (
            'Травмы с ВПТ, чел',
            'Смертельные на производстве, чел',
            'ДТП, случаи'
          )
),
asof_cal AS (
    SELECT
        m.data_aggr AS month_year,
        a.data_aggr AS as_of
    FROM pok_months m
    JOIN pok_months a
      ON m.data_aggr > (a.data_aggr - INTERVAL '12 months')::date
     AND a.data_aggr >= m.data_aggr
),
ytd_cal AS (
    SELECT
        m.data_aggr AS month_year,
        a.data_aggr AS as_of
    FROM pok_months m
    JOIN pok_months a
      ON a.data_aggr >= m.data_aggr
     AND EXTRACT(YEAR FROM a.data_aggr) = EXTRACT(YEAR FROM m.data_aggr)
),
roll_rows AS (
    SELECT
        c.as_of AS data_aggr,
        t.do_po,
        CASE
            WHEN t.tip LIKE '%,%'
                THEN split_part(t.tip, ',', 1) || ', скользящий 12 мес'
            ELSE t.tip || ', скользящий 12 мес'
        END AS tip,
        t.organizatsiya_key,
        NULL::numeric AS hipo,
        SUM(t.qty) AS qty
    FROM asof_cal c
    JOIN temp_aggr t
      ON t.data_aggr = c.month_year
    GROUP BY c.as_of, t.do_po, t.tip, t.organizatsiya_key
),
ytd_rows AS (
    SELECT
        c.as_of AS data_aggr,
        t.do_po,
        CASE
            WHEN t.tip LIKE '%,%'
                THEN split_part(t.tip, ',', 1) || ', c начала года'
            ELSE t.tip || ', c начала года'
        END AS tip,
        t.organizatsiya_key,
        NULL::numeric AS hipo,
        SUM(t.qty) AS qty
    FROM ytd_cal c
    JOIN temp_aggr t
      ON t.data_aggr = c.month_year
    GROUP BY c.as_of, t.do_po, t.tip, t.organizatsiya_key
),
aggr_rows AS (
    SELECT data_aggr, do_po, tip, organizatsiya_key, hipo, qty FROM block1
    UNION ALL
    SELECT data_aggr, do_po, tip, organizatsiya_key, hipo, qty FROM block2
    UNION ALL
    SELECT data_aggr, do_po, tip, organizatsiya_key, hipo, qty FROM block3
    UNION ALL
    SELECT data_aggr, do_po, tip, organizatsiya_key, hipo, qty FROM block4
    UNION ALL
    SELECT data_aggr, do_po, tip, organizatsiya_key, NULL::numeric AS hipo, qty
    FROM pok_month
    UNION ALL
    SELECT data_aggr, do_po, tip, organizatsiya_key, hipo, qty FROM ytd_rows
    UNION ALL
    SELECT data_aggr, do_po, tip, organizatsiya_key, hipo, qty FROM roll_rows
),
link_keys AS (
    SELECT
        row_number() OVER (
            ORDER BY
                u.data_aggr NULLS FIRST,
                u.do_po NULLS FIRST,
                u.tip NULLS FIRST,
                u.organizatsiya_key NULLS FIRST
        ) AS link_key,
        u.data_aggr,
        u.do_po,
        u.tip,
        u.organizatsiya_key
    FROM (
        SELECT t.data_aggr, t.do_po, t.tip, t.organizatsiya_key
        FROM typed t
        UNION
        SELECT a.data_aggr, a.do_po, a.tip, a.organizatsiya_key
        FROM aggr_rows a
    ) u
)
SELECT
    k.link_key AS link_key,
    k.data_aggr AS data_aggr,
    k.do_po AS do_po,
    k.tip AS utochnennyj_tip_proisshestviya,
    k.organizatsiya_key
FROM link_keys k;

COMMENT ON VIEW dm_ouod.link_table IS 'Ключ link_key = месяц + ДО/ПО + уточнённый тип + организация. Нумерация стабильна по сортировке ключа.';

COMMENT ON COLUMN dm_ouod.link_table.link_key IS 'Суррогатный ключ, стабильный при сортировке по месяцу, ДО/ПО, типу и организации. Один и тот же ключ у происшествия и агрегата с этим разрезом.';
COMMENT ON COLUMN dm_ouod.link_table.data_aggr IS 'Первое число месяца. Для происшествия — месяц Date, для показателя — месяц Date документа ввода, для накопленного итога — месяц, на который посчитано окно.';
COMMENT ON COLUMN dm_ouod.link_table.do_po IS 'Контур учёта. Для происшествия «ДО», если Подрядчик_Key — нулевой GUID, иначе «ПО». Для показателя «ДО», если ВидОтчета содержит «ДО», иначе «ПО».';
COMMENT ON COLUMN dm_ouod.link_table.utochnennyj_tip_proisshestviya IS 'Тип строки агрегата: уточнённый тип происшествия, служебный тип («КП с оборудованием», «Происшествия без последствий»), имя показателя (человеко-часы или пробег) либо то же имя с суффиксом «, c начала года» или «, скользящий 12 мес».';
COMMENT ON COLUMN dm_ouod.link_table.organizatsiya_key IS 'Организация_Key документа происшествия или документа ввода ежемесячных показателей.';
