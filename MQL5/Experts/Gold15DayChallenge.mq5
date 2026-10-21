//+------------------------------------------------------------------+
//|                                          Gold15DayChallenge.mq5  |
//|  15-day XAUUSD challenge for a tiny account: $10 -> $50 (or      |
//|  $100) with up to 4 trades a day, then it stops for good.        |
//|                                                                  |
//|  Every trade: stop $3 per oz, target 2 x stop, risk 30% of       |
//|  equity, so the lot size grows as the account grows (0.01 lot    |
//|  until ~$20, 0.02 until ~$30, ...). Direction = daily trend.     |
//|  Entries at 07, 09, 11, 13 UTC when flat, max 4 a day.           |
//|  Stops for good at the target, after 15 days, or when the money  |
//|  left cannot carry a 0.01-lot stop.                              |
//|                                                                  |
//|  Settings were chosen on 2011-2018 gold ticks                    |
//|  (research/xau_scalper/fifteen_days.py, 1,820 runs):             |
//|    $10 -> $50 in 15 days : 14.8% of runs  (math limit ~20%)      |
//|    $10 -> $100 in 15 days:  7.0% (RR 3)   (math limit ~10%)      |
//|  WARNING: about 85 of 100 runs LOSE most of the $10.             |
//|  No martingale, no grid, no averaging down.                      |
//+------------------------------------------------------------------+
#property copyright "Naitik"
#property version   "1.00"
#property description "15-day gold challenge: $10 -> $50/$100 with up to 4 trades a day, lot size grows with equity."
#property description "About 15 in 100 runs reach $50; most lose the deposit. Stops for good at target, day 15 or bust."

#include <Trade\Trade.mqh>

enum ENUM_CH_DIRECTION
{
   CH_TREND = 0, // Daily trend (D1 close vs EMA 20/50); skip mixed days
   CH_LONG  = 1, // Always buy
   CH_SHORT = 2  // Always sell
};

enum ENUM_CH_STATE
{
   CH_RUNNING  = 0,
   CH_TARGET   = 1,
   CH_DEADLINE = 2,
   CH_BUST     = 3
};

input group "Challenge"
input double InpTargetEquity      = 50.0;  // Close all and stop for good at this equity ($100: set InpRR = 3)
input int    InpDays              = 15;    // Stop for good after this many days from the first start
input bool   InpResetState        = false; // Set true once to start a new challenge (then back to false)

