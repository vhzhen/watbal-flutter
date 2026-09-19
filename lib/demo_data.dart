import 'dart:math';

import 'package:watbal/scraper.dart';

/// Self-contained demo account, for Google Play's "App access" review
/// requirement.
///
/// The app has no accounts of its own — it replays a University of Waterloo
/// sign-in session — so there is no real credential that can be handed to a
/// reviewer. Instead, entering [kDemoUsername] / [kDemoPassword] on the sign-in
/// screen puts the app into demo mode, where every scrape is answered from the
/// synthetic data below and **no network request is ever made**.
///
/// How it hangs together: enabling demo mode writes [kDemoSessionHeader] as the
/// stored session. That value is deliberately not a valid `Cookie:` header, so
/// even if it somehow reached the network it would simply fail to authenticate.
/// Every existing "is there a session?" check keeps working untouched, and
/// [Scraper] short-circuits to this data whenever it sees the sentinel. Signing
/// out clears it like any other session, which also ends demo mode.

/// Credentials to give Google Play. Intentionally not secret: they unlock
/// nothing but the fabricated data in this file.
const String kDemoUsername = 'demo@watbal.app';
const String kDemoPassword = 'watbalrocks';

/// Sentinel stored in place of a session cookie header while in demo mode.
const String kDemoSessionHeader = 'watbal-demo-mode-no-network';

/// Whether [user] is the demo username, ignoring the password.
///
/// Used by the sign-in email gate to decide whether to advance to the password
/// step. Kept separate from [isDemoLogin] so an unrecognised address can be
/// rejected as an invalid email *before* anyone is asked for a password.
bool isDemoUsername(String user) =>
    user.trim().toLowerCase() == kDemoUsername;

/// Whether [user] / [pass] are the demo credentials. Username comparison is
/// case-insensitive and trimmed, since reviewers typically paste it.
bool isDemoLogin(String user, String pass) =>
    user.trim().toLowerCase() == kDemoUsername && pass == kDemoPassword;

/// Whether a stored session is the demo sentinel rather than real cookies.
bool isDemoSession(String? session) => session == kDemoSessionHeader;

// ─────────────────────────────── the data ──────────────────────────────────

/// Raw account names. These go through [accountDisplayName], which renders
/// "FLEXIBLE" as "FLEX DOLLARS" and title-cases everything else, so these
/// surface in the UI as "FLEX DOLLARS" and "Meal Plan".
const String _flexAccount = 'FLEXIBLE';
const String _mealPlanAccount = 'MEAL PLAN';

/// Opaque per-account balance IDs, mirroring the real site's scheme. Having two
/// distinct IDs is what lets the demo exercise per-account filtering — each
/// account shows its own transactions and its own analytics.
const String _flexBalanceId = '5';
const String _mealPlanBalanceId = '7';

Map<String, String> demoBalanceIdMap() => const {
  _flexAccount: _flexBalanceId,
  _mealPlanAccount: _mealPlanBalanceId,
};

/// Current balances. Chosen to look like a plausible mid-term state: a meal plan
/// being drawn down through the term, and a smaller flex balance.
List<AccountBalance> demoAccounts() => const [
  AccountBalance(name: _mealPlanAccount, amount: r'$412.68'),
  AccountBalance(name: _flexAccount, amount: r'$63.47'),
];

/// Where the demo spends, with the price band and which account it draws from.
/// The mix is deliberately uneven so "Top Places" produces a meaningful ranking
/// rather than a flat list.
const List<({String name, double min, double max, String account, int weight})>
_merchants = [
  // Meal-plan heavy: dining halls and campus food.
  (name: 'MUDIES', min: 9.25, max: 16.80, account: _mealPlanAccount, weight: 9),
  (
    name: 'REVELATION',
    min: 8.40,
    max: 14.50,
    account: _mealPlanAccount,
    weight: 7,
  ),
  (
    name: 'TIM HORTONS SLC',
    min: 2.35,
    max: 7.90,
    account: _mealPlanAccount,
    weight: 8,
  ),
  (
    name: 'WILLIAMS FRESH CAFE',
    min: 5.15,
    max: 12.40,
    account: _mealPlanAccount,
    weight: 4,
  ),
  (
    name: 'LIQUID ASSETS',
    min: 3.10,
    max: 9.75,
    account: _mealPlanAccount,
    weight: 3,
  ),
  // Flex-dollar spending: convenience, printing, vending.
  (name: 'ICON MARKET', min: 4.20, max: 18.60, account: _flexAccount, weight: 5),
  (name: 'PIZZA PIZZA', min: 6.50, max: 13.25, account: _flexAccount, weight: 3),
  (name: 'W PRINT', min: 0.40, max: 4.80, account: _flexAccount, weight: 4),
  (name: 'VENDING C2', min: 1.75, max: 3.50, account: _flexAccount, weight: 3),
  (name: 'BOOKSTORE', min: 12.00, max: 48.00, account: _flexAccount, weight: 1),
];

/// Meal windows, as (hour, minute-spread, relative likelihood). Real clock times
/// matter: the Spending Patterns card only buckets rows whose timestamp isn't
/// exactly midnight, so every generated row carries a real time.
const List<({int hour, int spread, int weight})> _mealSlots = [
  (hour: 8, spread: 50, weight: 3), // breakfast
  (hour: 12, spread: 55, weight: 9), // lunch — the busiest
  (hour: 15, spread: 45, weight: 3), // afternoon
  (hour: 18, spread: 50, weight: 7), // dinner
  (hour: 22, spread: 40, weight: 2), // late night
];

