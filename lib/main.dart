import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'package:watbal/auth.dart';
import 'package:watbal/debug_log.dart';
import 'package:watbal/home_page.dart';
import 'package:watbal/loading_page.dart';
import 'package:watbal/scraper.dart';

// ─────────────────────────────── entry point ───────────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Migrate any session saved by an older build into the iOS shared app group
  // so the native widget-refresh task can read it. Idempotent.
  final cookies = await loadSession();
  if (cookies != null && cookies.isNotEmpty) await saveSession(cookies);

  // Background refresh so the home-screen widget updates without opening the
  // app. iOS: a one-off BGProcessingTask that re-queues itself (the native
  // BGAppRefreshTask in Swift is the primary path; this is a fallback). Android:
  // a periodic WorkManager task at the 15-min OS floor.
  try {
    await Workmanager().initialize(_workmanagerCallback);
    if (Platform.isIOS) {
      await Workmanager().registerOneOffTask(
        _refreshTaskId,
        _refreshTaskId,
        initialDelay: const Duration(minutes: 30),
      );
    } else if (Platform.isAndroid) {
      await Workmanager().registerPeriodicTask(
        _refreshTaskId,
        _refreshTaskId,
        // 15 min is WorkManager's hard floor; ask for it so the widget refreshes
        // as often as the OS allows.
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        // `update` (not `keep`): `keep` ignores this registration whenever a
        // task with the same name already exists, so an older build's frequency
        // would stick forever. `update` re-applies the current spec each launch.
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      );
    }
  } catch (e) {
    debugPrint("Background refresh setup skipped: $e");
  }

  runApp(const WatBalApp());
}

// ─────────────────────────── theme persistence ─────────────────────────────

enum AppTheme { light, dark, green }

extension AppThemeX on AppTheme {
  String get label => switch (this) {
        AppTheme.light => 'Light',
        AppTheme.dark => 'Dark',
        AppTheme.green => 'Green',
      };

  Color get swatch => switch (this) {
        AppTheme.light => Colors.white,
        AppTheme.dark => const Color(0xFF1C1C1E),
        AppTheme.green => const Color(0xFF2E7D32),
      };

  ThemeData get themeData => switch (this) {
        AppTheme.light => _build(Colors.blue, Brightness.light),
        AppTheme.dark => _build(Colors.blue, Brightness.dark),
        AppTheme.green => _build(Colors.green, Brightness.light),
      };
}

ThemeData _build(Color seed, Brightness brightness) {
  // Vibrant variant keeps the seed hue saturated. The default tonal mapping
  // desaturates a pure green into a muted grey-brown.
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      centerTitle: true,
    ),
  );
}

/// A tiny ChangeNotifier so the picker rebuilds when the user taps a swatch
/// and the active theme persists across launches.
class ThemeController extends ChangeNotifier {
  static const _key = 'app_theme';
  AppTheme _theme = AppTheme.light;
  AppTheme get theme => _theme;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_key);
    _theme = AppTheme.values.firstWhere(
      (t) => t.name == name,
      orElse: () => AppTheme.light,
    );
    notifyListeners();
    _syncWidget();
  }

  Future<void> set(AppTheme theme) async {
    if (theme == _theme) return;
    _theme = theme;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, theme.name);
    _syncWidget();
  }

  Future<void> _syncWidget() async {
    try {
      await HomeWidget.setAppGroupId('group.com.vincent.watbal');
      await HomeWidget.saveWidgetData<String>('app_theme', _theme.name);
      await reloadWatBalWidgets();
    } catch (_) {}
  }
}

// ─────────────────────────────── app root ──────────────────────────────────

class WatBalApp extends StatefulWidget {
  const WatBalApp({super.key});
  @override
  State<WatBalApp> createState() => _WatBalAppState();
}

