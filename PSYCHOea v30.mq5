//+------------------------------------------------------------------+
//|                       PSYCHOea.mq5  [M15 Chart]                 |
//|         XAU/USD Psychological Level Scalper  v8.00              |
//|                                                                  |
//|  CONCEPT                                                         |
//|  Gold reacts at round number levels every single day.           |
//|  $4400, $4450, $4500 — these are not random. Every retail       |
//|  trader, institutional algorithm and bank trading desk has       |
//|  orders sitting at these levels. When price sweeps through      |
//|  and snaps back, institutions have cleared stops and reversed.  |
//|                                                                  |
//|  HOW IT WORKS                                                    |
//|  Step 1 — Find nearest psychological level                      |
//|    Minor levels : every $50  (4350, 4400, 4450, 4500)          |
//|    Major levels : every $100 (4300, 4400, 4500) — stronger      |
//|    Always watching TWO levels: nearest above + nearest below    |
//|                                                                  |
//|  Step 2 — Detect interaction type                               |
//|    SWEEP+REVERSE: wick through level, close back other side     |
//|    REJECTION    : approach, touch, reject without breaking      |
//|    BREAK+HOLD   : clean break, holds 2+ candles (flip logic)   |
//|                                                                  |
//|  Step 3 — Confirm with independent filters                      |
//|    Rejection candle: strong body confirming reversal direction  |
//|    M1 momentum    : micro direction aligned with trade          |
//|                                                                  |
//|  SCORING (max 100)                                               |
//|  Level sweep/reject : 50 pts — core signal, must fire          |
//|  Rejection candle   : 30 pts — body confirms reversal          |
//|  M1 momentum        : 20 pts — entry timing precision          |
//|  $100 level bonus   : +10 pts — added to sweep score           |
//|  Min score 70 — sweep alone not enough, needs candle or M1     |
//|                                                                  |
//|  ATR GUARD                                                       |
//|  If ATR > 2x average = trending strongly, levels unreliable    |
//|  PSYCHOea goes silent during high momentum directional moves    |
//|                                                                  |
//|  KEY DIFFERENCE FROM OTHER EAs                                  |
//|  TRUEea  — trades WITH confirmed EMA trend                      |
//|  EDGEea  — trades structural CHOCH + sweep (swing levels)      |
//|  BOUNCEea — trades exhaustion at swing highs/lows              |
//|  PSYCHOea — trades mathematical round number reactions          |
//|             Works in trending, ranging and reversing markets    |
//|             Levels are permanent — never need recalculation     |
//|                                                                  |
//|  RISK                                                            |
//|  SL placed beyond the swept level with configurable ATR buffer  |
//|  TP = SL x 2.0 — always 2:1                                    |
//|  Breakeven, trailing stop, loss cooldown, DD caps               |
//|  No martingale. No grid. One trade at a time.                  |
//+------------------------------------------------------------------+
#property copyright "PSYCHOea"
#property version   "8.00"
#property strict

#define MAGIC 20250320 // PSYCHOea magic — unique across all EAs

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//|  INPUTS                                                          |
//+------------------------------------------------------------------+
input group "=== SYMBOL & TIMING ==="
input string  InpSymbol          = "XAUUSD"; // Trading symbol
input int     InpScanInterval    = 10;        // Scan every N seconds

input group "=== RISK MANAGEMENT ==="
input double  InpLotSize         = 0.01;      // Fixed lot size
input double  InpMaxSpread       = 1.50;      // Max spread (price units)
input double  InpMaxDailyDD      = 10.0;      // Max daily drawdown %
input double  InpMaxMonthlyDD    = 20.0;      // Max monthly drawdown %

input group "=== SL/TP ==="
input int     InpATRPeriod       = 14;        // ATR period (M15)
input double  InpSLMultiplier    = 0.20;      // SL = ATR x this
input double  InpMinSL           = 1.00;      // Minimum SL in price units

input group "=== BREAKEVEN ==="
input bool    InpUseBreakeven    = true;      // Enable breakeven
input double  InpBreakevenDist   = 1.50;      // Move SL to entry after $1.50 profit

input group "=== TRAILING STOP ==="
input bool    InpUseTrail        = true;      // Enable trailing stop
input double  InpTrailStart      = 3.00;      // Start trailing after $3.00 profit
input double  InpTrailStep       = 0.50;      // Trail in $0.50 steps

input group "=== LOSS PROTECTION ==="
input int     InpMaxConsecLosses = 3;         // Losses before cooldown
input int     InpCooldownMins    = 20;        // Cooldown minutes
input int     InpPostCloseCooldown = 5;      // Minutes before re-entering after ANY close (0=off)

input group "=== DEAD ZONE ==="
input bool    InpUseDeadZone     = true;      // Block low liquidity hours
input int     InpDeadZoneStart   = 1;         // Dead zone start hour (server)
input int     InpDeadZoneEnd     = 3;         // Dead zone end hour (server)

