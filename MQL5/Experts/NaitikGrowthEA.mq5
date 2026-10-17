//+------------------------------------------------------------------+
//|                                              NaitikGrowthEA.mq5  |
//|  Trend-pullback EA with fixed-percent risk, daily loss limit,    |
//|  max drawdown kill switch and an equity target (default $1000).  |
//|                                                                  |
//|  NOTE: No EA can guarantee profit. Backtest and demo-test first. |
//+------------------------------------------------------------------+
#property copyright "Naitik"
#property version   "1.00"
#property description "EMA trend + RSI pullback entries, ATR stops, % risk sizing."
#property description "Stops trading when the equity target or a loss limit is hit."

#include <Trade\Trade.mqh>

//--- Goal and protection
input group "Goal & protection"
input double InpTargetEquity      = 1000.0; // Stop trading when equity reaches this
input double InpRiskPercent       = 1.5;    // Risk per trade (% of equity)
input double InpMaxDailyLossPct   = 5.0;    // Stop for the day after losing this % (0 = off)
input double InpMaxDrawdownPct    = 30.0;   // Stop completely after this % drop from peak (0 = off)
input int    InpMaxPositions      = 1;      // Max open positions on this symbol

//--- Strategy
input group "Strategy"
input int    InpFastEMA           = 50;     // Fast EMA period
input int    InpSlowEMA           = 200;    // Slow (trend) EMA period
input int    InpRSIPeriod         = 14;     // RSI period
input double InpRSIBuyLevel       = 40.0;   // Buy when RSI crosses up through this
input double InpRSISellLevel      = 60.0;   // Sell when RSI crosses down through this
input int    InpATRPeriod         = 14;     // ATR period
input double InpSL_ATR            = 1.5;    // Stop loss = ATR x this
input double InpTP_ATR            = 3.0;    // Take profit = ATR x this (0 = none)

//--- Trade management
input group "Trade management"
input double InpBreakEvenR        = 1.0;    // Move SL to breakeven at this many R (0 = off)
input double InpTrail_ATR         = 1.0;    // Trail SL at ATR x this after breakeven (0 = off)

//--- Filters
input group "Filters"
input int    InpMaxSpreadPoints   = 30;     // Skip entries when spread is above this (points)
input int    InpStartHour         = 7;      // Trading window start (server hour)
input int    InpEndHour           = 20;     // Trading window end (server hour)
input bool   InpTradeFriday       = true;   // Allow new trades on Friday

input group "Misc"
input ulong  InpMagic             = 20261017; // Magic number
input string InpComment           = "NaitikGrowthEA";
input bool   InpResetState        = false;    // Clear saved peak/stop state on load

CTrade   trade;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE;
int      hRSI  = INVALID_HANDLE, hATR  = INVALID_HANDLE;
datetime lastBarTime = 0;

