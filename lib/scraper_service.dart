import 'package:http/http.dart' as http;
import 'package:html/parser.dart' show parse;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:home_widget/home_widget.dart';
import 'package:flutter/foundation.dart';

class ScraperService {
  final String appGroupId = 'group.com.vincent.watbal';

  /// Scrapes the balance and updates the Home Widget.
  /// Returns the balance string or throws an error.
  Future<String> fetchBalance(String cookieHeader) async {
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

      if (token == null) throw Exception("Session Expired");

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
        await _updateWidget(foundAmount);
        return foundAmount;
      } else {
        throw Exception("Structure Error");
      }
    } catch (e) {
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