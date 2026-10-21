// Minimal MQL5 -> C++ shim, only for syntax/type checking (never executed).
#include <string>
#include <vector>
#include <cmath>
typedef std::string string;
// ulong comes from sys/types.h (unsigned long, 64-bit)
typedef unsigned int uint;
typedef long long datetime;
typedef unsigned char uchar;
template<typename T> struct Arr { std::vector<T> v; T& operator[](int i) { return v[i]; } const T& operator[](int i) const { return v[i]; } };
template<typename T> int ArraySize(const Arr<T>& a) { return (int)a.v.size(); }
template<typename T> int ArraySize(const T (&a)[2]) { return 2; }
template<typename T> int ArrayResize(Arr<T>& a, int n) { a.v.resize(n); return n; }
enum ENUM_TIMEFRAMES { PERIOD_CURRENT, PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_H1, PERIOD_H4, PERIOD_D1 };
enum ENUM_MA_METHOD { MODE_SMA, MODE_EMA };
enum ENUM_APPLIED_PRICE { PRICE_CLOSE };
enum ENUM_ORDER_TYPE { ORDER_TYPE_BUY, ORDER_TYPE_SELL };
enum ENUM_POSITION_TYPE { POSITION_TYPE_BUY, POSITION_TYPE_SELL };
enum ENUM_POSITION_PROPERTY_INTEGER { POSITION_TYPE, POSITION_MAGIC, POSITION_TIME, POSITION_IDENTIFIER };
enum ENUM_POSITION_PROPERTY_DOUBLE { POSITION_VOLUME, POSITION_PRICE_OPEN, POSITION_TP, POSITION_SL, POSITION_PROFIT, POSITION_SWAP };
enum ENUM_POSITION_PROPERTY_STRING { POSITION_SYMBOL };
enum ENUM_ACCOUNT_INFO_INTEGER { ACCOUNT_MARGIN_MODE, ACCOUNT_LOGIN, ACCOUNT_TRADE_ALLOWED, ACCOUNT_TRADE_EXPERT };
enum ENUM_ACCOUNT_INFO_STRING { ACCOUNT_CURRENCY };
enum ENUM_ACCOUNT_MARGIN_MODE { ACCOUNT_MARGIN_MODE_RETAIL_NETTING, ACCOUNT_MARGIN_MODE_EXCHANGE, ACCOUNT_MARGIN_MODE_RETAIL_HEDGING };
enum ENUM_ACCOUNT_INFO_DOUBLE { ACCOUNT_BALANCE, ACCOUNT_EQUITY, ACCOUNT_MARGIN, ACCOUNT_MARGIN_FREE, ACCOUNT_MARGIN_LEVEL };
enum ENUM_SYMBOL_INFO_INTEGER { SYMBOL_TRADE_STOPS_LEVEL, SYMBOL_TRADE_FREEZE_LEVEL, SYMBOL_TRADE_MODE, SYMBOL_DIGITS, SYMBOL_SPREAD };
enum ENUM_SYMBOL_TRADE_MODE { SYMBOL_TRADE_MODE_DISABLED, SYMBOL_TRADE_MODE_LONGONLY, SYMBOL_TRADE_MODE_SHORTONLY, SYMBOL_TRADE_MODE_CLOSEONLY, SYMBOL_TRADE_MODE_FULL };
enum ENUM_SYMBOL_INFO_DOUBLE { SYMBOL_VOLUME_STEP, SYMBOL_VOLUME_MIN, SYMBOL_VOLUME_MAX, SYMBOL_POINT, SYMBOL_ASK, SYMBOL_BID, SYMBOL_TRADE_TICK_SIZE, SYMBOL_TRADE_TICK_VALUE, SYMBOL_TRADE_TICK_VALUE_LOSS, SYMBOL_TRADE_CONTRACT_SIZE };
enum ENUM_SYMBOL_INFO_STRING { SYMBOL_CURRENCY_BASE, SYMBOL_CURRENCY_PROFIT };
enum ENUM_TERMINAL_INFO_INTEGER { TERMINAL_TRADE_ALLOWED };
enum ENUM_MQL_INFO_INTEGER { MQL_TESTER, MQL_OPTIMIZATION, MQL_TRADE_ALLOWED, MQL_VISUAL_MODE };
enum ENUM_CALENDAR_EVENT_IMPORTANCE { CALENDAR_IMPORTANCE_NONE, CALENDAR_IMPORTANCE_LOW, CALENDAR_IMPORTANCE_MODERATE, CALENDAR_IMPORTANCE_HIGH };
enum ENUM_INIT_RETCODE { INIT_SUCCEEDED = 0, INIT_FAILED = 1, INIT_PARAMETERS_INCORRECT = 2 };
const int INVALID_HANDLE = -1;
const uint TRADE_RETCODE_DONE = 10009, TRADE_RETCODE_PLACED = 10008, TRADE_RETCODE_DONE_PARTIAL = 10010,
           TRADE_RETCODE_REQUOTE = 10004, TRADE_RETCODE_PRICE_CHANGED = 10020, TRADE_RETCODE_PRICE_OFF = 10021;
