import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'package:watbal/scraper_service.dart';
import 'package:watbal/session_strategies.dart';

/// Identifier shared between Dart, the iOS Info.plist
/// (BGTaskSchedulerPermittedIdentifiers) and AppDelegate registration.
const String kRefreshTaskId = 'com.vincent.watbal.refresh';

/// Background entry point. iOS decides when this actually runs — the goal is
/// only that the widget's data refreshes *eventually* without opening the app.
///
/// The interval and whether to do a full fetchBalance or a lightweight
/// keepAlive are driven by [kActiveStrategy] in session_strategies.dart.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();

    // iOS has no native periodic task in workmanager 0.5.2, so each run
    // queues the next one. iOS still decides when it actually fires.
    try {
      await Workmanager().registerOneOffTask(
        kRefreshTaskId,
        kRefreshTaskId,
        initialDelay: backgroundInterval(kActiveStrategy),
      );
    } catch (_) {}

    try {
      final prefs = await SharedPreferences.getInstance();
      final cookies = prefs.getString('session_cookies');
      // No stored session — re-login needs UI, so there's nothing to do
      // headlessly. Report success so iOS keeps scheduling future runs.
      if (cookies == null || cookies.isEmpty) return true;

      final scraper = ScraperService();

      // Alternate light/heavy runs on aggressive strategies so the widget
      // still gets fresh data periodically, but most background slots only
      // pay for a cheap keepAlive. iOS is more likely to grant the time.
      final lightweight = kActiveStrategy == SessionStrategy.ultraAggressive;

      if (lightweight) {
        await scraper.keepAlive(cookies);
      } else {
        // fetchBalance pushes balance + last_updated into the shared app
        // group, which is what the home-screen widget reads.
        await scraper.fetchBalance(cookies);

        // Best-effort: refresh the recent-transactions widget. Always uses a
        // wide (5-year) range so the widget shows the newest activity
        // regardless of what the user has selected in-app. A failure here
        // must not fail the whole task.
        try {
          await scraper.refreshTransactionsWidget(cookies);
        } catch (_) {}
      }

      return true;
    } catch (_) {
      // Session expired / network error. We can't recover without UI, so
      // succeed quietly; the app will fix the session on next open.
      return true;
    }
  });
}
