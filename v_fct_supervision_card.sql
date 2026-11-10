-- dm_udh_msnbi_dash_odou.v_fct_supervision_card
-- Карты наблюдений: факт для дашборда ОД/ОУ.
--
-- Оптимизация относительно DDL-дампа:
--   * date >= '2021-01-01' вместо date_part(year) — sargable-предикат;
--   * в подзапросах только нужные колонки (без SELECT * из ODS);
--   * календарные поля через EXTRACT / массивы имён месяцев;
--   * ветки ОУ/ОД/разделители без повторного SELECT всех полей step1;
--   * спец-организации вынесены в CTE для читаемости.

CREATE OR REPLACE VIEW dm_udh_msnbi_dash_odou.v_fct_supervision_card
AS
WITH

-- Организации, для которых берём level_1 вместо subsidiary.
org_use_level1(organizaciya_key) AS (
    VALUES
        ('29dc5a8a-6f15-11ee-84b3-005056928be7'),
        ('fa679786-0a02-11ea-ac91-005056920bff'),
        ('60523ed2-fa4c-11e9-ac95-005056920bff'),
        ('5fb397b4-fa4c-11e9-ac95-005056920bff'),
        ('9d2a15ba-cb42-11ea-b595-005056920bff'),
        ('d111e57e-91fe-11de-ae48-002264b1bb78')
),

karty_struktura AS (
    SELECT
        kn.ref_key,
        kn.date,
        kn.number,
        kn.avtorfio_key,
        kn.kartalpabosnovanie_key,
        kn.mogloprivestiksmertelnomuishodu,
        kn.proisshestviebezposledstvij,
        kn.vsebezopasno,
        kn.opisanienablyudeniya,
        kn.kategoriyaodprochee,
        kn.opasnoedejstvie,
        kn.kategoriyaouprochee,
        kn.opasnoeuslovie,
        kn.nemedlennopredprinyatyedejstviya,
        kn.rabotaostanovlena,
        kn.neposredstvennopredprinyatyenamestedejstviyaipredp_edejstviya,
        kn.podrazdelenieurovnya1_key,
        kn.podrazdelenieurovnya2_key,
        kn.podrazdelenieurovnya3_key,
        kn.podryadnayaorganizaciya,
        kn.status_key,
        kn.vypolnyaemyeraboty_key,
        CASE
            WHEN lvl.organizaciya_key IS NOT NULL THEN pcsr.level_1_id
            ELSE pcsr.subsidiary_id
        END AS organizaciya_key,
        CASE
            WHEN lvl.organizaciya_key IS NOT NULL
                THEN replace(pcsr.level_1, 'ГПН-', '')
            ELSE replace(pcsr.subsidiary, 'ГПН-', '')
        END AS sub_org_desc
    FROM ods_pb1c_src_data.kartynablyudenij kn
    JOIN ods_pb1c_src_data_calc.pb1c_strukturapredpriyatiya_r pcsr
      ON kn.organizaciya_key = pcsr.organizatsionnayaedinitsa_key_group
     AND pcsr.subsidiary_id IS NOT NULL
    LEFT JOIN org_use_level1 lvl
      ON lvl.organizaciya_key = kn.organizaciya_key
    WHERE kn.deletionmark = FALSE
      AND kn.date >= TIMESTAMP '2021-01-01'
),

quarter_user_activity AS (
    SELECT
        (EXTRACT(YEAR FROM kn.date)::int * 10
            + EXTRACT(QUARTER FROM kn.date)::int) AS user_quarter,
        (EXTRACT(YEAR FROM kn.date - INTERVAL '3 months')::int * 10
            + EXTRACT(QUARTER FROM kn.date - INTERVAL '3 months')::int) AS prev_user_quarter,
        p.ref_key AS user_key,
        p.description AS user_desc,
        (p.familiya || ' ' || left(p.imya, 1) || '.' || left(p.otchestvo, 1) || '.') AS user_short_desc,
        CASE
            WHEN p.organizaciya_type ILIKE '%организации%' THEN 'ДО'
            WHEN p.organizaciya_type ILIKE '%контрагенты%' THEN 'ПО'
        END AS user_org_type,
        COUNT(kn.number) AS card_cnt
    FROM karty_struktura kn
    JOIN ods_pb1c_src_data.polzovatelimp p
      ON kn.avtorfio_key = p.ref_key
     AND p.deletionmark = FALSE
    GROUP BY 1, 2, p.ref_key, p.description,
        (p.familiya || ' ' || left(p.imya, 1) || '.' || left(p.otchestvo, 1) || '.'),
        CASE
            WHEN p.organizaciya_type ILIKE '%организации%' THEN 'ДО'
            WHEN p.organizaciya_type ILIKE '%контрагенты%' THEN 'ПО'
        END
),

