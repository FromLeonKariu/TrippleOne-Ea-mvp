//+------------------------------------------------------------------+
//| MarketStructure_ZoneBot v8                                       |
//| v7 base + trend state tracking                                   |
//|                                                                  |
//| Trend Logic:                                                      |
//|   UPTREND   = price making higher swing highs + higher lows     |
//|   DOWNTREND = price making lower swing lows  + lower highs      |
//|   RANGING   = no consistent sequence in either direction         |
//|                                                                  |
//| Trend state gates zone promotion:                                |
//|   Demand zones only promoted in UPTREND or RANGING              |
//|   Supply zones only promoted in DOWNTREND or RANGING            |
//+------------------------------------------------------------------+
#property strict

//==================== ENUMS ====================
enum TREND_STATE
{
   TREND_UP      = 1,   // Higher highs + higher lows
   TREND_DOWN    = -1,  // Lower lows   + lower highs
   TREND_RANGING = 0    // No clear sequence
};

//==================== STRUCTS ====================
struct PriceData {
   double   high;
   double   low;
   double   close;
   datetime time;
   int   obIndex;
};

//==================== GLOBALS ====================

// --- Trend state ---
TREND_STATE currentTrend     = TREND_RANGING;
double      lastSwingHigh    = 0;   // most recent confirmed swing high level
double      lastSwingLow     = 0;   // most recent confirmed swing low level
double      prevSwingHigh    = 0;   // swing high before lastSwingHigh
double      prevSwingLow     = 0;   // swing low  before lastSwingLow

// --- Bullish side (demand zones) ---
double    swingHighs[];
PriceData confirmedBullishZones[];
PriceData tempBearishOB;

bool isPullbackActive  = false;
bool bullishZoneLocked = false;
int  barsSinceBearOB   = 0;

// --- Bearish side (supply zones) ---
double    swingLows[];
PriceData confirmedBearishZones[];
PriceData tempBullishOB;

bool isRallyActive     = false;
bool bearishZoneLocked = false;
int  barsSinceBullOB   = 0;

// --- Shadow locals for capped inputs ---
int EffectiveExpansionLookback;
int EffectiveFVGLookback;

//==================== INPUTS ====================
input double BOS_Buffer_Points  = 20;   // Points buffer to confirm BOS
input int    MaxStoredSwings    = 50;   // Max swings + zones stored
input int    ExpansionLookback  = 5;    // Bars to scan for expansion after OB
input int    FVG_Lookback       = 5;    // Bars to scan for FVG after OB
input bool   TrendFilterEnabled = true; // Gate zones by trend direction

