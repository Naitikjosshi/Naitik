//+------------------------------------------------------------------+
//|                                                AarYaParGold.mq5  |
//|  "Aar ya paar" for a tiny XAUUSD account (default $10 -> $100):  |
//|  ONE trade sized so that the stop loses ~90% of the account and  |
//|  the target lands exactly on the goal. Then it stops for good.   |
//|                                                                  |
//|  Why one trade: with no proven edge, the chance of multiplying   |
//|  money before losing it is at best start / target, and every     |
//|  extra trade pays the spread again. One trade pays it once.      |
//|  Tested on 2011-2018 gold ticks (research/xau_scalper/           |
//|  aar_ya_paar.py): 10x in one trade won 9.9% of the time with a   |
//|  random direction, 11.3% with the daily trend at 07:00 UTC.      |
//|                                                                  |
//|  Gold minimum lot 0.01 = 1 oz = $1 per $1 move. With $10 the     |
//|  stop sits ~$9 away and the target ~$90 away.                    |
//|                                                                  |
//|  WARNING: about 9 out of 10 runs LOSE the deposit. Use only      |
//|  money you are ready to lose. No martingale, no grid.            |
//+------------------------------------------------------------------+
#property copyright "Naitik"
#property version   "1.00"
#property description "Aar ya paar for small XAUUSD accounts: one trade, stop = ~90% of equity, target = the goal."
#property description "About 1 in 10 runs reach 10x; the rest lose the deposit. Stops for good either way."

#include <Trade\Trade.mqh>

enum ENUM_AYP_DIRECTION
{
   AYP_TREND = 0, // Daily trend (D1 close vs EMA 20/50); skip mixed days
   AYP_LONG  = 1, // Always buy
   AYP_SHORT = 2  // Always sell
};

enum ENUM_AYP_STATE
{
   AYP_RUNNING = 0,
   AYP_PAAR    = 1,   // target reached
   AYP_AAR     = 2    // too little money left for another trade
};

input group "Aar ya paar"
input double InpTargetEquity     = 100.0; // Close everything and stop for good at this equity
input double InpRiskPct          = 90.0;  // % of equity lost if the stop is hit
input double InpMaxRR            = 0.0;   // Cap reward:risk per trade (0 = one trade straight to the target)
input int    InpLotMultiple      = 1;     // Lots = broker minimum x this (more lots = tighter stop)
input double InpMaxStopPct       = 1.0;   // If the stop would be wider than this % of price, add lots
input bool   InpResetState       = false; // Set true once to start a new attempt (after a new deposit)

input group "Entry"
input ENUM_AYP_DIRECTION InpDirection = AYP_TREND; // Trade direction
input int    InpTrendFast        = 20;    // D1 fast EMA
input int    InpTrendSlow        = 50;    // D1 slow EMA
input int    InpEntryHourUTC     = 7;     // Daily entry time (London open)
input int    InpEntryWindowMin   = 120;   // Keep trying this many minutes if the spread is too wide
input int    InpServerUtcOffset  = 0;     // Server time minus UTC in hours (Exness = 0)

input group "Execution"
input double InpMaxSpreadUSD     = 0.60;  // Skip while ask - bid is wider (USD per oz)
input double InpMinStopSpreads   = 15.0;  // The stop must be at least this many spreads away (else wait)
input double InpMinStopUSD       = 3.0;   // If even the minimum lot's stop is closer than this, the run is over (AAR)
input double InpSlippageUSD      = 0.10;  // Stop slippage per oz kept inside the risk
input int    InpMaxHoldDays      = 0;     // Close after this many days (0 = hold until stop or target)
input ulong  InpMagic            = 20261023; // Magic number
input string InpComment          = "AarYaPar";

CTrade   trade;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE;
string   g_prefix;
bool     g_tester = false;
int      g_state = AYP_RUNNING;
int      g_lastTradeDay = 0;
string   g_status = "starting";
string   g_plan = "";
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

