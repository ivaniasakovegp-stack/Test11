-- PostgreSQL 9.4.26 / Greenplum 6.22
-- Логика: 02-1 Transform 1С КЛАД происшествия по КТ-55.qvs
--         03-1 PreCalc КЛАД 1С происшествия по КТ-55.qvs
-- QVD: cDataTier3/СправочникДО.qvd
-- Представление читает только ods_pb1c_src_data. Другие представления не используются.
--
-- Не вошло в источник source.sql и поэтому не включено:
--   * Excel «Происшествия за 2020 год для LTIF» (история для скользящего LTIF);
--   * QVD Количество_ОД_ОУ (типы ОД, ОУ, «Происшествия без последствий ОД/ОУ»).
--
-- Без WITH RECURSIVE: в GP6 рекурсивный обход при инлайне CTE даёт сотни slices
-- (ошибка «at most 300 slices are allowed»). Путь d1–d7 собирается цепочкой
-- LEFT JOIN к родителям. Ветки b1–b5 сведены в один CASE — иначе EXISTS по
-- предыдущим веткам снова размножает план.

CREATE SCHEMA IF NOT EXISTS dm_ouod;

DROP VIEW IF EXISTS dm_ouod.spravochnik_do;

CREATE VIEW dm_ouod.spravochnik_do AS
WITH

org_src AS (
    SELECT DISTINCT ON (s.ref_key)
        s.ref_key,
        CASE
            WHEN s.parent_key IS NULL
              OR s.parent_key IN ('', '00000000-0000-0000-0000-000000000000')
                THEN NULL
            ELSE s.parent_key
        END AS parent_key,
        CASE
            WHEN s.naimenovaniesokrashhennoe IS NULL
              OR s.naimenovaniesokrashhennoe = ''
                THEN s.description
            ELSE s.naimenovaniesokrashhennoe
        END AS description,
        s.organizacionnayaedinica
    FROM ods_pb1c_src_data.strukturapredpriyatiya s
    WHERE (
            s.polnoepredstavlenie ILIKE '%БРД%'
            AND s.gpnarhivnyj = FALSE
          )
       OR s.description ILIKE '%ГПН-Снабжение%'
    ORDER BY s.ref_key
),