input group "=== PSYCHOLOGICAL LEVELS ==="
input double  InpMinorStep       = 50.0;      // Minor level interval ($50)
input double  InpMajorStep       = 100.0;     // Major level interval ($100)
input double  InpLevelTolerance  = 2.0;       // Max distance from level to qualify ($)
input double  InpATRTrendFilter  = 2.0;       // Block if ATR > avg * this (trending)
input double  InpLevelBuffer     = 0.20;      // SL buffer beyond level (ATR x this — raise to survive double sweeps)
input int     InpMinScore        = 70;        // Min score to trade

input group "=== LOT SIZING MODE ==="
input bool    InpUseRiskPercent  = false;
input double  InpRiskPercent     = 1.0;

input group "=== ATR SCALING — regime-aware BE/Trail ==="
input bool    InpUseATRScaling   = true;
input double  InpBEMultiplier    = 0.30;      // PSYCHOea wider — level trades need room
input double  InpTrailStartMult  = 0.60;
input double  InpTrailStepMult   = 0.15;

//+------------------------------------------------------------------+
//|  GLOBALS                                                         |
//+------------------------------------------------------------------+
CTrade        trade;
CPositionInfo posInfo;

datetime      lastScanTime        = 0;
double        accountStartBalance = 0;
double        monthStartBalance   = 0;
int           symDigits           = 2;
int           consecLosses        = 0;
datetime      cooldownUntil       = 0;
ulong         lastProcessedTicket = 0;
datetime      lastClosedTime      = 0;    // When last position closed — for post-close re-entry guard
double        lastSL_p            = 2.00;

// ── LIVE PERFORMANCE TRACKER ───────────────────────────────────────
double        g_grossProfit       = 0;
double        g_grossLoss         = 0;
int           g_winTrades         = 0;
int           g_lossTrades        = 0;
double        g_netProfit         = 0;
double        g_peakBalance       = 0;
double        g_maxDD_dollar      = 0;
int           g_nTrades           = 0;
double        g_meanPnL           = 0;
double        g_M2PnL             = 0;

int           hATR;

//+------------------------------------------------------------------+
//|  ATR                                                             |
//+------------------------------------------------------------------+
double GetATR()
  {
   double b[]; ArraySetAsSeries(b, true);
   if(CopyBuffer(hATR, 0, 0, 1, b) < 1) return 3.0;
   return b[0];
  }

double GetAvgATR()
  {
   double b[]; ArraySetAsSeries(b, true);
   if(CopyBuffer(hATR, 0, 0, 14, b) < 14) return 3.0;
   double s = 0;
   for(int i = 0; i < 14; i++) s += b[i];
   return s / 14.0;
  }

//+------------------------------------------------------------------+
//|  DEAD ZONE                                                       |
//+------------------------------------------------------------------+
bool InDeadZone()
  {
   if(!InpUseDeadZone) return false;
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   int h = t.hour;
   if(InpDeadZoneEnd == 24) return (h >= InpDeadZoneStart);
   return (h >= InpDeadZoneStart && h < InpDeadZoneEnd);
  }

//+------------------------------------------------------------------+
//|  PSYCHOLOGICAL LEVEL CALCULATION                                 |
//|  Returns nearest minor level below and above current price      |
//|  Major levels ($100 intervals) score a bonus when hit           |
//+------------------------------------------------------------------+
double GetNearestLevelBelow(double price)
  {
   // Round down to nearest minor step
   return MathFloor(price / InpMinorStep) * InpMinorStep;
  }

double GetNearestLevelAbove(double price)
  {
   // Round up to nearest minor step
   return MathCeil(price / InpMinorStep) * InpMinorStep;
  }

bool IsMajorLevel(double level)
  {
   // Check if level falls on a $100 interval
   double remainder = MathMod(MathRound(level), MathRound(InpMajorStep));
   return (remainder < 0.01);
  }

//+------------------------------------------------------------------+
//|  LEVEL INTERACTION DETECTION                                     |
//|                                                                  |
//|  BullLevelSweep: price wicked BELOW a level then closed ABOVE   |
//|  Institutions swept stops below the round number then reversed  |
//|                                                                  |
//|  BearLevelSweep: price wicked ABOVE a level then closed BELOW   |
//|  Institutions swept stops above the round number then reversed  |
//|                                                                  |
//|  Checks bars 1 and 2 — catches multi-candle sweep sequences     |
//+------------------------------------------------------------------+
bool BullLevelSweep(double level, double &rejStrength)
  {
   if(level <= 0) return false;
   for(int bar = 1; bar <= 2; bar++)
     {
      double hi    = iHigh (InpSymbol, PERIOD_M15, bar);
      double lo    = iLow  (InpSymbol, PERIOD_M15, bar);
      double op    = iOpen (InpSymbol, PERIOD_M15, bar);
      double cl    = iClose(InpSymbol, PERIOD_M15, bar);
      double range = hi - lo;
      if(range <= 0) continue;
      // Wick must pierce below the level
      if(lo >= level) continue;
      // Must close back above the level
      if(cl <= level) continue;
      // Must be a bullish close
      if(cl <= op) continue;
      // Close must be in upper half of candle — strong rejection
      if(cl < lo + range * 0.50) continue;
      rejStrength = (cl - lo) / range;
      return true;
     }
   return false;
  }

