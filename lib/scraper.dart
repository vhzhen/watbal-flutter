import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:html/parser.dart' show parse;
import 'package:http/http.dart' as http;

import 'package:watbal/debug_log.dart';

/// Broadcasts a reload to every WatBal home-screen widget. The full widget
/// (balance + transactions) and the compact 1x1 widget read the same shared
/// data, so a single data write feeds both — they just need separate update
/// broadcasts. Each is guarded so a receiver that isn't placed (e.g. the user
/// only added one of the two) can't block the other. The compact widget is
/// Android-only; the `androidName` call is a no-op on iOS.
Future<void> reloadWatBalWidgets() async {
  try {
    await HomeWidget.updateWidget(
      name: 'WatBalWidgetReceiver',
      iOSName: 'WatBalWidget',
    );
  } catch (_) {}
  try {
    await HomeWidget.updateWidget(androidName: 'WatBalSmallWidgetReceiver');
  } catch (_) {}
}

/// One row from the TouchNet transaction-history table.
class Transaction {
  final String dateTime;
  final String type;
  final String terminal;
  final String amount;

  const Transaction({
    required this.dateTime,
    required this.type,
    required this.terminal,
    required this.amount,
  });

  /// True when money left the account (amount is negative, e.g. "$-10.00").
  bool get isDebit => amount.contains('-');

  /// Sign before the currency symbol: the site renders "$-0.14"; show "-$0.14".
  String get displayAmount => amount.replaceFirst(r'$-', r'-$');

  /// "102 : ACCOUNT ADJUSTMENT" -> "ACCOUNT ADJUSTMENT"
  String get label {
    final i = type.indexOf(':');
    return (i >= 0 ? type.substring(i + 1) : type).trim();
  }

  /// "00024 : WEBAPPS" -> "WEBAPPS"
  String get terminalLabel {
    final i = terminal.indexOf(':');
    return (i >= 0 ? terminal.substring(i + 1) : terminal).trim();
  }
}

/// All scraping against the TouchNet OneWeb dashboard. The site is a server-
/// rendered ASP.NET MVC app with no public API, so we mimic the same requests
/// the in-browser dashboard makes. Three endpoints matter:
///
/// 1. `GET /Account/Dashboard` — gives us a fresh anti-forgery token.
/// 2. `POST /Layout/KeepAlive` — bumps the sliding `.ASPXAUTH` window.
/// 3. `POST /Deposit/Home/Balances` — returns the balance table HTML.
///    `POST /TransactionHistory/TransactionsPass` — returns transactions.
///
/// A "Session Expired" exception is thrown when the Dashboard response no
/// longer contains the anti-forgery token; the caller then triggers re-auth.
class Scraper {
  static const _base = "https://secure.touchnet.net/C22566_oneweb";
  static const _userAgent =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36";
  static const _appGroupId = "group.com.vincent.watbal";

  /// Hits the Dashboard and pulls out the `__RequestVerificationToken`. Every
  /// authenticated POST needs this — ASP.NET's anti-forgery defence.
  Future<String> _token(String cookies) async {
    final res = await http.get(
      Uri.parse("$_base/Account/Dashboard"),
      headers: {"Cookie": cookies, "User-Agent": _userAgent},
    );
    final token = parse(res.body)
        .querySelector('input[name="__RequestVerificationToken"]')
        ?.attributes['value'];
    if (token == null) throw Exception("Session Expired");
    return token;
  }

  /// Lightweight session ping. Two small requests, no balance parse. Use this
  /// when you only want to keep the session warm.
  Future<void> keepAlive(String cookies) async {
    final token = await _token(cookies);
    await http.post(
      Uri.parse("$_base/Layout/KeepAlive"),
      headers: _ajaxHeaders(cookies),
      body: {"__RequestVerificationToken": token},
    );
  }

  /// Scrapes the current FLEXIBLE balance ("$237.41"), writes it to the iOS
  /// widget's shared app group, and returns it.
  Future<String> fetchBalance(String cookies) async {
    final token = await _token(cookies);

    // KeepAlive is folded in so a single fetchBalance also resets the
    // sliding-auth window — same shape the in-browser dashboard uses.
    await http.post(
      Uri.parse("$_base/Layout/KeepAlive"),
      headers: _ajaxHeaders(cookies),
      body: {"__RequestVerificationToken": token},
    );

    final res = await http.post(
      Uri.parse("$_base/Deposit/Home/Balances"),
      headers: {
        ..._ajaxHeaders(cookies),
        "Referer": "$_base/Deposit",
      },
      body: {"__RequestVerificationToken": token},
    );

    final balance = _findBalanceAfter("FLEXIBLE", res.body);
    if (balance == null) throw Exception("Balance not found");

    await _pushToWidget('balance_text', balance);
    return balance;
  }

