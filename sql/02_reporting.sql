-- 02_reporting.sql — витрина и метрики в схеме reporting.
-- Идемпотентно: CREATE OR REPLACE VIEW, повторный запуск ничего не ломает.
--
-- Правила расчёта (из задания):
--   портфель     = Σ principal_outstanding в тенге по курсу НА ДАТУ СРЕЗА, без списанных;
--   PAR30/PAR90  = доля портфеля с просрочкой строго > 30 / > 90 дней;
--   NPL          = доля портфеля с просрочкой > 90 дней ИЛИ реструктуризированных;
--   провизии     = остаток × ставка: NPL 50%, иначе 31–90 дней 10%, иначе (0–30 дней) 1%;
--   концентрация = доля 10 крупнейших групп связанных заёмщиков (group_id).

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA IF NOT EXISTS reporting;

-- 1. Курсы: убираем полные дубли строк. Уникальность (date, currency) проверяется в 03_checks.sql,
--    иначе джойн к курсам молча размножил бы кредиты.
CREATE OR REPLACE VIEW reporting.v_fx AS
SELECT DISTINCT date, currency, rate_kzt
FROM raw.fx;

-- 2. Очищенный срез по кредитам: все кредиты, включая списанные (с флагом).
--    В выгрузке 30 кредитов на каждую дату продублированы полными копиями строк —
--    убираем через DISTINCT по всей строке. Если бы дубли расходились по значениям,
--    DISTINCT их бы не схлопнул и проверка уникальности (report_date, loan_id) упала бы —
--    это сознательно: такие дубли нужно разбирать с источником, а не выбирать «любую» строку.
CREATE OR REPLACE VIEW reporting.v_loan_snapshot AS
WITH dedup AS (
    SELECT DISTINCT * FROM raw.portfolio
),
priced AS (
    SELECT
        d.*,
        -- В fx.csv нет строк для KZT: курс тенге к тенге = 1. Inner join к курсам
        -- выбросил бы все тенговые кредиты, поэтому LEFT JOIN + явная единица.
        CASE WHEN d.currency = 'KZT' THEN 1::numeric ELSE fx.rate_kzt END AS fx_rate
    FROM dedup d
    LEFT JOIN reporting.v_fx fx
           ON fx.currency = d.currency
          AND fx.date     = d.report_date      -- курс на дату среза, не на конец прошлого месяца
),
classified AS (
    SELECT
        p.*,
        p.principal_outstanding * p.fx_rate                  AS principal_kzt,
        (p.days_past_due > 30)                                AS is_par30,
        (p.days_past_due > 90)                                AS is_par90,
        (p.days_past_due > 90 OR p.restructured = 1)          AS is_npl
    FROM priced p
)
SELECT
    report_date,
    loan_id,
    borrower_id,
    group_id,
    sector,
    program,
    currency,
    issue_date,
    maturity_date,
    principal_outstanding                                     AS principal_ccy,
    fx_rate,
    principal_kzt,
    days_past_due                                             AS dpd,
    CASE
        WHEN days_past_due = 0  THEN '0'
        WHEN days_past_due <= 30 THEN '1–30'
        WHEN days_past_due <= 90 THEN '31–90'
        ELSE '91+'
    END                                                       AS dpd_bucket,
    (restructured = 1)                                        AS is_restructured,
    (written_off  = 1)                                        AS is_written_off,
    is_par30,
    is_par90,
    is_npl,
    (maturity_date < report_date)                             AS is_past_maturity,
    CASE
        WHEN is_npl                 THEN 'NPL'
        WHEN days_past_due > 30     THEN '31–90'
        ELSE '0–30'
    END                                                       AS provision_category,
    CASE
        WHEN is_npl                 THEN 0.50
        WHEN days_past_due > 30     THEN 0.10
        ELSE 0.01
    END                                                       AS provision_rate,
    principal_kzt * CASE
        WHEN is_npl                 THEN 0.50
        WHEN days_past_due > 30     THEN 0.10
        ELSE 0.01
    END                                                       AS provision_kzt,
    -- Суммовые колонки под меры семантического слоя (type: sum без фильтров).
    CASE WHEN is_par30 THEN principal_kzt ELSE 0 END          AS par30_kzt,
    CASE WHEN is_par90 THEN principal_kzt ELSE 0 END          AS par90_kzt,
    CASE WHEN is_npl   THEN principal_kzt ELSE 0 END          AS npl_kzt
FROM classified;