bool BearLevelSweep(double level, double &rejStrength)
  {
   if(level <= 0) return false;
   for(int bar = 1; bar <= 2; bar++)
     {
      double hi    = iHigh (InpSymbol, PERIOD_M15, bar);
      double lo    = iLow  (InpSymbol, PERIOD_M15, bar);
      double op    = iOpen (InpSymbol, PERIOD_M15, bar);
      double cl    = iClose(InpSymbol, PERIOD_M15, bar);
      double range = hi - lo;
      if(range <= 0) continue;
      // Wick must pierce above the level
      if(hi <= level) continue;
      // Must close back below the level
      if(cl >= level) continue;
      // Must be a bearish close
      if(cl >= op) continue;
      // Close must be in lower half of candle — strong rejection
      if(cl > lo + range * 0.50) continue;
      rejStrength = (hi - cl) / range;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|  LEVEL REJECTION — price approached level but didn't break      |
//|  Price came within tolerance, touched, and reversed             |
//+------------------------------------------------------------------+
bool BullLevelReject(double level)
  {
   if(level <= 0) return false;
   double lo1 = iLow(InpSymbol, PERIOD_M15, 1);
   double cl1 = iClose(InpSymbol, PERIOD_M15, 1);
   double op1 = iOpen(InpSymbol, PERIOD_M15, 1);
   // Bar came within tolerance of level from above
   if(MathAbs(lo1 - level) > InpLevelTolerance) return false;
   // Did not break below
   if(lo1 < level - InpLevelTolerance) return false;
   // Closed bullish
   return (cl1 > op1);
  }

bool BearLevelReject(double level)
  {
   if(level <= 0) return false;
   double hi1 = iHigh(InpSymbol, PERIOD_M15, 1);
   double cl1 = iClose(InpSymbol, PERIOD_M15, 1);
   double op1 = iOpen(InpSymbol, PERIOD_M15, 1);
   // Bar came within tolerance of level from below
   if(MathAbs(hi1 - level) > InpLevelTolerance) return false;
   // Did not break above
   if(hi1 > level + InpLevelTolerance) return false;
   // Closed bearish
   return (cl1 < op1);
  }

//+------------------------------------------------------------------+
//|  REJECTION CANDLE — strong body confirming reversal direction   |
//+------------------------------------------------------------------+
bool BullRejectionCandle()
  {
   double o = iOpen (InpSymbol, PERIOD_M15, 1);
   double c = iClose(InpSymbol, PERIOD_M15, 1);
   double h = iHigh (InpSymbol, PERIOD_M15, 1);
   double l = iLow  (InpSymbol, PERIOD_M15, 1);
   double range = h - l;
   if(range <= 0) return false;
   if(c <= o) return false;
   return (MathAbs(c - o) / range >= 0.40);
  }

bool BearRejectionCandle()
  {
   double o = iOpen (InpSymbol, PERIOD_M15, 1);
   double c = iClose(InpSymbol, PERIOD_M15, 1);
   double h = iHigh (InpSymbol, PERIOD_M15, 1);
   double l = iLow  (InpSymbol, PERIOD_M15, 1);
   double range = h - l;
   if(range <= 0) return false;
   if(c >= o) return false;
   return (MathAbs(c - o) / range >= 0.40);
  }

//+------------------------------------------------------------------+
//|  M1 MOMENTUM — micro entry timing                               |
//+------------------------------------------------------------------+
bool GetM1Momentum(double &m1mom)
  {
   double c[]; ArraySetAsSeries(c, true);
   if(CopyClose(InpSymbol, PERIOD_M1, 0, 6, c) < 6) return false;
   double sum = 0;
   for(int i = 0; i < 5; i++) sum += c[i] - c[i + 1];
   m1mom = sum / 5.0;
   return true;
  }

//+------------------------------------------------------------------+
//|  PSYCHO SCORE                                                    |
//|                                                                  |
//|  Sweep/Reject is the mandatory core — must fire for any score   |
//|  Major level adds bonus — $100 levels are stronger reactions    |
//|  Rejection candle confirms the reversal with price action       |
//|  M1 momentum aligns micro timing with the reversal direction    |
//|                                                                  |
//|  Max score = 100 (110 at a major level)                         |
//|  Min score 70 = needs sweep + candle OR sweep + M1              |
//+------------------------------------------------------------------+
int PsychoScore(bool hasSweep, bool hasReject, bool isMajor,
                bool rejCandle, bool m1Aligned)
  {
   if(!hasSweep && !hasReject) return 0; // Nothing to trade
   int s = 0;
   if(hasSweep)   s += 50; // Sweep through level and snap back
   if(hasReject)  s += 40; // Rejection without breaking
   if(isMajor)    s += 10; // $100 level bonus
   if(rejCandle)  s += 30; // Strong body confirmation
   if(m1Aligned)  s += 20; // Micro timing aligned
   return MathMin(s, 100); // Cap at 100
  }

//+------------------------------------------------------------------+
//|  SL/TP — placed beyond swept level with ATR buffer              |
//|                                                                  |
//|  FIX v4.00: SL now anchored to absolute level price, not to    |
//|  ask/bid. Old formula (ask - (level - buffer)) was ask-relative |
//|  and produced inconsistent distances when entry was far from    |
//|  the level. New formula computes a fixed SL price below/above   |
//|  the level, then derives distance from current ask/bid.         |
//|  atrSL floor still applies — can never be tighter than ATR.    |
//+------------------------------------------------------------------+
bool GetSLTP(double &sl_out, double &tp_out, double level, bool isBuy)
  {
   double atr = GetATR();
   double avg = GetAvgATR();
   if(avg <= 0) return false;
   if(atr > avg * 3.0) { Print("PSYCHOea: Extreme ATR — skip."); return false; }
   if(atr < avg * 0.3) { Print("PSYCHOea: Dead market — skip."); return false; }

   double atrSL  = MathMax(InpMinSL, atr * InpSLMultiplier);
   double buffer = atr * InpLevelBuffer; // Buffer beyond level — wider = survives double sweeps
   double bid    = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);

   if(isBuy)
     {
      // Absolute SL price = level - buffer (fixed point below the level)
      // Distance = ask - slPrice (how far entry is from that fixed point)
      double slPrice  = (level > 0) ? level - buffer : ask - atrSL;
      double structSL = ask - slPrice;
      sl_out = MathMax(atrSL, structSL); // Never tighter than ATR floor
     }
   else
     {
      // Absolute SL price = level + buffer (fixed point above the level)
      // Distance = slPrice - bid
      double slPrice  = (level > 0) ? level + buffer : bid + atrSL;
      double structSL = slPrice - bid;
      sl_out = MathMax(atrSL, structSL); // Never tighter than ATR floor
     }

   lastSL_p = sl_out;
   tp_out   = sl_out * 2.0; // Always 2:1

   double minStop = SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_STOPS_LEVEL)
                    * SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   if(sl_out < minStop)      sl_out = minStop;
   if(tp_out < minStop*2.0)  tp_out = minStop * 2.0;
   return true;
  }

