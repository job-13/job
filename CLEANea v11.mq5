//+------------------------------------------------------------------+
//|                        CLEANea.mq5  [M15 Chart]                 |
//|              XAU/USD  v11.0  — Structure-Aware Trend Sniper     |
//|                                                                  |
//|  PHILOSOPHY                                                      |
//|  Structure → Confirmation → Enter. Never the reverse.           |
//|  Every entry needs THREE layers of agreement:                   |
//|    1. H4 macro trend sets the direction (no counter-trend)      |
//|    2. M15 EMA + RSI + ADX confirms momentum at that level       |
//|    3. Price must be AT a swing S/R zone — not mid-range         |
//|                                                                  |
//|  ANTI-OVERFITTING GUARDS                                        |
//|  - EMAFast < EMASlow enforced at init (blocks inverted cross)   |
//|  - RSI inputs clamped 0-100 at init (blocks impossible values)  |
//|  - H4 filter cannot be gamed by M15-only optimisation           |
//|  - Swing zones require structural confluence, not curve-fit      |
//|                                                                  |
//|  SIGNAL — all layers must agree                                 |
//|  1. H4 trend (price vs H4 EMA) sets macro direction             |
//|  2. M15 EMA trend matches H4 direction                          |
//|  3. M5 EMA trend agrees or is neutral                           |
//|  4. RSI in pullback zone (38-52 buy, 48-62 sell)               |
//|  5. ADX > 20 (trending, not choppy)                             |
//|  6. Price is inside a swing S/R zone                            |
//|                                                                  |
//|  ENTRY TIMING                                                    |
//|  Fires ONLY on new M15 candle close — never mid-candle          |
//|                                                                  |
//|  RISK                                                            |
//|  SL  = ATR x InpSLMultiplier (min $4.05)                       |
//|  TP  = SL x 2.0 — always 2:1 RR                                |
//|  Trailing after 5.92x ATR profit — catches trending moves       |
//|  Daily drawdown hard stop. Loss cooldown. One trade at a time.  |
//+------------------------------------------------------------------+
#property copyright "CLEANea v11"
#property version   "11.00"
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
input double  InpMaxDailyDD       = 4.0;        // Max daily drawdown %

input group "=== SL / TP ==="
input int     InpATRPeriod        = 70;          // ATR period — wider = less noise
input double  InpSLMultiplier     = 0.875;       // SL = ATR x this
input double  InpMinSL            = 4.05;        // Min SL in $ — survives Gold volatility

input group "=== BREAKEVEN ==="
input bool    InpUseBreakeven     = true;
input double  InpBEMultiplier     = 0.65;        // Move to BE when profit >= ATR x this

input group "=== TRAILING STOP ==="
input bool    InpUseTrail         = true;
input double  InpTrailStartMult   = 5.92;        // Start trailing when profit >= ATR x this
input double  InpTrailStepMult    = 1.0;         // Trail step = ATR x this (1 ATR per step)

input group "=== LOSS PROTECTION ==="
input int     InpMaxConsecLosses  = 11;
input int     InpCooldownMins     = 134;
input int     InpPostCloseCooldown = 21;

input group "=== DEAD ZONE ==="
input bool    InpUseDeadZone      = true;
input int     InpDeadZoneStart    = 22;
input int     InpDeadZoneEnd      = 24;

input group "=== H4 TREND FILTER ==="
input bool    InpUseH4Filter      = true;        // Require H4 agreement — blocks counter-trend entries
input int     InpH4EMAPeriod      = 50;          // H4 EMA period for macro trend

input group "=== SWING S/R ZONES ==="
input bool    InpUseSwingFilter   = true;        // Only trade at swing S/R zones — kills mid-range noise
input int     InpSwingLookback    = 30;          // M15 bars to scan for swing pivots
input int     InpSwingStrength    = 3;           // Bars each side confirming a pivot
input double  InpZoneWidthMult    = 1.5;         // Zone width = ATR x this

