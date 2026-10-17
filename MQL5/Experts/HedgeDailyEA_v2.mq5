//+------------------------------------------------------------------+
//|                                             HedgeDailyEA_v2.mq5  |
//|  HedgeDaily 2.0 - adaptive buy + sell hedge grid                 |
//|                                                                  |
//|  What changed vs v1 (see README for the simulation results):     |
//|   - Lot size from min(balance, equity), never from balance alone |
//|   - ATR-based grid step / TP, widening grid levels               |
//|   - Trend-aligned mode: grid only in the higher-TF trend         |
//|   - Basket take profit at the volume-weighted average price      |
//|   - Hedge lock instead of a stop loss when drawdown gets deep    |
//|   - Range filter for new cycles, smart grid entries              |
//|   - News, spread, margin, session and Friday filters             |
//|   - Daily target measured on the day-start balance               |
//|                                                                  |
//|  Requires a HEDGING account (Exness MT5 default).                |
//|  No EA can guarantee a daily profit. Test on demo first.         |
//+------------------------------------------------------------------+
#property copyright "Naitik"
#property version   "2.00"
#property description "HedgeDaily 2.0: buy+sell hedge grid with trend alignment, ATR spacing,"
#property description "basket TP, hedge lock, news/time filters and a daily profit target."

#include <Trade\Trade.mqh>

enum ENUM_HD_MODE
{
   HD_TREND_ALIGNED = 0, // Trend-aligned: grid only with the higher-TF trend
   HD_BOTH_SIDES    = 1  // Both sides: grid on buys and sells (v1 style)
};

input group "Strategy mode"
input ENUM_HD_MODE    InpMode          = HD_TREND_ALIGNED; // Grid mode
input ENUM_TIMEFRAMES InpSignalTF      = PERIOD_H1;        // Signal timeframe (ATR, ADX, Bands)
input ENUM_TIMEFRAMES InpTrendTF       = PERIOD_H4;        // Trend timeframe (EMAs)
input int             InpTrendFastEMA  = 50;               // Trend fast EMA
input int             InpTrendSlowEMA  = 200;              // Trend slow EMA

input group "Daily target"
input double InpDailyTargetPct    = 1.5;   // Close all & stop for the day at +% of day-start balance (0 = off)

input group "Position sizing"
input double InpMoneyPer001Lot    = 300.0; // Account money per 0.01 lot (higher = safer)
input double InpLotMultiplier     = 1.0;   // Lot multiplier per grid level (1.0 = no martingale)
input double InpMaxTotalLots      = 0.0;   // Max total open lots (0 = no cap)
input bool   InpAllowMinLot       = false; // Trade the broker minimum lot even if it is above the safe size

input group "Grid"
input int    InpATRPeriod         = 14;    // ATR period
input double InpGridATR           = 2.0;   // Grid step = ATR x this
input double InpTpATR             = 2.0;   // Single-trade TP = ATR x this
input double InpBasketTpATR       = 1.0;   // Basket TP = average price +/- ATR x this
input double InpGridExpansion     = 1.3;   // Each next grid level is this much wider
input int    InpMaxLevels         = 4;     // Max trades per side
input int    InpMinGridPoints     = 80;    // Minimum grid step (points)
input int    InpMinTpPoints       = 60;    // Minimum TP distance (points)

input group "Market filters"
input int    InpADXPeriod         = 14;    // ADX (Wilder) period
input double InpADXRange          = 25.0;  // New cycle only when ADX is below this
input double InpADXTrend          = 30.0;  // Don't add against a trend stronger than this
input int    InpBandsPeriod       = 20;    // Bollinger period
input double InpBandsDev          = 2.0;   // Bollinger deviation
input bool   InpStartInRange      = true;  // Start new cycles only in a ranging market
input bool   InpSmartAdd          = true;  // Add a level only after a candle closes in its favour
input bool   InpBlockCounterTrend = true;  // Block adds against a strong ADX trend

