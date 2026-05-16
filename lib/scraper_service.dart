import 'package:http/http.dart' as http;
import 'package:html/parser.dart' show parse;
import 'package:home_widget/home_widget.dart';
import 'package:flutter/foundation.dart';
import 'package:watbal/transaction.dart';

class ScraperService {
  final String appGroupId = 'group.com.vincent.watbal';

  static const _userAgent =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36";
  static const _base = "https://secure.touchnet.net/C22566_oneweb";

  String _fmtDate(DateTime d) =>
      "${d.month.toString().padLeft(2, '0')}/"
      "${d.day.toString().padLeft(2, '0')}/${d.year}";

  /// GETs the Dashboard and parses the form-field __RequestVerificationToken
  /// (distinct from the cookie of the same prefix). Throws "Session Expired"
  /// when the token is gone, matching fetchBalance's behaviour.
  Future<String> _verificationToken(String cookieHeader) async {
    final res = await http.get(
      Uri.parse("$_base/Account/Dashboard"),
      headers: {"Cookie": cookieHeader, "User-Agent": _userAgent},
    );
    final token = parse(res.body)
        .querySelector('input[name="__RequestVerificationToken"]')
        ?.attributes['value'];
    if (token == null) throw Exception("Session Expired");
    return token;
  }

  /// POSTs TransactionHistory/TransactionsPass for the given range and parses
  /// the result table into [Transaction]s (newest first, as returned).
  Future<List<Transaction>> fetchTransactions(
    String cookieHeader,
    DateTime from,
    DateTime to,
  ) async {
    final token = await _verificationToken(cookieHeader);

    final res = await http.post(
      Uri.parse("$_base/TransactionHistory/TransactionsPass"),
      headers: {
        "Cookie": cookieHeader,
        "Accept": "*/*",
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "X-Requested-With": "XMLHttpRequest",
        "Origin": "https://secure.touchnet.net",
        "Referer": "$_base/TransactionHistory/Transactions",
        "User-Agent": _userAgent,
      },
      body: {
        "FromDate": _fmtDate(from),
        "ToDate": _fmtDate(to),
        "ReturnRows": "1000",
        "BalanceID": "",
        "__RequestVerificationToken": token,
      },
    );

    final rows = parse(res.body)
        .querySelectorAll('#transaction-history-result-table tbody tr');

    return rows.map((r) {
      String cell(String title) =>
          r.querySelector('td[data-title="$title"]')?.text.trim() ?? "";
      return Transaction(
        dateTime: cell("Date - Time"),
        type: cell("Type"),
        terminal: cell("Terminal"),
        status: cell("Status"),
        balance: cell("Balance"),
        units: cell("Units"),
        amount: cell("Amount"),
      );
    }).toList();
  }

  Future<String> fetchBalance(String cookieHeader) async {
    try {
      // --- STEP 1: GET DASHBOARD (To get the token) ---
      print("Fetching Dashboard to grab fresh token...");
      final dashboardRes = await http.get(
        Uri.parse("https://secure.touchnet.net/C22566_oneweb/Account/Dashboard"),
        headers: {
          "Cookie": cookieHeader,
          "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
        },
      );
      print("Dashboard Status: ${dashboardRes.statusCode}");

      var doc = parse(dashboardRes.body);
      var token = doc.querySelector('input[name="__RequestVerificationToken"]')?.attributes['value'];

      if (token == null) {
        print("Error: Could not find token in HTML.");
        throw Exception("Session Expired");
      }
      print("Verification Token parsed: ${token.substring(0, 15)}...");

      // --- STEP 2: KEEP ALIVE (Using the parsed token) ---
      print("Sending KeepAlive with parsed token...");
      final keepAliveRes = await http.post(
        Uri.parse("https://secure.touchnet.net/C22566_oneweb/Layout/KeepAlive"),
        headers: {
          "Cookie": cookieHeader,
          "Accept": "*/*",
          "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
          "X-Requested-With": "XMLHttpRequest",
          "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
        },
        body: {"__RequestVerificationToken": token}, // Using the token we just parsed
      );
      print("KeepAlive Status: ${keepAliveRes.statusCode}");

      // --- STEP 3: FETCH BALANCES ---
      print("Requesting Balances...");
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
      print("Balances Status: ${balanceRes.statusCode}");

      // --- STEP 4: PARSING ---
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
        print("Success! Found Balance: $foundAmount");
        await _updateWidget(foundAmount);
        return foundAmount;
      } else {
        throw Exception("Structure Error");
      }
    } catch (e) {
      print("Scraper Error: $e");
      rethrow;
    }
  }

  Future<void> _updateWidget(String balance) async {
    try {
      await HomeWidget.setAppGroupId(appGroupId);
      await HomeWidget.saveWidgetData<String>('balance_text', balance);
      await HomeWidget.updateWidget(
        name: 'WatBalWidgetReceiver', 
        iOSName: 'WatBalWidget',
      );
    } catch (e) {
      debugPrint("Widget Update Error: $e");
    }
  }
}