//+------------------------------------------------------------------+
//|                        CLEANea.mq5  [M15 Chart]                 |
//|              XAU/USD  v1.0  — Candle-Close Sniper               |
//|                                                                  |
//|  PHILOSOPHY                                                      |
//|  One clear edge. Three conditions. No noise.                    |
//|  Every entry waits for the M15 candle to CLOSE and confirm.    |
//|  No mid-candle firing. No scoring system. No complexity.        |
//|                                                                  |
//|  SIGNAL — 3 conditions, all must be true                        |
//|  1. EMA Trend   — M15 EMA20 vs EMA50 sets direction            |
//|                   M5  EMA20 vs EMA50 must agree                 |
//|  2. RSI Pullback — in uptrend: RSI pulled back to 38-52        |
//|                    in downtrend: RSI pulled back to 48-62       |
//|                    Buys momentum continuation, not exhaustion   |
//|  3. ADX Gate    — ADX > 20, market must be trending            |
//|                   Silences EA in flat/choppy conditions         |
//|                                                                  |
//|  ENTRY TIMING                                                    |
//|  Fires ONLY on new M15 candle close — never mid-candle          |
//|  This is the single most important fix vs previous EAs          |
//|                                                                  |
//|  RISK                                                            |
//|  SL  = ATR x InpSLMultiplier (min $1.50) — wide enough to live |
//|  TP  = SL x 2.0 — always 2:1 RR                                |
//|  Breakeven + trailing stop                                       |
//|  Daily drawdown hard stop — protects $50 account               |
//|  Loss cooldown after consecutive losses                         |
//|  Dead zone filter — no trading 22:00-00:00                     |
//|  One trade at a time. No martingale. No grid.                  |
//+------------------------------------------------------------------+
#property copyright "CLEANea"
#property version   "1.00"
#property strict

#define MAGIC 20250324

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//|  INPUTS                                                          |
//+------------------------------------------------------------------+
input group "=== SYMBOL ==="
input string  InpSymbol           = "XAUUSD";  // Trading symbol

input group "=== RISK MANAGEMENT ==="
input double  InpLotSize          = 0.01;       // Fixed lot size (use 0.01 on $50 account)
input double  InpMaxSpread        = 1.50;       // Max spread (price units)
input double  InpMaxDailyDD       = 4.0;        // Max daily drawdown % — hard stop for the day

input group "=== SL / TP ==="
input int     InpATRPeriod        = 14;         // ATR period (M15)
input double  InpSLMultiplier     = 0.25;       // SL = ATR x this — 0.25 gives Gold room to breathe
input double  InpMinSL            = 1.50;       // Min SL in $ — never tighter than this on Gold

input group "=== BREAKEVEN ==="
input bool    InpUseBreakeven     = true;       // Enable breakeven
input double  InpBEMultiplier     = 0.50;       // Move SL to entry when profit >= ATR x this

input group "=== TRAILING STOP ==="
input bool    InpUseTrail         = true;       // Enable trailing stop
input double  InpTrailStartMult   = 0.80;       // Start trailing when profit >= ATR x this
input double  InpTrailStepMult    = 0.20;       // Trail moves ATR x this per step

input group "=== LOSS PROTECTION ==="
input int     InpMaxConsecLosses  = 3;          // Losses before cooldown
input int     InpCooldownMins     = 30;         // Cooldown minutes after loss streak
input int     InpPostCloseCooldown = 20;        // Minutes to wait after ANY close before re-entering

input group "=== DEAD ZONE ==="
input bool    InpUseDeadZone      = true;       // Block low liquidity hours
input int     InpDeadZoneStart    = 22;         // Dead zone start (server hour)
input int     InpDeadZoneEnd      = 24;         // Dead zone end (24 = midnight)

