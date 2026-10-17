//+------------------------------------------------------------------+
//|                                                HedgeDailyEA.mq5  |
//|  Hedge grid EA: keeps a buy and a sell open, banks small TPs,    |
//|  grids the losing side, and closes everything once the daily     |
//|  profit target is reached. No per-trade stop loss.               |
//|                                                                  |
//|  WARNING: With no SL, a strong one-way trend builds a growing    |
//|  floating loss. The equity stop is the only thing that limits it.|
//|  Requires a HEDGING account (Exness MT5 default).                |
//+------------------------------------------------------------------+
#property copyright "Naitik"
#property version   "1.00"
#property description "Buy + sell hedge grid with a daily % profit target. No per-trade SL."

#include <Trade\Trade.mqh>

input group "Daily target"
input double InpDailyTargetPct   = 1.5;   // Close all & stop for the day at this % gain
input double InpBasketProfitPct  = 0.3;   // Close all & restart when open trades net this % of equity

input group "Lots"
input double InpLotPer100        = 0.01;  // Lot size per $100 of balance
input double InpLotMultiplier    = 1.0;   // Lot multiplier per grid level (1.0 = no martingale)

input group "Grid"
input int    InpTakeProfitPoints = 150;   // TP for each trade (points)
input int    InpGridStepPoints   = 200;   // Add to the losing side every this many points
input int    InpMaxLevels        = 6;     // Max trades per side

input group "Account protection"
input double InpEquityStopPct    = 40.0;  // Close all if equity falls this % below day start (0 = off)

input group "Filters"
input int    InpMaxSpreadPoints  = 30;    // Don't open trades when spread is above this
input int    InpStartHour        = 1;     // Trading window start (server hour)
input int    InpEndHour          = 22;    // Trading window end (server hour)

input group "Misc"
input ulong  InpMagic            = 20261019;
input string InpComment          = "HedgeDaily";

CTrade trade;
string gvDayDate, gvDayStart, gvDayDone;

//+------------------------------------------------------------------+
int OnInit()
{
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("This EA needs a HEDGING account. Open an MT5 hedging account in Exness.");
      return INIT_FAILED;
   }
   if(InpTakeProfitPoints <= 0 || InpGridStepPoints <= 0 || InpMaxLevels < 1 ||
      InpLotPer100 <= 0 || InpLotMultiplier < 1.0 || InpDailyTargetPct <= 0)
   {
      Print("Invalid inputs");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFillingBySymbol(_Symbol);

   string prefix = "HDEA_" + IntegerToString((long)InpMagic) + "_" + _Symbol + "_";
   gvDayDate  = prefix + "daydate";
   gvDayStart = prefix + "daystart";
   gvDayDone  = prefix + "daydone";
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   NewDayCheck();
   double dayStart = GlobalVariableGet(gvDayStart);
   double dayPct   = dayStart > 0 ? (equity - dayStart) / dayStart * 100.0 : 0;

   if(GlobalVariableGet(gvDayDone) > 0)
   {
      ShowStatus(equity, dayStart, dayPct, "Daily target done - waiting for tomorrow");
      return;
   }

   // Daily target reached: bank it and stop for today
   if(dayPct >= InpDailyTargetPct)
   {
      CloseAll();
      GlobalVariableSet(gvDayDone, 1);
      PrintFormat("Daily target hit: +%.2f%% (%.2f). Stopped for today.", dayPct, equity - dayStart);
      return;
   }

   // Emergency equity stop
   if(InpEquityStopPct > 0 && dayPct <= -InpEquityStopPct)
   {
      CloseAll();
      GlobalVariableSet(gvDayDone, 1);
      PrintFormat("Equity stop hit: %.2f%%. Closed all, stopped for today.", dayPct);
      return;
   }

   // Basket close: open trades together are in profit -> clear the grid and restart
   double openProfit = OpenProfit();
   if(CountSide(POSITION_TYPE_BUY) + CountSide(POSITION_TYPE_SELL) > 2 &&
      openProfit >= equity * InpBasketProfitPct / 100.0)
   {
      CloseAll();
      PrintFormat("Basket closed in profit: %.2f", openProfit);
      return;
   }

   ShowStatus(equity, dayStart, dayPct, "Running");

   if(!TradingTimeOK() || !SpreadOK())
      return;

   ManageSide(POSITION_TYPE_BUY);
   ManageSide(POSITION_TYPE_SELL);
}