-- 3. Витрина портфеля: ровно то, что входит в портфель (без списанных). На неё смотрит
--    семантическая модель и все агрегаты ниже.
CREATE OR REPLACE VIEW reporting.v_portfolio AS
SELECT *
FROM reporting.v_loan_snapshot
WHERE NOT is_written_off;

-- 4. Экспозиция по группам связанных заёмщиков с рангом.
CREATE OR REPLACE VIEW reporting.v_group_exposure AS
WITH g AS (
    SELECT report_date, group_id,
           count(*)           AS loans,
           sum(principal_kzt) AS exposure_kzt
    FROM reporting.v_portfolio
    GROUP BY report_date, group_id
)
SELECT
    report_date,
    group_id,
    loans,
    exposure_kzt,
    exposure_kzt / sum(exposure_kzt) OVER (PARTITION BY report_date)          AS share,
    row_number() OVER (PARTITION BY report_date ORDER BY exposure_kzt DESC, group_id) AS rnk
FROM g;

-- 5. Ключевые метрики на каждую дату (широкий формат).
CREATE OR REPLACE VIEW reporting.v_metrics AS
WITH p AS (
    SELECT report_date,
           count(*)                 AS loans,
           sum(principal_kzt)       AS portfolio_kzt,
           sum(par30_kzt)           AS par30_kzt,
           sum(par90_kzt)           AS par90_kzt,
           sum(npl_kzt)             AS npl_kzt,
           sum(provision_kzt)       AS provisions_kzt
    FROM reporting.v_portfolio
    GROUP BY report_date
),
top10 AS (
    SELECT report_date, sum(exposure_kzt) AS top10_kzt
    FROM reporting.v_group_exposure
    WHERE rnk <= 10
    GROUP BY report_date
),
wo AS (
    SELECT report_date,
           count(*)           FILTER (WHERE is_written_off) AS written_off_loans,
           coalesce(sum(principal_kzt) FILTER (WHERE is_written_off), 0) AS written_off_kzt
    FROM reporting.v_loan_snapshot
    GROUP BY report_date
)
SELECT
    p.report_date,
    p.loans,
    p.portfolio_kzt,
    p.par30_kzt,
    p.par90_kzt,
    p.npl_kzt,
    p.provisions_kzt,
    t.top10_kzt,
    p.par30_kzt      / p.portfolio_kzt AS par30_ratio,
    p.par90_kzt      / p.portfolio_kzt AS par90_ratio,
    p.npl_kzt        / p.portfolio_kzt AS npl_ratio,
    t.top10_kzt      / p.portfolio_kzt AS top10_ratio,
    p.provisions_kzt / p.portfolio_kzt AS provisions_ratio,   -- провизии к портфелю
    p.provisions_kzt / nullif(p.npl_kzt, 0) AS npl_coverage,  -- покрытие NPL провизиями
    w.written_off_loans,
    w.written_off_kzt
FROM p
JOIN top10 t USING (report_date)
JOIN wo    w USING (report_date);

-- 6. Метрики в длинном формате с изменением к предыдущему срезу.
--    Для сумм — абсолютное и относительное изменение, для долей — в процентных пунктах.
CREATE OR REPLACE VIEW reporting.v_metrics_change AS
WITH long AS (
    SELECT m.report_date, x.metric, x.label, x.unit, x.sort_order, x.value
    FROM reporting.v_metrics m
    CROSS JOIN LATERAL (VALUES
        ('portfolio_kzt',  'Портфель',            'kzt',   1, m.portfolio_kzt),
        ('par30_ratio',    'PAR30',               'ratio', 2, m.par30_ratio),
        ('par90_ratio',    'PAR90',               'ratio', 3, m.par90_ratio),
        ('npl_ratio',      'NPL',                 'ratio', 4, m.npl_ratio),
        ('provisions_kzt', 'Провизии',            'kzt',   5, m.provisions_kzt),
        ('top10_ratio',    'Топ-10 групп',        'ratio', 6, m.top10_ratio),
        ('npl_coverage',   'Покрытие NPL',        'ratio', 7, m.npl_coverage),
        ('loans',          'Кредитов в портфеле', 'count', 8, m.loans::numeric)
    ) AS x(metric, label, unit, sort_order, value)
)
SELECT
    report_date,
    metric,
    label,
    unit,
    sort_order,
    value,
    lag(value)  OVER w                    AS prev_value,
    value - lag(value) OVER w             AS change_abs,          -- для ratio это доли: ×100 = п.п.
    CASE WHEN unit <> 'ratio'
         THEN value / nullif(lag(value) OVER w, 0) - 1
    END                                   AS change_rel