//+------------------------------------------------------------------+
int OnInit()
{
   if(MaxStoredSwings < 5)
   {
      Print("ERROR: MaxStoredSwings must be >= 5");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(ExpansionLookback < 1 || FVG_Lookback < 1)
   {
      Print("ERROR: Lookback values must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(BOS_Buffer_Points < 0)
   {
      Print("ERROR: BOS_Buffer_Points must be >= 0");
      return(INIT_PARAMETERS_INCORRECT);
   }

   EffectiveExpansionLookback = MathMin(ExpansionLookback, 50);
   EffectiveFVGLookback       = MathMin(FVG_Lookback,      50);

   ObjectsDeleteAll(0, "OB_Demand_");
   ObjectsDeleteAll(0, "OB_Supply_");

   ArrayResize(swingHighs,            0);
   ArrayResize(swingLows,             0);
   ArrayResize(confirmedBullishZones, 0);
   ArrayResize(confirmedBearishZones, 0);

   // Reset trend tracking
   currentTrend  = TREND_RANGING;
   lastSwingHigh = 0;
   lastSwingLow  = 0;
   prevSwingHigh = 0;
   prevSwingLow  = 0;

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, "OB_Demand_");
   ObjectsDeleteAll(0, "OB_Supply_");
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!isNewBar()) return;

   ProcessBullishStructure();
   ProcessBearishStructure();
   UpdateTrendState();     // runs after both sides so swing levels are fresh
   ExtendZones();
   DebugInfo();
}

//+------------------------------------------------------------------+
//| TREND STATE                                                       |
//| Called after swing highs/lows are updated each bar               |
//|                                                                   |
//| UPTREND   : lastSwingHigh > prevSwingHigh                        |
//|             AND lastSwingLow  > prevSwingLow                     |
//| DOWNTREND : lastSwingLow  < prevSwingLow                         |
//|             AND lastSwingHigh < prevSwingHigh                    |
//| RANGING   : mixed or not enough data                             |
//+------------------------------------------------------------------+
void UpdateTrendState()
{
   // Need at least two swing highs AND two swing lows to classify
   if(prevSwingHigh == 0 || prevSwingLow == 0)
   {
      currentTrend = TREND_RANGING;
      return;
   }

   bool higherHigh = lastSwingHigh > prevSwingHigh;
   bool higherLow  = lastSwingLow  > prevSwingLow;
   bool lowerLow   = lastSwingLow  < prevSwingLow;
   bool lowerHigh  = lastSwingHigh < prevSwingHigh;

   if(higherHigh && higherLow)
      currentTrend = TREND_UP;
   else if(lowerLow && lowerHigh)
      currentTrend = TREND_DOWN;
   else
      currentTrend = TREND_RANGING;
}

//+------------------------------------------------------------------+
//| Returns human-readable trend label                               |
//+------------------------------------------------------------------+
string TrendLabel()
{
   switch(currentTrend)
   {
      case TREND_UP:      return "UPTREND";
      case TREND_DOWN:    return "DOWNTREND";
      case TREND_RANGING: return "RANGING";
      default:            return "UNKNOWN";
   }
}



//todo : fix bugs for this two functions below


//+------------------------------------------------------------------+
//| BULLISH SIDE — demand zones, bearish OB, bullish BOS            |
//+------------------------------------------------------------------+
void ProcessBullishStructure()
{
   if(isPullbackActive)
      barsSinceBearOB++;

   int currentIdx = 1;
   double open1  = iOpen (_Symbol, _Period, currentIdx);
   double close1 = iClose(_Symbol, _Period, currentIdx);
   double high1  = iHigh (_Symbol, _Period, currentIdx);
   double low1   = iLow  (_Symbol, _Period, currentIdx);

   // STEP 1: Track bearish OB candidate
   if(!bullishZoneLocked && close1 < open1)
   {
      if(!isPullbackActive || low1 < tempBearishOB.low)
      {
         tempBearishOB.high  = high1;
         tempBearishOB.low   = low1;
         tempBearishOB.close = close1;
         tempBearishOB.time  = iTime(_Symbol, _Period, currentIdx);

         isPullbackActive = true;
         barsSinceBearOB  = 0;
      }
   }

   // STEP 2: Bullish expansion + FVG → lock demand zone
   if(isPullbackActive && !bullishZoneLocked && barsSinceBearOB >= 2)
   {
      if(IsBullishExpansionAfterOB(EffectiveExpansionLookback, tempBearishOB.time) &&
         HasBullishFVGAfterOB(EffectiveFVGLookback, tempBearishOB.time))
      {
         bullishZoneLocked = true;
      }
   }

   // STEP 3: Bullish BOS → promote demand zone
   double highClosed = iHigh(_Symbol, _Period, 2); 
   int    size       = ArraySize(swingHighs);
   double buffer     = BOS_Buffer_Points * _Point;

   if(size == 0) {
      ArrayResize(swingHighs, 1);
      swingHighs[0] = highClosed;
      lastSwingHigh = highClosed;
   }
   else {
      double lastHigh = swingHighs[size - 1];

      if(IsSwingHigh() && highClosed > lastHigh + buffer) {
         prevSwingHigh = lastSwingHigh;
         lastSwingHigh = highClosed;

         if(size >= MaxStoredSwings) {
            ArrayRemove(swingHighs, 0);
            size = ArraySize(swingHighs);
         }
         ArrayResize(swingHighs, size + 1);
         swingHighs[size] = highClosed;

         bool trendAllows = !TrendFilterEnabled || (currentTrend == TREND_UP || currentTrend == TREND_RANGING);

         if(bullishZoneLocked && tempBearishOB.low > 0 && trendAllows)
         {
            // --- FIX: CHECK THE NEXT CANDLE INDEX AFTER OB ---
            int obIndex = iBarShift(_Symbol, _Period, tempBearishOB.time);
            int nextIdx = obIndex - 1;

            if(nextIdx >= 0) {
               double nextLow = iLow(_Symbol, _Period, nextIdx);
               if(nextLow < tempBearishOB.low) {
                  tempBearishOB.low = nextLow; // Expand zone to the wick that poked lower
                  Print("Demand Zone low expanded by next candle: ", tempBearishOB.low);
               }
            }

            int zSize = ArraySize(confirmedBullishZones);
            if(zSize >= MaxStoredSwings) {
               ArrayRemove(confirmedBullishZones, 0);
               zSize = ArraySize(confirmedBullishZones);
            }

            ArrayResize(confirmedBullishZones, zSize + 1);
            confirmedBullishZones[zSize] = tempBearishOB; // Use the same variable as Step 1

            DrawZone(confirmedBullishZones[zSize], "OB_Demand_", clrDodgerBlue);
         }
         ResetBullishState();
      }
   }
}

//+------------------------------------------------------------------+
//| BEARISH SIDE — supply zones, bullish OB, bearish BOS            |
//+------------------------------------------------------------------+
void ProcessBearishStructure()
{
   if(isRallyActive)
      barsSinceBullOB++;

   int currentIdx = 1;
   double open1  = iOpen (_Symbol, _Period, currentIdx);
   double close1 = iClose(_Symbol, _Period, currentIdx);
   double high1  = iHigh (_Symbol, _Period, currentIdx);
   double low1   = iLow  (_Symbol, _Period, currentIdx);

   // STEP 1: Track bullish OB candidate
   if(!bearishZoneLocked && close1 > open1)
   {
      if(!isRallyActive || high1 > tempBullishOB.high)
      {
         tempBullishOB.high  = high1;
         tempBullishOB.low   = low1;
         tempBullishOB.close = close1;
         tempBullishOB.time  = iTime(_Symbol, _Period, currentIdx);

         isRallyActive   = true;
         barsSinceBullOB = 0;
      }
   }

   // STEP 2: Bearish expansion + FVG → lock supply zone
   if(isRallyActive && !bearishZoneLocked && barsSinceBullOB >= 2)
   {
      if(IsBearishExpansionAfterOB(EffectiveExpansionLookback, tempBullishOB.time) &&
         HasBearishFVGAfterOB(EffectiveFVGLookback, tempBullishOB.time))
      {
         bearishZoneLocked = true;
      }
   }

   // STEP 3: Bearish BOS → promote supply zone
   double lowClosed = iLow(_Symbol, _Period, 2); 
   int    size      = ArraySize(swingLows);
   double buffer    = BOS_Buffer_Points * _Point;

   if(size == 0) {
      ArrayResize(swingLows, 1);
      swingLows[0] = lowClosed;
      lastSwingLow = lowClosed;
   }
   else {
      double lastLow = swingLows[size - 1];

      if(IsSwingLow() && lowClosed < lastLow - buffer) {
         prevSwingLow = lastSwingLow;
         lastSwingLow = lowClosed;

         if(size >= MaxStoredSwings) {
            ArrayRemove(swingLows, 0);
            size = ArraySize(swingLows);
         }
         ArrayResize(swingLows, size + 1);
         swingLows[size] = lowClosed;

         bool trendAllows = !TrendFilterEnabled || (currentTrend == TREND_DOWN || currentTrend == TREND_RANGING);

         if(bearishZoneLocked && tempBullishOB.high > 0 && trendAllows)
         {
            // --- FIX: CHECK THE NEXT CANDLE INDEX AFTER OB ---
            int obIndex = iBarShift(_Symbol, _Period, tempBullishOB.time);
            int nextIdx = obIndex - 1;

            if(nextIdx >= 0) {
               double nextHigh = iHigh(_Symbol, _Period, nextIdx);
               if(nextHigh > tempBullishOB.high) {
                  tempBullishOB.high = nextHigh; // Expand zone to the wick that poked higher
                  Print("Supply Zone high expanded by next candle: ", tempBullishOB.high);
               }
            }

            int zSize = ArraySize(confirmedBearishZones);
            if(zSize >= MaxStoredSwings) {
               ArrayRemove(confirmedBearishZones, 0);
               zSize = ArraySize(confirmedBearishZones);
            }
            
            ArrayResize(confirmedBearishZones, zSize + 1);
            confirmedBearishZones[zSize] = tempBullishOB;

            DrawZone(confirmedBearishZones[zSize], "OB_Supply_", clrTomato);
         }
         ResetBearishState();
      }
   }
}
//+------------------------------------------------------------------+
//| BULLISH EXPANSION — close above prior high, after OB            |
//+------------------------------------------------------------------+
bool IsBullishExpansionAfterOB(int lookback, datetime obTime)
{
   if(iBars(_Symbol, _Period) < lookback + 2) return false;

   for(int i = 1; i <= lookback; i++)
   {
      if(iTime(_Symbol, _Period, i) <= obTime) break;

      double c        = iClose(_Symbol, _Period, i);
      double o        = iOpen (_Symbol, _Period, i);
      double prevHigh = iHigh (_Symbol, _Period, i + 1);

      if(c > o && c > prevHigh)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| BEARISH EXPANSION — close below prior low, after OB             |
//+------------------------------------------------------------------+
bool IsBearishExpansionAfterOB(int lookback, datetime obTime)
{
   if(iBars(_Symbol, _Period) < lookback + 2) return false;

   for(int i = 1; i <= lookback; i++)
   {
      if(iTime(_Symbol, _Period, i) <= obTime) break;

      double c       = iClose(_Symbol, _Period, i);
      double o       = iOpen (_Symbol, _Period, i);
      double prevLow = iLow  (_Symbol, _Period, i + 1);

      if(c < o && c < prevLow)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| BULLISH FVG — high[i+2] < low[i], after OB                     |
//+------------------------------------------------------------------+
bool HasBullishFVGAfterOB(int lookback, datetime obTime)
{
   if(iBars(_Symbol, _Period) < lookback + 3) return false;

   for(int i = 1; i <= lookback; i++)
   {
      if(iTime(_Symbol, _Period, i)     <= obTime) break;
      if(iTime(_Symbol, _Period, i + 2) <= obTime) break;

      if(iHigh(_Symbol, _Period, i + 2) < iLow(_Symbol, _Period, i))
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| BEARISH FVG — low[i+2] > high[i], after OB                     |
//+------------------------------------------------------------------+
bool HasBearishFVGAfterOB(int lookback, datetime obTime)
{
   if(iBars(_Symbol, _Period) < lookback + 3) return false;

   for(int i = 1; i <= lookback; i++)
   {
      if(iTime(_Symbol, _Period, i)     <= obTime) break;
      if(iTime(_Symbol, _Period, i + 2) <= obTime) break;

      if(iLow(_Symbol, _Period, i + 2) > iHigh(_Symbol, _Period, i))
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| SWING HIGH — bar 2 pivot, bars 1 & 3 as closed shoulders        |
//+------------------------------------------------------------------+
bool IsSwingHigh()
{
   return (iHigh(_Symbol, _Period, 2) > iHigh(_Symbol, _Period, 1) &&
           iHigh(_Symbol, _Period, 2) > iHigh(_Symbol, _Period, 3));
}

//+------------------------------------------------------------------+
//| SWING LOW — bar 2 pivot, bars 1 & 3 as closed shoulders         |
//+------------------------------------------------------------------+
bool IsSwingLow()
{
   return (iLow(_Symbol, _Period, 2) < iLow(_Symbol, _Period, 1) &&
           iLow(_Symbol, _Period, 2) < iLow(_Symbol, _Period, 3));
}

//+------------------------------------------------------------------+
void ResetBullishState()
{
   isPullbackActive  = false;
   bullishZoneLocked = false;
   barsSinceBearOB   = 0;

   tempBearishOB.high  = 0;
   tempBearishOB.low   = 0;
   tempBearishOB.close = 0;
   tempBearishOB.time  = 0;
}

//+------------------------------------------------------------------+
void ResetBearishState()
{
   isRallyActive     = false;
   bearishZoneLocked = false;
   barsSinceBullOB   = 0;

   tempBullishOB.high  = 0;
   tempBullishOB.low   = 0;
   tempBullishOB.close = 0;
   tempBullishOB.time  = 0;
}

//+------------------------------------------------------------------+
//| Draw zone rectangle                                              |
//+------------------------------------------------------------------+
void DrawZone(PriceData &data, string prefix, color zoneColor)
{
   string name = prefix + IntegerToString((int)data.time);

   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0,
      data.time,              data.high,
      TimeCurrent() + 172800, data.low);

   ObjectSetInteger(0, name, OBJPROP_COLOR,      zoneColor);
   ObjectSetInteger(0, name, OBJPROP_FILL,       true);
   ObjectSetInteger(0, name, OBJPROP_BACK,       true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| Extend all zone right edges                                      |
//+------------------------------------------------------------------+
void ExtendZones()
{
   datetime newRight = TimeCurrent() + 172800;

   for(int i = 0; i < ArraySize(confirmedBullishZones); i++)
   {
      string name = "OB_Demand_" + IntegerToString((int)confirmedBullishZones[i].time);
      if(!ObjectMove(0, name, 1, newRight, confirmedBullishZones[i].low))
         Print("ExtendZones: failed to move ", name, " error: ", GetLastError());
   }

   for(int i = 0; i < ArraySize(confirmedBearishZones); i++)
   {
      string name = "OB_Supply_" + IntegerToString((int)confirmedBearishZones[i].time);
      if(!ObjectMove(0, name, 1, newRight, confirmedBearishZones[i].low))
         Print("ExtendZones: failed to move ", name, " error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
void DebugInfo()
{
   int    swingHighCount = ArraySize(swingHighs);
   int    swingLowCount  = ArraySize(swingLows);
   double lastHigh       = swingHighCount > 0 ? swingHighs[swingHighCount - 1] : 0;
   double lastLow        = swingLowCount  > 0 ? swingLows [swingLowCount  - 1] : 0;

   string trendLine;
   switch(currentTrend)
   {
      case TREND_UP:      trendLine = "▲ UPTREND";   break;
      case TREND_DOWN:    trendLine = "▼ DOWNTREND"; break;
      default:            trendLine = "↔ RANGING";   break;
   }

   string output =
      "=== MARKET STRUCTURE v8 ===\n"                                              +
      "Trend            : " + trendLine                                            + "\n" +
      "Filter Active    : " + (TrendFilterEnabled ? "YES" : "NO")                 + "\n" +
      "Prev Swing High  : " + DoubleToString(prevSwingHigh, _Digits)              + "\n" +
      "Last Swing High  : " + DoubleToString(lastSwingHigh, _Digits)              + "\n" +
      "Prev Swing Low   : " + DoubleToString(prevSwingLow,  _Digits)              + "\n" +
      "Last Swing Low   : " + DoubleToString(lastSwingLow,  _Digits)              + "\n" +
      "\n"                                                                          +
      "-- BULLISH (Demand) --\n"                                                   +
      "Pullback Active  : " + (isPullbackActive  ? "YES" : "NO")                  + "\n" +
      "Demand Locked    : " + (bullishZoneLocked ? "YES" : "NO")                  + "\n" +
      "Bars since BearOB: " + IntegerToString(barsSinceBearOB)                    + "\n" +
      "Bear OB Low(TEMP)      : " + DoubleToString(tempBearishOB.low,  _Digits)         + "\n" +
      "Demand Zones     : " + IntegerToString(ArraySize(confirmedBullishZones))   + "\n" +
      "\n"                                                                          +
      "-- BEARISH (Supply) --\n"                                                   +
      "Rally Active     : " + (isRallyActive     ? "YES" : "NO")                  + "\n" +
      "Supply Locked    : " + (bearishZoneLocked ? "YES" : "NO")                  + "\n" +
      "Bars since BullOB: " + IntegerToString(barsSinceBullOB)                    + "\n" +
      "Bull OB High(TEMP)     : " + DoubleToString(tempBullishOB.high, _Digits)         + "\n" +
      "Supply Zones     : " + IntegerToString(ArraySize(confirmedBearishZones));

   Comment(output);
}

//+------------------------------------------------------------------+
bool isNewBar()
{
   static datetime last_time = 0;
   datetime current = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);

   if(last_time == 0)       { last_time = current; return false; }
   if(last_time != current) { last_time = current; return true;  }

   return false;
}
//+------------------------------------------------------------------+