-- Путь от корня к узлу без RECURSIVE: до 12 уровней родителей (d1–d7 + запас).
org_hier AS (
    SELECT
        n.ref_key,
        n.description,
        n.organizacionnayaedinica,
        path_name[1] AS d1,
        path_name[2] AS d2,
        path_name[3] AS d3,
        path_name[4] AS d4,
        path_name[5] AS d5,
        path_name[6] AS d6,
        path_name[7] AS d7
    FROM (
        SELECT
            n.ref_key,
            n.description,
            n.organizacionnayaedinica,
            CASE
                WHEN p11.ref_key IS NOT NULL THEN
                    ARRAY[
                        COALESCE(p11.description, ''), COALESCE(p10.description, ''),
                        COALESCE(p9.description, ''),  COALESCE(p8.description, ''),
                        COALESCE(p7.description, ''),  COALESCE(p6.description, ''),
                        COALESCE(p5.description, ''),  COALESCE(p4.description, ''),
                        COALESCE(p3.description, ''),  COALESCE(p2.description, ''),
                        COALESCE(p1.description, ''),  COALESCE(n.description, '')
                    ]::text[]
                WHEN p10.ref_key IS NOT NULL THEN
                    ARRAY[
                        COALESCE(p10.description, ''), COALESCE(p9.description, ''),
                        COALESCE(p8.description, ''),  COALESCE(p7.description, ''),
                        COALESCE(p6.description, ''),  COALESCE(p5.description, ''),
                        COALESCE(p4.description, ''),  COALESCE(p3.description, ''),
                        COALESCE(p2.description, ''),  COALESCE(p1.description, ''),
                        COALESCE(n.description, '')
                    ]::text[]
                WHEN p9.ref_key IS NOT NULL THEN
                    ARRAY[
                        COALESCE(p9.description, ''), COALESCE(p8.description, ''),
                        COALESCE(p7.description, ''), COALESCE(p6.description, ''),
                        COALESCE(p5.description, ''), COALESCE(p4.description, ''),
                        COALESCE(p3.description, ''), COALESCE(p2.description, ''),
                        COALESCE(p1.description, ''), COALESCE(n.description, '')
                    ]::text[]
                WHEN p8.ref_key IS NOT NULL THEN
                    ARRAY[
                        COALESCE(p8.description, ''), COALESCE(p7.description, ''),
                        COALESCE(p6.description, ''), COALESCE(p5.description, ''),
                        COALESCE(p4.description, ''), COALESCE(p3.description, ''),
                        COALESCE(p2.description, ''), COALESCE(p1.description, ''),
                        COALESCE(n.description, '')
                    ]::text[]
                WHEN p7.ref_key IS NOT NULL THEN
                    ARRAY[
                        COALESCE(p7.description, ''), COALESCE(p6.description, ''),
                        COALESCE(p5.description, ''), COALESCE(p4.description, ''),
                        COALESCE(p3.description, ''), COALESCE(p2.description, ''),
                        COALESCE(p1.description, ''), COALESCE(n.description, '')
                    ]::text[]
                WHEN p6.ref_key IS NOT NULL THEN
                    ARRAY[
                        COALESCE(p6.description, ''), COALESCE(p5.description, ''),
                        COALESCE(p4.description, ''), COALESCE(p3.description, ''),
                        COALESCE(p2.description, ''), COALESCE(p1.description, ''),
                        COALESCE(n.description, '')
                    ]::text[]
                WHEN p5.ref_key IS NOT NULL THEN
                    ARRAY[
                        COALESCE(p5.description, ''), COALESCE(p4.description, ''),
                        COALESCE(p3.description, ''), COALESCE(p2.description, ''),
                        COALESCE(p1.description, ''), COALESCE(n.description, '')
                    ]::text[]
                WHEN p4.ref_key IS NOT NULL THEN
                    ARRAY[
                        COALESCE(p4.description, ''), COALESCE(p3.description, ''),
                        COALESCE(p2.description, ''), COALESCE(p1.description, ''),
                        COALESCE(n.description, '')
                    ]::text[]
                WHEN p3.ref_key IS NOT NULL THEN
                    ARRAY[
                        COALESCE(p3.description, ''), COALESCE(p2.description, ''),
                        COALESCE(p1.description, ''), COALESCE(n.description, '')
                    ]::text[]
                WHEN p2.ref_key IS NOT NULL THEN
                    ARRAY[
                        COALESCE(p2.description, ''), COALESCE(p1.description, ''),
                        COALESCE(n.description, '')
                    ]::text[]
                WHEN p1.ref_key IS NOT NULL THEN
                    ARRAY[
                        COALESCE(p1.description, ''), COALESCE(n.description, '')
                    ]::text[]
                ELSE
                    ARRAY[COALESCE(n.description, '')]::text[]
            END AS path_name
        FROM org_src n
        LEFT JOIN org_src p1
          ON n.parent_key IS NOT NULL
         AND p1.ref_key = n.parent_key
         AND p1.ref_key IS DISTINCT FROM n.ref_key
        LEFT JOIN org_src p2
          ON p1.parent_key IS NOT NULL
         AND p2.ref_key = p1.parent_key
         AND p2.ref_key IS DISTINCT FROM p1.ref_key
        LEFT JOIN org_src p3
          ON p2.parent_key IS NOT NULL
         AND p3.ref_key = p2.parent_key
         AND p3.ref_key IS DISTINCT FROM p2.ref_key
        LEFT JOIN org_src p4
          ON p3.parent_key IS NOT NULL
         AND p4.ref_key = p3.parent_key
         AND p4.ref_key IS DISTINCT FROM p3.ref_key
        LEFT JOIN org_src p5
          ON p4.parent_key IS NOT NULL
         AND p5.ref_key = p4.parent_key
         AND p5.ref_key IS DISTINCT FROM p4.ref_key
        LEFT JOIN org_src p6
          ON p5.parent_key IS NOT NULL
         AND p6.ref_key = p5.parent_key
         AND p6.ref_key IS DISTINCT FROM p5.ref_key
        LEFT JOIN org_src p7
          ON p6.parent_key IS NOT NULL
         AND p7.ref_key = p6.parent_key
         AND p7.ref_key IS DISTINCT FROM p6.ref_key
        LEFT JOIN org_src p8
          ON p7.parent_key IS NOT NULL
         AND p8.ref_key = p7.parent_key
         AND p8.ref_key IS DISTINCT FROM p7.ref_key
        LEFT JOIN org_src p9
          ON p8.parent_key IS NOT NULL
         AND p9.ref_key = p8.parent_key
         AND p9.ref_key IS DISTINCT FROM p8.ref_key
        LEFT JOIN org_src p10
          ON p9.parent_key IS NOT NULL
         AND p10.ref_key = p9.parent_key
         AND p10.ref_key IS DISTINCT FROM p9.ref_key
        LEFT JOIN org_src p11
          ON p10.parent_key IS NOT NULL
         AND p11.ref_key = p10.parent_key
         AND p11.ref_key IS DISTINCT FROM p10.ref_key
    ) n
)