//+------------------------------------------------------------------+
int OnInit()
{
   g_tester = (MQLInfoInteger(MQL_TESTER) != 0);
   if(InpRiskPct <= 0.0 || InpRiskPct > 95.0 || InpLotMultiple < 1 || InpMaxRR < 0.0 || InpMaxStopPct <= 0.0 ||
      InpTrendFast >= InpTrendSlow || InpEntryHourUTC < 0 || InpEntryHourUTC > 23 || InpMinStopSpreads < 1.0)
   {
      Print("[AYP] Invalid inputs: risk 0-95%, lot multiple >= 1, fast EMA < slow EMA, entry hour 0-23");
      return INIT_PARAMETERS_INCORRECT;
   }
   string sym = _Symbol;
   StringToUpper(sym);
   if(StringFind(sym, "XAU") < 0 && StringFind(sym, "GOLD") < 0)
      Print("[AYP] Warning: built for XAUUSD; ", _Symbol, " is not a gold symbol");

   g_prefix = StringFormat("AYP_%s%I64d_%I64u_%s_", g_tester ? "T_" : "", AccountInfoInteger(ACCOUNT_LOGIN), InpMagic, _Symbol);
   if(g_tester || InpResetState)
   {
      GVDel("state");
      GVDel("day");
      if(InpResetState)
         Print("[AYP] New attempt: saved state cleared. Set InpResetState back to false.");
   }
   g_state = (int)GV("state", AYP_RUNNING);
   g_lastTradeDay = (int)GV("day", 0);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_state == AYP_RUNNING && equity >= InpTargetEquity)
   {
      PrintFormat("[AYP] Equity %.2f is already at the target %.2f: raise InpTargetEquity", equity, InpTargetEquity);
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
      Print("[AYP] Failed to create indicator handles, error ", GetLastError());
      return INIT_FAILED;
   }
   PrintFormat("[AYP] %s | min lot %g, step %g, contract %g, stops level %d pts | equity %.2f %s -> target %.2f (x%.1f) | state %s",
               _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP),
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE), (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
               equity, AccountInfoString(ACCOUNT_CURRENCY), InpTargetEquity, InpTargetEquity / MathMax(equity, 0.01), StateName());
   PrintFormat("[AYP] Honest odds: about %.0f%% to reach the target, otherwise the deposit is lost.",
               100.0 * MathMax(equity, 0.0) / InpTargetEquity);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hFast);
   IndicatorRelease(hSlow);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk) || tk.bid <= 0.0 || tk.ask < tk.bid)
      return;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(g_state == AYP_RUNNING && equity >= InpTargetEquity)
   {
      SetState(AYP_PAAR);
      PrintFormat("[AYP] PAAR! Equity %.2f reached the target %.2f. Closing and stopping for good.", equity, InpTargetEquity);
   }
   if(g_state != AYP_RUNNING)
   {
      CloseOurPositions();
      g_status = (g_state == AYP_PAAR) ? "PAAR - target reached, stopped. Withdraw your profit."
                                       : "AAR - not enough money for another trade, stopped.";
      ShowPanel(tk, equity);
      return;
   }

   if(CountOurPositions() > 0)
      ManagePosition(tk);
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

double NormVolume(const double lots)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return 0.0;
   double v = MathFloor(lots / step + 1e-7) * step;
   int digits = 0;
   double s = step;
   while(digits < 8 && MathAbs(s - MathRound(s)) > 1e-9)
   {
      s *= 10.0;
      digits++;
   }
   return NormalizeDouble(MathMin(v, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX)), digits);
}

// Money made or lost by `lots` per 1.0 price move (e.g. $1 per oz for 0.01 lot of gold)
double MoneyPerPriceUnit(const int side, const double lots, const double price)
{
   double profit = 0.0;
   if(OrderCalcProfit(side > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, price, price + side * 1.0, profit) && profit > 0.0)
      return profit;
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   return (ts > 0.0 && tv > 0.0) ? lots * tv / ts : 0.0;
}

int UtcDayKey()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent() - InpServerUtcOffset * 3600, t);
   return t.year * 10000 + t.mon * 100 + t.day;
}

bool InEntryWindow()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent() - InpServerUtcOffset * 3600, t);
   if(t.day_of_week == 0 || t.day_of_week == 6)
      return false;
   int minutes = t.hour * 60 + t.min - InpEntryHourUTC * 60;
   return minutes >= 0 && minutes < InpEntryWindowMin;
}

