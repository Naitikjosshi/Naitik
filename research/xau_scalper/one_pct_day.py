"""1% a day on gold: what are the real chances?  2011-2018 Dukascopy ticks, money in today's terms ($4,000 gold,
$0.20 spread, $0.05 stop slippage).

Every trading day at 07:00 UTC: one trade in the daily-trend direction (mixed-trend days: no trade).
Take profit = +1% of equity, stop = -k% of equity, stop distance S dollars per oz (lots sized to match),
closed at 20:00 UTC if neither was hit. Then the day is over, win or lose.

Results are in % of equity, so they hold for any balance that can carry the 0.01-lot minimum:
minimum balance = S x $1 / k%   (e.g. S = $8, k = 3%  ->  about $270).

    python one_pct_day.py
"""
import os
import sys

import numba as nb
import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aar_ya_paar as ayp  # noqa: E402
import backtest as bt  # noqa: E402

TODAY, SPREAD, SLIP = 4000.0, 0.20, 0.05


@nb.njit(cache=True)
def day_trade(t, bh, bl, ah, al, s, side, stop, tp_dist, close_t):
    """Return of one day in units of 'risk' (loss at the stop = -1)."""
    mid = 0.25 * (bh[s] + bl[s] + ah[s] + al[s])
    scale = TODAY / mid
    entry = mid * scale + side * SPREAD / 2
    sl = entry - side * stop
    tp = entry + side * tp_dist
    x = s
    while x + 1 < len(t):
        x += 1
        hi = 0.5 * (bh[x] + ah[x]) * scale - side * SPREAD / 2
        lo = 0.5 * (bl[x] + al[x]) * scale - side * SPREAD / 2
        if (side > 0 and lo <= sl) or (side < 0 and hi >= sl):
            return -(stop + SLIP) / (stop + SLIP)
        if (side > 0 and hi >= tp) or (side < 0 and lo <= tp):
            return tp_dist / (stop + SLIP)
        if t[x] >= close_t:
            return side * ((hi + lo) / 2 - entry) / (stop + SLIP)
    return 0.0


def main():
    d = bt.load_10s()
    ts = pd.to_datetime(d["t"], unit="s")
    trend = ayp.daily_trend(d)
    idx = np.flatnonzero((ts.hour == 7) & (ts.minute == 0) & (ts.dayofweek < 5))
    first = pd.Series(idx, index=ts[idx].normalize()).groupby(level=0).first()
    sides = np.array([0 if np.isnan(trend.get(x, np.nan)) else int(trend.get(x)) for x in first.index])
    close_t = (first.index + pd.Timedelta(hours=20)).values.astype("datetime64[s]").astype(np.int64)
    n_days = len(first)
    print(f"{n_days} trading days, {int((sides != 0).sum())} with a clear trend (one trade each)\n")
    print("risk/day  stop   min bal.  days +1%  days lost  avg/day   1 month: median  P(up)  P(<-10%)   1 year: median  P(up)")
    for k in (1.0, 2.0, 3.0, 5.0, 10.0):
        for stop in (8.0, 16.0):
            # TP distance so a win = +1%: stop money = k% -> 1% is stop x (1 / k) (spread and slippage inside)
            tp_dist = (stop + SLIP) / k
            if tp_dist < 3 * SPREAD:
                continue
            r = np.zeros(n_days)
            for i in range(n_days):
                if sides[i] != 0:
                    r[i] = day_trade(d["t"], d["bh"], d["bl"], d["ah"], d["al"], first.values[i], sides[i], stop,
                                     tp_dist, close_t[i]) * k / 100.0
            traded = r[sides != 0]
            win = (traded >= 0.0099).mean()
            lost = (traded < 0).mean()
            logr = np.log1p(r)
            c = np.r_[0.0, np.cumsum(logr)]
            m = np.expm1(c[21:] - c[:-21])            # every 21-trading-day window
            y = np.expm1(c[250:] - c[:-250])          # every 250-trading-day window
            print(f"  {k:4.0f}%   ${stop:3.0f}   ${(stop + SLIP) / (k / 100):6.0f}   {100 * win:6.1f}%   {100 * lost:6.1f}%  "
                  f"{100 * traded.mean():+6.3f}%     {100 * np.median(m):+6.1f}%  {100 * (m > 0).mean():5.1f}%  "
                  f"{100 * (m < -0.10).mean():6.1f}%      {100 * np.median(y):+7.1f}%  {100 * (y > 0).mean():5.1f}%")
    print("\nRobustness of the low-risk rows: average per traded day, by half and on uptrend days only (like 2026)")
    years = first.index.year.values
    for k, stop in ((1.0, 8.0), (1.0, 16.0), (2.0, 16.0)):
        tp_dist = (stop + SLIP) / k
        r = np.array([day_trade(d["t"], d["bh"], d["bl"], d["ah"], d["al"], first.values[i], sides[i], stop, tp_dist,
                                close_t[i]) * k / 100.0 if sides[i] != 0 else np.nan for i in range(n_days)])
        cells = []
        for name, mask in (("2011-14", years < 2015), ("2015-18", years >= 2015), ("up days", sides > 0),
                           ("down days", sides < 0)):
            v = r[mask & (sides != 0)]
            cells.append(f"{name} {100 * np.nanmean(v):+.3f}% ({100 * np.mean(v >= 0.0099):.0f}% hit, n={len(v)})")
        print(f"  {k:.0f}% risk, ${stop:.0f} stop: " + " | ".join(cells))
    print("\nA true 1% every day would be +23% a month and about 12x a year.")


if __name__ == "__main__":
    main()