SELECT
    CASE
        WHEN h.d2 ILIKE 'ГПН%' THEN h.d1
        WHEN h.d4 ILIKE 'ГПН%'
          OR h.d4 ILIKE '%Мегион %'
          OR h.d4 ILIKE 'ИТС'
            THEN h.d1
        WHEN h.description ILIKE '%Томск%' THEN h.d1
        WHEN h.d1 ILIKE 'ГПН-Снабжение' THEN 'БППП'
        ELSE h.d1
    END AS blok,
    CASE
        WHEN h.d2 ILIKE 'ГПН%' THEN ''::text
        WHEN h.d4 ILIKE 'ГПН%'
          OR h.d4 ILIKE '%Мегион %'
          OR h.d4 ILIKE 'ИТС'
            THEN h.d2
        WHEN h.description ILIKE '%Томск%' THEN h.d2
        WHEN h.d1 ILIKE 'ГПН-Снабжение' THEN h.d2
        ELSE h.d2
    END AS direkciya,
    CASE
        WHEN h.d2 ILIKE 'ГПН%' THEN h.d2
        WHEN h.d4 ILIKE 'ГПН%'
          OR h.d4 ILIKE '%Мегион %'
          OR h.d4 ILIKE 'ИТС'
            THEN h.d4
        WHEN h.description ILIKE '%Томск%' THEN h.description
        WHEN h.d1 ILIKE 'ГПН-Снабжение' THEN h.d1
        ELSE h.d3
    END AS do_naimenovanie,
    CASE
        WHEN h.d2 ILIKE 'ГПН%' THEN h.d2
        WHEN h.d4 ILIKE 'ГПН%'
          OR h.d4 ILIKE '%Мегион %'
          OR h.d4 ILIKE 'ИТС'
            THEN h.d3
        WHEN h.description ILIKE '%Томск%' THEN h.d3
        WHEN h.d1 ILIKE 'ГПН-Снабжение' THEN h.d1
        ELSE h.d3
    END AS do_gruppy,
    CASE
        WHEN h.d2 ILIKE 'ГПН%' THEN h.d3
        WHEN h.d4 ILIKE 'ГПН%'
          OR h.d4 ILIKE '%Мегион %'
          OR h.d4 ILIKE 'ИТС'
            THEN h.d5
        WHEN h.description ILIKE '%Томск%' THEN h.d4
        WHEN h.d1 ILIKE 'ГПН-Снабжение' THEN h.d4
        ELSE h.d4
    END AS obekt_urovnya_1,
    CASE
        WHEN h.d2 ILIKE 'ГПН%' THEN h.d4
        WHEN h.d4 ILIKE 'ГПН%'
          OR h.d4 ILIKE '%Мегион %'
          OR h.d4 ILIKE 'ИТС'
            THEN h.d6
        WHEN h.description ILIKE '%Томск%' THEN h.d5
        WHEN h.d1 ILIKE 'ГПН-Снабжение' THEN h.d5
        ELSE h.d5
    END AS obekt_urovnya_2,
    CASE
        WHEN h.d2 ILIKE 'ГПН%' THEN h.d5
        WHEN h.d4 ILIKE 'ГПН%'
          OR h.d4 ILIKE '%Мегион %'
          OR h.d4 ILIKE 'ИТС'
            THEN h.d7
        WHEN h.description ILIKE '%Томск%' THEN h.d6
        WHEN h.d1 ILIKE 'ГПН-Снабжение' THEN h.d6
        ELSE h.d6
    END AS obekt_urovnya_3,
    CASE
        WHEN h.d2 ILIKE 'ГПН%' THEN h.d6
        WHEN h.d4 ILIKE 'ГПН%'
          OR h.d4 ILIKE '%Мегион %'
          OR h.d4 ILIKE 'ИТС'
            THEN NULL::text
        WHEN h.description ILIKE '%Томск%' THEN h.d7
        WHEN h.d1 ILIKE 'ГПН-Снабжение' THEN h.d7
        ELSE h.d7
    END AS obekt_urovnya_4,
    CASE
        WHEN h.d2 ILIKE 'ГПН%' THEN h.d7
        ELSE NULL::text
    END AS obekt_urovnya_5,
    h.description AS mesto_proisshestviya,
    h.organizacionnayaedinica AS organizatsiya_key