input group "Trades"
input double InpStopUSD           = 3.0;   // Stop loss distance in USD per oz (0.01 lot loses $3)
input double InpRR                = 2.0;   // Take profit = stop x this
input double InpRiskPct           = 30.0;  // % of equity risked per trade (lot size grows with equity)
input double InpMinLotMaxRiskPct  = 90.0;  // Use the 0.01 minimum lot while its risk is <= this % of equity
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
int      g_hours[];
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
      InpMinLotMaxRiskPct > 95.0 || InpDays < 1 || InpMaxTradesPerDay < 1 || InpTrendFast >= InpTrendSlow)
   {
      Print("[G15] Invalid inputs: stop, RR and risk must be > 0, risk <= 95%, days >= 1, fast EMA < slow EMA");
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
      if(InpResetState)
         Print("[G15] New challenge: saved state cleared. Set InpResetState back to false.");
   }
   g_state = (int)GV("state", CH_RUNNING);
   g_start = (datetime)GV("start", 0.0);
   if(g_start == 0)
   {
      g_start = TimeCurrent();
      GVSet("start", (double)g_start);
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_state == CH_RUNNING && equity >= InpTargetEquity)
   {
      PrintFormat("[G15] Equity %.2f is already at the target %.2f: raise InpTargetEquity", equity, InpTargetEquity);
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
   PrintFormat("[G15] %s | equity %.2f -> target %.2f in %d days (day %d now), stop $%.2f, RR %.1f, risk %.0f%%, state %s",
               _Symbol, equity, InpTargetEquity, InpDays, DayNumber(), InpStopUSD, InpRR, InpRiskPct, StateName());
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

   if(g_state == CH_RUNNING)
   {
      if(equity >= InpTargetEquity)
      {
         SetState(CH_TARGET);
         Note(StringFormat("TARGET! Equity %.2f >= %.2f. Closing and stopping for good.", equity, InpTargetEquity));
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
   double dist = InpStopUSD + InpSlippageUSD;
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

string StateName()
{
   switch(g_state)
   {
      case CH_TARGET:   return "TARGET REACHED - stopped. Withdraw your profit.";
      case CH_DEADLINE: return "15 DAYS OVER - stopped.";
      case CH_BUST:     return "NOT ENOUGH MONEY for a 0.01-lot stop - stopped.";
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
   if(lplBuy > 0.0 && vmin * lplBuy > equity * InpMinLotMaxRiskPct / 100.0)
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
   // lot size grows with equity: risk % of equity, at least the minimum lot while it fits the cap
   double lots = FloorVolume(equity * InpRiskPct / 100.0 / lpl);
   if(lots <= 0.0)
      lots = FloorVolume(vmin);
   double margin = 0.0;
   if(OrderCalcMargin(side > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, entry, margin) && margin > 0.0)
   {
      double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(margin > free * 0.8)
      {
         double fit = FloorVolume(lots * free * 0.8 / margin);
         if(fit <= 0.0)
         {
            g_status = StringFormat("margin %.2f too high for free margin %.2f: raise the account leverage", margin, free);
            return;
         }
         lots = fit;
      }
   }
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * SymPoint();
   if(InpStopUSD - spread <= minDist)
   {
      g_status = "stop closer than the broker allows";
      return;
   }
   double sl = NormPrice(entry - side * InpStopUSD);
   double tp = NormPrice(entry + side * InpRR * InpStopUSD);

   bool sent = false;
   uint rc = 0;
   for(int attempt = 0; attempt < 3 && !sent; attempt++)
   {
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
      sl = NormPrice(entry - side * InpStopUSD);
      tp = NormPrice(entry + side * InpRR * InpStopUSD);
   }
   GVSet("slot", slotKey);   // one try per entry hour, filled or not
   if(!sent)
   {
      Note(StringFormat("Order failed: %u %s", rc, trade.ResultRetcodeDescription()));
      return;
   }
   Note(StringFormat("Day %d, %02d:00 UTC, %s: %s %.2f lots @ %.2f | SL %.2f (-%.2f) | TP %.2f (+%.2f)",
                     DayNumber(), slotHour, why, side > 0 ? "BUY" : "SELL", lots, trade.ResultPrice(), sl,
                     lots * lpl, tp, lots * lpl * InpRR * InpStopUSD / (InpStopUSD + InpSlippageUSD)));
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
   string s = "GOLD 15-DAY CHALLENGE  |  " + _Symbol + "\n";
   s += "State: " + StateName() + "\n";
   if(g_state == CH_RUNNING)
      s += "Status: " + g_status + "\n";
   int day = DayNumber();
   if(day > InpDays)
      day = InpDays;
   s += StringFormat("Day %d of %d  |  equity %.2f -> target %.2f  (x%.1f to go)\n",
                     day, InpDays, equity, InpTargetEquity, InpTargetEquity / MathMax(equity, 0.01));
   s += StringFormat("Spread %.2f  |  stop $%.2f, RR %.1f, risk %.0f%% per trade, max %d trades/day\n",
                     tk.ask - tk.bid, InpStopUSD, InpRR, InpRiskPct, InpMaxTradesPerDay);
   s += "Last: " + g_last + "\n";
   s += "Tested odds: ~15% reach $50, ~7% reach $100. Most runs lose the deposit.";
   Comment(s);
}
//+------------------------------------------------------------------+
