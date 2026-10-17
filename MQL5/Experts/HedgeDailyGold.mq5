//+------------------------------------------------------------------+
//|                                             HedgeDailyGold.mq5   |
//|  HedgeDaily Gold 2.1 - buy + sell hedge grid tuned for XAUUSD    |
//|                                                                  |
//|  Built from HedgeDaily 2.0 and re-tuned on 13 years of XAUUSD    |
//|  hourly data (2006-2019, see README / research/hedge_sim):       |
//|   - Grid, TP and lot size scale with the DAILY ATR. Gold swings  |
//|     $50-100 in a few days, so hourly-ATR grids were far too tight|
//|   - Lot size = % of equity lost per 1 x ATR(D1) move, so the     |
//|     risk stays the same at $1300 or $4000 gold. Risk modes:      |
//|     SAFE 0.5% (default), AGGRESSIVE 1.0%, or CUSTOM              |
//|   - Trend from D1 EMA 50/200; grid only with that trend          |
//|   - Only one side may build a grid at a time                     |
//|   - Lock and hard stop measure drawdown from the cycle's equity  |
//|     peak (a long cycle can no longer hide a 40% giveback)        |
//|   - Spread filter relative to ATR (gold spreads jump at rollover |
//|     and news), gold trading hours, USD news filter               |
//|                                                                  |
//|  Requires a HEDGING account (Exness MT5 default).                |
//|  No EA can guarantee a daily profit. Test on demo first.         |
//+------------------------------------------------------------------+
#property copyright "Naitik"
#property version   "2.10"
#property description "HedgeDaily Gold 2.1 for XAUUSD: buy+sell hedge grid with D1-ATR spacing and sizing,"
#property description "D1 trend alignment, basket TP, hedge lock, news/spread/time filters and a daily target."

#include <Trade\Trade.mqh>

enum ENUM_HD_MODE
{
   HD_TREND_ALIGNED = 0, // Trend-aligned: grid only with the D1 trend
   HD_BOTH_SIDES    = 1  // Both sides: grid on buys and sells (v1 style)
};

enum ENUM_RISK_MODE
{
   RISK_SAFE       = 0, // Safe: 0.5% per daily ATR (best survival in tests)
   RISK_AGGRESSIVE = 1, // Aggressive: 1.0% per daily ATR (more profit, ~35% drawdowns)
   RISK_CUSTOM     = 2  // Custom: use InpRiskPerATRPct
};

input group "Strategy mode"
input ENUM_HD_MODE    InpMode          = HD_TREND_ALIGNED; // Grid mode
input ENUM_TIMEFRAMES InpSignalTF      = PERIOD_H1;        // Signal timeframe (ADX, Bands, candle check)
input ENUM_TIMEFRAMES InpATRTF         = PERIOD_D1;        // ATR timeframe (grid, TP, lot size)
input ENUM_TIMEFRAMES InpTrendTF       = PERIOD_D1;        // Trend timeframe (EMAs)
input int             InpTrendFastEMA  = 50;               // Trend fast EMA
input int             InpTrendSlowEMA  = 200;              // Trend slow EMA

input group "Daily target"
input double InpDailyTargetPct    = 1.5;   // Close all & stop for the day at +% of day-start balance (0 = off)

input group "Position sizing"
input ENUM_RISK_MODE InpRiskMode  = RISK_SAFE; // Risk mode
input double InpRiskPerATRPct     = 0.5;   // Custom risk: % of equity one trade loses per 1 x ATR move
input double InpMinLotRiskCap     = 2.0;   // Use the broker minimum lot if it is at most this many x the safe lot (0 = never)
input double InpLotMultiplier     = 1.0;   // Lot multiplier per grid level (1.0 = no martingale)
input double InpMaxTotalLots      = 0.0;   // Max total open lots (0 = no cap)

input group "Grid"
input int    InpATRPeriod         = 14;    // ATR period
input double InpGridATR           = 1.5;   // Grid step = ATR x this
input double InpTpATR             = 1.5;   // Single-trade TP = ATR x this
input double InpBasketTpATR       = 0.75;  // Basket TP = average price +/- ATR x this
input double InpGridExpansion     = 1.3;   // Each next grid level is this much wider
input int    InpMaxLevels         = 4;     // Max trades per side
input bool   InpOneGridOnly       = true;  // Only one side may build a grid at a time
input double InpMinGridPrice      = 1.0;   // Minimum grid step (price, $ for gold)
input double InpMinTpPrice        = 0.75;  // Minimum TP distance (price, $ for gold)

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
input double InpLockDDPct         = 10.0;  // Lock when drawdown from the cycle's equity peak reaches this %
input double InpLockRatio         = 1.0;   // Lock volume = net exposure x this
input double InpLockTrailStartATR = 1.0;   // Start trailing the lock after ATR x this profit
input double InpLockTrailATR      = 1.0;   // Lock trailing distance = ATR x this
input double InpLockExitATR       = 1.0;   // Remove the lock if it loses ATR x this (price reverting)
input double InpRelockStepPct     = 3.0;   // Extra drawdown % needed to lock again

