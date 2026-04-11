//+------------------------------------------------------------------+
//| MarketStructure_ZoneBot v11                                      |
//| v10 base + refined entry: BUY_STOP/SELL_STOP on candle          |
//| high/low break AFTER price returns to zone                      |
//|                                                                  |
//| Entry sequence (long):                                           |
//|  1. Price retraces into confirmed demand zone                   |
//|  2. A candle closes INSIDE the zone (reaction candle)           |
//|  3. BUY_STOP pending placed 1 tick above reaction candle high   |
//|  4. SL = zone low - buffer                                      |
//|  5. TP = entry + 2% of balance in price                        |
//|  6. If price exits zone without triggering → cancel pending     |
//|                                                                  |
//| Entry sequence (short):                                          |
//|  1. Price retraces into confirmed supply zone                   |
//|  2. A candle closes INSIDE the zone (reaction candle)           |
//|  3. SELL_STOP pending placed 1 tick below reaction candle low   |
//|  4. SL = zone high + buffer                                     |
//|  5. TP = entry - 2% of balance in price                        |
//|  6. If price exits zone without triggering → cancel pending     |
//|                                                                  |
//| Trail: every 0.5% profit move → SL advances by 0.5%           |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "11.00"
#property strict

//==================== ENUMS ====================
enum TREND_STATE
{
   TREND_UP      =  1,
   TREND_DOWN    = -1,
   TREND_RANGING =  0
};

enum CandleType
{
   BULLISH,
   BEARISH,
   NEUTRAL
};

enum order_type
{
   BUY        = 0,
   SELL       = 1,
   BUY_LIMIT  = 2,
   SELL_LIMIT = 3,
   BUY_STOP   = 4,
   SELL_STOP  = 5
};

//==================== STRUCTS ====================
struct PriceData {
   double   high;
   double   low;
   double   close;
   datetime time;
};

struct TradeState {
   // --- Live position ---
   ulong    ticket;           // position ticket (filled)
   bool     isOpen;           // true when position is live

   // --- Pending order ---
   ulong    pendingTicket;    // pending BUY_STOP / SELL_STOP ticket
   bool     hasPending;       // true when a pending order is waiting
   datetime pendingZoneTime;  // timestamp of the zone that triggered the entry
   double   entryTrigger;     // trigger price of the pending order
   int      direction;        // 1 = buy, -1 = sell

   // --- Position details (populated on fill) ---
   double   entryPrice;
   double   initialSL;
   double   initialTP;
   double   accountAtEntry;
   double   riskAmount;
   int      trailStep;
};

//==================== GLOBALS ====================
const ulong MAGIC_EAID = 54546648863218348;

// --- Trend state ---
TREND_STATE currentTrend = TREND_RANGING;
double lastSwingHigh     = 0;
double lastSwingLow      = 0;
double prevSwingHigh     = 0;
double prevSwingLow      = 0;

// --- Bullish side ---
PriceData confirmedBullishZones[];
PriceData tempBearishOB;

bool isPullbackActive  = false;
bool bullishZoneLocked = false;
int  barsSinceBearOB   = 0;

// --- Bearish side ---
PriceData confirmedBearishZones[];
PriceData tempBullishOB;

bool isRallyActive     = false;
bool bearishZoneLocked = false;
int  barsSinceBullOB   = 0;

bool initialCandleIndex = true;

// --- Trade state ---
TradeState activeTrade;

// --- Shadow locals ---
int EffectiveExpansionLookback;
int EffectiveFVGLookback;

//==================== INPUTS ====================
input double BOS_Buffer_Points  = 20;
input int    MaxStoredSwings    = 50;
input int    ExpansionLookback  = 5;
input int    FVG_Lookback       = 5;
input bool   TrendFilterEnabled = true;
input int    PrevCandleIndex    = 1;

// --- Risk inputs ---
input double RiskPercent        = 1.0;   // Risk per trade as % of balance
input double RewardPercent      = 2.0;   // Take profit as % of balance
input double TrailStepPercent   = 0.5;   // Trail SL every X% of profit
input double MaxSpreadPoints    = 30;    // Skip entry if spread exceeds this

//+------------------------------------------------------------------+
int OnInit()
{
   if(MaxStoredSwings < 5)   { Print("ERROR: MaxStoredSwings must be >= 5");  return INIT_PARAMETERS_INCORRECT; }
   if(ExpansionLookback < 1) { Print("ERROR: ExpansionLookback must be >= 1"); return INIT_PARAMETERS_INCORRECT; }
   if(FVG_Lookback < 1)      { Print("ERROR: FVG_Lookback must be >= 1");      return INIT_PARAMETERS_INCORRECT; }
   if(BOS_Buffer_Points < 0) { Print("ERROR: BOS_Buffer_Points must be >= 0"); return INIT_PARAMETERS_INCORRECT; }
   if(RiskPercent <= 0)      { Print("ERROR: RiskPercent must be > 0");        return INIT_PARAMETERS_INCORRECT; }
   if(RewardPercent <= 0)    { Print("ERROR: RewardPercent must be > 0");      return INIT_PARAMETERS_INCORRECT; }

   EffectiveExpansionLookback = MathMin(ExpansionLookback, 50);
   EffectiveFVGLookback       = MathMin(FVG_Lookback, 50);

   ObjectsDeleteAll(0, "OB_Demand_");
   ObjectsDeleteAll(0, "OB_Supply_");
   ObjectsDeleteAll(0, "Panel_");

   ArrayResize(confirmedBullishZones, 0);
   ArrayResize(confirmedBearishZones, 0);

   ZeroMemory(activeTrade);
   activeTrade.isOpen = false;

   SeedInitialTrend(200);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, "OB_Demand_");
   ObjectsDeleteAll(0, "OB_Supply_");
   ObjectsDeleteAll(0, "Panel_");
   ObjectsDeleteAll(0, "Current_High");
   ObjectsDeleteAll(0, "Current_Low");
   ObjectsDeleteAll(0, "HH_H1_Current");
   ObjectsDeleteAll(0, "HH_H2_Previous");
   ObjectsDeleteAll(0, "LL_L1_Current");
   ObjectsDeleteAll(0, "LL_L2_Previous");
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   InvalidateAndExtend();
   CheckPendingFillOrCancel(); // monitor pending order every tick
   ManageOpenTrade();          // trail SL every tick

   if(!isNewBar()) return;
   ProcessBullishStructure();
   ProcessBearishStructure();
   UpdateTrendState();
   CheckTradeEntry();   // places pending on reaction candle close
   DebugInfo();
}

