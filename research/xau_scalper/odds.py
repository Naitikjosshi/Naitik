"""Odds of $100 -> $1000 with GoldPullbackGrowth's money management (Monte Carlo).

Each path draws trades (R multiple + stop size) and applies the EA's sizing on a $100 account:
risk % of equity (halved 25% below the peak), 0.01 lot minimum used only while its real risk is <= the cap,
otherwise the trade is skipped; stop for good at $1000 or $40. Stops are scaled to today's gold
(median M5 stop $8.83, the figure in andamagodwin/forex's 2026 study).

R scenarios:
  measured   : R of every trade in backtest.py on 2011-2018 M5 data, with the spread scaled so spread/stop
               matches 2026 (about $0.20 on a $8.83 stop), i.e. the rules' real long-run behaviour
  claimed    : the 2026 study's own numbers: 58.9% winners at 1:1 (+0.18 R per trade), taken at face value

    python odds.py
"""
import os
import sys

import numba as nb
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import backtest as bt  # noqa: E402

MEDIAN_STOP_2026 = 8.83
SLIP = 0.05


@nb.njit(cache=True)
def _paths(r_pool, stop_pool, risk_pct, cap_pct, n_paths, max_trades, seed, eq0, target, floor, brake):
    np.random.seed(seed)
    hit = np.zeros(n_paths, np.bool_)
    bust = np.zeros(n_paths, np.bool_)
    taken = np.zeros(n_paths, np.int64)
    final = np.zeros(n_paths)
    n = len(r_pool)
    for p in range(n_paths):
        eq, peak, k, tries = eq0, eq0, 0, 0
        while k < max_trades and tries < max_trades * 3:
            tries += 1
            j = np.random.randint(0, n)
            lpl = (stop_pool[j] + SLIP) * 100.0              # $ lost per 1.0 lot at the stop
            r = risk_pct * (0.5 if eq < peak * (1 - brake / 100) else 1.0)
            lots = np.floor(eq * r / 100 / lpl / 0.01 + 1e-7) * 0.01
            if lots < 0.01:
                if 0.01 * lpl / eq * 100 <= cap_pct:
                    lots = 0.01
                else:
                    continue                                 # EA rejects: min lot too risky at this stop
            k += 1
            eq += r_pool[j] * lots * lpl
            peak = max(peak, eq)
            if eq >= target:
                hit[p] = True
                break
            if eq <= floor:
                bust[p] = True
                break
        taken[p] = k
        final[p] = eq
    return hit, bust, taken, final


def paths(r_pool, stop_pool, risk_pct, cap_pct, n_paths=20_000, max_trades=1300, seed=7,
          eq0=100.0, target=1000.0, floor=40.0, brake=25.0):
    hit, bust, taken, final = _paths(r_pool, stop_pool, float(risk_pct), float(cap_pct), n_paths, max_trades, seed,
                                     eq0, target, floor, brake)
    return (hit.mean(), bust.mean(), np.median(taken[hit]) if hit.any() else float("nan"),
            (final < eq0).mean(), np.median(final))


def main():
    ctx = bt.prepare()
    tr = bt.run(ctx, eq0=1e12, risk_pct=0.0001, spread_mult=0.2 / 8.83 * 2.18 / 0.31, slip=SLIP * 2.18 / 8.83,
                fixed_risk=True)
    stops = tr.sl_dist.values * MEDIAN_STOP_2026 / np.median(tr.sl_dist.values)
    rng = np.random.default_rng(1)
    pools = {"claimed": np.where(rng.random(len(stops)) < 0.589, 1.0, -1.0),     # 2026 study: +0.18 R
             "half edge": np.where(rng.random(len(stops)) < 0.545, 1.0, -1.0),   # +0.09 R
             "measured": tr.R.values}                                            # 2011-2018 rules
    for k, v in pools.items():
        print(f"{k:9s} pool: mean {v.mean():+.3f} R, win {100 * (v > 0).mean():.1f}%")
    print("\nscenario   risk  cap   P($1000)  P(floor)  P(end < $100)  median end $  trades to $1000 (max 1300 ~ 2 years)")
    for name, pool in pools.items():
        for risk, cap in [(1, 10), (3, 10), (5, 10), (5, 15), (5, 20), (10, 15)]:
            h, b, m, lose, med = paths(pool, stops, risk, cap)
            print(f"{name:9s} {risk:4d}%  {cap:3d}%  {100 * h:7.1f}%  {100 * b:7.1f}%  {100 * lose:11.1f}%  "
                  f"{med:11.0f}  {m:8.0f}")


if __name__ == "__main__":
    main()