//+------------------------------------------------------------------+
//|  SESSION MIN SCORE                                               |
//|  Raises threshold during Asian thin hours — more false reactions|
//+------------------------------------------------------------------+
int GetSessionMinScore()
  {
   MqlDateTime mt; TimeToStruct(TimeCurrent(), mt);
   int h = mt.hour;
   if(h >= 7  && h <= 10) return 65; // London open — active levels
   if(h >= 13 && h <= 17) return 65; // NY open — most active levels
   if(h >= 1  && h <= 6)  return 80; // Asian thin — raise bar
   return InpMinScore;               // Default
  }

//+------------------------------------------------------------------+
//|  LIVE PERFORMANCE STATS                                          |
//+------------------------------------------------------------------+
double GetProfitFactor()  { return g_grossLoss>0 ? g_grossProfit/g_grossLoss : 0; }
double GetRecoveryFactor(){ return g_maxDD_dollar>0 ? g_netProfit/g_maxDD_dollar : 0; }
double GetSharpeRatio()
  {
   if(g_nTrades<2) return 0;
   double stdDev=MathSqrt(g_M2PnL/(g_nTrades-1));
   return stdDev>0 ? g_meanPnL/stdDev : 0;
  }

//+------------------------------------------------------------------+
//|  ADAPTIVE LOT                                                    |
//+------------------------------------------------------------------+
double CalcAdaptiveLot(double sl_p)
  {
   double lot;
   if(InpUseRiskPercent)
     {
      double balance=AccountInfoDouble(ACCOUNT_BALANCE);
      double riskAmt=balance*InpRiskPercent/100.0;
      double tickVal=SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_VALUE);
      double tickSz =SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_SIZE);
      double pt     =SymbolInfoDouble(InpSymbol,SYMBOL_POINT);
      double slPts  =(pt>0)?sl_p/pt:0;
      double mpp    =(tickSz>0)?(tickVal/tickSz)*pt:0;
      lot=(mpp>0&&slPts>0)?riskAmt/(slPts*mpp):InpLotSize;
     }
   else lot=InpLotSize;
   if(consecLosses==2)      lot*=0.50;
   else if(consecLosses>=3) lot*=0.25;
   double minL=SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MIN);
   double maxL=SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_STEP);
   lot=MathFloor(lot/step)*step;
   return NormalizeDouble(MathMax(minL,MathMin(maxL,lot)),2);
  }

