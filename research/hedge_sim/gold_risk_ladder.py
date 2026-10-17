"""Risk ladder for the README:  XAUUSD_ZIP=path/to/xauusd.zip python gold_risk_ladder.py

Same Gold 2.1 logic at higher and higher risk per daily ATR, with a 1.5% and a 4.5% daily target.
Risk 50% per ATR is what a fixed 0.01 lot means on a $100 Standard account at a ~$50 daily gold ATR.
"""
from multiprocessing import Pool

import pandas as pd

from gold import GOLD, gold, mirrored, random_walk, split
from gold_tests import GOLD_SAFE
from sim import Engine, indicators, report
from strategies import V3

G = gold()
IS, OOS = split(G)
SETS = {"2006-19": G, "2006-19 mirrored": mirrored(G), "2013-19": OOS}
for k in range(3):
    SETS[f"random walk {k}"] = random_walk(OOS, k)
RISKS = [0.5, 1.0, 2.0, 3.0, 5.0, 8.0, 50.0]
TARGETS = [1.5, 4.5]


def job(args):
    risk, target, name = args
    strat = V3(**dict(GOLD_SAFE, risk_atr_pct=risk, target=target))
    df = SETS[name]
    eng = Engine(df, strat, balance=10_000.0, **GOLD).run(indicators(df))
    r = report(name, eng, strat)
    curve = eng.curve
    below = curve[curve <= 1_000.0]
    days = max(len(strat.days), 1)
    r.update(risk=risk, target=target,
             avg_daily_pct=round(((max(curve.iloc[-1], 1e-9) / 10_000.0) ** (1 / days) - 1) * 100, 3),
             days_to_minus90=(below.index[0] - curve.index[0]).days if len(below) else None,
             target_hit_pct_days=round(100 * strat.target_days / days, 1))
    return r


if __name__ == "__main__":
    pd.set_option("display.width", 200)
    with Pool() as p:
        rows = p.map(job, [(r, t, n) for r in RISKS for t in TARGETS for n in SETS])
    cols = ["risk", "target", "name", "ret_%", "avg_daily_pct", "maxDD_%", "target_hit_pct_days",
            "hard_stops", "days_to_minus90"]
    print(pd.DataFrame(rows)[cols].to_string(index=False))
