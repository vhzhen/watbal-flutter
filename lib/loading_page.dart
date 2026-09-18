import 'package:flutter/material.dart';

import 'package:watbal/auth.dart';
import 'package:watbal/demo_data.dart';
import 'package:watbal/scraper.dart';

/// Cold-start / session-lost page. The order of fallbacks is the entire UX
/// story:
///
/// 1. **Stored cookies + working scrape** — instant, no UI flash.
/// 2. **Stored cookies that 401'd** — try a silent re-auth using the
///    WebView's persisted DUO-remembered cookies. Headless, no UI.
/// 3. **Silent re-auth failed** — only now show the actual login popup.
///
/// The whole point is that steps 2-most-of-the-time means the user almost
/// never sees a "please sign in" dialog after their first real login.
class LoadingPage extends StatefulWidget {
  final void Function(List<AccountBalance> accounts) onLoaded;
  const LoadingPage({super.key, required this.onLoaded});

  @override
  State<LoadingPage> createState() => _LoadingPageState();
}

class _LoadingPageState extends State<LoadingPage> {
  String _status = "Checking your session…";
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final saved = await loadSession();
    if (saved != null) {
      _tryFetch(saved);
    } else {
      _trySilentThenPrompt();
    }
  }

  Future<void> _tryFetch(String cookies, {bool fromLogin = false}) async {
    setState(() {
      _busy = true;
      _status = "Fetching your balance…";
    });
    try {
      final accounts = await Scraper().fetchBalances(cookies);
      if (mounted) widget.onLoaded(accounts);
    } catch (_) {
      if (!mounted) return;
      if (fromLogin) {
        // The user just completed a real login but the scrape still failed.
        // Reopening the popup would spin — surface the problem instead.
        setState(() {
          _busy = false;
          _status =
              "Signed in, but couldn't load your balance. Tap to try again.";
        });
      } else {
        _trySilentThenPrompt(expired: true);
      }
    }
  }

  Future<void> _trySilentThenPrompt({bool expired = false}) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _status = "Signing you in…";
    });

    // trySilentReauth starts by clearing the WebView's TouchNet cookies, so a
    // server-expired session's stale `.ASPXAUTH` (which LoginWebView would
    // mistake for a completed sign-in) is gone before either path runs.
    final silent = await trySilentReauth();
    if (!mounted) return;
    if (silent != null) {
      _tryFetch(silent, fromLogin: true);
      return;
    }

    // Silent path is dead — show the actual login form.
    setState(() {
      _busy = false;
      _status = expired
          ? "Your session expired. Please sign in again."
          : "Please sign in to see your balance.";
    });

    // Full-screen page rather than a modal bottom sheet: the sheet's own
    // window/IME handling suppresses the system autofill bar (saved passwords)
    // on Android, and a full page is the normal home for a login form anyway.
    final header = await Navigator.of(context).push<String?>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const LoginWebView(),
      ),
    );

    if (!mounted) return;
    if (header != null) {
      _tryFetch(header, fromLogin: true);
    } else {
      setState(() {
        _busy = false;
        _status = "Sign-in needed to load your balance.";
      });
    }
  }

  /// Demo sign-in, for Google Play's app-review credentials. Accepts only
  /// [kDemoUsername] / [kDemoPassword]; anything else is rejected so this can't
  /// be mistaken for a real sign-in form. On success the app switches to the
  /// fabricated demo dataset and makes no further network requests.
  Future<void> _showDemoSignIn() async {
    final userController = TextEditingController();
    final passController = TextEditingController();
    String? errorText;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          void submit() {
            if (isDemoLogin(userController.text, passController.text)) {
              Navigator.of(dialogContext).pop(true);
            } else {
              setDialogState(
                () => errorText = "Those aren't the demo credentials.",
              );
            }
          }

          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: const Text("Demo access"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "Sample data for app review. No WatCard account is "
                  "contacted and no network request is made.",
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: userController,
                  autofocus: true,
                  autocorrect: false,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: "Username"),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passController,
                  obscureText: true,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: "Password",
                    errorText: errorText,
                  ),
                  onSubmitted: (_) => submit(),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text("Cancel"),
              ),
              FilledButton(onPressed: submit, child: const Text("Continue")),
            ],
          );
        },
      ),
    );

    if (ok != true || !mounted) return;
    await enterDemoMode();
    if (!mounted) return;
    _tryFetch(kDemoSessionHeader, fromLogin: true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Two faces of the same screen: a branded splash while we're working
    // (cold-start session check / silent re-auth), and a professional sign-in
    // screen once we know the user has to tap Sign In.
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                // Stretch to full width so content stays centred in the busy
                // state too (which has no full-width child to expand the
                // column).
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(flex: 3),
                  _Brandmark(scheme: scheme),
                  const Spacer(flex: 4),
                  if (_busy)
                    _busyFooter(scheme)
                  else
                    _signInFooter(scheme),
                  const Spacer(flex: 2),
                ],
              ),
            ),
            // Settings affordance, overlaid rather than placed in an AppBar so
            // the brandmark stays vertically centred on the splash.
            Positioned(top: 4, right: 4, child: _settingsMenu(scheme)),
          ],
        ),
      ),
    );
  }

  /// Gear icon opening a small menu. Its only entry is demo access, which is
  /// how a Google Play reviewer reaches the sample dataset without a real
  /// WatCard account. Tucked behind a menu so it doesn't compete with the
  /// primary Sign In action for ordinary users.
  Widget _settingsMenu(ColorScheme scheme) {
    return PopupMenuButton<String>(
      tooltip: "Settings",
      icon: Icon(Icons.settings_outlined, color: scheme.onSurfaceVariant),
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: (value) {
        if (value == 'demo') _showDemoSignIn();
      },
      itemBuilder: (context) => const [
        PopupMenuItem<String>(
          value: 'demo',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(Icons.science_outlined),
            title: Text("Demo account"),
            subtitle: Text("Browse sample data"),
          ),
        ),
      ],
    );
  }

  /// Splash footer: a slim progress bar + status while the app works.
  Widget _busyFooter(ColorScheme scheme) {
    return Column(
      children: [
        SizedBox(
          width: 120,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 4,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          _status,
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15),
        ),
      ],
    );
  }

  /// Sign-in footer: a status line + a full-width primary Sign In button.
  Widget _signInFooter(ColorScheme scheme) {
    return Column(
      children: [
        Text(
          _status,
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _trySilentThenPrompt,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              textStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: const Text("Sign In"),
          ),
        ),
      ],
    );
  }
}

/// The app's logo lockup: a rounded balance-tile icon over the wordmark and a
/// tagline — the banking-app first impression.
class _Brandmark extends StatelessWidget {
  final ColorScheme scheme;
  const _Brandmark({required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(
            Icons.account_balance_wallet_rounded,
            size: 38,
            color: scheme.onPrimaryContainer,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          "WatBal",
          style: TextStyle(
            fontFamily: 'BureauGrot',
            fontSize: 32,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          "It's (un)official!",
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
