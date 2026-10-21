//+------------------------------------------------------------------+
//|                                          GoldPullbackGrowth.mq5  |
//|  XAUUSD M5 trend-pullback scalper with a $100 -> $1000 growth    |
//|  plan, written for an Exness MT5 Pro account.                    |
//|                                                                  |
//|  Entry rules follow the trend-pullback study published in        |
//|  github.com/andamagodwin/forex (README "What the research        |
//|  actually found": M5, ADX >= 25, RR 1.0, no break-even, no       |
//|  trailing stop). The code here is an independent implementation |
//|  of those published rules, not a copy of that project's code.   |
//|                                                                  |
//|  Rules (long; short is the mirror image), on the CLOSED M5 bar:  |
//|   trend    : close > EMA200 and EMA21 > EMA200                   |
//|   pullback : a low touched EMA21 within the last 5 bars          |
//|   resume   : bar closes above EMA9, bullish, EMA9 > EMA21        |
//|   momentum : RSI(14) in 45..70 and rising, ADX(14) >= 25         |
//|   quality  : bar range <= 3 x ATR, spread <= $0.45, 07-17 UTC    |
//|   exits    : SL max(1.5 x ATR, $1.50), TP 1.0 x SL, 60-bar time  |
//|              stop, flat at 21:00 UTC and on Friday cut-off       |
//|                                                                  |
//|  Changes for a small account (the reason this file exists):      |
//|   - risk modes 1% / 3% / 5% of equity, sized with OrderCalcProfit|
//|     (default 5%: best odds of $1000 in research/xau_scalper)     |
//|   - the broker minimum lot is used only when its REAL risk is    |
//|     at most InpMinLotMaxRiskPct (the original EA silently traded |
//|     the minimum lot at any risk)                                 |
//|   - stops for good at the $1000 target or the $40 equity floor   |
//|   - risk halves while equity is 25% below its peak               |
//|   - daily loss limit on equity, max losses per day, cooldown     |
//|   - margin, stop-level, freeze-level, stale-quote, news filters, |
//|     retries on requotes, SL repair, never widens a stop          |
//|                                                                  |
//|  No martingale, no grid, no averaging down. Nothing here can     |
//|  guarantee $1000; see README for the measured odds.              |
//+------------------------------------------------------------------+
#property copyright "Naitik"
#property version   "1.00"
#property description "XAUUSD M5 trend-pullback scalper with a $100 -> $1000 growth plan (no martingale, no grid)."
#property description "Stops at the target or the equity floor. Attach to XAUUSD; signals always use M5."

#include <Trade\Trade.mqh>

enum ENUM_GROWTH_RISK
{
   RISK_STANDARD = 0, // Standard: 1% of equity per trade
   RISK_GROWTH   = 1, // Growth: 3% of equity per trade
   RISK_TURBO    = 2, // Max growth: 5% of equity per trade (best odds of the target in tests)
   RISK_CUSTOM   = 3  // Custom: InpCustomRiskPct
};

enum ENUM_GOAL_STATE
{
   GOAL_RUNNING = 0,
   GOAL_TARGET  = 1,
   GOAL_FLOOR   = 2
};

input group "Goal"
input double InpTargetEquity      = 1000.0; // Close all and stop for good at this equity (0 = off)
input double InpStopEquity        = 40.0;   // Close all and stop for good at this equity (0 = off)
input bool   InpResetState        = false;  // Set true once to re-arm after a target/floor stop

input group "Risk"
input ENUM_GROWTH_RISK InpRiskMode = RISK_TURBO; // Risk per trade
input double InpCustomRiskPct     = 2.0;    // Custom risk % of equity (max 10)
input double InpMinLotMaxRiskPct  = 15.0;   // Allow the broker minimum lot up to this real risk % (0 = never, max 25)
input double InpDDBrakePct        = 25.0;   // Halve risk while equity is this % below its peak (0 = off)
input double InpMaxDailyLossPct   = 25.0;   // No new trades today after equity falls this % from day start
input int    InpMaxLossesPerDay   = 3;      // No new trades today after this many losing trades
input int    InpMaxTradesPerDay   = 8;      // Max entries per UTC day
input int    InpCooldownBars      = 5;      // M5 bars to wait after a losing trade
input double InpCommissionPerLot  = 0.0;    // Round-turn commission per lot in account currency (Exness Pro: 0)
input double InpSlippageUSD       = 0.05;   // Extra stop slippage per oz included in the risk
input double InpMaxLot            = 5.0;    // Hard lot cap

input group "Strategy (M5 trend pullback)"
input ENUM_TIMEFRAMES InpTF       = PERIOD_M5; // Signal timeframe (validated on M5)
input int    InpEmaFast           = 9;      // Fast EMA
input int    InpEmaSlow           = 21;     // Pullback EMA
input int    InpEmaTrend          = 200;    // Trend EMA
input int    InpAtrPeriod         = 14;     // ATR period
input int    InpRsiPeriod         = 14;     // RSI period
input int    InpAdxPeriod         = 14;     // ADX (Wilder) period
input int    InpPullbackBars      = 5;      // Bars in which price must touch the pullback EMA
input double InpRsiLongMin        = 45.0;   // Long: RSI minimum
input double InpRsiLongMax        = 70.0;   // Long: RSI maximum
input double InpRsiShortMin       = 30.0;   // Short: RSI minimum
input double InpRsiShortMax       = 55.0;   // Short: RSI maximum
input double InpAdxMin            = 25.0;   // Minimum ADX (trend strength)
input double InpMaxBarRangeAtr    = 3.0;    // Skip signal bars wider than this x ATR (news spikes)
input int    InpWarmupBars        = 400;    // Bars of history needed before trading

