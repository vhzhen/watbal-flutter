import 'package:flutter/material.dart';

/// Full-page disclaimer, reachable from Settings → Disclaimer → "View
/// disclaimer".
///
/// Covers the three things that actually matter for shipping an unofficial
/// client: that this app has no relationship with the University of Waterloo or
/// TouchNet, exactly what data it keeps and where (which doubles as the
/// user-facing half of the Play Store Data safety declaration), and the
/// warranty/liability position.
///
/// Keep [_sections] in sync with what the code really stores — an inaccurate
/// data disclosure is worse than none, both for users and for the Play listing.
class DisclaimerPage extends StatelessWidget {
  const DisclaimerPage({super.key});

  static const List<({String heading, String body})> _sections = [
    (
      heading: 'No affiliation with the University of Waterloo',
      body:
          'WatBal is an independent, unofficial application. It is not '
          'affiliated with, authorized by, endorsed by, sponsored by, or in any '
          'way officially connected to the University of Waterloo, the WatCard '
          'Office, or TouchNet Information Systems, Inc.\n\n'
          '"University of Waterloo", "WatCard", "TouchNet", and all related '
          'names, marks, and logos are the property of their respective owners. '
          'They are used here in a purely descriptive sense to identify the '
          'service this app displays information from. No claim of ownership or '
          'association is made or implied.',
    ),
    (
      heading: 'Educational purpose',
      body:
          'This app was built and is published as a personal, non-commercial '
          'project for educational purposes — to learn mobile development, '
          'session handling, and home-screen widget integration. It is provided '
          'free of charge, contains no advertising, and no payment of any kind '
          'is collected.',
    ),
    (
      heading: 'Your sign-in credentials are never stored',
      body:
          'Your username, password, and two-factor responses are entered only '
          'on the University of Waterloo\'s own sign-in pages, loaded directly '
          'from the University inside the in-app login window. The app does not '
          'read, record, transmit, or store them at any point, and the '
          'developer never has access to them.\n\n'
          'If you choose to save your credentials, that is handled entirely by '
          'your device\'s own password manager (Google Password Manager on '
          'Android, iCloud Keychain on iOS) — not by this app.',
    ),
    (
      heading: 'What is stored on your device',
      body:
          'Everything the app keeps is stored locally on your device only:\n\n'
          '•  Session cookies — the sign-in session issued by the University '
          'after you authenticate, held in the operating system\'s encrypted '
          'credential store (Android Keystore-backed storage / iOS Keychain) so '
          'balances can be refreshed without signing in repeatedly.\n\n'
          '•  Account information — your account names, current balances, and '
          'transaction history (date, merchant/terminal, type, and amount), '
          'cached so the app works offline and only needs to download new '
          'activity.\n\n'
          '•  Home-screen widget data — the balance you selected to display and '
          'up to eight recent transactions, stored where the operating system '
          'can read them to draw the widget.\n\n'
          '•  Your preferences — theme, which account the widget shows, and your '
          'meal plan settings and term dates.\n\n'
          '•  A diagnostic log — timestamps, account names, and error messages '
          'from background refreshes, viewable under Settings → Logs. It never '
          'contains your password or your session cookies.',
    ),
    (
      heading: 'Nothing is sent anywhere else',
      body:
          'The developer operates no servers and receives none of your data. '
          'This app contains no analytics, telemetry, advertising, tracking, or '
          'crash-reporting services, and your information is never sold, shared, '
          'or transmitted to any third party.\n\n'
          'The only network connections the app makes are to the University of '
          'Waterloo\'s own systems, to retrieve your balances and transactions '
          'the same way your web browser would. All such traffic is encrypted '
          'over HTTPS.',
    ),
    (
      heading: 'Deleting your data',
      body:
          'Signing out clears your session, your cached balances and '
          'transactions, the data shown on the widget, and the diagnostic log. '
          'Uninstalling the app removes all remaining local data. App data is '
          'excluded from cloud backups and device-to-device transfers, so it '
          'does not leave your device.',
    ),
    (
      heading: 'Accuracy of information',
      body:
          'Balances and transactions are read from a third-party website whose '
          'structure, availability, and behaviour may change without notice. '
          'The information shown may therefore be delayed, incomplete, '
          'inaccurate, or unavailable, and the meal plan pacing figures are '
          'estimates only.\n\n'
          'Nothing in this app is financial advice. Always treat your official '
          'WatCard account statement as the authoritative record, and verify '
          'balances through official University channels before relying on them.',
    ),
    (
      heading: 'Provided without warranty',
      body:
          'This app is provided "as is" and "as available", without warranty of '
          'any kind, whether express, implied, or statutory, including but not '
          'limited to any implied warranties of merchantability, fitness for a '
          'particular purpose, accuracy, uninterrupted availability, or '
          'non-infringement. Use of this app is entirely at your own risk.',
    ),
    (
      heading: 'Limitation of liability',
      body:
          'To the maximum extent permitted by applicable law, the developer '
          'shall not be liable for any direct, indirect, incidental, special, '
          'consequential, exemplary, or punitive damages, or for any loss of '
          'data, funds, profits, access, or goodwill, arising out of or in '
          'connection with your use of — or inability to use — this app. This '
          'includes, without limitation, any consequence of inaccurate or '
          'unavailable balance information, any interruption or suspension of '
          'your account, or any action taken by the University of Waterloo or '
          'any third party in relation to your use of this app.',
    ),
    (
      heading: 'Your responsibilities',
      body:
          'You may use this app only with your own account and your own '
          'credentials. You are solely responsible for ensuring that your use '
          'complies with the University of Waterloo\'s acceptable use, '
          'information security, and account policies, and with the terms of any '
          'service you access through the app. Should the University or any '
          'other rights holder request it, you should discontinue use.',
    ),
    (
      heading: 'Changes to this disclaimer',
      body:
          'This disclaimer may be revised in future versions of the app. '
          'Continued use after an update constitutes acceptance of the revised '
          'disclaimer.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Disclaimer')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              'WatBal is an unofficial, independent app and is not affiliated '
              'with the University of Waterloo. Please read the following '
              'before using it.',
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (final section in _sections) ...[
            const SizedBox(height: 20),
            Text(
              section.heading,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              section.body,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
