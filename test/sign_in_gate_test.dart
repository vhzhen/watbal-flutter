import 'package:flutter_test/flutter_test.dart';
import 'package:watbal/auth.dart';
import 'package:watbal/demo_data.dart';

/// Tests for the first-run sign-in gate's routing rules.
///
/// The gate asks for an email and sends it one of three ways: a University of
/// Waterloo address to the real sign-in, the demo address to a password step,
/// and anything else to an "invalid email" error. Getting the domain check wrong
/// in either direction is costly — too strict locks students out of their own
/// app, too loose routes them somewhere confusing.
void main() {
  group('isUwaterlooEmail — accepts real student addresses', () {
    test('the plain uwaterloo.ca domain', () {
      expect(isUwaterlooEmail('vzhen@uwaterloo.ca'), isTrue);
    });

    test('subdomains, which students are also issued', () {
      expect(isUwaterlooEmail('v1zhen@edu.uwaterloo.ca'), isTrue);
      expect(isUwaterlooEmail('someone@connect.uwaterloo.ca'), isTrue);
    });

    test('is case-insensitive and tolerates pasted whitespace', () {
      expect(isUwaterlooEmail('  VZHEN@UWaterloo.CA  '), isTrue);
    });
  });

  group('isUwaterlooEmail — rejects everything else', () {
    test('other universities and consumer providers', () {
      expect(isUwaterlooEmail('student@utoronto.ca'), isFalse);
      expect(isUwaterlooEmail('someone@gmail.com'), isFalse);
    });

    test('lookalike domains that merely contain the name', () {
      // The check must anchor on the domain, not a substring match, or these
      // would sail through.
      expect(isUwaterlooEmail('me@uwaterloo.ca.evil.com'), isFalse);
      expect(isUwaterlooEmail('me@notuwaterloo.ca'), isFalse);
      expect(isUwaterlooEmail('me@fakeuwaterloo.ca'), isFalse);
    });

    test('the domain appearing only in the local part', () {
      expect(isUwaterlooEmail('uwaterloo.ca@gmail.com'), isFalse);
    });

    test('malformed input', () {
      for (final bad in ['', '   ', 'no-at-sign', '@uwaterloo.ca', 'me@', 'me']) {
        expect(isUwaterlooEmail(bad), isFalse, reason: 'accepted "$bad"');
      }
    });

    test('the demo address is not a UW address', () {
      // Critical: the demo must route to the password step, never to the real
      // University sign-in.
      expect(isUwaterlooEmail(kDemoUsername), isFalse);
    });
  });

  group('isDemoUsername — advances to the password step', () {
    test('matches the demo address, case-insensitively and trimmed', () {
      expect(isDemoUsername(kDemoUsername), isTrue);
      expect(isDemoUsername('  DEMO@WatBal.App  '), isTrue);
    });

    test('does not match a UW address or anything else', () {
      expect(isDemoUsername('vzhen@uwaterloo.ca'), isFalse);
      expect(isDemoUsername('demo@example.com'), isFalse);
      expect(isDemoUsername(''), isFalse);
    });
  });

  group('the three routes are mutually exclusive', () {
    test('no address is both a UW address and the demo address', () {
      for (final email in [
        'vzhen@uwaterloo.ca',
        'v1zhen@edu.uwaterloo.ca',
        kDemoUsername,
        'someone@gmail.com',
      ]) {
        expect(
          isUwaterlooEmail(email) && isDemoUsername(email),
          isFalse,
          reason: '"$email" matched both routes',
        );
      }
    });

    test('an address matching neither route is the rejected case', () {
      const rejected = 'someone@gmail.com';
      expect(isUwaterlooEmail(rejected), isFalse);
      expect(isDemoUsername(rejected), isFalse);
    });
  });
}
