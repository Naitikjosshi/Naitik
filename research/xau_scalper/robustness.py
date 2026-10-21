"""Robustness of Gold15DayChallenge's max-chance mode ( stop, 90% max loss, doubling in 15 days).

Each table splits 2011-2018 into 2011-14 and 2015-18 so a rule has to work in both halves:
  1. direction (daily trend / random / always buy / always sell) x minimum stop
  2. buy-only and sell-only by entry hour: gold fell in London/NY hours and rose in Asian hours in this data
  3. direction rules (trend, "session": sell 07 / buy 22 UTC, and mixes) for 0 / 00 / 00
  4. the same rules on runs that start in an uptrend (like 2026)

Findings:  is the best stop in both halves; trend beats random by ~5 points but that overlaps with the
time-of-day effect; no rule beats the current one in both halves; in uptrend periods the current rule doubled
45-47%, not the 52-54% of the full sample.

    python robustness.py
"""
import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aar_ya_paar as ayp  # noqa: E402
import backtest as bt  # noqa: E402
import bold_play as bp  # noqa: E402
import fifteen_days as fd  # noqa: E402

# ---------------------------------------------------------------- 1. direction x stop
args, day_first = fd.load()
t, bh, bl, ah, al, slot_idx, side, slot_day = args
days = pd.to_datetime(slot_day[day_first], unit="D")
halves = {"2011-14": day_first[days < "2015-01-01"], "2015-18": day_first[days >= "2015-01-01"]}
rng = np.random.default_rng(3)
sides = {"trend": side, "random": rng.choice([-1, 1], size=len(side)) * (side != 0),
         "long": np.where(side != 0, 1, 0), "short": np.where(side != 0, -1, 0)}
print("$100 -> $200, bold play, max loss 90%   (each cell: % doubled, about 900 runs)")
print("direction  min stop   2011-14   2015-18   both")
for dname, sd in sides.items():
    for ms in (5.0, 8.0, 12.0, 16.0, 24.0):
        a = (t, bh, bl, ah, al, slot_idx, sd, slot_day)
        r = {h: np.mean([bp.bold_run(*a, j0, ms, 0.9, 200.0, 15, 100.0, 1e9)[0] for j0 in js]) for h, js in halves.items()}
        allr = (r["2011-14"] * len(halves["2011-14"]) + r["2015-18"] * len(halves["2015-18"])) / len(day_first)
        print(f"{dname:9s}  ${ms:5.0f}    {100*r['2011-14']:6.1f}%   {100*r['2015-18']:6.1f}%   {100*allr:5.1f}%")

# ---------------------------------------------------------------- 2. entry hour
d = bt.load_10s()
ts = pd.to_datetime(d["t"], unit="s")
trend = ayp.daily_trend(d)
def slots_for(hours):
    keep = np.isin(ts.hour, hours) & (ts.minute == 0) & (ts.second < 10) & (ts.dayofweek < 5)
    idx = np.flatnonzero(keep)
    first = pd.Series(idx, index=ts[idx].floor("h")).groupby(level=0).first()
    days = first.index.normalize()
    tr = np.array([0 if np.isnan(v) else int(v) for v in trend.reindex(days).values])
    slot_day = ((days - pd.Timestamp("1970-01-01")).days).values.astype(np.int64)
    day_first = np.flatnonzero(np.r_[True, slot_day[1:] != slot_day[:-1]])[:-15]
    return first.values.astype(np.int64), tr, slot_day, day_first
print("\n$100 -> $200 bold play ($8 stop, 90%), ONE entry hour per day; % doubled in 2011-14 | 2015-18")
print("hour UTC   buy only          sell only         daily trend")
for h in (2, 4, 7, 10, 13, 16, 19, 22):
    idx, tr, sday, dfirst = slots_for([h])
    days = pd.to_datetime(sday[dfirst], unit="D")
    halves = [dfirst[days < "2015-01-01"], dfirst[days >= "2015-01-01"]]
    row = []
    for sd in (np.where(tr != 0, 1, 0), np.where(tr != 0, -1, 0), tr):
        a = (d["t"], d["bh"], d["bl"], d["ah"], d["al"], idx, sd, sday)
        r = [100 * np.mean([bp.bold_run(*a, j0, 8.0, 0.9, 200.0, 15, 100.0, 1e9)[0] for j0 in js]) for js in halves]
        row.append(f"{r[0]:5.1f} | {r[1]:5.1f}")
    print(f"  {h:02d}:00    " + "     ".join(row))

