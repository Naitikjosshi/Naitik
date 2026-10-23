# Setups a veteran actually uses on gold

None of these has a guaranteed edge. Test any of them on this repo's data
(`research/`) and on a demo account before risking money. Use ATR from the live chart;
gold's dollar volatility has grown with its price, so fixed-dollar stops from old
articles are usually too tight.

## 1. Asian range, London sweep and reversal
- Mark the 23:00-07:00 UTC high and low.
- At London open, wait for price to break one side, then close back inside on M5/M15.
- Enter toward the other side. Stop beyond the sweep extreme plus a spread buffer.
- TP1 mid-range, TP2 opposite side of the range. Skip on tier-1 news days before 13:30 UTC.

## 2. Trend pullback (H1 with H4 bias)
- H4 trend defined by structure (higher highs/lows) or EMA 50 above EMA 200.
- Wait for a pullback into a prior breakout level or the H1 EMA 20-50 zone.
- Trigger: a bullish close back in the trend direction (for an uptrend).
- Stop beyond the pullback swing; target the prior high first. Move to breakeven only after +1R.
- This is the logic in `MQL5/Experts/NaitikGrowthEA.mq5`.

## 3. News reaction (not news prediction)
- No position into the release.
- Wait 15 minutes. If price holds beyond the first-minute extreme, trade the continuation on
  the first pullback. If it fully retraces, the fade is the trade.
- Stops wider than normal, size smaller.

## 4. Prior-day high/low and round numbers
- Prior day high/low, weekly open and $50/$100 levels are where stops cluster.
- A clean break and retest of one of those levels is a continuation entry.
- A quick spike through and immediate rejection is a reversal entry.

## 5. Late-NY fade after a trend day
- After a large NY trend move, the 15:00 London fix and later hours often bring a partial
  retracement. Small size, quick target, only with the higher-timeframe bias.

## Trade management
- Decide the plan before entry; don't widen a stop after entry.
- Partial at 1R-1.5R is fine; let the rest run to structure.
- Max 2-3 trades a day. After two losses in a row, stop for the day.
- Journal every trade: setup, reason, screenshot, R result, rule broken (if any).

## Things that look like edges and aren't
- Martingale / doubling after losses: wins often, then one trend day empties the account.
- Grids and hedges without stops: same thing, slower.
- Very tight stops to "afford" bigger lots on a small account: noise stops you out, then spread and slippage cost more than you make.
- Backtests without spread, swap and slippage, or tuned on the same data they report.