input group "Hedge lock (protection without a stop loss)"
input bool   InpUseLock           = true;  // Freeze the net exposure in deep drawdown
input double InpLockDDPct         = 10.0;  // Lock when cycle drawdown reaches this %
input double InpLockRatio         = 1.0;   // Lock volume = net exposure x this
input double InpLockTrailStartATR = 1.0;   // Start trailing the lock after ATR x this profit
input double InpLockTrailATR      = 1.0;   // Lock trailing distance = ATR x this
input double InpLockExitATR       = 1.0;   // Remove the lock if it loses ATR x this (price reverting)
input double InpRelockStepPct     = 3.0;   // Extra drawdown % needed to lock again

input group "Account protection"
input double InpHardStopPct       = 30.0;  // Close the whole cycle at this % drawdown (0 = off)
input double InpMinMarginLevel    = 300.0; // Don't open grid trades below this margin level %
input int    InpMaxSpreadPoints   = 30;    // Don't open trades when spread is above this (points)

input group "Time & news"
input int    InpStartHour         = 1;     // Trading window start (server hour)
input int    InpEndHour           = 22;    // Trading window end (server hour)
input bool   InpFridayClose       = true;  // Friday: close the cycle if in profit, no new trades
input int    InpFridayCloseHour   = 20;    // Friday wind-down hour (server)
input bool   InpUseNews           = true;  // Pause new trades around high-impact news (live only)
input int    InpNewsBeforeMin     = 60;    // Minutes before the news
input int    InpNewsAfterMin      = 30;    // Minutes after the news

input group "Misc"
input ulong  InpMagic             = 20261020; // Magic number (lock trades use magic + 1)
input string InpComment           = "HedgeDaily2";
input bool   InpResetState        = false;    // Clear saved day/cycle state on load

//--- one of our open positions
struct SPos
{
   ulong  ticket;
   int    side;    // +1 buy, -1 sell
   double lots;
   double price;
   double tp;
   double sl;
   double profit;  // profit + swap
   bool   lock;
};

CTrade   trade;
SPos     g_pos[];
ulong    g_lockMagic;
string   g_prefix;
int      hATR = INVALID_HANDLE, hADX = INVALID_HANDLE, hBands = INVALID_HANDLE;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE;

//--- signal values of the last closed bar
double   sATR = 0, sADX = 0, sPDI = 0, sMDI = 0, sUpper = 0, sLower = 0;
double   sClose = 0, sOpen = 0, sFast = 0, sSlow = 0;
int      sBias = 0;       // +1 up, -1 down, 0 no trend
bool     sRange = false;
bool     sReady = false;

string   g_state   = "";
string   g_news    = "";
string   g_lotWarn = "";
datetime g_modifyPause = 0;

