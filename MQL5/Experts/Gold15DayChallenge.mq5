//+------------------------------------------------------------------+
//|                                          Gold15DayChallenge.mq5  |
//|  Two goals (InpGoal):                                            |
//|   1% A DAY (default): one trade a day at 07:00 UTC, take profit  |
//|     +1% of the day's equity, stop -1%, closed at 20:00 UTC.      |
//|     Stops for good after a 20% drop from the peak.               |
//|     2011-2018 ticks (research/xau_scalper/one_pct_day.py): 53%   |
//|     of days hit +1%, median year +17%; but on uptrend days (like |
//|     2026) about break-even: 48% of days +1%, -0.03% a day.       |
//|     Needs ~$800 for 1% risk with an $8 stop on 0.01 lot.         |
//|   DOUBLE: 15-day challenge to double the account ($10 -> $20,    |
//|     $100 -> $200, $500 -> $1000), then it stops for good.        |
//|                                                                  |
//|  Target = starting equity x InpTargetMultiple (default 2).       |
//|  Sizing modes:                                                   |
//|   MAX CHANCE (default, "bold play"): each trade risks only what  |
//|     is still missing to the target (max 90% of equity) and its   |
//|     take profit lands exactly on the target. Usually 1-2 trades. |
//|   ACTIVE: up to 4 trades a day; below $50 a $3 stop at 1:2 on    |
//|     0.01 lot, from $50 a $5 stop at 1:1 risking 50%.             |
//|  Direction = daily trend. Entries at 07, 09, 11, 13 UTC when     |
//|  flat. Stops for good at the target, after 15 days, or when a    |
//|  0.01-lot stop no longer fits.                                   |
//|                                                                  |
//|  2011-2018 gold ticks, 1,820 fifteen-day runs each               |
//|  (research/xau_scalper/bold_play.py, fifteen_days.py):           |
//|               $10->$20   $100->$200   $500->$1000                |
//|   MAX CHANCE    51.8%       53.8%        53.8%                   |
//|   ACTIVE        41.8%       43.2%        42.3%                   |
//|  Math alone gives ~47-48% for MAX CHANCE; the rest came from the |
//|  trend filter in this sample and may not repeat. Runs starting   |
//|  in an uptrend (like 2026) doubled 45-47%: plan for 45-50%.      |
//|  (research/xau_scalper/robustness.py)                            |
//|  WARNING: about half of all runs LOSE ~90% of the money.         |
//|  No martingale, no grid, no averaging down.                      |
//+------------------------------------------------------------------+
#property copyright "Naitik"
#property version   "1.20"
#property description "Gold: 1% a day (one trade, +1% / -1%) or a 15-day challenge to double the account."
#property description "1% a day hit on ~half the days in tests, about break-even in uptrends. Doubling: about half the runs."

#include <Trade\Trade.mqh>

enum ENUM_CH_DIRECTION
{
   CH_TREND = 0, // Daily trend (D1 close vs EMA 20/50); skip mixed days
   CH_LONG  = 1, // Always buy
   CH_SHORT = 2  // Always sell
};

enum ENUM_CH_GOAL
{
   GOAL_DAILY  = 0, // 1% a day: one trade a day, +1% target / -1% stop, every day
   GOAL_DOUBLE = 1  // Double the account in 15 days, then stop
};

enum ENUM_CH_SIZING
{
   SIZING_BOLD   = 0, // Max chance: risk only what is missing to the target (1-2 trades)
   SIZING_ACTIVE = 1, // Active: up to 4 trades a day, tested stop/RR/risk by balance
   SIZING_MANUAL = 2  // Manual: InpStopUSD / InpRR / InpRiskPct
};

enum ENUM_CH_STATE
{
   CH_RUNNING  = 0,
   CH_TARGET   = 1,
   CH_DEADLINE = 2,
   CH_BUST     = 3,
   CH_DRAWDOWN = 4
};

input group "Goal"
input ENUM_CH_GOAL InpGoal        = GOAL_DAILY; // What to aim for

