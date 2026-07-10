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

/// SharedPreferences key holding the account-name → balance-ID map as JSON,
/// e.g. `{"FLEXIBLE":"5","TRANSFER MP":"7"}`. The ID is the opaque number the
/// site renders in the `Balance` column of every transaction row, which is
/// what lets transactions be split per account. Discovered by
/// [Scraper.fetchBalanceIdMap]; read via [Scraper.ensureBalanceIdMap].
const String kBalanceIdMapKey = 'account_balance_ids';

/// SharedPreferences key holding every transaction row ever scraped, as a
/// JSON list (newest first). This cache is what makes transaction fetches
/// incremental: [Scraper.syncTransactions] only asks the site for rows since
/// the newest cached one. Wiped by [clearScraperCache] on sign-out.
const String kCachedTransactionsKey = 'cached_transactions';

/// Wipes all locally cached scrape state — the transaction cache and the
/// account ↔ balance-ID map, both on disk and in the isolate-static memos.
/// Must be called on sign-out: the next user's data must never merge into
/// this one's.
Future<void> clearScraperCache() async {
  Scraper._txnCache = null;
  Scraper._balanceIdCache = null;
  Scraper._unmappableIds.clear();
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(kCachedTransactionsKey);
  await prefs.remove(kBalanceIdMapKey);
}

/// User-facing name for a raw scraped account name. The site's internal
/// "FLEXIBLE" reads as "FLEX DOLLARS"; any other account is title-cased.
String accountDisplayName(String name) {
  if (name.toUpperCase() == 'FLEXIBLE') return 'FLEX DOLLARS';
  return name
      .split(RegExp(r'\s+'))
      .map((w) => w.isEmpty
          ? w
          : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
      .join(' ');
}

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

  /// User-facing name — see [accountDisplayName].
  String get displayName => accountDisplayName(name);
}

/// One row from the TouchNet transaction-history table.
class Transaction {
  final String dateTime;
  final String type;
  final String terminal;
  final String amount;

  /// The site's opaque account number from the row's `Balance` column (e.g.
  /// "5"). Matches an entry in the [kBalanceIdMapKey] map, which resolves it
  /// to an account name — how transactions are attributed to an account.
  /// Empty when the column is missing.
  final String balanceId;

  const Transaction({
    required this.dateTime,
    required this.type,
    required this.terminal,
    required this.amount,
    this.balanceId = '',
  });

  /// Round-tripping for the on-device cache ([kCachedTransactionsKey]).
  factory Transaction.fromJson(Map<String, dynamic> json) => Transaction(
        dateTime: json['dateTime'] as String? ?? '',
        type: json['type'] as String? ?? '',
        terminal: json['terminal'] as String? ?? '',
        amount: json['amount'] as String? ?? '',
        balanceId: json['balanceId'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'dateTime': dateTime,
        'type': type,
        'terminal': terminal,
        'amount': amount,
        'balanceId': balanceId,
      };

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

  // ─────────────────── incremental transaction sync ───────────────────

  /// Isolate-local copy of the on-disk transaction cache, so repeated syncs
  /// don't re-read and re-decode prefs.
  static List<Transaction>? _txnCache;

  /// FromDate for the very first sync, when nothing is cached — far enough
  /// back to cover any account's full history in one request.
  static final DateTime _txnEpoch = DateTime(2000, 3, 9);

  /// The cached transactions (newest first), or null when nothing has ever
  /// been synced. This is what the UI should render immediately on launch,
  /// before any network round trip.
  Future<List<Transaction>?> loadCachedTransactions() async {
    if (_txnCache != null) return _txnCache;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kCachedTransactionsKey);
    if (raw == null) return null;
    try {
      _txnCache = (jsonDecode(raw) as List)
          .map((e) => Transaction.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      // Unreadable cache (e.g. a schema change) — fall back to a full sync.
      await DebugLog.log("txns: cache unreadable ($e); resyncing from epoch");
      return null;
    }
    return _txnCache;
  }

  /// Incremental fetch: asks the site only for rows since the day *before*
  /// the newest cached transaction (the one-day overlap absorbs same-day rows
  /// that landed after the last sync), merges them into the cache, and
  /// returns the full history. First run (empty cache) fetches everything
  /// since [_txnEpoch].
  Future<List<Transaction>> syncTransactions(String cookies) async {
    final cached = await loadCachedTransactions();

    DateTime? newest;
    for (final t in cached ?? const <Transaction>[]) {
      final d = t.parsedDate;
      if (d != null && (newest == null || d.isAfter(newest))) newest = d;
    }
    final from = newest == null
        ? _txnEpoch
        : DateTime(newest.year, newest.month, newest.day)
            .subtract(const Duration(days: 1));

    final fresh =
        await fetchTransactions(cookies, from: from, to: DateTime.now());

    // The server is authoritative for the requested window: keep only cached
    // rows strictly before it, take the fresh rows wholesale. (Deduplicating
    // by row content instead would wrongly collapse two identical same-second
    // purchases.) Cached rows with unparseable dates are dropped — if dates
    // ever stop parsing, `newest` is null and we resync from the epoch anyway.
    final merged = <Transaction>[
      ...fresh,
      ...?cached?.where((t) {
        final d = t.parsedDate;
        return d != null && d.isBefore(from);
      }),
    ];
    merged.sort((a, b) {
      final da = a.parsedDate, db = b.parsedDate;
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return db.compareTo(da);
    });

    _txnCache = merged;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      kCachedTransactionsKey,
      jsonEncode([for (final t in merged) t.toJson()]),
    );
    await DebugLog.log(
        "txns: synced ${fresh.length} rows since ${_fmt(from)}; cache now ${merged.length}");
    return merged;
  }