//+------------------------------------------------------------------+
//| Saved state (survives terminal restarts)                         |
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
   GlobalVariableDel(g_prefix + key);
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("HedgeDaily 2.0 needs a HEDGING account. Open an MT5 hedging account in Exness.");
      return INIT_FAILED;
   }
   if(InpMaxLevels < 1 || InpGridATR <= 0 || InpTpATR <= 0 || InpBasketTpATR <= 0 ||
      InpGridExpansion < 1.0 || InpLotMultiplier < 1.0 || InpMoneyPer001Lot <= 0 ||
      InpTrendFastEMA >= InpTrendSlowEMA || InpLockRatio <= 0 || InpATRPeriod < 1)
   {
      Print("Invalid inputs: check grid, lot and EMA settings");
      return INIT_PARAMETERS_INCORRECT;
   }

   hATR   = iATR(_Symbol, InpSignalTF, InpATRPeriod);
   hADX   = iADXWilder(_Symbol, InpSignalTF, InpADXPeriod);
   hBands = iBands(_Symbol, InpSignalTF, InpBandsPeriod, 0, InpBandsDev, PRICE_CLOSE);
   hFast  = iMA(_Symbol, InpTrendTF, InpTrendFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow  = iMA(_Symbol, InpTrendTF, InpTrendSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(hATR == INVALID_HANDLE || hADX == INVALID_HANDLE || hBands == INVALID_HANDLE ||
      hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return INIT_FAILED;
   }

   g_lockMagic = InpMagic + 1;
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_prefix = "HD2_" + IntegerToString((long)InpMagic) + "_" + _Symbol + "_";
   if(InpResetState)
   {
      GVDel("day");
      GVDel("dayBal");
      GVDel("dayDone");
      GVDel("cycleEq");
      GVDel("unlockDD");
      GVDel("wasLocked");
   }
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hATR);
   IndicatorRelease(hADX);
   IndicatorRelease(hBands);
   IndicatorRelease(hFast);
   IndicatorRelease(hSlow);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk) || tk.bid <= 0 || tk.ask <= 0)
      return;

   ScanPositions();
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   UpdateDay(balance);
   sReady = ReadSignals();

   //--- cycle bookkeeping: a cycle runs from the first trade until we are flat again
   int    total   = ArraySize(g_pos);
   double cycleEq = GV("cycleEq");
   if(total == 0 && cycleEq > 0)
   {
      GVSet("cycleEq", 0);
      GVSet("unlockDD", 0);
      GVSet("wasLocked", 0);
      cycleEq = 0;
   }
   if(total > 0 && cycleEq <= 0)
   {
      cycleEq = balance;   // restarted without saved state
      GVSet("cycleEq", cycleEq);
   }
   double cycleDD = (total > 0 && cycleEq > 0) ? (cycleEq - equity) / cycleEq * 100.0 : 0.0;

   //--- day finished (target or hard stop): make sure we are flat, then idle
   if(GV("dayDone") > 0)
   {
      if(total > 0)
         CloseAll();
      g_state = "Day finished (target or hard stop) - waiting for the next day";
      ShowPanel(equity, balance, cycleDD);
      return;
   }

   double dayBal = GV("dayBal", balance);
   if(InpDailyTargetPct > 0 && equity >= dayBal * (1.0 + InpDailyTargetPct / 100.0))
   {
      CloseAll();
      GVSet("dayDone", 1);
      PrintFormat("Daily target reached: equity %.2f vs day start %.2f (+%.2f%%). Stopped for today.",
                  equity, dayBal, (equity - dayBal) / dayBal * 100.0);
      return;
   }
   if(InpHardStopPct > 0 && cycleDD >= InpHardStopPct)
   {
      CloseAll();
      GVSet("dayDone", 1);
      PrintFormat("Hard stop: cycle drawdown %.1f%% >= %.1f%%. Closed all, stopped for today.",
                  cycleDD, InpHardStopPct);
      return;
   }

   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(InpFridayClose && t.day_of_week == 5 && t.hour >= InpFridayCloseHour)
   {
      if(total > 0 && FloatingProfit() >= 0)
         CloseAll();
      g_state = "Friday wind-down: no new trades";
      ShowPanel(equity, balance, cycleDD);
      return;
   }

   if(!sReady)
   {
      g_state = "Waiting for indicator data";
      ShowPanel(equity, balance, cycleDD);
      return;
   }

   //--- hedge lock: freeze the net exposure instead of taking a stop loss
   //    (an existing lock is still managed if the lock input was switched off)
   if(InpUseLock || CountLocks() > 0)
   {
      ManageLock(tk, cycleDD);
      ScanPositions();
   }
   if(CountLocks() > 0)
   {
      g_state = "LOCKED - net exposure frozen, waiting for the trend to end";
      ShowPanel(equity, balance, cycleDD);
      return;
   }

   double gridDist = GridDistance();
   double tpDist   = TpDistance();
   double bDist    = MathMax(sATR * InpBasketTpATR, InpMinTpPoints * _Point);

   string block = EntryBlockReason(tk, t);
   if(block == "")
   {
      ManageSide(+1, gridDist, tpDist, equity);
      ManageSide(-1, gridDist, tpDist, equity);
      g_state = "Running";
   }
   else
      g_state = "No new trades: " + block;

   SymbolInfoTick(_Symbol, tk);
   UpdateBasket(+1, tk, bDist, tpDist);
   UpdateBasket(-1, tk, bDist, tpDist);
   ScanPositions();
   ShowPanel(equity, balance, cycleDD);
}

