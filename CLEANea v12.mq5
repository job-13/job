//+------------------------------------------------------------------+
//|                        CLEANea.mq5  [M15 Chart]                 |
//|              XAU/USD  v12.0  — Structure-Aware Trend Sniper     |
//|                                                                  |
//|  v12 CHANGES vs v11                                             |
//|  ─────────────────────────────────────────────────────────────  |
//|  1. TRAIL FIXED — was never firing (TrailStart 5.92 > TP 1.75) |
//|     TrailStartMult 5.92 → 1.5  | TrailStepMult 1.0 → 0.25      |
//|     TP widened 2.0 → 4.0  — gives trail room to catch big moves |
//|                                                                  |
//|  2. DRAWDOWN GUARD — MaxConsecLosses 11 → 4                    |
//|     At 25% win rate, 11 was letting the EA bleed 8 straight    |
//|     losses (-$113) before pausing. Now stops at 4 losses.       |
//|                                                                  |
//|  3. H1 SWING DETECTION — replaces M15 pivot scan               |
//|     M15 pivots were tick-sensitive (96 vs 52 trades same params)|
//|     H1 structural pivots are stable across runs.                |
//|                                                                  |
//|  4. ZONE TIGHTENED — ZoneWidthMult 1.5 → 0.7                  |
//|     1.5 × ATR zone was a $30 range — too wide to mean anything  |
//|     0.7 × ATR requires price to be genuinely AT the level       |
//|                                                                  |
//|  5. PIVOT STRENGTH — SwingStrength 3 → 5                       |
//|     Requires 5 H1 bars each side — only major structural turns  |
//|                                                                  |
//|  6. ADX TIGHTENED — 20 → 25                                    |
//|     ADX 20 passes ~60% of market time. 25 filters out chop.    |
//|                                                                  |
//|  7. H4 EMA STABILISED — period 50 → 100                       |
//|     EMA(50) on H4 flips too often. EMA(100) = smoother macro.  |
//|                                                                  |
//|  8. POST-CLOSE COOLDOWN — 21 → 45 mins                        |
//|     Prevents chaining multiple trades in same session move       |
//|                                                                  |
//|  PHILOSOPHY                                                      |
//|  Structure → Confirmation → Enter. Never the reverse.           |
//|  H4 macro direction → H1 S/R zone → M15 momentum → Enter       |
//+------------------------------------------------------------------+
#property copyright "CLEANea v12"
#property version   "12.00"
#property strict

#define MAGIC 20250324

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//|  INPUTS                                                          |
//+------------------------------------------------------------------+
input group "=== SYMBOL ==="
input string  InpSymbol           = "XAUUSD";

input group "=== RISK MANAGEMENT ==="
input double  InpLotSize          = 0.01;
input double  InpMaxSpread        = 1.50;
input double  InpMaxDailyDD       = 4.0;

input group "=== SL / TP ==="
input int     InpATRPeriod        = 70;
input double  InpSLMultiplier     = 0.875;
input double  InpMinSL            = 4.05;
input double  InpTPMultiplier     = 4.0;    // TP = SL x this — widened from 2.0 to give trail room

input group "=== BREAKEVEN ==="
input bool    InpUseBreakeven     = true;
input double  InpBEMultiplier     = 0.65;

input group "=== TRAILING STOP ==="
input bool    InpUseTrail         = true;
input double  InpTrailStartMult   = 1.5;    // FIXED: was 5.92 (higher than TP — trail never fired)
input double  InpTrailStepMult    = 0.25;   // Lock in profit every 0.25 ATR — was 1.0 (gave back too much)

input group "=== LOSS PROTECTION ==="
input int     InpMaxConsecLosses  = 4;      // REDUCED from 11 — stops 8-loss bleed at 25% win rate
input int     InpCooldownMins     = 60;
input int     InpPostCloseCooldown = 45;    // INCREASED from 21 — prevents intraday trade chaining

input group "=== DEAD ZONE ==="
input bool    InpUseDeadZone      = true;
input int     InpDeadZoneStart    = 22;
input int     InpDeadZoneEnd      = 24;

input group "=== H4 TREND FILTER ==="
input bool    InpUseH4Filter      = true;
input int     InpH4EMAPeriod      = 100;    // INCREASED from 50 — more stable macro trend

