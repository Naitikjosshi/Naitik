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

---

# AarYaParEA — all-or-nothing mode

`MQL5/Experts/AarYaParEA.mq5` makes **a few very large trades**. It either reaches the target
in a short winning streak (paar) or loses the deposit (aar).

**How it works**
- Same entry signal as NaitikGrowthEA (EMA 50/200 trend + RSI pullback), one trade at a time.
- Each trade risks `InpRiskPercent` (default **90%**) of equity at the SL.
- The TP is sized so that a win lands exactly on `InpTargetEquity`, capped at `InpMaxRR` (default 3.5).
  With $100: trade 1 risks ~$90 for ~+$315 → ~$415, trade 2 risks ~$373 for ~+$585 → **$1000**.
- At the target it closes everything and stops for good (`InpResetState = true` to rearm).
- Lot size is capped to 50% of free margin so the broker's stop-out doesn't hit before the SL.

**The real odds:** in a fair market, the chance of turning $100 into $1000 is **at best ~10%**, whatever
the strategy (the expected value of a trade is roughly zero, and the spread and commission pull it slightly negative).
With the default 2-trade plan it's roughly 1/4.5 × 1/2.6 ≈ **8–9%**. That means about **9 out of 10 runs lose the $100**.
Raising `InpMaxRR` to 10 makes it a single trade with the same ~9% chance.
Only use money you are fully prepared to lose.

---

# HedgeDailyEA — buy + sell hedge grid with a daily target

`MQL5/Experts/HedgeDailyEA.mq5` keeps both a buy and a sell open and stops each day once it has made its target.
**Needs an MT5 hedging account** (the Exness default).

> ⚠️ In simulation (see **HedgeDailyEA 2.0** below) this v1 lost about **96%** of the account on 2017 EURUSD data,
> even though it hit its daily target on 147 of 240 days. Use v2 instead.

**How it works**
- Opens 1 buy + 1 sell. Each trade has a small TP (`InpTakeProfitPoints`, default 150 points = 15 pips) and **no SL**.
- When a trade hits its TP, a new one opens on the same side, so it stays hedged.
- When a side is losing by `InpGridStepPoints` (200), it adds another trade on that side (up to `InpMaxLevels` = 6).
  When price comes back, those trades recover.
- **Basket close:** if all open trades together are +0.3% of equity, it closes everything and restarts fresh.
- **Daily target:** once equity is **+1.5%** for the day (`InpDailyTargetPct`), it closes everything and stops until the next server day.
- **Equity stop:** if equity drops 40% from the day's start, it closes everything (`InpEquityStopPct`, set 0 to disable).
- `InpLotMultiplier` = 1.0 means no martingale. Raising it makes recovery faster, but blow-ups much bigger.

**Lot sizing:** 0.01 lot per $100 balance. On a $100 account use a **Standard Cent** account (or keep 0.01) — on a
dollar account a 6-level grid against a 120-pip trend is already a ~$40 floating loss at 0.01 lots.

**The truth about "no stop loss":** a hedge does not remove risk. A buy + sell together only gain when price
swings back and forth. In ranging markets it hits +1–2% days regularly. In a strong one-way trend (news, NFP, gold rallies)
the losing side piles up and the floating loss grows faster and faster. One such day can wipe out weeks of +1.5% days.
That's why the equity stop exists; turning it off means one bad trend can blow the account.
Backtest at least 1–2 years (including trending months) and demo-test before going live.
Best on ranging pairs like EURCHF, AUDNZD, EURGBP; avoid XAUUSD and news times.

---

# HedgeDailyEA 2.0 — adaptive buy + sell hedge grid

`MQL5/Experts/HedgeDailyEA_v2.mq5`. **Needs an MT5 hedging account** (the Exness default).
Still a hedge EA: it holds buys and sells together, uses **no stop loss on trades**, and stops for the day at a profit target.

