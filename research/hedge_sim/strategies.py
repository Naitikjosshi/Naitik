"""Python mirrors of HedgeDailyEA v1 and the v2 design."""
import math
from sim import PIP

POINT = 0.00001


def round_lot(x, step=0.01, min_lot=0.01):
    return max(min_lot, math.floor(x / step + 1e-9) * step)


class Base:
    def __init__(self):
        self.day = None
        self.done = False
        self.days = set()
        self.target_days = 0
        self.hard_stops = 0
        self.row = None

    def on_bar(self, e, t, row):
        self.row = row


# ---------------------------------------------------------------- v1
class V1(Base):
    def __init__(self, target=1.5, basket=0.3, lot_per_100=0.01, mult=1.0,
                 tp_pts=150, grid_pts=200, max_levels=6, eq_stop=40.0, hours=(1, 22)):
        super().__init__()
        self.target, self.basket = target, basket
        self.lot_per_100, self.mult = lot_per_100, mult
        self.tp, self.grid = tp_pts * POINT, grid_pts * POINT
        self.max_levels, self.eq_stop, self.hours = max_levels, eq_stop, hours

    def on_tick(self, e, t, row):
        eq = e.equity()
        d = t.date()
        if d != self.day:
            self.day, self.day_start, self.done = d, eq, False
            self.days.add(d)
        if self.done:
            return
        day_pct = (eq - self.day_start) / self.day_start * 100
        if day_pct >= self.target:
            e.close_all(); self.done = True; self.target_days += 1
            return
        if self.eq_stop > 0 and day_pct <= -self.eq_stop:
            e.close_all(); self.done = True; self.hard_stops += 1
            return
        if len(e.pos) > 2 and e.floating() >= eq * self.basket / 100:
            e.close_all()
            return
        if t.weekday() >= 5 or not (self.hours[0] <= t.hour < self.hours[1]):
            return
        for side in (1, -1):
            self.manage(e, side)

    def manage(self, e, side):
        ps = [p for p in e.pos if p.side == side]
        n = len(ps)
        go = n == 0
        if 0 < n < self.max_levels:
            if side == 1:
                go = e.ask <= min(p.entry for p in ps) - self.grid
            else:
                go = e.bid >= max(p.entry for p in ps) + self.grid
        if not go:
            return
        lots = round_lot(e.balance / 100 * self.lot_per_100 * self.mult ** n)
        tp = e.ask + self.tp if side == 1 else e.bid - self.tp
        e.open(side, lots, tp=tp)


# ---------------------------------------------------------------- v2
V2_DEFAULTS = dict(
    target=1.5, target_on_balance=True,
    lot_per_100=0.01, mult=1.0, max_levels=6, max_gross_per_100=0.10,
    grid_atr=1.0, tp_atr=1.0, basket_atr=0.5, expansion=1.3,
    min_grid_pips=8.0, min_tp_pips=6.0,
    adx_range=25.0, adx_trend=30.0, use_bb=True, smart_add=True, block_trend=True,
    reopen_any_regime=True,
    use_lock=True, lock_dd=10.0, lock_ratio=1.0,
    lock_trail_start_atr=1.0, lock_trail_atr=1.0, lock_exit_atr=1.0, relock_step=3.0,
    hard_stop=25.0, hours=(1, 22), friday_close_hour=20,
)