//+------------------------------------------------------------------+
//| New server day: remember the starting balance                    |
//+------------------------------------------------------------------+
void UpdateDay(const double balance)
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   double key = t.year * 10000.0 + t.mon * 100.0 + t.day;
   if(GV("day") != key)
   {
      GVSet("day", key);
      GVSet("dayBal", balance);
      GVSet("dayDone", 0);
   }
}

//+------------------------------------------------------------------+
//| Indicator values of the last closed bar                          |
//+------------------------------------------------------------------+
bool CopyValue(const int handle, const int buffer, double &value)
{
   double b[];
   if(CopyBuffer(handle, buffer, 1, 1, b) != 1)
      return false;
   value = b[0];
   return true;
}

bool ReadSignals()
{
   if(!CopyValue(hATR, 0, sATR) || !CopyValue(hADX, 0, sADX) ||
      !CopyValue(hADX, 1, sPDI) || !CopyValue(hADX, 2, sMDI) ||
      !CopyValue(hBands, 1, sUpper) || !CopyValue(hBands, 2, sLower) ||
      !CopyValue(hFast, 0, sFast) || !CopyValue(hSlow, 0, sSlow))
      return false;

   sClose = iClose(_Symbol, InpSignalTF, 1);
   sOpen  = iOpen(_Symbol, InpSignalTF, 1);
   if(sATR <= 0 || sClose <= 0 || sOpen <= 0)
      return false;

   sBias = 0;
   if(sFast > sSlow && sClose > sSlow)
      sBias = 1;
   else if(sFast < sSlow && sClose < sSlow)
      sBias = -1;

   sRange = sADX < InpADXRange && sClose > sLower && sClose < sUpper;
   return true;
}

double GridDistance()
{
   return MathMax(sATR * InpGridATR, InpMinGridPoints * _Point);
}

double TpDistance()
{
   return MathMax(sATR * InpTpATR, InpMinTpPoints * _Point);
}

//+------------------------------------------------------------------+
//| Positions                                                        |
//+------------------------------------------------------------------+
void ScanPositions()
{
   ArrayResize(g_pos, 0);
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(magic != InpMagic && magic != g_lockMagic)
         continue;

      int n = ArraySize(g_pos);
      ArrayResize(g_pos, n + 1);
      g_pos[n].ticket = ticket;
      g_pos[n].side   = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1;
      g_pos[n].lots   = PositionGetDouble(POSITION_VOLUME);
      g_pos[n].price  = PositionGetDouble(POSITION_PRICE_OPEN);
      g_pos[n].tp     = PositionGetDouble(POSITION_TP);
      g_pos[n].sl     = PositionGetDouble(POSITION_SL);
      g_pos[n].profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      g_pos[n].lock   = magic == g_lockMagic;
   }
}

int CountSide(const int side)
{
   int n = 0;
   for(int i = 0; i < ArraySize(g_pos); i++)
      if(!g_pos[i].lock && g_pos[i].side == side)
         n++;
   return n;
}

double SideLots(const int side)
{
   double v = 0;
   for(int i = 0; i < ArraySize(g_pos); i++)
      if(!g_pos[i].lock && g_pos[i].side == side)
         v += g_pos[i].lots;
   return v;
}

int CountLocks()
{
   int n = 0;
   for(int i = 0; i < ArraySize(g_pos); i++)
      if(g_pos[i].lock)
         n++;
   return n;
}

double NetGridLots()
{
   return SideLots(1) - SideLots(-1);
}

double TotalLots()
{
   double v = 0;
   for(int i = 0; i < ArraySize(g_pos); i++)
      v += g_pos[i].lots;
   return v;
}

double FloatingProfit()
{
   double p = 0;
   for(int i = 0; i < ArraySize(g_pos); i++)
      p += g_pos[i].profit;
   return p;
}

