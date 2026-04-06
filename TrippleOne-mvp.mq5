//+------------------------------------------------------------------+
//|                                     MarketStructure_ZoneBot v8   |
//| Standardized SMC/ICT Logic: Expansion, FVG, BOS, and Invalidation|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "8.00"
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
};

//==================== GLOBALS ====================

// --- Trend state ---
TREND_STATE currentTrend     = TREND_RANGING;
double      lastSwingHigh    = 0; 
double      lastSwingLow     = 0; 
double      prevSwingHigh    = 0; 
double      prevSwingLow     = 0; 

// --- Bullish side (demand zones) ---
double    swingHighs[];
PriceData confirmedBullishZones[];
PriceData tempBearishOB; // The down candle before a pump

bool isPullbackActive  = false;
bool bullishZoneLocked = false;
int  barsSinceBearOB   = 0;

// --- Bearish side (supply zones) ---
double    swingLows[];
PriceData confirmedBearishZones[];
PriceData tempBullishOB; // The up candle before a dump

bool isRallyActive     = false;
bool bearishZoneLocked = false;
int  barsSinceBullOB   = 0;

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
   EffectiveExpansionLookback = MathMin(ExpansionLookback, 50);
   EffectiveFVGLookback       = MathMin(FVG_Lookback,      50);

   ObjectsDeleteAll(0, "OB_Demand_");
   ObjectsDeleteAll(0, "OB_Supply_");

   ArrayResize(swingHighs,            0);
   ArrayResize(swingLows,             0);
   ArrayResize(confirmedBullishZones, 0);
   ArrayResize(confirmedBearishZones, 0);

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { ObjectsDeleteAll(0, "OB_Demand_"); ObjectsDeleteAll(0, "OB_Supply_"); Comment(""); }

void OnTick()
{
   // Invalidation check runs every tick to catch price breaches immediately
   InvalidateAndExtend();

   if(!isNewBar()) return;

   ProcessBullishStructure();
   ProcessBearishStructure();
   UpdateTrendState();
   DebugInfo();
}

//+------------------------------------------------------------------+
//| CORE LOGIC: BULLISH SIDE (Demand)                                |
//+------------------------------------------------------------------+
void ProcessBullishStructure()
{
   if(isPullbackActive) barsSinceBearOB++;

   double open1 = iOpen(_Symbol,_Period,1);
   double close1= iClose(_Symbol,_Period,1);
   double high1 = iHigh(_Symbol,_Period,1);
   double low1  = iLow(_Symbol,_Period,1);

   // STEP 1: Track Bearish OB Candidate
   if(!bullishZoneLocked && close1 < open1)
   {
      if(!isPullbackActive || low1 < tempBearishOB.low)
      {
         tempBearishOB.high  = high1;
         tempBearishOB.low   = low1;
         tempBearishOB.time  = iTime(_Symbol,_Period,1);
         isPullbackActive    = true;
         barsSinceBearOB     = 0;
      }
   }

   // STEP 2: Confirm via Expansion + FVG
   if(isPullbackActive && !bullishZoneLocked && barsSinceBearOB >= 2)
   {
      if(IsBullishExpansionAfterOB(EffectiveExpansionLookback, tempBearishOB.time) &&
         HasBullishFVGAfterOB(EffectiveFVGLookback, tempBearishOB.time))
      {
         bullishZoneLocked = true;
      }
   }

   // STEP 3: Promote on BOS
   double highClosed = iHigh(_Symbol,_Period,2);
   if(IsSwingHigh() && highClosed > (lastSwingHigh + (BOS_Buffer_Points * _Point)))
   {
      prevSwingHigh = lastSwingHigh;
      lastSwingHigh = highClosed;
      
      bool trendAllows = !TrendFilterEnabled || (currentTrend != TREND_DOWN);

      if(bullishZoneLocked && tempBearishOB.low > 0 && trendAllows)
      {
         // Wick Expansion Check
         int obIdx = iBarShift(_Symbol,_Period, tempBearishOB.time);
         if(obIdx > 0 && iLow(_Symbol,_Period, obIdx-1) < tempBearishOB.low)
            tempBearishOB.low = iLow(_Symbol,_Period, obIdx-1);

         AddZone(confirmedBullishZones, tempBearishOB);
         DrawZone(tempBearishOB, "OB_Demand_", clrDodgerBlue);
      }
      ResetBullishState();
   }
}

