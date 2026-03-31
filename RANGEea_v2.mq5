//+------------------------------------------------------------------+
//|                       RANGEea v2.mq5  [M15 Chart]               |
//|           XAU/USD — Asian Session Range Breakout                 |
//|                                                                  |
//|  PHILOSOPHY                                                      |
//|  Gold consolidates during the Asian session (00:00-06:00).      |
//|  Institutions accumulate orders against that range, then        |
//|  London open breaks one side to hunt stops and set the day's    |
//|  directional bias. This EA captures that first clean break.     |
//|                                                                  |
//|  SIGNAL — structural, not indicator-based                       |
//|  1. Asian Range — high/low of 00:00-05:59 M15 bars             |
//|  2. Range must be compressed (0.5–4.0 × ATR)                   |
//|  3. First M15 candle CLOSE beyond range + buffer = entry        |
//|                                                                  |
//|  TIMING                                                          |
//|  Only trades 06:00–10:00 server time (London open window)       |
//|  One trade per day — Asian range consumed once it breaks        |
//|                                                                  |
//|  RISK                                                            |
//|  SL anchored to opposite Asian range boundary + ATR buffer      |
//|  TP = SL × 2.0 — always 2:1 RR                                 |
//|  Breakeven + trailing stop                                       |
//|  Daily drawdown hard stop                                        |
//|  Loss cooldown after consecutive losses                          |
//|  One trade at a time. No martingale. No grid.                   |
//|                                                                  |
//|  v2 CHANGES vs v1                                                |
//|  FIX 1 — CalcAsianRange now uses bar-index loop (bars 1..N)     |
//|    instead of CopyRates datetime range. The old CopyRates call  |
//|    used an inclusive stop_time of exactly 06:00:00, causing the |
//|    current (just-opened) 06:00 bar to be included. Its high ≈   |
//|    market price ≈ 05:45 close, inflating asianHigh to the exact |
//|    breakout level and making the signal condition structurally   |
//|    impossible at 06:00. All subsequent bars were then blocked   |
//|    because the inflated range also failed RangeIsValid.          |
//|  FIX 2 — InpMaxRangeMult default raised 2.5 → 4.0              |
//|    XAUUSD M15 ATR is ~$4-8 while the 6-hour Asian session range |
//|    is routinely $10-25. The old 2.5× cap rejected nearly every  |
//|    session as "already moved", starving the EA of entries.       |
//|  FIX 3 — Removed TERMINAL_CONNECTED / TERMINAL_TRADE_ALLOWED   |
//|    from canTrade gate. These are unreliable in Strategy Tester  |
//|    and redundant — CTrade already validates broker connectivity. |
//|  FIX 4 — Breakeven/Trail now compare price distance not P&L     |
//|    The old code compared posInfo.Profit() (account currency) to |
//|    atr * multiplier (price units). For a EUR-denominated account |
//|    trading XAUUSD, these are in different units and scale with   |
//|    lot size. Now using price-based open-price distance.          |
//|  FIX 5 — InpMaxSpread default raised 1.5 → 3.0                 |
//|    Gold spread on Fusion Markets can momentarily spike to $1-2  |
//|    at the opening tick of London-hour bars. The old 1.50 limit  |
//|    was blocking all entries on spread spikes.                    |
//+------------------------------------------------------------------+
#property copyright "RANGEea"
#property version   "2.00"
#property strict

#define MAGIC 20250327

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//|  INPUTS                                                          |
//+------------------------------------------------------------------+
input group "=== SYMBOL ==="
input string  InpSymbol            = "XAUUSD";  // Trading symbol

input group "=== RISK MANAGEMENT ==="
input double  InpLotSize           = 0.01;   // Fixed lot size
input double  InpMaxSpread         = 3.00;   // Max spread (price units) — was 1.5, now 3.0
input double  InpMaxDailyDD        = 4.0;    // Max daily drawdown % — hard stop

input group "=== ATR ==="
input int     InpATRPeriod         = 14;     // ATR period (M15)

input group "=== ASIAN SESSION (server hours) ==="
input int     InpAsianStart        = 0;      // Asian range build start (hour)
input int     InpAsianEnd          = 6;      // Asian range close / London open (hour)
input int     InpLondonEnd         = 10;     // London window close — no entries after this

input group "=== RANGE VALIDITY ==="
input double  InpMinRangeMult      = 0.5;    // Min range = ATR × this (rejects dead sessions)
input double  InpMaxRangeMult      = 4.0;    // Max range = ATR × this — was 2.5, now 4.0

input group "=== ENTRY ==="
input double  InpBreakoutBuffer    = 0.20;   // Close must be ATR × this beyond range boundary

