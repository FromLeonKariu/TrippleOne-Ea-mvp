//+------------------------------------------------------------------+
//| MarketStructure_ZoneBot v9                                       |
//| Base: v7 (correct trend logic, correct isNewBar, correct FVG)   |
//|                                                                  |
//| Cherry-picked improvements from submitted v8:                   |
//|  + ZeroMemory() in reset functions                              |
//|  + ArrayRemoveCustom() template — reusable removal              |
//|  + AddZone() helper — no duplicate resize logic                 |
//|  + iBarShift() in expansion/FVG scans — DST/gap safe           |
//|  + Wick expansion on zone promotion                             |
//|  + Tick-level zone invalidation (InvalidateAndExtend)           |
//|                                                                  |
//| Reverted / kept from v7:                                        |
//|  - isNewBar() init guard (last==0 → false) restored            |
//|  - HH/HL + LL/LH trend logic restored                          |
//|  - DebugInfo() does NOT call isNewBar()                        |
//|  - DrawZone() ObjectDelete before create restored              |
//|  - swingHighs[]/swingLows[] dead code removed                  |
//|  - lastSwingHigh/lastSwingLow seeded on first swing            |
//|  - FVG bar direction correct (older left, newer right)         |
//|  - TrendFilterEnabled explicit == TREND_UP/RANGING logic       |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "9.00"
#property strict

//==================== ENUMS ====================
enum TREND_STATE
{
   TREND_UP      =  1,  // Higher highs + higher lows
   TREND_DOWN    = -1,  // Lower lows   + lower highs
   TREND_RANGING =  0   // No clear sequence
};

//==================== STRUCTS ====================
struct PriceData {
   double   high;
   double   low;
   double   close;
   datetime time;
};

//==================== GLOBALS ====================

// --- Trend state ---
TREND_STATE currentTrend  = TREND_RANGING;
double lastSwingHigh      = 0;  // most recent confirmed swing high
double lastSwingLow       = 0;  // most recent confirmed swing low
double prevSwingHigh      = 0;  // swing high before lastSwingHigh
double prevSwingLow       = 0;  // swing low  before lastSwingLow

// --- Bullish side (demand zones) ---
PriceData confirmedBullishZones[];
PriceData tempBearishOB;         // lowest bearish candle → demand OB

bool isPullbackActive  = false;
bool bullishZoneLocked = false;
int  barsSinceBearOB   = 0;

// --- Bearish side (supply zones) ---
PriceData confirmedBearishZones[];
PriceData tempBullishOB;         // highest bullish candle → supply OB

bool isRallyActive     = false;
bool bearishZoneLocked = false;
int  barsSinceBullOB   = 0;

// --- Shadow locals for capped inputs ---
int EffectiveExpansionLookback;
int EffectiveFVGLookback;

//==================== INPUTS ====================
input double BOS_Buffer_Points  = 20;   // Points buffer to confirm BOS
input int    MaxStoredSwings    = 50;   // Max zones stored per side
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
   ObjectsDeleteAll(0, "Panel_");

   ArrayResize(confirmedBullishZones, 0);
   ArrayResize(confirmedBearishZones, 0);

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
   ObjectsDeleteAll(0, "Panel_");
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Tick-level: invalidate breached zones + extend right edge
   // Improvement from v8 — runs every tick, not just on bar close
   InvalidateAndExtend();

   if(!isNewBar()) return;

   ProcessBullishStructure();
   ProcessBearishStructure();
   UpdateTrendState();   // runs after both sides so swing levels are fresh
   DebugInfo();
}

