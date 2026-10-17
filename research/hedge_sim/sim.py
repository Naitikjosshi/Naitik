"""Event-driven simulator for the HedgeDaily EAs on H1 OHLC data.

Each H1 bar is expanded into synthetic ticks along O-L-H-C (bull bar) or
O-H-L-C (bear bar) at a fixed step, so TP/SL/grid levels are hit in order.
Indicators are computed on closed bars only (value of bar i-1 used in bar i),
mirroring how the MQL5 code reads shift=1.
"""
import math
import numpy as np
import pandas as pd

PIP = 0.0001
CONTRACT = 100_000  # EURUSD units per lot -> 1 lot = $10 per pip


# ---------------------------------------------------------------- indicators
def wilder(s, n):
    return s.ewm(alpha=1.0 / n, adjust=False).mean()


def indicators(df, atr_n=14, adx_n=14, bb_n=20, bb_dev=2.0, rsi_n=14):
    o, h, l, c = df.Open, df.High, df.Low, df.Close
    pc = c.shift(1)
    tr = pd.concat([h - l, (h - pc).abs(), (l - pc).abs()], axis=1).max(axis=1)
    atr = tr.rolling(atr_n).mean()  # MT5 iATR = SMA of TR

    up = h.diff()
    dn = -l.diff()
    pdm = np.where((up > dn) & (up > 0), up, 0.0)
    mdm = np.where((dn > up) & (dn > 0), dn, 0.0)
    atr_w = wilder(tr, adx_n)
    pdi = 100 * wilder(pd.Series(pdm, index=df.index), adx_n) / atr_w
    mdi = 100 * wilder(pd.Series(mdm, index=df.index), adx_n) / atr_w
    dx = 100 * (pdi - mdi).abs() / (pdi + mdi).replace(0, np.nan)
    adx = wilder(dx.fillna(0), adx_n)

    mid = c.rolling(bb_n).mean()
    sd = c.rolling(bb_n).std(ddof=0)

    delta = c.diff()
    gain = wilder(delta.clip(lower=0), rsi_n)
    loss = wilder((-delta).clip(lower=0), rsi_n)
    rsi = 100 - 100 / (1 + gain / loss.replace(0, np.nan))

    ind = pd.DataFrame({
        "atr": atr, "adx": adx, "pdi": pdi, "mdi": mdi,
        "bb_up": mid + bb_dev * sd, "bb_lo": mid - bb_dev * sd, "bb_mid": mid,
        "rsi": rsi, "open": o, "close": c,
        "ema_f": c.ewm(span=200, adjust=False).mean(),   # ~ H4 EMA50
        "ema_s": c.ewm(span=800, adjust=False).mean(),   # ~ H4 EMA200
    })
    return ind.shift(1)  # decisions in bar i only see bar i-1


# ---------------------------------------------------------------- engine
class Pos:
    __slots__ = ("side", "lots", "entry", "tp", "sl", "role", "id")

    def __init__(self, side, lots, entry, tp, sl, role, pid):
        self.side, self.lots, self.entry = side, lots, entry
        self.tp, self.sl, self.role, self.id = tp, sl, role, pid