dim_event AS (
    SELECT
        t.card_key,
        t.event_date::date AS event_date,
        t.datavypolneniya AS done_date,
        t.datazaversheniya AS complited_date,
        t.datanachalaispolneniya AS start_execution_date,
        t.srokproverki AS check_date,
        t.cancel_date,
        t.event_key,
        t.event_number,
        t.executor_desc,
        t.checking_desc,
        t.deadline_date,
        t.content_desc,
        t.event_status_desc,
        CASE
            WHEN t.event_status_desc = 'Выполнено'
             AND t.deadline_date < t.datazaversheniya::date THEN 1
            WHEN t.event_status_desc IN ('Отменено', 'ПодтверждениеОтмены')
             AND t.deadline_date < t.cancel_date THEN 1
            WHEN t.event_status_desc NOT IN ('Отменено', 'ПодтверждениеОтмены', 'НеСтартовано', 'Выполнено')
             AND t.deadline_date < CURRENT_DATE THEN 1
            ELSE 0
        END::smallint AS deadline_overdue_flg,
        ROW_NUMBER() OVER (
            PARTITION BY t.card_key
            ORDER BY t.event_date DESC, t.event_number DESC
        )::integer AS row_num_event
    FROM (
        SELECT
            m.predmet AS card_key,
            m.date AS event_date,
            m.datavypolneniya,
            m.datazaversheniya,
            m.datanachalaispolneniya,
            m.srokproverki,
            m.ref_key AS event_key,
            m.number AS event_number,
            i.description AS executor_desc,
            p.description AS checking_desc,
            m.srokispolneniya::date AS deadline_date,
            CASE
                WHEN m.status IN ('Отменено', 'ПодтверждениеОтмены') THEN
                    replace(
                        concat(
                            substring(substring(m.rezultatvypolneniya, 1, 10), 7, 4), '-',
                            substring(substring(m.rezultatvypolneniya, 1, 10), 4, 2), '-',
                            substring(substring(m.rezultatvypolneniya, 1, 10), 1, 2)
                        ),
                        '--',
                        '1900-01-01'
                    )::date
            END AS cancel_date,
            NULLIF(m.soderzhanie, '') AS content_desc,
            m.status AS event_status_desc,
            ROW_NUMBER() OVER (
                PARTITION BY m.ref_key
                ORDER BY m.write_ts DESC
            ) AS rn
        FROM ods_pb1c_src_data.meropriyatie m
        JOIN karty_struktura kn
          ON kn.ref_key = m.predmet
        LEFT JOIN ods_pb1c_src_data.polzovateli i
          ON m.ispolnitel = i.ref_key
         AND i.deletionmark = FALSE
        LEFT JOIN ods_pb1c_src_data.polzovateli p
          ON m.proveryayushhij = p.ref_key
         AND p.deletionmark = FALSE
        WHERE m.deletionmark = FALSE
    ) t
    WHERE t.rn = 1
),