input group "=== SL / TP ==="
input double  InpSLBuffer          = 0.30;   // SL placed ATR × this beyond opposite range boundary
input double  InpMinSL             = 2.00;   // Minimum SL in price units

input group "=== BREAKEVEN ==="
input bool    InpUseBreakeven      = true;   // Enable breakeven
input double  InpBEMultiplier      = 0.75;   // Move SL to entry when price moves ATR × this from open

input group "=== TRAILING STOP ==="
input bool    InpUseTrail          = true;   // Enable trailing stop
input double  InpTrailStartMult    = 1.50;   // Start trailing when price moves ATR × this from open
input double  InpTrailStepMult     = 0.30;   // Trail step ATR × this

input group "=== LOSS PROTECTION ==="
input int     InpMaxConsecLosses   = 3;      // Losses before cooldown
input int     InpCooldownMins      = 60;     // Cooldown minutes after loss streak
input int     InpPostCloseCooldown = 5;      // Minutes to wait after any close before re-entering

//+------------------------------------------------------------------+
//|  GLOBALS                                                         |
//+------------------------------------------------------------------+
CTrade        trade;
CPositionInfo posInfo;

datetime      lastBarTime          = 0;
double        accountStartBalance  = 0;
int           consecLosses         = 0;
datetime      cooldownUntil        = 0;
datetime      lastClosedTime       = 0;
ulong         lastProcessedTicket  = 0;
int           symDigits            = 2;

// Asian range state — reset every trading day
double        asianHigh            = 0;
double        asianLow             = 0;
bool          rangeReady           = false;
bool          tradeFiredToday      = false;
datetime      currentTradeDate     = 0;

int           hATR;

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

   hATR = iATR(InpSymbol, PERIOD_M15, InpATRPeriod);
   if(hATR == INVALID_HANDLE)
     {
      Print("RANGEea: ATR indicator init failed");
      return INIT_FAILED;
     }

   accountStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   EventSetTimer(60);

   Print("RANGEea v2 initialised | Balance: $", DoubleToString(accountStartBalance, 2),
         " | Asian window: ", InpAsianStart, ":00-", InpAsianEnd, ":00",
         " | London window: ", InpAsianEnd, ":00-", InpLondonEnd, ":00",
         " | MaxRangeMult: ", InpMaxRangeMult, "x ATR");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//|  OnDeinit                                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   IndicatorRelease(hATR);
   ObjectsDeleteAll(0, "RANGEea_");
  }

//+------------------------------------------------------------------+
//|  IsNewBar — gate on closed M15 candles only                     |
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
//|  GetATR — reads closed candle [1]                               |
//+------------------------------------------------------------------+
double GetATR()
  {
   double b[]; ArraySetAsSeries(b, true);
   if(CopyBuffer(hATR, 0, 1, 1, b) < 1) return 5.0;   // safe fallback for XAUUSD
   if(b[0] <= 0) return 5.0;
   return b[0];
  }

//+------------------------------------------------------------------+
//|  GetCurrentHour — server time hour                              |
//+------------------------------------------------------------------+
int GetCurrentHour()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return dt.hour;
  }

//+------------------------------------------------------------------+
//|  GetDayStart — returns today 00:00:00 server time               |
//+------------------------------------------------------------------+
datetime GetDayStart()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
  }

//+------------------------------------------------------------------+
//|  IsLondonWindow — true during 06:00-10:00 server time           |
//+------------------------------------------------------------------+
bool IsLondonWindow()
  {
   int h = GetCurrentHour();
   return (h >= InpAsianEnd && h < InpLondonEnd);
  }

