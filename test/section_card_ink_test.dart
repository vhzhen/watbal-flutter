import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the layout invariant behind `_SectionCard` in home_page.dart.
///
/// The Settings "WIDGET ACCOUNT" section renders a `RadioListTile` for each
/// account, and only appears when the user holds more than one account. The
/// ListTile family paints its highlight and ink splashes onto the nearest
/// `Material` ancestor, so putting a coloured `BoxDecoration` between the two
/// hides those effects — Flutter asserts on it, which flooded the console with
/// "ListTile background color or ink splashes may be invisible" for anyone with
/// two or more accounts (including every demo session).
///
/// These tests encode why the card must supply its background via `Material`
/// rather than a decorated `Container`, so the pattern can't silently regress.
void main() {
  /// Mirrors the *old* card: colour supplied by a decorated Container.
  Widget decoratedCard({required Widget child}) => MaterialApp(
    home: Scaffold(
      body: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFFDDE3EE),
          borderRadius: BorderRadius.circular(24),
        ),
        child: child,
      ),
    ),
  );

  /// Mirrors the *current* card: colour supplied by a Material, with an
  /// undecorated Container for padding only.
  Widget materialCard({required Widget child}) => MaterialApp(
    home: Scaffold(
      body: Material(
        color: const Color(0xFFDDE3EE),
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: Container(padding: const EdgeInsets.all(20), child: child),
      ),
    ),
  );

  /// The widget the Settings screen actually builds per account.
  Widget radioList() => RadioGroup<String>(
    groupValue: 'FLEXIBLE',
    onChanged: (_) {},
    child: const Column(
      children: [
        RadioListTile<String>(
          value: 'FLEXIBLE',
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text('FLEX DOLLARS'),
        ),
        RadioListTile<String>(
          value: 'MEAL PLAN',
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text('Meal Plan'),
        ),
      ],
    ),
  );

  /// A single tile, for the negative case: with more than one, Flutter collapses
  /// the several assertions into an opaque "Multiple exceptions" summary and the
  /// specific message can no longer be asserted.
  Widget singleRadio() => RadioGroup<String>(
    groupValue: 'FLEXIBLE',
    onChanged: (_) {},
    child: const RadioListTile<String>(
      value: 'FLEXIBLE',
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('FLEX DOLLARS'),
    ),
  );

  testWidgets('a decorated container over a ListTile trips the assertion', (
    tester,
  ) async {
    await tester.pumpWidget(decoratedCard(child: singleRadio()));

    final error = tester.takeException();
    expect(error, isNotNull, reason: 'this is the regression being guarded');
    expect(
      error.toString(),
      contains('ink splashes'),
      reason: 'should be the ListTile/Material assertion specifically',
    );
  });

  testWidgets('a Material-backed card renders the same tiles cleanly', (
    tester,
  ) async {
    await tester.pumpWidget(materialCard(child: radioList()));

    expect(
      tester.takeException(),
      isNull,
      reason: 'Material must be the nearest ancestor so splashes have a canvas',
    );
    // And the content is still actually there.
    expect(find.text('FLEX DOLLARS'), findsOneWidget);
    expect(find.text('Meal Plan'), findsOneWidget);
  });

  testWidgets('tapping a tile in the Material card raises no exception', (
    tester,
  ) async {
    await tester.pumpWidget(materialCard(child: radioList()));

    // The splash is painted on tap — the moment the missing Material would bite.
    await tester.tap(find.text('Meal Plan'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
  });
}