input group "=== SIGNAL ==="
input int     InpEMAFast          = 155;         // M15 fast EMA  (MUST be < InpEMASlow)
input int     InpEMASlow          = 386;         // M15 slow EMA  (macro trend — high period = no noise)
input int     InpM5EMAFast        = 149;         // M5 fast EMA
input int     InpM5EMASlow        = 240;         // M5 slow EMA
input int     InpRSIPeriod        = 57;          // RSI period
input double  InpRSIBuyLow        = 38.0;        // RSI floor for buy pullback
input double  InpRSIBuyHigh       = 52.0;        // RSI ceiling for buy pullback
input double  InpRSISellLow       = 48.0;        // RSI floor for sell pullback
input double  InpRSISellHigh      = 62.0;        // RSI ceiling for sell pullback (fixed — was 6067 in opt file)
input int     InpADXPeriod        = 14;
input double  InpADXMinLevel      = 20.0;

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

// Indicator handles
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
      Print("CLEANea ERROR: InpEMAFast (", InpEMAFast, ") must be less than InpEMASlow (",
            InpEMASlow, ") — inverted crossover detected, init rejected");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpM5EMAFast >= InpM5EMASlow)
     {
      Print("CLEANea ERROR: InpM5EMAFast (", InpM5EMAFast, ") must be less than InpM5EMASlow (",
            InpM5EMASlow, ")");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRSIBuyLow  < 0 || InpRSIBuyHigh  > 100 ||
      InpRSISellLow < 0 || InpRSISellHigh > 100)
     {
      Print("CLEANea ERROR: RSI inputs must be within 0-100. Got Buy:[",
            InpRSIBuyLow, "-", InpRSIBuyHigh, "] Sell:[",
            InpRSISellLow, "-", InpRSISellHigh, "]");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRSIBuyLow >= InpRSIBuyHigh || InpRSISellLow >= InpRSISellHigh)
     {
      Print("CLEANea ERROR: RSI low must be < RSI high");
      return INIT_PARAMETERS_INCORRECT;
     }

   trade.SetExpertMagicNumber(MAGIC);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFillingBySymbol(InpSymbol);
   trade.SetAsyncMode(false);

   symDigits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

   // M15 indicators
   hEMAFast = iMA(InpSymbol, PERIOD_M15, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   hEMASlow = iMA(InpSymbol, PERIOD_M15, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   hRSI     = iRSI(InpSymbol, PERIOD_M15, InpRSIPeriod, PRICE_CLOSE);
   hATR     = iATR(InpSymbol, PERIOD_M15, InpATRPeriod);
   hADX     = iADX(InpSymbol, PERIOD_M15, InpADXPeriod);

   // M5 confirmation EMAs
   hM5EMAFast = iMA(InpSymbol, PERIOD_M5, InpM5EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   hM5EMASlow = iMA(InpSymbol, PERIOD_M5, InpM5EMASlow, 0, MODE_EMA, PRICE_CLOSE);

   // H4 macro trend EMA
   hH4EMA = iMA(InpSymbol, PERIOD_H4, InpH4EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(hEMAFast == INVALID_HANDLE || hEMASlow == INVALID_HANDLE ||
      hRSI == INVALID_HANDLE     || hATR == INVALID_HANDLE      ||
      hADX == INVALID_HANDLE     || hM5EMAFast == INVALID_HANDLE ||
      hM5EMASlow == INVALID_HANDLE || hH4EMA == INVALID_HANDLE)
     {
      Print("CLEANea: Indicator init failed");
      return INIT_FAILED;
     }

   accountStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   EventSetTimer(60);

   Print("CLEANea v11 initialised | H4Filter:", InpUseH4Filter,
         " SwingFilter:", InpUseSwingFilter,
         " Balance:$", DoubleToString(accountStartBalance, 2));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//|  OnDeinit                                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   IndicatorRelease(hEMAFast);
   IndicatorRelease(hEMASlow);
   IndicatorRelease(hRSI);
   IndicatorRelease(hATR);
   IndicatorRelease(hADX);
   IndicatorRelease(hM5EMAFast);
   IndicatorRelease(hM5EMASlow);
   IndicatorRelease(hH4EMA);
   ObjectsDeleteAll(0, "CLEANea_");
  }

//+------------------------------------------------------------------+
//|  IsNewBar — fires only on M15 candle close                      |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime currentBar = iTime(InpSymbol, PERIOD_M15, 0);
   if(currentBar != lastBarTime)
     {
      lastBarTime = currentBar;
      return true;
     }
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
//|  GetTrend — "BULL", "BEAR" or "SIDE" from two EMA handles       |
//+------------------------------------------------------------------+
string GetTrend(int hFast, int hSlow)
  {
   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   if(CopyBuffer(hFast, 0, 1, 2, fast) < 2) return "SIDE";
   if(CopyBuffer(hSlow, 0, 1, 2, slow) < 2) return "SIDE";

   bool bullNow  = fast[0] > slow[0];
   bool bullPrev = fast[1] > slow[1];
   bool bearNow  = fast[0] < slow[0];
   bool bearPrev = fast[1] < slow[1];

   if(bullNow && bullPrev) return "BULL";
   if(bearNow && bearPrev) return "BEAR";
   return "SIDE";
  }

//+------------------------------------------------------------------+
//|  GetH4Trend — H4 close vs H4 EMA sets macro direction           |
//+------------------------------------------------------------------+
string GetH4Trend()
  {
   if(!InpUseH4Filter) return "ANY";
   double ema[], cls[];
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(cls, true);
   if(CopyBuffer(hH4EMA, 0, 1, 1, ema) < 1)             return "SIDE";
   if(CopyClose(InpSymbol, PERIOD_H4, 1, 1, cls) < 1)   return "SIDE";
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
//|  FindSwingHigh — most recent M15 pivot high in lookback window  |
//+------------------------------------------------------------------+
double FindSwingHigh()
  {
   int total = InpSwingLookback + InpSwingStrength + 1;
   double highs[];
   ArraySetAsSeries(highs, true);
   if(CopyHigh(InpSymbol, PERIOD_M15, 1, total, highs) < total)
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
//|  FindSwingLow — most recent M15 pivot low in lookback window    |
//+------------------------------------------------------------------+
double FindSwingLow()
  {
   int total = InpSwingLookback + InpSwingStrength + 1;
   double lows[];
   ArraySetAsSeries(lows, true);
   if(CopyLow(InpSymbol, PERIOD_M15, 1, total, lows) < total)
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
//|  IsAtSupport — price inside swing low zone (buy zone)           |
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
//|  IsAtResistance — price inside swing high zone (sell zone)      |
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
      Print("CLEANea: Daily DD limit hit (", DoubleToString(dailyDD, 2), "%) — no new trades today");
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
            Print("CLEANea: Cooldown until ", TimeToString(cooldownUntil));
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
//|  ManageTrail                                                     |
//+------------------------------------------------------------------+
void ManageTrail()
  {
   if(!InpUseTrail) return;
   double atr        = GetATR();
   double trailStart = atr * InpTrailStartMult;
   double trailStep  = atr * InpTrailStepMult;

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
   string zoneStr = atZone ? "YES" : "NO";
   string txt = StringFormat(
      " CLEANea v11 | H4:%s  M15:%s  M5:%s | RSI:%.1f  ADX:%.1f  ATR:%.2f\n"
      " SL:$%.2f  TP:$%.2f | Zone:%s | Signal:%s | Losses:%d | %s",
      tH4, tM15, tM5, rsi, adx, atr,
      sl_p, sl_p * 2.0,
      zoneStr,
      signal == "" ? "--" : signal,
      consecLosses,
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

   // ── CANDLE CLOSE GATE ─────────────────────────────────────────
   if(!IsNewBar()) return;

   // ── READ CLOSED CANDLE DATA ───────────────────────────────────
   double atr  = GetATR();
   double sl_p = MathMax(InpMinSL, atr * InpSLMultiplier);
   double tp_p = sl_p * 2.0;

   string tM15  = GetTrend(hEMAFast, hEMASlow);
   string tM5   = GetTrend(hM5EMAFast, hM5EMASlow);
   string tH4   = GetH4Trend();
   double rsi   = GetRSI();
   double adx   = GetADX();

   double spread = SymbolInfoDouble(InpSymbol, SYMBOL_ASK)
                 - SymbolInfoDouble(InpSymbol, SYMBOL_BID);

   // ── GATES ─────────────────────────────────────────────────────
   bool canTrade =
      !HasPosition()                                                 &&
      !InDeadZone()                                                  &&
      DrawdownOK()                                                   &&
      (spread <= InpMaxSpread)                                       &&
      (adx >= InpADXMinLevel)                                        &&
      (tM15 != "SIDE")                                               &&
      (tM5 == tM15 || tM5 == "SIDE")                                &&
      TimeCurrent() >= cooldownUntil                                 &&
      TimeCurrent() >= (lastClosedTime + InpPostCloseCooldown * 60) &&
      TerminalInfoInteger(TERMINAL_CONNECTED)                        &&
      AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)                     &&
      TerminalInfoInteger(TERMINAL_TRADE_ALLOWED);

   // ── STRUCTURE → CONFIRMATION → ENTER ─────────────────────────
   double currentPrice = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   string signal  = "";
   bool   atZone  = false;

   if(canTrade)
     {
      // ── BUY ──
      // Structure:     H4 is bullish (macro trend up)
      // Confirmation:  M15 BULL trend + RSI in pullback zone + ADX already checked
      // Location:      Price is at or near a swing low (support zone)
      if(tM15 == "BULL" && rsi >= InpRSIBuyLow && rsi <= InpRSIBuyHigh)
        {
         bool h4OK  = (tH4 == "BULL" || tH4 == "ANY");
         bool locOK = IsAtSupport(currentPrice, atr);
         atZone = locOK;
         if(h4OK && locOK) signal = "BUY";
        }

      // ── SELL ──
      // Structure:     H4 is bearish (macro trend down)
      // Confirmation:  M15 BEAR trend + RSI in pullback zone + ADX already checked
      // Location:      Price is at or near a swing high (resistance zone)
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

   // ── EXECUTE ───────────────────────────────────────────────────
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
         if(trade.Buy(InpLotSize, InpSymbol, ask, sl, tp, "CLEANea v11"))
           {
            Print("CLEANea BUY | H4:", tH4, " M15:", tM15,
                  " RSI:", DoubleToString(rsi, 1),
                  " ADX:", DoubleToString(adx, 1),
                  " Zone:YES SL:$", DoubleToString(sl_p, 2),
                  " TP:$", DoubleToString(tp_p, 2));
            break;
           }
         int err = GetLastError();
         Print("CLEANea BUY attempt ", a, " failed | Error:", err);
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
         if(trade.Sell(InpLotSize, InpSymbol, bid, sl, tp, "CLEANea v11"))
           {
            Print("CLEANea SELL | H4:", tH4, " M15:", tM15,
                  " RSI:", DoubleToString(rsi, 1),
                  " ADX:", DoubleToString(adx, 1),
                  " Zone:YES SL:$", DoubleToString(sl_p, 2),
                  " TP:$", DoubleToString(tp_p, 2));
            break;
           }
         int err = GetLastError();
         Print("CLEANea SELL attempt ", a, " failed | Error:", err);
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
      Print("CLEANea: New day | Balance reset to $",
            DoubleToString(accountStartBalance, 2));
     }
  }
//+------------------------------------------------------------------+