/// How many purchases happen on each weekday (Mon=1 … Sun=7), as a base count.
/// Weekdays are busier than weekends, which is what gives the weekday chart a
/// recognisable shape instead of a flat bar set.
const Map<int, int> _perWeekday = {
  1: 3,
  2: 3,
  3: 4,
  4: 3,
  5: 4,
  6: 2,
  7: 1,
};

/// Days of history to fabricate. Long enough that the 30/90/365-day analytics
/// windows all have data and "typical month" spend has completed months to
/// average over.
const int _historyDays = 160;

/// Cached so repeated calls (initial load, refresh, widget push) return an
/// identical list rather than regenerating.
List<Transaction>? _cached;

/// A fabricated transaction history, newest first — the same ordering the real
/// cache uses.
///
/// Deterministic: a fixed seed means every reviewer, device, and run sees the
/// same history, so a screenshot in a review note always matches. Dates are
/// relative to today, so the demo never goes stale.
List<Transaction> demoTransactions() {
  final cached = _cached;
  if (cached != null) return cached;

  final rng = Random(20260918);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final out = <Transaction>[];

  // Weighted pickers.
  final merchantPool = <int>[];
  for (var i = 0; i < _merchants.length; i++) {
    for (var w = 0; w < _merchants[i].weight; w++) {
      merchantPool.add(i);
    }
  }
  final slotPool = <int>[];
  for (var i = 0; i < _mealSlots.length; i++) {
    for (var w = 0; w < _mealSlots[i].weight; w++) {
      slotPool.add(i);
    }
  }

  for (var dayOffset = _historyDays; dayOffset >= 0; dayOffset--) {
    final day = today.subtract(Duration(days: dayOffset));

    // Top up the meal plan roughly monthly, and flex a little more often. These
    // are credits, so they make the balance-trend chart step upward instead of
    // sloping down forever. They also land on the WEBAPPS terminal, which the
    // Analytics tab filters out of Top Places / Spending Patterns.
    if (dayOffset % 34 == 3) {
      out.add(
        _txn(
          when: DateTime(day.year, day.month, day.day, 9, 14),
          terminal: 'WEBAPPS',
          type: '201 : DEPOSIT',
          amount: 250.00,
          isCredit: true,
          balanceId: _mealPlanBalanceId,
        ),
      );
    }
    if (dayOffset % 23 == 7) {
      out.add(
        _txn(
          when: DateTime(day.year, day.month, day.day, 20, 41),
          terminal: 'WEBAPPS',
          type: '201 : DEPOSIT',
          amount: 40.00,
          isCredit: true,
          balanceId: _flexBalanceId,
        ),
      );
    }

    var count = _perWeekday[day.weekday] ?? 2;
    // Some natural variance so the days aren't identical.
    if (rng.nextInt(4) == 0) count += 1;
    if (rng.nextInt(5) == 0) count -= 1;
    if (count <= 0) continue;

    final usedSlots = <int>{};
    for (var i = 0; i < count; i++) {
      // Avoid two purchases in the same meal window on the same day.
      var slotIdx = slotPool[rng.nextInt(slotPool.length)];
      var guard = 0;
      while (usedSlots.contains(slotIdx) && guard < 6) {
        slotIdx = slotPool[rng.nextInt(slotPool.length)];
        guard++;
      }
      usedSlots.add(slotIdx);

      final slot = _mealSlots[slotIdx];
      final m = _merchants[merchantPool[rng.nextInt(merchantPool.length)]];
      final minute = rng.nextInt(slot.spread);
      final amount = m.min + rng.nextDouble() * (m.max - m.min);

      out.add(
        _txn(
          when: DateTime(day.year, day.month, day.day, slot.hour, minute),
          terminal: m.name,
          type: '101 : PURCHASE',
          amount: amount,
          isCredit: false,
          balanceId: m.account == _flexAccount
              ? _flexBalanceId
              : _mealPlanBalanceId,
        ),
      );
    }
  }

  // Newest first, matching the real cache's ordering.
  out.sort((a, b) => b.parsedDate!.compareTo(a.parsedDate!));
  _cached = out;
  return out;
}

/// Builds one row in exactly the shape the scraper produces, so the rest of the
/// app can't tell the difference: a numeric-prefixed terminal, a `$`-formatted
/// amount that is negative for debits, and a US-style timestamp.
Transaction _txn({
  required DateTime when,
  required String terminal,
  required String type,
  required double amount,
  required bool isCredit,
  required String balanceId,
}) {
  final cents = amount.toStringAsFixed(2);
  return Transaction(
    dateTime: _formatDateTime(when),
    type: type,
    terminal: terminal == 'WEBAPPS' ? '00024 : WEBAPPS' : '000${_code(terminal)} : $terminal',
    amount: isCredit ? '\$$cents' : '\$-$cents',
    balanceId: balanceId,
  );
}

/// A stable pseudo terminal number per merchant, so the same place always shows
/// the same code the way the real site does.
int _code(String terminal) => 10 + (terminal.hashCode.abs() % 79);

/// "09/15/2026 12:34:00 PM" — the format [Transaction.parsedDate] expects.
String _formatDateTime(DateTime d) {
  final mm = d.month.toString().padLeft(2, '0');
  final dd = d.day.toString().padLeft(2, '0');
  final isPm = d.hour >= 12;
  var hour12 = d.hour % 12;
  if (hour12 == 0) hour12 = 12;
  final min = d.minute.toString().padLeft(2, '0');
  return '$mm/$dd/${d.year} $hour12:$min:00 ${isPm ? 'PM' : 'AM'}';
}
