import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watbal/scraper.dart';

/// Regression tests for the sign-out data-residue fix.
///
/// `home_widget` persists the pushed balance / transaction values in plaintext
/// platform storage, and the native widget renders whatever is there regardless
/// of whether a session still exists. Before [clearWidgetData] existed, signing
/// out left the previous user's balance and last 8 transactions painted on the
/// home screen indefinitely. These tests pin that behaviour by recording the
/// `home_widget` method-channel traffic.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('home_widget');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      // `getInstalledWidgets` is the only call whose return shape matters here.
      if (call.method == 'getInstalledWidgets') return <dynamic>[];
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// The keys nulled out by `saveWidgetData` during the call.
  Set<String> clearedKeys() => calls
      .where((c) => c.method == 'saveWidgetData' && c.arguments['data'] == null)
      .map<String>((c) => c.arguments['id'] as String)
      .toSet();

  group('clearWidgetData', () {
    test('nulls every financial key the widget renders', () async {
      await clearWidgetData();

      expect(
        clearedKeys(),
        containsAll(const [
          'balance_text',
          'balance_label',
          'transactions_json',
          'last_updated',
        ]),
        reason: 'a leftover value keeps the signed-out home screen showing the '
            'previous user account data',
      );
    });

    test('leaves the cosmetic theme preference alone', () async {
      await clearWidgetData();

      expect(clearedKeys(), isNot(contains('app_theme')),
          reason: 'the theme is not account data; wiping it would reset the '
              'widget appearance on every sign-out');
    });

    test('repaints the widgets so the cleared state is actually shown', () async {
      await clearWidgetData();

      expect(
        calls.map((c) => c.method),
        contains('updateWidget'),
        reason: 'clearing the stored values without a reload leaves the stale '
            'balance on screen until the next OS-driven update',
      );
    });
  });
}