//+------------------------------------------------------------------+
//| CORE LOGIC: BEARISH SIDE (Supply)                                |
//+------------------------------------------------------------------+
void ProcessBearishStructure()
{
   if(isRallyActive) barsSinceBullOB++;

   double open1 = iOpen(_Symbol,_Period,1);
   double close1= iClose(_Symbol,_Period,1);
   double high1 = iHigh(_Symbol,_Period,1);
   double low1  = iLow(_Symbol,_Period,1);

   if(!bearishZoneLocked && close1 > open1)
   {
      if(!isRallyActive || high1 > tempBullishOB.high)
      {
         tempBullishOB.high  = high1;
         tempBullishOB.low   = low1;
         tempBullishOB.time  = iTime(_Symbol,_Period,1);
         isRallyActive       = true;
         barsSinceBullOB     = 0;
      }
   }

   if(isRallyActive && !bearishZoneLocked && barsSinceBullOB >= 2)
   {
      if(IsBearishExpansionAfterOB(EffectiveExpansionLookback, tempBullishOB.time) &&
         HasBearishFVGAfterOB(EffectiveFVGLookback, tempBullishOB.time))
      {
         bearishZoneLocked = true;
      }
   }

   double lowClosed = iLow(_Symbol,_Period,2);
   if(IsSwingLow() && lowClosed < (lastSwingLow - (BOS_Buffer_Points * _Point)))
   {
      prevSwingLow = lastSwingLow;
      lastSwingLow = lowClosed;

      bool trendAllows = !TrendFilterEnabled || (currentTrend != TREND_UP);

      if(bearishZoneLocked && tempBullishOB.high > 0 && trendAllows)
      {
         // Wick Expansion Check
         int obIdx = iBarShift(_Symbol,_Period, tempBullishOB.time);
         if(obIdx > 0 && iHigh(_Symbol,_Period, obIdx-1) > tempBullishOB.high)
            tempBullishOB.high = iHigh(_Symbol,_Period, obIdx-1);

         AddZone(confirmedBearishZones, tempBullishOB);
         DrawZone(tempBullishOB, "OB_Supply_", clrTomato);
      }
      ResetBearishState();
   }
}

//+------------------------------------------------------------------+
//| ZONE INVALIDATION & EXTENSION                                    |
//+------------------------------------------------------------------+
void InvalidateAndExtend()
{
   datetime newRight = TimeCurrent() + 172800;

   // Demand Invalidation (Breached if Low < Zone Low)
   for(int i = ArraySize(confirmedBullishZones)-1; i >= 0; i--)
   {
      string name = "OB_Demand_" + IntegerToString((int)confirmedBullishZones[i].time);
      if(iLow(_Symbol, _Period, 0) < confirmedBullishZones[i].low) {
         ObjectDelete(0, name);
         ArrayRemoveCustom(confirmedBullishZones, i);
         continue;
      }
      ObjectMove(0, name, 1, newRight, confirmedBullishZones[i].low);
   }

   // Supply Invalidation (Breached if High > Zone High)
   for(int i = ArraySize(confirmedBearishZones)-1; i >= 0; i--)
   {
      string name = "OB_Supply_" + IntegerToString((int)confirmedBearishZones[i].time);
      if(iHigh(_Symbol, _Period, 0) > confirmedBearishZones[i].high) {
         ObjectDelete(0, name);
         ArrayRemoveCustom(confirmedBearishZones, i);
         continue;
      }
      ObjectMove(0, name, 1, newRight, confirmedBearishZones[i].low);
   }
}