//--- lowest buy / highest sell of the grid
double WorstPrice(const int side)
{
   double worst = 0;
   bool   found = false;
   for(int i = 0; i < ArraySize(g_pos); i++)
   {
      if(g_pos[i].lock || g_pos[i].side != side)
         continue;
      if(!found || (side > 0 && g_pos[i].price < worst) || (side < 0 && g_pos[i].price > worst))
         worst = g_pos[i].price;
      found = true;
   }
   return worst;
}

//+------------------------------------------------------------------+
//| Grid: open the first trade of a side, or add a level             |
//+------------------------------------------------------------------+
void ManageSide(const int side, const double gridDist, const double tpDist, const double equity)
{
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;
   ScanPositions();

   int n = CountSide(side);
   if(n == 0)
   {
      // A brand-new cycle waits for a quiet market; a hedge leg inside a cycle reopens at once
      if(ArraySize(g_pos) == 0 && InpStartInRange && !sRange)
         return;
   }
   else
   {
      if(n >= InpMaxLevels)
         return;
      if(InpMode == HD_TREND_ALIGNED && sBias != side)
         return;

      double step = gridDist * MathPow(InpGridExpansion, n - 1);
      double worst = WorstPrice(side);
      if(side > 0 && tk.ask > worst - step)
         return;
      if(side < 0 && tk.bid < worst + step)
         return;

      if(InpBlockCounterTrend && sADX > InpADXTrend)
      {
         if(side > 0 && sMDI > sPDI)
            return;
         if(side < 0 && sPDI > sMDI)
            return;
      }
      if(InpSmartAdd)
      {
         if(side > 0 && !(sClose > sOpen))
            return;
         if(side < 0 && !(sClose < sOpen))
            return;
      }
   }

   double lots = LotsForLevel(n);
   if(lots <= 0)
      return;
   if(InpMaxTotalLots > 0 && TotalLots() + lots > InpMaxTotalLots + 1e-9)
      return;
   if(!MarginOK(side, lots, tk))
      return;

   double price = side > 0 ? tk.ask : tk.bid;
   double tp    = NormalizeDouble(price + side * tpDist, _Digits);
   if(!TPValid(side, tp, tk))
      tp = 0;
   if(ArraySize(g_pos) == 0)
      GVSet("cycleEq", equity);
   OpenPosition(side, lots, tp, InpMagic, StringFormat("%s L%d", InpComment, n + 1));
}

//+------------------------------------------------------------------+
//| Basket TP: all trades of a side share one TP at the average price |
//+------------------------------------------------------------------+
void UpdateBasket(const int side, const MqlTick &tk, const double bDist, const double tpDist)
{
   ScanPositions();
   int n = CountSide(side);
   if(n == 0)
      return;

   if(n == 1)
   {
      for(int i = 0; i < ArraySize(g_pos); i++)
      {
         if(g_pos[i].lock || g_pos[i].side != side || g_pos[i].tp > 0)
            continue;
         // TP was removed by a lock: restore it
         double tp = NormalizeDouble(g_pos[i].price + side * tpDist, _Digits);
         if((side > 0 && tk.bid >= tp) || (side < 0 && tk.ask <= tp))
            ClosePosition(g_pos[i].ticket);
         else if(TPValid(side, tp, tk))
            ModifyPosition(g_pos[i].ticket, g_pos[i].sl, tp);
      }
      return;
   }

   double vol = 0, sum = 0;
   for(int i = 0; i < ArraySize(g_pos); i++)
   {
      if(g_pos[i].lock || g_pos[i].side != side)
         continue;
      vol += g_pos[i].lots;
      sum += g_pos[i].lots * g_pos[i].price;
   }
   if(vol <= 0)
      return;
   double target = NormalizeDouble(sum / vol + side * bDist, _Digits);

   // Already past the basket target: take it now
   if((side > 0 && tk.bid >= target) || (side < 0 && tk.ask <= target))
   {
      CloseSide(side);
      return;
   }
   if(!TPValid(side, target, tk))
      return;
   for(int i = 0; i < ArraySize(g_pos); i++)
   {
      if(g_pos[i].lock || g_pos[i].side != side)
         continue;
      if(MathAbs(g_pos[i].tp - target) > _Point / 2.0)
         ModifyPosition(g_pos[i].ticket, g_pos[i].sl, target);
   }
}