input group "Exits"
input double InpSlAtrMult         = 1.5;    // Stop = ATR x this
input double InpMinSlUSD          = 1.50;   // Stop never tighter than this (USD per oz)
input double InpTpRR              = 1.0;    // Target = stop distance x this
input double InpBeTriggerR        = 0.0;    // Move stop to break-even at this R (0 = off, tested better)
input double InpBeLockUSD         = 0.10;   // Break-even stop sits this far past entry
input double InpTrailAtrMult      = 0.0;    // ATR trailing stop after break-even (0 = off)
input int    InpMaxHoldBars       = 60;     // Time stop in signal bars

input group "Session (UTC)"
input int    InpServerUtcOffset   = 0;      // Server time minus UTC in hours (Exness = 0; 99 = auto, live only)
input int    InpSessionStartHour  = 7;      // New trades from this UTC hour
input int    InpSessionEndHour    = 17;     // No new trades from this UTC hour
input int    InpFridayCutoffHour  = 15;     // No new trades on Friday from this UTC hour
input int    InpForceCloseHour    = 21;     // Close open trades at this UTC hour

input group "Execution filters"
input double InpMaxSpreadUSD      = 0.45;   // Skip entries when ask - bid is wider (USD per oz)
input int    InpDeviationPoints   = 0;      // Max slippage in points (0 = auto, $0.30)
input int    InpEntryWindowSec    = 60;     // Keep trying a signal this long into the new bar
input int    InpStaleQuoteSec     = 30;     // Skip entries if the last quote is older (live only)
input double InpMarginBuffer      = 1.5;    // Free margin must cover the margin x this
input bool   InpUseNews           = true;   // Pause entries around high-impact USD news (live only)
input int    InpNewsBeforeMin     = 30;     // Minutes before the event
input int    InpNewsAfterMin      = 30;     // Minutes after the event

input group "General"
input ulong  InpMagic             = 20261022; // Magic number
input string InpComment           = "GPG";    // Order comment
input bool   InpShowPanel         = true;     // Show the chart panel

//--- globals
CTrade   trade;
int      hEmaFast = INVALID_HANDLE, hEmaSlow = INVALID_HANDLE, hEmaTrend = INVALID_HANDLE;
int      hAtr = INVALID_HANDLE, hRsi = INVALID_HANDLE, hAdx = INVALID_HANDLE;
string   g_prefix;
bool     g_tester = false;

datetime g_lastBar        = 0;
int      g_goalState      = GOAL_RUNNING;
double   g_peakEquity     = 0.0;

int      g_dayKey         = 0;
double   g_dayStartEquity = 0.0;
int      g_dayEntries     = 0;
int      g_dayLosses      = 0;
double   g_dayClosedPnl   = 0.0;
datetime g_cooldownUntil  = 0;
bool     g_historyDirty   = true;

int      g_pendingSide    = 0;      // signal waiting for a tradable quote
datetime g_pendingBar     = 0;      // bar the signal belongs to
datetime g_lastEntryBar   = 0;      // one entry per signal bar
double   g_pendingAtr     = 0.0;

datetime g_newsLoaded     = 0;
datetime g_newsTimes[];
string   g_newsNames[];

string   g_status         = "starting";
string   g_lastMsg        = "";
datetime g_lastPanel      = 0;

//+------------------------------------------------------------------+
//| Persistent state (terminal global variables)                     |
//+------------------------------------------------------------------+
double GV(const string key, const double def = 0.0)
{
   string name = g_prefix + key;
   return GlobalVariableCheck(name) ? GlobalVariableGet(name) : def;
}

void GVSet(const string key, const double value)
{
   GlobalVariableSet(g_prefix + key, value);
}

void GVDel(const string key)
{
   string name = g_prefix + key;
   if(GlobalVariableCheck(name))
      GlobalVariableDel(name);
}

