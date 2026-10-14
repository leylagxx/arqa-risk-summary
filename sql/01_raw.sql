-- 01_raw.sql — сырой слой: таблицы 1:1 с CSV, без очистки.
-- Идемпотентно: схема и таблицы создаются только если их нет, данные перезаливаются целиком.
-- Запускать из корня репозитория (пути в \copy — относительно текущей папки клиента psql).

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA IF NOT EXISTS raw;

CREATE TABLE IF NOT EXISTS raw.portfolio (
    report_date           date           NOT NULL,
    loan_id               text           NOT NULL,
    borrower_id           text           NOT NULL,
    group_id              text           NOT NULL,
    sector                text           NOT NULL,
    program               text           NOT NULL,
    currency              text           NOT NULL,
    issue_date            date,
    maturity_date         date,
    principal_outstanding numeric(20, 2) NOT NULL,  -- в валюте кредита
    days_past_due         integer        NOT NULL,
    restructured          smallint       NOT NULL,
    written_off           smallint       NOT NULL
);

CREATE TABLE IF NOT EXISTS raw.fx (
    date      date           NOT NULL,
    currency  text           NOT NULL,
    rate_kzt  numeric(18, 4) NOT NULL   -- тенге за 1 единицу валюты
);

-- Сырой слой намеренно без PK/UNIQUE: дубли из выгрузки должны доехать до raw,
-- чтобы их было видно и чтобы их явно обработала витрина (см. 02_reporting.sql).

BEGIN;
TRUNCATE raw.portfolio, raw.fx;
\copy raw.portfolio FROM 'data/portfolio.csv' WITH (FORMAT csv, HEADER true)
\copy raw.fx        FROM 'data/fx.csv'        WITH (FORMAT csv, HEADER true)
COMMIT;