class V2(Base):
    def __init__(self, **kw):
        super().__init__()
        cfg = dict(V2_DEFAULTS)
        unknown = set(kw) - set(cfg)
        if unknown:
            raise ValueError(unknown)
        cfg.update(kw)
        self.c = cfg
        self.cycle_start = None
        self.last_unlock_dd = 0.0
        self.was_locked = False
        self.locks = 0

    def grid_pos(self, e, side=None):
        return [p for p in e.pos if p.role == "grid" and (side is None or p.side == side)]

    def size_base(self, e):
        return min(e.balance, e.equity())

    def lot(self, e, level):
        return round_lot(self.size_base(e) / 100 * self.c["lot_per_100"] * self.c["mult"] ** level)

    def reset_cycle(self):
        self.cycle_start = None
        self.last_unlock_dd = 0.0
        self.was_locked = False

    def on_tick(self, e, t, row):
        c = self.c
        eq = e.equity()
        d = t.date()
        if d != self.day:
            self.day, self.done = d, False
            self.day_start_bal, self.day_start_eq = e.balance, eq
            self.days.add(d)
        if self.done:
            return

        base = self.day_start_bal if c["target_on_balance"] else self.day_start_eq
        if eq >= base * (1 + c["target"] / 100):
            e.close_all(); self.done = True; self.target_days += 1; self.reset_cycle()
            return

        if not e.pos:
            self.reset_cycle()
        cycle_dd = (self.cycle_start - eq) / self.cycle_start * 100 if self.cycle_start else 0.0
        if c["hard_stop"] > 0 and cycle_dd >= c["hard_stop"]:
            e.close_all(); self.done = True; self.hard_stops += 1; self.reset_cycle()
            return

        if t.weekday() == 4 and t.hour >= c["friday_close_hour"]:
            if e.pos and e.floating() >= 0:
                e.close_all(); self.reset_cycle()
            return

        atr = row["atr"]
        if atr != atr:  # NaN warmup
            return
        if c["use_lock"]:
            self.manage_lock(e, row, cycle_dd, atr)
        if any(p.role == "lock" for p in e.pos):
            return

        grid = max(atr * c["grid_atr"], c["min_grid_pips"] * PIP)
        tpd = max(atr * c["tp_atr"], c["min_tp_pips"] * PIP)
        bd = max(atr * c["basket_atr"], c["min_tp_pips"] * PIP)
        if t.weekday() < 5 and c["hours"][0] <= t.hour < c["hours"][1]:
            for side in (1, -1):
                self.manage_side(e, side, row, grid, tpd, eq)
        for side in (1, -1):
            self.update_basket(e, side, bd, tpd)

    def regime_range(self, row):
        c = self.c
        ok = row["adx"] < c["adx_range"]
        if c["use_bb"]:
            ok = ok and row["bb_lo"] < row["close"] < row["bb_up"]
        return ok

    def manage_side(self, e, side, row, grid, tpd, eq):
        c = self.c
        ps = self.grid_pos(e, side)
        n = len(ps)
        if n == 0:
            if not e.pos:
                if not self.regime_range(row):
                    return
            elif not (c["reopen_any_regime"] or self.regime_range(row)):
                return
        elif n < c["max_levels"]:
            step = grid * c["expansion"] ** (n - 1)
            if side == 1:
                if e.ask > min(p.entry for p in ps) - step:
                    return
            elif e.bid < max(p.entry for p in ps) + step:
                return
            if c["block_trend"] and row["adx"] > c["adx_trend"]:
                if (side == 1 and row["mdi"] > row["pdi"]) or (side == -1 and row["pdi"] > row["mdi"]):
                    return
            if c["smart_add"]:
                bull = row["close"] > row["open"]
                bear = row["close"] < row["open"]
                if (side == 1 and not bull) or (side == -1 and not bear):
                    return
        else:
            return
        lots = self.lot(e, n)
        gross = sum(p.lots for p in e.pos)
        if gross + lots > self.size_base(e) / 100 * c["max_gross_per_100"] + 1e-9:
            return
        if self.cycle_start is None:
            self.cycle_start = eq
        tp = e.ask + tpd if side == 1 else e.bid - tpd
        e.open(side, lots, tp=tp)
        e.stats["max_levels"] = max(e.stats["max_levels"], n + 1)

    def update_basket(self, e, side, bd, tpd):
        ps = self.grid_pos(e, side)
        if len(ps) >= 2:
            vol = sum(p.lots for p in ps)
            avg = sum(p.lots * p.entry for p in ps) / vol
            target = avg + bd if side == 1 else avg - bd
            if (side == 1 and e.bid >= target) or (side == -1 and e.ask <= target):
                for p in ps:
                    e.close(p)
                return
            for p in ps:
                p.tp = target
        elif len(ps) == 1 and ps[0].tp == 0:
            p = ps[0]
            p.tp = p.entry + tpd if side == 1 else p.entry - tpd
            if (side == 1 and e.bid >= p.tp) or (side == -1 and e.ask <= p.tp):
                e.close(p)

    def manage_lock(self, e, row, cycle_dd, atr):
        c = self.c
        locks = [p for p in e.pos if p.role == "lock"]
        if not locks:
            if self.was_locked:
                self.was_locked = False
                self.last_unlock_dd = max(cycle_dd, 0.0)
            thr = c["lock_dd"]
            if self.last_unlock_dd > 0:
                thr = max(thr, self.last_unlock_dd + c["relock_step"])
            net = sum(p.side * p.lots for p in self.grid_pos(e))
            if cycle_dd >= thr and abs(net) >= 0.01:
                side = -1 if net > 0 else 1
                lots = round(abs(net) * c["lock_ratio"], 2)
                e.open(side, lots, role="lock")
                self.locks += 1
                self.was_locked = True
                for p in self.grid_pos(e):
                    p.tp = 0.0
            return
        for p in locks:
            prof = (e.bid - p.entry) if p.side == 1 else (p.entry - e.ask)
            if prof >= c["lock_trail_start_atr"] * atr:
                if p.side == 1:
                    new = e.bid - c["lock_trail_atr"] * atr
                    if new > p.sl:
                        p.sl = new
                else:
                    new = e.ask + c["lock_trail_atr"] * atr
                    if p.sl == 0 or new < p.sl:
                        p.sl = new
            if c["lock_exit_atr"] > 0 and prof <= -c["lock_exit_atr"] * atr:
                e.close(p)