//+------------------------------------------------------------------+
//|  CalcAsianRange                                                  |
//|                                                                  |
//|  FIX v2: Uses bar-index loop instead of CopyRates datetime range.|
//|                                                                  |
//|  v1 BUG: CopyRates(sym, M15, dayStart, asianClose, rates) uses  |
//|  an INCLUSIVE stop_time. When asianClose = 06:00:00 exactly, MT5 |
//|  includes the bar whose open_time == 06:00:00 — the current     |
//|  (partially-formed) bar. Its high ≈ low ≈ open ≈ close of       |
//|  the 05:45 bar, so asianHigh gets inflated to the exact current  |
//|  price. Then the signal check                                    |
//|    iClose(M15, 1) > asianHigh + buffer                           |
//|  becomes: close_of_05:45 > close_of_05:45 + buffer → ALWAYS     |
//|  FALSE. Zero entries result.                                     |
//|                                                                  |
//|  v2 FIX: Iterate bar indices 1..asianBars (bar[1]=05:45 down to |
//|  bar[asianBars]=00:00), which are ALL closed bars. The current   |
//|  06:00 bar (index 0) is never touched.                           |
//+------------------------------------------------------------------+
bool CalcAsianRange()
  {
   // Number of completed M15 bars in the Asian session
   // e.g. InpAsianEnd=6 → 6h × 4 bars/h = 24 bars (00:00 .. 05:45)
   int asianBars = InpAsianEnd * 4;
   if(asianBars <= 0) return false;

   double hi = -DBL_MAX;
   double lo =  DBL_MAX;

   for(int i = 1; i <= asianBars; i++)
     {
      double h = iHigh(InpSymbol, PERIOD_M15, i);
      double l = iLow (InpSymbol, PERIOD_M15, i);
      if(h <= 0 || l <= 0 || l >= h)
        {
         Print("RANGEea: Bad bar data at index ", i, " (h=", h, " l=", l, ") — skipping");
         continue;
        }
      if(h > hi) hi = h;
      if(l < lo) lo = l;
     }

   if(hi == -DBL_MAX || lo == DBL_MAX)
     {
      Print("RANGEea: CalcAsianRange — no valid bars found");
      return false;
     }

   asianHigh = NormalizeDouble(hi, symDigits);
   asianLow  = NormalizeDouble(lo, symDigits);

   Print("RANGEea: Asian range set | High:", DoubleToString(asianHigh, symDigits),
         " Low:", DoubleToString(asianLow, symDigits),
         " Range:", DoubleToString(asianHigh - asianLow, symDigits),
         " (", asianBars, " M15 bars, bar-index method)");
   return true;
  }

//+------------------------------------------------------------------+
//|  RangeIsValid — rejects dead and already-broken sessions        |
//+------------------------------------------------------------------+
bool RangeIsValid(double atr)
  {
   if(asianHigh <= 0 || asianLow <= 0) return false;
   double range = asianHigh - asianLow;
   if(range < InpMinRangeMult * atr)
     {
      Print("RANGEea: Range too small (", DoubleToString(range, 2),
            " < ", DoubleToString(InpMinRangeMult * atr, 2), ") — dead session, skip");
      return false;
     }
   if(range > InpMaxRangeMult * atr)
     {
      Print("RANGEea: Range too large (", DoubleToString(range, 2),
            " > ", DoubleToString(InpMaxRangeMult * atr, 2), ") — session too volatile, skip");
      return false;
     }
   return true;
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
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyDD = ((accountStartBalance - equity) / accountStartBalance) * 100.0;
   if(dailyDD >= InpMaxDailyDD)
     {
      Print("RANGEea: Daily DD limit hit (", DoubleToString(dailyDD, 2), "%) — no new trades today");
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//|  SpreadOK                                                        |
//+------------------------------------------------------------------+
bool SpreadOK()
  {
   double spread = SymbolInfoDouble(InpSymbol, SYMBOL_ASK) - SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   return (spread <= InpMaxSpread);
  }

//+------------------------------------------------------------------+
//|  UpdateLossTracker — scans closed deals for this EA             |
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
         Print("RANGEea: Loss #", consecLosses, " | P&L: $", DoubleToString(profit, 2));
         if(consecLosses >= InpMaxConsecLosses)
           {
            cooldownUntil = TimeCurrent() + InpCooldownMins * 60;
            Print("RANGEea: Cooldown until ", TimeToString(cooldownUntil));
           }
        }
      else
        {
         Print("RANGEea: Win | P&L: $", DoubleToString(profit, 2));
         consecLosses = 0;
        }
     }
  }

//+------------------------------------------------------------------+
//|  ManageBreakeven                                                 |
//|                                                                  |
//|  FIX v2: Trigger now uses price distance from open, not P&L.    |
//|  v1 compared posInfo.Profit() [account currency] to             |
//|  atr * InpBEMultiplier [price units]. For a EUR account, these  |
//|  are in different units and break at non-0.01 lot sizes.         |
//+------------------------------------------------------------------+
void ManageBreakeven()
  {
   if(!InpUseBreakeven) return;
   double atr       = GetATR();
   double beTrigger = atr * InpBEMultiplier;   // price-units distance from open
   double point     = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);

   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != InpSymbol || posInfo.Magic() != MAGIC) continue;

      double openPrice = posInfo.PriceOpen();
      double currentSL = posInfo.StopLoss();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
         double bid      = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
         double priceDist = bid - openPrice;          // how far price has moved from open
         double beTarget  = NormalizeDouble(openPrice + point * 2, symDigits);
         if(priceDist >= beTrigger && (currentSL < openPrice || currentSL == 0))
            trade.PositionModify(InpSymbol, beTarget, posInfo.TakeProfit());
        }
      else
        {
         double ask      = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
         double priceDist = openPrice - ask;
         double beTarget  = NormalizeDouble(openPrice - point * 2, symDigits);
         if(priceDist >= beTrigger && (currentSL > openPrice || currentSL == 0))
            trade.PositionModify(InpSymbol, beTarget, posInfo.TakeProfit());
        }
     }
  }

