import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watbal/login_webview.dart';
import 'package:watbal/scraper_service.dart';

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

  Future<void> _fetch(String cookies) async {
    setState(() {
      _busy = true;
      _status = "Fetching your balance…";
    });

    try {
      final result = await _scraper.fetchBalance(cookies);
      if (mounted) widget.onLoaded(result);
    } catch (e) {
      // Any failure here means the saved session can no longer reach the
      // balance, so send the user back through login.
      _promptLogin(expired: true);
    }
  }

  Future<void> _promptLogin({bool expired = false}) async {
    if (!mounted) return;
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
      _fetch(header);
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
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text("WatBal", style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_busy)
              const CircularProgressIndicator(color: Colors.blueAccent)
            else
              const Icon(Icons.lock_outline, size: 48, color: Colors.grey),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _status,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey, fontSize: 16),
              ),
            ),
            if (!_busy) ...[
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => _promptLogin(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                ),
                child: const Text("Sign in"),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