## What changed vs v1 (each fix targets a v1 failure found in simulation)
| v1 problem | v2 fix |
|---|---|
| Lot size from *balance*: while a hedge leg floats in loss, balance > equity, so lots got too big | Lot size from `min(balance, equity)`, set as money per 0.01 lot (`InpMoneyPer001Lot` = 300) |
| Fixed 15-pip TP / 20-pip grid: the spread ate ~7% of every win, and the grid was too tight for volatile days | ATR-based spacing (`InpGridATR`/`InpTpATR` = 2 × ATR(H1), ~25–30 pips on EURUSD), each level 1.3× wider |
| Grid on both sides: in a trend the losing side piled up until the 40% equity stop | **Trend-aligned mode**: adds only in the H4 trend direction (buys on dips in an uptrend, sells on rallies in a downtrend); the other side keeps one hedge trade |
| Every trade had its own TP | **Basket TP**: all trades of a side close together at the average price ± 1 × ATR |
| Daily target on day-start *equity*: a losing cycle got closed on a bounce and still counted as a target day | Daily target on day-start **balance** (`InpDailyTargetPct` = 1.5) |
| Only a 40% equity stop | **Hedge lock** at 10% cycle drawdown (`InpUseLock`): opens the opposite side for the net exposure so the loss stops growing, with no stop loss on the trades. Then a **hard stop** at 30% as the last resort (`InpHardStopPct`, 0 = off) |
| No market filters | New cycles only in a range (ADX < 25, price inside the Bollinger bands); add a level only after a candle closes in its favour; no adds against a strong ADX trend; **news filter** (live only, high-impact events); spread, margin level, trading hours, Friday close |

## Simulation results
Python simulator in `research/hedge_sim/` (reproduce with `python run_tests.py`). EURUSD H1, Apr 2017 – Feb 2018,
1-pip spread, $10,000 start (the % results scale the same for a $100 cent account).

| Test | v1 | v2 |
|---|---|---|
| Real data (uptrend 1.07 → 1.23) | **−96.4%** | **+67.2%** (max drawdown 33.5%) |
| Same data mirrored into a downtrend, with swap costs | −97.0% | +38.0% (max drawdown 40.0%) |
| 6 random-walk tests (real volatility, no trend) | −59.9% … −98.5% (all 6 lost) | −61.0% … +17.8% (4 of 6 lost, median ≈ −25%) |
| Days the 1.5% daily target was hit (real data) | 147 of 240 | 0 |

v2 month by month on the real data: +13.4%, +19.8%, +20.2%, +1.6%, +4.2%, −4.6%, +19.9%, −1.5%, −15.5%, +1.7%.

**How to read this honestly**
- v1's 147 "target days" still ended at −96%: five days with ~40% losses wiped them all out. A high win rate is not profit.
- v2 makes money when the market **trends** (it buys dips with the trend) and usually **loses when there is no trend**.
  It is not a guaranteed daily income.
- At the lot size where the account survived the tests, **+1.5% in one day almost never happened**. A daily 1–2%
  target is only reachable with v1-style lot sizes, and those are what blew up v1.
- This is a 10-month, single-pair simulation on hourly bars (no real tick data, no news, no slippage).
  Treat it as a sanity check, not a promise. Run the MT5 Strategy Tester on several years and a demo account before going live.

## Key settings
| Input | Default | Meaning |
|---|---|---|
| `InpMode` | Trend-aligned | `Both sides` = v1-style grid on buys and sells |
| `InpSignalTF` / `InpTrendTF` | H1 / H4 | ATR/ADX/Bands timeframe, and trend EMA (50/200) timeframe |
| `InpDailyTargetPct` | 1.5 | Close all and stop for the day at +1.5% of the day-start balance |
| `InpMoneyPer001Lot` | 300 | 0.01 lot per $300 of balance/equity (lower = more risk) |
| `InpMaxLevels` | 4 | Max trades per side |
| `InpUseLock` / `InpLockDDPct` | on / 10 | Hedge lock at 10% cycle drawdown |
| `InpHardStopPct` | 30 | Close the whole cycle at 30% drawdown (0 = off, not recommended) |
| `InpUseNews` | on | Pause new trades 60 min before / 30 min after high-impact news (not in the tester) |
| `InpFridayClose` | on | Friday from 20:00 server time: close if in profit, no new trades |

## Running it with $100
- At `InpMoneyPer001Lot = 300`, a $100 Standard account would need 0.0033 lot, which is below the 0.01 minimum.
  The EA then **does not trade** and shows a message on the chart. Your options:
  1. **Exness Standard Cent account** (if your region offers it on MT5): $100 = 10,000 USC, so it works exactly as designed.
  2. Deposit $300 or more on a Standard account.
  3. Set `InpAllowMinLot = true`: it trades 0.01 lot on $100, which is **3× the tested risk** (about v1's risk level).
- Attach it to **EURUSD** (any chart timeframe; signals use H1/H4). Gold needs `InpMaxSpreadPoints` ≈ 300 and is much riskier.
- In MetaEditor press F7 to compile. It was syntax-checked here with `tools/mql_syntax_check` (a C++ shim),
  but not compiled with MetaEditor, so fix anything MetaEditor reports before using it.
- Run one copy per symbol. The daily target uses the whole account's equity.
