import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:html/parser.dart' show parse;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watbal/debug_log.dart';

/// SharedPreferences key holding the raw account name (e.g. "FLEXIBLE") the
/// user chose to display on the home-screen widgets. Null/absent means "the
/// first account". Read by the scraper when deciding which balance to push.
const String kWidgetAccountKey = 'widget_account';

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
  try {
    await HomeWidget.updateWidget(androidName: 'WatBalMediumWidgetReceiver');
  } catch (_) {}
}

/// One row from the TouchNet "Available Balances" table. A user can hold more
/// than one account type (e.g. FLEXIBLE plus a dining plan), so balances are
/// always handled as a list.
class AccountBalance {
  /// Raw account name exactly as scraped, e.g. "FLEXIBLE". Used as the stable
  /// key for the widget-account preference.
  final String name;

  /// Formatted amount as rendered by the site, e.g. "$0.44".
  final String amount;

  const AccountBalance({required this.name, required this.amount});

  /// User-facing name. The site's internal "FLEXIBLE" reads as "FLEX DOLLARS";
  /// any other account is title-cased from its raw name.
  String get displayName {
    if (name.toUpperCase() == 'FLEXIBLE') return 'FLEX DOLLARS';
    return name
        .split(RegExp(r'\s+'))
        .map((w) => w.isEmpty
            ? w
            : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
        .join(' ');
  }
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

  /// Parses [dateTime] into a DateTime for grouping/sorting. Tolerant of the
  /// common shapes the site might emit — US slash ("6/14/2026 12:34:56 PM"),
  /// ISO dash ("2026-06-14"), 2- or 4-digit year, optional time/AM-PM. Returns
  /// null on anything unexpected so the UI falls back to the raw string.
  DateTime? get parsedDate {
    final s = dateTime.trim();
    if (s.isEmpty) return null;
    try {
      final tokens = s.split(RegExp(r'\s+'));
      final dateTok = tokens.first;
      final sep = dateTok.contains('/')
          ? '/'
          : (dateTok.contains('-') ? '-' : null);
      if (sep == null) return null;
      final p = dateTok.split(sep);
      if (p.length != 3) return null;

      int year, month, day;
      if (p[0].length == 4) {
        // yyyy-MM-dd
        year = int.parse(p[0]);
        month = int.parse(p[1]);
        day = int.parse(p[2]);
      } else {
        // MM/dd/yyyy (US)
        month = int.parse(p[0]);
        day = int.parse(p[1]);
        year = int.parse(p[2]);
        if (year < 100) year += 2000;
      }
      if (month < 1 || month > 12 || day < 1 || day > 31) return null;

      var hour = 0, minute = 0;
      if (tokens.length >= 2 && tokens[1].contains(':')) {
        final t = tokens[1].split(':');
        hour = int.parse(t[0]);
        if (t.length > 1) minute = int.parse(t[1]);
        final ampm = tokens.length >= 3 ? tokens[2].toUpperCase() : '';
        if (ampm == 'PM' && hour != 12) hour += 12;
        if (ampm == 'AM' && hour == 12) hour = 0;
      }
      return DateTime(year, month, day, hour, minute);
    } catch (_) {
      return null;
    }
  }

  /// Signed numeric value of the amount ("$-0.14" -> -0.14, "$5.00" -> 5.00).
  /// 0 on parse failure. Debits are negative.
  double get amountValue =>
      double.tryParse(amount.replaceAll(RegExp(r'[^0-9.\-]'), '')) ?? 0;
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

  /// Scrapes every account in the "Available Balances" table, pushes the
  /// user-selected account's balance to the home-screen widgets, and returns
  /// the full list (a user may hold more than one account type).
  Future<List<AccountBalance>> fetchBalances(String cookies) async {
    final token = await _token(cookies);

    // KeepAlive is folded in so a single fetch also resets the sliding-auth
    // window — same shape the in-browser dashboard uses.
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

    final accounts = _parseBalances(res.body);
    if (accounts.isEmpty) throw Exception("Balance not found");

    await pushSelectedBalanceToWidget(accounts);
    return accounts;
  }

  /// Writes the user-selected account's balance (and its label) into the shared
  /// widget data and reloads the widgets. Exposed so the settings screen can
  /// re-push immediately when the user changes which account the widget shows,
  /// without waiting for the next scrape.
  Future<void> pushSelectedBalanceToWidget(
      List<AccountBalance> accounts) async {
    if (accounts.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final selected = prefs.getString(kWidgetAccountKey);
    final chosen = accounts.firstWhere(
      (a) => a.name == selected,
      orElse: () => accounts.first,
    );
    await _pushWidgetData({
      'balance_text': chosen.amount,
      'balance_label': chosen.displayName,
    });
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
              // Merchant name as the row title (matches the in-app list),
              // falling back to the type description when it's blank.
              'label': t.terminalLabel.isNotEmpty ? t.terminalLabel : t.label,
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

  /// Parses every row of the "Available Balances" table. Each row is
  /// `Name | Type | Amount | Credit`; we take the name (its `title` attribute
  /// when present, so the full value survives the ellipsis truncation) and the
  /// first right-aligned cell (the Amount column). Rows without a `$` amount are
  /// skipped. Falls back to a permissive FLEXIBLE regex if the table markup
  /// isn't what we expect, so a single-account user is never left empty-handed.
  List<AccountBalance> _parseBalances(String html) {
    final out = <AccountBalance>[];
    for (final row in parse(html).querySelectorAll('table tbody tr')) {
      final nameCell = row.querySelector('td');
      if (nameCell == null) continue;
      final name = (nameCell.querySelector('[title]')?.attributes['title'] ??
              nameCell.text)
          .trim();
      final amount = row.querySelector('td.text-right')?.text.trim() ?? '';
      if (name.isEmpty || !amount.contains(r'$')) continue;
      out.add(AccountBalance(name: name, amount: amount));
    }
    if (out.isEmpty) {
      final fallback = _findBalanceAfter("FLEXIBLE", html);
      if (fallback != null) {
        out.add(AccountBalance(name: "FLEXIBLE", amount: fallback));
      }
    }
    return out;
  }

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
  Future<void> _pushToWidget(String key, String value) =>
      _pushWidgetData({key: value});

  /// Saves several shared keys at once, bumps `last_updated`, then issues a
  /// single widget reload. Batching the writes behind one reload matters:
  /// rapid-fire broadcasts get coalesced (and can freeze the launcher), so the
  /// balance + its label must land together under one broadcast.
  Future<void> _pushWidgetData(Map<String, String> data) async {
    try {
      await HomeWidget.setAppGroupId(_appGroupId);
      for (final e in data.entries) {
        await HomeWidget.saveWidgetData<String>(e.key, e.value);
      }
      await HomeWidget.saveWidgetData<String>(
        'last_updated',
        DateTime.now().millisecondsSinceEpoch.toString(),
      );
      await reloadWatBalWidgets();
      await DebugLog.log("widget: pushed ${data.keys.join(', ')} + reload");
    } catch (e) {
      debugPrint("Widget update skipped: $e");
      await DebugLog.log("widget: push failed (${data.keys.join(', ')}): $e");
    }
  }
}