input group "1% a day (InpGoal = 1% a day)"
input double InpDailyTargetPct    = 1.0;   // Take profit = +this % of the day's starting equity
input double InpDailyRiskPct      = 1.0;   // Stop = -this % (1 = best in tests; 3-10 win more days but lose over time)
input double InpDailyMinStopUSD   = 8.0;   // Stop at least this far (USD per oz); less spread cost
input int    InpDailyEntryHour    = 7;     // UTC hour of the daily trade
input int    InpDailyCloseHour    = 20;    // UTC hour to close it if neither TP nor SL was hit
input double InpMaxDrawdownPct    = 20.0;  // Stop for good when equity falls this % below its peak (0 = off)

input group "Double in 15 days (InpGoal = Double)"
input double InpTargetMultiple    = 2.0;   // Target = starting equity x this (2 = double)
input double InpTargetEquity      = 0.0;   // Fixed target instead (0 = use the multiple)
input int    InpDays              = 15;    // Stop for good after this many days from the first start
input bool   InpResetState        = false; // Set true once to start fresh (then back to false)

input group "Double: trades"
input ENUM_CH_SIZING InpSizing   = SIZING_BOLD; // Sizing mode
input double InpBoldMinStopUSD    = 8.0;   // Max chance: stop at least this far (USD per oz); wider is cheaper in spread
input double InpBoldMaxLossPct    = 90.0;  // Max chance: never lose more than this % of equity in one trade
input double InpStopUSD           = 3.0;   // Manual: stop loss distance in USD per oz (0.01 lot loses $3)
input double InpRR                = 2.0;   // Manual: take profit = stop x this
input double InpRiskPct           = 30.0;  // Manual: % of equity risked per trade (lot size grows with equity)
input double InpMinLotMaxRiskPct  = 90.0;  // Active/Manual: use the 0.01 lot while its risk is <= this % of equity
input int    InpMaxTradesPerDay   = 4;     // Max entries per UTC day
input string InpEntryHours        = "7,9,11,13"; // Entry hours, UTC (one try per hour, only when flat)
input int    InpEntryWindowMin    = 30;    // Minutes after each entry hour to wait for a good spread

input group "Direction"
input ENUM_CH_DIRECTION InpDirection = CH_TREND; // Trade direction
input int    InpTrendFast         = 20;    // D1 fast EMA
input int    InpTrendSlow         = 50;    // D1 slow EMA

input group "Execution"
input double InpMaxSpreadUSD      = 0.35;  // Skip while ask - bid is wider (USD per oz)
input double InpSlippageUSD       = 0.05;  // Stop slippage per oz counted in the risk
input int    InpServerUtcOffset   = 0;     // Server time minus UTC in hours (Exness = 0)
input ulong  InpMagic             = 20261024; // Magic number
input string InpComment           = "Gold15";

CTrade   trade;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE;
string   g_prefix;
bool     g_tester = false;
int      g_state = CH_RUNNING;
datetime g_start = 0;
double   g_startEq = 0.0;
double   g_target = 0.0;
double   g_stop = 0.0;     // settings in use (Max chance: minimum stop)
double   g_rr = 0.0;
double   g_risk = 0.0;
int      g_hours[];
int      g_dayKey = 0;     // 1% a day: current UTC day, its starting equity, and the equity peak
double   g_dayStart = 0.0;
double   g_peak = 0.0;
string   g_status = "starting";
string   g_last = "";
datetime g_lastPanel = 0;

//+------------------------------------------------------------------+
double GV(const string key, const double def = 0.0)
{
   string name = g_prefix + key;
   return GlobalVariableCheck(name) ? GlobalVariableGet(name) : def;
}

void GVSet(const string key, const double value)
{
   GlobalVariableSet(g_prefix + key, value);
   if(!g_tester)
      GlobalVariablesFlush();
}

void GVDel(const string key)
{
   string name = g_prefix + key;
   if(GlobalVariableCheck(name))
      GlobalVariableDel(name);
}