input group "=== H1 SWING S/R ZONES ==="
input bool    InpUseSwingFilter   = true;
input int     InpSwingLookback    = 20;     // H1 bars (20 H1 bars = ~1 trading day back)
input int     InpSwingStrength    = 5;      // INCREASED from 3 — requires 5 H1 bars each side
input double  InpZoneWidthMult    = 0.7;    // TIGHTENED from 1.5 — must be genuinely at the level

input group "=== SIGNAL ==="
input int     InpEMAFast          = 155;
input int     InpEMASlow          = 386;
input int     InpM5EMAFast        = 149;
input int     InpM5EMASlow        = 240;
input int     InpRSIPeriod        = 57;
input double  InpRSIBuyLow        = 38.0;
input double  InpRSIBuyHigh       = 52.0;
input double  InpRSISellLow       = 48.0;
input double  InpRSISellHigh      = 62.0;
input int     InpADXPeriod        = 14;
input double  InpADXMinLevel      = 25.0;   // INCREASED from 20 — filters choppy low-trend entries

//+------------------------------------------------------------------+
//|  GLOBALS                                                         |
//+------------------------------------------------------------------+
CTrade        trade;
CPositionInfo posInfo;

datetime      lastBarTime         = 0;
double        accountStartBalance = 0;
int           consecLosses        = 0;
datetime      cooldownUntil       = 0;
datetime      lastClosedTime      = 0;
ulong         lastProcessedTicket = 0;
int           symDigits           = 2;

int           hEMAFast, hEMASlow;
int           hM5EMAFast, hM5EMASlow;
int           hH4EMA;
int           hRSI, hATR, hADX;

//+------------------------------------------------------------------+
//|  OnInit                                                          |
//+------------------------------------------------------------------+
int OnInit()
  {
   // ── PARAMETER VALIDATION — blocks optimizer abuse ──────────────
   if(InpEMAFast >= InpEMASlow)
     {
      Print("CLEANea ERROR: InpEMAFast (", InpEMAFast, ") must be < InpEMASlow (", InpEMASlow, ")");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpM5EMAFast >= InpM5EMASlow)
     {
      Print("CLEANea ERROR: InpM5EMAFast (", InpM5EMAFast, ") must be < InpM5EMASlow (", InpM5EMASlow, ")");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRSIBuyLow  < 0 || InpRSIBuyHigh  > 100 ||
      InpRSISellLow < 0 || InpRSISellHigh > 100)
     {
      Print("CLEANea ERROR: RSI values must be 0-100. Got Buy:[",
            InpRSIBuyLow,"-",InpRSIBuyHigh,"] Sell:[",InpRSISellLow,"-",InpRSISellHigh,"]");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRSIBuyLow >= InpRSIBuyHigh || InpRSISellLow >= InpRSISellHigh)
     {
      Print("CLEANea ERROR: RSI low must be < RSI high");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpTrailStartMult >= InpTPMultiplier / InpSLMultiplier)
      Print("CLEANea WARNING: TrailStart >= TP distance — trail may not activate before TP. Consider widening TP.");

   trade.SetExpertMagicNumber(MAGIC);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFillingBySymbol(InpSymbol);
   trade.SetAsyncMode(false);

   symDigits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

   hEMAFast   = iMA(InpSymbol, PERIOD_M15, InpEMAFast,    0, MODE_EMA, PRICE_CLOSE);
   hEMASlow   = iMA(InpSymbol, PERIOD_M15, InpEMASlow,    0, MODE_EMA, PRICE_CLOSE);
   hRSI       = iRSI(InpSymbol, PERIOD_M15, InpRSIPeriod, PRICE_CLOSE);
   hATR       = iATR(InpSymbol, PERIOD_M15, InpATRPeriod);
   hADX       = iADX(InpSymbol, PERIOD_M15, InpADXPeriod);
   hM5EMAFast = iMA(InpSymbol, PERIOD_M5,  InpM5EMAFast,  0, MODE_EMA, PRICE_CLOSE);
   hM5EMASlow = iMA(InpSymbol, PERIOD_M5,  InpM5EMASlow,  0, MODE_EMA, PRICE_CLOSE);
   hH4EMA     = iMA(InpSymbol, PERIOD_H4,  InpH4EMAPeriod,0, MODE_EMA, PRICE_CLOSE);

   if(hEMAFast   == INVALID_HANDLE || hEMASlow  == INVALID_HANDLE ||
      hRSI       == INVALID_HANDLE || hATR      == INVALID_HANDLE ||
      hADX       == INVALID_HANDLE || hM5EMAFast== INVALID_HANDLE ||
      hM5EMASlow == INVALID_HANDLE || hH4EMA    == INVALID_HANDLE)
     {
      Print("CLEANea: Indicator init failed");
      return INIT_FAILED;
     }

   accountStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   EventSetTimer(60);

   Print("CLEANea v12 | Trail fixed (start:", InpTrailStartMult, "x step:", InpTrailStepMult,
         "x) | TP:", InpTPMultiplier, "x | MaxLoss:", InpMaxConsecLosses,
         " | Balance:$", DoubleToString(accountStartBalance, 2));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//|  OnDeinit                                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   IndicatorRelease(hEMAFast);   IndicatorRelease(hEMASlow);
   IndicatorRelease(hRSI);       IndicatorRelease(hATR);
   IndicatorRelease(hADX);       IndicatorRelease(hM5EMAFast);
   IndicatorRelease(hM5EMASlow); IndicatorRelease(hH4EMA);
   ObjectsDeleteAll(0, "CLEANea_");
  }

