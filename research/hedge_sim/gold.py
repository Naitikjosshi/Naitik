"""XAUUSD helpers for the gold simulations (data: QuantConnect Lean sample data, Oanda XAUUSD H1 2006-2019).

Get the data file (about 2 MB) without cloning all of Lean:

    git clone --depth 1 --filter=blob:none --sparse https://github.com/QuantConnect/Lean
    cd Lean && git sparse-checkout set --no-cone /Data/cfd/oanda/hour/xauusd.zip

then point XAUUSD_ZIP at Lean/Data/cfd/oanda/hour/xauusd.zip (default: ./xauusd.zip).
"""
import io
import os
import zipfile

import numpy as np
import pandas as pd

from sim import Engine, indicators, report

GOLD = dict(contract=100.0, pip=0.01, tick_pips=30)   # 1 lot = 100 oz, ticks every $0.30
SWAP_COST = (-3.0, -1.0)                                # annual % of notional, long / short


def gold(path=None):
    """Bid OHLC plus the bar's closing spread (ask - bid), UTC hours (= Exness server time)."""
    path = path or os.environ.get("XAUUSD_ZIP", "xauusd.zip")
    z = zipfile.ZipFile(path)
    raw = pd.read_csv(io.BytesIO(z.read(z.namelist()[0])), header=None,
                      names=["t", "bo", "bh", "bl", "bc", "bs", "ao", "ah", "al", "ac", "as"])
    raw.index = pd.to_datetime(raw.pop("t"), format="%Y%m%d %H:%M")
    return pd.DataFrame({"Open": raw.bo, "High": raw.bh, "Low": raw.bl, "Close": raw.bc,
                         "Spread": raw.ac - raw.bc})


def split(df):
    return df.loc[:"2012-12-31"], df.loc["2013-01-01":]


def mirrored(df):
    p0 = df.Close.iloc[0]
    m = pd.DataFrame({"Open": 2 * p0 - df.Open, "High": 2 * p0 - df.Low,
                      "Low": 2 * p0 - df.High, "Close": 2 * p0 - df.Close}, index=df.index)
    m["Spread"] = df.Spread
    return m


def random_walk(df, seed):
    """Real bar shapes and spreads, random direction per bar: no trend, no edge."""
    rng = np.random.default_rng(seed)
    pc = df.Close.shift(1).fillna(df.Open)
    rel = np.column_stack([(df.Open - pc) / pc, (df.High - df.Open) / df.Open,
                           (df.Low - df.Open) / df.Open, (df.Close - df.Open) / df.Open])
    out = np.zeros((len(df), 4))
    close = df.Close.iloc[0]
    for i, (gap, h, l, c) in enumerate(rel):
        s = 1.0 if rng.random() < 0.5 else -1.0
        o = close * (1 + s * gap)
        out[i] = (o, o * (1 + h), o * (1 + l), o * (1 + c)) if s > 0 else (o, o * (1 - l), o * (1 - h), o * (1 - c))
        close = out[i][3]
    rw = pd.DataFrame(out, index=df.index, columns=["Open", "High", "Low", "Close"])
    rw["Spread"] = df.Spread.values / df.Close.values * rw.Close.values
    return rw


def run_gold(name, df, strat, swap=False, balance=10_000.0):
    eng = Engine(df, strat, balance=balance, swap_pct=SWAP_COST if swap else None, **GOLD)
    return report(name, eng.run(indicators(df)), strat)
