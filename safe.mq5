//+------------------------------------------------------------------+
//|                                     HighFreqMeanReversionEA.mq5  |
//| Multi-Position High-Frequency Scalper on Short Timeframes       |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>

//--- General Settings
input group "=== General ==="
input double    LotSize                    = 0.01;      // Fixed lot size per position
input int       MaxPositions               = 10;        // Max concurrent open trades allowed
input long      MagicNumber                = 850211;    // EA magic number
input double    TargetCapital              = 20000.0;   // Stop opening new trades at this balance
input bool      CloseAllWhenCapitalReached = true;      // Close open positions at target balance

//--- Fast Averages (Minute-Scale Windows)
input group "=== High-Frequency Averages ==="
input int       ShortLookbackBars          = 20;        // M1 lookback bars
input int       MediumLookbackBars         = 20;        // M5 lookback bars
input int       LongLookbackBars           = 20;        // M15 lookback bars

//--- Entry Rules (Micro-Pips)
input group "=== Micro Entry Thresholds ==="
input double    ThresholdPips              = 3.0;       // Micro-deviation to trigger trade (pips)
input double    SLDistanceFromMeanPips     = 12.0;      // SL distance measured FROM THE MEAN (pips)
input double    TPPips                     = 15.0;      // Fixed Take Profit distance (pips)

//--- Trailing Settings
input group "=== Micro Trailing ==="
input double    TrailStartPips             = 12.0;      // Profit pips before activation
input double    TrailGapPips               = 2.0;       // Trailing gap (pips)

//--- Filters
input group "=== News Filter ==="
input bool      UseNewsFilter              = false;     // Set true if calendar news filtering is required
input int       NewsBufferMinutesBefore    = 15;        // Minutes before high-impact news
input int       NewsBufferMinutesAfter     = 15;        // Minutes after high-impact news
input ENUM_CALENDAR_EVENT_IMPORTANCE MinNewsImportance = CALENDAR_IMPORTANCE_HIGH;

input group "=== Volatility Filter ==="
input bool      UseVolatilityFilter        = true;
input int       ATRPeriod                  = 14;
input int       ATRAveragePeriod           = 20;
input double    ATRMinRatio                = 0.5;       // Low barrier to ensure continuous trading
input double    ATRMaxRatio                = 2.0;       // Max volatility cap

//--- Globals
CTrade    trade;
int       atrHandle = INVALID_HANDLE;
datetime  lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   atrHandle = iATR(_Symbol, PERIOD_M1, ATRPeriod);
   if(atrHandle == INVALID_HANDLE)
     {
      Print("Failed to create ATR handle. Error: ", GetLastError());
      return(INIT_FAILED);
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ManageOpenPositions();   // Run trailing updates on every tick

   if(!IsNewM1Bar())
      return;               // Evaluates new entries every M1 bar for fast execution

   if(CapitalTargetReached())
     {
      if(CloseAllWhenCapitalReached)
         CloseAllPositions();
      return;
     }

   // Concurrent position ceiling check
   if(CountOpenPositions() >= MaxPositions)
      return;

   if(UseNewsFilter && IsNewsTime())
      return;

   if(UseVolatilityFilter && !IsVolatilityAcceptable())
      return;

   CheckEntry();
  }