//+------------------------------------------------------------------+
//|  IsNewBar — fires only on M15 candle close                      |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime currentBar = iTime(InpSymbol, PERIOD_M15, 0);
   if(currentBar != lastBarTime) { lastBarTime = currentBar; return true; }
   return false;
  }

//+------------------------------------------------------------------+
//|  GetATR                                                          |
//+------------------------------------------------------------------+
double GetATR()
  {
   double b[]; ArraySetAsSeries(b, true);
   if(CopyBuffer(hATR, 0, 1, 1, b) < 1) return 3.0;
   return b[0];
  }

//+------------------------------------------------------------------+
//|  GetTrend — "BULL", "BEAR" or "SIDE"                           |
//+------------------------------------------------------------------+
string GetTrend(int hFast, int hSlow)
  {
   double fast[], slow[];
   ArraySetAsSeries(fast, true); ArraySetAsSeries(slow, true);
   if(CopyBuffer(hFast, 0, 1, 2, fast) < 2) return "SIDE";
   if(CopyBuffer(hSlow, 0, 1, 2, slow) < 2) return "SIDE";
   if(fast[0] > slow[0] && fast[1] > slow[1]) return "BULL";
   if(fast[0] < slow[0] && fast[1] < slow[1]) return "BEAR";
   return "SIDE";
  }

//+------------------------------------------------------------------+
//|  GetH4Trend — H4 close vs H4 EMA(100) macro direction          |
//+------------------------------------------------------------------+
string GetH4Trend()
  {
   if(!InpUseH4Filter) return "ANY";
   double ema[], cls[];
   ArraySetAsSeries(ema, true); ArraySetAsSeries(cls, true);
   if(CopyBuffer(hH4EMA, 0, 1, 1, ema) < 1)           return "SIDE";
   if(CopyClose(InpSymbol, PERIOD_H4, 1, 1, cls) < 1) return "SIDE";
   if(cls[0] > ema[0]) return "BULL";
   if(cls[0] < ema[0]) return "BEAR";
   return "SIDE";
  }

//+------------------------------------------------------------------+
//|  GetRSI                                                          |
//+------------------------------------------------------------------+
double GetRSI()
  {
   double b[]; ArraySetAsSeries(b, true);
   if(CopyBuffer(hRSI, 0, 1, 1, b) < 1) return 50.0;
   return b[0];
  }

//+------------------------------------------------------------------+
//|  GetADX                                                          |
//+------------------------------------------------------------------+
double GetADX()
  {
   double b[]; ArraySetAsSeries(b, true);
   if(CopyBuffer(hADX, 0, 1, 1, b) < 1) return 0.0;
   return b[0];
  }

//+------------------------------------------------------------------+
//|  FindSwingHigh — H1 pivot high (stable, not tick-sensitive)     |
//|  Uses H1 bars — avoids the M15 inconsistency (96 vs 52 trades) |
//+------------------------------------------------------------------+
double FindSwingHigh()
  {
   int total = InpSwingLookback + InpSwingStrength + 1;
   double highs[];
   ArraySetAsSeries(highs, true);
   if(CopyHigh(InpSymbol, PERIOD_H1, 1, total, highs) < total)
      return 0;

   int n = InpSwingStrength;
   for(int i = n; i < InpSwingLookback; i++)
     {
      bool isPivot = true;
      for(int j = 1; j <= n && isPivot; j++)
         if(highs[i - j] >= highs[i] || highs[i + j] >= highs[i])
            isPivot = false;
      if(isPivot) return highs[i];
     }
   return 0;
  }