//+------------------------------------------------------------------+
//| Keep one trade per side; add to a side when it is losing by a     |
//| grid step (up to InpMaxLevels).                                   |
//+------------------------------------------------------------------+
void ManageSide(ENUM_POSITION_TYPE side)
{
   int    count;
   double worstOpen;   // lowest buy / highest sell
   SideInfo(side, count, worstOpen);

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double grid  = InpGridStepPoints * point;

   bool open = false;
   if(count == 0)
      open = true;
   else if(count < InpMaxLevels)
   {
      if(side == POSITION_TYPE_BUY  && ask <= worstOpen - grid) open = true;
      if(side == POSITION_TYPE_SELL && bid >= worstOpen + grid) open = true;
   }
   if(!open)
      return;

   double lots = LotsForLevel(count);
   if(lots <= 0)
      return;

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double tp     = InpTakeProfitPoints * point;
   if(side == POSITION_TYPE_BUY)
   {
      if(!trade.Buy(lots, _Symbol, ask, 0, NormalizeDouble(ask + tp, digits), InpComment))
         Print("Buy failed: ", trade.ResultRetcodeDescription());
   }
   else
   {
      if(!trade.Sell(lots, _Symbol, bid, 0, NormalizeDouble(bid - tp, digits), InpComment))
         Print("Sell failed: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
double LotsForLevel(int level)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double base = AccountInfoDouble(ACCOUNT_BALANCE) / 100.0 * InpLotPer100;
   double lots = base * MathPow(InpLotMultiplier, level);
   lots = MathFloor(lots / step) * step;
   lots = MathMax(minL, MathMin(maxL, lots));

   double margin;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lots, SymbolInfoDouble(_Symbol, SYMBOL_ASK), margin) &&
      margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.8)
   {
      Print("Not enough free margin for another trade");
      return 0;
   }

   int volDigits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(lots, volDigits);
}

//+------------------------------------------------------------------+
void NewDayCheck()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   double today = t.year * 10000 + t.mon * 100 + t.day;
   if(!GlobalVariableCheck(gvDayDate) || GlobalVariableGet(gvDayDate) != today)
   {
      GlobalVariableSet(gvDayDate, today);
      GlobalVariableSet(gvDayStart, AccountInfoDouble(ACCOUNT_EQUITY));
      GlobalVariableSet(gvDayDone, 0);
   }
}

bool IsOurPosition()
{
   return PositionGetString(POSITION_SYMBOL) == _Symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic;
}

void SideInfo(ENUM_POSITION_TYPE side, int &count, double &worstOpen)
{
   count = 0;
   worstOpen = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0 || !IsOurPosition() ||
         PositionGetInteger(POSITION_TYPE) != side)
         continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      if(count == 0 ||
         (side == POSITION_TYPE_BUY  && open < worstOpen) ||
         (side == POSITION_TYPE_SELL && open > worstOpen))
         worstOpen = open;
      count++;
   }
}

int CountSide(ENUM_POSITION_TYPE side)
{
   int count;
   double worst;
   SideInfo(side, count, worst);
   return count;
}

double OpenProfit()
{
   double p = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) > 0 && IsOurPosition())
         p += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   return p;
}

void CloseAll()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && IsOurPosition())
         trade.PositionClose(ticket);
   }
}

bool TradingTimeOK()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(t.day_of_week == 0 || t.day_of_week == 6)
      return false;
   if(InpStartHour <= InpEndHour)
      return t.hour >= InpStartHour && t.hour < InpEndHour;
   return t.hour >= InpStartHour || t.hour < InpEndHour;
}

bool SpreadOK()
{
   return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPoints;
}

void ShowStatus(double equity, double dayStart, double dayPct, string state)
{
   Comment(StringFormat("HedgeDaily | %s\nEquity: %.2f   Day start: %.2f   Today: %+.2f%% (target %.1f%%)\nBuys: %d   Sells: %d   Open P/L: %.2f",
                        state, equity, dayStart, dayPct, InpDailyTargetPct,
                        CountSide(POSITION_TYPE_BUY), CountSide(POSITION_TYPE_SELL), OpenProfit()));
}
//+------------------------------------------------------------------+