  /// Scrapes the transaction history table for a date range. The page tops
  /// out at 1000 rows; we cap the request there.
  Future<List<Transaction>> fetchTransactions(
    String cookies, {
    required DateTime from,
    required DateTime to,
  }) async {
    final token = await _token(cookies);

    final res = await http.post(
      Uri.parse("$_base/TransactionHistory/TransactionsPass"),
      headers: {
        ..._ajaxHeaders(cookies),
        "Origin": "https://secure.touchnet.net",
        "Referer": "$_base/TransactionHistory/Transactions",
      },
      body: {
        "FromDate": _fmt(from),
        "ToDate": _fmt(to),
        "ReturnRows": "1000",
        "BalanceID": "",
        "__RequestVerificationToken": token,
      },
    );

    return parse(res.body)
        .querySelectorAll('#transaction-history-result-table tbody tr')
        .map((r) {
      String cell(String title) =>
          r.querySelector('td[data-title="$title"]')?.text.trim() ?? "";
      return Transaction(
        dateTime: cell("Date - Time"),
        type: cell("Type"),
        terminal: cell("Terminal"),
        amount: cell("Amount"),
      );
    }).toList();
  }

  /// Refreshes the iOS transactions widget with the 8 most-recent rows. Uses
  /// a 5-year query so the widget always shows the newest activity regardless
  /// of any in-app date filter the user has set.
  Future<void> refreshTransactionsWidget(String cookies) async {
    final now = DateTime.now();
    final txns = await fetchTransactions(
      cookies,
      from: DateTime(now.year - 5, now.month, now.day),
      to: now,
    );
    final recent = txns
        .take(8)
        .map((t) => {
              'label': t.label,
              'amount': t.displayAmount,
              'date': t.dateTime,
              'isDebit': t.isDebit,
            })
        .toList();
    await _pushToWidget('transactions_json', jsonEncode(recent));
  }

  /// Bumps only the widget's "last updated" timestamp and reloads it — no
  /// network. Used when the app closes so the home-screen time reflects the
  /// user's last visit. A single, isolated broadcast (not part of a refresh
  /// burst) is far more likely to actually re-render than one buried in a
  /// rapid-fire sequence, which Android coalesces.
  Future<void> touchWidget() async {
    try {
      await HomeWidget.setAppGroupId(_appGroupId);
      await HomeWidget.saveWidgetData<String>(
        'last_updated',
        DateTime.now().millisecondsSinceEpoch.toString(),
      );
      await reloadWatBalWidgets();
      await DebugLog.log("widget: touched last_updated + reload");
    } catch (e) {
      await DebugLog.log("widget: touch failed: $e");
    }
  }

  // ───────────────────────────── helpers ──────────────────────────────

  Map<String, String> _ajaxHeaders(String cookies) => {
        "Cookie": cookies,
        "Accept": "*/*",
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "X-Requested-With": "XMLHttpRequest",
        "User-Agent": _userAgent,
      };

  String _fmt(DateTime d) =>
      "${d.month.toString().padLeft(2, '0')}/"
      "${d.day.toString().padLeft(2, '0')}/${d.year}";

  /// Finds the first `$X.XX` value that appears after [marker] in the HTML.
  /// The balance row markup varies (table cells, divs, spans) so a permissive
  /// regex on raw HTML is more robust than DOM walking.
  String? _findBalanceAfter(String marker, String html) {
    final pattern = RegExp(
      "$marker" r"[\s\S]{0,4000}?(\$[0-9,]+\.[0-9]{2})",
    );
    return pattern.firstMatch(html)?.group(1);
  }

  /// Saves [value] into the shared iOS app group and reloads the widget
  /// timeline. Also updates the `last_updated` timestamp so the widget can
  /// show "Updated Xm ago". Failures are non-fatal — Android dev for example
  /// has no widget extension.
  Future<void> _pushToWidget(String key, String value) async {
    try {
      await HomeWidget.setAppGroupId(_appGroupId);
      await HomeWidget.saveWidgetData<String>(key, value);
      await HomeWidget.saveWidgetData<String>(
        'last_updated',
        DateTime.now().millisecondsSinceEpoch.toString(),
      );
      await reloadWatBalWidgets();
      await DebugLog.log(
        "widget: pushed $key=${value.length > 40 ? '${value.length} chars' : value} + reload",
      );
    } catch (e) {
      debugPrint("Widget update skipped: $e");
      await DebugLog.log("widget: push failed for $key: $e");
    }
  }
}
