import 'package:flutter_test/flutter_test.dart';
import 'package:watbal/demo_data.dart';
import 'package:watbal/scraper.dart';

/// Tests for the Play-review demo account.
///
/// Two things matter: the fabricated data must be indistinguishable in *shape*
/// from real scraped data (or the UI silently renders nothing), and it must be
/// rich enough that a reviewer opening the Analytics tab sees every card
/// populated rather than an empty state.
void main() {
  group('demo credentials', () {
    test('accepts the exact demo credentials', () {
      expect(isDemoLogin(kDemoUsername, kDemoPassword), isTrue);
    });

    test('username is case-insensitive and tolerates padding', () {
      expect(isDemoLogin('  DEMO@WatBal.App ', kDemoPassword), isTrue);
    });

    test('rejects a wrong password and a wrong username', () {
      expect(isDemoLogin(kDemoUsername, 'nope'), isFalse);
      expect(isDemoLogin('someone@uwaterloo.ca', kDemoPassword), isFalse);
      expect(isDemoLogin('', ''), isFalse);
    });

    test('the sentinel session is recognised, and nothing else is', () {
      expect(isDemoSession(kDemoSessionHeader), isTrue);
      expect(isDemoSession('.ASPXAUTH=real; ROUTEID=.1'), isFalse);
      expect(isDemoSession(null), isFalse);
    });

    test('the sentinel is not a plausible cookie header', () {
      // If it ever escaped to the network it must fail, not authenticate.
      expect(kDemoSessionHeader.contains('ASPXAUTH'), isFalse);
      expect(kDemoSessionHeader.contains('='), isFalse);
    });
  });

  group('demo accounts', () {
    test('surface as "Meal Plan" and "FLEX DOLLARS" in the UI', () {
      final names = demoAccounts().map((a) => a.displayName).toList();
      expect(names, containsAll(['Meal Plan', 'FLEX DOLLARS']));
    });

    test('balances parse to numbers the pacing math can use', () {
      for (final a in demoAccounts()) {
        expect(a.amountValue, isNotNull, reason: '${a.name} balance unparseable');
        expect(a.amountValue!, greaterThan(0));
      }
    });

    test('every account has a distinct balance ID, so filtering works', () {
      final map = demoBalanceIdMap();
      for (final a in demoAccounts()) {
        expect(map[a.name], isNotNull, reason: '${a.name} has no balance ID');
      }
      expect(map.values.toSet().length, map.length, reason: 'IDs must be unique');
    });

    test('both accounts are attributable, so no count is suppressed', () {
      final accounts = demoAccounts();
      for (final a in accounts) {
        expect(
          isAccountAttributable(
            accountName: a.name,
            allAccountNames: accounts.map((x) => x.name),
            balanceIds: demoBalanceIdMap(),
          ),
          isTrue,
        );
      }
    });
  });

  group('demo transactions', () {
    final txns = demoTransactions();

    test('generates a substantial history', () {
      expect(txns.length, greaterThan(150));
    });

    test('is deterministic across calls', () {
      expect(demoTransactions().length, txns.length);
      expect(demoTransactions().first.dateTime, txns.first.dateTime);
    });

    test('every row has a parseable date, newest first', () {
      expect(txns.every((t) => t.parsedDate != null), isTrue);
      for (var i = 1; i < txns.length; i++) {
        expect(
          txns[i].parsedDate!.isAfter(txns[i - 1].parsedDate!),
          isFalse,
          reason: 'row $i is out of order',
        );
      }
    });

    test('every row carries a real clock time, not midnight', () {
      // Spending Patterns only buckets rows with a genuine timestamp.
      final timed = txns.where(
        (t) => t.parsedDate!.hour != 0 || t.parsedDate!.minute != 0,
      );
      expect(timed.length, txns.length);
    });

    test('every row maps to one of the demo accounts', () {
      final ids = demoBalanceIdMap().values.toSet();
      expect(txns.every((t) => ids.contains(t.balanceId)), isTrue);
      // Both accounts must actually have activity.
      for (final id in ids) {
        expect(
          txns.where((t) => t.balanceId == id).length,
          greaterThan(20),
          reason: 'account $id has too little activity to analyse',
        );
      }
    });

    test('contains both debits and credits', () {
      expect(txns.where((t) => t.isDebit).length, greaterThan(100));
      expect(txns.where((t) => !t.isDebit).length, greaterThan(3));
    });

    test('amounts parse, with debits negative and credits positive', () {
      for (final t in txns) {
        expect(t.amountValue, isNot(0), reason: '${t.amount} parsed as zero');
        expect(t.isDebit ? t.amountValue < 0 : t.amountValue > 0, isTrue);
      }
    });

    test('Top Places will have at least five distinct merchants', () {
      final merchants = withoutWebApps(txns)
          .where((t) => t.isDebit)
          .map((t) => t.terminalLabel)
          .toSet();
      expect(merchants.length, greaterThanOrEqualTo(5));
    });

    test('spending covers every weekday, so the pattern chart is populated', () {
      final weekdays = txns
          .where((t) => t.isDebit)
          .map((t) => t.parsedDate!.weekday)
          .toSet();
      expect(weekdays.length, 7);
    });

    test('spans enough months for "typical month" spend to be meaningful', () {
      final months = txns
          .map((t) => '${t.parsedDate!.year}-${t.parsedDate!.month}')
          .toSet();
      expect(months.length, greaterThanOrEqualTo(4));
    });

    test('has activity in the current month for the summary card', () {
      final now = DateTime.now();
      final thisMonth = txns.where(
        (t) =>
            t.parsedDate!.year == now.year && t.parsedDate!.month == now.month,
      );
      expect(thisMonth, isNotEmpty);
    });

    test('top-ups use the WEBAPPS terminal and are filtered from Top Places', () {
      final credits = txns.where((t) => !t.isDebit);
      expect(credits.every((t) => t.terminalLabel == kWebAppsTerminal), isTrue);
      expect(withoutWebApps(credits).toList(), isEmpty);
    });
  });
}