FROM long
WINDOW w AS (PARTITION BY metric ORDER BY report_date);

-- 7. Разрезы: отрасль и программа в одном представлении.
CREATE OR REPLACE VIEW reporting.v_by_dimension AS
WITH u AS (
    SELECT report_date, 'Отрасль'::text   AS dimension, sector  AS dim_value, principal_kzt, par30_kzt, par90_kzt, npl_kzt, provision_kzt
    FROM reporting.v_portfolio
    UNION ALL
    SELECT report_date, 'Программа'::text AS dimension, program AS dim_value, principal_kzt, par30_kzt, par90_kzt, npl_kzt, provision_kzt
    FROM reporting.v_portfolio
)
SELECT
    report_date,
    dimension,
    dim_value,
    count(*)                            AS loans,
    sum(principal_kzt)                  AS portfolio_kzt,
    sum(par30_kzt)                      AS par30_kzt,
    sum(npl_kzt)                        AS npl_kzt,
    sum(provision_kzt)                  AS provisions_kzt,
    sum(principal_kzt) / sum(sum(principal_kzt)) OVER (PARTITION BY report_date, dimension) AS share_of_portfolio,
    sum(par30_kzt) / sum(principal_kzt) AS par30_ratio,
    sum(par90_kzt) / sum(principal_kzt) AS par90_ratio,
    sum(npl_kzt)   / sum(principal_kzt) AS npl_ratio
FROM u
GROUP BY report_date, dimension, dim_value;

-- 8. Структура портфеля по корзинам просрочки.
CREATE OR REPLACE VIEW reporting.v_dpd_buckets AS
SELECT
    report_date,
    dpd_bucket,
    is_restructured,
    count(*)           AS loans,
    sum(principal_kzt) AS portfolio_kzt,
    sum(provision_kzt) AS provisions_kzt
FROM reporting.v_portfolio
GROUP BY report_date, dpd_bucket, is_restructured;

-- 9. Мост изменения портфеля между срезами: откуда взялась разница.
--    Валютная переоценка = остаток в валюте на новую дату × (новый курс − старый курс);
--    погашения = изменение остатка в валюте × старый курс. Сумма компонентов = изменению портфеля
--    (сверяется в 03_checks.sql).
CREATE OR REPLACE VIEW reporting.v_portfolio_bridge AS
WITH d AS (
    SELECT DISTINCT report_date FROM reporting.v_loan_snapshot
),
pairs AS (
    SELECT lag(report_date) OVER (ORDER BY report_date) AS prev_date, report_date AS curr_date
    FROM d
),
j AS (
    SELECT pr.prev_date, pr.curr_date, l.*
    FROM pairs pr
    CROSS JOIN LATERAL (
        SELECT loan_id,
               a.principal_ccy  AS ccy_prev, a.fx_rate AS fx_prev, a.principal_kzt AS kzt_prev,
               a.is_written_off AS wo_prev,
               b.principal_ccy  AS ccy_curr, b.fx_rate AS fx_curr, b.principal_kzt AS kzt_curr,
               b.is_written_off AS wo_curr
        FROM      (SELECT * FROM reporting.v_loan_snapshot WHERE report_date = pr.prev_date) a
        FULL JOIN (SELECT * FROM reporting.v_loan_snapshot WHERE report_date = pr.curr_date) b
               USING (loan_id)
    ) l
    WHERE pr.prev_date IS NOT NULL
),
parts AS (
    SELECT prev_date, curr_date, x.step, x.label, x.sort_order, x.amount
    FROM j
    CROSS JOIN LATERAL (VALUES
        ('opening',      'Портфель на начало',                      1,
             CASE WHEN wo_prev = false THEN kzt_prev ELSE 0 END),
        ('new',          'Новые кредиты',                           2,
             CASE WHEN ccy_prev IS NULL AND wo_curr = false THEN kzt_curr ELSE 0 END),
        ('repaid_out',   'Выбыли из выгрузки',                      3,
             CASE WHEN ccy_curr IS NULL AND wo_prev = false THEN -kzt_prev ELSE 0 END),
        ('written_off',  'Списаны за период',                       4,
             CASE WHEN wo_prev = false AND wo_curr = true THEN -kzt_prev ELSE 0 END),
        ('reinstated',   'Сняты с баланса списанных (аномалия)',    5,
             CASE WHEN wo_prev = true AND wo_curr = false THEN kzt_curr ELSE 0 END),
        ('amortization', 'Погашения и выдачи в валюте кредита',     6,
             CASE WHEN wo_prev = false AND wo_curr = false THEN (ccy_curr - ccy_prev) * fx_prev ELSE 0 END),
        ('fx',           'Валютная переоценка',                     7,
             CASE WHEN wo_prev = false AND wo_curr = false THEN ccy_curr * (fx_curr - fx_prev) ELSE 0 END)
    ) AS x(step, label, sort_order, amount)
)
SELECT prev_date, curr_date, step, label, sort_order, sum(amount) AS amount_kzt
FROM parts
GROUP BY prev_date, curr_date, step, label, sort_order
UNION ALL
SELECT pr.prev_date, pr.curr_date, 'closing', 'Портфель на конец', 99, m.portfolio_kzt
FROM pairs pr
JOIN reporting.v_metrics m ON m.report_date = pr.curr_date
WHERE pr.prev_date IS NOT NULL;