void Note(const string msg)
{
   g_last = msg;
   Print("[G15] ", msg);
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_tester = (MQLInfoInteger(MQL_TESTER) != 0);
   if(InpStopUSD <= 0.0 || InpRR <= 0.0 || InpRiskPct <= 0.0 || InpRiskPct > 95.0 || InpMinLotMaxRiskPct <= 0.0 ||
      InpTargetMultiple <= 1.0 || InpTargetEquity < 0.0 || InpBoldMinStopUSD <= 0.0 || InpBoldMaxLossPct <= 0.0 ||
      InpBoldMaxLossPct > 95.0 ||
      InpMinLotMaxRiskPct > 95.0 || InpDays < 1 || InpMaxTradesPerDay < 1 || InpTrendFast >= InpTrendSlow ||
      InpDailyTargetPct <= 0.0 || InpDailyRiskPct <= 0.0 || InpDailyRiskPct > 20.0 || InpDailyMinStopUSD <= 0.0 ||
      InpDailyEntryHour < 0 || InpDailyEntryHour > 23 || InpDailyCloseHour <= InpDailyEntryHour || InpDailyCloseHour > 24 ||
      InpMaxDrawdownPct < 0.0 || InpMaxDrawdownPct >= 100.0)
   {
      Print("[G15] Invalid inputs: stop, RR and risk must be > 0, risk <= 95% (daily <= 20%), days >= 1, ",
            "fast EMA < slow EMA, daily close hour after the entry hour");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(!ParseHours())
   {
      Print("[G15] Invalid InpEntryHours: use UTC hours 0-23 separated by commas, e.g. 7,9,11,13");
      return INIT_PARAMETERS_INCORRECT;
   }
   string sym = _Symbol;
   StringToUpper(sym);
   if(StringFind(sym, "XAU") < 0 && StringFind(sym, "GOLD") < 0)
      Print("[G15] Warning: built for XAUUSD; ", _Symbol, " is not a gold symbol");

   g_prefix = StringFormat("G15_%s%I64d_%I64u_%s_", g_tester ? "T_" : "", AccountInfoInteger(ACCOUNT_LOGIN), InpMagic, _Symbol);
   if(g_tester || InpResetState)
   {
      GVDel("state");
      GVDel("start");
      GVDel("slot");
      GVDel("startEq");
      GVDel("dKey");
      GVDel("dStart");
      GVDel("dTraded");
      GVDel("peak");
      if(InpResetState)
         Print("[G15] Fresh start: saved state cleared. Set InpResetState back to false.");
   }
   g_state = (int)GV("state", CH_RUNNING);
   g_start = (datetime)GV("start", 0.0);
   if(g_start == 0)
   {
      g_start = TimeCurrent();
      GVSet("start", (double)g_start);
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_startEq = GV("startEq", 0.0);
   if(g_startEq <= 0.0)
   {
      g_startEq = equity;
      GVSet("startEq", g_startEq);
   }
   g_target = (InpTargetEquity > 0.0) ? InpTargetEquity : g_startEq * InpTargetMultiple;
   if(InpGoal == GOAL_DAILY)
   {
      g_stop = InpDailyMinStopUSD;  // per-trade stop and target are sized in DailyTryEntry
      g_rr   = InpDailyTargetPct / InpDailyRiskPct;
      g_risk = InpDailyRiskPct;
   }
   else if(InpSizing == SIZING_BOLD)
   {
      g_stop = InpBoldMinStopUSD;   // per-trade stop and target are sized in TryEntry
      g_rr   = 0.0;
      g_risk = InpBoldMaxLossPct;
   }
   else if(InpSizing == SIZING_ACTIVE)
   {
      // best combinations in research/xau_scalper/fifteen_days.py (doubling, 15 days)
      g_stop = (g_startEq < 50.0) ? 3.0 : 5.0;
      g_rr   = (g_startEq < 50.0) ? 2.0 : 1.0;
      g_risk = (g_startEq < 50.0) ? 30.0 : 50.0;
   }
   else
   {
      g_stop = InpStopUSD;
      g_rr   = InpRR;
      g_risk = InpRiskPct;
   }
   g_peak = MathMax(GV("peak", 0.0), equity);
   g_dayKey = (int)GV("dKey", 0.0);
   g_dayStart = GV("dStart", 0.0);
   if(InpGoal == GOAL_DOUBLE && g_state == CH_RUNNING && equity >= g_target)
   {
      PrintFormat("[G15] Equity %.2f is already at the target %.2f: set InpResetState = true to start a new challenge",
                  equity, g_target);
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints((ulong)MathMax(10.0, MathRound(0.30 / SymPoint())));
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetMarginMode();
   trade.LogLevel(LOG_LEVEL_ERRORS);

   hFast = iMA(_Symbol, PERIOD_D1, InpTrendFast, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, PERIOD_D1, InpTrendSlow, 0, MODE_EMA, PRICE_CLOSE);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE)
   {
      Print("[G15] Failed to create indicator handles, error ", GetLastError());
      return INIT_FAILED;
   }
   if(InpGoal == GOAL_DAILY)
   {
      PrintFormat("[G15] %s | 1%% a day: +%.1f%% / -%.1f%% per day, trade at %02d:00 UTC, stop >= $%.2f, max drawdown %.0f%% | equity %.2f | %s",
                  _Symbol, InpDailyTargetPct, InpDailyRiskPct, InpDailyEntryHour, g_stop, InpMaxDrawdownPct, equity, StateName());
      PrintFormat("[G15] Honest odds: ~half the days hit +%.1f%%, the rest lose %.1f%%; in uptrends about break-even in tests. "
                  "Balance needed for 0.01 lot: about %.0f", InpDailyTargetPct, InpDailyRiskPct,
                  (g_stop + InpSlippageUSD) * 100.0 * SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN) / (InpDailyRiskPct / 100.0));
   }
   else
   {
      PrintFormat("[G15] %s | start %.2f, equity %.2f -> target %.2f in %d days (day %d now) | %s stop $%.2f, RR %.1f, risk %.0f%% | %s",
                  _Symbol, g_startEq, equity, g_target, InpDays, DayNumber(), SizingName(),
                  g_stop, g_rr, g_risk, StateName());
      PrintFormat("[G15] Honest odds: at most ~%.0f%% to reach the target with no proven edge (doubling tested ~50%% max chance, ~42%% active)",
                  100.0 * g_startEq / g_target);
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hFast);
   IndicatorRelease(hSlow);
   Comment("");
}

bool ParseHours()
{
   string parts[];
   int n = StringSplit(InpEntryHours, ',', parts);
   ArrayResize(g_hours, 0);
   for(int i = 0; i < n; i++)
   {
      string p = parts[i];
      StringTrimLeft(p);
      StringTrimRight(p);
      if(p == "")
         continue;
      for(int c = 0; c < StringLen(p); c++)
      {
         ushort ch = StringGetCharacter(p, c);
         if(ch < '0' || ch > '9')
            return false;
      }
      int h = (int)StringToInteger(p);
      if(h > 23)
         return false;
      int k = ArraySize(g_hours);
      ArrayResize(g_hours, k + 1);
      g_hours[k] = h;
   }
   return ArraySize(g_hours) > 0;
}

//+------------------------------------------------------------------+
void OnTick()
{
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk) || tk.bid <= 0.0 || tk.ask < tk.bid)
      return;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(InpGoal == GOAL_DAILY)
   {
      DailyTick(tk, equity);
      ShowPanel(tk, equity);
      return;
   }

   if(g_state == CH_RUNNING)
   {
      if(equity >= g_target)
      {
         SetState(CH_TARGET);
         Note(StringFormat("TARGET! Equity %.2f >= %.2f. Closing and stopping for good.", equity, g_target));
      }
      else if(TimeCurrent() - g_start >= (datetime)InpDays * 86400)
      {
         SetState(CH_DEADLINE);
         Note(StringFormat("Day %d reached with equity %.2f. Closing and stopping for good.", InpDays, equity));
      }
   }
   if(g_state != CH_RUNNING)
   {
      CloseOurPositions();
      ShowPanel(tk, equity);
      return;
   }

   if(CountOurPositions() > 0)
   {
      ManagePosition();
      g_status = "in a trade";
   }
   else
      TryEntry(tk, equity);
   ShowPanel(tk, equity);
}