//+------------------------------------------------------------------+
//| BULLISH SIDE — demand zones, bearish OB, bullish BOS            |
//+------------------------------------------------------------------+
void ProcessBullishStructure()
{
   if(isPullbackActive)
      barsSinceBearOB++;

   double open1  = iOpen (_Symbol, _Period, 1);
   double close1 = iClose(_Symbol, _Period, 1);
   double high1  = iHigh (_Symbol, _Period, 1);
   double low1   = iLow  (_Symbol, _Period, 1);

   // STEP 1: Track bearish OB candidate (lowest bear candle)
   if(!bullishZoneLocked && close1 < open1)
   {
      if(!isPullbackActive || low1 < tempBearishOB.low)
      {
         tempBearishOB.high  = high1;
         tempBearishOB.low   = low1;
         tempBearishOB.close = close1;
         tempBearishOB.time  = iTime(_Symbol, _Period, 1);

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
         Print("Demand Zone Locked at Low: ", tempBearishOB.low,
               " | Bars since OB: ", barsSinceBearOB,
               " | Trend: ", TrendLabel());
      }
   }

   // STEP 3: Bullish BOS → promote demand zone
   // Bar 2 pivot — all bars fully closed
   double highClosed = iHigh(_Symbol, _Period, 2);
   double buffer     = BOS_Buffer_Points * _Point;

   // Seed first swing high level on first valid bar
   if(lastSwingHigh == 0)
   {
      lastSwingHigh = highClosed;
      return;
   }

   if(IsSwingHigh() && highClosed > lastSwingHigh + buffer)
   {
      // Update trend tracking BEFORE storing new swing
      prevSwingHigh = lastSwingHigh;
      lastSwingHigh = highClosed;

      // Gate by trend — demand only in uptrend or ranging
      bool trendAllows = !TrendFilterEnabled ||
                         (currentTrend == TREND_UP || currentTrend == TREND_RANGING);

      if(bullishZoneLocked && tempBearishOB.low > 0 && trendAllows)
      {
         // Improvement from v8: wick expansion — extend zone low
         // to include wick of bar immediately before OB if it printed lower
         int obIdx = iBarShift(_Symbol, _Period, tempBearishOB.time);
         if(obIdx > 0 && iLow(_Symbol, _Period, obIdx + 1) < tempBearishOB.low)
            tempBearishOB.low = iLow(_Symbol, _Period, obIdx + 1);

         AddZone(confirmedBullishZones, tempBearishOB);
         DrawZone(tempBearishOB, "OB_Demand_", clrDodgerBlue);
         Print("Bullish BOS → Demand Zone saved at: ", tempBearishOB.low,
               " | Trend: ", TrendLabel());
      }
      else if(bullishZoneLocked && !trendAllows)
         Print("Demand zone suppressed by trend filter (", TrendLabel(), ")");
      else if(isPullbackActive)
         Print("Bullish BOS without locked zone → OB discarded at: ", tempBearishOB.low);

      ResetBullishState();
   }
}

//+------------------------------------------------------------------+
//| BEARISH SIDE — supply zones, bullish OB, bearish BOS            |
//+------------------------------------------------------------------+
void ProcessBearishStructure()
{
   if(isRallyActive)
      barsSinceBullOB++;

   double open1  = iOpen (_Symbol, _Period, 1);
   double close1 = iClose(_Symbol, _Period, 1);
   double high1  = iHigh (_Symbol, _Period, 1);
   double low1   = iLow  (_Symbol, _Period, 1);

   // STEP 1: Track bullish OB candidate (highest bull candle)
   if(!bearishZoneLocked && close1 > open1)
   {
      if(!isRallyActive || high1 > tempBullishOB.high)
      {
         tempBullishOB.high  = high1;
         tempBullishOB.low   = low1;
         tempBullishOB.close = close1;
         tempBullishOB.time  = iTime(_Symbol, _Period, 1);

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
         Print("Supply Zone Locked at High: ", tempBullishOB.high,
               " | Bars since OB: ", barsSinceBullOB,
               " | Trend: ", TrendLabel());
      }
   }

   // STEP 3: Bearish BOS → promote supply zone
   // Bar 2 pivot — all bars fully closed
   double lowClosed = iLow(_Symbol, _Period, 2);
   double buffer    = BOS_Buffer_Points * _Point;

   // Seed first swing low level on first valid bar
   if(lastSwingLow == 0)
   {
      lastSwingLow = lowClosed;
      return;
   }

   if(IsSwingLow() && lowClosed < lastSwingLow - buffer)
   {
      // Update trend tracking BEFORE storing new swing
      prevSwingLow = lastSwingLow;
      lastSwingLow = lowClosed;

      // Gate by trend — supply only in downtrend or ranging
      bool trendAllows = !TrendFilterEnabled ||
                         (currentTrend == TREND_DOWN || currentTrend == TREND_RANGING);

      if(bearishZoneLocked && tempBullishOB.high > 0 && trendAllows)
      {
         // Improvement from v8: wick expansion — extend zone high
         // to include wick of bar immediately before OB if it printed higher
         int obIdx = iBarShift(_Symbol, _Period, tempBullishOB.time);
         if(obIdx > 0 && iHigh(_Symbol, _Period, obIdx + 1) > tempBullishOB.high)
            tempBullishOB.high = iHigh(_Symbol, _Period, obIdx + 1);

         AddZone(confirmedBearishZones, tempBullishOB);
         DrawZone(tempBullishOB, "OB_Supply_", clrTomato);
         Print("Bearish BOS → Supply Zone saved at: ", tempBullishOB.high,
               " | Trend: ", TrendLabel());
      }
      else if(bearishZoneLocked && !trendAllows)
         Print("Supply zone suppressed by trend filter (", TrendLabel(), ")");
      else if(isRallyActive)
         Print("Bearish BOS without locked zone → OB discarded at: ", tempBullishOB.high);

      ResetBearishState();
   }
}

