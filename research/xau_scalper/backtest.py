"""Backtest of GoldPullbackGrowth.mq5 on 10-second Dukascopy bid/ask bars (see data.py).

Mirrors the EA: signals on closed M5 bid bars, entry in the first 60 s of the next bar at the ask (long) or bid
(short) once the spread is <= max, SL/TP checked on the exit side of the book every 10 s (SL first when one
10 s bar touches both, gaps fill at the bar open), slippage on stop / market exits, 60-bar time stop, flat at
21:00 UTC, Friday cut-off, daily loss limit, max losses and trades per day, 5-bar cooldown after a loss, and
the EA's lot sizing: risk % of equity, broker minimum lot only while its real risk is <= the cap.

    python backtest.py                      # all years in $XAU_DATA (default ./data)
"""
import glob
import math
import os
import sys

import numba as nb
import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.environ.get("XAU_DATA", os.path.join(HERE, "data"))

P = dict(ema_fast=9, ema_slow=21, ema_trend=200, atr_n=14, rsi_n=14, adx_n=14, pullback=5,
         rsi_long=(45.0, 70.0), rsi_short=(30.0, 55.0), adx_min=25.0, max_range_atr=3.0,
         sl_atr=1.5, min_sl=1.5, rr=1.0, max_hold=60, start_h=7, end_h=17, fri_h=15, flat_h=21,
         max_spread=0.45, entry_window=60, cooldown=5)


# ------------------------------------------------------------------ data
def load_10s():
    files = sorted(glob.glob(os.path.join(DATA, "xau_10s_*.npz")))
    if not files:
        sys.exit(f"no data in {DATA}: run data.py first")
    parts = [np.load(f) for f in files]
    cols = ["t", "bo", "bh", "bl", "bc", "ao", "ah", "al", "ac"]
    d = {c: np.concatenate([p[c] for p in parts]).astype(np.int64 if c == "t" else np.float64) for c in cols}
    o = np.argsort(d["t"], kind="stable")
    return {c: v[o] for c, v in d.items()}


def m5_bars(d, period=300):
    key = d["t"] // period
    starts = np.flatnonzero(np.r_[True, key[1:] != key[:-1]])
    ends = np.r_[starts[1:], len(key)]
    bars = pd.DataFrame({
        "open": d["bo"][starts], "high": np.maximum.reduceat(d["bh"], starts),
        "low": np.minimum.reduceat(d["bl"], starts), "close": d["bc"][ends - 1],
        "spread": d["ac"][ends - 1] - d["bc"][ends - 1],
    }, index=pd.to_datetime(key[starts] * period, unit="s"))
    return bars, starts, ends


# ------------------------------------------------------------------ indicators (MT5 definitions)
def wilder(s, n):
    return s.ewm(alpha=1.0 / n, adjust=False).mean()


def features(b, p=P):
    c, h, l = b.close, b.high, b.low
    f = pd.DataFrame(index=b.index)
    f["ema_f"] = c.ewm(span=p["ema_fast"], adjust=False).mean()
    f["ema_s"] = c.ewm(span=p["ema_slow"], adjust=False).mean()
    f["ema_t"] = c.ewm(span=p["ema_trend"], adjust=False).mean()
    pc = c.shift(1)
    tr = pd.concat([h - l, (h - pc).abs(), (l - pc).abs()], axis=1).max(axis=1)
    f["atr"] = tr.rolling(p["atr_n"]).mean()                       # iATR: simple average of TR
    dlt = c.diff()
    rs = wilder(dlt.clip(lower=0), p["rsi_n"]) / wilder((-dlt).clip(lower=0), p["rsi_n"]).replace(0, np.nan)
    f["rsi"] = (100 - 100 / (1 + rs)).fillna(50.0)                 # iRSI: Wilder smoothing
    up, dn = h.diff(), -l.diff()
    pdm = pd.Series(np.where((up > dn) & (up > 0), up, 0.0), index=b.index)
    mdm = pd.Series(np.where((dn > up) & (dn > 0), dn, 0.0), index=b.index)
    atr_w = wilder(tr, p["adx_n"]).replace(0, np.nan)
    pdi, mdi = 100 * wilder(pdm, p["adx_n"]) / atr_w, 100 * wilder(mdm, p["adx_n"]) / atr_w
    dx = 100 * (pdi - mdi).abs() / (pdi + mdi).replace(0, np.nan)
    f["adx"] = wilder(dx.fillna(0), p["adx_n"])                    # iADXWilder
    return f