void LogMsg(const string msg)
{
   g_lastMsg = msg;
   Print("[GPG] ", msg);
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_tester = (MQLInfoInteger(MQL_TESTER) != 0);
   if(InpCustomRiskPct <= 0.0 || InpCustomRiskPct > 10.0 || InpMinLotMaxRiskPct < 0.0 || InpMinLotMaxRiskPct > 25.0 ||
      InpTpRR <= 0.0 || InpSlAtrMult <= 0.0 || InpPullbackBars < 1 || InpMaxHoldBars < 1 ||
      InpSessionStartHour < 0 || InpSessionEndHour > 24 || InpSessionStartHour >= InpSessionEndHour ||
      InpForceCloseHour < 1 || InpForceCloseHour > 24 || InpMaxSpreadUSD <= 0.0 || InpMarginBuffer < 1.0)
   {
      Print("[GPG] Invalid inputs: custom risk must be 0-10%, min-lot cap 0-25%, sessions 0-24 with start < end");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpStopEquity > 0.0 && InpTargetEquity > 0.0 && InpStopEquity >= InpTargetEquity)
   {
      Print("[GPG] Invalid inputs: the equity floor must be below the target");
      return INIT_PARAMETERS_INCORRECT;
   }

   string sym = _Symbol;
   StringToUpper(sym);
   if(StringFind(sym, "XAU") < 0 && StringFind(sym, "GOLD") < 0)
      Print("[GPG] Warning: built and tested for XAUUSD; ", _Symbol, " is not a gold symbol");

   g_prefix = StringFormat("GPG_%s%I64d_%I64u_%s_", g_tester ? "T_" : "", AccountInfoInteger(ACCOUNT_LOGIN), InpMagic, _Symbol);
   if(g_tester || InpResetState)
   {
      GVDel("goal");
      GVDel("peak");
      if(InpResetState)
         Print("[GPG] State reset: goal flag and equity peak cleared");
   }
   g_goalState  = (int)GV("goal", GOAL_RUNNING);
   g_peakEquity = MathMax(GV("peak", 0.0), AccountInfoDouble(ACCOUNT_EQUITY));
   GVSet("peak", g_peakEquity);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_goalState == GOAL_RUNNING && InpTargetEquity > 0.0 && equity >= InpTargetEquity)
   {
      PrintFormat("[GPG] Equity %.2f is already at the target %.2f: raise InpTargetEquity", equity, InpTargetEquity);
      return INIT_PARAMETERS_INCORRECT;
   }

   ulong dev = (InpDeviationPoints > 0) ? (ulong)InpDeviationPoints : (ulong)MathMax(10.0, MathRound(0.30 / SymPoint()));
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(dev);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetMarginMode();
   trade.SetAsyncMode(false);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   hEmaFast  = iMA(_Symbol, InpTF, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow  = iMA(_Symbol, InpTF, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hEmaTrend = iMA(_Symbol, InpTF, InpEmaTrend, 0, MODE_EMA, PRICE_CLOSE);
   hAtr      = iATR(_Symbol, InpTF, InpAtrPeriod);
   hRsi      = iRSI(_Symbol, InpTF, InpRsiPeriod, PRICE_CLOSE);
   hAdx      = iADXWilder(_Symbol, InpTF, InpAdxPeriod);
   if(hEmaFast == INVALID_HANDLE || hEmaSlow == INVALID_HANDLE || hEmaTrend == INVALID_HANDLE ||
      hAtr == INVALID_HANDLE || hRsi == INVALID_HANDLE || hAdx == INVALID_HANDLE)
   {
      Print("[GPG] Failed to create indicator handles, error ", GetLastError());
      return INIT_FAILED;
   }

   PrintFormat("[GPG] %s | digits %d, point %g, tick size %g, contract %g, lots %g-%g step %g, stops level %d, freeze level %d pts",
               _Symbol, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS), SymPoint(),
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP), (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL));
   PrintFormat("[GPG] Risk %s, target %.2f, floor %.2f, equity %.2f %s, state %s",
               RiskName(), InpTargetEquity, InpStopEquity, equity, AccountInfoString(ACCOUNT_CURRENCY), GoalName());
   if(InpServerUtcOffset != 99 && !g_tester)
   {
      int live = (int)MathRound((double)(TimeTradeServer() - TimeGMT()) / 3600.0);
      if(live != InpServerUtcOffset)
         PrintFormat("[GPG] Warning: server looks like UTC%+d but InpServerUtcOffset = %d; session hours will be shifted",
                     live, InpServerUtcOffset);
   }
   g_historyDirty = true;
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hEmaFast);
   IndicatorRelease(hEmaSlow);
   IndicatorRelease(hEmaTrend);
   IndicatorRelease(hAtr);
   IndicatorRelease(hRsi);
   IndicatorRelease(hAdx);
   if(!g_tester)
      GlobalVariablesFlush();
   Comment("");
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
      g_historyDirty = true;
}

//+------------------------------------------------------------------+
void OnTick()
{
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk) || tk.bid <= 0.0 || tk.ask <= 0.0 || tk.ask < tk.bid)
      return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_peakEquity)
   {
      g_peakEquity = equity;
      GVSet("peak", g_peakEquity);
   }

   UpdateDay(equity);
   if(g_historyDirty)
      RefreshDayFromHistory();

   if(CheckGoal(equity))
   {
      ShowPanel(tk, equity, true);
      return;
   }

   // manage first: a time stop on this tick must not block a fresh signal as "position open"
   ManagePosition(tk);

   datetime bar0 = iTime(_Symbol, InpTF, 0);
   if(bar0 > 0 && bar0 != g_lastBar)
   {
      g_lastBar = bar0;
      OnNewBar(equity);
   }

   TryPendingEntry(tk, equity);
   ShowPanel(tk, equity, false);
}

//+------------------------------------------------------------------+
//| Symbol helpers                                                    |
//+------------------------------------------------------------------+
double SymPoint()
{
   double p = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return (p > 0.0) ? p : _Point;
}

double NormPrice(const double price)
{
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double p = price;
   if(ts > 0.0)
      p = MathRound(p / ts) * ts;
   return NormalizeDouble(p, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

int VolumeDigits(const double step)
{
   int d = 0;
   double s = step;
   while(d < 8 && MathAbs(s - MathRound(s)) > 1e-9)
   {
      s *= 10.0;
      d++;
   }
   return d;
}

// Round DOWN to the broker's volume step; 0 if below the minimum
double FloorVolume(const double lots)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), InpMaxLot);
   if(step <= 0.0 || vmin <= 0.0 || lots <= 0.0)
      return 0.0;
   double v = MathFloor(lots / step + 1e-7) * step;
   if(v > vmax)
      v = MathFloor(vmax / step + 1e-7) * step;
   v = NormalizeDouble(v, VolumeDigits(step));
   return (v + 1e-9 < vmin) ? 0.0 : v;
}

