import 'dart:io';
import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';
import 'package:watbal/app_theme.dart';
import 'package:watbal/background_refresh.dart';
import 'package:watbal/display_page.dart';
import 'package:watbal/loading_page.dart';
import 'package:watbal/transactions_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Workmanager().initialize(callbackDispatcher);
    if (Platform.isIOS) {
      // workmanager 0.5.2 has no periodic task on iOS — schedule a one-off
      // BGProcessingTask; the task itself re-schedules the next one (see
      // background_refresh.dart), giving a periodic-ish chain. iOS still
      // decides the real timing.
      await Workmanager().registerOneOffTask(
        kRefreshTaskId,
        kRefreshTaskId,
        initialDelay: const Duration(minutes: 15),
      );
    }
  } catch (e) {
    debugPrint("Background refresh setup skipped: $e");
  }

  runApp(const WatBalRoot());
}

class WatBalRoot extends StatefulWidget {
  const WatBalRoot({super.key});

  @override
  State<WatBalRoot> createState() => _WatBalRootState();
}

class _WatBalRootState extends State<WatBalRoot> {
  final ThemeController _theme = ThemeController();

  @override
  void initState() {
    super.initState();
    _theme.load();
  }

  @override
  void dispose() {
    _theme.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ThemeScope(
      controller: _theme,
      child: ListenableBuilder(
        listenable: _theme,
        builder: (context, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme.option.themeData,
          home: const WatBalApp(),
        ),
      ),
    );
  }
}

class WatBalApp extends StatefulWidget {
  const WatBalApp({super.key});

  @override
  State<WatBalApp> createState() => _WatBalAppState();
}

class _WatBalAppState extends State<WatBalApp> {
  String? _balance;

  @override
  Widget build(BuildContext context) {
    if (_balance == null) {
      return LoadingPage(
        onLoaded: (balance) => setState(() => _balance = balance),
      );
    }
    return HomePager(
      balance: _balance!,
      onSessionLost: () => setState(() => _balance = null),
    );
  }
}

/// Two swipeable pages: the balance (page 0, where the user starts) and the
/// transaction history (page 1, revealed by swiping left).
class HomePager extends StatefulWidget {
  final String balance;
  final VoidCallback onSessionLost;

  const HomePager({
    super.key,
    required this.balance,
    required this.onSessionLost,
  });

  @override
  State<HomePager> createState() => _HomePagerState();
}

class _HomePagerState extends State<HomePager> {
  final PageController _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Stack(
        children: [
          PageView(
            controller: _controller,
            onPageChanged: (i) => setState(() => _page = i),
            children: [
              DisplayPage(
                balance: widget.balance,
                onSessionLost: widget.onSessionLost,
              ),
              TransactionsPage(onSessionLost: widget.onSessionLost),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(2, (i) {
                    final active = i == _page;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: active ? 20 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: active
                            ? scheme.primary
                            : scheme.onSurface.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    );
                  }),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
