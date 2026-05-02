import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' show parse;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:home_widget/home_widget.dart'; 
import 'package:watbal/balance_display.dart'; 

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
  String _balance = "Checking...";
  bool _isLoggingIn = false;

  // Replace with the App Group ID you create in Xcode
  final String appGroupId = 'group.com.vincent.watbal';

  @override
  void initState() {
    super.initState();
    // Configure the App Group so the iOS widget can see the data
    HomeWidget.setAppGroupId(appGroupId);
    _attemptAutoFetch();
  }

  Future<void> _attemptAutoFetch() async {
    setState(() => _balance = "Checking...");
    final prefs = await SharedPreferences.getInstance();
    String? savedCookies = prefs.getString("session_cookies");

    if (savedCookies != null) {
      await fetchBalance(savedCookies);
    } else {
      setState(() {
        _balance = "Login Required";
        _isLoggingIn = true; 
      });
    }
  }

  Future<void> fetchBalance(String cookieHeader) async {
    try {
      final dashboardRes = await http.get(
        Uri.parse("https://secure.touchnet.net/C22566_oneweb/Account/Dashboard"),
        headers: {
          "Cookie": cookieHeader,
          "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
        },
      );

      var doc = parse(dashboardRes.body);
      var token = doc.querySelector('input[name="__RequestVerificationToken"]')?.attributes['value'];

      if (token == null) {
        setState(() {
          _balance = "Session Expired";
          _isLoggingIn = true; 
        });
        return;
      }

      final balanceRes = await http.post(
        Uri.parse("https://secure.touchnet.net/C22566_oneweb/Deposit/Home/Balances"),
        headers: {
          "Cookie": cookieHeader,
          "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
          "X-Requested-With": "XMLHttpRequest",
          "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
          "Referer": "https://secure.touchnet.net/C22566_oneweb/Deposit",
        },
        body: {"__RequestVerificationToken": token},
      );

      var balanceDoc = parse(balanceRes.body);
      String? foundAmount;
      var allCells = balanceDoc.querySelectorAll('td, div, span');
      bool foundFlexible = false;
      
      for (var cell in allCells) {
        String text = cell.text.trim();
        if (text.contains("FLEXIBLE")) {
          foundFlexible = true;
          continue; 
        }
        if (foundFlexible && text.contains(RegExp(r'\$\d'))) {
          foundAmount = text;
          break;
        }
      }

      if (foundAmount != null) {
        // 1. Update the UI
        setState(() {
          _balance = foundAmount!;
          _isLoggingIn = false; 
        });

        // 2. Update the Home Screen Widget (Outside setState)
        await _updateWidget(foundAmount);
        
      } else {
        setState(() => _balance = "Structure Error");
      }
    } catch (e) {
      setState(() => _balance = "Error");
    }
  }

  /// Helper to push data to iOS/Android widgets
  Future<void> _updateWidget(String balance) async {
    try {
      await HomeWidget.saveWidgetData<String>('balance_text', balance);
      await HomeWidget.updateWidget(
        name: 'WatBalWidgetReceiver', 
        iOSName: 'WatBalWidget',
      );
    } catch (e) {
      debugPrint("Widget Update Error: $e");
    }
  }

  Future<void> _saveAndProcessCookies(WebUri? url) async {
    if (url == null || !url.toString().contains("Account/Dashboard")) return;

    CookieManager cookieManager = CookieManager.instance();
    var cookies = await cookieManager.getCookies(url: url);

    if (cookies.length >= 3) {
      String header = cookies.map((c) => "${c.name}=${c.value}").join("; ");
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("session_cookies", header);
      await fetchBalance(header);
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
        actions: _isLoggingIn 
          ? [IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _isLoggingIn = false))] 
          : null,
      ),
      body: _isLoggingIn 
        ? InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri("https://secure.touchnet.net/C22566_oneweb/Account/Dashboard")),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
            ),
            onLoadStop: (controller, url) async => await _saveAndProcessCookies(url),
            onUpdateVisitedHistory: (controller, url, isReload) async => await _saveAndProcessCookies(url),
          )
        : Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                BalanceDisplay(balance: _balance),
                const SizedBox(height: 60),
                ElevatedButton.icon(
                  onPressed: _attemptAutoFetch,
                  icon: const Icon(Icons.refresh),
                  label: const Text("Refresh Balance"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))
                  ),
                ),
              ],
            ),
          ),
    );
  }
}