//+------------------------------------------------------------------+
//|  FindSwingLow — H1 pivot low                                    |
//+------------------------------------------------------------------+
double FindSwingLow()
  {
   int total = InpSwingLookback + InpSwingStrength + 1;
   double lows[];
   ArraySetAsSeries(lows, true);
   if(CopyLow(InpSymbol, PERIOD_H1, 1, total, lows) < total)
      return 0;

   int n = InpSwingStrength;
   for(int i = n; i < InpSwingLookback; i++)
     {
      bool isPivot = true;
      for(int j = 1; j <= n && isPivot; j++)
         if(lows[i - j] <= lows[i] || lows[i + j] <= lows[i])
            isPivot = false;
      if(isPivot) return lows[i];
     }
   return 0;
  }

//+------------------------------------------------------------------+
//|  IsAtSupport — price within 0.7 ATR of H1 swing low            |
//+------------------------------------------------------------------+
bool IsAtSupport(double price, double atr)
  {
   if(!InpUseSwingFilter) return true;
   double swingLow = FindSwingLow();
   if(swingLow == 0) return false;
   double zone = atr * InpZoneWidthMult;
   return (price >= swingLow - zone && price <= swingLow + zone);
  }

//+------------------------------------------------------------------+
//|  IsAtResistance — price within 0.7 ATR of H1 swing high        |
//+------------------------------------------------------------------+
bool IsAtResistance(double price, double atr)
  {
   if(!InpUseSwingFilter) return true;
   double swingHigh = FindSwingHigh();
   if(swingHigh == 0) return false;
   double zone = atr * InpZoneWidthMult;
   return (price >= swingHigh - zone && price <= swingHigh + zone);
  }

//+------------------------------------------------------------------+
//|  HasPosition                                                     |
//+------------------------------------------------------------------+
bool HasPosition()
  {
   for(int i = 0; i < PositionsTotal(); i++)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == InpSymbol && posInfo.Magic() == MAGIC)
            return true;
   return false;
  }

//+------------------------------------------------------------------+
//|  DrawdownOK                                                      |
//+------------------------------------------------------------------+
bool DrawdownOK()
  {
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyDD = ((accountStartBalance - equity) / accountStartBalance) * 100.0;
   if(dailyDD >= InpMaxDailyDD)
     {
      Print("CLEANea: Daily DD limit hit (", DoubleToString(dailyDD, 2), "%) — stopped for today");
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//|  InDeadZone                                                      |
//+------------------------------------------------------------------+
bool InDeadZone()
  {
   if(!InpUseDeadZone) return false;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(InpDeadZoneEnd == 24) return (h >= InpDeadZoneStart);
   return (h >= InpDeadZoneStart && h < InpDeadZoneEnd);
  }

//+------------------------------------------------------------------+
//|  UpdateLossTracker                                               |
//+------------------------------------------------------------------+
void UpdateLossTracker()
  {
   HistorySelect(TimeCurrent() - 7 * 86400, TimeCurrent());
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(ticket <= lastProcessedTicket) break;
      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != MAGIC) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      lastProcessedTicket = ticket;
      lastClosedTime      = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                    + HistoryDealGetDouble(ticket, DEAL_SWAP)
                    + HistoryDealGetDouble(ticket, DEAL_COMMISSION);

      if(profit < 0)
        {
         consecLosses++;
         Print("CLEANea: Loss #", consecLosses, " | P&L: $", DoubleToString(profit, 2));
         if(consecLosses >= InpMaxConsecLosses)
           {
            cooldownUntil = TimeCurrent() + InpCooldownMins * 60;
            Print("CLEANea: ", InpMaxConsecLosses, " consecutive losses — cooldown until ",
                  TimeToString(cooldownUntil));
           }
        }
      else
        {
         Print("CLEANea: Win | P&L: $", DoubleToString(profit, 2));
         consecLosses = 0;
        }
     }
  }

