# GoldPullbackGrowth — XAUUSD, $100 → $1000 attempt (start here)

`MQL5/Experts/GoldPullbackGrowth.mq5`. Attach it to an **XAUUSD** chart on an Exness MT5 account (signals always use M5).
It trades one position at a time with a stop loss on every trade. It stops for good at **$1000** (target) or **$40** (floor).
No martingale, no grid, no averaging down.

> **The honest part first.** No EA can promise $100 → $1000. This one is built to give the **best measured chance**,
> and the tables below show that chance. It depends on one thing nobody can know in advance: whether the
> strategy's 2026 edge is real. Run it on a demo account first. The first 50 trades will tell you which case you are in.

## Where the strategy comes from
I reviewed 8 open-source XAUUSD EAs on GitHub (their READMEs, licenses and how they were tested): FvgGold,
BAKOME ICT scalper, MT5-Automation-Labs reversion, ronnisnai Gold-Scalping, Zaibten, Sandyyy123, francomascareloai
and andamagodwin/forex. The strongest was **[andamagodwin/forex](https://github.com/andamagodwin/forex)**: the only one
that publishes a bid/ask backtest with costs, a train/validation split and its losing cases
(PF 1.42, 58.9% wins, +25% in 6 months of 2026 on M5). That repository has **no license**, so its code is not copied
here. `GoldPullbackGrowth.mq5` is a new implementation of its published rules, with the small-account changes below.

**Rules** (long; short is the mirror image), on the closed M5 bar:
- Trend: close > EMA200 and EMA21 > EMA200
- Pullback: a low touched EMA21 in the last 5 bars
- Resume: bar closes above EMA9, is bullish, EMA9 > EMA21
- Momentum: RSI(14) 45–70 and rising, ADX(14) ≥ 25
- Quality: bar range ≤ 3 × ATR, spread ≤ $0.45, new trades only 07–17 UTC (Friday until 15 UTC)
- Exits: stop = max(1.5 × ATR, $1.50), target = 1 × stop, close after 60 bars, at 21:00 UTC and before the broker's daily break

**What is new compared with the original EA**
| Original | GoldPullbackGrowth |
|---|---|
| Fixed 0.5% risk; silently opened the 0.01 minimum lot at **any** risk | Risk modes 1 / 3 / **5%** (default), sized with `OrderCalcProfit` (spread, slippage, commission included). The minimum lot is used only while its real risk is ≤ `InpMinLotMaxRiskPct` (**15%**), otherwise the trade is skipped and the panel shows the equity needed |
| No goal | Closes everything and stops at **$1000**; stops at the **$40** floor; risk halves while equity is 25% below its peak |
| Daily loss lock on closed P/L | Daily loss limit on **equity** (25%), max 3 losing trades and 8 entries per day, 5-bar cooldown after a loss, all rebuilt from deal history (restart-safe) |
| Entry only on the first tick of the bar | Keeps a signal for 60 s in case of a spread spike, one entry per signal bar |
| — | Margin check, broker stop/freeze levels, tick-size price rounding, requote retries, stale-quote check, closes at once if slippage makes the risk 1.5× the plan, repairs a missing stop (or closes), never widens a stop |
| — | High-impact USD news pause (MQL5 calendar, live only), chart panel, journal line for every entry, skip and rejection |

## Why the default is 5% risk and a 15% minimum-lot cap
On a $100 account the risk per trade is set by the **broker's 0.01 lot minimum**, not by the risk setting. 0.01 lot of gold
= 1 oz, and today's typical stop is about $9, so the smallest possible trade risks ~9% of $100. Below about $180
every risk mode trades the same 0.01 lot. What decides the outcome is how far it may go above the plan to keep trading
after a loss. I tested every combination by Monte Carlo (`research/xau_scalper/odds.py`, 20,000 runs of up to 1,300
trades ≈ 2 years, stops scaled to today's gold):

| If the strategy really has… | 3% risk, 10% cap | **5% risk, 15% cap (default)** | 5% risk, 20% cap |
|---|---|---|---|
| the 2026 study's edge (+0.18 R per trade, 59% wins) | 51% reach $1000 | **83% reach $1000** (≈ 260 trades, about 4–5 months) | 88% reach $1000, 8% hit the $40 floor |
| a smaller edge (+0.06 R, 53% wins) | 14% | **30%** | 36%, but 39% hit the floor |
| no edge, like 2011–2018 (−0.04 R, 48% wins) | 0% (ends ≈ $83) | **0.2%** (ends ≈ $52) | 0.2%, and 70% hit the floor |

When it runs low, the EA does not blow up. Below ~$60 the minimum lot breaks the 15% cap on most stops, so it stops
trading and keeps what is left. A pause rule ("stop if the live profit factor is below 1 after 40 trades") was also tested.
It cut the chance in the good case from 83% to 74% and saved only about $13 in the bad case, so it is not included.

## What 7 years of real data say (read this)
I tested the exact rules on **Dukascopy tick data, May 2011 – June 2018** (bid/ask every tick, 10-second bars,
`research/xau_scalper/backtest.py`). This period was never used to design the rules, so it is a clean out-of-sample test:

| M5 rules, 3,600+ trades | Win rate | Avg per trade | Profit factor |
|---|---|---|---|
| Zero cost (mid price, no slippage) | 49.2% | −0.01 R | 0.98 |
| Random entries, same exits, zero cost (baseline) | 50.2% | +0.00 R | 1.01 |
| Cost like 2026 ($0.20 spread on a $8.83 stop) | 47.8% | −0.04 R | 0.92 |
| Real 2011–2018 spread ($0.31) | 41.8% | −0.17 R | 0.70 |

Same rules on M15: −0.03 R at zero cost. On H1: +0.07 R at zero cost but −0.03 R with the real spread.
Only 2013 (+0.07 R) and 2017 (+0.14 R) were positive years on M5.

**So on 2011–2018 the entry signal did no better than random.** The +25% the original author measured comes from
one 6-month window (gold's 2026 rally). It may continue, or it may have been luck. That is why the odds table has three rows.
What this test does not cover: 2019–2026 (that data was not reachable here), and Exness's own price feed.

## How to know which case you are in
Run it on an **Exness demo** (same account type) for 50–100 trades and look at the win rate
(after 100 trades it is only accurate to about ±5 points, so more trades give a clearer answer):
- **~57–60%**: you are in the good case. In the model, going live with $100 then has roughly an 80% chance of $1000.
- **~50–53%**: thin edge. Roughly a 1 in 3 chance.
- **≤ 48%**: no edge. Do not go live. The EA will slowly shrink $100 to ~$50 and stop.

## Install on Exness MT5
1. File → Open Data Folder → `MQL5/Experts`. Copy `GoldPullbackGrowth.mq5` there.
2. MetaEditor (F4) → open it → **Compile (F7)**. It passed a C++ syntax check here (`tools/mql_syntax_check`), but it
   has not been compiled in MetaEditor, so fix anything F7 reports.
3. Open an **XAUUSD** chart (any timeframe), drag the EA on, tick **Allow Algo Trading**, press **Algo Trading**.
4. Inputs: `InpServerUtcOffset = 0` is right for Exness (server time = UTC). Leave everything else on default.
5. Backtest first: Strategy Tester → GoldPullbackGrowth, XAUUSD, **Every tick based on real ticks**, deposit 100 USD,
   at least the last 6–12 months. The news filter does not work in the tester.

| Key input | Default | Meaning |
|---|---|---|
| `InpTargetEquity` / `InpStopEquity` | 1000 / 40 | Close all and stop for good (set `InpResetState = true` once to re-arm) |
| `InpRiskMode` | Max growth 5% | Risk per trade (below about $180 the 0.01 minimum lot sets the real risk) |
| `InpMinLotMaxRiskPct` | 15 | Highest real risk allowed for the 0.01 minimum lot (max 25; 20+ raises the chance of hitting the floor a lot) |
| `InpMaxDailyLossPct` / `InpMaxLossesPerDay` | 25 / 3 | Daily brakes |
| `InpMaxSpreadUSD` | 0.45 | Skip entries when ask − bid is wider |
| `InpSessionStartHour` / `EndHour` | 7 / 17 UTC | New trades only in London/New York hours |

Reproduce the research: `cd research/xau_scalper && python data.py 2011 2012 2013 2014 2015 2016 2017 2018 && python backtest.py && python odds.py`
(needs `numpy pandas numba`; downloads about 1 GB from [FX-Data/FX-Data-XAUUSD-DS](https://github.com/FX-Data/FX-Data-XAUUSD-DS)).

---

# Gold15DayChallenge — double the account in 15 days ($10 → $20, $100 → $200, $500 → $1000)

`MQL5/Experts/Gold15DayChallenge.mq5`. Attach it to XAUUSD with any balance. The target is **starting equity × 2**
(`InpTargetMultiple`). It trades for at most **15 days**, then **stops for good**: at the target, on day 15, or when the
money left cannot carry a 0.01-lot stop. Direction follows the daily trend. Entries at 07, 09, 11, 13 UTC, only when no trade is open.
No martingale, no grid. It never adds lots after a loss.

**Two sizing modes** (`InpSizing`):
- **Max chance (default, "bold play")**: each trade risks only what is still **missing** to reach the target (at most 90%
  of equity). The take profit lands **exactly on the target**, and the stop is at least $8 away so the spread costs
  little. Usually 1–2 trades. This is the mathematically best way to reach a target when there is no proven edge
  (Dubins & Savage): fewer trades means less spread paid.
- **Active**: up to 4 trades a day. Below $50: $3 stop, 1:2, 0.01 lot. From $50: $5 stop, 1:1, 50% risk.

> ⚠️ **About half of all runs double. The other half lose ~90% of the money.** This is a coin flip, not income.

**Tested odds** (1,820 fifteen-day runs per cell on 2011–2018 gold ticks, today's prices and spread;
`research/xau_scalper/bold_play.py` and `fifteen_days.py`):

| Start → target | **Max chance (default)** | Active | No-edge limit |
|---|---|---|---|
| $10 → $20 | **51.8%** (1 trade) | 41.8% (~6.5 trades) | ~50% |
| $100 → $200 | **53.8%** (~1.5 trades) | 43.2% (~12 trades) | ~50% |
| $500 → $1000 | **53.8%** (~1.5 trades) | 42.3% (~16 trades) | ~50% |

Read it honestly: from the math alone, Max chance should double about **47–48%** of the time (the spread takes the rest).
The extra few points came from the daily-trend filter in 2011–2018, a falling gold market, and may not repeat. Other
Max-chance stop sizes ($3–$12) gave 47–54%. Active mode trades more but pays the spread more often, so it doubles less.

**Can it be improved further? Tested, and no.** `research/xau_scalper/robustness.py` splits the data into 2011–14 and
2015–18, so a change has to help in both halves:
- **Stop size:** $8 was the best in both halves ($5: more spread; $12–24: slower and worse). It's already the default.
- **Direction:** the daily trend beat a random direction by ~5 points in both halves. But in this data gold fell during
  London/New York hours and rose in Asian hours: selling at 07:00 UTC doubled 55–56%, buying at 07:00 only 39–42%,
  buying at 22:00 49–52%. A "sell at 07:00, buy at 22:00" rule gave 52–54% overall, the same as now, and was worse
  than now in 2015–18 on uptrend days. So it is not a reliable improvement and is not used.
- **What to expect in 2026:** gold is in an uptrend, so the EA mostly buys. Counting only runs that started in an
  uptrend, it doubled **45% ($10) and 47% ($100)**, not 52–54%. Plan for about **45–50%**.

For bigger goals the odds fall fast. Set `InpTargetMultiple` to 5 for about 15%, or 10 for about 7–8%. Lot-size tricks
don't beat the limit: `research/xau_scalper/size_up.py` gave 8–11% for 10× with pyramiding or one big trade, and
**0% with martingale**.

| Key input | Default | Meaning |
|---|---|---|
| `InpTargetMultiple` | 2 | Target = starting equity × this (`InpTargetEquity` > 0 sets a fixed target instead) |
| `InpDays` | 15 | Stops for good after this many days |
| `InpSizing` | Max chance | or Active (3–4 trades a day) or Manual (`InpStopUSD` / `InpRR` / `InpRiskPct`) |
| `InpBoldMinStopUSD` / `InpBoldMaxLossPct` | 8 / 90 | Max chance: smallest stop and the largest loss per trade |
| `InpMaxTradesPerDay` / `InpEntryHours` | 4 / "7,9,11,13" | Trades per day and their UTC hours (Exness server = UTC) |
| `InpResetState` | false | Set true once to start a new challenge (it saves the new starting balance) |

Needs high leverage for small balances (1:1000 or more at $10). The panel shows the day, start → target, and every trade.
Install: copy it to `MQL5/Experts`, compile with F7, attach it to XAUUSD, turn on Algo Trading. It passed the syntax check here but has not been
compiled in MetaEditor.

---

# AarYaParGold — $10 aar ya paar on XAUUSD

`MQL5/Experts/AarYaParGold.mq5`. **One big trade, then it stops for good.** The stop loss is placed where the loss is
~90% of the account. The take profit is placed where the win lands exactly on the target (default **$10 → $100**).
- **PAAR:** the target is hit. It closes everything and stops. Withdraw the profit.
- **AAR:** the stop is hit. About $1 is left, too little for another trade, so it stops.

> ⚠️ **About 9 out of 10 runs lose the $10.** About 1 in 10 reach $100. This is a lottery-style bet, not income.
> Only use money you are ready to lose completely.

**How the trade is built** (gold minimum lot 0.01 = 1 oz = $1 per $1 move):
| Equity | Lots | Stop | Target | Reward:risk |
|---|---|---|---|---|
| $10 → $100 | 0.01 | ~$8.90 away (−$9) | ~$90 away (+$90) | ~10 : 1 |

- Direction: the **daily trend** (yesterday's D1 close and EMA20 both above EMA50 = buy; both below = sell; mixed = no trade
  that day). Entry once a day at **07:00 UTC** (London open, Exness server time = UTC). It keeps trying until 09:00 if the
  spread is wider than $0.60.
- It checks margin and the broker's stop-out level, so the broker can't close the trade before our stop does.
  It needs high leverage (1:1000 or more) for $10. The panel says so if the margin is too high.
- No martingale, no grid. If you raise `InpRiskPct` (e.g. 50%), it can take a second shot after a loss.

**Why one trade and not many small ones?** If a strategy has no proven edge, the best possible chance of turning $10 into
$100 is about 10 / 100 = 10%, however you split it up. Every extra trade pays the spread again. Tested on 2011–2018 gold
tick data (`research/xau_scalper/aar_ya_paar.py`, about 1,830 trials, spread at today's cost):

| How | Chance of 10× |
|---|---|
| **1 trade at 10:1, daily trend, 07:00 UTC (default)** | **11.3%** |
| 1 trade at 10:1, random direction | 9.9% |
| 2 wins in a row at 3.16:1, daily trend | 7.7% (27.8% × 27.8%) |
| 3 wins in a row at 1.27:1, daily trend | 12.4% (49.8%³) |
| 1 trade at 10:1, entry 13:00 UTC | 8.4% |

All of these sit around the 9% that pure chance gives. The trend's small lead may be luck, because gold mostly fell
in 2011–2018 (always-sell won 12.6%). Most trades are decided within the same day.

| Key input | Default | Meaning |
|---|---|---|
| `InpTargetEquity` | 100 | Goal. $10 → $1000 is possible too, but the odds are about 1%. |
| `InpRiskPct` | 90 | % of equity lost at the stop |
| `InpMaxRR` | 0 | 0 = one trade straight to the goal; e.g. 1.27 = three steps |
| `InpDirection` | Daily trend | or always buy / always sell |
| `InpEntryHourUTC` | 7 | Daily entry time |
| `InpResetState` | false | Set true once for a new attempt after a new deposit |

Install it like the EA above: copy it to `MQL5/Experts`, compile with F7, attach it to an XAUUSD chart, and turn on Algo Trading.
Syntax-checked here with `tools/mql_syntax_check` but not compiled in MetaEditor, so fix anything F7 reports.

---

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

---

# HedgeDaily Gold 2.1 — XAUUSD version

`MQL5/Experts/HedgeDailyGold.mq5`. **Needs an MT5 hedging account.** Attach it to the XAUUSD chart
(any suffix works, e.g. `XAUUSDm`, `XAUUSDc`). It holds buys and sells together, uses no stop loss on trades,
and stops for the day at the daily target, like 2.0.

## Why gold needs its own version
On 13 years of XAUUSD hourly data, **v1 blew the account within 45–82 days in every test**, and the EURUSD 2.0
settings lost 87–99.9%. Gold often moves $50–100 in a few days, so a grid spaced on the *hourly* ATR ($3–8)
fills all its levels and gets stuck. V-shaped moves also loaded buy and sell grids at the same time.

## What is different from 2.0
| Setting | 2.0 (EURUSD) | Gold 2.1 |
|---|---|---|
| Grid / TP spacing | 2 × ATR(H1) | **1.5 × ATR(D1)** (`InpATRTF`, `InpGridATR`) |
| Lot size | $300 per 0.01 lot | **% of equity lost per 1 × ATR(D1) move**, so risk stays the same at $1,300 or $4,000 gold. `InpRiskMode`: **SAFE 0.5%** (default), AGGRESSIVE 1.0%, or CUSTOM (`InpRiskPerATRPct`) |
| Trend filter | H4 EMA 50/200 | **D1 EMA 50/200** |
| Grids | both sides could fill | **only one side may build a grid at a time** (`InpOneGridOnly`) |
| Lock (10%) / hard stop (30%) drawdown | from cycle start | **from the cycle's equity peak**, so a long cycle can't hide a 40% giveback |
| Spread filter | 30 points | **3% of ATR(D1)** (gold spreads jump at rollover and news) |
| News filter | 60 / 30 min | USD high-impact news, 60 / 60 min |

## Simulation results (XAUUSD H1, 2006 – Feb 2019, real bid/ask spreads, $10,000 start)
Scripts: `research/hedge_sim/gold_tests.py` (data download steps are in `gold.py`).

| Test | v1 | 2.0 EURUSD settings | **Gold 2.1, risk 0.5 (default)** | Gold 2.1, risk 1.0 |
|---|---|---|---|---|
| 2006–2012 bull market | blown in 45 days | −99.9% | **+62.8%** (max DD 10.9%) | +293.7% (max DD 29.0%) |
| 2013–2019 crash, bear, range | blown in 82 days | −88.5% | **+17.3%** (max DD 30.7%) | +87.6% (max DD 34.1%) |
| 2006–2019 mirrored (bull ↔ bear) | blown | −99.7% | **+59.2%** (max DD 15.2%) | +101.6% (max DD 32.6%) |
| 3 random walks (no trend) | all blown | −87% … −94% | −35.6%, +10.7%, +32.1% | −68.4%, −9.7%, +31.6% |
| 2006–2019 **with swap costs** | — | — | **+16.9%** (max DD 17.4%) | **−30.6%** (max DD 60.9%) |
| Days the 1.5% daily target was hit | — | — | 0 | ≤ 5 |

Gold 2.1 (risk 0.5) year by year, 2006–2019 run: −0.4, +12.4, +2.4, +8.6, +16.3, +12.3, 0.0, 0.0, −3.7, −3.1, +2.2, +4.0, −0.5, +1.2 (%).

**How to read this honestly**
- The default settings made about **4% a year** in the simulation, not 1–2% a day. The 1.5% daily target was never reached.
- Risk 1.0 made about 12% a year, with 30–35% drawdowns, and it **lost money once swap costs were included**.
- **Swap matters a lot**: trades stay open for weeks or months. Swap costs cut +62.6% to +16.9% at risk 0.5. Use an
  Exness **swap-free** account if it is offered to you.
- No stop loss has a price. In the full run, buys from the 2011 top ($1,650–1,900) and a 2006 sell hedge stayed open
  until the data ended in 2019. The money was tied up for 7 years.
- Settings were picked on 2006–2012. The 2013–2019 data was then used to find two bugs: drawdown was measured from the
  wrong reference, and grids got stranded. It was also used to choose the safer 0.5 risk. So it is not a clean
  out-of-sample test. This is a simulation on hourly bars (no ticks, no slippage, no news filter), not a promise.

## Can it make 4–5% a day? (risk ladder)
Same Gold 2.1 logic on the same 6 tests (2006–19, mirrored, 2013–19, 3 random walks), only the risk changed.
Script: `research/hedge_sim/gold_risk_ladder.py`.

| Risk per daily ATR | Average per day | Max drawdown | Tests in profit | What happened |
|---|---|---|---|---|
| **0.5% (SAFE, default)** | −0.02% … +0.015% | 11–38% | 5 of 6 | survived every test |
| 1.0% (AGGRESSIVE) | −0.06% … +0.04% | 33–73% | 4 of 6 | survived, deep drawdowns on random data |
| 2.0% | −0.06% … −0.01% | 62–86% | 0 of 6 | the 30% hard stop fired 4–7 times per test |
| 3.0% | −0.10% … +0.05% | 56–95% | 1 of 6 | |
| 5.0% | −0.10% … −0.02% | 85–99% | 0 of 6 | |
| 8.0% | −0.24% … −0.02% | 87–100% | 0 of 6 | 4 tests lost 90% within 1.3–6 years |
| ≈50% = **0.01 lot on a $100 Standard account** at today's gold volatility | −0.40% … −0.18% | ~100% | 0 of 6 | every test lost 90% within 6–26 months |

- **The best single run in the whole ladder made about +0.06% a day, roughly 80× below 4–5% a day.** It was one lucky
  run at 5% risk; the other runs at that risk lost 54–97%. Raising the risk made results worse, not better, because
  each step up hit the hard stop more often.
- Setting the daily target to 4.5% instead of 1.5% changed almost nothing. It was reached on at most 3% of days, and
  only at risk levels that destroyed the account.
- 4% a day compounds to about 18,000× in a year (250 trading days), and 5% to about 200,000×. EAs advertised with
  4–5% daily results are grids or martingales that look smooth for weeks or months and then lose everything.
  Pick two: high daily profit, small drawdowns, no stop loss. You cannot have all three.

## Running it with $100
- Lot size = equity × risk% ÷ (ATR(D1) × 100). If that is below the broker minimum (0.01), the EA still uses 0.01 as long
  as it is at most 2× the safe size (`InpMinLotRiskCap`). Otherwise it **does not trade** and the chart shows the
  balance needed. The panel always shows "Balance needed for min lot".
- Balance needed for 0.01 lot ≈ **100 × daily ATR** (SAFE) or **50 × daily ATR** (AGGRESSIVE), in account currency.
  At a daily ATR of $60 that is 6,000 / 3,000:
  - **Exness Standard Cent account** (if available on MT5 for you): $100 = 10,000 USC, so **it runs in both modes**.
  - **$100 Standard account: it will not trade** (it would need $6,000 / $3,000). Forcing 0.01 lot with
    `InpMinLotRiskCap = 1000` is the last row of the risk ladder: every test lost 90% or more.
- Test in the MT5 Strategy Tester ("Every tick based on real ticks") on recent years, then on a demo account.