string   gvPeak, gvDayStart, gvDayDate, gvStopped;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpFastEMA >= InpSlowEMA || InpRiskPercent <= 0 || InpSL_ATR <= 0)
   {
      Print("Invalid inputs: FastEMA must be < SlowEMA, risk and SL must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   hFast = iMA(_Symbol, _Period, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, _Period, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI  = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
   hATR  = iATR(_Symbol, _Period, InpATRPeriod);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE ||
      hRSI == INVALID_HANDLE || hATR == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFillingBySymbol(_Symbol);

   // Persist state across terminal restarts
   string prefix = "NGEA_" + IntegerToString((long)InpMagic) + "_" + _Symbol + "_";
   gvPeak     = prefix + "peak";
   gvDayStart = prefix + "daystart";
   gvDayDate  = prefix + "daydate";
   gvStopped  = prefix + "stopped";

   if(InpResetState)
   {
      GlobalVariableDel(gvPeak);
      GlobalVariableDel(gvDayStart);
      GlobalVariableDel(gvDayDate);
      GlobalVariableDel(gvStopped);
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(!GlobalVariableCheck(gvPeak))
      GlobalVariableSet(gvPeak, equity);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hFast);
   IndicatorRelease(hSlow);
   IndicatorRelease(hRSI);
   IndicatorRelease(hATR);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   UpdateDailyState(equity);

   double peak = MathMax(GlobalVariableGet(gvPeak), equity);
   GlobalVariableSet(gvPeak, peak);

   // Permanent stop: target reached or max drawdown hit
   if(GlobalVariableCheck(gvStopped))
   {
      ShowStatus(equity, peak, "STOPPED (target or max drawdown reached)");
      return;
   }
   if(equity >= InpTargetEquity)
   {
      CloseAll();
      GlobalVariableSet(gvStopped, 1);
      Print("Equity target reached: ", DoubleToString(equity, 2), ". Trading stopped.");
      return;
   }
   if(InpMaxDrawdownPct > 0 && equity <= peak * (1.0 - InpMaxDrawdownPct / 100.0))
   {
      CloseAll();
      GlobalVariableSet(gvStopped, 1);
      Print("Max drawdown hit. Equity ", DoubleToString(equity, 2),
            " peak ", DoubleToString(peak, 2), ". Trading stopped.");
      return;
   }

   ManagePositions();

   // Daily loss limit: no new trades for the rest of the day
   double dayStart = GlobalVariableGet(gvDayStart);
   bool dailyLimitHit = InpMaxDailyLossPct > 0 &&
                        equity <= dayStart * (1.0 - InpMaxDailyLossPct / 100.0);
   if(dailyLimitHit)
   {
      ShowStatus(equity, peak, "Daily loss limit hit - waiting for next day");
      return;
   }

   ShowStatus(equity, peak, "Running");

   // Only evaluate entries once per new bar
   datetime barTime = iTime(_Symbol, _Period, 0);
   if(barTime == lastBarTime)
      return;
   lastBarTime = barTime;

   if(CountPositions() >= InpMaxPositions || !TradingTimeOK() || !SpreadOK())
      return;

   CheckEntry();
}

//+------------------------------------------------------------------+
void UpdateDailyState(double equity)
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   double today = t.year * 10000 + t.mon * 100 + t.day;
   if(!GlobalVariableCheck(gvDayDate) || GlobalVariableGet(gvDayDate) != today)
   {
      GlobalVariableSet(gvDayDate, today);
      GlobalVariableSet(gvDayStart, AccountInfoDouble(ACCOUNT_BALANCE));
   }
}

//+------------------------------------------------------------------+
bool GetValue(int handle, int shift, double &value)
{
   double buf[];
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1)
      return false;
   value = buf[0];
   return true;
}

//+------------------------------------------------------------------+
void CheckEntry()
{
   double fast, slow, rsi1, rsi2, atr;
   if(!GetValue(hFast, 1, fast) || !GetValue(hSlow, 1, slow) ||
      !GetValue(hRSI, 1, rsi1) || !GetValue(hRSI, 2, rsi2) ||
      !GetValue(hATR, 1, atr) || atr <= 0)
      return;

   double close1 = iClose(_Symbol, _Period, 1);
   bool upTrend   = fast > slow && close1 > slow;
   bool downTrend = fast < slow && close1 < slow;

   bool buySignal  = upTrend   && rsi2 < InpRSIBuyLevel  && rsi1 >= InpRSIBuyLevel;
   bool sellSignal = downTrend && rsi2 > InpRSISellLevel && rsi1 <= InpRSISellLevel;
   if(!buySignal && !sellSignal)
      return;

   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double minStop  = (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 5) * point;
   double slDist   = MathMax(atr * InpSL_ATR, minStop);
   double tpDist   = InpTP_ATR > 0 ? MathMax(atr * InpTP_ATR, minStop) : 0;

   double lots = CalcLots(slDist);
   if(lots <= 0)
   {
      Print("Lot size too small for risk settings - skipping signal");
      return;
   }

   if(buySignal)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - slDist, digits);
      double tp  = tpDist > 0 ? NormalizeDouble(ask + tpDist, digits) : 0;
      if(!trade.Buy(lots, _Symbol, ask, sl, tp, InpComment))
         Print("Buy failed: ", trade.ResultRetcodeDescription());
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + slDist, digits);
      double tp  = tpDist > 0 ? NormalizeDouble(bid - tpDist, digits) : 0;
      if(!trade.Sell(lots, _Symbol, bid, sl, tp, InpComment))
         Print("Sell failed: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Lot size so that hitting the SL loses ~InpRiskPercent of equity   |
//+------------------------------------------------------------------+
double CalcLots(double slDist)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0 || slDist <= 0)
      return 0;

   double lossPerLot = slDist / tickSize * tickValue;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double lots = MathFloor(riskMoney / lossPerLot / step) * step;
   if(lots < minL)
   {
      // Allow the minimum lot only if it doesn't risk more than 2x the setting
      if(minL * lossPerLot > riskMoney * 2.0)
         return 0;
      lots = minL;
   }
   lots = MathMin(lots, maxL);

   // Make sure we have enough free margin
   double margin;
   ENUM_ORDER_TYPE type = ORDER_TYPE_BUY;
   if(OrderCalcMargin(type, _Symbol, lots, SymbolInfoDouble(_Symbol, SYMBOL_ASK), margin) &&
      margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9)
      return 0;

   int volDigits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(lots, volDigits);
}