FROM org_hier h;

COMMENT ON VIEW dm_ouod.spravochnik_do IS 'Справочник ДО/ПО: уровни оргструктуры БРД и ГПН-Снабжение.';

COMMENT ON COLUMN dm_ouod.spravochnik_do.blok IS 'Верхний уровень иерархии структуры предприятия (первый элемент пути). Имя узла — НаименованиеСокращенное, если оно заполнено, иначе Description. Для отдельной ветки ГПН-Снабжение подставляется константа БППП.';
COMMENT ON COLUMN dm_ouod.spravochnik_do.direkciya IS 'Дирекция: второй уровень иерархии. В ветке, где второй уровень начинается с ГПН, поле намеренно пустое.';
COMMENT ON COLUMN dm_ouod.spravochnik_do.do_naimenovanie IS 'Дочернее общество. Уровень пути зависит от ветки справочника: второй уровень для узлов ГПН; четвёртый, если он ГПН, Мегион или ИТС; третий в общей ветке; наименование самого узла для Томска; первый уровень для ГПН-Снабжение.';
COMMENT ON COLUMN dm_ouod.spravochnik_do.do_gruppy IS 'Группа дочерних обществ. Совпадает с ДО в ветке ГПН и для ГПН-Снабжение; в остальных ветках это третий уровень иерархии.';
COMMENT ON COLUMN dm_ouod.spravochnik_do.obekt_urovnya_1 IS 'Объект на следующем уровне после ДО. Глубина исходного узла сдвигается по ветке справочника; если уровня нет, NULL.';
COMMENT ON COLUMN dm_ouod.spravochnik_do.obekt_urovnya_2 IS 'Объект на два уровня ниже ДО. Если ветка справочника этот уровень не заполняет, NULL.';
COMMENT ON COLUMN dm_ouod.spravochnik_do.obekt_urovnya_3 IS 'Объект на три уровня ниже ДО. Если ветка справочника этот уровень не заполняет, NULL.';
COMMENT ON COLUMN dm_ouod.spravochnik_do.obekt_urovnya_4 IS 'Объект на четыре уровня ниже ДО. В ветке четвёртого уровня (ГПН, Мегион, ИТС) не заполняется.';
COMMENT ON COLUMN dm_ouod.spravochnik_do.obekt_urovnya_5 IS 'Объект на пять уровней ниже ДО. Заполняется только в ветке, где ДО — второй уровень иерархии (ГПН).';
COMMENT ON COLUMN dm_ouod.spravochnik_do.mesto_proisshestviya IS 'Наименование текущего узла структуры предприятия: НаименованиеСокращенное, а при пустом сокращении — Description.';
COMMENT ON COLUMN dm_ouod.spravochnik_do.organizatsiya_key IS 'ОрганизационнаяЕдиница узла структуры предприятия. Ключ связи с Организация_Key происшествия и ежемесячных показателей.';