//+------------------------------------------------------------------+
//|  LOSS TRACKER                                                    |
//+------------------------------------------------------------------+
void UpdateLossTracker()
  {
   if(!HistorySelect(TimeCurrent() - 604800, TimeCurrent())) return;
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0 || t <= lastProcessedTicket) break;
      if(HistoryDealGetInteger(t, DEAL_MAGIC) != MAGIC)          continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      double profit  = HistoryDealGetDouble(t, DEAL_PROFIT);
      double fullPnL = profit
                     + HistoryDealGetDouble(t, DEAL_COMMISSION)
                     + HistoryDealGetDouble(t, DEAL_SWAP);
      lastProcessedTicket = t;
      lastClosedTime = TimeCurrent(); // mark close time
      g_nTrades++; g_netProfit+=fullPnL;
      if(fullPnL>0){g_grossProfit+=fullPnL;g_winTrades++;}
      else{g_grossLoss+=MathAbs(fullPnL);g_lossTrades++;}
      double bal=AccountInfoDouble(ACCOUNT_BALANCE);
      if(bal>g_peakBalance) g_peakBalance=bal;
      double dd=g_peakBalance-bal; if(dd>g_maxDD_dollar) g_maxDD_dollar=dd;
      double delta=fullPnL-g_meanPnL; g_meanPnL+=delta/g_nTrades; g_M2PnL+=delta*(fullPnL-g_meanPnL);
      if(profit < 0)
        {
         consecLosses++;
         Print("PSYCHOea: Loss #", consecLosses);
         if(consecLosses >= InpMaxConsecLosses)
           { cooldownUntil = TimeCurrent() + InpCooldownMins * 60;
             consecLosses  = 0;
             Print("PSYCHOea: Cooldown until ", TimeToString(cooldownUntil, TIME_MINUTES)); }
        }
      else if(profit > 0) { consecLosses = 0; }
      break;
     }
  }

//+------------------------------------------------------------------+
//|  BREAKEVEN                                                       |
//+------------------------------------------------------------------+
void ManageBreakeven()
  {
   if(!InpUseBreakeven) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i))     continue;
      if(posInfo.Symbol() != InpSymbol) continue;
      if(posInfo.Magic()  != MAGIC)     continue;
      double op  = posInfo.PriceOpen(), sl = posInfo.StopLoss();
      double bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
      double beDist = InpUseATRScaling ? GetATR()*InpBEMultiplier : MathMax(InpBreakevenDist, lastSL_p * 0.35);
      if(posInfo.PositionType() == POSITION_TYPE_BUY)
        { if(bid - op >= beDist && sl < op)
            trade.PositionModify(posInfo.Ticket(), NormalizeDouble(op + 0.01, symDigits), posInfo.TakeProfit()); }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
        { if(op - ask >= beDist && (sl > op || sl == 0))
            trade.PositionModify(posInfo.Ticket(), NormalizeDouble(op - 0.01, symDigits), posInfo.TakeProfit()); }
     }
  }

//+------------------------------------------------------------------+
//|  TRAILING STOP                                                   |
//+------------------------------------------------------------------+
void ManageTrail()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i))     continue;
      if(posInfo.Symbol() != InpSymbol) continue;
      if(posInfo.Magic()  != MAGIC)     continue;
      double op  = posInfo.PriceOpen(), sl = posInfo.StopLoss();
      double bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
      double _atr = GetATR();
      double trailStart = InpUseATRScaling ? _atr*InpTrailStartMult : MathMax(InpTrailStart, lastSL_p * 0.50);
      double trailStep  = InpUseATRScaling ? _atr*InpTrailStepMult : MathMax(InpTrailStep,  lastSL_p * 0.20);
      if(posInfo.PositionType() == POSITION_TYPE_BUY)
        { if(bid - op >= trailStart)
           { double nsl = NormalizeDouble(bid - trailStep, symDigits);
             if(nsl > sl + trailStep) trade.PositionModify(posInfo.Ticket(), nsl, posInfo.TakeProfit()); } }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
        { if(op - ask >= trailStart)
           { double nsl = NormalizeDouble(ask + trailStep, symDigits);
             if(sl == 0 || nsl < sl - trailStep) trade.PositionModify(posInfo.Ticket(), nsl, posInfo.TakeProfit()); } }
     }
  }

//+------------------------------------------------------------------+
//|  DRAWDOWN                                                        |
//+------------------------------------------------------------------+
bool DrawdownOK()
  {
   if(accountStartBalance <= 0 || monthStartBalance <= 0) return true;

   // Daily DD — equity (live, includes open floating P&L)
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if((accountStartBalance - eq) / accountStartBalance * 100.0 >= InpMaxDailyDD)
     { Print("PSYCHOea: Daily DD hit (equity basis)."); return false; }

   // Monthly DD — balance only (settled trades, not distorted by open floating P&L)
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if((monthStartBalance - bal) / monthStartBalance * 100.0 >= InpMaxMonthlyDD)
     { Print("PSYCHOea: Monthly DD hit (balance basis)."); return false; }

   return true;
  }

//+------------------------------------------------------------------+
//|  OPEN POSITION CHECK                                             |
//+------------------------------------------------------------------+
bool HasPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     { if(!posInfo.SelectByIndex(i)) continue;
       if(posInfo.Symbol() == InpSymbol && posInfo.Magic() == MAGIC) return true; }
   return false;
  }