void SetState(const int state)
{
   g_state = state;
   GVSet("state", state);
}

string StateName()
{
   if(g_state == AYP_PAAR)
      return "PAAR (target reached)";
   if(g_state == AYP_AAR)
      return "AAR (account done)";
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
      if(!trade.PositionClose(t))
         PrintFormat("[AYP] Close #%I64u failed: %u %s", t, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

// Direction for today: +1 buy, -1 sell, 0 skip
int TodayDirection(string &why)
{
   if(InpDirection == AYP_LONG)
   {
      why = "always buy";
      return 1;
   }
   if(InpDirection == AYP_SHORT)
   {
      why = "always sell";
      return -1;
   }
   double f[];
   double s[];
   if(CopyBuffer(hFast, 0, 1, 1, f) != 1 || CopyBuffer(hSlow, 0, 1, 1, s) != 1)
   {
      why = "D1 history not ready";
      return 0;
   }
   double c = iClose(_Symbol, PERIOD_D1, 1);
   if(c <= 0.0)
   {
      why = "D1 history not ready";
      return 0;
   }
   if(c > s[0] && f[0] > s[0])
   {
      why = StringFormat("D1 uptrend (close %.2f > EMA%d %.2f, EMA%d %.2f)", c, InpTrendSlow, s[0], InpTrendFast, f[0]);
      return 1;
   }
   if(c < s[0] && f[0] < s[0])
   {
      why = StringFormat("D1 downtrend (close %.2f < EMA%d %.2f, EMA%d %.2f)", c, InpTrendSlow, s[0], InpTrendFast, f[0]);
      return -1;
   }
   why = "D1 trend mixed, no trade today";
   return 0;
}

//+------------------------------------------------------------------+
//| The one big trade                                                 |
//+------------------------------------------------------------------+
void TryEntry(const MqlTick &tk, const double equity)
{
   double spread = tk.ask - tk.bid;
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   // Is there enough money left for even one more minimum-lot trade?
   double riskMoney = equity * InpRiskPct / 100.0;
   double perUnitMin = MoneyPerPriceUnit(1, vmin, tk.ask);
   if(perUnitMin > 0.0 && (riskMoney / perUnitMin - InpSlippageUSD) < InpMinStopUSD)
   {
      SetState(AYP_AAR);
      PrintFormat("[AYP] AAR. Equity %.2f: the minimum lot's stop would be only $%.2f away (< $%.2f). Stopped.",
                  equity, riskMoney / perUnitMin - InpSlippageUSD, InpMinStopUSD);
      return;
   }

   int day = UtcDayKey();
   if(!InEntryWindow())
   {
      g_status = StringFormat("waiting for %02d:00 UTC", InpEntryHourUTC);
      return;
   }
   if(day == g_lastTradeDay)
   {
      g_status = "already traded today";
      return;
   }
   string why;
   int side = TodayDirection(why);
   if(side == 0)
   {
      if(g_status != why)
         Print("[AYP] ", why);
      g_status = why;
      return;
   }
   if(spread > InpMaxSpreadUSD)
   {
      g_status = StringFormat("waiting: spread %.2f > %.2f", spread, InpMaxSpreadUSD);
      return;
   }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      g_status = "algo trading is disabled";
      return;
   }

   double entry = (side > 0) ? tk.ask : tk.bid;
   double lots = NormVolume(vmin * InpLotMultiple);
   double perUnit = MoneyPerPriceUnit(side, lots, entry);
   if(lots <= 0.0 || perUnit <= 0.0)
   {
      g_status = "cannot price the trade (symbol data missing)";
      return;
   }

   // keep the broker's stop-out from closing the trade before our stop does
   double margin = 0.0;
   if(!OrderCalcMargin(side > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, entry, margin) || margin <= 0.0)
   {
      g_status = "cannot compute margin";
      return;
   }
   double soLevel = AccountInfoDouble(ACCOUNT_MARGIN_SO_SO);
   double soMoney = (AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE) == ACCOUNT_STOPOUT_MODE_PERCENT) ? margin * soLevel / 100.0 : soLevel;
   double maxLoss = equity - soMoney * 1.1;
   if(margin >= AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.95 || maxLoss <= 0.0)
   {
      g_status = StringFormat("margin %.2f too high for equity %.2f: raise the account leverage", margin, equity);
      return;
   }
   double risk = MathMin(riskMoney, maxLoss);

   // stop where the loss = risk, target where the win lands on the goal
   double stopDist = risk / perUnit - InpSlippageUSD;
   while(stopDist > entry * InpMaxStopPct / 100.0)
   {
      double more = NormVolume(lots + vmin);
      double perMore = MoneyPerPriceUnit(side, more, entry);
      if(more <= lots || perMore <= 0.0)
         break;
      lots = more;
      perUnit = perMore;
      stopDist = risk / perUnit - InpSlippageUSD;
   }
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * SymPoint();
   if(stopDist < InpMinStopSpreads * spread || stopDist <= minDist + spread)
   {
      g_status = StringFormat("stop $%.2f too close for spread %.2f, waiting", stopDist, spread);
      return;
   }
   double tpDist = (InpTargetEquity - equity) / perUnit + spread;
   if(InpMaxRR > 0.0)
      tpDist = MathMin(tpDist, InpMaxRR * stopDist);
   double sl = NormPrice(entry - side * stopDist);
   double tp = NormPrice(entry + side * tpDist);
   double rr = tpDist / stopDist;
   double odds = 100.0 * (stopDist - spread) / (stopDist + tpDist);

   bool sent = false;
   for(int attempt = 0; attempt < 3 && !sent; attempt++)
   {
      sent = (side > 0) ? trade.Buy(lots, _Symbol, entry, sl, tp, InpComment)
                        : trade.Sell(lots, _Symbol, entry, sl, tp, InpComment);
      uint rc = trade.ResultRetcode();
      sent = sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED);
      if(sent)
         break;
      PrintFormat("[AYP] Order failed (try %d): %u %s", attempt + 1, rc, trade.ResultRetcodeDescription());
      if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_PRICE_CHANGED && rc != TRADE_RETCODE_PRICE_OFF)
         return;
      MqlTick fresh;
      if(!SymbolInfoTick(_Symbol, fresh))
         return;
      entry = (side > 0) ? fresh.ask : fresh.bid;
      sl = NormPrice(entry - side * stopDist);
      tp = NormPrice(entry + side * tpDist);
   }
   if(!sent)
      return;
   g_lastTradeDay = day;
   GVSet("day", day);
   g_plan = StringFormat("%s %.2f lots @ %.2f | SL %.2f ($%.2f away) | TP %.2f ($%.2f away) | R:R %.1f | odds ~%.0f%%",
                         side > 0 ? "BUY" : "SELL", lots, trade.ResultPrice(), sl, stopDist, tp, tpDist, rr, odds);
   Print("[AYP] ", why, " -> ", g_plan);
}