//+------------------------------------------------------------------+
//| Breakeven + ATR trailing stop                                     |
//+------------------------------------------------------------------+
void ManagePositions()
{
   if(InpBreakEvenR <= 0 && InpTrail_ATR <= 0)
      return;

   double atr;
   if(!GetValue(hATR, 1, atr) || atr <= 0)
      return;

   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minStop = (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 5) * point;
   double initialRisk = atr * InpSL_ATR;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPosition())
         continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double newSL = sl;

      if(type == POSITION_TYPE_BUY)
      {
         double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profit = bid - open;
         if(InpBreakEvenR > 0 && profit >= initialRisk * InpBreakEvenR && (sl < open || sl == 0))
            newSL = open + point;
         if(InpTrail_ATR > 0 && sl >= open)
            newSL = MathMax(newSL, bid - atr * InpTrail_ATR);
         newSL = NormalizeDouble(newSL, digits);
         if(newSL > sl + point && bid - newSL >= minStop)
            trade.PositionModify(ticket, newSL, tp);
      }
      else
      {
         double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit = open - ask;
         if(InpBreakEvenR > 0 && profit >= initialRisk * InpBreakEvenR && (sl > open || sl == 0))
            newSL = open - point;
         if(InpTrail_ATR > 0 && sl > 0 && sl <= open)
            newSL = MathMin(newSL, ask + atr * InpTrail_ATR);
         newSL = NormalizeDouble(newSL, digits);
         if((sl == 0 || newSL < sl - point) && newSL - ask >= minStop)
            trade.PositionModify(ticket, newSL, tp);
      }
   }
}

//+------------------------------------------------------------------+
bool IsOurPosition()
{
   return PositionGetString(POSITION_SYMBOL) == _Symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic;
}

int CountPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) > 0 && IsOurPosition())
         n++;
   return n;
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
   if(!InpTradeFriday && t.day_of_week == 5)
      return false;
   if(InpStartHour <= InpEndHour)
      return t.hour >= InpStartHour && t.hour < InpEndHour;
   return t.hour >= InpStartHour || t.hour < InpEndHour; // window crosses midnight
}

bool SpreadOK()
{
   return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPoints;
}

void ShowStatus(double equity, double peak, string state)
{
   Comment(StringFormat("NaitikGrowthEA  |  %s\nEquity: %.2f   Target: %.2f   Progress: %.1f%%\nPeak: %.2f   Risk/trade: %.1f%%",
                        state, equity, InpTargetEquity,
                        InpTargetEquity > 0 ? equity / InpTargetEquity * 100.0 : 0.0,
                        peak, InpRiskPercent));
}
//+------------------------------------------------------------------+