card_step1 AS (
    SELECT
        kn.ref_key AS card_key,
        kn.number AS card_number,
        kn.date::date AS card_date,
        EXTRACT(YEAR FROM kn.date)::integer AS card_year,
        EXTRACT(MONTH FROM kn.date)::integer AS card_month,
        (ARRAY[
            'янв', 'фев', 'мар', 'апр', 'май', 'июн',
            'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'
         ])[EXTRACT(MONTH FROM kn.date)::int] AS card_month_short_nm,
        (ARRAY[
            'январь', 'февраль', 'март', 'апрель', 'май', 'июнь',
            'июль', 'август', 'сентябрь', 'октябрь', 'ноябрь', 'декабрь'
         ])[EXTRACT(MONTH FROM kn.date)::int] AS card_month_nm,
        (EXTRACT(YEAR FROM kn.date)::int * 100
            + EXTRACT(MONTH FROM kn.date)::int) AS card_month_year,
        (ARRAY[
            'янв', 'фев', 'мар', 'апр', 'май', 'июн',
            'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'
         ])[EXTRACT(MONTH FROM kn.date)::int]
            || ' ' || EXTRACT(YEAR FROM kn.date)::text AS card_year_month_short_nm,
        EXTRACT(QUARTER FROM kn.date)::integer AS card_quarter,
        (EXTRACT(YEAR FROM kn.date)::int * 10
            + EXTRACT(QUARTER FROM kn.date)::int) AS card_quarter_year,
        (EXTRACT(QUARTER FROM kn.date)::text || 'кв. '
            || substring(EXTRACT(YEAR FROM kn.date)::text, 3)) AS card_quarter_year_name,
        NULLIF(kn.opisanienablyudeniya, '') AS supervision_desc,
        kn.kartalpabosnovanie_key AS lpab_card_key,
        CASE WHEN kn.mogloprivestiksmertelnomuishodu IS TRUE THEN 1 ELSE 0 END::smallint AS hipo_flg,
        CASE WHEN kn.proisshestviebezposledstvij IS TRUE THEN 1 ELSE 0 END::smallint AS no_consequence_flg,
        CASE WHEN kn.vsebezopasno IS TRUE THEN 1 ELSE 0 END::smallint AS safe_flg,
        s.description AS card_status_desc,
        CASE WHEN kn.date < TIMESTAMP '2023-01-01' THEN 1 ELSE 0 END::smallint AS archive_flg,
        kn.avtorfio_key AS author_key,
        p.description AS author_desc,
        CASE
            WHEN p.organizaciya_type ILIKE '%организации%' THEN o.description
            WHEN p.organizaciya_type ILIKE '%контрагенты%' THEN k.description
            WHEN p.organizaciya_type ILIKE '%string%' THEN NULLIF(p.organizaciya, '')
        END AS author_workplace_desc,
        m.description AS author_depart_desc,
        CASE WHEN length(kn.kategoriyaodprochee) > 1 THEN 1 ELSE 0 END::smallint AS unsafe_act_other_flg,
        CASE WHEN length(kn.kategoriyaouprochee) > 1 THEN 1 ELSE 0 END::smallint AS unsafe_condition_other_flg,
        CASE
            WHEN length(kn.kategoriyaodprochee) > 1
             AND kn.opasnoedejstvie = FALSE
             AND kn.date < TIMESTAMP '2023-01-01'
                THEN 1
            WHEN kn.opasnoedejstvie = TRUE THEN 1
            ELSE 0
        END::smallint AS unsafe_act_flg,
        CASE
            WHEN length(kn.kategoriyaouprochee) > 1
             AND kn.opasnoeuslovie = FALSE
             AND kn.date < TIMESTAMP '2023-01-01'
                THEN 1
            WHEN kn.opasnoeuslovie = TRUE THEN 1
            ELSE 0
        END::smallint AS unsafe_condition_flg,
        g.description AS work_desc,
        kn.nemedlennopredprinyatyedejstviya AS completed_action_desc,
        CASE WHEN kn.rabotaostanovlena IS TRUE THEN 1 ELSE 0 END::smallint AS work_stopped_flg,
        kn.neposredstvennopredprinyatyenamestedejstviyaipredp_edejstviya AS suggested_action_desc,
        kn.organizaciya_key AS organization_key,
        kn.sub_org_desc,
        kn.podrazdelenieurovnya1_key AS organization_unit1_key,
        kn.podrazdelenieurovnya2_key AS organization_unit2_key,
        kn.podrazdelenieurovnya3_key AS organization_unit3_key,
        kn.podryadnayaorganizaciya AS contract_organization_key
    FROM karty_struktura kn
    LEFT JOIN ods_pb1c_src_data.statusykartnablyudeniya s
      ON kn.status_key = s.ref_key
     AND s.deletionmark = FALSE
    LEFT JOIN ods_pb1c_src_data.polzovatelimp p
      ON kn.avtorfio_key = p.ref_key
     AND p.deletionmark = FALSE
    LEFT JOIN ods_pb1c_src_data.organizacii o
      ON p.organizaciya = o.ref_key
     AND o.deletionmark = FALSE
    LEFT JOIN ods_pb1c_src_data.kontragenty k
      ON k.ref_key = p.organizaciya
     AND k.deletionmark = FALSE
    LEFT JOIN ods_pb1c_src_data.gpnvypolnyaemyeraboty g
      ON kn.vypolnyaemyeraboty_key = g.ref_key
     AND g.deletionmark = FALSE
    LEFT JOIN ods_pb1c_src_data.mestopolozheniya m
      ON p.strukturnoepodrazdelenie_key = m.ref_key
),

