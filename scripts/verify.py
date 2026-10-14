"""Независимый пересчёт ключевых метрик прямо из CSV (pandas, без SQL) и сверка с витриной.

Зачем: SQL и этот скрипт написаны отдельно и по-разному (джойн к курсам через map, дубли через
drop_duplicates, провизии через np.select). Если обе реализации дают одни и те же цифры до тиына —
ошибка в понимании определений маловероятна; если расходятся — ищем причину, а не подгоняем.

    python3 scripts/verify.py            # сравнивает с dashboard/data/metrics.json (выгружает run.sh)
"""
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
TOL = 0.01  # тенге

p = pd.read_csv(ROOT / "data/portfolio.csv", parse_dates=["report_date"])
fx = pd.read_csv(ROOT / "data/fx.csv", parse_dates=["date"])

p = p.drop_duplicates()
assert not p.duplicated(["report_date", "loan_id"]).any(), "расходящиеся дубли кредитов"

rates = fx.set_index(["date", "currency"])["rate_kzt"]
assert rates.index.is_unique, "курсы не уникальны по (date, currency)"
p["rate"] = [1.0 if c == "KZT" else rates.get((d, c), np.nan)
             for d, c in zip(p.report_date, p.currency)]
assert p.rate.notna().all(), "нет курса на дату среза"
p["kzt"] = p.principal_outstanding * p.rate

pf = p[p.written_off == 0].copy()
dpd = pf.days_past_due
npl = (dpd > 90) | (pf.restructured == 1)
pf["prov"] = pf.kzt * np.select([npl, dpd > 30], [0.50, 0.10], default=0.01)

rows = []
for d, g in pf.groupby("report_date"):
    tot = g.kzt.sum()
    grp = g.groupby("group_id").kzt.sum().nlargest(10).sum()
    gd, gn = g.days_past_due, (g.days_past_due > 90) | (g.restructured == 1)
    rows.append(dict(
        report_date=d.date().isoformat(),
        loans=len(g),
        portfolio_kzt=tot,
        par30_ratio=g.kzt[gd > 30].sum() / tot,
        par90_ratio=g.kzt[gd > 90].sum() / tot,
        npl_ratio=g.kzt[gn].sum() / tot,
        provisions_kzt=g.prov.sum(),
        top10_ratio=grp / tot,
    ))
py = pd.DataFrame(rows).set_index("report_date")

sql = pd.DataFrame(json.loads((ROOT / "dashboard/data/metrics.json").read_text()))
sql = sql.set_index("report_date")[py.columns].astype(float)

ok = True
print(f"{'метрика':<16}{'дата':<12}{'pandas':>22}{'SQL':>22}{'разница':>12}")
for d in py.index:
    for c in py.columns:
        a, b = float(py.loc[d, c]), float(sql.loc[d, c])
        tol = TOL if c.endswith("_kzt") else 1e-12 if c.endswith("_ratio") else 0
        bad = abs(a - b) > tol
        ok &= not bad
        print(f"{c:<16}{d:<12}{a:>22,.4f}{b:>22,.4f}{a - b:>12.2e}{'  ✗' if bad else ''}")

print("\n✓ pandas и SQL совпадают" if ok else "\n✗ ЕСТЬ РАСХОЖДЕНИЯ")
sys.exit(0 if ok else 1)