//+------------------------------------------------------------------+
//|  ManageBreakeven                                                 |
//+------------------------------------------------------------------+
void ManageBreakeven()
  {
   if(!InpUseBreakeven) return;
   double atr       = GetATR();
   double beTrigger = atr * InpBEMultiplier;

   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != InpSymbol || posInfo.Magic() != MAGIC) continue;

      double openPrice = posInfo.PriceOpen();
      double currentSL = posInfo.StopLoss();
      double profit    = posInfo.Profit();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
         double beTarget = openPrice + SymbolInfoDouble(InpSymbol, SYMBOL_POINT) * 2;
         if(profit >= beTrigger && (currentSL < openPrice || currentSL == 0))
            trade.PositionModify(InpSymbol, beTarget, posInfo.TakeProfit());
        }
      else
        {
         double beTarget = openPrice - SymbolInfoDouble(InpSymbol, SYMBOL_POINT) * 2;
         if(profit >= beTrigger && (currentSL > openPrice || currentSL == 0))
            trade.PositionModify(InpSymbol, beTarget, posInfo.TakeProfit());
        }
     }
  }

//+------------------------------------------------------------------+
//|  ManageTrail — FIXED: now activates before TP                   |
//|  Trail starts at 1.5x ATR, steps every 0.25x ATR               |
//|  Wide TP (4x) gives the trail room to run on big moves          |
//+------------------------------------------------------------------+
void ManageTrail()
  {
   if(!InpUseTrail) return;
   double atr        = GetATR();
   double trailStart = atr * InpTrailStartMult;   // $15 at typical ATR $10
   double trailStep  = atr * InpTrailStepMult;    // $2.50 per step

   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != InpSymbol || posInfo.Magic() != MAGIC) continue;

      double currentSL = posInfo.StopLoss();
      double profit    = posInfo.Profit();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
         double bid   = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
         double newSL = NormalizeDouble(bid - atr, symDigits);
         if(profit >= trailStart)
            if(newSL > currentSL + trailStep || currentSL == 0)
               trade.PositionModify(InpSymbol, newSL, posInfo.TakeProfit());
        }
      else
        {
         double ask   = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
         double newSL = NormalizeDouble(ask + atr, symDigits);
         if(profit >= trailStart)
            if(newSL < currentSL - trailStep || currentSL == 0)
               trade.PositionModify(InpSymbol, newSL, posInfo.TakeProfit());
        }
     }
  }

