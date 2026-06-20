//+------------------------------------------------------------------+
//|                                    HFT_Ultimate_Grid_Bot_MT5.mq5 |
//|                                  Copyright 2026, Arena.ai Agent  |
//|                                             https://arena.ai     |
//+------------------------------------------------------------------+
#property copyright "Arena.ai Agent"
#property link      "https://arena.ai"
#property version   "8.10"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Distance Measurement Mode
enum ENUM_DIST_MODE {
    MODE_ABSOLUTE_PRICE,  // Absolute Price Units (e.g. 1.35 & 0.30 for XAUUSD / Indices / Crypto)
    MODE_STANDARD_PIPS,   // Standard Forex Pips (e.g. 1.35 & 0.30 for EURUSD / GBPUSD)
    MODE_BROKER_POINTS    // Raw Broker Points (e.g. 135 points)
};

//--- Inputs
input group "--- Grid Spacing & Deployment Settings ---"
input ENUM_DIST_MODE InpDistanceMode   = MODE_ABSOLUTE_PRICE; // Distance Measurement Mode
input double         InpInitialGap     = 1.35;      // Initial Breakout Straddle Gap from Live Price (1.35)
input double         InpStepGap        = 0.30;      // Step Gap between next 10 orders (0.30)
input int            InpGridLevels     = 11;        // Total Orders per side (1 Initial + 10 Steps = 11)
input double         InpLots           = 0.01;      // Lot Size per order
input ulong          InpMagicNumber    = 101010;    // EA Magic Number

input group "--- Pure Live Market Exit: Net Cash PnL Target ---"
input bool           InpUseBasketPnL     = true;    // Enable Combined Cash Basket Exit (TRUE)
input double         InpBasketTakeProfit = 10.0;    // Net Cash Take Profit Target ($ / Account Currency)
input double         InpBasketStopLoss   = 50.0;    // Net Emergency Hard Stop Loss ($ / Account Currency)

//--- Global Tracking Variables
double   g_pipSize;

//+------------------------------------------------------------------+
//| Initialization Function                                          |
//+------------------------------------------------------------------+
int OnInit() {
    trade.SetExpertMagicNumber(InpMagicNumber);
    if(_Digits == 5 || _Digits == 3)
        g_pipSize = _Point * 10.0;
    else
        g_pipSize = _Point;
        
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Calculate Absolute Price Gap based on Mode                       |
//+------------------------------------------------------------------+
double GetAbsoluteGap(double val) {
    if(InpDistanceMode == MODE_ABSOLUTE_PRICE) {
        return val; // Directly uses 1.35 and 0.30
    }
    else if(InpDistanceMode == MODE_STANDARD_PIPS) {
        if(_Digits == 5 || _Digits == 3) return val * 10.0 * _Point;
        return val * _Point;
    }
    else if(InpDistanceMode == MODE_BROKER_POINTS) {
        return val * _Point;
    }
    return val;
}

//+------------------------------------------------------------------+
//| Main Tick Function                                               |
//+------------------------------------------------------------------+
void OnTick() {
    // 1. Scan active market positions and pending orders
    int positionsCount = 0;
    double netFloatingPnL = 0.0;
    
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong posTicket = PositionGetTicket(i);
        if(posTicket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
            positionsCount++;
            netFloatingPnL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        }
    }
    
    int pendingOrdersCount = 0;
    for(int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong orderTicket = OrderGetTicket(i);
        if(orderTicket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber) {
            pendingOrdersCount++;
        }
    }
    
    // 2. Deployment: If completely flat (0 active trades and 0 pending orders), deploy brand fresh validated grid
    if(positionsCount == 0 && pendingOrdersCount == 0) {
        PlaceGrid();
        return;
    }
    
    // 3. Evaluate Pure Cash PnL Exits (When actively holding market positions)
    if(positionsCount > 0) {
        if(InpUseBasketPnL) {
            // Take Profit
            if(InpBasketTakeProfit > 0 && netFloatingPnL >= InpBasketTakeProfit) {
                PrintFormat("🏆 Fixed Profit Target hit! Net Cash PnL: +$%.2f across %d active positions. Flattening basket.", netFloatingPnL, positionsCount);
                CloseAllAndCleanUp();
                return;
            }
            
            // Emergency Stop Loss
            if(InpBasketStopLoss > 0 && netFloatingPnL <= -InpBasketStopLoss) {
                PrintFormat("🛑 Emergency Stop Loss hit! Net Cash PnL: -$%.2f across %d active positions. Flattening basket.", MathAbs(netFloatingPnL), positionsCount);
                CloseAllAndCleanUp();
                return;
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Deploy Initial Validated Breakout Straddle & Follow-up Steps     |
//+------------------------------------------------------------------+
void PlaceGrid() {
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    
    // Safety verification: Get broker Stop Level with explicit (double) casting to eliminate warnings
    long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double minStopDist = (double)stopLevel * _Point;
    
    double initialGap = GetAbsoluteGap(InpInitialGap);
    double stepGap    = GetAbsoluteGap(InpStepGap);
    
    // Ensure initial gap is strictly larger than broker Stop Level
    double actualInitialGap = MathMax(initialGap, minStopDist + (_Point * 2.0));

    PrintFormat("Deploying Straddle Grid... Live Ask: %.*f, Live Bid: %.*f | Start Gap: %.4f, Step Gap: %.4f", 
                _Digits, ask, _Digits, bid, actualInitialGap, stepGap);
    
    // Place 11 Buy Stops (1 Initial Straddle Order + 10 Step Orders)
    for(int i = 0; i < InpGridLevels; i++) {
        double price = ask + actualInitialGap + ((double)i * stepGap);
        price = NormalizeDouble(price, _Digits);
        trade.BuyStop(InpLots, price, _Symbol, 0.0, 0.0, ORDER_TIME_GTC);
    }
    
    // Place 11 Sell Stops (1 Initial Straddle Order + 10 Step Orders)
    for(int i = 0; i < InpGridLevels; i++) {
        double price = bid - actualInitialGap - ((double)i * stepGap);
        price = NormalizeDouble(price, _Digits);
        trade.SellStop(InpLots, price, _Symbol, 0.0, 0.0, ORDER_TIME_GTC);
    }
}

//+------------------------------------------------------------------+
//| Fully Close Active Positions & Delete Pending Orders             |
//+------------------------------------------------------------------+
void CloseAllAndCleanUp() {
    // 1. Delete all pending orders first to block stray fills
    for(int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong orderTicket = OrderGetTicket(i);
        if(orderTicket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber) {
            trade.OrderDelete(orderTicket);
        }
    }
    
    // 2. Instant market close on all active market positions
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong posTicket = PositionGetTicket(i);
        if(posTicket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
            trade.PositionClose(posTicket);
        }
    }
}
//+------------------------------------------------------------------+