//+------------------------------------------------------------------+
//|  ManageTrail                                                     |
//|                                                                  |
//|  FIX v2: Trigger now uses price distance from open, not P&L.    |
//+------------------------------------------------------------------+
void ManageTrail()
  {
   if(!InpUseTrail) return;
   double atr        = GetATR();
   double trailStart = atr * InpTrailStartMult;    // price distance from open to start trailing
   double trailStep  = atr * InpTrailStepMult;     // minimum improvement before updating SL

   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != InpSymbol || posInfo.Magic() != MAGIC) continue;

      double openPrice = posInfo.PriceOpen();
      double currentSL = posInfo.StopLoss();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
         double bid       = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
         double priceDist = bid - openPrice;
         double newSL     = NormalizeDouble(bid - atr, symDigits);
         if(priceDist >= trailStart)
            if(newSL > currentSL + trailStep || currentSL == 0)
               trade.PositionModify(InpSymbol, newSL, posInfo.TakeProfit());
        }
      else
        {
         double ask       = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
         double priceDist = openPrice - ask;
         double newSL     = NormalizeDouble(ask + atr, symDigits);
         if(priceDist >= trailStart)
            if(newSL < currentSL - trailStep || currentSL == 0)
               trade.PositionModify(InpSymbol, newSL, posInfo.TakeProfit());
        }
     }
  }