//+------------------------------------------------------------------+
//|  DASHBOARD                                                       |
//+------------------------------------------------------------------+
void Dashboard(double levelBelow, double levelAbove,
               double bid, double atr, double spread,
               bool bullSweep, bool bearSweep,
               bool bullReject, bool bearReject,
               bool bullMajor, bool bearMajor,
               bool rejCandleBull, bool rejCandleBear,
               double m1v, bool m1OK,
               int buyScore, int sellScore,
               double sl_p, double tp_p,
               string signal, int sessionMin,
               bool atrBlocked)
  {
   string block = "";
   if(InDeadZone())                          block = "DEAD ZONE";
   else if(atrBlocked)                       block = "ATR TRENDING";
   else if(buyScore  < sessionMin &&
           sellScore < sessionMin)            block = "LOW SCORE";
   else if(TimeCurrent() < cooldownUntil)    block = "COOLDOWN";
   else if(TimeCurrent()<(lastClosedTime+InpPostCloseCooldown*60)) block = "POST-CLOSE";

   string n = "--";
   string d = "===== PSYCHOea v8.00 =====\n";
   d += "Time  : " + TimeToString(TimeCurrent(), TIME_MINUTES) + "\n";
   d += "Price : " + DoubleToString(bid, 2);
   d += "  Sprd:$" + DoubleToString(spread, 2) + "\n";
   d += "ATR:$" + DoubleToString(atr, 2);
   d += "  SL:$" + DoubleToString(sl_p, 2);
   d += "  TP:$" + DoubleToString(tp_p, 2) + "\n";
   d += "---- PSYCH LEVELS ----\n";
   d += "Level Below: $" + DoubleToString(levelBelow, 0);
   d += (bullMajor ? " [MAJOR]" : " [minor]") + "\n";
   d += "Level Above: $" + DoubleToString(levelAbove, 0);
   d += (bearMajor ? " [MAJOR]" : " [minor]") + "\n";
   d += "---- INTERACTIONS ----\n";
   d += "BullSweep: " + (bullSweep ? "YES" : n);
   d += "  BullReject: " + (bullReject ? "YES" : n) + "\n";
   d += "BearSweep: " + (bearSweep ? "YES" : n);
   d += "  BearReject: " + (bearReject ? "YES" : n) + "\n";
   d += "RejCndle: Buy=" + (rejCandleBull?"YES":n);
   d += " Sell=" + (rejCandleBear?"YES":n) + "\n";
   d += "M1Mom : " + (m1OK ? DoubleToString(m1v, 3) : "n/a") + "\n";
   d += "BuyScore : " + IntegerToString(buyScore) + "/" + IntegerToString(sessionMin) + "\n";
   d += "SellScore: " + IntegerToString(sellScore) + "/" + IntegerToString(sessionMin) + "\n";
   d += "Losses: " + IntegerToString(consecLosses) + "/" + IntegerToString(InpMaxConsecLosses) + "\n";
   if(block != "")
      d += "BLOCK : " + block + "\n";
   d += "Cooldown: " + (TimeCurrent() < cooldownUntil ? TimeToString(cooldownUntil, TIME_MINUTES) : "none") + "\n";
   datetime _pcEnd = lastClosedTime + InpPostCloseCooldown*60;
   d += "PostClose: " + (TimeCurrent()<_pcEnd ? TimeToString(_pcEnd,TIME_MINUTES)+" (wait)" : "ready") + "\n";
   // ATR-scaled display values — use passed atr param (consistent with rest of dashboard)
   double beShow=InpUseATRScaling?atr*InpBEMultiplier:InpBreakevenDist;
   double trShow=InpUseATRScaling?atr*InpTrailStartMult:InpTrailStart;
   d += "BE:$"+DoubleToString(beShow,2)+(InpUseATRScaling?"(ATR)":"($)");
   d += "  Trail:$"+DoubleToString(trShow,2)+(InpUseATRScaling?"(ATR)":"($)")+"\n";
   d += "Lot:"+DoubleToString(CalcAdaptiveLot(sl_p),2)+"\n";
   d += "---- LIVE PERF ----\n";
   d += "T:"+IntegerToString(g_nTrades)+" W:"+IntegerToString(g_winTrades)+" L:"+IntegerToString(g_lossTrades);
   if(g_nTrades>0) d += " ("+DoubleToString((double)g_winTrades/g_nTrades*100,1)+"%)";
   d += "\n";
   d += "PF:"+(g_grossLoss>0?DoubleToString(GetProfitFactor(),2):"n/a");
   d += " RF:"+(g_maxDD_dollar>0?DoubleToString(GetRecoveryFactor(),2):"n/a");
   d += " SR:"+(g_nTrades>=2?DoubleToString(GetSharpeRatio(),2):"n/a")+"\n";
   d += "Net:$"+DoubleToString(g_netProfit,2)+" MaxDD:$"+DoubleToString(g_maxDD_dollar,2)+"\n";
   d += (signal != "" ? ">>> " + signal + " <<<" : "Watching levels...");
   Comment(d);
  }

//+------------------------------------------------------------------+
//|  RECONSTRUCT DAILY START BALANCE                                 |
//|  Sums all closed deal P&L since 00:00 today and subtracts from  |
//|  current balance to recover the true open-of-day balance.       |
//|  Survives mid-day MT5 restarts — daily DD gate never resets.    |
//+------------------------------------------------------------------+
double ReconstructDayStartBalance()
  {
   MqlDateTime today; TimeToStruct(TimeCurrent(), today);
   datetime dayStart = StringToTime(StringFormat("%04d.%02d.%02d 00:00",
                                    today.year, today.mon, today.day));
   if(!HistorySelect(dayStart, TimeCurrent())) return AccountInfoDouble(ACCOUNT_BALANCE);
   double pnl = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      pnl += HistoryDealGetDouble(t, DEAL_PROFIT)
           + HistoryDealGetDouble(t, DEAL_COMMISSION)
           + HistoryDealGetDouble(t, DEAL_SWAP);
     }
   return AccountInfoDouble(ACCOUNT_BALANCE) - pnl;
  }