//+------------------------------------------------------------------+
//|  Dashboard                                                       |
//+------------------------------------------------------------------+
void Dashboard(string tM15, string tM5, string tH4,
               double rsi, double adx, double atr, double sl_p,
               string signal, bool canTrade, bool atZone)
  {
   string name = "CLEANea_dash";
   string txt  = StringFormat(
      " CLEANea v12 | H4:%s  M15:%s  M5:%s | RSI:%.1f  ADX:%.1f  ATR:%.2f\n"
      " SL:$%.2f  TP:$%.2f | Trail@%.1fx | Zone:%s | Signal:%s | Losses:%d/%d | %s",
      tH4, tM15, tM5, rsi, adx, atr,
      sl_p, sl_p * InpTPMultiplier,
      InpTrailStartMult,
      atZone ? "AT LEVEL" : "mid-range",
      signal == "" ? "--" : signal,
      consecLosses, InpMaxConsecLosses,
      canTrade ? "READY" : "BLOCKED"
   );

   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 20);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  9);
      ObjectSetInteger(0, name, OBJPROP_COLOR,     clrWhite);
     }
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//|  OnTick                                                          |
//+------------------------------------------------------------------+
void OnTick()
  {
   ManageBreakeven();
   ManageTrail();
   UpdateLossTracker();

   if(!IsNewBar()) return;

   double atr  = GetATR();
   double sl_p = MathMax(InpMinSL, atr * InpSLMultiplier);
   double tp_p = sl_p * InpTPMultiplier;

   string tM15 = GetTrend(hEMAFast, hEMASlow);
   string tM5  = GetTrend(hM5EMAFast, hM5EMASlow);
   string tH4  = GetH4Trend();
   double rsi  = GetRSI();
   double adx  = GetADX();

   double spread = SymbolInfoDouble(InpSymbol, SYMBOL_ASK)
                 - SymbolInfoDouble(InpSymbol, SYMBOL_BID);

   bool canTrade =
      !HasPosition()                                                 &&
      !InDeadZone()                                                  &&
      DrawdownOK()                                                   &&
      (spread  <= InpMaxSpread)                                      &&
      (adx     >= InpADXMinLevel)                                    &&
      (tM15    != "SIDE")                                            &&
      (tM5     == tM15 || tM5 == "SIDE")                            &&
      TimeCurrent() >= cooldownUntil                                 &&
      TimeCurrent() >= (lastClosedTime + InpPostCloseCooldown * 60) &&
      TerminalInfoInteger(TERMINAL_CONNECTED)                        &&
      AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)                     &&
      TerminalInfoInteger(TERMINAL_TRADE_ALLOWED);

   double currentPrice = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   string signal = "";
   bool   atZone = false;

   if(canTrade)
     {
      // BUY — H4 bull + M15 bull + RSI pullback + at H1 support zone
      if(tM15 == "BULL" && rsi >= InpRSIBuyLow && rsi <= InpRSIBuyHigh)
        {
         bool h4OK  = (tH4 == "BULL" || tH4 == "ANY");
         bool locOK = IsAtSupport(currentPrice, atr);
         atZone = locOK;
         if(h4OK && locOK) signal = "BUY";
        }
      // SELL — H4 bear + M15 bear + RSI pullback + at H1 resistance zone
      else if(tM15 == "BEAR" && rsi >= InpRSISellLow && rsi <= InpRSISellHigh)
        {
         bool h4OK  = (tH4 == "BEAR" || tH4 == "ANY");
         bool locOK = IsAtResistance(currentPrice, atr);
         atZone = locOK;
         if(h4OK && locOK) signal = "SELL";
        }
     }

   Dashboard(tM15, tM5, tH4, rsi, adx, atr, sl_p, signal, canTrade, atZone);

   if(signal == "") return;

   double ask     = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   double minDist = SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_STOPS_LEVEL)
                  * SymbolInfoDouble(InpSymbol, SYMBOL_POINT);

   if(signal == "BUY")
     {
      double sl = NormalizeDouble(ask - sl_p, symDigits);
      double tp = NormalizeDouble(ask + tp_p, symDigits);
      if(ask - sl < minDist) sl = NormalizeDouble(ask - minDist,     symDigits);
      if(tp - ask < minDist) tp = NormalizeDouble(ask + minDist * 2, symDigits);

      for(int a = 1; a <= 3; a++)
        {
         if(trade.Buy(InpLotSize, InpSymbol, ask, sl, tp, "CLEANea v12"))
           {
            Print("CLEANea v12 BUY | H4:", tH4, " RSI:", DoubleToString(rsi,1),
                  " ADX:", DoubleToString(adx,1), " Zone:H1-Support",
                  " SL:$", DoubleToString(sl_p,2), " TP:$", DoubleToString(tp_p,2));
            break;
           }
         int err = GetLastError();
         if(err != 10013 && err != 10014 && err != 10018 && err != 10004) break;
         if(a == 3) { cooldownUntil = TimeCurrent() + 600; break; }
         Sleep(500);
         ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
         sl  = NormalizeDouble(ask - sl_p, symDigits);
         tp  = NormalizeDouble(ask + tp_p, symDigits);
        }
     }
   else if(signal == "SELL")
     {
      double sl = NormalizeDouble(bid + sl_p, symDigits);
      double tp = NormalizeDouble(bid - tp_p, symDigits);
      if(sl - bid < minDist) sl = NormalizeDouble(bid + minDist,     symDigits);
      if(bid - tp < minDist) tp = NormalizeDouble(bid - minDist * 2, symDigits);

      for(int a = 1; a <= 3; a++)
        {
         if(trade.Sell(InpLotSize, InpSymbol, bid, sl, tp, "CLEANea v12"))
           {
            Print("CLEANea v12 SELL | H4:", tH4, " RSI:", DoubleToString(rsi,1),
                  " ADX:", DoubleToString(adx,1), " Zone:H1-Resistance",
                  " SL:$", DoubleToString(sl_p,2), " TP:$", DoubleToString(tp_p,2));
            break;
           }
         int err = GetLastError();
         if(err != 10013 && err != 10014 && err != 10018 && err != 10004) break;
         if(a == 3) { cooldownUntil = TimeCurrent() + 600; break; }
         Sleep(500);
         bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
         sl  = NormalizeDouble(bid + sl_p, symDigits);
         tp  = NormalizeDouble(bid - tp_p, symDigits);
        }
     }
  }

//+------------------------------------------------------------------+
//|  OnTimer — daily balance reset                                  |
//+------------------------------------------------------------------+
void OnTimer()
  {
   static datetime lastDay = 0;
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   datetime dayStart = StringToTime(StringFormat("%04d.%02d.%02d 00:00",
                                                 t.year, t.mon, t.day));
   if(dayStart != lastDay)
     {
      accountStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      lastDay = dayStart;
      Print("CLEANea: New day | Balance reset to $", DoubleToString(accountStartBalance, 2));
     }
  }
//+------------------------------------------------------------------+