class Engine:
    def __init__(self, df, strategy, balance=10_000.0, spread_pips=1.0,
                 swap_long=0.0, swap_short=0.0, tick_pips=0.5):
        self.df = df
        self.s = strategy
        self.balance = balance
        self.start_balance = balance
        self.spread = spread_pips * PIP
        self.swap = {1: swap_long, -1: swap_short}  # pips per lot per rollover
        self.step = tick_pips * PIP
        self.pos = []
        self.next_id = 1
        self.bid = self.ask = None
        self.t = None
        self.first_tick = False
        self.blown = False
        self.stats = {"closed": 0, "max_gross": 0.0, "max_levels": 0, "spread_cost": 0.0}

    # --- account
    def pnl(self, p):
        if p.side == 1:
            return (self.bid - p.entry) * CONTRACT * p.lots
        return (p.entry - self.ask) * CONTRACT * p.lots

    def floating(self):
        return sum(self.pnl(p) for p in self.pos)

    def equity(self):
        return self.balance + self.floating()

    # --- orders
    def open(self, side, lots, tp=0.0, sl=0.0, role="grid"):
        if lots <= 0:
            return None
        price = self.ask if side == 1 else self.bid
        p = Pos(side, lots, price, tp, sl, role, self.next_id)
        self.next_id += 1
        self.pos.append(p)
        gross = sum(q.lots for q in self.pos)
        self.stats["max_gross"] = max(self.stats["max_gross"], gross)
        return p

    def close(self, p, price=None):
        if price is None:
            pnl = self.pnl(p)
        else:
            pnl = ((price - p.entry) if p.side == 1 else (p.entry - price)) * CONTRACT * p.lots
        self.balance += pnl
        self.pos.remove(p)
        self.stats["closed"] += 1
        self.stats["spread_cost"] += p.lots * self.spread * CONTRACT
        return pnl

    def close_all(self, role=None):
        for p in list(self.pos):
            if role is None or p.role == role:
                self.close(p)

    # --- server-side TP / SL
    def check_stops(self):
        for p in list(self.pos):
            if p.side == 1:
                if p.tp > 0 and self.bid >= p.tp:
                    self.close(p, self.bid if self.first_tick else p.tp)
                elif p.sl > 0 and self.bid <= p.sl:
                    self.close(p, self.bid if self.first_tick else p.sl)
            else:
                if p.tp > 0 and self.ask <= p.tp:
                    self.close(p, self.ask if self.first_tick else p.tp)
                elif p.sl > 0 and self.ask >= p.sl:
                    self.close(p, self.ask if self.first_tick else p.sl)

    def apply_swap(self, old_date):
        mult = 3 if old_date.weekday() == 2 else 1
        for p in self.pos:
            self.balance += self.swap[p.side] * 10.0 * p.lots * mult

    # --- run
    def ticks(self, o, h, l, c):
        pts = [o, l, h, c] if c >= o else [o, h, l, c]
        out = [o]
        for a, b in zip(pts[:-1], pts[1:]):
            n = max(1, int(abs(b - a) / self.step))
            out.extend(np.linspace(a, b, n + 1)[1:])
        return out

    def run(self, ind, warmup=220):
        df = self.df
        curve = []
        low_eq = self.balance
        prev_date = None
        idx = df.index
        O, H, L, C = df.Open.values, df.High.values, df.Low.values, df.Close.values
        rows = ind.to_dict("records")
        for i in range(warmup, len(df)):
            t = idx[i]
            d = t.date()
            if prev_date is not None and d != prev_date:
                self.apply_swap(prev_date)
            prev_date = d
            self.s.on_bar(self, t, rows[i])
            for k, price in enumerate(self.ticks(O[i], H[i], L[i], C[i])):
                self.t = t
                self.first_tick = k == 0
                self.bid = price
                self.ask = price + self.spread
                self.check_stops()
                self.s.on_tick(self, t, rows[i])
                eq = self.equity()
                low_eq = min(low_eq, eq)
                if eq <= 0:
                    self.blown = True
                    self.close_all()
                    break
            if self.blown:
                curve.append((t, 0.0))
                break
            curve.append((t, self.equity()))
        self.curve = pd.Series(dict(curve))
        self.low_eq = low_eq
        return self


def report(name, eng, strat):
    c = eng.curve
    peak = c.cummax()
    dd = ((peak - c) / peak).max() * 100
    final = c.iloc[-1]
    days = strat.days
    return {
        "name": name,
        "final": round(final, 0),
        "ret_%": round((final / eng.start_balance - 1) * 100, 1),
        "maxDD_%": round(dd, 1),
        "worst_eq_%": round((eng.low_eq / eng.start_balance - 1) * 100, 1),
        "target_days": strat.target_days,
        "days": len(days),
        "hard_stops": strat.hard_stops,
        "locks": getattr(strat, "locks", 0),
        "max_gross_lots": round(eng.stats["max_gross"], 2),
        "trades": eng.stats["closed"],
        "spread_$": round(eng.stats["spread_cost"], 0),
        "blown": eng.blown,
    }
