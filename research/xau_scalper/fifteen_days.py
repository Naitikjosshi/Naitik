"""$10 -> $50 or $100 in 15 days with up to 4 trades a day: which settings give the best chance?
Tested on 2011-2018 gold ticks (10 s bid/ask bars), money in today's dollars ($4,000 gold, $0.20 spread).

Each run starts with $10 on one day and trades the next 15 calendar days. Entries at 07, 09, 11 and 13 UTC
(when flat) in the daily-trend direction. Each trade: stop = S dollars per oz, target = RR x S, lots grow with
equity (risk = f % of equity, at least 0.01 lot while that risks <= 90%). Stops at the target, at bust, or on day 15.

    python fifteen_days.py
"""
import os
import sys

import numba as nb
import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aar_ya_paar as ayp  # noqa: E402
import backtest as bt  # noqa: E402

TODAY = 4000.0
SPREAD = 0.20
SLOTS = (7, 9, 11, 13)


@nb.njit(cache=True)
def one_run(t, bh, bl, ah, al, slot_idx, slot_side, slot_day, j0, stop, rr, f, target, days):
    eq = 10.0
    j = j0
    end_day = slot_day[j0] + days
    trades = 0
    while j < len(slot_idx) and slot_day[j] < end_day:
        side = slot_side[j]
        if side == 0:
            j += 1
            continue
        lots = np.floor(eq * f / 100.0 / ((stop + 0.05) * 100.0) / 0.01 + 1e-7) * 0.01
        if lots < 0.01:
            if (stop + 0.05) * 1.0 <= 0.9 * eq:
                lots = 0.01
            else:
                return 0, eq, trades                          # cannot afford a minimum-lot stop: bust
        s = slot_idx[j]
        mid = 0.25 * (bh[s] + bl[s] + ah[s] + al[s])
        scale = TODAY / mid
        entry = mid * scale + side * SPREAD / 2
        sl = entry - side * stop
        tp = entry + side * rr * stop
        x = s
        pnl = 0.0
        limit = t[s] + (end_day - slot_day[j]) * 86400
        while x + 1 < len(t):
            x += 1
            hi = 0.5 * (bh[x] + ah[x]) * scale - side * SPREAD / 2
            lo = 0.5 * (bl[x] + al[x]) * scale - side * SPREAD / 2
            if (side > 0 and lo <= sl) or (side < 0 and hi >= sl):
                pnl = -(stop + 0.05)
                break
            if (side > 0 and hi >= tp) or (side < 0 and lo <= tp):
                pnl = rr * stop
                break
            if t[x] >= limit:                                  # day 15: close at market
                pnl = side * ((hi + lo) / 2 - entry)
                break
        eq += pnl * lots * 100.0
        trades += 1
        if eq >= target:
            return 1, eq, trades
        while j < len(slot_idx) and slot_idx[j] <= x:
            j += 1
    return 0, eq, trades


def main():
    d = bt.load_10s()
    ts = pd.to_datetime(d["t"], unit="s")
    trend = ayp.daily_trend(d)
    keep = np.isin(ts.hour, SLOTS) & (ts.minute == 0) & (ts.second < 10) & (ts.dayofweek < 5)
    idx = np.flatnonzero(keep)
    key = ts[idx].floor("h")
    first = pd.Series(idx, index=key).groupby(level=0).first()
    days = first.index.normalize()
    side = np.array([0 if np.isnan(v) else int(v) for v in trend.reindex(days).values])
    slot_day = ((days - pd.Timestamp("1970-01-01")).days).values.astype(np.int64)
    slot_idx = first.values.astype(np.int64)
    day_first = np.flatnonzero(np.r_[True, slot_day[1:] != slot_day[:-1]])[:-15]
    args = (d["t"], d["bh"], d["bl"], d["ah"], d["al"], slot_idx, side, slot_day)
    print(f"{len(day_first)} runs, 15 days each, up to 4 trades a day\n")
    print("target  stop  RR  risk%   P(target)  P(bust)  avg trades  median end $")
    best = {}
    for target in (50.0, 100.0):
        for stop in (2.0, 3.0, 5.0):
            for rr in (1.0, 2.0, 3.0):
                for f in (30.0, 50.0, 90.0):
                    res = [one_run(*args, j0, stop, rr, f, target, 15) for j0 in day_first]
                    hit = np.mean([r[0] for r in res])
                    bust = np.mean([r[1] < stop + 0.05 + 0.5 or r[1] < 0.9 for r in res])
                    tr = np.mean([r[2] for r in res])
                    med = np.median([r[1] for r in res])
                    if hit > best.get(target, (0,))[0]:
                        best[target] = (hit, stop, rr, f)
                    print(f"${target:4.0f}  ${stop:3.0f}  {rr:3.0f}  {f:4.0f}%   {100 * hit:7.1f}%  {100 * bust:6.1f}%  "
                          f"{tr:8.1f}   {med:9.2f}")
    for target, (hit, stop, rr, f) in best.items():
        print(f"\nbest for ${target:.0f}: stop ${stop:.0f}, RR {rr:.0f}, risk {f:.0f}% -> {100 * hit:.1f}% "
              f"(no-edge limit {100 * 10 / target:.0f}%)")


if __name__ == "__main__":
    main()
