import 'package:flutter_test/flutter_test.dart';
import 'package:watbal/scraper.dart';

/// Tests for [isAccountAttributable], the guard that stops the dashboard from
/// printing the same transaction total under every account.
///
/// The account names and balance IDs here are the real ones observed in a
/// captured session: FLEXIBLE → "5" and TRANSFER MP → "7", with rows carrying
/// stale IDs (e.g. "6") from earlier statement periods.
void main() {
  const flex = 'FLEXIBLE';
  const transfer = 'TRANSFER MP';
  const both = [flex, transfer];

  group('isAccountAttributable', () {
    test('an account with a known balance ID is attributable', () {
      expect(
        isAccountAttributable(
          accountName: flex,
          allAccountNames: both,
          balanceIds: const {flex: '5', transfer: '7'},
        ),
        isTrue,
      );
    });

    test('the only account with an unknown ID is still attributable', () {
      // FLEXIBLE's rows are identifiable, so whatever is left over has to be
      // TRANSFER MP's — subtraction is sound with a single unknown.
      expect(
        isAccountAttributable(
          accountName: transfer,
          allAccountNames: both,
          balanceIds: const {flex: '5'},
        ),
        isTrue,
      );
    });

    test('a single-account user is always attributable, even with no map', () {
      // Nothing to divide: every row belongs to the one account. This is the
      // behaviour the "never silently lose rows" fallback depends on.
      expect(
        isAccountAttributable(
          accountName: flex,
          allAccountNames: const [flex],
          balanceIds: const {},
        ),
        isTrue,
      );
    });

    test('no account is attributable when the map is empty and there are two',
        () {
      // The regression: an empty map made every account report the entire
      // history, so both hero cards showed an identical count.
      for (final name in both) {
        expect(
          isAccountAttributable(
            accountName: name,
            allAccountNames: both,
            balanceIds: const {},
          ),
          isFalse,
          reason: '$name cannot be singled out when no ID is known',
        );
      }
    });

    test('a map holding only stale IDs does not make accounts attributable',
        () {
      // Balance IDs appear to be reissued between terms: rows can carry an ID
      // ("6") that belongs to neither current account. Such a map is keyed by
      // an account name that no longer exists, so both live accounts remain
      // unknown and therefore unattributable.
      expect(
        isAccountAttributable(
          accountName: flex,
          allAccountNames: both,
          balanceIds: const {'OLD MEAL PLAN': '6'},
        ),
        isFalse,
      );
    });

    test('three accounts with two unknown IDs are not attributable', () {
      const three = [flex, transfer, 'DINING'];
      for (final name in [transfer, 'DINING']) {
        expect(
          isAccountAttributable(
            accountName: name,
            allAccountNames: three,
            balanceIds: const {flex: '5'},
          ),
          isFalse,
          reason: 'the unclaimed rows could belong to either of the two',
        );
      }
      expect(
        isAccountAttributable(
          accountName: flex,
          allAccountNames: three,
          balanceIds: const {flex: '5'},
        ),
        isTrue,
      );
    });
  });
}