//+------------------------------------------------------------------+
//| TREND STATE — HH/HL = uptrend, LL/LH = downtrend               |
//| v7 logic restored — more robust than raw price vs level check   |
//+------------------------------------------------------------------+
void UpdateTrendState()
{
   // Need two confirmed swings on each side to classify
   if(prevSwingHigh == 0 || prevSwingLow == 0)
   {
      currentTrend = TREND_RANGING;
      return;
   }

   bool higherHigh = lastSwingHigh > prevSwingHigh;
   bool higherLow  = lastSwingLow  > prevSwingLow;
   bool lowerLow   = lastSwingLow  < prevSwingLow;
   bool lowerHigh  = lastSwingHigh < prevSwingHigh;

   TREND_STATE prev = currentTrend;

   if(higherHigh && higherLow)
      currentTrend = TREND_UP;
   else if(lowerLow && lowerHigh)
      currentTrend = TREND_DOWN;
   else
      currentTrend = TREND_RANGING;

   if(currentTrend != prev)
      Print("STRUCTURAL SHIFT → ", TrendLabel(),
            " | HH:", DoubleToString(lastSwingHigh,_Digits),
            " HL:", DoubleToString(lastSwingLow,_Digits));
}

//+------------------------------------------------------------------+
//| ZONE INVALIDATION + RIGHT EDGE EXTENSION (every tick)           |
//| Improvement from v8 — moved from OnNewBar to OnTick             |
//+------------------------------------------------------------------+
void InvalidateAndExtend()
{
   datetime newRight = TimeCurrent() + 172800;
   double   bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Demand zones — invalidate if current price closes below zone low
   for(int i = ArraySize(confirmedBullishZones) - 1; i >= 0; i--)
   {
      string name = "OB_Demand_" + IntegerToString((int)confirmedBullishZones[i].time);
      if(bid < confirmedBullishZones[i].low)
      {
         ObjectDelete(0, name);
         ArrayRemoveCustom(confirmedBullishZones, i);
         Print("Demand Zone invalidated at: ", confirmedBullishZones[i].low);
         continue;
      }
      ObjectMove(0, name, 1, newRight, confirmedBullishZones[i].low);
   }

   // Supply zones — invalidate if current price closes above zone high
   for(int i = ArraySize(confirmedBearishZones) - 1; i >= 0; i--)
   {
      string name = "OB_Supply_" + IntegerToString((int)confirmedBearishZones[i].time);
      if(bid > confirmedBearishZones[i].high)
      {
         ObjectDelete(0, name);
         ArrayRemoveCustom(confirmedBearishZones, i);
         Print("Supply Zone invalidated at: ", confirmedBearishZones[i].high);
         continue;
      }
      ObjectMove(0, name, 1, newRight, confirmedBearishZones[i].low);
   }
}