//+------------------------------------------------------------------+
//| Helpers                                                           |
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

// Round DOWN to the volume step; 0 if below the minimum
double FloorVolume(const double lots)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(step <= 0.0 || lots <= 0.0)
      return 0.0;
   double v = MathMin(MathFloor(lots / step + 1e-7) * step, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));
   int digits = 0;
   double s = step;
   while(digits < 8 && MathAbs(s - MathRound(s)) > 1e-9)
   {
      s *= 10.0;
      digits++;
   }
   v = NormalizeDouble(v, digits);
   return (v + 1e-9 < vmin) ? 0.0 : v;
}

// Money lost by 1.0 lot at the stop, slippage included
double LossPerLot(const int side, const double entry)
{
   double dist = g_stop + InpSlippageUSD;
   double profit = 0.0;
   if(OrderCalcProfit(side > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, entry, entry - side * dist, profit) && profit < 0.0)
      return -profit;
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0.0)
      tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   return (ts > 0.0 && tv > 0.0) ? dist / ts * tv : 0.0;
}

void UtcNow(MqlDateTime &t)
{
   TimeToStruct(TimeCurrent() - InpServerUtcOffset * 3600, t);
}

int DayNumber()
{
   return (int)((TimeCurrent() - g_start) / 86400) + 1;
}