-- 10. Качество данных: что нашли в выгрузке и как обработали. Это не ошибки расчёта,
--     а вопросы к источнику — выносим в README и риск-комитету.
CREATE OR REPLACE VIEW reporting.v_data_quality AS
SELECT 'raw_rows' AS check_name, report_date, count(*)::numeric AS value,
       'Строк в raw.portfolio' AS description
FROM raw.portfolio GROUP BY report_date
UNION ALL
SELECT 'exact_duplicates', report_date, count(*) - count(DISTINCT (raw.portfolio.*)),
       'Полные дубли строк (удалены в витрине)'
FROM raw.portfolio GROUP BY report_date
UNION ALL
SELECT 'written_off_loans', report_date, count(*) FILTER (WHERE is_written_off),
       'Списанные кредиты (исключены из портфеля)'
FROM reporting.v_loan_snapshot GROUP BY report_date
UNION ALL
SELECT 'past_maturity_current', report_date,
       count(*) FILTER (WHERE is_past_maturity AND dpd = 0),
       'Срок погашения прошёл, но просрочка 0 дней (в портфеле, вопрос к источнику)'
FROM reporting.v_portfolio GROUP BY report_date
UNION ALL
SELECT 'reinstated_after_writeoff', b.report_date, count(*),
       'Были списаны на прошлую дату, на эту — нет (вопрос к источнику)'
FROM reporting.v_loan_snapshot a
JOIN reporting.v_loan_snapshot b
  ON b.loan_id = a.loan_id
 AND a.report_date = (SELECT max(report_date) FROM reporting.v_loan_snapshot x WHERE x.report_date < b.report_date)
WHERE a.is_written_off AND NOT b.is_written_off
GROUP BY b.report_date
UNION ALL
SELECT 'cured_from_91plus', b.report_date, count(*),
       'Просрочка 91+ на прошлую дату, 0 дней на эту, без реструктуризации (вопрос к источнику)'
FROM reporting.v_loan_snapshot a
JOIN reporting.v_loan_snapshot b
  ON b.loan_id = a.loan_id
 AND a.report_date = (SELECT max(report_date) FROM reporting.v_loan_snapshot x WHERE x.report_date < b.report_date)
WHERE NOT a.is_written_off AND NOT b.is_written_off
  AND a.dpd > 90 AND b.dpd = 0 AND NOT b.is_restructured
GROUP BY b.report_date
UNION ALL
-- Просрочка выросла на весь интервал между срезами (платежей не было), а остаток всё равно уменьшился.
-- Если таких много — principal_outstanding, вероятно, плановый остаток по графику, а не фактический долг,
-- и подтверждать «излечения» по нему нельзя.
SELECT 'balance_down_without_payment', b.report_date, count(*),
       'Просрочка выросла на весь период между срезами, а остаток уменьшился (остаток — плановый? вопрос к источнику)'
FROM reporting.v_loan_snapshot a
JOIN reporting.v_loan_snapshot b
  ON b.loan_id = a.loan_id
 AND a.report_date = (SELECT max(report_date) FROM reporting.v_loan_snapshot x WHERE x.report_date < b.report_date)
WHERE NOT a.is_written_off AND NOT b.is_written_off
  AND a.dpd > 0
  AND b.dpd - a.dpd >= (b.report_date - a.report_date)
  AND b.principal_ccy < a.principal_ccy
GROUP BY b.report_date;