//+------------------------------------------------------------------+
//| Hedge lock                                                        |
//|  - Drawdown >= InpLockDDPct: open the opposite side for the net   |
//|    exposure, so the floating loss stops growing.                  |
//|  - The lock is trailed once in profit (trend continues, then ends)|
//|    and removed if price reverts against it (grid recovers).       |
//|  - After an unlock, the next lock needs InpRelockStepPct more DD. |
//+------------------------------------------------------------------+
void ManageLock(const MqlTick &tk, const double cycleDD)
{
   if(CountLocks() == 0)
   {
      if(GV("wasLocked") > 0)
      {
         GVSet("wasLocked", 0);
         GVSet("unlockDD", MathMax(cycleDD, 0.0));
         PrintFormat("Hedge lock removed at cycle drawdown %.1f%%", cycleDD);
      }
      if(!InpUseLock || ArraySize(g_pos) == 0)
         return;

      double threshold  = InpLockDDPct;
      double lastUnlock = GV("unlockDD");
      if(lastUnlock > 0)
         threshold = MathMax(threshold, lastUnlock + InpRelockStepPct);
      if(cycleDD < threshold)
         return;

      double net  = NetGridLots();
      double lots = NormalizeVolume(MathAbs(net) * InpLockRatio);
      if(lots <= 0)
         return;
      int side = net > 0 ? -1 : 1;
      if(OpenPosition(side, lots, 0.0, g_lockMagic, InpComment + " LOCK"))
      {
         GVSet("wasLocked", 1);
         PrintFormat("Hedge lock opened: %s %.2f lots at cycle drawdown %.1f%%",
                     side > 0 ? "BUY" : "SELL", lots, cycleDD);
         // Remove grid TPs so one side cannot close alone while we are locked
         for(int i = 0; i < ArraySize(g_pos); i++)
            if(!g_pos[i].lock && g_pos[i].tp > 0)
               ModifyPosition(g_pos[i].ticket, g_pos[i].sl, 0.0);
      }
      return;
   }

   for(int i = 0; i < ArraySize(g_pos); i++)
   {
      if(!g_pos[i].lock)
         continue;
      int    s    = g_pos[i].side;
      double prof = s > 0 ? tk.bid - g_pos[i].price : g_pos[i].price - tk.ask;

      if(InpLockExitATR > 0 && prof <= -InpLockExitATR * sATR)
      {
         ClosePosition(g_pos[i].ticket);
         continue;
      }
      if(prof >= InpLockTrailStartATR * sATR)
      {
         double sl = NormalizeDouble(s > 0 ? tk.bid - InpLockTrailATR * sATR
                                           : tk.ask + InpLockTrailATR * sATR, _Digits);
         bool better = s > 0 ? sl > g_pos[i].sl + _Point
                             : (g_pos[i].sl == 0 || sl < g_pos[i].sl - _Point);
         if(better && SLValid(s, sl, tk))
            ModifyPosition(g_pos[i].ticket, sl, g_pos[i].tp);
      }
   }
}

//+------------------------------------------------------------------+
//| Filters                                                           |
//+------------------------------------------------------------------+
string EntryBlockReason(const MqlTick &tk, const MqlDateTime &t)
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return "Algo Trading is disabled";
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
      return "symbol is not fully tradable";
   if(t.day_of_week == 0 || t.day_of_week == 6)
      return "weekend";
   if(!InHours(t.hour))
      return "outside trading hours";
   double spread = (tk.ask - tk.bid) / _Point;
   if(spread > InpMaxSpreadPoints)
      return StringFormat("spread %.0f > %d points", spread, InpMaxSpreadPoints);
   double ml = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(ml > 0 && ml < InpMinMarginLevel)
      return StringFormat("margin level %.0f%%", ml);
   if(NewsBlocked())
      return "news " + g_news;
   return "";
}