double StopsLevelPrice()
{
   return (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * SymPoint();
}

double FreezeLevelPrice()
{
   return (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * SymPoint();
}

// Money lost by 1.0 lot from entry to stop, including slippage and commission
double LossPerLot(const int side, const double entry, const double sl)
{
   double slipSl = (side > 0) ? sl - InpSlippageUSD : sl + InpSlippageUSD;
   double profit = 0.0;
   double loss = 0.0;
   if(OrderCalcProfit(side > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, entry, slipSl, profit) && profit < 0.0)
      loss = -profit;
   else
   {
      double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tv <= 0.0)
         tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(ts <= 0.0 || tv <= 0.0)
         return 0.0;
      loss = MathAbs(entry - slipSl) / ts * tv;
   }
   return loss + MathMax(0.0, InpCommissionPerLot);
}

//+------------------------------------------------------------------+
//| Time helpers: sessions are defined in UTC                        |
//+------------------------------------------------------------------+
int ServerOffsetSec()
{
   if(InpServerUtcOffset == 99 && !g_tester)
      return (int)MathRound((double)(TimeTradeServer() - TimeGMT()) / 3600.0) * 3600;
   if(InpServerUtcOffset == 99)
      return 0;
   return InpServerUtcOffset * 3600;
}

datetime UtcNow()
{
   return TimeCurrent() - ServerOffsetSec();
}

int DayKey(const datetime utc)
{
   MqlDateTime t;
   TimeToStruct(utc, t);
   return t.year * 10000 + t.mon * 100 + t.day;
}

datetime UtcDayStart(const datetime utc)
{
   return utc - (utc % 86400);
}

bool InEntrySession(const datetime utc)
{
   MqlDateTime t;
   TimeToStruct(utc, t);
   if(t.day_of_week == 0 || t.day_of_week == 6)
      return false;
   if(t.hour < InpSessionStartHour || t.hour >= InpSessionEndHour)
      return false;
   if(t.day_of_week == 5 && t.hour >= InpFridayCutoffHour)
      return false;
   return true;
}

// Seconds until the symbol's current trade session ends (broker session table, server time).
// -1 = market closed now, 86400 = no break today.
int SecondsToSessionEnd()
{
   datetime now = TimeTradeServer();
   MqlDateTime t;
   TimeToStruct(now, t);
   int sec = t.hour * 3600 + t.min * 60 + t.sec;
   bool any = false;
   for(uint i = 0; i < 10; i++)
   {
      datetime from = 0, to = 0;
      if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)t.day_of_week, i, from, to))
         break;
      any = true;
      int f = (int)from, e = (int)to;
      if(sec >= f && sec < e)
         return (e >= 86400) ? 86400 : e - sec;
   }
   return any ? -1 : 86400;
}

bool MustFlatten(const datetime utc)
{
   MqlDateTime t;
   TimeToStruct(utc, t);
   if(t.hour >= InpForceCloseHour || t.day_of_week == 0 || t.day_of_week == 6)
      return true;
   int left = SecondsToSessionEnd();
   return left >= 0 && left <= 10 * 60;   // close before the broker's daily break
}

//+------------------------------------------------------------------+
//| Day state, rebuilt from deal history so restarts are safe.       |
//| Trades are flat by 21:00 UTC, so the balance at the day start is |
//| the current balance minus today's closed P/L.                    |
//+------------------------------------------------------------------+
void UpdateDay(const double equity)
{
   int key = DayKey(UtcNow());
   if(key == g_dayKey)
      return;
   g_dayKey = key;
   RefreshDayFromHistory();
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_BALANCE) - g_dayClosedPnl;
   if(g_dayStartEquity <= 0.0)
      g_dayStartEquity = equity;
   PrintFormat("[GPG] New UTC day %d: start equity %.2f, entries %d, losses %d", key, g_dayStartEquity, g_dayEntries, g_dayLosses);
}

void RefreshDayFromHistory()
{
   g_historyDirty = false;
   datetime from = UtcDayStart(UtcNow()) + ServerOffsetSec();
   if(!HistorySelect(from, TimeCurrent() + 86400))
   {
      g_historyDirty = true;
      return;
   }
   int total = HistoryDealsTotal();
   long   posIds[];
   double posPnl[];
   datetime posClose[];
   int entries = 0;
   double closed = 0.0;
   for(int i = 0; i < total; i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != (long)InpMagic || HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol)
         continue;
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      double net = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) +
                   HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
      closed += net;
      if(entry == DEAL_ENTRY_IN)
         entries++;
      long pid = HistoryDealGetInteger(d, DEAL_POSITION_ID);
      int k = ArraySize(posIds) - 1;
      while(k >= 0 && posIds[k] != pid)
         k--;
      if(k < 0)
      {
         k = ArraySize(posIds);
         ArrayResize(posIds, k + 1);
         ArrayResize(posPnl, k + 1);
         ArrayResize(posClose, k + 1);
         posIds[k] = pid;
         posPnl[k] = 0.0;
         posClose[k] = 0;
      }
      posPnl[k] += net;
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT || entry == DEAL_ENTRY_OUT_BY)
         posClose[k] = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
   }
   int losses = 0;
   datetime lastClose = 0;
   double lastPnl = 0.0;
   for(int k = 0; k < ArraySize(posIds); k++)
   {
      if(posClose[k] == 0 || HasOpenPosition(posIds[k]))
         continue;
      if(posPnl[k] < 0.0)
         losses++;
      if(posClose[k] >= lastClose)
      {
         lastClose = posClose[k];
         lastPnl = posPnl[k];
      }
   }
   g_dayEntries = entries;
   g_dayLosses = losses;
   g_dayClosedPnl = closed;
   if(lastClose > 0 && lastPnl < 0.0)
   {
      datetime until = lastClose + (datetime)(InpCooldownBars * PeriodSeconds(InpTF));
      if(until > g_cooldownUntil)
         g_cooldownUntil = until;
   }
}

bool HasOpenPosition(const long positionId)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetInteger(POSITION_IDENTIFIER) == positionId)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Goal: stop for good at the target or the floor                   |
//+------------------------------------------------------------------+
bool CheckGoal(const double equity)
{
   if(g_goalState == GOAL_RUNNING)
   {
      if(InpTargetEquity > 0.0 && equity >= InpTargetEquity)
      {
         g_goalState = GOAL_TARGET;
         LogMsg(StringFormat("TARGET reached: equity %.2f >= %.2f. Closing and stopping for good.", equity, InpTargetEquity));
      }
      else if(InpStopEquity > 0.0 && equity <= InpStopEquity)
      {
         g_goalState = GOAL_FLOOR;
         LogMsg(StringFormat("Equity floor hit: %.2f <= %.2f. Closing and stopping for good.", equity, InpStopEquity));
      }
      if(g_goalState != GOAL_RUNNING)
      {
         GVSet("goal", g_goalState);
         if(!g_tester)
            GlobalVariablesFlush();
      }
   }
   if(g_goalState == GOAL_RUNNING)
      return false;
   g_pendingSide = 0;
   CloseOurPositions("goal");
   g_status = (g_goalState == GOAL_TARGET) ? "TARGET REACHED - stopped (InpResetState to re-arm)"
                                           : "EQUITY FLOOR - stopped (InpResetState to re-arm)";
   return true;
}