//+------------------------------------------------------------------+
//| TRADE ENTRY — pending order on reaction candle break            |
//|                                                                  |
//| Called on every new bar close.                                  |
//|                                                                  |
//| LONG sequence:                                                   |
//|  - Price must have closed inside a demand zone last bar         |
//|  - Place BUY_STOP 1 tick above that candle's high              |
//|  - SL at zone low - buffer                                      |
//|  - TP at entry + RewardPercent of balance in price              |
//|                                                                  |
//| SHORT sequence:                                                  |
//|  - Price must have closed inside a supply zone last bar         |
//|  - Place SELL_STOP 1 tick below that candle's low              |
//|  - SL at zone high + buffer                                     |
//|  - TP at entry - RewardPercent of balance in price              |
//+------------------------------------------------------------------+
void CheckTradeEntry()
{
   // Don't stack entries
   if(activeTrade.isOpen || activeTrade.hasPending) return;

   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spread = (ask - bid) / _Point;

   if(spread > MaxSpreadPoints)
   {
      Print("Entry skipped — spread too wide: ", spread, " points");
      return;
   }

   // Bar 1 = candle that just closed — use its high/low as trigger levels
   double prevHigh  = iHigh (_Symbol, _Period, 1);
   double prevLow   = iLow  (_Symbol, _Period, 1);
   double prevClose = iClose (_Symbol, _Period, 1);
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double buffer    = BOS_Buffer_Points * _Point;
   double oneTick   = _Point;

   // ----------------------------------------------------------------
   // LONG: reaction candle closed inside a demand zone
   // ----------------------------------------------------------------
   bool bullTrendOk = !TrendFilterEnabled ||
                      (currentTrend == TREND_UP || currentTrend == TREND_RANGING);

   if(bullTrendOk)
   {
      for(int i = ArraySize(confirmedBullishZones) - 1; i >= 0; i--)
      {
         double zoneHigh = confirmedBullishZones[i].high;
         double zoneLow  = confirmedBullishZones[i].low;

         // Reaction candle: bar 1 closed inside the zone
         if(prevClose >= zoneLow && prevClose <= zoneHigh)
         {
            // BUY_STOP 1 tick above the reaction candle high
            double entryPrice = NormalizeDouble(prevHigh + oneTick, _Digits);
            double sl         = NormalizeDouble(zoneLow - buffer, _Digits);
            double slDist     = entryPrice - sl;

            if(slDist <= 0) { Print("Long pending skipped — SL distance invalid"); break; }

            double lots = CalcLotSize(balance, RiskPercent, slDist);
            if(lots <= 0)   { Print("Long pending skipped — lot size zero"); break; }

            // TP based on reward % from expected entry
            double tp = NormalizeDouble(entryPrice + CalcPriceMove(balance, RewardPercent), _Digits);

            ulong ticket = PlaceOrder(_Symbol, lots, entryPrice, sl, tp, BUY_STOP);
            if(ticket > 0)
            {
               activeTrade.hasPending    = true;
               activeTrade.pendingTicket = ticket;
               activeTrade.pendingZoneTime = confirmedBullishZones[i].time;
               activeTrade.entryTrigger   = entryPrice;
               activeTrade.direction     = 1;
               activeTrade.initialSL     = sl;
               activeTrade.initialTP     = tp;
               activeTrade.accountAtEntry= balance;
               activeTrade.riskAmount    = balance * RiskPercent / 100.0;
               activeTrade.trailStep     = 0;

               Print("BUY_STOP placed | Trigger: ", entryPrice,
                     " | SL: ", sl, " | TP: ", tp,
                     " | Zone: ", zoneLow, "-", zoneHigh);
            }
            break; // one pending per bar
         }
      }
   }

   if(activeTrade.hasPending) return;

   // ----------------------------------------------------------------
   // SHORT: reaction candle closed inside a supply zone
   // ----------------------------------------------------------------
   bool bearTrendOk = !TrendFilterEnabled ||
                      (currentTrend == TREND_DOWN || currentTrend == TREND_RANGING);

   if(bearTrendOk)
   {
      for(int i = ArraySize(confirmedBearishZones) - 1; i >= 0; i--)
      {
         double zoneHigh = confirmedBearishZones[i].high;
         double zoneLow  = confirmedBearishZones[i].low;

         if(prevClose >= zoneLow && prevClose <= zoneHigh)
         {
            // SELL_STOP 1 tick below the reaction candle low
            double entryPrice = NormalizeDouble(prevLow - oneTick, _Digits);
            double sl         = NormalizeDouble(zoneHigh + buffer, _Digits);
            double slDist     = sl - entryPrice;

            if(slDist <= 0) { Print("Short pending skipped — SL distance invalid"); break; }

            double lots = CalcLotSize(balance, RiskPercent, slDist);
            if(lots <= 0)   { Print("Short pending skipped — lot size zero"); break; }

            double tp = NormalizeDouble(entryPrice - CalcPriceMove(balance, RewardPercent), _Digits);

            ulong ticket = PlaceOrder(_Symbol, lots, entryPrice, sl, tp, SELL_STOP);
            if(ticket > 0)
            {
               activeTrade.hasPending    = true;
               activeTrade.pendingTicket = ticket;
               activeTrade.pendingZoneTime = confirmedBearishZones[i].time;
               activeTrade.entryTrigger   = entryPrice;
               activeTrade.direction     = -1;
               activeTrade.initialSL     = sl;
               activeTrade.initialTP     = tp;
               activeTrade.accountAtEntry= balance;
               activeTrade.riskAmount    = balance * RiskPercent / 100.0;
               activeTrade.trailStep     = 0;

               Print("SELL_STOP placed | Trigger: ", entryPrice,
                     " | SL: ", sl, " | TP: ", tp,
                     " | Zone: ", zoneLow, "-", zoneHigh);
            }
            break;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| PENDING ORDER MONITOR — runs every tick                         |
//|                                                                  |
//| Three outcomes:                                                  |
//|  A) Pending filled → promote to live position tracking         |
//|  B) Price exits zone before fill → cancel pending               |
//|  C) Zone invalidated (removed from array) → cancel pending      |
//+------------------------------------------------------------------+
void CheckPendingFillOrCancel()
{
   if(!activeTrade.hasPending) return;

   ulong pendingTicket = activeTrade.pendingTicket;

   // --- Check if the pending became a live position ---
   if(PositionSelectByTicket(pendingTicket))
   {
      // Filled — promote to live trade
      activeTrade.isOpen        = true;
      activeTrade.hasPending    = false;
      activeTrade.ticket        = pendingTicket;
      activeTrade.entryPrice    = PositionGetDouble(POSITION_PRICE_OPEN);

      Print("Pending filled → Live position | Ticket: ", pendingTicket,
            " | Entry: ", activeTrade.entryPrice);
      return;
   }

   // --- Pending still waiting — check if zone is still valid ---
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(activeTrade.direction == 1)
   {
      // Long pending — find the zone by time
      bool zoneFound = false;
      for(int j = 0; j < ArraySize(confirmedBullishZones); j++)
      {
         if(confirmedBullishZones[j].time == activeTrade.pendingZoneTime)
         {
            zoneFound = true;
            double zoneLow  = confirmedBullishZones[j].low;
            double zoneHigh = confirmedBullishZones[j].high;
            if(bid < zoneLow || bid > zoneHigh)
            {
               CancelPendingOrder(pendingTicket);
               Print("BUY_STOP cancelled — price exited demand zone");
               ZeroMemory(activeTrade);
            }
            break;
         }
      }
      if(!zoneFound)
      {
         CancelPendingOrder(pendingTicket);
         Print("BUY_STOP cancelled — demand zone invalidated");
         ZeroMemory(activeTrade);
      }
   }
   else
   {
      // Short pending — find the zone by time
      bool zoneFound = false;
      for(int j = 0; j < ArraySize(confirmedBearishZones); j++)
      {
         if(confirmedBearishZones[j].time == activeTrade.pendingZoneTime)
         {
            zoneFound = true;
            double zoneLow  = confirmedBearishZones[j].low;
            double zoneHigh = confirmedBearishZones[j].high;
            if(bid > zoneHigh || bid < zoneLow)
            {
               CancelPendingOrder(pendingTicket);
               Print("SELL_STOP cancelled — price exited supply zone");
               ZeroMemory(activeTrade);
            }
            break;
         }
      }
      if(!zoneFound)
      {
         CancelPendingOrder(pendingTicket);
         Print("SELL_STOP cancelled — supply zone invalidated");
         ZeroMemory(activeTrade);
      }
   }
}

//+------------------------------------------------------------------+
//| Cancel a pending order by ticket                                 |
//+------------------------------------------------------------------+
void CancelPendingOrder(ulong ticket)
{
   MqlTradeRequest request; ZeroMemory(request);
   MqlTradeResult  result;  ZeroMemory(result);

   request.action = TRADE_ACTION_REMOVE;
   request.order  = ticket;

   if(!OrderSend(request, result))
      Print("CancelPendingOrder failed: ", GetLastError(),
            " retcode: ", result.retcode);
   else
      Print("Pending order cancelled: ", ticket);
}

//+------------------------------------------------------------------+
//| TRADE MANAGEMENT — trailing stop (runs every tick)              |
//+------------------------------------------------------------------+
void ManageOpenTrade()
{
   if(!activeTrade.isOpen) return;

   if(!PositionSelectByTicket(activeTrade.ticket))
   {
      Print("Position ", activeTrade.ticket, " closed. Resetting trade state.");
      ZeroMemory(activeTrade);
      return;
   }

   double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double balance   = activeTrade.accountAtEntry;
   double stepPrice = CalcPriceMove(balance, TrailStepPercent);

   double priceProfitFromEntry = (activeTrade.direction == 1)
                                 ? bid - activeTrade.entryPrice
                                 : activeTrade.entryPrice - ask;

   int stepsInProfit = (int)MathFloor(priceProfitFromEntry / stepPrice);
   if(stepsInProfit <= activeTrade.trailStep) return;

   int    slSteps = stepsInProfit - 1;
   double newSL;

   if(activeTrade.direction == 1)
      newSL = activeTrade.entryPrice + (slSteps * stepPrice);
   else
      newSL = activeTrade.entryPrice - (slSteps * stepPrice);

   newSL = NormalizeDouble(newSL, _Digits);

   double currentSL = PositionGetDouble(POSITION_SL);
   if(activeTrade.direction ==  1 && newSL <= currentSL) return;
   if(activeTrade.direction == -1 && newSL >= currentSL) return;

   double currentTP = PositionGetDouble(POSITION_TP);
   ModifyPosition(activeTrade.ticket, newSL, currentTP);

   activeTrade.trailStep = stepsInProfit;
   Print("Trail SL → Step ", stepsInProfit, " | SL: ", newSL,
         " | Entry: ", activeTrade.entryPrice);
}

//+------------------------------------------------------------------+
//| CalcLotSize                                                      |
//| Converts a risk% of balance + SL distance into a lot size       |
//+------------------------------------------------------------------+
double CalcLotSize(double balance, double riskPct, double slDistancePrice)
{
   if(slDistancePrice <= 0) return 0;

   double riskAmount    = balance * riskPct / 100.0;
   double tickValue     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotMin        = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotMax        = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(tickValue <= 0 || tickSize <= 0) return 0;

   // Value per lot per unit price move
   double valuePerLot = (slDistancePrice / tickSize) * tickValue;
   if(valuePerLot <= 0) return 0;

   double lots = riskAmount / valuePerLot;

   // Snap to broker lot step
   lots = MathFloor(lots / lotStep) * lotStep;
   // Don't force lotMin — return 0 and skip the trade instead
if(lots < lotMin)
{
   Print("CalcLotSize: calculated lots ", lots, " below lotMin ", lotMin, " — skipping");
   return 0;
}
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| CalcPriceMove                                                    |
//| Converts a % of balance into a price distance for this symbol   |
//+------------------------------------------------------------------+

double CalcPriceMove(double balance, double pct)
{
   double targetAmount = balance * pct / 100.0;
   double tickValue    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0) return 0;

   // Value per pip per 1.0 lot — the standard reference unit
   double valuePerPipPerLot = tickValue / tickSize;
   // lots we'd trade at 1% risk with a 1-pip SL — gives us a per-pip value
   // Simpler: price move = targetAmount / (tickValue / tickSize)
   double priceMove = (targetAmount * tickSize) / tickValue;

   return NormalizeDouble(priceMove, _Digits);
}


//+------------------------------------------------------------------+
//| BULLISH STRUCTURE                                                |
//+------------------------------------------------------------------+
void ProcessBullishStructure()
{
   if(isPullbackActive) barsSinceBearOB++;

   double open1  = iOpen (_Symbol, _Period, 1);
   double close1 = iClose(_Symbol, _Period, 1);
   double high1  = iHigh (_Symbol, _Period, 1);
   double low1   = iLow  (_Symbol, _Period, 1);

   if(!bullishZoneLocked && close1 < open1)
   {
      if(!isPullbackActive || low1 < tempBearishOB.low)
      {
         tempBearishOB.high  = high1;
         tempBearishOB.low   = low1;
         tempBearishOB.close = close1;
         tempBearishOB.time  = iTime(_Symbol, _Period, 1);
         isPullbackActive    = true;
         barsSinceBearOB     = 0;
      }
   }

   if(isPullbackActive && !bullishZoneLocked && barsSinceBearOB >= 2)
   {
      if(IsBullishExpansionAfterOB(EffectiveExpansionLookback, tempBearishOB.time) &&
         HasBullishFVGAfterOB(EffectiveFVGLookback, tempBearishOB.time))
      {
         bullishZoneLocked = true;
         Print("Demand Zone Locked | Low: ", tempBearishOB.low, " | Trend: ", TrendLabel());
      }
   }

   double highClosed = iHigh(_Symbol, _Period, PrevCandleIndex);
   double buffer     = BOS_Buffer_Points * _Point;

   if(lastSwingHigh == 0) { lastSwingHigh = highClosed; return; }

   if(IsSwingHigh() && highClosed > lastSwingHigh + buffer)
   {
      prevSwingHigh = lastSwingHigh;
      lastSwingHigh = highClosed;

      if(initialCandleIndex)
      {
         ObjectsDeleteAll(0, "HH_H1_Current");
         ObjectsDeleteAll(0, "HH_H2_Previous");
         initialCandleIndex = false;
      }
      ObjectsDeleteAll(0, "Current_High");
      DrawStructureLine("Current_High", lastSwingHigh, clrSkyBlue);
      ObjectsDeleteAll(0, "Current_Low");
      DrawStructureLine("Current_Low", lastSwingLow, clrPink);

      bool trendAllows = !TrendFilterEnabled ||
                         (currentTrend == TREND_UP || currentTrend == TREND_RANGING);

      if(bullishZoneLocked && tempBearishOB.low > 0 && trendAllows)
      {
         int obIdx = iBarShift(_Symbol, _Period, tempBearishOB.time);
         if(obIdx > 0 && iLow(_Symbol, _Period, obIdx + 1) < tempBearishOB.low)
            tempBearishOB.low = iLow(_Symbol, _Period, obIdx + 1);

         AddZone(confirmedBullishZones, tempBearishOB);
         DrawZone(tempBearishOB, "OB_Demand_", clrDodgerBlue);
         Print("Bullish BOS → Demand Zone: ", tempBearishOB.low, " | Trend: ", TrendLabel());
      }
      else if(bullishZoneLocked && !trendAllows)
         Print("Demand zone suppressed (", TrendLabel(), ")");
      else if(isPullbackActive)
         Print("Bullish BOS — no locked zone, OB discarded: ", tempBearishOB.low);

      ResetBullishState();
   }
}

//+------------------------------------------------------------------+
//| BEARISH STRUCTURE                                                |
//+------------------------------------------------------------------+
void ProcessBearishStructure()
{
   if(isRallyActive) barsSinceBullOB++;

   double open1  = iOpen (_Symbol, _Period, 1);
   double close1 = iClose(_Symbol, _Period, 1);
   double high1  = iHigh (_Symbol, _Period, 1);
   double low1   = iLow  (_Symbol, _Period, 1);

   if(!bearishZoneLocked && close1 > open1)
   {
      if(!isRallyActive || high1 > tempBullishOB.high)
      {
         tempBullishOB.high  = high1;
         tempBullishOB.low   = low1;
         tempBullishOB.close = close1;
         tempBullishOB.time  = iTime(_Symbol, _Period, 1);
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
         Print("Supply Zone Locked | High: ", tempBullishOB.high, " | Trend: ", TrendLabel());
      }
   }

   double lowClosed = iLow(_Symbol, _Period, 2);
   double buffer    = BOS_Buffer_Points * _Point;

   if(lastSwingLow == 0) { lastSwingLow = lowClosed; return; }

   if(IsSwingLow() && lowClosed < lastSwingLow - buffer)
   {
      prevSwingLow = lastSwingLow;
      lastSwingLow = lowClosed;

      if(initialCandleIndex)
      {
         ObjectsDeleteAll(0, "LL_L1_Current");
         ObjectsDeleteAll(0, "LL_L2_Previous");
         initialCandleIndex = false;
      }
      ObjectsDeleteAll(0, "Current_Low");
      DrawStructureLine("Current_Low", lastSwingLow, clrPink);

      bool trendAllows = !TrendFilterEnabled ||
                         (currentTrend == TREND_DOWN || currentTrend == TREND_RANGING);

      if(bearishZoneLocked && tempBullishOB.high > 0 && trendAllows)
      {
         int obIdx = iBarShift(_Symbol, _Period, tempBullishOB.time);
         if(obIdx > 0 && iHigh(_Symbol, _Period, obIdx + 1) > tempBullishOB.high)
            tempBullishOB.high = iHigh(_Symbol, _Period, obIdx + 1);

         AddZone(confirmedBearishZones, tempBullishOB);
         DrawZone(tempBullishOB, "OB_Supply_", clrTomato);
         Print("Bearish BOS → Supply Zone: ", tempBullishOB.high, " | Trend: ", TrendLabel());
      }
      else if(bearishZoneLocked && !trendAllows)
         Print("Supply zone suppressed (", TrendLabel(), ")");
      else if(isRallyActive)
         Print("Bearish BOS — no locked zone, OB discarded: ", tempBullishOB.high);

      ResetBearishState();
   }
}

//+------------------------------------------------------------------+
//| TREND STATE                                                      |
//+------------------------------------------------------------------+
void UpdateTrendState()
{
   if(prevSwingHigh == 0 || prevSwingLow == 0)
   {
      currentTrend = TREND_RANGING;
      return;
   }

   bool higherHigh = lastSwingHigh > prevSwingHigh;
   bool higherLow  = lastSwingLow  > prevSwingLow;
   bool lowerLow   = lastSwingLow  < prevSwingLow;
   bool lowerHigh  = lastSwingHigh < prevSwingHigh;

   DrawStructureLine("HH_H1_Current",  lastSwingHigh, clrSkyBlue);
   DrawStructureLine("HH_H2_Previous", prevSwingHigh, clrRoyalBlue);
   DrawStructureLine("LL_L1_Current",  lastSwingLow,  clrPink);
   DrawStructureLine("LL_L2_Previous", prevSwingLow,  clrCrimson);

   TREND_STATE prev = currentTrend;

   if(higherHigh && higherLow)        currentTrend = TREND_UP;
   else if(lowerLow && lowerHigh)     currentTrend = TREND_DOWN;
   else                               currentTrend = TREND_RANGING;

   if(currentTrend != prev)
      Print("STRUCTURAL SHIFT → ", TrendLabel(),
            " | SH:", DoubleToString(lastSwingHigh, _Digits),
            " SL:", DoubleToString(lastSwingLow, _Digits));
}

//+------------------------------------------------------------------+
//| ZONE INVALIDATION + EXTENSION (every tick)                      |
//+------------------------------------------------------------------+
void InvalidateAndExtend()
{
   datetime newRight = TimeCurrent() + 172800;
   double   bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i = ArraySize(confirmedBullishZones) - 1; i >= 0; i--)
   {
      string name = "OB_Demand_" + IntegerToString((int)confirmedBullishZones[i].time);
      if(bid < confirmedBullishZones[i].low)
      {
         Print("Demand Zone invalidated: ", confirmedBullishZones[i].low);
         ObjectDelete(0, name);
         ArrayRemoveCustom(confirmedBullishZones, i);
         continue;
      }
      ObjectMove(0, name, 1, newRight, confirmedBullishZones[i].low);
   }

   for(int i = ArraySize(confirmedBearishZones) - 1; i >= 0; i--)
   {
      string name = "OB_Supply_" + IntegerToString((int)confirmedBearishZones[i].time);
      if(bid > confirmedBearishZones[i].high)
      {
         double invalidatedHigh = confirmedBearishZones[i].high;
         Print("Supply Zone invalidated: ", invalidatedHigh);
         ObjectDelete(0, name);
         ArrayRemoveCustom(confirmedBearishZones, i);
         continue;
      }
      ObjectMove(0, name, 1, newRight, confirmedBearishZones[i].low);
   }
}

//+------------------------------------------------------------------+
//| SEED INITIAL TREND                                               |
//+------------------------------------------------------------------+
void SeedInitialTrend(int lookback = 200)
{
   Print("Scanning history for initial trend context...");
   double h1=0, h2=0, l1=0, l2=0;
   int foundHighs=0, foundLows=0;

   for(int i = 5; i < lookback - 1 && (foundHighs < 2 || foundLows < 2); i++)
   {
      bool shLeft  = iClose(_Symbol,_Period,i+1) < iClose(_Symbol,_Period,i+2) &&
                     iClose(_Symbol,_Period,i+2) < iClose(_Symbol,_Period,i+3) &&
                     iClose(_Symbol,_Period,i+3) < iClose(_Symbol,_Period,i+4);
      bool shRight = iHigh(_Symbol,_Period,i) > iHigh(_Symbol,_Period,i+1);

      if(shLeft && shRight)
      {
         double pivotHigh = iHigh(_Symbol,_Period,i);
         if(foundHighs == 0)                           { h1 = pivotHigh; foundHighs++; }
         else if(foundHighs == 1 && pivotHigh != h1)  { h2 = pivotHigh; foundHighs++; }
      }

      bool slLeft  = iClose(_Symbol,_Period,i+1) > iClose(_Symbol,_Period,i+2) &&
                     iClose(_Symbol,_Period,i+2) > iClose(_Symbol,_Period,i+3) &&
                     iClose(_Symbol,_Period,i+3) > iClose(_Symbol,_Period,i+4);
      bool slRight = iLow(_Symbol,_Period,i) < iLow(_Symbol,_Period,i+1);

      if(slLeft && slRight)
      {
         double pivotLow = iLow(_Symbol,_Period,i);
         if(foundLows == 0)                          { l1 = pivotLow; foundLows++; }
         else if(foundLows == 1 && pivotLow != l1)  { l2 = pivotLow; foundLows++; }
      }
   }

   lastSwingHigh = h1; prevSwingHigh = h2;
   lastSwingLow  = l1; prevSwingLow  = l2;

   DrawStructureLine("HH_H1_Current",  h1, clrSkyBlue);
   DrawStructureLine("HH_H2_Previous", h2, clrRoyalBlue);
   DrawStructureLine("LL_L1_Current",  l1, clrPink);
   DrawStructureLine("LL_L2_Previous", l2, clrCrimson);

   if(h1 > h2 && l1 > l2)      currentTrend = TREND_UP;
   else if(l1 < l2 && h1 < h2) currentTrend = TREND_DOWN;
   else                         currentTrend = TREND_RANGING;

   Print("Initial Trend: ", TrendLabel(), " H1:", h1, " H2:", h2, " L1:", l1, " L2:", l2);
}

//+------------------------------------------------------------------+
//| EXPANSION / FVG FUNCTIONS                                        |
//+------------------------------------------------------------------+
bool IsBullishExpansionAfterOB(int lookback, datetime obTime)
{
   if(iBars(_Symbol,_Period) < lookback + 2) return false;
   int obIdx = iBarShift(_Symbol,_Period,obTime);
   if(obIdx < 0) return false;
   for(int i = obIdx-1; i >= 1 && i >= obIdx-lookback; i--)
      if(iClose(_Symbol,_Period,i) > iOpen(_Symbol,_Period,i) &&
         iClose(_Symbol,_Period,i) > iHigh(_Symbol,_Period,i+1)) return true;
   return false;
}

bool IsBearishExpansionAfterOB(int lookback, datetime obTime)
{
   if(iBars(_Symbol,_Period) < lookback + 2) return false;
   int obIdx = iBarShift(_Symbol,_Period,obTime);
   if(obIdx < 0) return false;
   for(int i = obIdx-1; i >= 1 && i >= obIdx-lookback; i--)
      if(iClose(_Symbol,_Period,i) < iOpen(_Symbol,_Period,i) &&
         iClose(_Symbol,_Period,i) < iLow(_Symbol,_Period,i+1)) return true;
   return false;
}

bool HasBullishFVGAfterOB(int lookback, datetime obTime)
{
   int totalBars = iBars(_Symbol,_Period);
   int obIdx = iBarShift(_Symbol,_Period,obTime);
   if(obIdx < 0 || obIdx+2 >= totalBars) return false;
   for(int i = obIdx-1; i >= 1 && i >= obIdx-lookback; i--)
   {
      if(i+2 >= totalBars) break;
      if(iHigh(_Symbol,_Period,i+2) < iLow(_Symbol,_Period,i)) return true;
   }
   return false;
}

bool HasBearishFVGAfterOB(int lookback, datetime obTime)
{
   int totalBars = iBars(_Symbol,_Period);
   int obIdx = iBarShift(_Symbol,_Period,obTime);
   if(obIdx < 0 || obIdx+2 >= totalBars) return false;
   for(int i = obIdx-1; i >= 1 && i >= obIdx-lookback; i--)
   {
      if(i+2 >= totalBars) break;
      if(iLow(_Symbol,_Period,i+2) > iHigh(_Symbol,_Period,i)) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| SWING HIGH / LOW                                                 |
//+------------------------------------------------------------------+
CandleType GetCandleType(uint i)
{
   double o = iOpen(_Symbol,_Period,i), c = iClose(_Symbol,_Period,i);
   if(c > o) return BULLISH;
   if(c < o) return BEARISH;
   return NEUTRAL;
}

bool IsSwingHigh()
{
   double pivot = iHigh(_Symbol,_Period,1);
   bool leftSide  = (GetCandleType(2)==BULLISH||GetCandleType(2)==NEUTRAL) &&
                    (GetCandleType(3)==BULLISH||GetCandleType(3)==NEUTRAL) &&
                    (GetCandleType(4)==BULLISH||GetCandleType(4)==NEUTRAL);
   bool rightSide = pivot > iHigh(_Symbol,_Period,2);
   bool isNewHigh = iClose(_Symbol,_Period,1) > lastSwingHigh;
   if(leftSide && rightSide)
   {
      lastSwingHigh = iClose(_Symbol,_Period,1);
      return true;
   }
   return false;
}

bool IsSwingLow()
{
   double pivot = iLow(_Symbol,_Period,1);
   bool leftSide  = (GetCandleType(2)==BEARISH||GetCandleType(2)==NEUTRAL) &&
                    (GetCandleType(3)==BEARISH||GetCandleType(3)==NEUTRAL) &&
                    (GetCandleType(4)==BEARISH||GetCandleType(4)==NEUTRAL);
   bool rightSide = pivot < iLow(_Symbol,_Period,2);
   bool isNewLow  = iClose(_Symbol,_Period,1) < lastSwingLow;
   if(leftSide && rightSide)
   {
      lastSwingLow = iClose(_Symbol,_Period,1);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| ZONE / ARRAY HELPERS                                             |
//+------------------------------------------------------------------+
void AddZone(PriceData &arr[], PriceData &val)
{
   int s = ArraySize(arr);
   if(s >= MaxStoredSwings) { ArrayRemoveCustom(arr,0); s = ArraySize(arr); }
   ArrayResize(arr, s+1);
   arr[s] = val;
}

template<typename T>
void ArrayRemoveCustom(T &arr[], int index)
{
   int s = ArraySize(arr);
   for(int i = index; i < s-1; i++) arr[i] = arr[i+1];
   ArrayResize(arr, s-1);
}

void DrawZone(PriceData &data, string prefix, color zoneColor)
{
   string name = prefix + IntegerToString((int)data.time);
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0,
      data.time, data.high, TimeCurrent()+172800, data.low);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      zoneColor);
   ObjectSetInteger(0, name, OBJPROP_FILL,       true);
   ObjectSetInteger(0, name, OBJPROP_BACK,       true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void DrawStructureLine(string name, double price, color clr, int style=STYLE_DOT)
{
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_BACK,  true);
   ObjectSetString (0, name, OBJPROP_TEXT,  name);
}

void ResetBullishState() { isPullbackActive=false; bullishZoneLocked=false; barsSinceBearOB=0; ZeroMemory(tempBearishOB); }
void ResetBearishState() { isRallyActive=false; bearishZoneLocked=false; barsSinceBullOB=0; ZeroMemory(tempBullishOB); }

string TrendLabel()
{
   switch(currentTrend)
   {
      case TREND_UP:   return "UPTREND";
      case TREND_DOWN: return "DOWNTREND";
      default:         return "RANGING";
   }
}

bool isNewBar()
{
   static datetime last_time = 0;
   datetime current = (datetime)SeriesInfoInteger(_Symbol,_Period,SERIES_LASTBAR_DATE);
   if(last_time == 0)       { last_time = current; return false; }
   if(last_time != current) { last_time = current; return true;  }
   return false;
}

//+------------------------------------------------------------------+
//| ORDER FUNCTIONS                                                  |
//+------------------------------------------------------------------+
ulong PlaceOrder(string symbol, double volume, double price, double sl, double tp, order_type type)
{
   MqlTradeRequest request; ZeroMemory(request);
   MqlTradeResult  result;  ZeroMemory(result);

   request.symbol        = symbol;
   request.volume        = volume;
   request.price         = NormalizeDouble(price, _Digits);
   request.sl            = NormalizeDouble(sl, _Digits);
   request.tp            = NormalizeDouble(tp, _Digits);
   request.deviation     = 10;
   request.magic         = MAGIC_EAID;
   request.comment       = "ZoneBot_v10";

   switch(type)
   {
      case BUY:        request.type=ORDER_TYPE_BUY;        request.action=TRADE_ACTION_DEAL;    request.type_filling = ORDER_FILLING_FOK; break;
      case SELL:       request.type=ORDER_TYPE_SELL;       request.action=TRADE_ACTION_DEAL;    request.type_filling = ORDER_FILLING_FOK; break;
      case BUY_LIMIT:  request.type=ORDER_TYPE_BUY_LIMIT;  request.action=TRADE_ACTION_PENDING; request.type_filling = ORDER_FILLING_RETURN; break;
      case SELL_LIMIT: request.type=ORDER_TYPE_SELL_LIMIT; request.action=TRADE_ACTION_PENDING; request.type_filling = ORDER_FILLING_RETURN; break;
      case BUY_STOP:   request.type=ORDER_TYPE_BUY_STOP;   request.action=TRADE_ACTION_PENDING; request.type_filling = ORDER_FILLING_RETURN; break;
      case SELL_STOP:  request.type=ORDER_TYPE_SELL_STOP;  request.action=TRADE_ACTION_PENDING; request.type_filling = ORDER_FILLING_RETURN; break;
      default: Print("PlaceOrder: invalid type"); return 0;
   }

   if(!OrderSend(request, result))
   {
      Print("PlaceOrder failed: ", GetLastError(), " retcode: ", result.retcode);
      return 0;
   }
   Print("Order placed: ticket=", result.order, " type=", type, " price=", price);
   return result.order;
}

void ModifyPosition(ulong ticket, double newSL, double newTP)
{
   MqlTradeRequest request; ZeroMemory(request);
   MqlTradeResult  result;  ZeroMemory(result);

   request.action   = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.sl       = NormalizeDouble(newSL, _Digits);
   request.tp       = NormalizeDouble(newTP, _Digits);
   request.magic    = MAGIC_EAID;

   if(!OrderSend(request, result))
      Print("ModifyPosition failed: ", GetLastError(), " retcode: ", result.retcode);
}

void ClosePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;

   MqlTradeRequest request; ZeroMemory(request);
   MqlTradeResult  result;  ZeroMemory(result);

   request.action   = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol   = PositionGetString(POSITION_SYMBOL);
   request.volume   = PositionGetDouble(POSITION_VOLUME);
   request.deviation= 10;
   request.magic    = MAGIC_EAID;
   request.type     = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
                      ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price    = (request.type == ORDER_TYPE_SELL)
                      ? SymbolInfoDouble(request.symbol, SYMBOL_BID)
                      : SymbolInfoDouble(request.symbol, SYMBOL_ASK);
   request.type_filling = ORDER_FILLING_FOK;

   if(!OrderSend(request, result))
      Print("ClosePosition failed: ", GetLastError(), " retcode: ", result.retcode);
   else
      Print("Position closed: ticket=", ticket);
}

//+------------------------------------------------------------------+
//| DEBUG INFO                                                       |
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

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double openPnL = equity - balance;

   string tradeInfo;
   if(activeTrade.isOpen)
      tradeInfo = StringFormat("LIVE | %s | Ticket:%d | Entry:%.5f | SL:%.5f | Trail:%d",
         activeTrade.direction == 1 ? "BUY" : "SELL",
         activeTrade.ticket,
         activeTrade.entryPrice,
         activeTrade.initialSL,
         activeTrade.trailStep);
   else if(activeTrade.hasPending)
      tradeInfo = StringFormat("PENDING | %s_STOP | Ticket:%d | Trigger:%.5f | SL:%.5f",
         activeTrade.direction == 1 ? "BUY" : "SELL",
         activeTrade.pendingTicket,
         activeTrade.entryTrigger,
         activeTrade.initialSL);
   else
      tradeInfo = "No trade / No pending";

   string output =
      "=== MARKET STRUCTURE v11 ===\n"                                             +
      "Time             : " + TimeToString(TimeCurrent(), TIME_SECONDS)            + "\n" +
      "Balance          : " + DoubleToString(balance, 2)                           + "\n" +
      "Open P&L         : " + DoubleToString(openPnL, 2)                           + "\n" +
      "Trend            : " + trendLine                                            + "\n" +
      "Filter Active    : " + (TrendFilterEnabled ? "YES" : "NO")                 + "\n" +
      "Prev Swing High  : " + DoubleToString(prevSwingHigh, _Digits)              + "\n" +
      "Last Swing High  : " + DoubleToString(lastSwingHigh, _Digits)              + "\n" +
      "Prev Swing Low   : " + DoubleToString(prevSwingLow,  _Digits)              + "\n" +
      "Last Swing Low   : " + DoubleToString(lastSwingLow,  _Digits)              + "\n" +
      "---\n"                                                                       +
      "BULLISH (Demand)\n"                                                          +
      " Pullback Active : " + (isPullbackActive  ? "YES" : "NO")                  + "\n" +
      " Zone Locked     : " + (bullishZoneLocked ? "YES" : "NO")                  + "\n" +
      " Bars Since OB   : " + IntegerToString(barsSinceBearOB)                    + "\n" +
      " OB Low          : " + DoubleToString(tempBearishOB.low, _Digits)          + "\n" +
      " Active Zones    : " + IntegerToString(ArraySize(confirmedBullishZones))   + "\n" +
      "---\n"                                                                       +
      "BEARISH (Supply)\n"                                                          +
      " Rally Active    : " + (isRallyActive     ? "YES" : "NO")                  + "\n" +
      " Zone Locked     : " + (bearishZoneLocked ? "YES" : "NO")                  + "\n" +
      " Bars Since OB   : " + IntegerToString(barsSinceBullOB)                    + "\n" +
      " OB High         : " + DoubleToString(tempBullishOB.high, _Digits)         + "\n" +
      " Active Zones    : " + IntegerToString(ArraySize(confirmedBearishZones))   + "\n" +
      "---\n"                                                                       +
      "TRADE\n"                                                                     +
      " " + tradeInfo;

   Comment(output);
}
//+------------------------------------------------------------------+llll



//todo -- redo the whole ea from scratch starting with just strucure detection and zone drawing  --- when thoat works, the add simple trade management and execution not using any AI Models,