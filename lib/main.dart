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

  @override
  void initState() {
    super.initState();
    _attemptAutoFetch();
  }

  Future<void> _attemptAutoFetch() async {
    setState(() => _balance = "\$--.--");
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
    try {
      final result = await _scraper.fetchBalance(cookies);
      setState(() {
        _balance = result;
        _isLoggingIn = false;
      });
    } catch (e) {
      setState(() {
        _balance = e.toString().contains("Expired") ? "Session Expired" : "Structure Error";
        _isLoggingIn = true;
      });
    }
  }

  Future<void> _handleWebLogin(WebUri? url) async {
    if (url == null || !url.toString().contains("Account/Dashboard")) return;

    CookieManager cookieManager = CookieManager.instance();
    var cookies = await cookieManager.getCookies(url: url);

    if (cookies.length >= 3) {
      String header = cookies.map((c) => "${c.name}=${c.value}").join("; ");
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("session_cookies", header);
      _runFetch(header);
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
      body: _isLoggingIn 
        ? InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri("https://secure.touchnet.net/C22566_oneweb/Account/Dashboard")),
            onLoadStop: (controller, url) => _handleWebLogin(url),
            onUpdateVisitedHistory: (controller, url, isReload) => _handleWebLogin(url),
          )
        : Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                BalanceDisplay(balance: _balance),
                const SizedBox(height: 40),
                ElevatedButton(
                  onPressed: _attemptAutoFetch,
                  child: const Text("Refresh"),
                ),
              ],
            ),
          ),
    );
  }
}