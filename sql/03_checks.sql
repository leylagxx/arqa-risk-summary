-- 03_checks.sql — сверки. Любая ошибка останавливает запуск (RAISE EXCEPTION).
-- Это не тесты «ради галочки»: каждая проверка ловит конкретный способ получить неверную цифру.

\set ON_ERROR_STOP on

DO $$
DECLARE
    n        bigint;
    diff     numeric;
    tol      constant numeric := 0.01;  -- допуск 1 тиын на округления numeric
BEGIN
    -- 1. Курсы уникальны по (date, currency) — иначе джойн размножит кредиты.
    SELECT count(*) INTO n FROM (
        SELECT date, currency FROM reporting.v_fx GROUP BY 1, 2 HAVING count(*) > 1) t;
    IF n > 0 THEN RAISE EXCEPTION 'v_fx: % пар (date, currency) с разными курсами', n; END IF;

    -- 2. В витрине один кредит = одна строка на дату (полные дубли убраны, расходящихся нет).
    SELECT count(*) INTO n FROM (
        SELECT report_date, loan_id FROM reporting.v_loan_snapshot GROUP BY 1, 2 HAVING count(*) > 1) t;
    IF n > 0 THEN RAISE EXCEPTION 'v_loan_snapshot: % ключей (report_date, loan_id) с расходящимися дублями', n; END IF;

    -- 3. Ни одна строка не потерялась и не размножилась при джойне к курсам.
    SELECT abs((SELECT count(*) FROM (SELECT DISTINCT * FROM raw.portfolio) d)
             - (SELECT count(*) FROM reporting.v_loan_snapshot)) INTO n;
    IF n <> 0 THEN RAISE EXCEPTION 'v_loan_snapshot: число строк не совпадает с raw без дублей (разница %)', n; END IF;

    -- 4. У каждого кредита есть курс (нет валютных кредитов без курса на дату среза).
    SELECT count(*) INTO n FROM reporting.v_loan_snapshot WHERE fx_rate IS NULL;
    IF n > 0 THEN RAISE EXCEPTION 'v_loan_snapshot: % строк без курса на дату среза', n; END IF;

    -- 5. Сумма в валюте по витрине сходится с raw без дублей, по каждой дате и валюте.
    SELECT coalesce(max(abs(r.s - v.s)), 0) INTO diff
    FROM (SELECT report_date, currency, sum(principal_outstanding) s
          FROM (SELECT DISTINCT * FROM raw.portfolio) d GROUP BY 1, 2) r
    FULL JOIN (SELECT report_date, currency, sum(principal_ccy) s
               FROM reporting.v_loan_snapshot GROUP BY 1, 2) v USING (report_date, currency);
    IF diff IS NULL OR diff > tol THEN RAISE EXCEPTION 'Суммы в валюте не сходятся с raw: %', diff; END IF;

    -- 6. Разрезы по отрасли и по программе в сумме дают портфель.
    SELECT max(abs(d.s - m.portfolio_kzt)) INTO diff
    FROM (SELECT report_date, dimension, sum(portfolio_kzt) s FROM reporting.v_by_dimension GROUP BY 1, 2) d
    JOIN reporting.v_metrics m USING (report_date);
    IF diff > tol THEN RAISE EXCEPTION 'Разрезы не сходятся с портфелем: %', diff; END IF;

    -- 7. Логическая вложенность: PAR90 ⊆ PAR30, PAR90 ⊆ NPL; провизии в границах 1%..50% портфеля.
    SELECT count(*) INTO n FROM reporting.v_metrics
    WHERE NOT (par90_kzt <= par30_kzt AND par90_kzt <= npl_kzt
               AND provisions_kzt BETWEEN 0.01 * portfolio_kzt AND 0.50 * portfolio_kzt);
    IF n > 0 THEN RAISE EXCEPTION 'Нарушена вложенность PAR/NPL или границы провизий'; END IF;

    -- 8. Провизии = Σ по категориям × ставка (пересчёт другим путём, от корзин).
    SELECT max(abs(m.provisions_kzt - c.p)) INTO diff
    FROM reporting.v_metrics m
    JOIN (SELECT report_date,
                 sum(CASE provision_category WHEN 'NPL' THEN 0.50 WHEN '31–90' THEN 0.10 ELSE 0.01 END
                     * principal_kzt) p
          FROM reporting.v_portfolio GROUP BY 1) c USING (report_date);
    IF diff > tol THEN RAISE EXCEPTION 'Провизии не сходятся с пересчётом по категориям: %', diff; END IF;

    -- 9. Мост: начало + компоненты = конец.
    SELECT max(abs(o.s - c.amount_kzt)) INTO diff
    FROM (SELECT curr_date, sum(amount_kzt) s FROM reporting.v_portfolio_bridge
          WHERE step <> 'closing' GROUP BY 1) o
    JOIN reporting.v_portfolio_bridge c ON c.curr_date = o.curr_date AND c.step = 'closing';
    IF diff > tol THEN RAISE EXCEPTION 'Мост портфеля не сходится: %', diff; END IF;

    -- 10. Топ-10 — это именно 10 групп и доля не больше 100%.
    SELECT count(*) INTO n FROM (
        SELECT report_date FROM reporting.v_group_exposure WHERE rnk <= 10
        GROUP BY 1 HAVING count(*) <> 10) t;
    IF n > 0 THEN RAISE EXCEPTION 'В топ-10 не 10 групп'; END IF;

    RAISE NOTICE 'Все проверки пройдены';
END $$;

-- Предупреждения по качеству данных (не останавливают запуск, но попадают в отчёт).
SELECT check_name, report_date, value, description
FROM reporting.v_data_quality
ORDER BY check_name, report_date;