def signals(b, f, p=P):
    o, h, l, c = b.open, b.high, b.low, b.close
    n = p["pullback"]
    bull = (c > f.ema_t) & (f.ema_s > f.ema_t)
    bear = (c < f.ema_t) & (f.ema_s < f.ema_t)
    touch_l = (l <= f.ema_s).astype(float).rolling(n, min_periods=1).max() > 0
    touch_s = (h >= f.ema_s).astype(float).rolling(n, min_periods=1).max() > 0
    res_l = (c > f.ema_f) & (c > o) & (f.ema_f > f.ema_s)
    res_s = (c < f.ema_f) & (c < o) & (f.ema_f < f.ema_s)
    rsi_up, rsi_dn = f.rsi > f.rsi.shift(1), f.rsi < f.rsi.shift(1)
    rsi_l = f.rsi.between(*p["rsi_long"]) & rsi_up
    rsi_s = f.rsi.between(*p["rsi_short"]) & rsi_dn
    ok = (f.adx >= p["adx_min"]) & ((h - l) <= p["max_range_atr"] * f.atr)
    sig = np.where(bull & touch_l & res_l & rsi_l & ok, 1, np.where(bear & touch_s & res_s & rsi_s & ok, -1, 0))
    sig[:1000] = 0                                                  # indicator warm-up
    return sig.astype(np.int64)