-- Разделители ОУ/ОД/безопасно/ПбП (с 2023 — флаги; до 2023 — строки категорий).
card_separate AS (
    SELECT
        tmp.card_key,
        tmp.separate_key,
        tmp.separate_desc,
        tmp.separate_cnt,
        ROW_NUMBER() OVER (
            PARTITION BY tmp.card_key
            ORDER BY tmp.separate_key
        ) AS row_num_separate
    FROM (
        SELECT
            c.card_key,
            1::smallint AS separate_key,
            'ОУ'::text AS separate_desc,
            1::bigint AS separate_cnt
        FROM card_step1 c
        WHERE c.unsafe_condition_flg = 1
          AND c.card_date >= DATE '2023-01-01'

        UNION ALL
        SELECT
            c.card_key,
            2::smallint,
            'ОД'::text,
            1::bigint
        FROM card_step1 c
        WHERE c.unsafe_act_flg = 1
          AND c.card_date >= DATE '2023-01-01'

        UNION ALL
        SELECT
            x.card_key,
            1::smallint,
            'ОУ'::text,
            COUNT(1)
        FROM (
            SELECT koy.ref_key AS card_key
            FROM ods_pb1c_src_data.kartynablyudenij_kategoriiopasnyhuslovij koy
            JOIN card_step1 c
              ON koy.ref_key = c.card_key
             AND c.card_date < DATE '2023-01-01'
             AND c.unsafe_condition_flg = 1
            UNION ALL
            SELECT c.card_key
            FROM card_step1 c
            WHERE c.unsafe_condition_other_flg = 1
              AND c.archive_flg = 1
        ) x
        GROUP BY x.card_key

        UNION ALL
        SELECT
            x.card_key,
            2::smallint,
            'ОД'::text,
            COUNT(1)
        FROM (
            SELECT kod.ref_key AS card_key, kod.kategoriya_key
            FROM ods_pb1c_src_data.kartynablyudenij_kategoriiopasnyhdejstvij kod
            JOIN card_step1 c
              ON kod.ref_key = c.card_key
             AND c.card_date < DATE '2023-01-01'
             AND c.unsafe_act_flg = 1
            GROUP BY kod.ref_key, kod.kategoriya_key
            UNION ALL
            SELECT c.card_key, '10000000-0000-0000-0000-100000000000'::text
            FROM card_step1 c
            WHERE c.unsafe_act_other_flg = 1
              AND c.archive_flg = 1
        ) x
        GROUP BY x.card_key

        UNION ALL
        SELECT
            c.card_key,
            3::smallint,
            'Все безопасно'::text,
            1::bigint
        FROM card_step1 c
        WHERE c.safe_flg = 1

        UNION ALL
        SELECT
            c.card_key,
            4::smallint,
            'ПбП'::text,
            1::bigint
        FROM card_step1 c
        WHERE c.no_consequence_flg = 1
    ) tmp
),

