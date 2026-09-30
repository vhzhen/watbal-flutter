import 'package:flutter_test/flutter_test.dart';
import 'package:watbal/home_page.dart';
import 'package:watbal/scraper.dart';

/// Tests for [txnDetailFields] and [txnDetailClipboardText], the data behind
/// the transaction detail sheet (tap a row in an account's history).
///
/// The sheet exists to show what the terse list row hides: the unabbreviated
/// timestamp, the raw terminal string *including* its numeric prefix, and which
/// account the row was attributed to. So the tests pin the site's real string
/// shapes ("00024 : WEBAPPS", "101 : PURCHASE", r"$-5.00") rather than tidy
/// fixtures.
void main() {
  Transaction txn({
    String dateTime = '06/14/2026 12:34:00 PM',
    String type = '101 : PURCHASE',
    String terminal = '00031 : TIM HORTONS',
    String amount = r'$-5.00',
  }) => Transaction(
    dateTime: dateTime,
    type: type,
    terminal: terminal,
    amount: amount,
  );

  String? valueFor(List<(String, String)> fields, String label) {
    for (final (l, v) in fields) {
      if (l == label) return v;
    }
    return null;
  }

  group('txnDetailFields', () {
    test(
      'renders the full timestamp, not the row\'s "Today"/time-only form',
      () {
        final fields = txnDetailFields(txn(), 'Flexible');
        expect(valueFor(fields, 'When'), 'Sun, Jun 14, 2026 at 12:34 PM');
      },
    );

    test('keeps the raw terminal prefix the list row strips', () {
      final fields = txnDetailFields(txn(), 'Flexible');
      // The row shows "TIM HORTONS"; the sheet is where "00031" is recoverable.
      expect(valueFor(fields, 'Terminal'), '00031 : TIM HORTONS');
      expect(valueFor(fields, 'Type'), 'PURCHASE');
      expect(valueFor(fields, 'Account'), 'Flexible');
    });

    test('falls back to the raw string when the date does not parse', () {
      final fields = txnDetailFields(txn(dateTime: 'sometime tuesday'), 'Meal');
      expect(valueFor(fields, 'When'), 'sometime tuesday');
    });

    test('drops empty fields instead of showing blank rows', () {
      final fields = txnDetailFields(txn(type: '', terminal: ''), 'Flexible');
      expect(valueFor(fields, 'Type'), isNull);
      expect(valueFor(fields, 'Terminal'), isNull);
      // "When" and "Account" always survive.
      expect(fields.map((f) => f.$1), ['When', 'Account']);
    });

    test('handles midnight and noon without a 0:00 / 0:00 PM', () {
      expect(
        valueFor(
          txnDetailFields(txn(dateTime: '06/14/2026 12:00:00 AM'), 'Flexible'),
          'When',
        ),
        'Sun, Jun 14, 2026 at 12:00 AM',
      );
      expect(
        valueFor(
          txnDetailFields(txn(dateTime: '06/14/2026 12:05:00 PM'), 'Flexible'),
          'When',
        ),
        'Sun, Jun 14, 2026 at 12:05 PM',
      );
    });
  });

  group('txnDetailClipboardText', () {
    test('leads with merchant and signed amount, then one line per field', () {
      final text = txnDetailClipboardText(txn(), 'Flexible');
      expect(text.split('\n'), [
        'TIM HORTONS',
        r'-$5.00',
        'When: Sun, Jun 14, 2026 at 12:34 PM',
        'Type: PURCHASE',
        'Terminal: 00031 : TIM HORTONS',
        'Account: Flexible',
      ]);
    });

    test('labels an unnamed terminal rather than copying a blank line', () {
      final text = txnDetailClipboardText(txn(terminal: ''), 'Flexible');
      expect(text.split('\n').first, 'Transaction');
    });

    test('keeps a credit positive', () {
      final text = txnDetailClipboardText(
        txn(type: '102 : DEPOSIT', amount: r'$25.00'),
        'Flexible',
      );
      expect(text.split('\n')[1], r'$25.00');
    });
  });
}
