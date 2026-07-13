import 'package:shared_preferences/shared_preferences.dart';

import 'package:watbal/scraper.dart';

/// Meal-plan burn-down tracking. Unlike FLEX (which you top up), a meal plan is
/// a fixed pot you want to *finish* by the end of the term — so the useful
/// question is "how much can I spend per day to run it to zero on time, and am
/// I on pace?" The user designates one account as their meal plan and sets its
/// term dates; [MealPlanPacing.compute] turns that plus the account's balance
/// and transactions into an allowance + a verdict.

const String _kAccountKey = 'meal_plan_account';
const String _kStartKey = 'meal_plan_start';
const String _kEndKey = 'meal_plan_end';
const String _kCtaDismissedKey = 'meal_plan_cta_dismissed';

/// Whether the user dismissed the "Track your meal plan" home-screen CTA. Only
/// hides that prompt — meal-plan setup stays reachable in the Features popup.
Future<bool> loadMealPlanCtaDismissed() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kCtaDismissedKey) ?? false;
}

Future<void> setMealPlanCtaDismissed(bool value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kCtaDismissedKey, value);
}

/// The user's meal-plan selection: which account, and the term window. Any
/// field may be null until the user finishes setup.
class MealPlanConfig {
  final String? accountName;
  final DateTime? start;
  final DateTime? end;

  const MealPlanConfig({this.accountName, this.start, this.end});

  /// Fully set up (account chosen and both dates entered) — the only state in
  /// which pacing can be computed.
  bool get isConfigured =>
      accountName != null && start != null && end != null;

  static Future<MealPlanConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return MealPlanConfig(
      accountName: prefs.getString(_kAccountKey),
      start: _parse(prefs.getString(_kStartKey)),
      end: _parse(prefs.getString(_kEndKey)),
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await _put(prefs, _kAccountKey, accountName);
    await _put(prefs, _kStartKey, start == null ? null : _fmt(start!));
    await _put(prefs, _kEndKey, end == null ? null : _fmt(end!));
  }