string GoalName()
{
   if(g_goalState == GOAL_TARGET)
      return "target reached";
   if(g_goalState == GOAL_FLOOR)
      return "floor hit";
   return "running";
}

//+------------------------------------------------------------------+
//| Risk                                                              |
//+------------------------------------------------------------------+
double BaseRiskPct()
{
   switch(InpRiskMode)
   {
      case RISK_STANDARD: return 1.0;
      case RISK_GROWTH:   return 3.0;
      case RISK_TURBO:    return 5.0;
      default:            break;
   }
   return InpCustomRiskPct;
}

bool BrakeActive(const double equity)
{
   return InpDDBrakePct > 0.0 && g_peakEquity > 0.0 && equity < g_peakEquity * (1.0 - InpDDBrakePct / 100.0);
}

double CurrentRiskPct(const double equity)
{
   double r = BaseRiskPct();
   if(BrakeActive(equity))
      r *= 0.5;
   return r;
}

string RiskName()
{
   switch(InpRiskMode)
   {
      case RISK_STANDARD: return "Standard 1%";
      case RISK_GROWTH:   return "Growth 3%";
      case RISK_TURBO:    return "Max growth 5%";
      default:            break;
   }
   return StringFormat("Custom %.2f%%", InpCustomRiskPct);
}

// Lots for this stop, or 0 with the reason in why
double LotsForTrade(const int side, const double entry, const double sl, const double equity, string &why)
{
   double lpl = LossPerLot(side, entry, sl);
   if(lpl <= 0.0 || equity <= 0.0)
   {
      why = "cannot price the stop (tick value missing)";
      return 0.0;
   }
   double riskPct = CurrentRiskPct(equity);
   double lots = FloorVolume(equity * riskPct / 100.0 / lpl);
   if(lots <= 0.0)
   {
      double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double minRiskPct = vmin * lpl / equity * 100.0;
      if(InpMinLotMaxRiskPct > 0.0 && minRiskPct <= InpMinLotMaxRiskPct)
      {
         lots = FloorVolume(vmin);
         LogMsg(StringFormat("Min lot %.2f risks %.2f%% (> %.2f%% plan, <= %.2f%% cap): using it", vmin, minRiskPct, riskPct, InpMinLotMaxRiskPct));
      }
      else
      {
         why = StringFormat("min lot %.2f would risk %.2f (%.1f%% of equity) > cap %.1f%%; equity needed %.2f",
                            vmin, vmin * lpl, minRiskPct, InpMinLotMaxRiskPct,
                            InpMinLotMaxRiskPct > 0.0 ? vmin * lpl * 100.0 / InpMinLotMaxRiskPct : vmin * lpl * 100.0 / riskPct);
         return 0.0;
      }
   }
   // margin: shrink to what free margin can carry with a buffer
   double margin = 0.0;
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(OrderCalcMargin(side > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, entry, margin) && margin > 0.0 &&
      margin * InpMarginBuffer > freeMargin)
   {
      double fit = FloorVolume(lots * freeMargin / (margin * InpMarginBuffer));
      if(fit <= 0.0)
      {
         why = StringFormat("not enough margin: need %.2f x %.1f, free %.2f", margin, InpMarginBuffer, freeMargin);
         return 0.0;
      }
      lots = fit;
   }
   return lots;
}

// Equity at which the minimum lot fits the risk cap, for the panel
double EquityNeededForMinLot(const double slDist)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0.0 || slDist <= 0.0)
      return 0.0;
   double lpl = LossPerLot(1, ask, ask - slDist);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double cap = (InpMinLotMaxRiskPct > 0.0) ? MathMax(InpMinLotMaxRiskPct, BaseRiskPct()) : BaseRiskPct();
   return vmin * lpl * 100.0 / cap;
}

//+------------------------------------------------------------------+
//| Signal on the last closed bar                                     |
//+------------------------------------------------------------------+
bool CopyIndicator(const int handle, const int count, double &buf[])
{
   ArraySetAsSeries(buf, true);
   return CopyBuffer(handle, 0, 1, count, buf) == count;
}

