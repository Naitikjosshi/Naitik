"""Bold play vs fixed sizing for doubling a gold account in 15 days (2011-2018 ticks, today's prices and spread).

Bold play (Dubins & Savage): when the odds are fair or worse, the best chance of reaching a target is to stake
exactly what is still missing, min(equity, target - equity), and no more. Here each trade:
  planned loss L = min(fmax x equity, target - equity)     win W = target - equity (so a win lands on the target)
  lots = L / (min_stop x 100) rounded down (at least 0.01), then the stop is widened so the loss is exactly L
Entries at 07/09/11/13 UTC when flat, daily-trend direction, up to 4 a day, 15 days.

    python bold_play.py
"""
import os
import sys

import numba as nb
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fifteen_days as fd  # noqa: E402

TODAY, SPREAD, SLIP = fd.TODAY, fd.SPREAD, 0.05


@nb.njit(cache=True)
def bold_run(t, bh, bl, ah, al, slot_idx, slot_side, slot_day, j0, min_stop, fmax, target, days, eq0, max_rr):
    eq = eq0
    j = j0
    end_day = slot_day[j0] + days
    trades = 0
    while j < len(slot_idx) and slot_day[j] < end_day:
        side = slot_side[j]
        if side == 0:
            j += 1
            continue
        L = min(fmax * eq, target - eq)
        lots = np.floor(L / ((min_stop + SLIP) * 100.0) / 0.01 + 1e-7) * 0.01
        if lots < 0.01:
            lots = 0.01
        stop = L / (lots * 100.0) - SLIP                 # widen the stop so the loss is exactly L
        if stop < min_stop * 0.999:
            return 0, eq, trades                          # cannot carry even a minimum-lot stop: bust
        W = target - eq
        tp_dist = W / (lots * 100.0) + SPREAD
        if tp_dist > max_rr * stop:
            tp_dist = max_rr * stop
        s = slot_idx[j]
        mid = 0.25 * (bh[s] + bl[s] + ah[s] + al[s])
        scale = TODAY / mid
        entry = mid * scale + side * SPREAD / 2
        sl = entry - side * stop
        tp = entry + side * tp_dist
        limit = t[s] + (end_day - slot_day[j]) * 86400
        x = s
        pnl = 0.0
        while x + 1 < len(t):
            x += 1
            hi = 0.5 * (bh[x] + ah[x]) * scale - side * SPREAD / 2
            lo = 0.5 * (bl[x] + al[x]) * scale - side * SPREAD / 2
            if (side > 0 and lo <= sl) or (side < 0 and hi >= sl):
                pnl = -(stop + SLIP)
                break
            if (side > 0 and hi >= tp) or (side < 0 and lo <= tp):
                pnl = tp_dist
                break
            if t[x] >= limit:
                pnl = side * ((hi + lo) / 2 - entry)
                break
        eq += pnl * lots * 100.0
        trades += 1
        if eq >= target - 0.01:
            return 1, eq, trades
        while j < len(slot_idx) and slot_idx[j] <= x:
            j += 1
    return 0, eq, trades


def main():
    args, day_first = fd.load()
    print(f"{len(day_first)} fifteen-day runs per row, target = 2 x start\n")
    print("start   sizing                                   doubled  avg trades  median end $")
    for eq0 in (10.0, 100.0, 500.0):
        base = (3.0, 2.0, 30.0) if eq0 < 50 else (5.0, 1.0, 50.0)
        res = [fd.one_run(*args, j0, base[0], base[1], base[2], 2 * eq0, 15, eq0) for j0 in day_first]
        print(f"${eq0:4.0f}  current auto (${base[0]:.0f} stop, 1:{base[1]:.0f}, {base[2]:.0f}%)            "
              f"{100 * np.mean([r[0] for r in res]):5.1f}%  {np.mean([r[2] for r in res]):8.1f}   {np.median([r[1] for r in res]):9.2f}")
        for min_stop in (3.0, 5.0, 8.0, 12.0):
            for fmax in (0.5, 0.9):
                res = [bold_run(*args, j0, min_stop, fmax, 2 * eq0, 15, eq0, 1e9) for j0 in day_first]
                print(f"${eq0:4.0f}  bold play, stop >= ${min_stop:4.1f}, max loss {100 * fmax:3.0f}%      "
                      f"{100 * np.mean([r[0] for r in res]):5.1f}%  {np.mean([r[2] for r in res]):8.1f}   "
                      f"{np.median([r[1] for r in res]):9.2f}")
        print()


if __name__ == "__main__":
    main()
