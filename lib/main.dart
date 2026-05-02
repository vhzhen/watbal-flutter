import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watbal/balance_display.dart'; 
import 'package:watbal/scraper_service.dart';

void main() => runApp(const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: WatBalApp(),
    ));

class WatBalApp extends StatefulWidget {
  const WatBalApp({super.key});

  @override
  State<WatBalApp> createState() => _WatBalAppState();
}

class _WatBalAppState extends State<WatBalApp> {
  final ScraperService _scraper = ScraperService();
  String _balance = "\$--.--";
  bool _isLoggingIn = false;
  bool _isLoading = false; // NEW: Prevents the WebView flicker

  @override
  void initState() {
    super.initState();
    _attemptAutoFetch();
  }

  Future<void> _attemptAutoFetch() async {
    final prefs = await SharedPreferences.getInstance();
    String? savedCookies = prefs.getString("session_cookies");

    if (savedCookies != null) {
      _runFetch(savedCookies);
    } else {
      setState(() {
        _balance = "Login Required";
        _isLoggingIn = true; 
      });
    }
  }

  Future<void> _runFetch(String cookies) async {
    // Start loading state first
    setState(() {
      _isLoading = true;
      _isLoggingIn = false; 
      _balance = "\$--.--";
    });

    try {
      final result = await _scraper.fetchBalance(cookies);
      setState(() {
        _balance = result;
        _isLoading = false;
        _isLoggingIn = false;
      });
    } catch (e) {
      // Only now, after failure, do we trigger the login view
      debugPrint("Fetch failed, redirecting to login: $e");
      setState(() {
        _balance = e.toString().contains("Expired") ? "Session Expired" : "Structure Error";
        _isLoggingIn = true;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleWebLogin(WebUri? url) async {
    if (url == null || !url.toString().contains("Account/Dashboard")) return;

    CookieManager cookieManager = CookieManager.instance();
    var cookies = await cookieManager.getCookies(url: url);

    // Look for the specific auth cookie to ensure we are actually logged in
    bool hasAuth = cookies.any((c) => c.name == ".ASPXAUTH");
    if (hasAuth && cookies.length >= 4) {
      String header = cookies.map((c) => "${c.name}=${c.value}").join("; ");
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("session_cookies", header);
      
      // Stop showing the WebView and start the background fetch
      await Future.delayed(const Duration(milliseconds: 800));
      _runFetch(header);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Logic to decide which screen to show
    Widget currentBody;

    if (_isLoggingIn && !_isLoading) {
      // Show login portal
      currentBody = InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri("https://secure.touchnet.net/C22566_oneweb/Account/Dashboard")),
        onLoadStop: (controller, url) => _handleWebLogin(url),
        onUpdateVisitedHistory: (controller, url, isReload) => _handleWebLogin(url),
      );
    } else {
      // Show balance (or loading state)
      currentBody = Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            BalanceDisplay(balance: _balance),
            const SizedBox(height: 40),
            // Show a spinner if loading, otherwise the refresh button
            _isLoading 
              ? const CircularProgressIndicator(color: Colors.blueAccent)
              : ElevatedButton(
                  onPressed: _attemptAutoFetch,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text("Refresh"),
                ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text("WatBal", style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        // Allow user to close the login portal if they get stuck
        actions: _isLoggingIn ? [
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => setState(() => _isLoggingIn = false),
          )
        ] : null,
      ),
      body: currentBody,
    );
  }
}