# ------------------------------------------------------------------ simulator
@nb.njit(cache=True)
def simulate(sig, atr, bar_t, starts, t, bo, bh, bl, ao, ah, al, spread_mult,
             eq0, risk_pct, minlot_cap_pct, brake_pct, day_loss_pct, max_losses, max_trades, stop_eq, target_eq,
             sl_atr, min_sl, rr, max_hold, start_h, end_h, fri_h, flat_h, max_spread, window, cooldown, slip,
             contract, vmin, vstep, fixed_risk, period):
    nbar = len(bar_t)
    nt = len(t)
    out = np.zeros((nbar, 10))   # entry_t, exit_t, side, entry, exit, sl_dist, lots, pnl, equity, reason
    k = 0
    eq = eq0
    peak = eq0
    day = -1
    day_start = eq0
    day_entries = 0
    day_losses = 0
    cool_until = 0
    i = 1000
    while i < nbar - 1:
        s = sig[i]
        j = i + 1                                   # entry bar
        bt = bar_t[j]
        if bt // 86400 != day:
            day = bt // 86400
            day_start = eq
            day_entries = 0
            day_losses = 0
        if s == 0 or bt - bar_t[i] > 3600 + period:          # no signal, or a data gap / weekend between the bars
            i += 1
            continue
        hour = (bt % 86400) // 3600
        dow = ((bt // 86400) + 4) % 7               # 1970-01-01 was a Thursday; 0 = Sunday
        if (hour < start_h or hour >= end_h or hour >= flat_h or dow == 0 or dow == 6 or (dow == 5 and hour >= fri_h)
                or (day_start - eq) / day_start * 100.0 >= day_loss_pct or day_losses >= max_losses
                or day_entries >= max_trades or bt < cool_until or eq <= stop_eq or eq >= target_eq):
            i += 1
            continue
        # first 10 s bar inside the entry window with an acceptable spread
        e = starts[j]
        found = -1
        while e < nt and t[e] < bt + window:
            if (ao[e] - bo[e]) * spread_mult <= max_spread:
                found = e
                break
            e += 1
        if found < 0:
            i += 1
            continue
        half = (ao[found] - bo[found]) * (spread_mult - 1.0) * 0.5   # widen/narrow the spread around the mid
        ask0 = ao[found] + half
        bid0 = bo[found] - half
        dist = max(sl_atr * atr[i], min_sl)
        entry = ask0 if s > 0 else bid0
        sl = entry - s * dist
        tp = entry + s * rr * dist
        loss_per_lot = (dist + slip) * contract
        r = risk_pct * (0.5 if (brake_pct > 0 and eq < peak * (1 - brake_pct / 100.0)) else 1.0)
        risk_eq = eq0 if fixed_risk else eq
        lots = math.floor(risk_eq * r / 100.0 / loss_per_lot / vstep + 1e-7) * vstep
        if lots < vmin - 1e-9:
            if minlot_cap_pct > 0 and vmin * loss_per_lot / eq * 100.0 <= minlot_cap_pct:
                lots = vmin
            else:
                i += 1
                continue
        # walk forward until an exit
        x = found
        exit_px = 0.0
        reason = 0
        while True:
            x += 1
            if x >= nt:
                x = nt - 1
                exit_px = bo[x] if s > 0 else ao[x]
                reason = 4
                break
            tx = t[x]
            hx = (tx % 86400) // 3600
            dx = ((tx // 86400) + 4) % 7
            h2 = (ah[x] - bh[x]) * (spread_mult - 1.0) * 0.5
            if tx - t[found] >= max_hold * period or hx >= flat_h or dx == 0 or dx == 6 or tx - t[x - 1] > 3600:
                exit_px = (bo[x] - h2 - slip) if s > 0 else (ao[x] + h2 + slip)
                reason = 3
                break
            if s > 0:
                lo, hi, op = bl[x] - h2, bh[x] - h2, bo[x] - h2
                if lo <= sl:
                    exit_px = min(sl, op) - slip
                    reason = 1
                    break
                if hi >= tp:
                    exit_px = max(tp, op) if op > tp else tp
                    reason = 2
                    break
            else:
                lo, hi, op = al[x] + h2, ah[x] + h2, ao[x] + h2
                if hi >= sl:
                    exit_px = max(sl, op) + slip
                    reason = 1
                    break
                if lo <= tp:
                    exit_px = min(tp, op) if op < tp else tp
                    reason = 2
                    break
        pnl = s * (exit_px - entry) * contract * lots
        eq += pnl
        if eq > peak:
            peak = eq
        day_entries += 1
        if pnl < 0:
            day_losses += 1
            cool_until = t[x] + cooldown * period
        out[k, 0] = t[found]
        out[k, 1] = t[x]
        out[k, 2] = s
        out[k, 3] = entry
        out[k, 4] = exit_px
        out[k, 5] = dist
        out[k, 6] = lots
        out[k, 7] = pnl
        out[k, 8] = eq
        out[k, 9] = reason
        k += 1
        # resume with the signal of the bar the exit happened in
        while i < nbar - 1 and bar_t[i + 1] < t[x]:
            i += 1
        if eq <= stop_eq or eq >= target_eq:
            break
    return out[:k]


COLS = ["entry_t", "exit_t", "side", "entry", "exit", "sl_dist", "lots", "pnl", "equity", "reason"]


def run(ctx, spread_mult=1.0, eq0=10_000.0, risk_pct=0.5, minlot_cap=0.0, brake=0.0, day_loss=1e9, max_losses=10**9,
        max_trades=8, stop_eq=0.0, target_eq=1e18, slip=0.05, fixed_risk=False, sig=None, start=None, end=None):
    p = P
    s = ctx["sig"] if sig is None else sig
    if start is not None or end is not None:
        s = s.copy()
        bt = ctx["bar_t"]
        if start is not None:
            s[bt < pd.Timestamp(start).value // 10**9] = 0
        if end is not None:
            s[bt >= pd.Timestamp(end).value // 10**9] = 0
    d = ctx["d"]
    out = simulate(s, ctx["atr"], ctx["bar_t"], ctx["starts"], d["t"], d["bo"], d["bh"], d["bl"], d["ao"], d["ah"],
                   d["al"], spread_mult, eq0, risk_pct, minlot_cap, brake, day_loss, max_losses, max_trades, stop_eq,
                   target_eq, p["sl_atr"], p["min_sl"], p["rr"], p["max_hold"], p["start_h"], p["end_h"], p["fri_h"],
                   p["flat_h"], p["max_spread"], p["entry_window"], p["cooldown"], slip, 100.0, 0.01, 0.01, fixed_risk,
                   ctx["period"])
    tr = pd.DataFrame(out, columns=COLS)
    tr["entry_t"] = pd.to_datetime(tr.entry_t, unit="s")
    tr["exit_t"] = pd.to_datetime(tr.exit_t, unit="s")
    tr["R"] = tr.side * (tr.exit - tr.entry) / (tr.sl_dist + slip)
    return tr


def stats(tr, eq0):
    if len(tr) == 0:
        return dict(trades=0)
    eq = np.r_[eq0, tr.equity.values]
    peak = np.maximum.accumulate(eq)
    dd = ((peak - eq) / peak).max() * 100
    wins, losses = tr.pnl[tr.pnl > 0].sum(), -tr.pnl[tr.pnl < 0].sum()
    net = eq[-1] - eq0
    return dict(trades=len(tr), win_pct=round(100 * (tr.pnl > 0).mean(), 1),
                pf=round(wins / losses, 2) if losses > 0 else float("inf"),
                avg_R=round(tr.R.mean(), 3), net_pct=round(100 * net / eq0, 1), max_dd_pct=round(dd, 1),
                recovery=round(net / (dd / 100 * peak.max()), 2) if dd > 0 else float("inf"),
                hold_min=round((tr.exit_t - tr.entry_t).dt.total_seconds().mean() / 60, 1),
                med_stop=round(tr.sl_dist.median(), 2))


def prepare(period=300, d=None):
    d = load_10s() if d is None else d
    bars, starts, _ = m5_bars(d, period)
    f = features(bars)
    return dict(d=d, period=period, bars=bars, starts=starts.astype(np.int64), bar_t=bars.index.values.astype("datetime64[s]").astype(np.int64),
                atr=f.atr.fillna(0).values, sig=signals(bars, f), feat=f)


def summary(tr):
    pf = tr.R[tr.R > 0].sum() / -tr.R[tr.R < 0].sum()
    return (f"{len(tr):5d} trades  win {100 * (tr.R > 0).mean():5.1f}%  avg {tr.R.mean():+.3f} R  PF {pf:.2f}  "
            f"stop ${tr.sl_dist.median():.2f}  hold {(tr.exit_t - tr.entry_t).dt.total_seconds().mean() / 60:.0f} min")


if __name__ == "__main__":
    d = load_10s()
    ctx = prepare(300, d)
    b = ctx["bars"]
    print(f"M5 bars {len(b):,} from {b.index[0]} to {b.index[-1]}; median close spread ${b.spread.median():.2f}, "
          f"median ATR ${ctx['feat'].atr.median():.2f}\n")
    tiny = dict(eq0=1e12, risk_pct=1e-4, fixed_risk=True)       # results in R; equity never limits the run
    runs = [("zero cost (mid price, no slippage)", dict(spread_mult=0.0, slip=0.0)),
            ("2026-like cost ($0.20 spread on a $8.83 stop)", dict(spread_mult=0.2 / 8.83 * 2.18 / 0.31, slip=0.012)),
            ("half Dukascopy spread", dict(spread_mult=0.5)),
            ("Dukascopy spread (real, 2011-2018)", dict(spread_mult=1.0))]
    print("M5 EA rules")
    for name, kw in runs:
        tr = run(ctx, **tiny, **kw)
        print(f"  {name:46s} {summary(tr)}")
    tr = run(ctx, **tiny, spread_mult=0.0, slip=0.0)
    tr["y"] = tr.entry_t.dt.year
    print("  by year, zero cost: " + " | ".join(f"{y} {g.R.mean():+.2f}R ({len(g)})" for y, g in tr.groupby("y")))
    rng = np.random.default_rng(1)
    sig = np.zeros_like(ctx["sig"])
    idx = rng.choice(np.arange(1000, len(sig)), size=int((ctx["sig"] != 0).sum()), replace=False)
    sig[idx] = rng.choice([-1, 1], size=len(idx))
    print(f"  {'baseline: random entries, zero cost':46s} {summary(run(ctx, **tiny, spread_mult=0.0, slip=0.0, sig=sig))}")
    for period, name in [(900, "M15"), (3600, "H1")]:
        c = prepare(period, d)
        P["max_spread"] = 99.0
        print(f"{name} same rules")
        for nm, kw in [runs[0], runs[3]]:
            print(f"  {nm:46s} {summary(run(c, **tiny, **kw))}")
        P["max_spread"] = 0.45
