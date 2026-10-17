# NaitikGrowthEA (MetaTrader 5 / Exness)

An Expert Advisor for MT5 that tries to grow a small account (default: $100 → $1000 target)
using a trend-following pullback strategy with strict risk control.

> **Important:** No EA can guarantee turning $100 into $1000. A 10x return needs many
> winning trades in a row and takes months even in good conditions; any EA that "promises"
> it quickly is using martingale/grid or huge lot sizes and will usually blow the account.
> This EA risks a fixed small % per trade and stops itself at the target or at a drawdown limit.
> **Always backtest and run on a demo account first.**

## Strategy
- **Trend:** EMA 50 vs EMA 200 (price must be on the trend side of EMA 200).
- **Entry:** RSI(14) pullback — buy when RSI crosses back up through 40 in an uptrend,
  sell when it crosses back down through 60 in a downtrend. Checked once per closed bar.
- **Stops:** SL = 1.5 × ATR, TP = 3 × ATR (1:2 reward/risk).
- **Management:** move SL to breakeven at +1R, then trail at 1 × ATR.

## Risk controls
| Input | Default | Meaning |
|---|---|---|
| `InpRiskPercent` | 1.5 | % of equity risked per trade (lot size is calculated from the SL) |
| `InpTargetEquity` | 1000 | Closes trades and stops when equity reaches this |
| `InpMaxDailyLossPct` | 5 | No new trades for the rest of the day after this loss |
| `InpMaxDrawdownPct` | 30 | Closes everything and stops after this drop from the peak |
| `InpMaxSpreadPoints` | 30 | Skips entries when spread is too wide |
| `InpStartHour`/`InpEndHour` | 7 / 20 | Trading window in server time (Exness server = GMT+0) |

The "stopped" state is saved in terminal global variables so it survives restarts.
Set `InpResetState = true` once to start fresh.

## Install on Exness MT5
1. Open an **MT5** account in Exness (Standard or Raw Spread; Standard Cent works great for $100 and makes risk sizing finer).
2. In MT5: **File → Open Data Folder → MQL5 → Experts**, copy `MQL5/Experts/NaitikGrowthEA.mq5` there.
3. Open **MetaEditor** (F4), open the file, press **Compile** (F7).
4. In MT5 enable **Algo Trading**, drag the EA onto a chart.
   Suggested: **EURUSD or XAUUSD, H1**. Exness symbol suffixes (e.g. `EURUSDm`) work automatically.
5. Backtest first: **View → Strategy Tester**, select the EA, symbol, H1, "Every tick based on real ticks".

## Tips for a $100 account
- Keep `InpRiskPercent` at 1–2%. At 2% risk, losing 10 trades in a row costs ~18%; at 10% it wipes ~65%.
- For XAUUSD raise `InpMaxSpreadPoints` (gold spreads are larger in points, e.g. 200–400).
- If you see "Lot size too small for risk settings", the minimum 0.01 lot is too big for your
  balance/SL — use a Cent account or a lower-volatility symbol.