map_condition_area AS (
    SELECT
        opasnoeuslovie_key,
        oblastproisshestvij_key,
        gruppaproisshestvij_key
    FROM ods_pb1c_src_data.sootvetstvieprichiniuslovijdlyafiksaciiopasnyhdejstvijikt55
    GROUP BY opasnoeuslovie_key, oblastproisshestvij_key, gruppaproisshestvij_key
),

map_act_area AS (
    SELECT
        prichinaopasnogodejstviya_key,
        oblastproisshestvij_key,
        gruppaproisshestvij_key
    FROM ods_pb1c_src_data.sootvetstvieprichiniuslovijdlyafiksaciiopasnyhdejstvijikt55
    GROUP BY prichinaopasnogodejstviya_key, oblastproisshestvij_key, gruppaproisshestvij_key
),

card_hazard AS (
    -- Не «Персонал»: область/группа по опасному условию.
    SELECT
        kou.ref_key AS card_key,
        COALESCE(parent.description, ou.description) AS hazard_category_desc,
        obl.description AS incident_area_desc,
        grp.description AS incident_group_desc,
        ou.description AS probably_happen_desc
    FROM card_step1 c
    JOIN (
        SELECT ref_key, kategoriya_key
        FROM ods_pb1c_src_data.kartynablyudenij_kategoriiopasnyhuslovij
        GROUP BY ref_key, kategoriya_key
    ) kou
      ON c.card_key = kou.ref_key
    LEFT JOIN ods_pb1c_src_data.kategoriiopasnyhuslovij ou
      ON kou.kategoriya_key = ou.ref_key
    LEFT JOIN ods_pb1c_src_data.kategoriiopasnyhuslovij parent
      ON parent.ref_key = ou.parent_key
    LEFT JOIN map_condition_area map
      ON map.opasnoeuslovie_key = kou.kategoriya_key
    LEFT JOIN ods_pb1c_src_data.oblastiproisshestvij obl
      ON obl.ref_key = map.oblastproisshestvij_key
    LEFT JOIN ods_pb1c_src_data.gruppyproisshestvij grp
      ON grp.ref_key = map.gruppaproisshestvij_key
    WHERE c.card_date >= DATE '2023-01-01'
      AND ou.description <> 'Персонал'

    UNION ALL

    -- «Персонал»: область/группа по причине ОД; при нескольких — NULL.
    SELECT
        pr.card_key,
        pr.hazard_category_desc,
        CASE WHEN pr.cnt > 1 THEN NULL ELSE pr.incident_area_desc END,
        CASE WHEN pr.cnt > 1 THEN NULL ELSE pr.incident_group_desc END,
        pr.probably_happen_desc
    FROM (
        SELECT
            kou.ref_key AS card_key,
            COALESCE(parent.description, ou.description) AS hazard_category_desc,
            obl.description AS incident_area_desc,
            grp.description AS incident_group_desc,
            ou.description AS probably_happen_desc,
            COUNT(c.card_number) OVER (PARTITION BY c.card_number) AS cnt
        FROM card_step1 c
        LEFT JOIN ods_pb1c_src_data.kartynablyudenij_kategoriiopasnyhuslovij kou
          ON c.card_key = kou.ref_key
        LEFT JOIN ods_pb1c_src_data.kategoriiopasnyhuslovij ou
          ON kou.kategoriya_key = ou.ref_key
        LEFT JOIN ods_pb1c_src_data.kategoriiopasnyhuslovij parent
          ON parent.ref_key = ou.parent_key
        LEFT JOIN map_act_area map
          ON map.prichinaopasnogodejstviya_key = kou.prichina_key
        LEFT JOIN ods_pb1c_src_data.oblastiproisshestvij obl
          ON obl.ref_key = map.oblastproisshestvij_key
        LEFT JOIN ods_pb1c_src_data.gruppyproisshestvij grp
          ON grp.ref_key = map.gruppaproisshestvij_key
        WHERE c.card_date >= DATE '2023-01-01'
          AND ou.description = 'Персонал'
    ) pr
    GROUP BY
        pr.card_key,
        pr.hazard_category_desc,
        CASE WHEN pr.cnt > 1 THEN NULL ELSE pr.incident_area_desc END,
        CASE WHEN pr.cnt > 1 THEN NULL ELSE pr.incident_group_desc END,
        pr.probably_happen_desc
)