  /// Clears the meal-plan selection (the "None" choice). Deliberately *not*
  /// called on sign-out: the selection + term dates persist across logout so a
  /// returning user doesn't have to set them up again. Leaves the CTA-dismissed
  /// flag alone so re-selecting None doesn't resurrect a prompt the user hid.
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAccountKey);
    await prefs.remove(_kStartKey);
    await prefs.remove(_kEndKey);
  }

  MealPlanConfig copyWith({
    String? accountName,
    DateTime? start,
    DateTime? end,
  }) =>
      MealPlanConfig(
        accountName: accountName ?? this.accountName,
        start: start ?? this.start,
        end: end ?? this.end,
      );

  static Future<void> _put(
      SharedPreferences prefs, String key, String? value) async {
    if (value == null) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, value);
    }
  }

  static String _fmt(DateTime d) =>
      "${d.year.toString().padLeft(4, '0')}-"
      "${d.month.toString().padLeft(2, '0')}-"
      "${d.day.toString().padLeft(2, '0')}";

  static DateTime? _parse(String? s) {
    if (s == null) return null;
    final p = s.split('-');
    if (p.length != 3) return null;
    final y = int.tryParse(p[0]), m = int.tryParse(p[1]), d = int.tryParse(p[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }
}

/// Where the plan stands relative to finishing on time.
enum MealPlanStatus {
  /// Recent pace lands the balance at ~zero around term end.
  onTrack,

  /// Spending faster than the allowance — will run dry before term end.
  tooFast,

  /// Spending slower than the allowance — money will be left over.
  moneyToSpare,

  /// The term end date has passed.
  termEnded,
}

/// The computed pacing snapshot the dashboard card renders.
class MealPlanPacing {
  /// Dollars per remaining day to hit exactly zero at term end.
  final double perDayAllowance;

  /// Whole days from today until term end (0 once the term is over).
  final int daysRemaining;

  /// Current balance being paced down.
  final double balance;

  /// Recent average daily spend on this account (trailing window).
  final double recentDailyPace;

  /// Fraction of the term-start balance spent so far (0–1), for the progress
  /// bar: 0 = pot untouched, 1 = fully used. The start balance is
  /// reconstructed from history — the current balance with every transaction
  /// dated on/after term start undone — so spending *before* the term never
  /// counts against the pot.
  final double spentFraction;

  final MealPlanStatus status;

  const MealPlanPacing({
    required this.perDayAllowance,
    required this.daysRemaining,
    required this.balance,
    required this.recentDailyPace,
    required this.spentFraction,
    required this.status,
  });

  /// Days of slack between the projected run-out (at [recentDailyPace]) and
  /// term end that still counts as "on track".
  static const _onTrackSlackDays = 5;

  /// Trailing window (days) used to estimate the recent spending pace.
  static const _paceWindowDays = 14;

  /// Builds a pacing snapshot for a designated meal-plan account. [txns] should
  /// already be filtered to that account (e.g. via `_HomeController.txnsFor`).
  static MealPlanPacing compute({
    required double balance,
    required DateTime start,
    required DateTime end,
    required List<Transaction> txns,
    DateTime? now,
  }) {
    final today = _dateOnly(now ?? DateTime.now());
    final termStart = _dateOnly(start);
    final termEnd = _dateOnly(end);

    // Balance at term start = current balance with every transaction dated
    // on/after the start undone (amountValue is negative for debits, so
    // credits/top-ups also unwind correctly).
    var netSinceStart = 0.0;
    for (final t in txns) {
      final d = t.parsedDate;
      if (d == null) continue;
      if (_dateOnly(d).isBefore(termStart)) continue;
      netSinceStart += t.amountValue;
    }
    final startBalance = balance - netSinceStart;
    final spentFraction = startBalance <= 0
        ? 0.0
        : ((startBalance - balance) / startBalance).clamp(0.0, 1.0);

    if (!today.isBefore(termEnd)) {
      return MealPlanPacing(
        perDayAllowance: balance,
        daysRemaining: 0,
        balance: balance,
        recentDailyPace: 0,
        spentFraction: spentFraction,
        status: MealPlanStatus.termEnded,
      );
    }

    final daysRemaining = termEnd.difference(today).inDays.clamp(1, 1 << 31);
    final perDayAllowance = balance / daysRemaining;

    // Recent pace: debits over the trailing window, but never counting before
    // the term started.
    final windowStart = today.subtract(const Duration(days: _paceWindowDays));
    final effectiveStart =
        windowStart.isBefore(termStart) ? termStart : windowStart;
    final windowDays = today.difference(effectiveStart).inDays.clamp(1, 1 << 31);
    var spent = 0.0;
    for (final t in txns) {
      if (!t.isDebit) continue;
      final d = t.parsedDate;
      if (d == null) continue;
      final day = _dateOnly(d);
      if (day.isBefore(effectiveStart) || day.isAfter(today)) continue;
      spent += -t.amountValue; // debit values are negative
    }
    final recentDailyPace = spent / windowDays;

    // Compare where the current pace runs the balance to zero against term end.
    MealPlanStatus status;
    if (recentDailyPace <= 0) {
      status = MealPlanStatus.moneyToSpare;
    } else {
      final daysToRunout = balance / recentDailyPace;
      final projectedRunout =
          today.add(Duration(days: daysToRunout.round()));
      final slack = projectedRunout.difference(termEnd).inDays;
      if (slack.abs() <= _onTrackSlackDays) {
        status = MealPlanStatus.onTrack;
      } else if (slack < 0) {
        status = MealPlanStatus.tooFast; // runs out before term end
      } else {
        status = MealPlanStatus.moneyToSpare; // leftover at term end
      }
    }

    return MealPlanPacing(
      perDayAllowance: perDayAllowance,
      daysRemaining: daysRemaining,
      balance: balance,
      recentDailyPace: recentDailyPace,
      spentFraction: spentFraction,
      status: status,
    );
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
}