void ManagePosition(const MqlTick &tk)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != (long)InpMagic || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      double sl = PositionGetDouble(POSITION_SL);
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(sl <= 0.0)
      {
         // never leave the big trade without a stop: close it if the broker dropped the SL
         Print("[AYP] Position has no stop loss: closing it");
         trade.PositionClose(t);
         continue;
      }
      if(InpMaxHoldDays > 0 && TimeCurrent() - opened >= (datetime)InpMaxHoldDays * 86400)
      {
         Print("[AYP] Max hold time reached: closing");
         trade.PositionClose(t);
         continue;
      }
      g_status = StringFormat("in the trade: P/L %.2f", PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP));
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
   string s = "AAR YA PAAR  |  " + _Symbol + "\n";
   s += "Status: " + g_status + "\n";
   s += StringFormat("Equity %.2f  ->  target %.2f  (x%.1f)\n", equity, InpTargetEquity, InpTargetEquity / MathMax(equity, 0.01));
   s += StringFormat("Spread %.2f  |  risk %.0f%% at the stop  |  honest odds ~%.0f%%\n",
                     tk.ask - tk.bid, InpRiskPct, 100.0 * MathMax(equity, 0.0) / InpTargetEquity);
   if(g_plan != "")
      s += "Trade: " + g_plan + "\n";
   s += "About 9 in 10 runs lose the deposit. Money you can lose only.";
   Comment(s);
}
//+------------------------------------------------------------------+