# ---------------------------------------------------------------- v2 trend-aligned
class V3(V2):
    """Hedge pair always on; grid adds only on the side of the higher-TF trend."""

    EXTRA = dict(grid_none=False, start_filter="any", trend_buffer_atr=0.0, reducer=False)

    def __init__(self, **kw):
        extra = {k: kw.pop(k) for k in list(kw) if k in self.EXTRA}
        super().__init__(**kw)
        self.x = dict(self.EXTRA)
        self.x.update(extra)

    def on_tick(self, e, t, row):
        if self.cycle_start is not None and not e.pos:
            self.cycle_bal = None
        super().on_tick(e, t, row)
        if self.x["reducer"] and e.pos and getattr(self, "cycle_bal", None) is not None:
            if not any(p.role == "lock" for p in e.pos):
                self.reduce(e)

    def reduce(self, e):
        """Use realized cycle profit to close the worst losing position."""
        bank = e.balance - self.cycle_bal
        if bank <= 0:
            return
        worst = min(e.pos, key=e.pnl)
        loss = e.pnl(worst)
        if loss < 0 and bank + loss >= 0:
            e.close(worst)

    def bias(self, row):
        f, s, c = row["ema_f"], row["ema_s"], row["close"]
        buf = self.x["trend_buffer_atr"] * row["atr"]
        if f > s and c > s + buf:
            return 1
        if f < s and c < s - buf:
            return -1
        return 0

    def manage_side(self, e, side, row, grid, tpd, eq):
        c = self.c
        ps = self.grid_pos(e, side)
        n = len(ps)
        if n == 0:
            if not e.pos and self.x["start_filter"] == "range" and not self.regime_range(row):
                return
        elif n < c["max_levels"]:
            b = self.bias(row)
            if b == 0 and not self.x["grid_none"]:
                return
            if b != 0 and side != b:
                return
            step = grid * c["expansion"] ** (n - 1)
            if side == 1:
                if e.ask > min(p.entry for p in ps) - step:
                    return
            elif e.bid < max(p.entry for p in ps) + step:
                return
            if c["block_trend"] and row["adx"] > c["adx_trend"]:
                if (side == 1 and row["mdi"] > row["pdi"]) or (side == -1 and row["pdi"] > row["mdi"]):
                    return
            if c["smart_add"]:
                bull = row["close"] > row["open"]
                bear = row["close"] < row["open"]
                if (side == 1 and not bull) or (side == -1 and not bear):
                    return
        else:
            return
        lots = self.lot(e, n)
        gross = sum(p.lots for p in e.pos)
        if gross + lots > self.size_base(e) / 100 * c["max_gross_per_100"] + 1e-9:
            return
        if self.cycle_start is None:
            self.cycle_start = eq
            self.cycle_bal = e.balance
        tp = e.ask + tpd if side == 1 else e.bid - tpd
        e.open(side, lots, tp=tp)
        e.stats["max_levels"] = max(e.stats["max_levels"], n + 1)
