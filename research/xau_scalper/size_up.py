"""Can increasing the lot size make $10 -> $100 likely?  Tested on 2011-2018 gold ticks (10 s bid/ask bars).

Money is in today's dollars: a move of x% of price is worth x% of $4,000 per 0.01 lot (1 oz), spread $0.20.
Each run starts with $10 at 07:00 UTC on one day and keeps trading the following days until $100 (win) or until
it cannot afford a minimum-lot stop (loss). One run per start day, about 1,800 runs.

  single    : one trade, stop = 90% of equity, target = $100 (the AarYaParGold default), daily-trend direction
  pyramid   : start with a small stop; each time price moves one more stop-distance in favour, add 0.01 lot and
              trail the stop for all lots to one stop-distance behind the newest lot ("size badhao" on winners)
  martingale: 1:1 trades with a fixed stop; after a loss the next trade doubles its lots, after a win it resets

    python size_up.py
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
MARGIN_PER_LOT001 = 2.0   # 1:2000 leverage on $4,000 gold


@nb.njit(cache=True)
def run_pyramid(t, bh, bl, ah, al, day_start_idx, day_side, k0, stop_usd, max_days, single):
    """Runs from day k0 on. Returns 1 if $100 reached, else 0."""
    eq = 10.0
    k = k0
    nd = len(day_start_idx)
    while k < nd and k < k0 + max_days:
        side = day_side[k]
        if side == 0:
            k += 1
            continue
        s = day_start_idx[k]
        mid = 0.25 * (bh[s] + bl[s] + ah[s] + al[s])
        scale = TODAY / mid                                   # today's dollars per 1.0 of old price
        if single:
            stop = 0.9 * eq - 0.10                            # $ move per 0.01 lot
            if stop < 3.0:
                return 0
            target = 100.0 - eq + SPREAD
        else:
            stop = stop_usd
            if eq < stop + 0.5:
                return 0
            target = 1e9
        units = 1
        avg = mid * scale + side * SPREAD / 2                 # entry in today's dollars
        last_add = avg
        sl = avg - side * stop
        tp = avg + side * target
        x = s
        closed = False
        while x + 1 < len(t):
            x += 1
            hi = 0.5 * (bh[x] + ah[x]) * scale - side * SPREAD / 2
            lo = 0.5 * (bl[x] + al[x]) * scale - side * SPREAD / 2
            adverse = lo if side > 0 else hi
            favour = hi if side > 0 else lo
            if (side > 0 and adverse <= sl) or (side < 0 and adverse >= sl):
                eq += side * (sl - avg) * units
                closed = True
                break
            open_pl = side * (favour - avg) * units
            if eq + open_pl >= 100.0 or (single and side * (favour - tp) >= 0):
                return 1
            if not single:
                # add one more 0.01 lot each time price moved another stop distance in our favour
                while side * (favour - (last_add + side * stop)) >= 0 and (units + 1) * MARGIN_PER_LOT001 < eq + open_pl:
                    last_add = last_add + side * stop
                    add_px = last_add + side * SPREAD
                    avg = (avg * units + add_px) / (units + 1)
                    units += 1
                    sl = last_add - side * stop
                    open_pl = side * (favour - avg) * units
        if not closed:
            return 0
        if eq >= 100.0:
            return 1
        # next attempt: the day after the trade closed
        while k < nd and day_start_idx[k] <= x:
            k += 1
    return 0


@nb.njit(cache=True)
def run_martingale(t, bh, bl, ah, al, day_start_idx, day_side, k0, stop_usd, max_days):
    eq = 10.0
    lots = 1
    k = k0
    nd = len(day_start_idx)
    while k < nd and k < k0 + max_days:
        side = day_side[k]
        if side == 0:
            k += 1
            continue
        if eq < lots * stop_usd + 0.5 or lots * MARGIN_PER_LOT001 > eq:
            if eq >= stop_usd + 0.5:
                lots = 1                                       # cannot afford the doubled size: start over
            else:
                return 0
        s = day_start_idx[k]
        mid = 0.25 * (bh[s] + bl[s] + ah[s] + al[s])
        scale = TODAY / mid
        entry = mid * scale + side * SPREAD / 2
        sl = entry - side * stop_usd
        tp = entry + side * stop_usd
        x = s
        res = 0
        while x + 1 < len(t):
            x += 1
            hi = 0.5 * (bh[x] + ah[x]) * scale - side * SPREAD / 2
            lo = 0.5 * (bl[x] + al[x]) * scale - side * SPREAD / 2
            if (side > 0 and lo <= sl) or (side < 0 and hi >= sl):
                res = -1
                break
            if (side > 0 and hi >= tp) or (side < 0 and lo <= tp):
                res = 1
                break
        if res == 0:
            return 0
        eq += res * lots * (stop_usd - (SPREAD if res < 0 else 0.0)) if res > 0 else -lots * stop_usd
        lots = 1 if res > 0 else lots * 2
        if eq >= 100.0:
            return 1
        while k < nd and day_start_idx[k] <= x:
            k += 1
    return 0


def main():
    d = bt.load_10s()
    ts = pd.to_datetime(d["t"], unit="s")
    trend = ayp.daily_trend(d)
    idx = np.flatnonzero((ts.hour == 7) & (ts.minute == 0) & (ts.dayofweek < 5))
    first = pd.Series(idx, index=ts[idx].normalize()).groupby(level=0).first()
    side = np.array([int(trend.get(dd, 0)) if not np.isnan(trend.get(dd, np.nan)) else 0 for dd in first.index])
    starts = first.values.astype(np.int64)
    args = (d["t"], d["bh"], d["bl"], d["ah"], d["al"], starts, side)
    n = len(starts) - 60
    def rate(fn, *extra):
        return 100.0 * np.mean([fn(*args, k0, *extra) for k0 in range(n)])
    print(f"{n} runs of $10 -> $100 (each may use up to 60 trading days)\n")
    print(f"  single trade, 90% stop (AarYaParGold default)       {rate(run_pyramid, 0.0, 60, True):5.1f}%")
    for stop in (2.0, 3.0, 5.0):
        print(f"  pyramid, ${stop:.0f} stop, add 0.01 lot every ${stop:.0f} in profit     {rate(run_pyramid, stop, 60, False):5.1f}%")
    for stop in (1.0, 2.0):
        print(f"  martingale 1:1, ${stop:.0f} stop, double after a loss            {rate(run_martingale, stop, 60):5.1f}%")
    print("\n  upper limit with no edge: 10 / 100 = 10%")


if __name__ == "__main__":
    main()