//+------------------------------------------------------------------+
//| UTILS & HELPERS                                                  |
//+------------------------------------------------------------------+
void UpdateTrendState()
{
   if(prevSwingHigh == 0 || prevSwingLow == 0) { currentTrend = TREND_RANGING; return; }
   if(lastSwingHigh > prevSwingHigh && lastSwingLow > prevSwingLow) currentTrend = TREND_UP;
   else if(lastSwingLow < prevSwingLow && lastSwingHigh < prevSwingHigh) currentTrend = TREND_DOWN;
   else currentTrend = TREND_RANGING;
}

bool IsBullishExpansionAfterOB(int lookback, datetime obTime) {
   int idx = iBarShift(_Symbol,_Period,obTime);
   for(int i=idx-1; i>=1 && i>=idx-lookback; i--)
      if(iClose(_Symbol,_Period,i) > iHigh(_Symbol,_Period,i+1)) return true;
   return false;
}

bool IsBearishExpansionAfterOB(int lookback, datetime obTime) {
   int idx = iBarShift(_Symbol,_Period,obTime);
   for(int i=idx-1; i>=1 && i>=idx-lookback; i--)
      if(iClose(_Symbol,_Period,i) < iLow(_Symbol,_Period,i+1)) return true;
   return false;
}

bool HasBullishFVGAfterOB(int lookback, datetime obTime) {
   int idx = iBarShift(_Symbol,_Period,obTime);
   for(int i=idx-1; i>=1 && i>=idx-lookback; i--)
      if(iHigh(_Symbol,_Period,i+1) < iLow(_Symbol,_Period,i-1)) return true;
   return false;
}

bool HasBearishFVGAfterOB(int lookback, datetime obTime) {
   int idx = iBarShift(_Symbol,_Period,obTime);
   for(int i=idx-1; i>=1 && i>=idx-lookback; i--)
      if(iLow(_Symbol,_Period,i+1) > iHigh(_Symbol,_Period,i-1)) return true;
   return false;
}

bool IsSwingHigh() { return (iHigh(_Symbol,_Period,2) > iHigh(_Symbol,_Period,1) && iHigh(_Symbol,_Period,2) > iHigh(_Symbol,_Period,3)); }
bool IsSwingLow()  { return (iLow(_Symbol,_Period,2)  < iLow(_Symbol,_Period,1)  && iLow(_Symbol,_Period,2)  < iLow(_Symbol,_Period,3));  }

void AddZone(PriceData &arr[], PriceData &val) {
   int s = ArraySize(arr);
   if(s >= MaxStoredSwings) { ArrayRemoveCustom(arr, 0); s = ArraySize(arr); }
   ArrayResize(arr, s+1);
   arr[s] = val;
}

template<typename T>
void ArrayRemoveCustom(T &arr[], int index) {
   int s = ArraySize(arr);
   for(int i=index; i<s-1; i++) arr[i] = arr[i+1];
   ArrayResize(arr, s-1);
}

void DrawZone(PriceData &data, string prefix, color c) {
   string name = prefix + IntegerToString((int)data.time);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, data.time, data.high, TimeCurrent()+172800, data.low);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
}

void ResetBullishState() { isPullbackActive=false; bullishZoneLocked=false; barsSinceBearOB=0; ZeroMemory(tempBearishOB); }
void ResetBearishState() { isRallyActive=false; bearishZoneLocked=false; barsSinceBullOB=0; ZeroMemory(tempBullishOB); }

bool isNewBar() {
   static datetime last = 0;
   datetime curr = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   if(last != curr) { last = curr; return true; }
   return false;
}

void DebugInfo() {
   string out = "Trend: " + (currentTrend==TREND_UP?"UP":currentTrend==TREND_DOWN?"DOWN":"RANGING") + 
                "\nDemand Zones: " + (string)ArraySize(confirmedBullishZones) +
                "\nSupply Zones: " + (string)ArraySize(confirmedBearishZones);
   Comment(out);
}