//+------------------------------------------------------------------+
//| Detect a new M1 bar for ultra-fast checks                       |
//+------------------------------------------------------------------+
bool IsNewM1Bar()
  {
   datetime t[1];
   if(CopyTime(_Symbol, PERIOD_M1, 0, 1, t) <= 0)
      return false;
   if(t[0] != lastBarTime)
     {
      lastBarTime = t[0];
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Standard pip adjustment                                          |
//+------------------------------------------------------------------+
double GetPipSize()
  {
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(digits == 3 || digits == 5)
      return point * 10.0;
   return point;
  }

//+------------------------------------------------------------------+
//| Averages across short minute-based windows (M1, M5, M15)         |
//+------------------------------------------------------------------+
double ComputeTimeframeAverage(ENUM_TIMEFRAMES tf, int lookback)
  {
   double sum = 0;
   int count = 0;
   for(int i = 1; i <= lookback; i++)
     {
      double h = iHigh(_Symbol, tf, i);
      double l = iLow(_Symbol, tf, i);
      double c = iClose(_Symbol, tf, i);
      if(h <= 0 || l <= 0 || c <= 0)
         continue;
      sum += (h + l + c) / 3.0;
      count++;
     }
   if(count == 0)
      return 0;
   return sum / count;
  }

//+------------------------------------------------------------------+
//| Composite Short-Term Mean                                        |
//+------------------------------------------------------------------+
double ComputeMeanPrice()
  {
   double m1Avg  = ComputeTimeframeAverage(PERIOD_M1, ShortLookbackBars);
   double m5Avg  = ComputeTimeframeAverage(PERIOD_M5, MediumLookbackBars);
   double m15Avg = ComputeTimeframeAverage(PERIOD_M15, LongLookbackBars);

   if(m1Avg <= 0 || m5Avg <= 0 || m15Avg <= 0)
      return 0;

   return (m1Avg + m5Avg + m15Avg) / 3.0;
  }

//+------------------------------------------------------------------+
//| High-impact news filter                                          |
//+------------------------------------------------------------------+
bool IsNewsTime()
  {
   string base  = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string quote = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   string currencies[2] = {base, quote};

   datetime from = TimeCurrent() - 1 * 24 * 3600;
   datetime to   = TimeCurrent() + 1 * 24 * 3600;

   for(int c = 0; c < 2; c++)
     {
      if(StringLen(currencies[c]) == 0)
         continue;

      MqlCalendarValue values[];
      if(!CalendarValueHistory(values, from, to, currencies[c], NULL))
         continue;

      for(int i = 0; i < ArraySize(values); i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev))
            continue;
         if(ev.importance < MinNewsImportance)
            continue;

         long secondsUntil = (long)(values[i].time - TimeCurrent());
         if(secondsUntil >= 0)
           {
            if(secondsUntil <= (long)NewsBufferMinutesBefore * 60)
               return true;
           }
         else
           {
            if(-secondsUntil <= (long)NewsBufferMinutesAfter * 60)
               return true;
           }
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Volatility filter                                                |
//+------------------------------------------------------------------+
bool IsVolatilityAcceptable()
  {
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(atrHandle, 0, 0, ATRAveragePeriod + 1, atrBuf) <= 0)
      return false;

   double current = atrBuf[0];
   double sum = 0;
   for(int i = 1; i <= ATRAveragePeriod; i++)
      sum += atrBuf[i];
   double avg = sum / ATRAveragePeriod;

   if(avg <= 0)
      return false;

   double ratio = current / avg;
   return (ratio >= ATRMinRatio && ratio <= ATRMaxRatio);
  }

//+------------------------------------------------------------------+
bool CapitalTargetReached()
  {
   return AccountInfoDouble(ACCOUNT_BALANCE) >= TargetCapital;
  }

//+------------------------------------------------------------------+
//| Returns current open position count for this EA                  |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         trade.PositionClose(ticket);
     }
  }

//+------------------------------------------------------------------+
//| Core Entry Logic                                                 |
//+------------------------------------------------------------------+
void CheckEntry()
  {
   double mean = ComputeMeanPrice();
   if(mean <= 0)
      return;

   double pip = GetPipSize();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double diffPips = (bid - mean) / pip;

   if(diffPips > ThresholdPips)
     {
      // Deviation above mean -> Sell
      double entry = bid;
      double sl = mean + SLDistanceFromMeanPips * pip;
      double tp = entry - TPPips * pip;
      if(sl > entry && tp < entry)
         trade.Sell(LotSize, _Symbol, entry, sl, tp, "HFT MeanRevert Sell");
     }
   else if(diffPips < -ThresholdPips)
     {
      // Deviation below mean -> Buy
      double entry = ask;
      double sl = mean - SLDistanceFromMeanPips * pip;
      double tp = entry + TPPips * pip;
      if(sl < entry && tp > entry)
         trade.Buy(LotSize, _Symbol, entry, sl, tp, "HFT MeanRevert Buy");
     }
  }

//+------------------------------------------------------------------+
//| Dynamic Trailing Manager                                         |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   double pip = GetPipSize();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(type == POSITION_TYPE_BUY)
        {
         double profitPips = (bid - openPrice) / pip;
         if(profitPips >= TrailStartPips)
           {
            double newSL = bid - TrailGapPips * pip;
            if(newSL > curSL || curSL == 0)
               trade.PositionModify(ticket, newSL, 0); 
           }
        }
      else if(type == POSITION_TYPE_SELL)
        {
         double profitPips = (openPrice - ask) / pip;
         if(profitPips >= TrailStartPips)
           {
            double newSL = ask + TrailGapPips * pip;
            if(newSL < curSL || curSL == 0)
               trade.PositionModify(ticket, newSL, 0);
           }
        }
     }
  }
//+------------------------------------------------------------------+