# ---------------------------------------------------------------- 3-4. direction rules
def build(rule):
    """rule(hour, trend) -> side. Slots: every hour listed in rule.hours."""
    keep = np.isin(ts.hour, rule["hours"]) & (ts.minute == 0) & (ts.second < 10) & (ts.dayofweek < 5)
    idx = np.flatnonzero(keep)
    first = pd.Series(idx, index=ts[idx].floor("h")).groupby(level=0).first()
    days = first.index.normalize()
    tr = np.array([0 if np.isnan(v) else int(v) for v in trend.reindex(days).values])
    hrs = first.index.hour.values
    side = np.array([rule["side"](h, t) for h, t in zip(hrs, tr)], dtype=np.int64)
    slot_day = ((days - pd.Timestamp("1970-01-01")).days).values.astype(np.int64)
    day_first = np.flatnonzero(np.r_[True, slot_day[1:] != slot_day[:-1]])[:-15]
    return first.values.astype(np.int64), side, slot_day, day_first
rules = {
  "current: trend at 07/09/11/13":          dict(hours=[7, 9, 11, 13], side=lambda h, t: t),
  "trend at 07 only":                       dict(hours=[7], side=lambda h, t: t),
  "session: sell 07, buy 22":               dict(hours=[7, 22], side=lambda h, t: -1 if h == 7 else 1),
  "session: sell 07, buy 23":               dict(hours=[7, 23], side=lambda h, t: -1 if h == 7 else 1),
  "session: sell 07, buy 21":               dict(hours=[7, 21], side=lambda h, t: -1 if h == 7 else 1),
  "trend+session: down->sell 07, up->buy 22": dict(hours=[7, 22], side=lambda h, t: -1 if (h == 7 and t < 0) else (1 if (h == 22 and t > 0) else 0)),
  "trend+session, mixed days: session":     dict(hours=[7, 22], side=lambda h, t: -1 if (h == 7 and t <= 0) else (1 if (h == 22 and t >= 0) else 0)),
}
print("% doubled in 15 days, bold play ($8 stop, 90% max loss)   [2011-14 | 2015-18 | all]")
for name, rule in rules.items():
    idx, side, sday, dfirst = build(rule)
    days = pd.to_datetime(sday[dfirst], unit="D")
    halves = [dfirst[days < "2015-01-01"], dfirst[days >= "2015-01-01"]]
    cells = []
    for eq0 in (10.0, 100.0, 500.0):
        a = (d["t"], d["bh"], d["bl"], d["ah"], d["al"], idx, side, sday)
        r = [np.array([bp.bold_run(*a, j0, 8.0, 0.9, 2 * eq0, 15, eq0, 1e9)[0] for j0 in js]) for js in halves]
        allp = 100 * np.concatenate(r).mean()
        cells.append(f"${eq0:.0f}: {100*r[0].mean():4.1f}|{100*r[1].mean():4.1f}|{allp:4.1f}")
    print(f"{name:42s} " + "   ".join(cells))

print("\nONLY runs that START on an uptrend day (like 2026)   [2011-14 | 2015-18 | all, n runs]")
rules2 = {
  "current: trend at 07/09/11/13":   rules["current: trend at 07/09/11/13"],
  "session: sell 07, buy 22":        rules["session: sell 07, buy 22"],
  "buy 22 only":                     dict(hours=[22], side=lambda h, t: 1),
  "uptrend: buy 22, else trend 07":  dict(hours=[7, 22], side=lambda h, t: 1 if (h == 22 and t > 0) else (t if (h == 7 and t < 0) else 0)),
}
for name, rule in rules2.items():
    idx, side, sday, dfirst = build(rule)
    # start-day trend: trend of the calendar day of the run's first slot
    start_days = pd.to_datetime(sday[dfirst], unit="D")
    up = np.array([trend.get(dd, np.nan) == 1 for dd in start_days])
    js_all = dfirst[up]
    days = pd.to_datetime(sday[js_all], unit="D")
    halves = [js_all[days < "2015-01-01"], js_all[days >= "2015-01-01"]]
    cells = []
    for eq0 in (10.0, 100.0):
        a = (d["t"], d["bh"], d["bl"], d["ah"], d["al"], idx, side, sday)
        r = [np.array([bp.bold_run(*a, j0, 8.0, 0.9, 2 * eq0, 15, eq0, 1e9)[0] for j0 in js]) for js in halves]
        cells.append(f"${eq0:.0f}: {100*r[0].mean():4.1f}|{100*r[1].mean():4.1f}|{100*np.concatenate(r).mean():4.1f} (n={len(js_all)})")
    print(f"{name:34s} " + "   ".join(cells))