  /// Scrapes the transaction history table for a date range. The page tops
  /// out at 1000 rows; we cap the request there. Most callers want
  /// [syncTransactions] instead — this hits the site for the whole window
  /// every time.
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

    final txns = parse(res.body)
        .querySelectorAll('#transaction-history-result-table tbody tr')
        .map((r) {
      String cell(String title) =>
          r.querySelector('td[data-title="$title"]')?.text.trim() ?? "";
      return Transaction(
        dateTime: cell("Date - Time"),
        type: cell("Type"),
        terminal: cell("Terminal"),
        amount: cell("Amount"),
        balanceId: cell("Balance"),
      );
    }).toList();

    // Keep the account ↔ balance-ID map in step with what the rows actually
    // reference — a no-op (no network) once every seen ID is known. Mapping
    // problems must never take down the transaction list itself.
    try {
      await ensureBalanceIdMap(
        cookies,
        seenBalanceIds: txns.map((t) => t.balanceId),
        token: token,
      );
    } catch (e) {
      await DebugLog.log("map: ensure failed: $e");
    }

    return txns;
  }

  // ─────────────────── account ↔ balance-ID mapping ───────────────────

  /// Isolate-local copy of the stored map so repeated fetches don't re-read
  /// prefs, plus the IDs that survived a re-fetch still unmapped (an account
  /// with no activity in the current statement can't be mapped yet) so one
  /// stubborn ID can't trigger a CurrentStatement request on every refresh.
  static Map<String, String>? _balanceIdCache;
  static final Set<String> _unmappableIds = {};

  /// Returns the account-name → balance-ID map, fetching it from the site
  /// only when needed: when nothing is stored yet, or when [seenBalanceIds]
  /// (from freshly scraped transaction rows) contains an ID the stored map
  /// doesn't know — the signal that a new account type appeared.
  Future<Map<String, String>> ensureBalanceIdMap(
    String cookies, {
    Iterable<String> seenBalanceIds = const [],
    String? token,
  }) async {
    var map = _balanceIdCache;
    if (map == null) {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(kBalanceIdMapKey);
      map = stored == null
          ? <String, String>{}
          : Map<String, String>.from(jsonDecode(stored) as Map);
      _balanceIdCache = map;
    }

    final unknown = seenBalanceIds
        .where((id) =>
            id.isNotEmpty &&
            !map!.containsValue(id) &&
            !_unmappableIds.contains(id))
        .toSet();
    if (map.isNotEmpty && unknown.isEmpty) return map;

    map = await fetchBalanceIdMap(cookies, token: token);
    for (final id in unknown.where((id) => !map!.containsValue(id))) {
      _unmappableIds.add(id);
      await DebugLog.log(
          "map: balance ID $id not in current statement; deferring");
    }
    return map;
  }

  /// Scrapes `/TransactionHistory/CurrentStatement`, whose response is one
  /// card per account carrying both the account's name and transaction rows
  /// with that account's balance ID — the only place the two appear together.
  /// Stores the resulting map (prefs + cache) and logs it.
  Future<Map<String, String>> fetchBalanceIdMap(
    String cookies, {
    String? token,
  }) async {
    token ??= await _token(cookies);

    final res = await http.post(
      Uri.parse("$_base/TransactionHistory/CurrentStatement"),
      headers: {
        ..._ajaxHeaders(cookies),
        "Origin": "https://secure.touchnet.net",
        "Referer": "$_base/TransactionHistory/Transactions",
      },
      body: {"__RequestVerificationToken": token},
    );

    final map = _parseBalanceIdMap(res.body);
    if (map.isEmpty) {
      await DebugLog.log("map: CurrentStatement yielded no account mappings");
      return _balanceIdCache ?? {};
    }

    // Merge over what's known rather than replace: an account with no
    // activity this statement period drops out of the response, but its ID
    // hasn't changed.
    final merged = {...?_balanceIdCache, ...map};
    _balanceIdCache = merged;
    _unmappableIds.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kBalanceIdMapKey, jsonEncode(merged));
    await DebugLog.log(
        "map: stored account balance IDs: ${merged.entries.map((e) => '${e.key}=${e.value}').join(', ')}");
    return merged;
  }

  /// Resolves a transaction row's balance ID to its raw account name (e.g.
  /// "5" → "FLEXIBLE"), or null when unmapped. Feed the result through
  /// [accountDisplayName] for the UI.
  static String? accountNameForBalanceId(
          Map<String, String> map, String balanceId) =>
      map.entries
          .where((e) => e.value == balanceId)
          .map((e) => e.key)
          .firstOrNull;

  /// One card of the CurrentStatement response: the account name sits in a
  /// `<p><span class="statement-info">Name</span>FLEXIBLE</p>` line, and every
  /// row of the card's table carries that account's balance ID in its
  /// `Balance` column. A card whose table has no rows can't be mapped.
  Map<String, String> _parseBalanceIdMap(String html) {
    final out = <String, String>{};
    for (final card in parse(html).querySelectorAll('.oc-card')) {
      String? name;
      for (final p in card.querySelectorAll('p')) {
        final label = p.querySelector('span.statement-info');
        if (label?.text.trim() == 'Name') {
          name = p.text.replaceFirst(label!.text, '').trim();
          break;
        }
      }
      final id = card.querySelector('td[data-title="Balance"]')?.text.trim();
      if (name == null || name.isEmpty || id == null || id.isEmpty) continue;
      out[name] = id;
    }
    return out;
  }

  /// Refreshes the transactions widget with the 8 most-recent rows, via the
  /// incremental sync (which returns the full history newest-first).
  Future<void> refreshTransactionsWidget(String cookies) async {
    final txns = await syncTransactions(cookies);
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