input group "=== SIGNAL ==="
input int     InpEMAFast          = 20;         // M15 fast EMA
input int     InpEMASlow          = 50;         // M15 slow EMA
input int     InpM5EMAFast        = 20;         // M5 fast EMA
input int     InpM5EMASlow        = 50;         // M5 slow EMA
input int     InpRSIPeriod        = 14;         // RSI period (M15)
input double  InpRSIBuyLow        = 38.0;       // RSI floor for buy (pullback floor)
input double  InpRSIBuyHigh       = 52.0;       // RSI ceiling for buy (not overbought)
input double  InpRSISellLow       = 48.0;       // RSI floor for sell (not oversold)
input double  InpRSISellHigh      = 62.0;       // RSI ceiling for sell (pullback ceiling)
input int     InpADXPeriod        = 14;         // ADX period
input double  InpADXMinLevel      = 20.0;       // Min ADX to trade (below = flat/choppy)

//+------------------------------------------------------------------+
//|  GLOBALS                                                         |
//+------------------------------------------------------------------+
CTrade        trade;
CPositionInfo posInfo;

datetime      lastBarTime          = 0;   // Track M15 bar close — CORE of candle-close logic
double        accountStartBalance  = 0;
int           consecLosses         = 0;
datetime      cooldownUntil        = 0;
datetime      lastClosedTime       = 0;
ulong         lastProcessedTicket  = 0;
int           symDigits            = 2;

int           hEMAFast, hEMASlow;
int           hM5EMAFast, hM5EMASlow;
int           hRSI, hATR, hADX;

