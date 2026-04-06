# MarketStructure_Zone v9

## Overview

**MarketStructure_ZoneBot v9** is an advanced Smart Money Concepts (SMC) / ICT-based market structure indicator for MetaTrader.

It automatically identifies:

* Order Blocks (Supply & Demand)
* Break of Structure (BOS)
* Fair Value Gaps (FVG)
* Market Trend (HH/HL & LL/LH logic)
* Zone invalidation in real time

This version is a **refined, production-ready evolution** combining robust structure logic with efficient execution and clean architecture.

---

## Core Concepts Implemented

### 1. Order Blocks (OB)

* **Bullish OB (Demand)** → last bearish candle before expansion up
* **Bearish OB (Supply)** → last bullish candle before expansion down

The bot tracks the **extreme candle**:

* Lowest bearish candle (for demand)
* Highest bullish candle (for supply)

---

### 2. Expansion Confirmation

A valid OB must be followed by **strong displacement**:

* Bullish:

  * Close > previous candle high
* Bearish:

  * Close < previous candle low

This ensures momentum exists after the OB.

---

### 3. Fair Value Gap (FVG)

The bot confirms imbalance using a 3-candle structure:

* **Bullish FVG**

  ```
  High (older) < Low (newer)
  ```

* **Bearish FVG**

  ```
  Low (older) > High (newer)
  ```

This validates institutional imbalance.

---

### 4. Break of Structure (BOS)

Structure is confirmed using swing points:

* **Bullish BOS**

  * New swing high > previous swing high + buffer

* **Bearish BOS**

  * New swing low < previous swing low - buffer

Buffer is controlled via:

```
input double BOS_Buffer_Points
```

---

### 5. Trend Logic (HH/HL Model)

Trend is determined using confirmed swing structure:

| Condition                | Trend     |
| ------------------------ | --------- |
| Higher High + Higher Low | UPTREND   |
| Lower Low + Lower High   | DOWNTREND |
| Mixed structure          | RANGING   |

This is more reliable than price-based trend detection.

---

### 6. Trend Filtering

Zones are filtered based on trend:

* Demand zones allowed in:

  * UPTREND
  * RANGING

* Supply zones allowed in:

  * DOWNTREND
  * RANGING

Controlled by:

```
input bool TrendFilterEnabled
```

---

## Execution Flow

### On Every Tick

```
InvalidateAndExtend()
```

* Removes broken zones instantly
* Extends valid zones forward

---

### On New Bar

1. Process Bullish Structure
2. Process Bearish Structure
3. Update Trend State
4. Display Debug Info

---

## Bullish Logic (Demand Zones)

### Step 1: Detect Pullback

* Identify bearish candles
* Track the lowest one as OB candidate

### Step 2: Confirm Zone

* Wait minimum 2 bars
* Require:

  * Bullish expansion
  * Bullish FVG

→ Zone becomes **locked**

### Step 3: Confirm BOS

* Detect swing high break

If valid:

* Apply wick expansion
* Save zone
* Draw rectangle

---

## Bearish Logic (Supply Zones)

Same as bullish, reversed:

* Track bullish candle (OB)
* Confirm with bearish expansion + FVG
* Confirm BOS via swing low break
* Save + draw zone

---

## Zone Invalidation (Real-Time)

Runs on every tick:

### Demand Zones

Invalidated when:

```
price < zone.low
```

### Supply Zones

Invalidated when:

```
price > zone.high
```

Invalid zones:

* Removed from chart
* Removed from memory

---

## Wick Expansion

Before saving zones:

* The bot checks the candle **before the OB**
* Expands zone if wick extends further

This improves accuracy of institutional levels.

---

## Data Structures

### PriceData

```
struct PriceData {
   double high;
   double low;
   double close;
   datetime time;
};
```

Used to store zones and OBs.

---

## Key Inputs

| Input              | Description                 |
| ------------------ | --------------------------- |
| BOS_Buffer_Points  | Minimum break distance      |
| MaxStoredSwings    | Max zones stored            |
| ExpansionLookback  | Bars to scan for expansion  |
| FVG_Lookback       | Bars to scan for imbalance  |
| TrendFilterEnabled | Enable/disable trend gating |

---

## Helper Systems

### AddZone()

* Adds zone with bounds checking
* Prevents overflow

### ArrayRemoveCustom()

* Safe array element removal

### ZeroMemory()

* Clears OB state safely

### isNewBar()

* Ensures logic runs once per candle

---

## Debug Panel

Displays:

* Trend state
* Swing levels
* OB tracking state
* Active zones
* Internal flags

Useful for:

* Testing
* Strategy validation
* Debugging

---

## What This Bot DOES NOT Do

This is **NOT a trading bot yet**.

Missing features:

* Trade execution (buy/sell)
* Stop loss / take profit
* Risk management
* Entry confirmation logic

It is currently:

> A high-quality **market structure & zone detection engine**

---

## Suggested Next Steps

To turn this into a full system:

1. Add entry logic:

   * Price returns to zone
   * Confirmation candle

2. Add risk management:

   * SL below/above zone
   * Fixed RR (e.g. 1:2)

3. Add multi-timeframe bias:

   * HTF trend filter

4. Add backtesting framework

---

## Version Highlights (v9)

* Restored HH/HL trend logic
* Tick-level zone invalidation
* Robust FVG detection
* Safer memory handling (ZeroMemory)
* Clean modular architecture
* Reliable object drawing lifecycle

---

## Summary

MarketStructure_ZoneBot v9 is a **robust SMC engine** that:

* Accurately tracks market structure
* Identifies high-probability zones
* Maintains real-time relevance via invalidation
* Provides a strong foundation for automation or signal generation

---

## License

Custom / Private Use (modify as needed)

---

## Author

Leon Kariu
