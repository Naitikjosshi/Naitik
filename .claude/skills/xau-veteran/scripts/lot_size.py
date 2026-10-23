"""XAUUSD position size from equity, risk % and stop distance in dollars of price.

    python3 lot_size.py --equity 500 --risk 1 --stop 8
    python3 lot_size.py --equity 50 --risk 1 --stop 6 --cent     # Exness cent account (USC)

1 lot = 100 oz (cent: same lot, P&L in US cents), so a $1.00 move = $100 per lot.
"""
import argparse
import math


def size(equity, risk_pct, stop, contract=100.0, min_lot=0.01, step=0.01, max_lot=200.0):
    risk_cash = equity * risk_pct / 100.0
    per_lot = stop * contract                     # loss at the stop for 1.00 lot
    raw = risk_cash / per_lot
    lots = min(math.floor(raw / step + 1e-9) * step, max_lot)
    return risk_cash, raw, round(lots, 2), min_lot * per_lot


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--equity", type=float, required=True, help="account equity in USD")
    p.add_argument("--risk", type=float, default=1.0, help="risk per trade, %% of equity (default 1)")
    p.add_argument("--stop", type=float, required=True, help="stop distance in $ of gold price, e.g. 8 = $8")
    p.add_argument("--slippage", type=float, default=0.0, help="extra $ of price to allow for spread/slippage")
    p.add_argument("--cent", action="store_true", help="cent account: equity is in USD, P&L per lot is 1/100")
    p.add_argument("--min-lot", type=float, default=0.01)
    p.add_argument("--step", type=float, default=0.01)
    a = p.parse_args()

    if a.equity <= 0 or a.risk <= 0 or a.stop <= 0:
        p.error("equity, risk and stop must be positive")
    stop = a.stop + a.slippage
    contract = 1.0 if a.cent else 100.0
    risk_cash, raw, lots, min_risk = size(a.equity, a.risk, stop, contract, a.min_lot, a.step)
    unit = "cent lots" if a.cent else "lots"

    print(f"Equity ${a.equity:,.2f}  risk {a.risk}% = ${risk_cash:,.2f}  stop ${stop:.2f} of price")
    print(f"Loss per 1.00 {unit[:-1]} at the stop: ${stop * contract:,.2f}")
    if lots < a.min_lot:
        print(f"TOO SMALL: the risk allows {raw:.4f} {unit}, below the {a.min_lot} minimum.")
        print(f"The minimum lot would risk ${min_risk:,.2f} ({min_risk / a.equity * 100:.1f}% of equity).")
        if not a.cent:
            print("Options: a cent account (--cent), more capital, or skip the trade. Don't tighten the stop to fit.")
        return
    actual = lots * stop * contract
    print(f"Size: {lots:.2f} {unit}  ->  ${actual:,.2f} at risk ({actual / a.equity * 100:.2f}% of equity)")
    print(f"Each $1 of gold price = ${lots * contract:,.2f}")


if __name__ == "__main__":
    main()
