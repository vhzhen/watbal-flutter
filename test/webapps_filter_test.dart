import 'package:flutter_test/flutter_test.dart';
import 'package:watbal/scraper.dart';

/// Tests for [withoutWebApps], the filter behind excluding web-originated rows
/// from the Analytics tab's "Top Places" and "Spending Patterns".
///
/// Terminal strings use the site's real shapes: a numeric terminal prefix
/// ("00024 : WEBAPPS") for card taps at physical readers, and the same form for
/// online activity.
void main() {
  Transaction txn(String terminal, {String amount = r'$-5.00'}) => Transaction(
    dateTime: '06/14/2026 12:30:00 PM',
    type: '101 : PURCHASE',
    terminal: terminal,
    amount: amount,
  );

  group('withoutWebApps', () {
    test('drops the prefixed WEBAPPS terminal the site actually sends', () {
      final kept = withoutWebApps([txn('00024 : WEBAPPS')]).toList();
      expect(kept, isEmpty);
    });

    test('drops a bare WEBAPPS terminal with no numeric prefix', () {
      expect(withoutWebApps([txn('WEBAPPS')]).toList(), isEmpty);
    });

    test('matches case-insensitively and tolerates padding', () {
      for (final t in ['00024 : webapps', '00024 :   WebApps  ', '  WEBAPPS ']) {
        expect(
          withoutWebApps([txn(t)]).toList(),
          isEmpty,
          reason: 'should have dropped $t',
        );
      }
    });

    test('keeps real places, including names that merely contain WEBAPPS', () {
      final rows = [
        txn('00031 : TIM HORTONS'),
        txn('00012 : MARKET'),
        txn('00099 : WEBAPPS KIOSK'),
      ];
      final kept = withoutWebApps(rows).toList();
      expect(kept.length, 3);
      expect(
        kept.map((t) => t.terminalLabel),
        containsAll(['TIM HORTONS', 'MARKET', 'WEBAPPS KIOSK']),
        reason: 'only an exact terminal match should be excluded',
      );
    });

    test('removes only the WEBAPPS rows from a mixed list, order preserved', () {
      final rows = [
        txn('00031 : TIM HORTONS'),
        txn('00024 : WEBAPPS', amount: r'$50.00'),
        txn('00012 : MARKET'),
        txn('00024 : WEBAPPS'),
      ];
      expect(
        withoutWebApps(rows).map((t) => t.terminalLabel).toList(),
        ['TIM HORTONS', 'MARKET'],
      );
    });

    test('an empty terminal is not treated as WEBAPPS', () {
      // Top Places skips blank names on its own; this filter must not silently
      // swallow them, since Spending Patterns still counts those rows.
      expect(withoutWebApps([txn('')]).toList(), hasLength(1));
    });
  });
}