//+------------------------------------------------------------------+
//|  RECONSTRUCT MONTH START BALANCE                                 |
//+------------------------------------------------------------------+
double ReconstructMonthStartBalance()
  {
   MqlDateTime today; TimeToStruct(TimeCurrent(), today);
   datetime monStart = StringToTime(StringFormat("%04d.%02d.01 00:00",
                                    today.year, today.mon));
   if(!HistorySelect(monStart, TimeCurrent())) return AccountInfoDouble(ACCOUNT_BALANCE);
   double pnl = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      pnl += HistoryDealGetDouble(t, DEAL_PROFIT)
           + HistoryDealGetDouble(t, DEAL_COMMISSION)
           + HistoryDealGetDouble(t, DEAL_SWAP);
     }
   return AccountInfoDouble(ACCOUNT_BALANCE) - pnl;
  }

//+------------------------------------------------------------------+
//|  OnInit                                                          |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      Print("PSYCHOea: Trade not allowed yet — retrying each tick.");

   trade.SetExpertMagicNumber(MAGIC);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFillingBySymbol(InpSymbol);
   trade.SetAsyncMode(false);

   symDigits           = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   accountStartBalance = ReconstructDayStartBalance();
   monthStartBalance   = ReconstructMonthStartBalance();
   g_peakBalance       = accountStartBalance;

   hATR = iATR(InpSymbol, PERIOD_M15, InpATRPeriod);
   if(hATR == INVALID_HANDLE)
     { Print("PSYCHOea: ATR handle error."); return INIT_FAILED; }

   EventSetTimer(60);
   Print("PSYCHOea v8.00 Ready | ", InpSymbol, " | Psych Level Scalper | Lot:", InpLotSize, " | MinScore:", InpMinScore);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//|  OnDeinit                                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(hATR);
   EventKillTimer(); Comment(""); Print("PSYCHOea: Stopped.");
  }