void SetState(const int state)
{
   g_state = state;
   GVSet("state", state);
}

string SizingName()
{
   if(InpSizing == SIZING_BOLD)
      return "max chance";
   return (InpSizing == SIZING_ACTIVE) ? "active" : "manual";
}

string StateName()
{
   switch(g_state)
   {
      case CH_TARGET:   return "TARGET REACHED - stopped. Withdraw your profit.";
      case CH_DEADLINE: return "15 DAYS OVER - stopped.";
      case CH_BUST:     return "NOT ENOUGH MONEY for a 0.01-lot stop - stopped.";
      case CH_DRAWDOWN: return "MAX DRAWDOWN hit - stopped for good. Review before restarting.";
      default:          break;
   }
   return "running";
}

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

void CloseOurPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != (long)InpMagic || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(trade.PositionClose(t))
         Note(StringFormat("Closed #%I64u", t));
      else
         Note(StringFormat("Close #%I64u failed: %u %s", t, trade.ResultRetcode(), trade.ResultRetcodeDescription()));
   }
}

// Entries made today (UTC), from deal history so a restart cannot reset the count
int EntriesToday()
{
   MqlDateTime t;
   UtcNow(t);
   t.hour = 0;
   t.min = 0;
   t.sec = 0;
   datetime from = StructToTime(t) + InpServerUtcOffset * 3600;
   if(!HistorySelect(from, TimeCurrent() + 86400))
      return InpMaxTradesPerDay;   // unknown: be safe
   int n = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d > 0 && HistoryDealGetInteger(d, DEAL_MAGIC) == (long)InpMagic && HistoryDealGetString(d, DEAL_SYMBOL) == _Symbol &&
         HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
         n++;
   }
   return n;
}

// +1 buy, -1 sell, 0 no trade today
int TodayDirection(string &why)
{
   if(InpDirection == CH_LONG)
   {
      why = "always buy";
      return 1;
   }
   if(InpDirection == CH_SHORT)
   {
      why = "always sell";
      return -1;
   }
   double f[];
   double s[];
   double c = iClose(_Symbol, PERIOD_D1, 1);
   if(CopyBuffer(hFast, 0, 1, 1, f) != 1 || CopyBuffer(hSlow, 0, 1, 1, s) != 1 || c <= 0.0)
   {
      why = "D1 history not ready";
      return 0;
   }
   if(c > s[0] && f[0] > s[0])
   {
      why = "D1 uptrend";
      return 1;
   }
   if(c < s[0] && f[0] < s[0])
   {
      why = "D1 downtrend";
      return -1;
   }
   why = "D1 trend mixed, no trades today";
   return 0;
}