SELECT
    kn.card_key,
    tscs.separate_key,
    tscs.separate_desc,
    tscs.separate_cnt,
    tqua.user_quarter,
    tqua.prev_user_quarter,
    tqua.user_desc,
    tqua.user_short_desc,
    tqua.user_org_type,
    tqua.card_cnt,
    kn.card_number,
    kn.card_date,
    kn.card_year,
    kn.card_month,
    kn.card_month_short_nm,
    kn.card_month_nm,
    kn.card_month_year,
    kn.card_year_month_short_nm,
    kn.card_quarter,
    kn.card_quarter_year,
    kn.card_quarter_year_name,
    kn.supervision_desc,
    kn.lpab_card_key,
    kn.hipo_flg,
    kn.no_consequence_flg,
    kn.safe_flg,
    kn.card_status_desc,
    kn.author_key,
    kn.author_desc,
    kn.author_workplace_desc,
    kn.author_depart_desc,
    kn.unsafe_act_other_flg,
    kn.unsafe_condition_other_flg,
    kn.unsafe_act_flg,
    kn.unsafe_condition_flg,
    ko.hazard_category_desc,
    ko.incident_area_desc,
    ko.incident_group_desc,
    ko.probably_happen_desc,
    kn.work_desc,
    kn.completed_action_desc,
    kn.suggested_action_desc,
    kn.work_stopped_flg,
    vde.event_date,
    vde.done_date,
    vde.complited_date,
    vde.start_execution_date,
    vde.check_date,
    vde.cancel_date,
    vde.event_key,
    vde.event_number,
    vde.executor_desc,
    vde.checking_desc,
    vde.deadline_date,
    vde.content_desc,
    vde.event_status_desc,
    vde.deadline_overdue_flg,
    kn.organization_key,
    kn.sub_org_desc,
    kn.organization_unit1_key,
    mp.description AS departament_desc,
    kn.organization_unit2_key,
    mr.description AS mine_desc,
    mp1.description AS platform_desc,
    kn.organization_unit3_key,
    mp3.description AS object_desc,
    kn.contract_organization_key,
    k.description AS contract_organization_desc,
    COALESCE(vde.row_num_event, 1) AS row_num_event,
    COALESCE(tscs.row_num_separate, 1)::integer AS row_num_separate,
    ROW_NUMBER() OVER (
        PARTITION BY tqua.user_key, tqua.user_quarter
        ORDER BY kn.card_date DESC, vde.event_date DESC, tscs.separate_key, kn.card_key, vde.event_key
    )::integer AS row_num_user_activity
FROM card_step1 kn
LEFT JOIN card_hazard ko
  ON kn.card_key = ko.card_key
LEFT JOIN ods_pb1c_src_data.kontragenty k
  ON kn.contract_organization_key = k.ref_key
 AND k.deletionmark = FALSE
LEFT JOIN ods_pb1c_src_data.mestopolozheniya mp
  ON kn.organization_unit1_key = mp.ref_key
 AND mp.deletionmark = FALSE
LEFT JOIN ods_pb1c_src_data.mestopolozheniya mp1
  ON kn.organization_unit2_key = mp1.ref_key
 AND mp1.deletionmark = FALSE
LEFT JOIN ods_pb1c_src_data.mestorozhdeniya mr
  ON mp1.mestorozhdenie_key = mr.ref_key
 AND mr.deletionmark = FALSE
LEFT JOIN ods_pb1c_src_data.mestopolozheniya mp3
  ON mp3.ref_key = kn.organization_unit3_key
 AND mp3.deletionmark = FALSE
LEFT JOIN dim_event vde
  ON vde.card_key = kn.card_key
LEFT JOIN quarter_user_activity tqua
  ON tqua.user_key = kn.author_key
 AND tqua.user_quarter = kn.card_quarter_year
LEFT JOIN card_separate tscs
  ON tscs.card_key = kn.card_key;

