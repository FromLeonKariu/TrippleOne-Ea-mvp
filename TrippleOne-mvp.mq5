//+------------------------------------------------------------------+
//|                                               TrippleOne-mvp.mq5 |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Leon Kariu"
#property link      "https:/leonkariu.xyz"
#property version   "1.01"

//imports


#include <Trade\Trade.mqh>

//variables

int londonOpenDst = 10;
int londonOpen = 11;
int newYorkOpenDst = 15;
int newYorkOpen = 16;
int magicNumber = 9999;
int swingStrength = 20;
 
int tradesTaken[];
CTrade trade;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//---
   Print("EA INITIALIZED!!");
//---
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//---
   
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//---
   if(!isNewBar()) return; 

   checkSwing();
  }
//+------------------------------------------------------------------+
//| Trade function                                                   |
//+------------------------------------------------------------------+
void OnTrade()
  {
//---
   
  }



  void drawSwingLines() {
    // This function would contain code to draw lines on the chart for swing highs and lows
    // It would use the swing points identified in the checkSwing() function
  }

  void drawZone(string name, datetime time_1, double anchor_price_1_high, datetime time_2, double anchor_price_2_low) {
    // This function would contain code to draw the demand/supply zone based on the anchor prices
    bool objectCreated = ObjectCreate(_Symbol, name, OBJ_RECTANGLE_LABEL, 0, time_1, anchor_price_1_high , time_2, anchor_price_2_low);
 
  if (!objectCreated) {
    Print("Failed to create zone object");
    return;
  }
    ObjectSetInteger(_Symbol, name, OBJPROP_BACK, true); // Send to back
    ObjectSetInteger(_Symbol, name, OBJPROP_COLOR, clrYellow); // Set color
    ObjectSetInteger(_Symbol, name, OBJPROP_WIDTH, 2); // Set line width
    Print("Zone drawn successfully!");
  }


//+------------------------------------------------------------------+
//| TradeTransaction function                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
  {
//---
   
  }
//+------------------------------------------------------------------+

bool isNewBar() {
   
   static datetime lastbar = 0;
   datetime currentBar = iTime(_Symbol, _Period, 0);
   if (currentBar != lastbar) {
   lastbar = currentBar;
   return true;
   }
   
   return false;
}

bool hasOpenPosition(){
   for(int i = PositionsTotal()-1; i>=0; i--){
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == magicNumber)
      return true;
      }
   }
   return false;
}

double calculateLotSize (double entry, double sl) {
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * 0.005;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   double slPoints = MathAbs(entry - sl) /pointValue;
   if (slPoints <= 0) return 0.01;
   
   double lot = riskAmount / (slPoints * tickValue * pointValue / _Point);
   return NormalizeDouble(lot, 2);
}

void manageTrade() {

   
}

   
   // Strength 2 means 2 lower highs on each side (standard fractal)
   bool IsSwingHigh(const double &highs[], int i, int strength, int totalBars) {
       // Boundary protection
       if(i < strength || i > totalBars - strength - 1) return false;
   
       for(int j = 1; j <= strength; j++) {
           if(highs[i] <= highs[i + j]) return false; // Check older bars
           if(highs[i] <= highs[i - j]) return false; // Check newer bars
       }
       return true;
}

bool IsSwingLow(const double &lows[], int i, int strength, int totalBars) {
    if(i < strength || i > totalBars - strength - 1) return false;

    for(int j = 1; j <= strength; j++) {
        if(lows[i] >= lows[i + j]) return false; 
        if(lows[i] >= lows[i - j]) return false;
    }
    return true;
}

// Body High = top of the candle body (regardless of bull/bear)
double BodyHigh(int index) {
    return MathMax(iOpen(_Symbol, _Period, index), 
                   iClose(_Symbol, _Period, index));
}

// Body Low = bottom of the candle body
double BodyLow(int index) {
    return MathMin(iOpen(_Symbol, _Period, index), 
                   iClose(_Symbol, _Period, index));
}


struct SwingPoint {
    double   price;
    int      index;
    datetime time;
};


int FindSwings(const double &highs[], const double &lows[], 
               const datetime &times[], int totalBars, int strength,
               SwingPoint &swingHighs[], SwingPoint &swingLows[]) {

    int shCount = 0, slCount = 0;
    ArrayResize(swingHighs, 0);
    ArrayResize(swingLows,  0);

    for(int i = strength; i < totalBars - strength; i++) {
        // Swing High
        if(IsSwingHigh(highs, i, strength, totalBars)) {
            ArrayResize(swingHighs, shCount + 1);
            swingHighs[shCount].price = highs[i];
            swingHighs[shCount].index = i;
            swingHighs[shCount].time  = times[i];
            shCount++;
        }
        // Swing Low
        if(IsSwingLow(lows, i, strength, totalBars)) {
            ArrayResize(swingLows, slCount + 1);
            swingLows[slCount].price = lows[i];
            swingLows[slCount].index = i;
            swingLows[slCount].time  = times[i];
            slCount++;
        }
    }
    return shCount + slCount; // total swings found
}



void checkSwing() {

   
   double buffer_highs[];
   double buffer_lows[] ;
   datetime times_buffer[];
      
   // 2. Set as Series (Index 0 = Current Candle)
   ArraySetAsSeries(buffer_highs, true);
   ArraySetAsSeries(buffer_lows, true);
   ArraySetAsSeries(times_buffer, true);

   // 3. Copy the last 500 bars of data from the chart
   int lookback = 500; 
   if(CopyHigh(_Symbol, _Period, 0, lookback, buffer_highs) < lookback) return;
   if(CopyLow(_Symbol, _Period, 0, lookback, buffer_lows) < lookback) return;
   if(CopyTime(_Symbol, _Period, 0, lookback, times_buffer) < lookback) return;

   // 4. Declare your output arrays (The storage for your swings)
   SwingPoint mySwingHighs[];
   SwingPoint mySwingLows[];

   FindSwings(buffer_highs, buffer_lows, times_buffer, lookback, swingStrength, mySwingHighs, mySwingLows);

   Print("Found ", ArraySize(mySwingHighs), " Swing Highs and ", ArraySize(mySwingLows), " Swing Lows.");
 // --- LOOP 1: Handle Highs (Supply) ---
for(int i = 0; i < ArraySize(mySwingHighs); i++) {
   int idx = mySwingHighs[i].index;
   Print("Swing High at index ", idx, " with price ", mySwingHighs[i].price);
   
   string name = "Supply_" + (string)idx;
   // Draw Supply: Top is the High, Bottom is the Low of that candle
   drawZone(name, mySwingHighs[i].time, mySwingHighs[i].price, TimeCurrent(), buffer_lows[idx]);
}

// --- LOOP 2: Handle Lows (Demand) ---
for(int i = 0; i < ArraySize(mySwingLows); i++) {
   int idx = mySwingLows[i].index;
   Print("Swing Low at index ", idx, " with price ", mySwingLows[i].price);
   
   string name = "Demand_" + (string)idx;
   // Draw Demand: Top is the High of that candle, Bottom is the Low
   drawZone(name, mySwingLows[i].time, buffer_highs[idx], TimeCurrent(), mySwingLows[i].price);
}
   
   //fvg check
   
 }
   