//+------------------------------------------------------------------+
//|  Dashboard                                                       |
//+------------------------------------------------------------------+
void Dashboard(double atr, bool rangeValid, string signal, bool canTrade)
  {
   string name   = "RANGEea_dash";
   int    hour   = GetCurrentHour();
   string phase  = "";
   if(hour >= InpAsianStart && hour < InpAsianEnd)
      phase = "BUILDING RANGE";
   else if(IsLondonWindow())
      phase = "LONDON WINDOW";
   else
      phase = "INACTIVE";

   string rangeStr = rangeReady
      ? StringFormat("Hi:%.2f  Lo:%.2f  Sz:%.2f", asianHigh, asianLow, asianHigh - asianLow)
      : "NOT READY";

   string txt = StringFormat(
      " RANGEea v2 | %s | ATR:%.2f\n"
      " Asian Range: %s  Valid:%s\n"
      " Signal:%-6s | Losses:%d | Trade today:%s | %s",
      phase, atr,
      rangeStr, rangeValid ? "YES" : "NO",
      signal == "" ? "—" : signal,
      consecLosses,
      tradeFiredToday ? "YES" : "NO",
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
   // Always manage open positions and track closed deals on every tick
   ManageBreakeven();
   ManageTrail();
   UpdateLossTracker();

   // ── CANDLE CLOSE GATE ─────────────────────────────────────────
   if(!IsNewBar()) return;

   // ── DAILY STATE RESET ─────────────────────────────────────────
   datetime dayStart = GetDayStart();
   if(dayStart != currentTradeDate)
     {
      currentTradeDate = dayStart;
      tradeFiredToday  = false;
      rangeReady       = false;
      asianHigh        = 0;
      asianLow         = 0;
      Print("RANGEea: New day started — range and trade state reset");
     }

   // ── CALCULATE ASIAN RANGE (once, at London open hour) ─────────
   // Triggered on the first new bar at or after InpAsianEnd.
   // Uses bar-index method — see CalcAsianRange() for full notes.
   if(!rangeReady && GetCurrentHour() >= InpAsianEnd)
     {
      rangeReady = CalcAsianRange();
     }

   // ── GATE EVALUATION ───────────────────────────────────────────
   double atr      = GetATR();
   bool   rangeVal = RangeIsValid(atr);

   // FIX v2: Removed TerminalInfoInteger(TERMINAL_CONNECTED) and
   // TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) from canTrade.
   // These can return false inside Strategy Tester (offline simulation)
   // even when the terminal is connected, silently blocking all trades.
   // CTrade already validates connectivity before placing orders.
   bool canTrade =
      rangeReady                                                     &&
      rangeVal                                                       &&
      !tradeFiredToday                                               &&
      !HasPosition()                                                 &&
      IsLondonWindow()                                               &&
      DrawdownOK()                                                   &&
      SpreadOK()                                                     &&
      TimeCurrent() >= cooldownUntil                                 &&
      TimeCurrent() >= (lastClosedTime + InpPostCloseCooldown * 60) &&
      AccountInfoInteger(ACCOUNT_TRADE_ALLOWED);

   // ── SIGNAL ────────────────────────────────────────────────────
   string signal = "";

   if(canTrade)
     {
      double bufferDist = InpBreakoutBuffer * atr;
      double closedBar  = iClose(InpSymbol, PERIOD_M15, 1); // confirmed closed candle

      if(closedBar > asianHigh + bufferDist)
         signal = "BUY";
      else if(closedBar < asianLow - bufferDist)
         signal = "SELL";
     }

   // Dashboard always updates (visible even when blocked)
   Dashboard(atr, rangeVal, signal, canTrade);

   if(signal == "") return;

   // ── EXECUTE ───────────────────────────────────────────────────
   double ask     = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   double minDist = SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_STOPS_LEVEL)
                  * SymbolInfoDouble(InpSymbol, SYMBOL_POINT);

   if(signal == "BUY")
     {
      double slDist = MathMax(InpMinSL, ask - (asianLow - InpSLBuffer * atr));
      double tpDist = slDist * 2.0;
      double sl     = NormalizeDouble(ask - slDist, symDigits);
      double tp     = NormalizeDouble(ask + tpDist, symDigits);
      if(ask - sl < minDist) sl = NormalizeDouble(ask - minDist, symDigits);
      if(tp - ask < minDist) tp = NormalizeDouble(ask + minDist * 2, symDigits);

      for(int a = 1; a <= 3; a++)
        {
         if(trade.Buy(InpLotSize, InpSymbol, ask, sl, tp, "RANGEea"))
           {
            Print("RANGEea BUY | AH:", DoubleToString(asianHigh, 2),
                  " AL:", DoubleToString(asianLow, 2),
                  " Entry:", DoubleToString(ask, 2),
                  " SL:", DoubleToString(sl, 2),
                  " TP:", DoubleToString(tp, 2),
                  " SLdist:", DoubleToString(slDist, 2));
            tradeFiredToday = true;
            break;
           }
         int err = GetLastError();
         Print("RANGEea BUY attempt ", a, " failed | Error:", err);
         if(err != 10013 && err != 10014 && err != 10018 && err != 10004) break;
         if(a == 3) { cooldownUntil = TimeCurrent() + 600; break; }
         Sleep(500);
         ask    = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
         slDist = MathMax(InpMinSL, ask - (asianLow - InpSLBuffer * atr));
         tpDist = slDist * 2.0;
         sl     = NormalizeDouble(ask - slDist, symDigits);
         tp     = NormalizeDouble(ask + tpDist, symDigits);
        }
     }
   else if(signal == "SELL")
     {
      double slDist = MathMax(InpMinSL, (asianHigh + InpSLBuffer * atr) - bid);
      double tpDist = slDist * 2.0;
      double sl     = NormalizeDouble(bid + slDist, symDigits);
      double tp     = NormalizeDouble(bid - tpDist, symDigits);
      if(sl - bid < minDist) sl = NormalizeDouble(bid + minDist, symDigits);
      if(bid - tp < minDist) tp = NormalizeDouble(bid - minDist * 2, symDigits);

      for(int a = 1; a <= 3; a++)
        {
         if(trade.Sell(InpLotSize, InpSymbol, bid, sl, tp, "RANGEea"))
           {
            Print("RANGEea SELL | AH:", DoubleToString(asianHigh, 2),
                  " AL:", DoubleToString(asianLow, 2),
                  " Entry:", DoubleToString(bid, 2),
                  " SL:", DoubleToString(sl, 2),
                  " TP:", DoubleToString(tp, 2),
                  " SLdist:", DoubleToString(slDist, 2));
            tradeFiredToday = true;
            break;
           }
         int err = GetLastError();
         Print("RANGEea SELL attempt ", a, " failed | Error:", err);
         if(err != 10013 && err != 10014 && err != 10018 && err != 10004) break;
         if(a == 3) { cooldownUntil = TimeCurrent() + 600; break; }
         Sleep(500);
         bid    = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
         slDist = MathMax(InpMinSL, (asianHigh + InpSLBuffer * atr) - bid);
         tpDist = slDist * 2.0;
         sl     = NormalizeDouble(bid + slDist, symDigits);
         tp     = NormalizeDouble(bid - tpDist, symDigits);
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
      Print("RANGEea: New day | Balance reset to $", DoubleToString(accountStartBalance, 2));
     }
  }
//+------------------------------------------------------------------+
