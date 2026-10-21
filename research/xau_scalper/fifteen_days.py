"""Grow a small gold account by a multiple in 15 days with up to 4 trades a day: which settings give the best chance?
Tested on 2011-2018 gold ticks (10 s bid/ask bars), money in today's dollars ($4,000 gold, $0.20 spread).

Each run starts with eq0 on one day and trades the next 15 calendar days. Entries at 07, 09, 11 and 13 UTC
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
def one_run(t, bh, bl, ah, al, slot_idx, slot_side, slot_day, j0, stop, rr, f, target, days, eq0=10.0):
    eq = eq0
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


def load():
    d = bt.load_10s()
    ts = pd.to_datetime(d["t"], unit="s")
    trend = ayp.daily_trend(d)
    keep = np.isin(ts.hour, SLOTS) & (ts.minute == 0) & (ts.second < 10) & (ts.dayofweek < 5)
    idx = np.flatnonzero(keep)
    first = pd.Series(idx, index=ts[idx].floor("h")).groupby(level=0).first()
    days = first.index.normalize()
    side = np.array([0 if np.isnan(v) else int(v) for v in trend.reindex(days).values])
    slot_day = ((days - pd.Timestamp("1970-01-01")).days).values.astype(np.int64)
    slot_idx = first.values.astype(np.int64)
    day_first = np.flatnonzero(np.r_[True, slot_day[1:] != slot_day[:-1]])[:-15]
    return (d["t"], d["bh"], d["bl"], d["ah"], d["al"], slot_idx, side, slot_day), day_first


def grid(args, day_first, eq0, multiple, stops, rrs, risks):
    target = eq0 * multiple
    rows = []
    for stop in stops:
        for rr in rrs:
            for f in risks:
                res = [one_run(*args, j0, stop, rr, f, target, 15, eq0) for j0 in day_first]
                hit = np.mean([r[0] for r in res])
                rows.append((hit, stop, rr, f, np.mean([r[2] for r in res]), np.median([r[1] for r in res])))
    return rows


def main():
    args, day_first = load()
    print(f"{len(day_first)} runs, 15 days each, up to 4 trades a day")
    for eq0, mult in ((10.0, 5.0), (10.0, 10.0)):
        rows = grid(args, day_first, eq0, mult, (2.0, 3.0, 5.0), (1.0, 2.0, 3.0), (30.0, 50.0, 90.0))
        b = max(rows)
        print(f"\n${eq0:.0f} -> ${eq0 * mult:.0f}: best stop ${b[1]:.0f}, RR {b[2]:.0f}, risk {b[3]:.0f}% -> {100 * b[0]:.1f}% "
              f"(no-edge limit {100 / mult:.0f}%)")
        for r in rows:
            if (r[1], r[2], r[3]) in ((3.0, 2.0, 30.0), (3.0, 3.0, 30.0)):
                print(f"   stop ${r[1]:.0f}, RR {r[2]:.0f}, risk {r[3]:.0f}%: {100 * r[0]:.1f}%, {r[4]:.1f} trades")
    print("\nDOUBLING (x2), the Gold15DayChallenge default")
    print("start  stop  RR  risk%   P(x2)   avg trades  median end $")
    for eq0 in (10.0, 100.0, 500.0):
        rows = grid(args, day_first, eq0, 2.0, (3.0, 5.0), (1.0, 2.0), (10.0, 20.0, 30.0, 50.0))
        for hit, stop, rr, f, tr, med in rows:
            print(f"${eq0:4.0f}  ${stop:3.0f}  {rr:3.0f}  {f:4.0f}%   {100 * hit:5.1f}%  {tr:8.1f}   {med:9.2f}")
        b = max(rows)
        print(f"  best for ${eq0:.0f}: stop ${b[1]:.0f}, RR {b[2]:.0f}, risk {b[3]:.0f}% -> {100 * b[0]:.1f}% (limit 50%)\n")


if __name__ == "__main__":
    main()