//+------------------------------------------------------------------+
//| BULLISH EXPANSION — close above prior bar high, after OB        |
//| Uses iBarShift for DST/gap safety (improvement from v8)         |
//+------------------------------------------------------------------+
bool IsBullishExpansionAfterOB(int lookback, datetime obTime)
{
   if(iBars(_Symbol, _Period) < lookback + 2) return false;

   int obIdx = iBarShift(_Symbol, _Period, obTime);
   if(obIdx < 0) return false;

   // Scan bars newer than OB (lower index = more recent)
   for(int i = obIdx - 1; i >= 1 && i >= obIdx - lookback; i--)
   {
      double c        = iClose(_Symbol, _Period, i);
      double prevHigh = iHigh (_Symbol, _Period, i + 1);
      double o        = iOpen (_Symbol, _Period, i);

      if(c > o && c > prevHigh)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| BEARISH EXPANSION — close below prior bar low, after OB         |
//+------------------------------------------------------------------+
bool IsBearishExpansionAfterOB(int lookback, datetime obTime)
{
   if(iBars(_Symbol, _Period) < lookback + 2) return false;

   int obIdx = iBarShift(_Symbol, _Period, obTime);
   if(obIdx < 0) return false;

   for(int i = obIdx - 1; i >= 1 && i >= obIdx - lookback; i--)
   {
      double c       = iClose(_Symbol, _Period, i);
      double prevLow = iLow  (_Symbol, _Period, i + 1);
      double o       = iOpen (_Symbol, _Period, i);

      if(c < o && c < prevLow)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| BULLISH FVG — high[left] < low[right], after OB                 |
//| i+1 = middle bar, i+2 = left (older), i = right (newer)        |
//| v7 bar direction preserved — older left, newer right            |
//+------------------------------------------------------------------+
bool HasBullishFVGAfterOB(int lookback, datetime obTime)
{
   if(iBars(_Symbol, _Period) < lookback + 3) return false;

   int obIdx = iBarShift(_Symbol, _Period, obTime);
   if(obIdx < 0) return false;

   // i = right bar of FVG (newest), i+2 = left bar (oldest of the 3)
   // scan from bar just after OB toward present
   for(int i = obIdx - 1; i >= 1 && i >= obIdx - lookback; i--)
   {
      double highLeft  = iHigh(_Symbol, _Period, i + 2); // older
      double lowRight  = iLow (_Symbol, _Period, i);     // newer

      if(highLeft < lowRight)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| BEARISH FVG — low[left] > high[right], after OB                 |
//+------------------------------------------------------------------+
bool HasBearishFVGAfterOB(int lookback, datetime obTime)
{
   if(iBars(_Symbol, _Period) < lookback + 3) return false;

   int obIdx = iBarShift(_Symbol, _Period, obTime);
   if(obIdx < 0) return false;

   for(int i = obIdx - 1; i >= 1 && i >= obIdx - lookback; i--)
   {
      double lowLeft   = iLow (_Symbol, _Period, i + 2); // older
      double highRight = iHigh(_Symbol, _Period, i);     // newer

      if(lowLeft > highRight)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| SWING HIGH — bar 2 pivot, bars 1 & 3 fully closed shoulders     |
//+------------------------------------------------------------------+
bool IsSwingHigh()
{
   return (iHigh(_Symbol, _Period, 2) > iHigh(_Symbol, _Period, 1) &&
           iHigh(_Symbol, _Period, 2) > iHigh(_Symbol, _Period, 3));
}

//+------------------------------------------------------------------+
//| SWING LOW — bar 2 pivot, bars 1 & 3 fully closed shoulders      |
//+------------------------------------------------------------------+
bool IsSwingLow()
{
   return (iLow(_Symbol, _Period, 2) < iLow(_Symbol, _Period, 1) &&
           iLow(_Symbol, _Period, 2) < iLow(_Symbol, _Period, 3));
}

//+------------------------------------------------------------------+
//| AddZone — bounds-checked insert (improvement from v8)           |
//+------------------------------------------------------------------+
void AddZone(PriceData &arr[], PriceData &val)
{
   int s = ArraySize(arr);
   if(s >= MaxStoredSwings)
   {
      ArrayRemoveCustom(arr, 0);
      s = ArraySize(arr);
   }
   ArrayResize(arr, s + 1);
   arr[s] = val;
}

//+------------------------------------------------------------------+
//| ArrayRemoveCustom — reusable template (improvement from v8)     |
//+------------------------------------------------------------------+
template<typename T>
void ArrayRemoveCustom(T &arr[], int index)
{
   int s = ArraySize(arr);
   for(int i = index; i < s - 1; i++)
      arr[i] = arr[i + 1];
   ArrayResize(arr, s - 1);
}

//+------------------------------------------------------------------+
//| DrawZone — ObjectDelete before create (v7 behaviour restored)   |
//+------------------------------------------------------------------+
void DrawZone(PriceData &data, string prefix, color zoneColor)
{
   string name = prefix + IntegerToString((int)data.time);

   ObjectDelete(0, name);   // v7: prevent silent create failure
   ObjectCreate(0, name, OBJ_RECTANGLE, 0,
      data.time,              data.high,
      TimeCurrent() + 172800, data.low);

   ObjectSetInteger(0, name, OBJPROP_COLOR,      zoneColor);
   ObjectSetInteger(0, name, OBJPROP_FILL,       true);
   ObjectSetInteger(0, name, OBJPROP_BACK,       true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| Reset functions — ZeroMemory (improvement from v8)              |
//+------------------------------------------------------------------+
void ResetBullishState()
{
   isPullbackActive  = false;
   bullishZoneLocked = false;
   barsSinceBearOB   = 0;
   ZeroMemory(tempBearishOB);
}

void ResetBearishState()
{
   isRallyActive     = false;
   bearishZoneLocked = false;
   barsSinceBullOB   = 0;
   ZeroMemory(tempBullishOB);
}

//+------------------------------------------------------------------+
//| TrendLabel — human readable trend string                        |
//+------------------------------------------------------------------+
string TrendLabel()
{
   switch(currentTrend)
   {
      case TREND_UP:   return "UPTREND";
      case TREND_DOWN: return "DOWNTREND";
      default:         return "RANGING";
   }
}

//+------------------------------------------------------------------+
//| isNewBar — init guard restored from v7                          |
//| DebugInfo() does NOT call this (v8 regression avoided)          |
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
//| DebugInfo — Comment() panel                                     |
//| Does NOT call isNewBar() (v8 regression avoided)               |
//+------------------------------------------------------------------+
void DebugInfo()
{
   string trendLine;
   switch(currentTrend)
   {
      case TREND_UP:   trendLine = "▲ UPTREND";   break;
      case TREND_DOWN: trendLine = "▼ DOWNTREND"; break;
      default:         trendLine = "↔ RANGING";   break;
   }

   string output =
      "=== MARKET STRUCTURE v9 ===\n"                                             +
      "Time             : " + TimeToString(TimeCurrent(), TIME_SECONDS)           + "\n" +
      "Trend            : " + trendLine                                           + "\n" +
      "Filter Active    : " + (TrendFilterEnabled ? "YES" : "NO")                + "\n" +
      "Prev Swing High  : " + DoubleToString(prevSwingHigh, _Digits)             + "\n" +
      "Last Swing High  : " + DoubleToString(lastSwingHigh, _Digits)             + "\n" +
      "Prev Swing Low   : " + DoubleToString(prevSwingLow,  _Digits)             + "\n" +
      "Last Swing Low   : " + DoubleToString(lastSwingLow,  _Digits)             + "\n" +
      "---\n"                                                                      +
      "BULLISH (Demand)\n"                                                         +
      " Pullback Active : " + (isPullbackActive  ? "YES" : "NO")                 + "\n" +
      " Zone Locked     : " + (bullishZoneLocked ? "YES" : "NO")                 + "\n" +
      " Bars Since OB   : " + IntegerToString(barsSinceBearOB)                   + "\n" +
      " OB Low          : " + DoubleToString(tempBearishOB.low,  _Digits)        + "\n" +
      " Active Zones    : " + IntegerToString(ArraySize(confirmedBullishZones))  + "\n" +
      "---\n"                                                                      +
      "BEARISH (Supply)\n"                                                         +
      " Rally Active    : " + (isRallyActive     ? "YES" : "NO")                 + "\n" +
      " Zone Locked     : " + (bearishZoneLocked ? "YES" : "NO")                 + "\n" +
      " Bars Since OB   : " + IntegerToString(barsSinceBullOB)                   + "\n" +
      " OB High         : " + DoubleToString(tempBullishOB.high, _Digits)        + "\n" +
      " Active Zones    : " + IntegerToString(ArraySize(confirmedBearishZones));

   Comment(output);
}
//+------------------------------------------------------------------+