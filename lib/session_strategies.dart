import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watbal/scraper_service.dart';

/// =============================================================================
/// SESSION-LIVENESS STRATEGIES
/// =============================================================================
/// TouchNet OneWeb uses ASP.NET Forms Auth with a sliding `.ASPXAUTH` cookie —
/// there is no refresh token. Every authenticated request resets the sliding
/// window. The server's own `/Layout/KeepAlive` endpoint exists specifically
/// to do this cheaply.
///
/// To switch strategies, change [kActiveStrategy] below and restart the app.
/// Each option documents its trade-offs.
///
/// Reporting back? Note which strategy was active + roughly how long the
/// session held before the next forced re-login.
/// =============================================================================

enum SessionStrategy {
  /// The pre-existing behaviour. Only the background task (every ~30 min on
  /// iOS, throttled by the OS) does anything. No foreground keep-alive.
  ///
  /// Falls back here if you want to confirm a different strategy actually
  /// helped vs placebo.
  original,

  /// **RECOMMENDED — try this first.**
  /// While app is open: ping `/Layout/KeepAlive` every 3 minutes (one small
  /// POST, ~1 KB). When app is backgrounded: tighten the background task to
  /// 15 min and have it call [ScraperService.keepAlive] instead of the full
  /// [ScraperService.fetchBalance] — fewer requests, less likely to timeout
  /// in iOS's tiny background-execution window.
  ///
  /// Periodically (every 4th ping ≈ 12 min) it still does a full
  /// `fetchBalance` so the widget stays fresh.
  foregroundTicker,

  /// 60-second foreground ticker, 10-min background. Maximum liveness while
  /// the app is open; noticeably more battery + network. Try if
  /// [foregroundTicker] still expires.
  ultraAggressive,

  /// No ticker; one ping each time the app enters foreground (`resumed`
  /// lifecycle event). Lowest battery cost, but no protection while the app
  /// sits open and idle for hours.
  resumeOnly,
}

/// >>> CHANGE THIS LINE TO SWITCH STRATEGIES <<<
const SessionStrategy kActiveStrategy = SessionStrategy.foregroundTicker;

/// How often the foreground ticker fires for each strategy. `null` means no
/// ticker (the strategy handles itself differently or does nothing in
/// foreground).
Duration? foregroundInterval(SessionStrategy s) {
  switch (s) {
    case SessionStrategy.foregroundTicker:
      return const Duration(minutes: 3);
    case SessionStrategy.ultraAggressive:
      return const Duration(seconds: 60);
    case SessionStrategy.original:
    case SessionStrategy.resumeOnly:
      return null;
  }
}

/// How often the background WorkManager task reschedules itself. iOS may run
/// it later than this — the OS still has final say.
Duration backgroundInterval(SessionStrategy s) {
  switch (s) {
    case SessionStrategy.original:
      return const Duration(minutes: 30);
    case SessionStrategy.foregroundTicker:
      return const Duration(minutes: 15);
    case SessionStrategy.ultraAggressive:
      return const Duration(minutes: 10);
    case SessionStrategy.resumeOnly:
      return const Duration(minutes: 30);
  }
}

/// Does the strategy want a ping the instant the app comes back to foreground?
bool pingOnResume(SessionStrategy s) {
  switch (s) {
    case SessionStrategy.foregroundTicker:
    case SessionStrategy.ultraAggressive:
    case SessionStrategy.resumeOnly:
      return true;
    case SessionStrategy.original:
      return false;
  }
}

/// Manages the foreground keep-alive timer based on [kActiveStrategy]. Owned
/// by the top-level app widget and started/stopped in lifecycle callbacks.
class SessionKeeper {
  final ScraperService _scraper = ScraperService();
  Timer? _timer;
  int _tickCount = 0;

  /// Begin (or restart) the foreground ticker. Safe to call repeatedly —
  /// cancels any previous timer first. No-op for strategies without a ticker.
  void start() {
    stop();
    final interval = foregroundInterval(kActiveStrategy);
    if (interval == null) return;
    _timer = Timer.periodic(interval, (_) => _tick());
    debugPrint(
      "[SessionKeeper] started: strategy=$kActiveStrategy interval=$interval",
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Fire one immediate ping — call this on `AppLifecycleState.resumed`. Does
  /// a full balance + transactions widget refresh, so coming back to the app
  /// always freshens the home-screen widget.
  Future<void> pingNow() async {
    if (!pingOnResume(kActiveStrategy)) return;
    await _ping(fullFetch: true);
  }

  Future<void> _tick() async {
    _tickCount++;
    // Every 4th tick on [foregroundTicker] (~12 min) do a full fetchBalance so
    // the widget data doesn't go stale. Aggressive strategy only does
    // keep-alives; explicit full refreshes still happen when the user opens
    // the app or pulls to refresh.
    final fullFetch = kActiveStrategy == SessionStrategy.foregroundTicker &&
        _tickCount % 4 == 0;
    await _ping(fullFetch: fullFetch);
  }

  Future<void> _ping({required bool fullFetch}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cookies = prefs.getString('session_cookies');
      if (cookies == null || cookies.isEmpty) return;
      if (fullFetch) {
        await _scraper.fetchBalance(cookies);
        // Best-effort widget transaction refresh — don't let a transaction
        // failure mask the balance success in logs.
        try {
          await _scraper.refreshTransactionsWidget(cookies);
        } catch (e) {
          debugPrint("[SessionKeeper] txn widget refresh failed: $e");
        }
        debugPrint("[SessionKeeper] full refresh OK");
      } else {
        await _scraper.keepAlive(cookies);
        debugPrint("[SessionKeeper] keepAlive OK");
      }
    } catch (e) {
      // Session-expired / network — don't crash the timer; next tick retries.
      debugPrint("[SessionKeeper] ping failed: $e");
    }
  }
}
