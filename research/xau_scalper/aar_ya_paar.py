"""All-or-nothing ("aar ya paar") geometry test for a $10 gold account, on 2011-2018 Dukascopy tick data.

With $10 and gold's 0.01 minimum lot (1 oz = $1 per $1 move), risking 90% means a $9 stop, which is about 0.22% of
today's ~$4,000 gold. Each trial opens one trade at a fixed UTC hour with the stop at stop_pct of price and the
target at rr x stop, then follows 10 s bid/ask bars until one is hit. The spread is scaled to today's cost
($0.20 on a $9 stop = 2.2% of the stop). Swap is not charged.

    python aar_ya_paar.py
"""
import os
import sys

import numba as nb
import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import backtest as bt  # noqa: E402

SPREAD_OF_STOP = 0.2 / 9.0


@nb.njit(cache=True)
def trial(t, bh, bl, ah, al, start, side, stop_pct, rr, max_sec):
    """1 = target first, 0 = stop first (or time limit with a loss), plus seconds to resolution."""
    mid0 = 0.5 * (bh[start] + al[start] + bl[start] + ah[start]) * 0.5
    stop = stop_pct * mid0
    half = 0.5 * SPREAD_OF_STOP * stop
    entry = mid0 + side * half
    sl = entry - side * stop
    tp = entry + side * rr * stop
    for x in range(start + 1, len(t)):
        if t[x] - t[start] > max_sec:
            return 0, t[x] - t[start]
        hi = 0.5 * (bh[x] + ah[x]) - side * half      # exit side of the book
        lo = 0.5 * (bl[x] + al[x]) - side * half
        if side > 0:
            if lo <= sl:
                return 0, t[x] - t[start]
            if hi >= tp:
                return 1, t[x] - t[start]
        else:
            if hi >= sl:
                return 0, t[x] - t[start]
            if lo <= tp:
                return 1, t[x] - t[start]
    return -1, 0


def daily_trend(d):
    day = pd.to_datetime(d["t"], unit="s").normalize()
    close = pd.Series(d["bc"]).groupby(day.values).last()
    e20, e50 = close.ewm(span=20, adjust=False).mean(), close.ewm(span=50, adjust=False).mean()
    trend = np.where((close > e50) & (e20 > e50), 1, np.where((close < e50) & (e20 < e50), -1, 0))
    return pd.Series(trend, index=close.index).shift(1)            # yesterday's close decides today


def run(d, starts_by_day, trend, rule, stop_pct, rr, max_days=30, seed=1):
    rng = np.random.default_rng(seed)
    wins = n = 0
    secs = []
    for day, start in starts_by_day.items():
        tr = trend.get(day, np.nan)
        if np.isnan(tr):
            continue
        side = {"long": 1, "short": -1, "random": rng.choice([-1, 1]), "trend": int(tr)}[rule]
        if side == 0:
            continue
        w, s = trial(d["t"], d["bh"], d["bl"], d["ah"], d["al"], start, side, stop_pct, rr, max_days * 86400)
        if w < 0:
            continue
        wins += w
        n += 1
        secs.append(s)
    return wins / n, n, np.median(secs) / 86400


def main():
    d = bt.load_10s()
    ts = pd.to_datetime(d["t"], unit="s")
    trend = daily_trend(d)
    for hour in (7, 13):
        idx = np.flatnonzero((ts.hour == hour) & (ts.minute == 0) & (ts.dayofweek < 5))
        first = pd.Series(idx, index=ts[idx].normalize()).groupby(level=0).first()
        print(f"\nentry {hour:02d}:00 UTC, stop 0.22% of price (= $9 on $4,000 gold), driftless odds ~ (1 - 0.022) / (1 + RR)")
        for rr in (10.0, 3.16, 1.27):
            row = []
            for rule in ("trend", "long", "short", "random"):
                p, n, days = run(d, first.to_dict(), trend, rule, 0.0022, rr)
                row.append(f"{rule} {100 * p:5.1f}%")
            steps = {10.0: 1, 3.16: 2, 1.27: 3}[rr]
            print(f"  RR {rr:5.2f} ({steps} win{'s' if steps > 1 else ''} needed): " + "  ".join(row) +
                  f"   | n={n}, median {days:.1f} days to resolve")
    idx = np.flatnonzero((ts.hour == 7) & (ts.minute == 0) & (ts.dayofweek < 5))
    first = pd.Series(idx, index=ts[idx].normalize()).groupby(level=0).first().to_dict()
    print("\nsmaller stop (2 x 0.01 lot = 0.11% of price), RR 10, trend rule:",
          f"{100 * run(d, first, trend, 'trend', 0.0011, 10.0)[0]:.1f}%")


if __name__ == "__main__":
    main()