// +1 long, -1 short, 0 none. atr receives ATR of the signal bar.
int ComputeSignal(double &atr, string &why)
{
   int n = InpPullbackBars;
   double emaF[];
   double emaS[];
   double emaT[];
   double atrB[];
   double rsiB[];
   double adxB[];
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(!CopyIndicator(hEmaFast, 1, emaF) || !CopyIndicator(hEmaSlow, n, emaS) || !CopyIndicator(hEmaTrend, 1, emaT) ||
      !CopyIndicator(hAtr, 1, atrB) || !CopyIndicator(hRsi, 2, rsiB) || !CopyIndicator(hAdx, 1, adxB) ||
      CopyRates(_Symbol, InpTF, 1, n, r) != n)
   {
      why = "indicator data not ready";
      return 0;
   }
   atr = atrB[0];
   if(atr <= 0.0 || !MathIsValidNumber(atr) || !MathIsValidNumber(emaT[0]) || !MathIsValidNumber(adxB[0]))
   {
      why = "invalid indicator values";
      return 0;
   }
   double o = r[0].open, h = r[0].high, l = r[0].low, c = r[0].close;

   bool bull = c > emaT[0] && emaS[0] > emaT[0];
   bool bear = c < emaT[0] && emaS[0] < emaT[0];
   bool touchL = false, touchS = false;
   for(int k = 0; k < n; k++)
   {
      if(r[k].low <= emaS[k])
         touchL = true;
      if(r[k].high >= emaS[k])
         touchS = true;
   }
   bool resumeL = c > emaF[0] && c > o && emaF[0] > emaS[0];
   bool resumeS = c < emaF[0] && c < o && emaF[0] < emaS[0];
   bool rsiL = rsiB[0] >= InpRsiLongMin && rsiB[0] <= InpRsiLongMax && rsiB[0] > rsiB[1];
   bool rsiS = rsiB[0] >= InpRsiShortMin && rsiB[0] <= InpRsiShortMax && rsiB[0] < rsiB[1];

   int side = 0;
   if(bull && touchL && resumeL && rsiL)
      side = 1;
   else if(bear && touchS && resumeS && rsiS)
      side = -1;
   if(side == 0)
   {
      why = "no setup";
      return 0;
   }
   if(adxB[0] < InpAdxMin)
   {
      why = StringFormat("%s setup but ADX %.1f < %.1f (no trend)", side > 0 ? "BUY" : "SELL", adxB[0], InpAdxMin);
      return 0;
   }
   if(h - l > InpMaxBarRangeAtr * atr)
   {
      why = StringFormat("%s setup but bar range %.2f > %.1f x ATR %.2f (spike)", side > 0 ? "BUY" : "SELL", h - l, InpMaxBarRangeAtr, atr);
      return 0;
   }
   why = StringFormat("%s setup: close %.2f, EMA9 %.2f, EMA21 %.2f, EMA200 %.2f, RSI %.1f, ADX %.1f, ATR %.2f",
                      side > 0 ? "BUY" : "SELL", c, emaF[0], emaS[0], emaT[0], rsiB[0], adxB[0], atr);
   return side;
}

//+------------------------------------------------------------------+
//| Gates that block NEW entries (not the management of open ones)   |
//+------------------------------------------------------------------+
string EntryBlockReason(const double equity)
{
   datetime utc = UtcNow();
   if(!InEntrySession(utc) || MustFlatten(utc))
      return "outside session";
   int left = SecondsToSessionEnd();
   if(left < 0)
      return "market closed";
   if(left < 30 * 60)
      return "broker session ends in < 30 min";
   if(CountOurPositions() > 0)
      return "position already open";
   if(g_dayStartEquity > 0.0 && (g_dayStartEquity - equity) / g_dayStartEquity * 100.0 >= InpMaxDailyLossPct)
      return StringFormat("daily loss limit %.1f%% reached", InpMaxDailyLossPct);
   if(InpMaxLossesPerDay > 0 && g_dayLosses >= InpMaxLossesPerDay)
      return StringFormat("%d losing trades today", g_dayLosses);
   if(InpMaxTradesPerDay > 0 && g_dayEntries >= InpMaxTradesPerDay)
      return StringFormat("max %d trades today", InpMaxTradesPerDay);
   if(TimeCurrent() < g_cooldownUntil)
      return "cooldown after a loss until " + TimeToString(g_cooldownUntil, TIME_MINUTES);
   string ev;
   if(NewsBlocked(ev))
      return "news: " + ev;
   return "";
}

void OnNewBar(const double equity)
{
   g_pendingSide = 0;
   RefreshDayFromHistory();
   if(Bars(_Symbol, InpTF) < InpWarmupBars)
   {
      g_status = "warming up history";
      return;
   }
   double atr = 0.0;
   string why;
   int side = ComputeSignal(atr, why);
   string block = EntryBlockReason(equity);
   g_status = (block == "") ? "scanning" : block;
   if(side == 0)
   {
      if(why != "no setup")
         LogMsg("Skip: " + why);
      return;
   }
   datetime signalBar = iTime(_Symbol, InpTF, 1);
   if(signalBar == g_lastEntryBar)
   {
      LogMsg("Skip: already traded this signal bar");
      return;
   }
   if(block != "")
   {
      LogMsg(why + " | skipped: " + block);
      return;
   }
   LogMsg(why);
   g_pendingSide = side;
   g_pendingBar  = signalBar;
   g_pendingAtr  = atr;
}

//+------------------------------------------------------------------+
//| Entry                                                             |
//+------------------------------------------------------------------+
void TryPendingEntry(const MqlTick &tk, const double equity)
{
   if(g_pendingSide == 0)
      return;
   if(TimeCurrent() - g_lastBar > InpEntryWindowSec)
   {
      LogMsg("Signal expired: no tradable quote within the entry window");
      g_pendingSide = 0;
      return;
   }
   double spread = tk.ask - tk.bid;
   if(spread > InpMaxSpreadUSD)
   {
      g_status = StringFormat("waiting: spread %.2f > %.2f", spread, InpMaxSpreadUSD);
      return;
   }
   if(!g_tester && InpStaleQuoteSec > 0 && TimeTradeServer() - tk.time > InpStaleQuoteSec)
   {
      g_status = "waiting: stale quote";
      return;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      g_status = "algo trading is disabled";
      return;
   }
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY ||
      (mode == SYMBOL_TRADE_MODE_LONGONLY && g_pendingSide < 0) || (mode == SYMBOL_TRADE_MODE_SHORTONLY && g_pendingSide > 0))
   {
      LogMsg("Skip: symbol trade mode does not allow this direction");
      g_pendingSide = 0;
      return;
   }
   string block = EntryBlockReason(equity);
   if(block != "")
   {
      LogMsg("Skip: " + block);
      g_pendingSide = 0;
      return;
   }

   int side = g_pendingSide;
   g_pendingSide = 0;   // one attempt sequence per signal
   OpenTrade(side, g_pendingAtr, equity);
}