bool InHours(const int hour)
{
   if(InpStartHour <= InpEndHour)
      return hour >= InpStartHour && hour < InpEndHour;
   return hour >= InpStartHour || hour < InpEndHour; // window crosses midnight
}

//--- High-impact calendar events for the symbol's currencies (not available in the tester)
bool NewsBlocked()
{
   if(!InpUseNews || MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION))
      return false;

   static datetime lastCheck = 0;
   static bool     blocked   = false;
   datetime now = TimeTradeServer();
   if(now - lastCheck < 60)
      return blocked;
   lastCheck = now;
   blocked   = false;
   g_news    = "";

   string ccy[2];
   ccy[0] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   ccy[1] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   for(int k = 0; k < 2 && !blocked; k++)
   {
      if(ccy[k] == "" || (k == 1 && ccy[1] == ccy[0]))
         continue;
      MqlCalendarValue values[];
      datetime from = (datetime)(now - InpNewsAfterMin * 60);
      datetime to   = (datetime)(now + InpNewsBeforeMin * 60);
      if(!CalendarValueHistory(values, from, to, NULL, ccy[k]))
         continue;
      for(int i = 0; i < ArraySize(values); i++)
      {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev) || ev.importance != CALENDAR_IMPORTANCE_HIGH)
            continue;
         blocked = true;
         g_news  = ccy[k] + " " + ev.name + " at " + TimeToString(values[i].time, TIME_MINUTES);
         break;
      }
   }
   return blocked;
}

//+------------------------------------------------------------------+
//| Sizing and margin                                                 |
//+------------------------------------------------------------------+
double NormalizeVolume(double v)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0)
      step = 0.01;
   v = MathFloor(v / step + 1e-9) * step;
   if(v < minL - 1e-12)
      return 0;
   v = MathMin(v, maxL);
   int digits = (int)MathMax(0.0, MathCeil(-MathLog10(step) - 1e-9));
   return NormalizeDouble(v, digits);
}

double LotsForLevel(const int level)
{
   double base = MathMin(AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY)) /
                 InpMoneyPer001Lot * 0.01;
   double raw  = base * MathPow(InpLotMultiplier, level);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(raw < minL)
   {
      if(!InpAllowMinLot)
      {
         if(g_lotWarn == "")
            PrintFormat("Safe lot %.4f is below the broker minimum %.2f. Use a Cent account, add balance, "
                        "or set InpAllowMinLot = true (higher risk).", raw, minL);
         g_lotWarn = StringFormat("Balance too small: safe lot %.4f < min %.2f (use a Cent account)", raw, minL);
         return 0;
      }
      raw = minL;
   }
   g_lotWarn = "";
   return NormalizeVolume(raw);
}

bool MarginOK(const int side, const double lots, const MqlTick &tk)
{
   double margin;
   ENUM_ORDER_TYPE type = side > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price = side > 0 ? tk.ask : tk.bid;
   if(!OrderCalcMargin(type, _Symbol, lots, price, margin))
      return true; // cannot estimate: let the server decide
   if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9)
      return false;
   double used = AccountInfoDouble(ACCOUNT_MARGIN) + margin;
   if(used > 0 && AccountInfoDouble(ACCOUNT_EQUITY) / used * 100.0 < InpMinMarginLevel)
      return false;
   return true;
}

//+------------------------------------------------------------------+
//| Stop levels                                                       |
//+------------------------------------------------------------------+
double MinStopDistance()
{
   double lvl = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double frz = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (MathMax(lvl, frz) + 1.0) * _Point;
}

bool TPValid(const int side, const double tp, const MqlTick &tk)
{
   double d = MinStopDistance();
   return side > 0 ? tp >= tk.bid + d : tp <= tk.ask - d;
}