const int TIME_DATE = 1, TIME_MINUTES = 2;
struct MqlTick { datetime time; double bid; double ask; double last; ulong volume; };
struct MqlDateTime { int year, mon, day, hour, min, sec, day_of_week, day_of_year; };
struct MqlCalendarValue { ulong id; ulong event_id; datetime time; };
struct MqlCalendarEvent { ulong id; ENUM_CALENDAR_EVENT_IMPORTANCE importance; string name; };
extern string _Symbol; extern double _Point; extern int _Digits; extern ENUM_TIMEFRAMES _Period;
bool SymbolInfoTick(const string&, MqlTick&);
double SymbolInfoDouble(const string&, ENUM_SYMBOL_INFO_DOUBLE);
long SymbolInfoInteger(const string&, ENUM_SYMBOL_INFO_INTEGER);
string SymbolInfoString(const string&, ENUM_SYMBOL_INFO_STRING);
double AccountInfoDouble(ENUM_ACCOUNT_INFO_DOUBLE);
long AccountInfoInteger(ENUM_ACCOUNT_INFO_INTEGER);
long TerminalInfoInteger(ENUM_TERMINAL_INFO_INTEGER);
long MQLInfoInteger(ENUM_MQL_INFO_INTEGER);
int iATR(const string&, ENUM_TIMEFRAMES, int);
int iADXWilder(const string&, ENUM_TIMEFRAMES, int);
int iBands(const string&, ENUM_TIMEFRAMES, int, int, double, ENUM_APPLIED_PRICE);
int iMA(const string&, ENUM_TIMEFRAMES, int, int, ENUM_MA_METHOD, ENUM_APPLIED_PRICE);
int iRSI(const string&, ENUM_TIMEFRAMES, int, ENUM_APPLIED_PRICE);
double iClose(const string&, ENUM_TIMEFRAMES, int);
double iOpen(const string&, ENUM_TIMEFRAMES, int);
datetime iTime(const string&, ENUM_TIMEFRAMES, int);
int CopyBuffer(int, int, int, int, Arr<double>&);
bool IndicatorRelease(int);
int PositionsTotal();
ulong PositionGetTicket(int);
string PositionGetString(ENUM_POSITION_PROPERTY_STRING);
long PositionGetInteger(ENUM_POSITION_PROPERTY_INTEGER);
double PositionGetDouble(ENUM_POSITION_PROPERTY_DOUBLE);
bool OrderCalcMargin(ENUM_ORDER_TYPE, const string&, double, double, double&);
bool GlobalVariableCheck(const string&);
double GlobalVariableGet(const string&);
datetime GlobalVariableSet(const string&, double);
bool GlobalVariableDel(const string&);
datetime TimeCurrent();
datetime TimeTradeServer();
bool TimeToStruct(datetime, MqlDateTime&);
string TimeToString(datetime, int);
string IntegerToString(long);
int StringFind(const string&, const string&, int start = 0);
string DoubleToString(double, int);
string EnumToString(ENUM_TIMEFRAMES);
bool CalendarValueHistory(Arr<MqlCalendarValue>&, datetime, datetime, const string&, const string&);
bool CalendarEventById(ulong, MqlCalendarEvent&);
double NormalizeDouble(double, int);
inline double MathMax(double a, double b) { return a > b ? a : b; }
inline double MathMin(double a, double b) { return a < b ? a : b; }
inline double MathAbs(double a) { return std::fabs(a); }
inline double MathFloor(double a) { return std::floor(a); }
inline double MathCeil(double a) { return std::ceil(a); }
inline double MathPow(double a, double b) { return std::pow(a, b); }
inline double MathLog10(double a) { return std::log10(a); }
template<typename... A> void Print(A... a) {}
template<typename... A> void PrintFormat(const string&, A... a) {}
template<typename... A> string StringFormat(const string&, A... a) { return ""; }
void Comment(const string&);
enum ENUM_LOG_LEVELS { LOG_LEVEL_NO, LOG_LEVEL_ERRORS, LOG_LEVEL_ALL };
class CTrade {
public:
  void SetExpertMagicNumber(ulong);
  void SetDeviationInPoints(ulong);
  bool SetTypeFillingBySymbol(const string&);
  bool Buy(double, const string&, double, double, double, const string&);
  bool Sell(double, const string&, double, double, double, const string&);
  bool PositionModify(ulong, double, double);
  bool PositionClose(ulong, ulong deviation = ~0ULL);
  uint ResultRetcode();
  double ResultPrice();
  void SetMarginMode();
  void SetAsyncMode(bool);
  void LogLevel(ENUM_LOG_LEVELS);
  string ResultRetcodeDescription();
};