void OpenTrade(const int side, const double atr, const double equity)
{
   double slDist = MathMax(InpSlAtrMult * atr, InpMinSlUSD);
   slDist = MathMax(slDist, StopsLevelPrice() + 2.0 * SymPoint());
   for(int attempt = 0; attempt < 3; attempt++)
   {
      MqlTick tk;
      if(!SymbolInfoTick(_Symbol, tk))
         return;
      double entry = (side > 0) ? tk.ask : tk.bid;
      double sl = NormPrice(side > 0 ? entry - slDist : entry + slDist);
      double tp = NormPrice(side > 0 ? entry + InpTpRR * slDist : entry - InpTpRR * slDist);
      double minDist = StopsLevelPrice();
      if((side > 0 && (tk.bid - sl <= minDist || tp - tk.bid <= minDist)) ||
         (side < 0 && (sl - tk.ask <= minDist || tk.ask - tp <= minDist)))
      {
         LogMsg(StringFormat("Skip: stops too close for the broker stop level (%.2f)", minDist));
         return;
      }
      string why;
      double lots = LotsForTrade(side, entry, sl, equity, why);
      if(lots <= 0.0)
      {
         LogMsg("Risk rejection: " + why);
         return;
      }
      double riskMoney = lots * LossPerLot(side, entry, sl);

      bool sent = (side > 0) ? trade.Buy(lots, _Symbol, entry, sl, tp, InpComment)
                             : trade.Sell(lots, _Symbol, entry, sl, tp, InpComment);
      uint rc = trade.ResultRetcode();
      if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED))
      {
         g_lastEntryBar = g_pendingBar;
         g_dayEntries++;
         LogMsg(StringFormat("%s %.2f lots @ %.2f | SL %.2f TP %.2f | stop $%.2f/oz | risk %.2f (%.2f%%) | spread %.2f",
                          side > 0 ? "BUY" : "SELL", lots, trade.ResultPrice(), sl, tp, slDist, riskMoney,
                          riskMoney / equity * 100.0, tk.ask - tk.bid));
         CheckFillSlippage(side, sl, lots, riskMoney);
         return;
      }
      LogMsg(StringFormat("Order failed (try %d): %u %s", attempt + 1, rc, trade.ResultRetcodeDescription()));
      if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_PRICE_CHANGED && rc != TRADE_RETCODE_PRICE_OFF)
         return;   // not a price problem: do not hammer the server
   }
}

// A fill far worse than planned makes the stop risk more than intended: close at once
void CheckFillSlippage(const int side, const double sl, const double lots, const double plannedRisk)
{
   double fill = trade.ResultPrice();
   if(fill <= 0.0 || plannedRisk <= 0.0)
      return;
   double actual = lots * LossPerLot(side, fill, sl);
   if(actual > plannedRisk * 1.5)
   {
      LogMsg(StringFormat("Fill %.2f slipped: risk %.2f vs planned %.2f. Closing.", fill, actual, plannedRisk));
      CloseOurPositions("slippage");
   }
}

//+------------------------------------------------------------------+
//| Position management                                              |
//+------------------------------------------------------------------+
int CountOurPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetInteger(POSITION_MAGIC) == (long)InpMagic && PositionGetString(POSITION_SYMBOL) == _Symbol)
         n++;
   }
   return n;
}

void CloseOurPositions(const string why)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != (long)InpMagic || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(trade.PositionClose(t))
         LogMsg(StringFormat("Closed #%I64u (%s)", t, why));
      else
         LogMsg(StringFormat("Close #%I64u failed: %u %s", t, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   }
}