//+------------------------------------------------------------------+
//| Entry                                                             |
//+------------------------------------------------------------------+
void TryEntry(const MqlTick &tk, const double equity)
{
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lplBuy = LossPerLot(1, tk.ask);
   double capPct = (InpSizing == SIZING_BOLD) ? InpBoldMaxLossPct : InpMinLotMaxRiskPct;
   if(lplBuy > 0.0 && vmin * lplBuy > equity * capPct / 100.0)
   {
      SetState(CH_BUST);
      Note(StringFormat("Equity %.2f cannot carry a %.2f-lot stop of %.2f. Stopped for good.", equity, vmin, vmin * lplBuy));
      return;
   }

   MqlDateTime t;
   UtcNow(t);
   if(t.day_of_week == 0 || t.day_of_week == 6)
   {
      g_status = "weekend";
      return;
   }
   int slotHour = -1;
   for(int i = 0; i < ArraySize(g_hours); i++)
      if(t.hour == g_hours[i] && t.min < InpEntryWindowMin)
         slotHour = g_hours[i];
   if(slotHour < 0)
   {
      g_status = "waiting for the next entry hour (" + InpEntryHours + " UTC)";
      return;
   }
   int slotKey = (t.year * 10000 + t.mon * 100 + t.day) * 100 + slotHour;
   if((int)GV("slot", 0.0) == slotKey)
   {
      g_status = "this entry hour is done";
      return;
   }
   if(EntriesToday() >= InpMaxTradesPerDay)
   {
      g_status = StringFormat("max %d trades today", InpMaxTradesPerDay);
      return;
   }
   string why;
   int side = TodayDirection(why);
   if(side == 0)
   {
      if(g_status != why)
         Note(why);
      g_status = why;
      GVSet("slot", slotKey);
      return;
   }
   double spread = tk.ask - tk.bid;
   if(spread > InpMaxSpreadUSD)
   {
      g_status = StringFormat("waiting: spread %.2f > %.2f", spread, InpMaxSpreadUSD);
      return;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      g_status = "algo trading is disabled";
      return;
   }

   double entry = (side > 0) ? tk.ask : tk.bid;
   double lpl = LossPerLot(side, entry);
   if(lpl <= 0.0)
   {
      g_status = "cannot price the stop (symbol data missing)";
      return;
   }
   double perLot = lpl / (g_stop + InpSlippageUSD);       // money per 1.0 price move for 1.0 lot
   double need = g_target - equity;
   double boldLoss = MathMin(equity * InpBoldMaxLossPct / 100.0, need);
   // Max chance: stake what is missing (capped); others: risk % of equity. Lot size grows with equity either way.
   double lots = FloorVolume((InpSizing == SIZING_BOLD ? boldLoss : equity * g_risk / 100.0) / lpl);
   if(lots <= 0.0)
      lots = FloorVolume(vmin);
   lots = FitMargin(side, lots, entry);
   if(lots <= 0.0)
      return;
   double stopDist = g_stop;
   double tpDist = g_rr * g_stop;
   if(InpSizing == SIZING_BOLD)
   {
      // widen the stop so a loss costs exactly the planned stake; a win lands on the target
      stopDist = MathMax(g_stop, boldLoss / (lots * perLot) - InpSlippageUSD);
      tpDist = need / (lots * perLot) + spread;
   }
   if(!StopsAllowed(stopDist, tpDist, spread))
      return;
   double sl = 0.0, tp = 0.0;
   uint rc = 0;
   bool sent = SendOrder(side, lots, stopDist, tpDist, entry, sl, tp, rc);
   GVSet("slot", slotKey);   // one try per entry hour, filled or not
   if(!sent)
   {
      Note(StringFormat("Order failed: %u %s", rc, trade.ResultRetcodeDescription()));
      return;
   }
   Note(StringFormat("Day %d, %02d:00 UTC, %s: %s %.2f lots @ %.2f | SL %.2f (-%.2f) | TP %.2f (+%.2f)",
                     DayNumber(), slotHour, why, side > 0 ? "BUY" : "SELL", lots, trade.ResultPrice(), sl,
                     lots * perLot * (stopDist + InpSlippageUSD), tp, lots * perLot * tpDist));
}

// Shrink lots so the margin stays under 80% of free margin; 0 (with a status) if even the minimum does not fit
double FitMargin(const int side, const double lots, const double entry)
{
   double margin = 0.0;
   if(!OrderCalcMargin(side > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, entry, margin) || margin <= 0.0)
      return lots;
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin <= free * 0.8)
      return lots;
   double fit = FloorVolume(lots * free * 0.8 / margin);
   if(fit <= 0.0)
      g_status = StringFormat("margin %.2f too high for free margin %.2f: raise the account leverage", margin, free);
   return fit;
}

bool StopsAllowed(const double stopDist, const double tpDist, const double spread)
{
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * SymPoint();
   if(stopDist - spread > minDist && tpDist > minDist)
      return true;
   g_status = "stop closer than the broker allows";
   return false;
}

// Market order with SL/TP at the given distances; retries on requotes. sl/tp receive the prices sent.
bool SendOrder(const int side, const double lots, const double stopDist, const double tpDist, double entry, double &sl, double &tp, uint &rc)
{
   bool sent = false;
   for(int attempt = 0; attempt < 3; attempt++)
   {
      sl = NormPrice(entry - side * stopDist);
      tp = NormPrice(entry + side * tpDist);
      sent = (side > 0) ? trade.Buy(lots, _Symbol, entry, sl, tp, InpComment)
                        : trade.Sell(lots, _Symbol, entry, sl, tp, InpComment);
      rc = trade.ResultRetcode();
      sent = sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED);
      if(sent || (rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_PRICE_CHANGED && rc != TRADE_RETCODE_PRICE_OFF))
         break;
      MqlTick fresh;
      if(!SymbolInfoTick(_Symbol, fresh))
         break;
      entry = (side > 0) ? fresh.ask : fresh.bid;
   }
   return sent;
}