bool SLValid(const int side, const double sl, const MqlTick &tk)
{
   double d = MinStopDistance();
   return side > 0 ? sl <= tk.bid - d : sl >= tk.ask + d;
}

//+------------------------------------------------------------------+
//| Trade operations                                                  |
//+------------------------------------------------------------------+
bool OpenPosition(const int side, const double lots, const double tp, const ulong magic, const string comment)
{
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return false;
   trade.SetExpertMagicNumber(magic);
   bool ok = side > 0 ? trade.Buy(lots, _Symbol, tk.ask, 0.0, tp, comment)
                      : trade.Sell(lots, _Symbol, tk.bid, 0.0, tp, comment);
   trade.SetExpertMagicNumber(InpMagic);
   uint rc = trade.ResultRetcode();
   if(!ok || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED && rc != TRADE_RETCODE_DONE_PARTIAL))
   {
      PrintFormat("%s %.2f failed: %u %s", side > 0 ? "Buy" : "Sell", lots, rc, trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

bool ClosePosition(const ulong ticket)
{
   if(trade.PositionClose(ticket))
      return true;
   PrintFormat("Close #%I64u failed: %u %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   return false;
}

//--- after a rejected modification, pause modifications for 30 s instead of retrying every tick
bool ModifyPosition(const ulong ticket, const double sl, const double tp)
{
   if(TimeCurrent() < g_modifyPause)
      return false;
   if(trade.PositionModify(ticket, sl, tp))
      return true;
   PrintFormat("Modify #%I64u failed: %u %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   g_modifyPause = TimeCurrent() + 30;
   return false;
}

void CloseSide(const int side)
{
   for(int i = ArraySize(g_pos) - 1; i >= 0; i--)
      if(!g_pos[i].lock && g_pos[i].side == side)
         ClosePosition(g_pos[i].ticket);
   ScanPositions();
}

void CloseAll()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(magic == InpMagic || magic == g_lockMagic)
         ClosePosition(ticket);
   }
   ScanPositions();
}

//+------------------------------------------------------------------+
//| On-chart dashboard                                                |
//+------------------------------------------------------------------+
void ShowPanel(const double equity, const double balance, const double cycleDD)
{
   double dayBal = GV("dayBal", balance);
   double dayPct = dayBal > 0 ? (equity - dayBal) / dayBal * 100.0 : 0.0;
   string trend  = sBias > 0 ? "UP" : (sBias < 0 ? "DOWN" : "FLAT");
   string mode   = InpMode == HD_TREND_ALIGNED ? "Trend-aligned" : "Both sides";
   double point  = _Point > 0 ? _Point : 1.0;

   string text = StringFormat("HedgeDaily 2.0  |  %s\n", g_state);
   text += StringFormat("Mode: %s   Trend %s: %s   Market: %s (ADX %.1f)\n",
                        mode, EnumToString(InpTrendTF), trend, sRange ? "RANGE" : "TRENDING", sADX);
   text += StringFormat("Today: %+.2f%%   Target: +%.1f%%   Day-start balance: %.2f\n",
                        dayPct, InpDailyTargetPct, dayBal);
   text += StringFormat("Cycle drawdown: %.1f%%   Lock at: %.1f%%   Hard stop: %.1f%%   Lock: %s\n",
                        cycleDD, InpUseLock ? InpLockDDPct : 0.0, InpHardStopPct, CountLocks() > 0 ? "ON" : "off");
   text += StringFormat("Buys: %d (%.2f lots)   Sells: %d (%.2f lots)   Open P/L: %.2f\n",
                        CountSide(1), SideLots(1), CountSide(-1), SideLots(-1), FloatingProfit());
   if(sReady)
      text += StringFormat("ATR: %.0f pts   Grid step: %.0f pts   TP: %.0f pts\n",
                           sATR / point, GridDistance() / point, TpDistance() / point);
   if(g_lotWarn != "")
      text += g_lotWarn + "\n";
   if(g_news != "")
      text += "News: " + g_news + "\n";
   Comment(text);
}
//+------------------------------------------------------------------+
