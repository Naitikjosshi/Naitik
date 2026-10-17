"""Reproduce the v1 vs v2 comparison from the README.

    pip install backtesting pandas numpy
    python run_tests.py

Data: EURUSD H1, Apr 2017 - Feb 2018 (sample bundled with the `backtesting` package).
Datasets: the real series, the same series mirrored into a downtrend (with swap costs),
and 6 random walks built from the real bars with random direction (no trend, no edge).
"""
from multiprocessing import Pool

import numpy as np
import pandas as pd

from sim import Engine, indicators, report
from strategies import V1, V3

V2_SETTINGS = dict(tp_atr=2.0, grid_atr=2.0, basket_atr=1.0, lot_per_100=0.0035, max_levels=4,
                   hard_stop=30.0, use_lock=True, start_filter="range")
SWAP = {"mirror_down": (-0.6, -0.2)}  # long/short swap in pips per lot per night


def real():
    from backtesting.test import EURUSD
    return EURUSD[["Open", "High", "Low", "Close"]].copy()


def mirrored(df):
    p0 = df.Close.iloc[0]
    return pd.DataFrame({"Open": 2 * p0 - df.Open, "High": 2 * p0 - df.Low,
                         "Low": 2 * p0 - df.High, "Close": 2 * p0 - df.Close}, index=df.index)


def random_walk(df, seed):
    rng = np.random.default_rng(seed)
    pc = df.Close.shift(1).fillna(df.Open)
    rel = np.column_stack([df.Open - pc, df.High - df.Open, df.Low - df.Open, df.Close - df.Open])
    out = np.zeros((len(df), 4))
    close = df.Close.iloc[0]
    for i, (gap, h, l, c) in enumerate(rel):
        s = rng.choice([-1.0, 1.0])
        o = close + s * gap
        out[i] = (o, o + h, o + l, o + c) if s > 0 else (o, o - l, o - h, o - c)
        close = out[i][3]
    return pd.DataFrame(out, index=df.index, columns=["Open", "High", "Low", "Close"])


def datasets():
    d = real()
    sets = {"real_up": d, "mirror_down": mirrored(d)}
    for k in range(6):
        sets[f"rw{k}"] = random_walk(d, k)
    return sets


SETS = datasets()


def job(args):
    variant, name = args
    strat = V1() if variant == "v1" else V3(**V2_SETTINGS)
    df = SETS[name]
    sw = SWAP.get(name, (0.0, 0.0))
    eng = Engine(df, strat, balance=10_000.0, spread_pips=1.0, swap_long=sw[0], swap_short=sw[1])
    r = report(name, eng.run(indicators(df)), strat)
    r["variant"] = variant
    return r


if __name__ == "__main__":
    pd.set_option("display.width", 200)
    with Pool() as p:
        rows = p.map(job, [(v, n) for v in ("v1", "v2") for n in SETS])
    cols = ["variant", "name", "ret_%", "maxDD_%", "target_days", "hard_stops", "locks", "trades", "blown"]
    print(pd.DataFrame(rows)[cols].to_string(index=False))
