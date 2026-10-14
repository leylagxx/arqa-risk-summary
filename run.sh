#!/usr/bin/env bash
# Полный прогон: raw → reporting → проверки → выгрузка данных для дашборда.
# Повторный запуск безопасен (всё идемпотентно).
#
#   docker compose up -d          # или любой локальный PostgreSQL 16
#   ./run.sh
#
# Подключение берётся из DATABASE_URL (по умолчанию — контейнер из docker-compose.yml).
set -euo pipefail
cd "$(dirname "$0")"

DB="${DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/arqa}"
PSQL=(psql "$DB" -X -q -v ON_ERROR_STOP=1)

echo "→ raw: загрузка CSV"
"${PSQL[@]}" -f sql/01_raw.sql

echo "→ reporting: витрина и метрики"
"${PSQL[@]}" -f sql/02_reporting.sql

echo "→ проверки"
"${PSQL[@]}" -f sql/03_checks.sql

echo "→ выгрузка данных для дашборда"
mkdir -p dashboard/data
export_view () {   # $1 — имя файла, $2 — запрос
  "${PSQL[@]}" -A -t -c "SELECT coalesce(json_agg(t), '[]'::json) FROM ($2) t" > "dashboard/data/$1.json"
}
export_view metrics        "SELECT * FROM reporting.v_metrics ORDER BY report_date"
export_view metrics_change "SELECT * FROM reporting.v_metrics_change ORDER BY sort_order, report_date"
export_view by_dimension   "SELECT * FROM reporting.v_by_dimension ORDER BY dimension, dim_value, report_date"
export_view dpd_buckets    "SELECT * FROM reporting.v_dpd_buckets ORDER BY report_date, dpd_bucket"
export_view top_groups     "SELECT * FROM reporting.v_group_exposure WHERE rnk <= 10 ORDER BY report_date, rnk"
export_view bridge         "SELECT * FROM reporting.v_portfolio_bridge ORDER BY curr_date, sort_order"
export_view data_quality   "SELECT * FROM reporting.v_data_quality ORDER BY check_name, report_date"

echo "✓ данные выгружены. Дашборд: python3 -m http.server 8000 -d dashboard  →  http://localhost:8000"

echo "→ сверка: независимый пересчёт в pandas и проверка YAML-моделей"
python3 scripts/verify.py
python3 scripts/check_semantic.py
