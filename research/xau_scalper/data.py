"""Build 10-second bid/ask bars for XAUUSD from Dukascopy tick data mirrored on GitHub.

Source: https://github.com/FX-Data/FX-Data-XAUUSD-DS (one branch per year, XAUUSD-2011 ... XAUUSD-2018,
May 2011 - mid June 2018). Each file holds one hour of ticks: "time,bid,ask,bid_vol,ask_vol" in UTC.
UTC is also the Exness MT5 server time (GMT+0, no DST), so hours here are server hours.

    python data.py 2014 2015 ...      # writes data/xau_10s_<year>.npz, then deletes the raw clone

Each npz holds t (int64 epoch seconds, start of the 10 s bucket), bo/bh/bl/bc and ao/ah/al/ac (float32),
and n (ticks in the bucket). The raw files quote gold divided by 100 (13.12 = $1312); prices are rescaled.
"""
import glob
import os
import shutil
import subprocess
import sys

import numpy as np
import pandas as pd

URL = "https://github.com/FX-Data/FX-Data-XAUUSD-DS"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("XAU_DATA", os.path.join(HERE, "data"))
BUCKET = 10


def clone(year, work):
    dst = os.path.join(work, f"raw{year}")
    if not os.path.isdir(dst):
        subprocess.run(["git", "clone", "-q", "--depth", "1", "--single-branch", "-b", f"XAUUSD-{year}", URL, dst],
                       check=True)
    return dst


def hour_bars(path):
    df = pd.read_csv(path, header=None, names=["t", "p1", "p2", "v1", "v2"], usecols=[0, 1, 2])
    if df.empty:
        return None
    t = pd.to_datetime(df.t, format="%Y.%m.%d %H:%M:%S.%f").values.astype("datetime64[s]").astype(np.int64)
    p1, p2 = df.p1.values, df.p2.values
    bid, ask = (p1, p2) if np.median(p2 - p1) >= 0 else (p2, p1)
    scale = 100.0 if np.median(bid) < 100 else 1.0
    bid, ask = bid * scale, ask * scale
    ok = (bid > 0) & (ask >= bid)
    t, bid, ask = t[ok], bid[ok], ask[ok]
    if len(t) == 0:
        return None
    b = t // BUCKET * BUCKET
    g = pd.DataFrame({"b": b, "bid": bid, "ask": ask}).groupby("b", sort=True)
    a = g.agg(bo=("bid", "first"), bh=("bid", "max"), bl=("bid", "min"), bc=("bid", "last"),
              ao=("ask", "first"), ah=("ask", "max"), al=("ask", "min"), ac=("ask", "last"), n=("bid", "size"))
    a.index.name = "t"
    return a


def build(year, work):
    out = os.path.join(OUT, f"xau_10s_{year}.npz")
    if os.path.exists(out):
        print(year, "exists")
        return
    raw = clone(year, work)
    files = sorted(glob.glob(os.path.join(raw, "XAUUSD", str(year), "*", "*_ticks.csv")))
    parts = [p for p in (hour_bars(f) for f in files) if p is not None]
    a = pd.concat(parts).sort_index()
    a = a[~a.index.duplicated(keep="first")]
    os.makedirs(OUT, exist_ok=True)
    np.savez_compressed(out, t=a.index.values.astype(np.int64),
                        **{c: a[c].values.astype(np.float32) for c in ["bo", "bh", "bl", "bc", "ao", "ah", "al", "ac"]},
                        n=a["n"].values.astype(np.int32))
    print(year, len(files), "hour files ->", len(a), "10 s bars", out)
    shutil.rmtree(raw)


if __name__ == "__main__":
    work = os.environ.get("XAU_WORK", OUT)
    os.makedirs(work, exist_ok=True)
    for y in sys.argv[1:]:
        build(int(y), work)