bool ModifySL(const ulong ticket, const int side, const double newSl, const double tp, const MqlTick &tk, const string why)
{
   double cur = PositionGetDouble(POSITION_SL);
   // never widen: a stop may only move toward profit
   if(cur > 0.0 && ((side > 0 && newSl <= cur) || (side < 0 && newSl >= cur)))
      return false;
   double minDist = MathMax(StopsLevelPrice(), FreezeLevelPrice());
   if((side > 0 && tk.bid - newSl <= minDist) || (side < 0 && newSl - tk.ask <= minDist))
      return false;
   if(cur > 0.0 && ((side > 0 && tk.bid - cur <= FreezeLevelPrice()) || (side < 0 && cur - tk.ask <= FreezeLevelPrice())))
      return false;   // inside the freeze zone the broker rejects changes
   if(!trade.PositionModify(ticket, newSl, tp))
   {
      LogMsg(StringFormat("Modify #%I64u failed: %u %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
      return false;
   }
   LogMsg(StringFormat("SL #%I64u %.2f -> %.2f (%s)", ticket, cur, newSl, why));
   return true;
}

void ManagePosition(const MqlTick &tk)
{
   datetime utc = UtcNow();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != (long)InpMagic || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      int side = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      int held = (int)((TimeCurrent() - opened) / PeriodSeconds(InpTF));

      if(MustFlatten(utc) || held >= InpMaxHoldBars)
      {
         if(trade.PositionClose(t))
            LogMsg(StringFormat("Closed #%I64u (%s)", t, held >= InpMaxHoldBars ? "time stop" : "session end"));
         else
            LogMsg(StringFormat("Close #%I64u failed: %u %s", t, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
         continue;
      }

      bool needAtr = (sl <= 0.0) || InpTrailAtrMult > 0.0;
      double atr[];
      double atrNow = (needAtr && CopyIndicator(hAtr, 1, atr)) ? atr[0] : 0.0;
      double initDist = MathMax(InpSlAtrMult * atrNow, InpMinSlUSD);
      if(sl <= 0.0)
      {
         // every position must carry a stop: repair, or close if the broker refuses
         double repair = NormPrice(side > 0 ? entry - initDist : entry + initDist);
         if((side > 0 && repair >= tk.bid) || (side < 0 && repair <= tk.ask) || !ModifySL(t, side, repair, tp, tk, "missing stop"))
         {
            LogMsg(StringFormat("Position #%I64u has no valid stop: closing", t));
            trade.PositionClose(t);
         }
         continue;
      }
      bool beDone = (side > 0) ? sl >= entry : sl <= entry;
      if(!beDone)
         initDist = MathAbs(entry - sl);
      double mark = (side > 0) ? tk.bid : tk.ask;
      double gain = (side > 0) ? mark - entry : entry - mark;

      if(!beDone && InpBeTriggerR > 0.0 && gain >= InpBeTriggerR * initDist)
      {
         double be = NormPrice(side > 0 ? entry + InpBeLockUSD : entry - InpBeLockUSD);
         if(ModifySL(t, side, be, tp, tk, "break-even"))
            continue;
      }
      if(beDone && InpTrailAtrMult > 0.0 && atrNow > 0.0)
      {
         double trail = NormPrice(side > 0 ? mark - InpTrailAtrMult * atrNow : mark + InpTrailAtrMult * atrNow);
         double minStep = MathMax(0.05 * atrNow, SymPoint() * 10.0);
         if((side > 0 && trail >= sl + minStep) || (side < 0 && trail <= sl - minStep))
            ModifySL(t, side, trail, tp, tk, "trail");
      }
   }
}

//+------------------------------------------------------------------+
//| News filter: high-impact USD events from the MQL5 calendar       |
//| (the calendar is not available in the Strategy Tester)           |
//+------------------------------------------------------------------+
bool NewsBlocked(string &what)
{
   if(!InpUseNews || g_tester)
      return false;
   datetime now = TimeTradeServer();
   if(now - g_newsLoaded >= 900)
   {
      g_newsLoaded = now;
      ArrayResize(g_newsTimes, 0);
      ArrayResize(g_newsNames, 0);
      MqlCalendarValue vals[];
      if(CalendarValueHistory(vals, now - 86400, now + 86400, NULL, "USD"))
      {
         for(int i = 0; i < ArraySize(vals); i++)
         {
            MqlCalendarEvent ev;
            if(!CalendarEventById(vals[i].event_id, ev) || ev.importance != CALENDAR_IMPORTANCE_HIGH)
               continue;
            int k = ArraySize(g_newsTimes);
            ArrayResize(g_newsTimes, k + 1);
            ArrayResize(g_newsNames, k + 1);
            g_newsTimes[k] = vals[i].time;
            g_newsNames[k] = ev.name;
         }
      }
   }
   for(int i = 0; i < ArraySize(g_newsTimes); i++)
   {
      if(now >= g_newsTimes[i] - InpNewsBeforeMin * 60 && now <= g_newsTimes[i] + InpNewsAfterMin * 60)
      {
         what = g_newsNames[i] + " at " + TimeToString(g_newsTimes[i], TIME_MINUTES);
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Chart panel                                                       |
//+------------------------------------------------------------------+
void ShowPanel(const MqlTick &tk, const double equity, const bool force)
{
   if(!InpShowPanel || (g_tester && !MQLInfoInteger(MQL_VISUAL_MODE)))
      return;
   datetime now = TimeLocal();
   if(!force && now == g_lastPanel)
      return;
   g_lastPanel = now;

   double atr[];
   double atrNow = CopyIndicator(hAtr, 1, atr) ? atr[0] : 0.0;
   double slDist = MathMax(InpSlAtrMult * atrNow, InpMinSlUSD);
   double dayDD = (g_dayStartEquity > 0.0) ? (g_dayStartEquity - equity) / g_dayStartEquity * 100.0 : 0.0;
   double progress = (InpTargetEquity > 0.0) ? equity / InpTargetEquity * 100.0 : 0.0;

   string pos = "none";
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetInteger(POSITION_MAGIC) == (long)InpMagic && PositionGetString(POSITION_SYMBOL) == _Symbol)
         pos = StringFormat("%s %.2f @ %.2f  SL %.2f  TP %.2f  P/L %.2f",
                            PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL",
                            PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_OPEN),
                            PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP),
                            PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP));
   }

   string s = "GoldPullbackGrowth  |  " + _Symbol + " " + EnumToString(InpTF) + "\n";
   s += StringFormat("Status: %s\n", g_status);
   s += StringFormat("Balance %.2f  Equity %.2f  Peak %.2f  Goal %.0f (%.0f%%)\n",
                     AccountInfoDouble(ACCOUNT_BALANCE), equity, g_peakEquity, InpTargetEquity, progress);
   s += StringFormat("Risk %s%s -> %.2f%% now  |  min-lot cap %.1f%%\n",
                     RiskName(), BrakeActive(equity) ? " (brake: halved)" : "", CurrentRiskPct(equity), InpMinLotMaxRiskPct);
   s += StringFormat("Spread %.2f (max %.2f)  ATR %.2f  Stop now $%.2f/oz\n", tk.ask - tk.bid, InpMaxSpreadUSD, atrNow, slDist);
   s += StringFormat("Equity needed for min lot at this stop: %.2f\n", EquityNeededForMinLot(slDist));
   s += StringFormat("Today: DD %.2f%% (max %.1f%%)  entries %d/%d  losses %d/%d\n",
                     dayDD, InpMaxDailyLossPct, g_dayEntries, InpMaxTradesPerDay, g_dayLosses, InpMaxLossesPerDay);
   s += "Position: " + pos + "\n";
   s += "Last: " + g_lastMsg;
   Comment(s);
}

//+------------------------------------------------------------------+
//| Strategy Tester criterion: recovery factor, 0 below 50 trades    |
//+------------------------------------------------------------------+
double OnTester()
{
   double trades = TesterStatistics(STAT_TRADES);
   double dd = TesterStatistics(STAT_EQUITY_DD);
   if(trades < 50.0 || dd <= 0.0)
      return 0.0;
   return TesterStatistics(STAT_PROFIT) / dd;
}
//+------------------------------------------------------------------+