//+------------------------------------------------------------------+
//|  OnInit                                                          |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(MAGIC);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFillingBySymbol(InpSymbol);
   trade.SetAsyncMode(false);

   symDigits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

   // M15 indicators
   hEMAFast  = iMA(InpSymbol, PERIOD_M15, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   hEMASlow  = iMA(InpSymbol, PERIOD_M15, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   hRSI      = iRSI(InpSymbol, PERIOD_M15, InpRSIPeriod, PRICE_CLOSE);
   hATR      = iATR(InpSymbol, PERIOD_M15, InpATRPeriod);
   hADX      = iADX(InpSymbol, PERIOD_M15, InpADXPeriod);

   // M5 indicators — for trend confirmation only
   hM5EMAFast = iMA(InpSymbol, PERIOD_M5, InpM5EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   hM5EMASlow = iMA(InpSymbol, PERIOD_M5, InpM5EMASlow, 0, MODE_EMA, PRICE_CLOSE);

   if(hEMAFast==INVALID_HANDLE || hEMASlow==INVALID_HANDLE ||
      hRSI==INVALID_HANDLE     || hATR==INVALID_HANDLE      ||
      hADX==INVALID_HANDLE     || hM5EMAFast==INVALID_HANDLE ||
      hM5EMASlow==INVALID_HANDLE)
     {
      Print("CLEANea: Indicator init failed");
      return INIT_FAILED;
     }

   accountStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   EventSetTimer(60);

   Print("CLEANea initialised | Balance: $", DoubleToString(accountStartBalance, 2));
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
   ObjectsDeleteAll(0, "CLEANea_");
  }

//+------------------------------------------------------------------+
//|  IsNewBar — the core gate. Only acts on closed M15 candles.     |
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
   if(CopyBuffer(hATR, 0, 1, 1, b) < 1) return 3.0; // use closed bar [1]
   return b[0];
  }

//+------------------------------------------------------------------+
//|  GetTrend — returns "BULL", "BEAR" or "SIDE"                    |
//+------------------------------------------------------------------+
string GetTrend(int hFast, int hSlow, ENUM_TIMEFRAMES tf)
  {
   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   // Read bar [1] — the just-closed candle, not the forming one
   if(CopyBuffer(hFast, 0, 1, 2, fast) < 2) return "SIDE";
   if(CopyBuffer(hSlow, 0, 1, 2, slow) < 2) return "SIDE";

   bool bullNow  = fast[0] > slow[0];
   bool bullPrev = fast[1] > slow[1];
   bool bearNow  = fast[0] < slow[0];
   bool bearPrev = fast[1] < slow[1];

   if(bullNow && bullPrev) return "BULL";
   if(bearNow && bearPrev) return "BEAR";
   return "SIDE"; // crossing — skip
  }

//+------------------------------------------------------------------+
//|  GetRSI — reads closed candle [1]                               |
//+------------------------------------------------------------------+
double GetRSI()
  {
   double b[]; ArraySetAsSeries(b, true);
   if(CopyBuffer(hRSI, 0, 1, 1, b) < 1) return 50.0;
   return b[0];
  }

//+------------------------------------------------------------------+
//|  GetADX — reads closed candle [1]                               |
//+------------------------------------------------------------------+
double GetADX()
  {
   double b[]; ArraySetAsSeries(b, true);
   if(CopyBuffer(hADX, 0, 1, 1, b) < 1) return 0.0;
   return b[0];
  }

//+------------------------------------------------------------------+
//|  HasPosition                                                     |
//+------------------------------------------------------------------+
bool HasPosition()
  {
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == InpSymbol && posInfo.Magic() == MAGIC)
            return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|  DrawdownOK — daily hard stop                                   |
//+------------------------------------------------------------------+
bool DrawdownOK()
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   // Daily drawdown from today's start balance
   double dailyDD = ((accountStartBalance - equity) / accountStartBalance) * 100.0;
   if(dailyDD >= InpMaxDailyDD)
     {
      Print("CLEANea: Daily DD limit hit (", DoubleToString(dailyDD, 2), "%) — no new trades today");
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//|  InDeadZone                                                     |
//+------------------------------------------------------------------+
bool InDeadZone()
  {
   if(!InpUseDeadZone) return false;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   if(InpDeadZoneEnd == 24)
      return (h >= InpDeadZoneStart);
   return (h >= InpDeadZoneStart && h < InpDeadZoneEnd);
  }

//+------------------------------------------------------------------+
//|  UpdateLossTracker — detects closed positions and counts losses  |
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
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT) continue;

      lastProcessedTicket = ticket;
      lastClosedTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
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
   double atr = GetATR();
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
   double atr       = GetATR();
   double trailStart = atr * InpTrailStartMult;
   double trailStep  = atr * InpTrailStepMult;
   double point      = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);

   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != InpSymbol || posInfo.Magic() != MAGIC) continue;

      double openPrice  = posInfo.PriceOpen();
      double currentSL  = posInfo.StopLoss();
      double profit     = posInfo.Profit();

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
//|  Dashboard — simple chart overlay                               |
//+------------------------------------------------------------------+
void Dashboard(string trend15, string trendM5, double rsi, double adx,
               double atr, double sl_p, string signal, bool canTrade)
  {
   string name = "CLEANea_dash";
   string txt  = StringFormat(
      " CLEANea | M15:%s  M5:%s | RSI:%.1f  ADX:%.1f  ATR:%.2f\n"
      " SL:$%.2f  TP:$%.2f | Signal:%s | Losses:%d | %s",
      trend15, trendM5, rsi, adx, atr,
      sl_p, sl_p * 2.0,
      signal == "" ? "—" : signal,
      consecLosses,
      canTrade ? "READY" : "BLOCKED"
   );

   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 20);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
     }
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//|  OnTick                                                          |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Always run position management on every tick
   ManageBreakeven();
   ManageTrail();

   // Update loss tracker on every tick (lightweight)
   UpdateLossTracker();

   // ── CANDLE CLOSE GATE ─────────────────────────────────────────
   // Everything below this line only runs when a new M15 bar opens
   // i.e. the previous candle just closed and confirmed
   if(!IsNewBar()) return;

   // ── READ CLOSED CANDLE DATA ───────────────────────────────────
   double atr    = GetATR();
   double sl_p   = MathMax(InpMinSL, atr * InpSLMultiplier);
   double tp_p   = sl_p * 2.0;

   string tM15   = GetTrend(hEMAFast,   hEMASlow,   PERIOD_M15);
   string tM5    = GetTrend(hM5EMAFast, hM5EMASlow, PERIOD_M5);
   double rsi    = GetRSI();
   double adx    = GetADX();

   // ── GATES ─────────────────────────────────────────────────────
   double spread = SymbolInfoDouble(InpSymbol, SYMBOL_ASK) - SymbolInfoDouble(InpSymbol, SYMBOL_BID);

   bool canTrade =
      !HasPosition()                                                    &&
      !InDeadZone()                                                     &&
      DrawdownOK()                                                      &&
      (spread <= InpMaxSpread)                                          &&
      (adx >= InpADXMinLevel)                                           && // trend strength gate
      (tM15 != "SIDE")                                                  && // must have M15 direction
      (tM5 == tM15 || tM5 == "SIDE")                                   && // M5 must agree or neutral
      TimeCurrent() >= cooldownUntil                                    &&
      TimeCurrent() >= (lastClosedTime + InpPostCloseCooldown * 60)    &&
      TerminalInfoInteger(TERMINAL_CONNECTED)                           &&
      AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)                        &&
      TerminalInfoInteger(TERMINAL_TRADE_ALLOWED);

   // ── SIGNAL ────────────────────────────────────────────────────
   string signal = "";

   if(canTrade)
     {
      // BUY: uptrend confirmed, RSI pulled back into range (not overbought)
      if(tM15 == "BULL" && rsi >= InpRSIBuyLow && rsi <= InpRSIBuyHigh)
         signal = "BUY";

      // SELL: downtrend confirmed, RSI pulled back into range (not oversold)
      else if(tM15 == "BEAR" && rsi >= InpRSISellLow && rsi <= InpRSISellHigh)
         signal = "SELL";
     }

   // Dashboard always updates
   Dashboard(tM15, tM5, rsi, adx, atr, sl_p, signal, canTrade);

   if(signal == "") return;

   // ── EXECUTE ───────────────────────────────────────────────────
   double ask   = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   double minDist = SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_STOPS_LEVEL)
                  * SymbolInfoDouble(InpSymbol, SYMBOL_POINT);

   if(signal == "BUY")
     {
      double sl = NormalizeDouble(ask - sl_p, symDigits);
      double tp = NormalizeDouble(ask + tp_p, symDigits);
      // Enforce broker minimum distance
      if(ask - sl < minDist) sl = NormalizeDouble(ask - minDist, symDigits);
      if(tp - ask < minDist) tp = NormalizeDouble(ask + minDist * 2, symDigits);

      for(int a = 1; a <= 3; a++)
        {
         if(trade.Buy(InpLotSize, InpSymbol, ask, sl, tp, "CLEANea"))
           {
            Print("CLEANea BUY | RSI:", DoubleToString(rsi, 1),
                  " ADX:", DoubleToString(adx, 1),
                  " Trend:", tM15, "/", tM5,
                  " SL:$", DoubleToString(sl_p, 2),
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
      if(sl - bid < minDist) sl = NormalizeDouble(bid + minDist, symDigits);
      if(bid - tp < minDist) tp = NormalizeDouble(bid - minDist * 2, symDigits);

      for(int a = 1; a <= 3; a++)
        {
         if(trade.Sell(InpLotSize, InpSymbol, bid, sl, tp, "CLEANea"))
           {
            Print("CLEANea SELL | RSI:", DoubleToString(rsi, 1),
                  " ADX:", DoubleToString(adx, 1),
                  " Trend:", tM15, "/", tM5,
                  " SL:$", DoubleToString(sl_p, 2),
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
   datetime dayStart = StringToTime(StringFormat("%04d.%02d.%02d 00:00", t.year, t.mon, t.day));
   if(dayStart != lastDay)
     {
      accountStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      lastDay = dayStart;
      Print("CLEANea: New day | Balance reset to $", DoubleToString(accountStartBalance, 2));
     }
  }
//+------------------------------------------------------------------+