// --- additions for GoldPullbackGrowth
template<typename T> bool ArraySetAsSeries(Arr<T>&, bool) { return true; }
struct MqlRates { datetime time; double open, high, low, close; long tick_volume; int spread; long real_volume; };
int CopyRates(const string&, ENUM_TIMEFRAMES, int, int, Arr<MqlRates>&);
int Bars(const string&, ENUM_TIMEFRAMES);
int PeriodSeconds(ENUM_TIMEFRAMES);
enum ENUM_DAY_OF_WEEK { SUNDAY, MONDAY, TUESDAY, WEDNESDAY, THURSDAY, FRIDAY, SATURDAY };
bool SymbolInfoSessionTrade(const string&, ENUM_DAY_OF_WEEK, uint, datetime&, datetime&);
enum ENUM_DEAL_PROPERTY_INTEGER { DEAL_MAGIC, DEAL_ENTRY, DEAL_POSITION_ID, DEAL_TIME, DEAL_TYPE };
enum ENUM_DEAL_PROPERTY_DOUBLE { DEAL_PROFIT, DEAL_SWAP, DEAL_COMMISSION, DEAL_FEE, DEAL_VOLUME };
enum ENUM_DEAL_PROPERTY_STRING { DEAL_SYMBOL };
enum ENUM_DEAL_ENTRY { DEAL_ENTRY_IN, DEAL_ENTRY_OUT, DEAL_ENTRY_INOUT, DEAL_ENTRY_OUT_BY };
bool HistorySelect(datetime, datetime);
int HistoryDealsTotal();
ulong HistoryDealGetTicket(int);
long HistoryDealGetInteger(ulong, ENUM_DEAL_PROPERTY_INTEGER);
double HistoryDealGetDouble(ulong, ENUM_DEAL_PROPERTY_DOUBLE);
string HistoryDealGetString(ulong, ENUM_DEAL_PROPERTY_STRING);
bool OrderCalcProfit(ENUM_ORDER_TYPE, const string&, double, double, double, double&);
string AccountInfoString(ENUM_ACCOUNT_INFO_STRING);
void GlobalVariablesFlush();
datetime TimeGMT();
datetime TimeLocal();
bool StringToUpper(string&);
int GetLastError();
inline double MathRound(double a) { return std::round(a); }
inline bool MathIsValidNumber(double a) { return std::isfinite(a); }
enum ENUM_STATISTICS { STAT_PROFIT, STAT_TRADES, STAT_EQUITY_DD };
double TesterStatistics(ENUM_STATISTICS);
enum ENUM_TRADE_TRANSACTION_TYPE { TRADE_TRANSACTION_ORDER_ADD, TRADE_TRANSACTION_DEAL_ADD };
struct MqlTradeTransaction { ulong deal; ulong order; string symbol; ENUM_TRADE_TRANSACTION_TYPE type; };
struct MqlTradeRequest { ulong magic; string symbol; double volume; double price; double sl; double tp; };
struct MqlTradeResult { uint retcode; ulong deal; ulong order; double price; };