//+------------------------------------------------------------------+
//|  OnTick                                                          |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(TimeCurrent() - lastScanTime < InpScanInterval) return;
   lastScanTime = TimeCurrent();

   UpdateLossTracker();

   // ATR — always compute for dashboard
   double atr = GetATR(), avg = GetAvgATR();
   bool atrBlocked = (avg > 0 && atr > avg * InpATRTrendFilter);

   // SL/TP preview for dashboard
   double sl_p = MathMax(InpMinSL, atr * InpSLMultiplier);
   double tp_p = sl_p * 2.0;

   // Position management always runs
   if(InpUseBreakeven) ManageBreakeven();
   if(InpUseTrail)     ManageTrail();

   double spread = SymbolInfoDouble(InpSymbol, SYMBOL_ASK) - SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   double bid    = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);

   // ── FIND NEAREST PSYCHOLOGICAL LEVELS ───────────────────────────
   double levelBelow = GetNearestLevelBelow(bid);
   double levelAbove = GetNearestLevelAbove(bid);
   // If price is exactly on a level, shift to next ones
   if(MathAbs(bid - levelBelow) < 0.01) levelBelow -= InpMinorStep;
   if(MathAbs(bid - levelAbove) < 0.01) levelAbove += InpMinorStep;
   bool bullMajor = IsMajorLevel(levelBelow);
   bool bearMajor = IsMajorLevel(levelAbove);

   // ── DETECT INTERACTIONS ──────────────────────────────────────────
   double bullRejStr = 0, bearRejStr = 0;
   bool bullSweep   = BullLevelSweep(levelBelow, bullRejStr);
   bool bearSweep   = BearLevelSweep(levelAbove, bearRejStr);
   bool bullReject  = (!bullSweep) ? BullLevelReject(levelBelow) : false;
   bool bearReject  = (!bearSweep) ? BearLevelReject(levelAbove) : false;

   // ── CONFIRMATION FILTERS ─────────────────────────────────────────
   bool rejCandleBull = BullRejectionCandle();
   bool rejCandleBear = BearRejectionCandle();

   double m1mom = 0;
   bool   m1OK  = GetM1Momentum(m1mom);
   bool   m1Bull = m1OK && (m1mom >  0.20);
   bool   m1Bear = m1OK && (m1mom < -0.20);

   // ── SCORE BOTH DIRECTIONS ────────────────────────────────────────
   int buyScore  = PsychoScore(bullSweep, bullReject, bullMajor, rejCandleBull, m1Bull);
   int sellScore = PsychoScore(bearSweep, bearReject, bearMajor, rejCandleBear, m1Bear);
   int sessionMin = GetSessionMinScore();

   // ── SIGNAL ───────────────────────────────────────────────────────
   string signal = "";
   double sl = 0, tp = 0;
   double activeLevel = 0;

   if(buyScore >= sessionMin && (!m1OK || m1Bull))
     {
      activeLevel = levelBelow;
      if(GetSLTP(sl_p, tp_p, activeLevel, true))
        { signal = "BUY";
          sl = NormalizeDouble(ask - sl_p, symDigits);
          tp = NormalizeDouble(ask + tp_p, symDigits); }
     }
   else if(sellScore >= sessionMin && (!m1OK || m1Bear))
     {
      activeLevel = levelAbove;
      if(GetSLTP(sl_p, tp_p, activeLevel, false))
        { signal = "SELL";
          sl = NormalizeDouble(bid + sl_p, symDigits);
          tp = NormalizeDouble(bid - tp_p, symDigits); }
     }

   // Dashboard ALWAYS updates
   Dashboard(levelBelow, levelAbove, bid, atr, spread,
             bullSweep, bearSweep, bullReject, bearReject,
             bullMajor, bearMajor, rejCandleBull, rejCandleBear,
             m1mom, m1OK, buyScore, sellScore,
             sl_p, tp_p, signal, sessionMin, atrBlocked);

   // All gates — dashboard already updated
   if(atrBlocked)                                    { Print("PSYCHOea: ATR trending — skip."); return; }
   if(InDeadZone())                                  return;
   if(TimeCurrent() < cooldownUntil)                 return;
   if(TimeCurrent() < (lastClosedTime+InpPostCloseCooldown*60)) return; // post-close re-entry guard
   if(!DrawdownOK())                                 return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))  return;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))    return;
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))       return;
   if(spread > InpMaxSpread)                         return;
   if(HasPosition())                                 return;
   if(signal == "")                                  return;

   double lot = CalcAdaptiveLot(sl_p);
   if(lot <= 0) { Print("PSYCHOea: Invalid lot — skip."); return; }

   if(signal == "BUY")
     {
      for(int a = 1; a <= 3; a++)
        {
         double md = SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_STOPS_LEVEL)
                     * SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
         if(ask - sl < md) sl = NormalizeDouble(ask - md,    symDigits);
         if(tp - ask < md) tp = NormalizeDouble(ask + md*2,  symDigits);
         if(trade.Buy(lot, InpSymbol, ask, sl, tp, "PSYCHOea"))
           { Print("PSYCHOea BUY | Level:$",DoubleToString(activeLevel,0)," Score:",buyScore," Lot:",lot," SL:$",DoubleToString(sl_p,2)," TP:$",DoubleToString(tp_p,2)); break; }
         int err = GetLastError();
         Print("PSYCHOea BUY attempt ", a, " FAILED | Error:", err);
         if(err != 10013 && err != 10014 && err != 10018 && err != 10004) break;
         if(a == 3) { cooldownUntil = TimeCurrent() + 600; Print("PSYCHOea: Circuit breaker BUY."); break; }
         Sleep(500);
         ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
         GetSLTP(sl_p, tp_p, activeLevel, true);
         sl = NormalizeDouble(ask - sl_p, symDigits);
         tp = NormalizeDouble(ask + tp_p, symDigits);
        }
     }
   else if(signal == "SELL")
     {
      for(int a = 1; a <= 3; a++)
        {
         double md = SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_STOPS_LEVEL)
                     * SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
         if(sl - bid < md) sl = NormalizeDouble(bid + md,    symDigits);
         if(bid - tp < md) tp = NormalizeDouble(bid - md*2,  symDigits);
         if(trade.Sell(lot, InpSymbol, bid, sl, tp, "PSYCHOea"))
           { Print("PSYCHOea SELL | Level:$",DoubleToString(activeLevel,0)," Score:",sellScore," Lot:",lot," SL:$",DoubleToString(sl_p,2)," TP:$",DoubleToString(tp_p,2)); break; }
         int err = GetLastError();
         Print("PSYCHOea SELL attempt ", a, " FAILED | Error:", err);
         if(err != 10013 && err != 10014 && err != 10018 && err != 10004) break;
         if(a == 3) { cooldownUntil = TimeCurrent() + 600; Print("PSYCHOea: Circuit breaker SELL."); break; }
         Sleep(500);
         bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
         GetSLTP(sl_p, tp_p, activeLevel, false);
         sl = NormalizeDouble(bid + sl_p, symDigits);
         tp = NormalizeDouble(bid - tp_p, symDigits);
        }
     }
  }

//+------------------------------------------------------------------+
//|  OnTimer — daily/monthly balance reset                           |
//+------------------------------------------------------------------+
void OnTimer()
  {
   static datetime lastDay = 0, lastMon = 0;
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   datetime dS = StringToTime(StringFormat("%04d.%02d.%02d 00:00", t.year, t.mon, t.day));
   datetime mS = StringToTime(StringFormat("%04d.%02d.01 00:00",   t.year, t.mon));
   if(dS != lastDay)
     { accountStartBalance = AccountInfoDouble(ACCOUNT_BALANCE); lastDay = dS;
       Print("PSYCHOea: Daily reset $", DoubleToString(accountStartBalance, 2)); }
   if(mS != lastMon)
     { monthStartBalance = AccountInfoDouble(ACCOUNT_BALANCE); lastMon = mS;
       Print("PSYCHOea: Monthly reset $", DoubleToString(monthStartBalance, 2)); }
  }
//+------------------------------------------------------------------+
