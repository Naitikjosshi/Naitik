"""Reproduce the XAUUSD results in the README:  XAUUSD_ZIP=path/to/xauusd.zip python gold_tests.py"""
from multiprocessing import Pool

import pandas as pd

from gold import gold, mirrored, random_walk, run_gold, split
from strategies import V1, V3

G = gold()
IS, OOS = split(G)
SETS = {"2006-12 bull": IS, "2013-19 bear+range": OOS, "2006-19 full": G, "2006-19 mirrored": mirrored(G)}
for k in range(3):
    SETS[f"random walk {k}"] = random_walk(OOS, k)

# Same logic and defaults as MQL5/Experts/HedgeDailyGold.mq5
GOLD_SAFE = dict(use_lock=True, lock_dd=10.0, hard_stop=30.0, start_filter="range", smart_add=True,
                 block_trend=True, expansion=1.3, min_grid_pips=100, min_tp_pips=75, atr_source="d1",
                 grid_atr=1.5, tp_atr=1.5, basket_atr=0.75, max_levels=4, risk_atr_pct=0.5,
                 bias_source="d1", one_grid=True, dd_mode="peak")
VARIANTS = {
    "v1 (HedgeDailyEA)": None,
    "v2 EURUSD settings": dict(tp_atr=2.0, grid_atr=2.0, basket_atr=1.0, risk_atr_pct=0.45, max_levels=4,
                               hard_stop=30.0, use_lock=True, start_filter="range",
                               min_grid_pips=100, min_tp_pips=75),
    "Gold 2.1 risk 0.5": GOLD_SAFE,
    "Gold 2.1 risk 1.0": dict(GOLD_SAFE, risk_atr_pct=1.0),
}


def job(args):
    variant, name, swap = args
    cfg = VARIANTS[variant]
    strat = V1(point=0.01) if cfg is None else V3(**cfg)
    r = run_gold(name + (" +swap" if swap else ""), SETS[name], strat, swap=swap)
    r["variant"] = variant
    return r


if __name__ == "__main__":
    pd.set_option("display.width", 200)
    jobs = [(v, n, False) for v in VARIANTS for n in SETS]
    jobs += [(v, "2006-19 full", True) for v in ("Gold 2.1 risk 0.5", "Gold 2.1 risk 1.0")]
    with Pool() as p:
        rows = p.map(job, jobs)
    cols = ["variant", "name", "ret_%", "maxDD_%", "target_days", "hard_stops", "locks", "trades", "blown"]
    print(pd.DataFrame(rows)[cols].to_string(index=False))
