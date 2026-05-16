import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watbal/login_webview.dart';
import 'package:watbal/scraper_service.dart';
import 'package:watbal/silent_auth.dart';

/// The page shown whenever we don't have a balance to display yet:
/// on cold start, while fetching, and whenever the session dies.
///
/// It auto-attempts a fetch and auto-presents the login popup when the
/// session is missing or expired. Calls [onLoaded] once a balance is in hand.
class LoadingPage extends StatefulWidget {
  final void Function(String balance) onLoaded;

  const LoadingPage({super.key, required this.onLoaded});

  @override
  State<LoadingPage> createState() => _LoadingPageState();
}

class _LoadingPageState extends State<LoadingPage> {
  final ScraperService _scraper = ScraperService();
  String _status = "Checking your session…";
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString("session_cookies");
    if (saved != null) {
      _fetch(saved);
    } else {
      _promptLogin();
    }
  }

  Future<void> _fetch(String cookies, {bool fromLogin = false}) async {
    setState(() {
      _busy = true;
      _status = "Fetching your balance…";
    });

    try {
      final result = await _scraper.fetchBalance(cookies);
      if (mounted) widget.onLoaded(result);
    } catch (e) {
      if (!mounted) return;
      if (fromLogin) {
        // Hard stop: the user just completed a real login but the scrape
        // still failed. Re-opening the popup here would spin, so surface
        // the problem and let the user retry by hand instead.
        setState(() {
          _busy = false;
          _status =
              "Signed in, but couldn't load your balance. Tap to try again.";
        });
      } else {
        // Stale saved session — send the user through login once.
        _promptLogin(expired: true);
      }
    }
  }

  Future<void> _promptLogin({bool expired = false}) async {
    if (!mounted) return;

    // Try a fast, invisible re-auth using the persisted WebView session
    // (DUO-remembered) before bothering the user with the login form. No
    // WebView is shown, so there is no Dashboard flash.
    setState(() {
      _busy = true;
      _status = "Signing you in…";
    });
    final silent = await trySilentReauth();
    if (!mounted) return;
    if (silent != null) {
      _fetch(silent, fromLogin: true);
      return;
    }

    setState(() {
      _busy = false;
      _status = expired
          ? "Your session expired. Please sign in again."
          : "Please sign in to see your balance.";
    });

    final header = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.95,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: const LoginWebView(),
        ),
      ),
    );

    if (header != null) {
      _fetch(header, fromLogin: true);
    } else if (mounted) {
      // User backed out of the popup — let them retry manually.
      setState(() {
        _busy = false;
        _status = "Sign-in needed to load your balance.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text("WatBal", style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_busy)
              const CircularProgressIndicator()
            else
              Icon(Icons.lock_outline,
                  size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _status,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: scheme.onSurfaceVariant, fontSize: 16),
              ),
            ),
            if (!_busy) ...[
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => _promptLogin(),
                child: const Text("Sign in"),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
