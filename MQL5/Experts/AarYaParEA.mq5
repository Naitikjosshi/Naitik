//+------------------------------------------------------------------+
//|                                                  AarYaParEA.mq5  |
//|  "All or nothing" EA: a few very large trades sized so that a    |
//|  short winning streak reaches the equity target, while losses    |
//|  can empty the account. Stops for good at the target.            |
//|                                                                  |
//|  WARNING: Most runs of this EA are expected to LOSE the deposit. |
//+------------------------------------------------------------------+
#property copyright "Naitik"
#property version   "1.00"
#property description "All-or-nothing mode: huge risk per trade, TP sized to hit the target."
#property description "Expect to lose the deposit far more often than you reach the target."

#include <Trade\Trade.mqh>

input group "Aar ya Paar"
input double InpTargetEquity    = 1000.0; // Close everything and stop at this equity
input double InpRiskPercent     = 90.0;   // % of equity lost if SL is hit
input double InpMaxRR           = 3.5;    // Max reward:risk per trade (higher = fewer, longer-shot trades)
input double InpMinRR           = 1.0;    // Min reward:risk per trade

input group "Entry signal"
input int    InpFastEMA         = 50;     // Fast EMA period
input int    InpSlowEMA         = 200;    // Slow (trend) EMA period
input int    InpRSIPeriod       = 14;     // RSI period
input double InpRSIBuyLevel     = 40.0;   // Buy when RSI crosses up through this
input double InpRSISellLevel    = 60.0;   // Sell when RSI crosses down through this
input int    InpATRPeriod       = 14;     // ATR period
input double InpSL_ATR          = 1.5;    // Stop loss = ATR x this

input group "Filters"
input int    InpMaxSpreadPoints = 30;     // Skip entries when spread is above this (points)
input int    InpStartHour       = 7;      // Trading window start (server hour)
input int    InpEndHour         = 20;     // Trading window end (server hour)

input group "Misc"
input ulong  InpMagic           = 20261018; // Magic number
input string InpComment         = "AarYaPar";
input bool   InpResetState      = false;    // Clear saved "finished" state on load

CTrade   trade;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE;
int      hRSI  = INVALID_HANDLE, hATR  = INVALID_HANDLE;
datetime lastBarTime = 0;
string   gvDone;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpFastEMA >= InpSlowEMA || InpRiskPercent <= 0 || InpRiskPercent > 100 ||
      InpSL_ATR <= 0 || InpMinRR <= 0 || InpMaxRR < InpMinRR)
   {
      Print("Invalid inputs");
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

   gvDone = "AYP_" + IntegerToString((long)InpMagic) + "_" + _Symbol + "_done";
   if(InpResetState)
      GlobalVariableDel(gvDone);

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

   if(GlobalVariableCheck(gvDone))
   {
      Comment(StringFormat("AarYaPar | FINISHED - target reached\nEquity: %.2f", equity));
      return;
   }
   if(equity >= InpTargetEquity)
   {
      CloseAll();
      GlobalVariableSet(gvDone, 1);
      Print("PAAR! Target reached: ", DoubleToString(equity, 2), ". EA stopped.");
      return;
   }

   Comment(StringFormat("AarYaPar | Running\nEquity: %.2f   Target: %.2f   Need: x%.2f",
                        equity, InpTargetEquity, equity > 0 ? InpTargetEquity / equity : 0.0));

   datetime barTime = iTime(_Symbol, _Period, 0);
   if(barTime == lastBarTime)
      return;
   lastBarTime = barTime;

   if(CountPositions() > 0 || !TradingTimeOK() || !SpreadOK())
      return;

   CheckEntry(equity);
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
void CheckEntry(double equity)
{
   double fast, slow, rsi1, rsi2, atr;
   if(!GetValue(hFast, 1, fast) || !GetValue(hSlow, 1, slow) ||
      !GetValue(hRSI, 1, rsi1) || !GetValue(hRSI, 2, rsi2) ||
      !GetValue(hATR, 1, atr) || atr <= 0)
      return;

   double close1 = iClose(_Symbol, _Period, 1);
   bool buySignal  = fast > slow && close1 > slow && rsi2 < InpRSIBuyLevel  && rsi1 >= InpRSIBuyLevel;
   bool sellSignal = fast < slow && close1 < slow && rsi2 > InpRSISellLevel && rsi1 <= InpRSISellLevel;
   if(!buySignal && !sellSignal)
      return;

   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double minStop = (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 5) * point;
   double slDist  = MathMax(atr * InpSL_ATR, minStop);

   double riskMoney = equity * InpRiskPercent / 100.0;
   double lots = CalcLots(slDist, riskMoney, buySignal);
   if(lots <= 0)
   {
      Print("Cannot size a trade (balance too low or margin insufficient) - account is done.");
      return;
   }

   // Actual money at risk after lot rounding/margin caps
   double actualRisk = lots * LossPerLot(slDist);
   // Pick R:R so a win lands on the target, clamped to [MinRR, MaxRR]
   double rr = (InpTargetEquity - equity) / actualRisk;
   rr = MathMax(InpMinRR, MathMin(InpMaxRR, rr));
   double tpDist = MathMax(slDist * rr, minStop);

   if(buySignal)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(!trade.Buy(lots, _Symbol, ask, NormalizeDouble(ask - slDist, digits),
                    NormalizeDouble(ask + tpDist, digits), InpComment))
         Print("Buy failed: ", trade.ResultRetcodeDescription());
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(!trade.Sell(lots, _Symbol, bid, NormalizeDouble(bid + slDist, digits),
                     NormalizeDouble(bid - tpDist, digits), InpComment))
         Print("Sell failed: ", trade.ResultRetcodeDescription());
   }
   PrintFormat("Aar ya Paar trade: lots=%.2f risk=%.2f R:R=%.2f", lots, actualRisk, rr);
}

//+------------------------------------------------------------------+
double LossPerLot(double slDist)
{
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0)
      return 0;
   return slDist / tickSize * tickValue;
}

//+------------------------------------------------------------------+
//| Lots so that the SL loses riskMoney, capped by free margin        |
//+------------------------------------------------------------------+
double CalcLots(double slDist, double riskMoney, bool isBuy)
{
   double lossPerLot = LossPerLot(slDist);
   if(lossPerLot <= 0)
      return 0;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double lots = MathFloor(riskMoney / lossPerLot / step) * step;
   lots = MathMin(lots, maxL);

   // Keep margin use under 50% of free margin so the broker's stop-out
   // doesn't close the trade before our SL does
   ENUM_ORDER_TYPE type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price = SymbolInfoDouble(_Symbol, isBuy ? SYMBOL_ASK : SYMBOL_BID);
   double marginPerLot;
   if(OrderCalcMargin(type, _Symbol, 1.0, price, marginPerLot) && marginPerLot > 0)
   {
      double maxByMargin = MathFloor(AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.5 / marginPerLot / step) * step;
      lots = MathMin(lots, maxByMargin);
   }

   if(lots < minL)
      return 0;

   int volDigits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(lots, volDigits);
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
   if(InpStartHour <= InpEndHour)
      return t.hour >= InpStartHour && t.hour < InpEndHour;
   return t.hour >= InpStartHour || t.hour < InpEndHour;
}

bool SpreadOK()
{
   return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPoints;
}
//+------------------------------------------------------------------+
