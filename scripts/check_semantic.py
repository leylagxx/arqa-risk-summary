"""Проверка семантических моделей против базы: источник существует, колонки есть,
типы мер допустимы, sum/avg стоят только на числовых колонках, имена уникальны.

    python3 scripts/check_semantic.py   # DATABASE_URL по умолчанию — как в run.sh
"""
import os
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
DB = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/arqa")
NUMERIC = {"numeric", "integer", "bigint", "smallint", "double precision", "real"}


def columns(source: str) -> dict:
    schema, table = source.split(".")
    out = subprocess.run(
        ["psql", DB, "-XAt", "-F", "\t", "-c",
         "SELECT column_name, data_type FROM information_schema.columns "
         f"WHERE table_schema = '{schema}' AND table_name = '{table}'"],
        check=True, capture_output=True, text=True).stdout
    return dict(line.split("\t") for line in out.splitlines() if line)


errors = []
for f in sorted((ROOT / "semantic").glob("*.yml")):
    m = yaml.safe_load(f.read_text())
    where = f.name
    cols = columns(m["source"])
    if not cols:
        errors.append(f"{where}: источник {m['source']} не найден")
        continue
    names = [d["name"] for d in m.get("dimensions", [])] + [x["name"] for x in m.get("measures", [])]
    dup = {n for n in names if names.count(n) > 1}
    if dup:
        errors.append(f"{where}: повторяются имена {sorted(dup)}")
    for d in m.get("dimensions", []):
        if d["column"] not in cols:
            errors.append(f"{where}: измерение {d['name']} → нет колонки {d['column']}")
    for x in m.get("measures", []):
        if x["type"] not in {"sum", "avg", "count"}:
            errors.append(f"{where}: мера {x['name']} — недопустимый тип {x['type']}")
        if x["column"] not in cols:
            errors.append(f"{where}: мера {x['name']} → нет колонки {x['column']}")
        elif x["type"] in {"sum", "avg"} and cols[x["column"]] not in NUMERIC:
            errors.append(f"{where}: мера {x['name']} ({x['type']}) на нечисловой колонке {x['column']}")
    print(f"{where}: {m['model']} ← {m['source']}, "
          f"{len(m.get('dimensions', []))} измерений, {len(m.get('measures', []))} мер")

if errors:
    print("\n".join(["", "✗ Ошибки:"] + errors))
    sys.exit(1)
print("✓ семантические модели согласованы с витриной")