COMMENT ON VIEW dm_udh_msnbi_dash_odou.v_fct_supervision_card IS 'Факт Карты наблюдений';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.card_key IS 'Ключ КН';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.separate_key IS 'Ключ разделителя КН';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.separate_desc IS 'Описание разделителя (ОУ/ОД/Все безопасно/ПбП)';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.separate_cnt IS 'Количество ОУ/ОД/Все безопасно/ПбП';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.user_quarter IS 'Квартал';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.prev_user_quarter IS 'Предыдущий квартал';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.user_desc IS 'ФИО пользователя';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.user_short_desc IS 'Фамилия и инициалы пользователя';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.user_org_type IS 'Тип организации пользователя (ДО/ПО)';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.card_cnt IS 'Кол-во карт, оформленных пользователем за квартал';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.card_number IS 'Регистрационный номер КН';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.card_date IS 'Дата КН';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.card_year IS 'Год КН';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.card_month IS 'Месяц КН';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.card_month_short_nm IS 'Сокращенное название месяца КН';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.card_month_nm IS 'Название месяца КН';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.card_month_year IS 'Месяц и год КН';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.card_year_month_short_nm IS 'Год и сокращенное название месяца КН';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.card_quarter IS 'Квартал КН';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.card_quarter_year IS 'Квартал и год КН';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.card_quarter_year_name IS 'Квартал c кв. и год КН';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.supervision_desc IS 'Описание события';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.lpab_card_key IS 'Ключ карты ЛПАБ';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.hipo_flg IS 'Признак Могло привести к смертельному исходу';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.no_consequence_flg IS 'Признак Без последствий';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.safe_flg IS 'Признак Все безопасно';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.card_status_desc IS 'Статус КН';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.author_key IS 'Ключ автора (работника выявившего ОД/ОУ)';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.author_desc IS 'ФИО автора';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.author_workplace_desc IS 'Место работы автора';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.author_depart_desc IS 'Структурное подразделение сотрудника выявившего ОД ОУ';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.unsafe_act_other_flg IS 'Признак категория ОД прочее';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.unsafe_condition_other_flg IS 'Признак категория ОУ прочее';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.unsafe_act_flg IS 'Признак ОД';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.unsafe_condition_flg IS 'Признак ОУ';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.hazard_category_desc IS 'Категория опасности';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.incident_area_desc IS 'Область происшествий';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.incident_group_desc IS 'Группа происшествий';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.probably_happen_desc IS 'Что может произойти';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.work_desc IS 'Выполняемые работы';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.completed_action_desc IS 'Предпринятые действия';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.suggested_action_desc IS 'Предполагаемые действия';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.work_stopped_flg IS 'Приостановка работ';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.event_date IS 'Дата мероприятия';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.done_date IS 'Дата Выполнения';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.complited_date IS 'Дата Завершения';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.start_execution_date IS 'Дата Начала Исполнения';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.check_date IS 'Срок Проверки';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.cancel_date IS 'Дата отмены';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.event_key IS 'Ключ мероприятия';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.event_number IS 'Номер мероприятия';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.executor_desc IS 'Исполнитель';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.checking_desc IS 'Проверяющий';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.deadline_date IS 'Срок исполнения';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.content_desc IS 'Содержание';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.event_status_desc IS 'Статус мероприятия';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.deadline_overdue_flg IS 'Флаг просроченного мероприятия';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.organization_key IS 'Ключ ДО (организации)';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.sub_org_desc IS 'ДО';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.organization_unit1_key IS 'Ключ подразделения уровня 1';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.departament_desc IS 'Структурное подразделение';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.organization_unit2_key IS 'Ключ подразделения уровня 2';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.mine_desc IS 'Месторождение';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.platform_desc IS 'Площадка';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.organization_unit3_key IS 'Ключ подразделения уровня 3';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.object_desc IS 'Объект';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.contract_organization_key IS 'Ключ подрядной организации';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.contract_organization_desc IS 'Подрядная организация';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.row_num_event IS 'Порядковый номер мероприятия';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.row_num_separate IS 'Порядковый номер разделителя КН';
COMMENT ON COLUMN dm_udh_msnbi_dash_odou.v_fct_supervision_card.row_num_user_activity IS 'Порядковый номер активности пользователей в квартал';