//+------------------------------------------------------------------+
//| 1% a day                                                          |
//+------------------------------------------------------------------+
void DailyTick(const MqlTick &tk, const double equity)
{
   int open = CountOurPositions();
   if(g_state == CH_RUNNING && InpMaxDrawdownPct > 0.0 && g_peak > 0.0 && equity <= g_peak * (1.0 - InpMaxDrawdownPct / 100.0))
   {
      SetState(CH_DRAWDOWN);
      Note(StringFormat("Equity %.2f is %.0f%% below the peak %.2f. Closing and stopping for good.", equity, InpMaxDrawdownPct, g_peak));
   }
   if(g_state != CH_RUNNING)
   {
      CloseOurPositions();
      return;
   }
   if(open == 0 && equity > g_peak)
   {
      g_peak = equity;
      GVSet("peak", g_peak);
   }

   MqlDateTime t;
   UtcNow(t);
   int key = t.year * 10000 + t.mon * 100 + t.day;
   if(key != g_dayKey)
   {
      g_dayKey = key;
      g_dayStart = (open > 0) ? AccountInfoDouble(ACCOUNT_BALANCE) : equity;
      GVSet("dKey", key);
      GVSet("dStart", g_dayStart);
   }

   if(open > 0)
   {
      ManagePosition();
      if(t.hour >= InpDailyCloseHour || t.day_of_week == 0 || t.day_of_week == 6)
      {
         Note(StringFormat("%02d:00 UTC: closing today's trade", InpDailyCloseHour));
         CloseOurPositions();
      }
      g_status = "today's trade is open";
      return;
   }
   if((int)GV("dTraded", 0.0) == key)
   {
      double dayPct = (g_dayStart > 0.0) ? (equity / g_dayStart - 1.0) * 100.0 : 0.0;
      g_status = StringFormat("today is done (%+.2f%%), next trade tomorrow %02d:00 UTC", dayPct, InpDailyEntryHour);
      return;
   }
   if(t.day_of_week == 0 || t.day_of_week == 6)
   {
      g_status = "weekend";
      return;
   }
   if(t.hour != InpDailyEntryHour || t.min >= InpEntryWindowMin)
   {
      g_status = StringFormat("waiting for %02d:00 UTC", InpDailyEntryHour);
      return;
   }
   DailyTryEntry(tk, key);
}

void DailyTryEntry(const MqlTick &tk, const int key)
{
   string why;
   int side = TodayDirection(why);
   if(side == 0)
   {
      if(g_status != why)
         Note(why);
      g_status = why;
      GVSet("dTraded", key);
      return;
   }
   double spread = tk.ask - tk.bid;
   if(spread > InpMaxSpreadUSD)
   {
      g_status = StringFormat("waiting: spread %.2f > %.2f", spread, InpMaxSpreadUSD);
      return;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      g_status = "algo trading is disabled";
      return;
   }
   double entry = (side > 0) ? tk.ask : tk.bid;
   double lpl = LossPerLot(side, entry);              // per 1.0 lot at the minimum stop
   if(lpl <= 0.0)
   {
      g_status = "cannot price the stop (symbol data missing)";
      return;
   }
   double perLot = lpl / (g_stop + InpSlippageUSD);
   double stake = g_dayStart * InpDailyRiskPct / 100.0;
   double win = g_dayStart * InpDailyTargetPct / 100.0;
   double lots = FloorVolume(stake / lpl);
   if(lots <= 0.0)
   {
      g_status = StringFormat("balance too small: %.1f%% risk with a $%.0f stop needs about %.0f for 0.01 lot",
                              InpDailyRiskPct, g_stop, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN) * lpl * 100.0 / InpDailyRiskPct);
      return;
   }
   lots = FitMargin(side, lots, entry);
   if(lots <= 0.0)
      return;
   // widen the stop so a loss costs exactly the planned %; the take profit pays exactly the target %
   double stopDist = MathMax(g_stop, stake / (lots * perLot) - InpSlippageUSD);
   double tpDist = win / (lots * perLot) + spread;
   if(!StopsAllowed(stopDist, tpDist, spread))
      return;
   double sl = 0.0, tp = 0.0;
   uint rc = 0;
   bool sent = SendOrder(side, lots, stopDist, tpDist, entry, sl, tp, rc);
   if(!sent && (rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED || rc == TRADE_RETCODE_PRICE_OFF))
      return;                                         // price problem: try again on the next tick of the window
   GVSet("dTraded", key);
   if(!sent)
   {
      Note(StringFormat("Order failed: %u %s", rc, trade.ResultRetcodeDescription()));
      return;
   }
   Note(StringFormat("%s: %s %.2f lots @ %.2f | SL %.2f (-%.2f, -%.1f%%) | TP %.2f (+%.2f, +%.1f%%)",
                     why, side > 0 ? "BUY" : "SELL", lots, trade.ResultPrice(), sl, lots * perLot * (stopDist + InpSlippageUSD),
                     InpDailyRiskPct, tp, lots * perLot * tpDist, InpDailyTargetPct));
}

void ManagePosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != (long)InpMagic || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetDouble(POSITION_SL) <= 0.0)
      {
         Note("Position has no stop loss: closing it");
         trade.PositionClose(t);
      }
   }
}

//+------------------------------------------------------------------+
void ShowPanel(const MqlTick &tk, const double equity)
{
   if(g_tester && !MQLInfoInteger(MQL_VISUAL_MODE))
      return;
   datetime now = TimeLocal();
   if(now == g_lastPanel)
      return;
   g_lastPanel = now;
   if(InpGoal == GOAL_DAILY)
   {
      double dayPct = (g_dayStart > 0.0) ? (equity / g_dayStart - 1.0) * 100.0 : 0.0;
      string d = "GOLD 1% A DAY  |  " + _Symbol + "\n";
      d += "State: " + StateName() + "\n";
      if(g_state == CH_RUNNING)
         d += "Status: " + g_status + "\n";
      d += StringFormat("Equity %.2f  |  today %+.2f%% (target +%.1f%%, stop -%.1f%%)  |  peak %.2f, stop-for-good at -%.0f%%\n",
                        equity, dayPct, InpDailyTargetPct, InpDailyRiskPct, g_peak, InpMaxDrawdownPct);
      d += StringFormat("Spread %.2f  |  one trade at %02d:00 UTC, closed by %02d:00 UTC\n", tk.ask - tk.bid,
                        InpDailyEntryHour, InpDailyCloseHour);
      d += "Last: " + g_last + "\n";
      d += "Honest odds: ~half the days +1%, the rest -1%. About break-even in uptrends in tests.";
      Comment(d);
      return;
   }
   string s = "GOLD 15-DAY CHALLENGE  |  " + _Symbol + "\n";
   s += "State: " + StateName() + "\n";
   if(g_state == CH_RUNNING)
      s += "Status: " + g_status + "\n";
   int day = DayNumber();
   if(day > InpDays)
      day = InpDays;
   s += StringFormat("Day %d of %d  |  start %.2f  equity %.2f -> target %.2f  (x%.2f to go)\n",
                     day, InpDays, g_startEq, equity, g_target, g_target / MathMax(equity, 0.01));
   if(InpSizing == SIZING_BOLD)
      s += StringFormat("Spread %.2f  |  max chance: stake = what is missing (max %.0f%%), stop >= $%.2f\n",
                        tk.ask - tk.bid, InpBoldMaxLossPct, g_stop);
   else
      s += StringFormat("Spread %.2f  |  %s: stop $%.2f, RR %.1f, risk %.0f%% per trade, max %d trades/day\n",
                        tk.ask - tk.bid, SizingName(), g_stop, g_rr, g_risk, InpMaxTradesPerDay);
   s += "Last: " + g_last + "\n";
   bool doubling = MathAbs(g_target / MathMax(g_startEq, 0.01) - 2.0) < 0.01;
   s += StringFormat("Honest odds: %s (limit %.0f%%). The rest lose most of the money.",
                     !doubling ? "see README" : (InpSizing == SIZING_BOLD ? "~50% doubled in tests" : "~42% doubled in tests"),
                     100.0 * g_startEq / g_target);
   Comment(s);
}
//+------------------------------------------------------------------+
