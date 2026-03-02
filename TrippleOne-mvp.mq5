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
   
  }
//+------------------------------------------------------------------+
//| Trade function                                                   |
//+------------------------------------------------------------------+
void OnTrade()
  {
//---
   
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
   for(int i = PositionTotal()-1; i>=0; i--){
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == magicNumber)
      return true;
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

void checkSwing() {

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

struct swingPoints {
   double   price;
   int      index;
   datetime    time;
};

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