class _WatBalAppState extends State<WatBalApp> with WidgetsBindingObserver {
  final ThemeController _theme = ThemeController();
  Timer? _keepAlive;
  String? _balance;
  DateTime? _lastResumeRefresh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _theme.load();
    _startKeepAlive();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _keepAlive?.cancel();
    _theme.dispose();
    super.dispose();
  }

  /// Foreground ticker: while the app is open, hit KeepAlive every 3 min to
  /// keep the ASP.NET sliding session warm. Stopped when the app backgrounds
  /// (the Flutter timer can't run there anyway — the iOS BGAppRefreshTask
  /// takes over).
  void _startKeepAlive() {
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(const Duration(minutes: 3), (_) async {
      try {
        final cookies = await loadSession();
        if (cookies == null) return;
        await Scraper().keepAlive(cookies);
      } catch (e) {
        debugPrint("[keepAlive] $e");
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _startKeepAlive();
        // On resume, immediately push fresh balance + transactions to the
        // widget so re-opening the app always freshens the home screen.
        _refreshOnResume();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _keepAlive?.cancel();
        // App is closing/backgrounding: stamp the widget with "now" via a
        // single, isolated reload so the home-screen "Updated …" reflects this
        // visit. Fire-and-forget — the data shown was already fetched on resume.
        Scraper().touchWidget();
        break;
      case AppLifecycleState.inactive:
        break;
    }
  }

  Future<void> _refreshOnResume() async {
    // The OS can deliver several `resumed` events in quick succession; without
    // this guard each one kicks off a full balance+transactions fetch, and the
    // resulting burst of widget broadcasts is exactly what Android coalesces
    // into a frozen display. Throttle to one refresh per 10s.
    final now = DateTime.now();
    if (_lastResumeRefresh != null &&
        now.difference(_lastResumeRefresh!) < const Duration(seconds: 10)) {
      return;
    }
    _lastResumeRefresh = now;

    await DebugLog.log("resume: refreshing widget");
    try {
      final cookies = await loadSession();
      if (cookies == null) {
        await DebugLog.log("resume: no session; skipping");
        return;
      }
      final scraper = Scraper();
      final balance = await scraper.fetchBalance(cookies);
      await DebugLog.log("resume: balance = $balance");
      // Best-effort — transactions failure shouldn't poison the balance push.
      try {
        await scraper.refreshTransactionsWidget(cookies);
      } catch (e) {
        debugPrint("[onResume txns] $e");
        await DebugLog.log("resume: transactions failed: $e");
      }
    } catch (e) {
      debugPrint("[onResume] $e");
      await DebugLog.log("resume: failed: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _theme,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme.theme.themeData,
        home: _balance == null
            ? LoadingPage(
                onLoaded: (b) => setState(() => _balance = b),
              )
            : HomePage(
                balance: _balance!,
                theme: _theme,
                onBalanceChanged: (b) => setState(() => _balance = b),
                onSignedOut: () => setState(() => _balance = null),
              ),
      ),
    );
  }
}

// ───────────────────────── workmanager background ──────────────────────────

const String _refreshTaskId = 'com.vincent.watbal.refresh';

/// Background isolate entry point. Re-queues itself, then does a best-effort
/// balance + transactions refresh. If the session has expired (no token in
/// the Dashboard response) we just exit quietly — there's no UI here to
/// trigger re-auth, and the app will silently re-auth on next foreground.
@pragma('vm:entry-point')
void _workmanagerCallback() {
  Workmanager().executeTask((task, _) async {
    WidgetsFlutterBinding.ensureInitialized();
    // iOS one-off tasks don't repeat, so re-queue the next run here. Android's
    // periodic task repeats on its own — re-registering would disturb it.
    if (Platform.isIOS) {
      try {
        await Workmanager().registerOneOffTask(
          _refreshTaskId,
          _refreshTaskId,
          initialDelay: const Duration(minutes: 30),
        );
      } catch (_) {}
    }

    await DebugLog.log("bg: workmanager task fired ($task)");

    // Coalesce bursts. WorkManager can fire several deferred runs back-to-back
    // after Doze (we've seen 3 land within 10s); each re-auths and hammers the
    // widget host with update broadcasts, which is exactly what tips Android
    // into throttling/freezing the widget. Skip if we ran in the last 60s.
    // Cross-isolate-safe via SharedPreferences.
    final prefs = await SharedPreferences.getInstance();
    final lastRun = prefs.getInt('last_bg_run') ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - lastRun < 60 * 1000) {
      await DebugLog.log("bg: skipping duplicate run (<60s since last)");
      return true;
    }
    await prefs.setInt('last_bg_run', nowMs);

    // If no widget is on the home screen, there's nothing to refresh — skip the
    // scrape and (especially) the headless-WebView re-auth so we don't drain the
    // battery updating a widget that isn't there. The task stays registered, so
    // it resumes on its own once a widget is added. Android-only: iOS doesn't
    // report installed widgets here, and its refresh path is a separate fallback.
    if (Platform.isAndroid) {
      try {
        final widgets = await HomeWidget.getInstalledWidgets();
        if (widgets.isEmpty) {
          await DebugLog.log("bg: no widget placed; skipping");
          return true;
        }
      } catch (e) {
        // Couldn't determine widget state — proceed rather than silently stop.
        await DebugLog.log("bg: widget check failed ($e); proceeding");
      }
    }

    try {
      var cookies = await loadSession();
      if (cookies == null) {
        await DebugLog.log("bg: no session; skipping");
        return true;
      }
      final scraper = Scraper();

      try {
        final balance = await scraper.fetchBalance(cookies);
        await DebugLog.log("bg: balance = $balance");
      } catch (e) {
        // Only "Session Expired" is recoverable in the background: the saved
        // TouchNet cookie is dead, but the SSO / DUO "remember this device"
        // session still lives in the WebView's cookie jar. Replay it headlessly
        // — no password, no app open — so the widget self-heals on its own.
        // Any other error (network, etc.) we let fall through to the outer log.
        if (!e.toString().contains("Expired")) rethrow;
        await DebugLog.log("bg: session expired; trying silent re-auth");
        final fresh = await trySilentReauth();
        if (fresh == null) {
          // SSO is genuinely dead — a real sign-in is required, which only the
          // foreground app can do. Leave the widget on its last value.
          await DebugLog.log("bg: silent re-auth failed; needs real sign-in");
          return true;
        }
        cookies = fresh;
        final balance = await scraper.fetchBalance(cookies);
        await DebugLog.log("bg: re-auth ok; balance = $balance");
      }

      try {
        await scraper.refreshTransactionsWidget(cookies);
        await DebugLog.log("bg: transactions refreshed");
      } catch (e) {
        await DebugLog.log("bg: transactions failed: $e");
      }
    } catch (e) {
      await DebugLog.log("bg: refresh failed: $e");
    }
    return true;
  });
}