input group "Account protection"
input double InpHardStopPct       = 30.0;  // Close everything at this % drawdown from the cycle's peak (0 = off)
input double InpMinMarginLevel    = 300.0; // Don't open grid trades below this margin level %
input double InpMaxSpreadATRPct   = 3.0;   // Don't open trades when spread > this % of ATR
input int    InpMaxSpreadPoints   = 0;     // Optional hard spread cap in points (0 = off)

input group "Time & news"
input int    InpStartHour         = 1;     // Trading window start (server hour)
input int    InpEndHour           = 22;    // Trading window end (server hour)
input bool   InpFridayClose       = true;  // Friday: close the cycle if in profit, no new trades
input int    InpFridayCloseHour   = 20;    // Friday wind-down hour (server)
input bool   InpUseNews           = true;  // Pause new trades around high-impact USD news (live only)
input int    InpNewsBeforeMin     = 60;    // Minutes before the news
input int    InpNewsAfterMin      = 60;    // Minutes after the news

input group "Misc"
input ulong  InpMagic             = 20261021; // Magic number (lock trades use magic + 1)
input string InpComment           = "HedgeGold";
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
      Print("HedgeDaily Gold needs a HEDGING account. Open an MT5 hedging account in Exness.");
      return INIT_FAILED;
   }
   if(InpMaxLevels < 1 || InpGridATR <= 0 || InpTpATR <= 0 || InpBasketTpATR <= 0 ||
      InpGridExpansion < 1.0 || InpLotMultiplier < 1.0 || RiskPct() <= 0 || InpMinLotRiskCap < 0 ||
      InpTrendFastEMA >= InpTrendSlowEMA || InpLockRatio <= 0 || InpATRPeriod < 1)
   {
      Print("Invalid inputs: check grid, risk and EMA settings");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(StringFind(_Symbol, "XAU") < 0)
      PrintFormat("Note: HedgeDaily Gold is tuned for XAUUSD, but it is running on %s.", _Symbol);
   if(RiskPct() > 1.0)
      PrintFormat("WARNING: risk %.1f%% per ATR. In the 2006-2019 gold simulation every setting above 1.0%% "
                  "lost money and drawdowns reached 60-100%%.", RiskPct());

   hATR   = iATR(_Symbol, InpATRTF, InpATRPeriod);
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
   trade.SetDeviationInPoints(50);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_prefix = "HDG_" + IntegerToString((long)InpMagic) + "_" + _Symbol + "_";
   if(InpResetState)
   {
      GVDel("day");
      GVDel("dayBal");
      GVDel("dayDone");
      GVDel("cyclePeak");
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

   //--- cycle bookkeeping: a cycle runs from the first trade until we are flat again.
   //    Drawdown is measured from the highest equity reached during the cycle.
   int    total = ArraySize(g_pos);
   double peak  = GV("cyclePeak");
   if(total == 0 && peak > 0)
   {
      GVSet("cyclePeak", 0);
      GVSet("unlockDD", 0);
      GVSet("wasLocked", 0);
      peak = 0;
   }
   if(total > 0)
   {
      if(peak <= 0)
         peak = MathMax(balance, equity);   // restarted without saved state
      if(equity > peak)
         peak = equity;
      GVSet("cyclePeak", peak);
   }
   double cycleDD = (total > 0 && peak > 0) ? (peak - equity) / peak * 100.0 : 0.0;

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
      PrintFormat("Hard stop: drawdown %.1f%% from the cycle peak >= %.1f%%. Closed all, stopped for today.",
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
   double bDist    = MathMax(sATR * InpBasketTpATR, InpMinTpPrice);

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
   return MathMax(sATR * InpGridATR, InpMinGridPrice);
}

double TpDistance()
{
   return MathMax(sATR * InpTpATR, InpMinTpPrice);
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
      if(InpOneGridOnly && CountSide(-side) > 1)
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
      GVSet("cyclePeak", equity);
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
         PrintFormat("Hedge lock removed at drawdown %.1f%%", cycleDD);
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
         PrintFormat("Hedge lock opened: %s %.2f lots at drawdown %.1f%%",
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
   double spread = tk.ask - tk.bid;
   if(InpMaxSpreadATRPct > 0 && spread > sATR * InpMaxSpreadATRPct / 100.0)
      return StringFormat("spread %.2f > %.1f%% of ATR", spread, InpMaxSpreadATRPct);
   if(InpMaxSpreadPoints > 0 && spread / _Point > InpMaxSpreadPoints)
      return StringFormat("spread %.0f > %d points", spread / _Point, InpMaxSpreadPoints);
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

//--- High-impact calendar events for the symbol's currencies (not available in the tester).
//    For XAUUSD the base currency (XAU) has no calendar, so this watches USD news.
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

//--- money one lot makes or loses per 1.0 price move (gold: ~100 per lot)
double MoneyPerPriceUnit()
{
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0)
      return 0;
   return tickValue / tickSize;
}

double RiskPct()
{
   if(InpRiskMode == RISK_SAFE)
      return 0.5;
   if(InpRiskMode == RISK_AGGRESSIVE)
      return 1.0;
   return InpRiskPerATRPct;
}

string RiskName()
{
   if(InpRiskMode == RISK_SAFE)
      return "SAFE";
   if(InpRiskMode == RISK_AGGRESSIVE)
      return "AGGRESSIVE";
   return "CUSTOM";
}

//--- balance needed before the EA may trade the broker's minimum lot
double MinBalanceForMinLot()
{
   double perUnit = MoneyPerPriceUnit();
   if(perUnit <= 0 || sATR <= 0)
      return 0;
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   return minL * sATR * perUnit / (RiskPct() / 100.0) / MathMax(InpMinLotRiskCap, 1.0);
}

//--- base lot loses RiskPct() of equity when price moves 1 x ATR
double LotsForLevel(const int level)
{
   double perUnit = MoneyPerPriceUnit();
   if(perUnit <= 0 || sATR <= 0)
      return 0;
   double money = MathMin(AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY));
   double base  = money * RiskPct() / 100.0 / (sATR * perUnit);
   double raw   = base * MathPow(InpLotMultiplier, level);
   double minL  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(raw < minL)
   {
      // A small account may use the minimum lot if it is only a little above the safe size
      if(InpMinLotRiskCap <= 0 || minL > raw * InpMinLotRiskCap + 1e-12)
      {
         double need = MinBalanceForMinLot();
         if(g_lotWarn == "")
            PrintFormat("Balance too small for gold right now: safe lot %.4f, broker minimum %.2f, daily ATR %.2f. "
                        "Need about %.0f in account currency (or a Cent account).", raw, minL, sATR, need);
         g_lotWarn = StringFormat("Balance too small: need about %.0f for %.2f lot (Cent account recommended)", need, minL);
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

   string text = StringFormat("HedgeDaily Gold 2.1  |  %s\n", g_state);
   text += StringFormat("Mode: %s   Trend %s: %s   Market: %s (ADX %.1f)\n",
                        mode, EnumToString(InpTrendTF), trend, sRange ? "RANGE" : "TRENDING", sADX);
   text += StringFormat("Today: %+.2f%%   Target: +%.1f%%   Day-start balance: %.2f\n",
                        dayPct, InpDailyTargetPct, dayBal);
   text += StringFormat("Drawdown from cycle peak: %.1f%%   Lock at: %.1f%%   Hard stop: %.1f%%   Lock: %s\n",
                        cycleDD, InpUseLock ? InpLockDDPct : 0.0, InpHardStopPct, CountLocks() > 0 ? "ON" : "off");
   text += StringFormat("Buys: %d (%.2f lots)   Sells: %d (%.2f lots)   Open P/L: %.2f\n",
                        CountSide(1), SideLots(1), CountSide(-1), SideLots(-1), FloatingProfit());
   if(sReady)
   {
      text += StringFormat("ATR %s: %.2f   Grid step: %.2f   TP: %.2f\n",
                           EnumToString(InpATRTF), sATR, GridDistance(), TpDistance());
      text += StringFormat("Risk: %s %.1f%% per ATR   Balance needed for min lot: %.0f\n",
                           RiskName(), RiskPct(), MinBalanceForMinLot());
   }
   if(g_lotWarn != "")
      text += g_lotWarn + "\n";
   if(g_news != "")
      text += "News: " + g_news + "\n";
   Comment(text);
}
//+------------------------------------------------------------------+
