import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watbal/balance_display.dart';
import 'package:watbal/scraper_service.dart';

/// Shows the fetched balance. Refresh re-scrapes with the saved session;
/// if that fails, [onSessionLost] sends the user back to the loading page
/// (which re-triggers the login popup).
class DisplayPage extends StatefulWidget {
  final String balance;
  final VoidCallback onSessionLost;

  const DisplayPage({
    super.key,
    required this.balance,
    required this.onSessionLost,
  });

  @override
  State<DisplayPage> createState() => _DisplayPageState();
}

class _DisplayPageState extends State<DisplayPage> {
  final ScraperService _scraper = ScraperService();
  late String _balance = widget.balance;
  bool _refreshing = false;

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    final prefs = await SharedPreferences.getInstance();
    final cookies = prefs.getString("session_cookies");

    if (cookies == null) {
      widget.onSessionLost();
      return;
    }

    try {
      final result = await _scraper.fetchBalance(cookies);
      if (mounted) {
        setState(() {
          _balance = result;
          _refreshing = false;
        });
      }
    } catch (e) {
      if (mounted) widget.onSessionLost();
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
            BalanceDisplay(balance: _balance),
            const SizedBox(height: 40),
            _refreshing
                ? const CircularProgressIndicator(color: Colors.blueAccent)
                : ElevatedButton(
                    onPressed: _refresh,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text("Refresh"),
                  ),
          ],
        ),
      ),
    );
  }
}
