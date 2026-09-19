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

  /// Whether this user must qualify an email address before signing in. False
  /// once a real sign-in has ever succeeded, which collapses the screen back to
  /// a single "Sign In" button that goes straight to the University flow.
  bool _requireEmail = false;

  /// Set once the entered address is the demo one, revealing the password field.
  bool _askPassword = false;

  final _emailController = TextEditingController();
  final _passController = TextEditingController();
  String? _formError;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final saved = await loadSession();
    if (saved != null) {
      // An existing real session is itself proof of a past real sign-in. This
      // also migrates users who installed before the email gate existed, so
      // they're never asked to qualify an address they've already used.
      if (!isDemoSession(saved)) await markRealSignIn();
      _tryFetch(saved);
      return;
    }

    // No session. Only drive straight into the University flow for someone who
    // has already completed a real sign-in — for them the silent re-auth is the
    // whole point, since it usually restores the session with no UI at all.
    //
    // Everyone else must go through the email gate, so we stop here and let the
    // Sign In button start it. Without this, landing on this screen would shove
    // the University's login page in front of someone who never asked for it —
    // which is exactly what happened after signing out of the demo, and on a
    // brand-new install it skipped the gate entirely.
    if (await hasEverSignedInForReal()) {
      _trySilentThenPrompt();
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _requireEmail = true;
      _status = "Sign in to see your balance.";
    });
  }

  Future<void> _tryFetch(String cookies, {bool fromLogin = false}) async {
    setState(() {
      _busy = true;
      _status = "Fetching your balance…";
    });
    try {
      final accounts = await Scraper().fetchBalances(cookies);
      // Only a real session qualifies: a demo sign-in must not unlock the
      // straight-to-UW path, so demo users keep seeing the email step.
      if (!isDemoSession(cookies)) await markRealSignIn();
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

  /// Handles the inline email field.
  ///
  /// A University of Waterloo address hands off to the real sign-in (which is
  /// necessarily a popup — it's the University's own page in a WebView). The
  /// demo address reveals the password field below. Anything else is rejected
  /// inline, so a student who mistypes their address is told their email is
  /// wrong rather than being asked for a password that could never work.
  void _submitEmail() {
    final email = _emailController.text;
    if (isUwaterlooEmail(email)) {
      FocusScope.of(context).unfocus();
      _trySilentThenPrompt();
      return;
    }
    if (isDemoUsername(email)) {
      setState(() {
        _askPassword = true;
        _formError = null;
      });
      return;
    }
    setState(() => _formError = "Invalid email address");
  }

  /// Handles the inline demo password field. Only the demo password can reach
  /// this; nothing typed here is ever sent anywhere.
  Future<void> _submitPassword() async {
    if (!isDemoLogin(_emailController.text, _passController.text)) {
      setState(() => _formError = "Incorrect password.");
      return;
    }
    FocusScope.of(context).unfocus();
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            // Stretch to full width so content stays centred in the busy
            // state too (which has no full-width child to expand the column).
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 3),
              _Brandmark(scheme: scheme),
              const Spacer(flex: 4),
              if (_busy) _busyFooter(scheme) else _signInFooter(scheme),
              const Spacer(flex: 2),
            ],
          ),
        ),
      ),
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

  /// Sign-in footer.
  ///
  /// Returning users (anyone who has completed a real sign-in) get a single
  /// Sign In button straight into the University flow. First-timers get the
  /// email field inline on the page instead, which then reveals a password field
  /// if the address is the demo one.
  Widget _signInFooter(ColorScheme scheme) {
    return Column(
      children: [
        Text(
          _status,
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15),
        ),
        const SizedBox(height: 24),
        if (_requireEmail)
          ..._emailForm()
        else
          _primaryButton(label: "Sign In", onPressed: _trySilentThenPrompt),
      ],
    );
  }

  /// The inline gate: an email field, plus a password field once the demo
  /// address has been entered.
  List<Widget> _emailForm() {
    return [
      TextField(
        controller: _emailController,
        autocorrect: false,
        keyboardType: TextInputType.emailAddress,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: "Email",
          hintText: "",
          border: const OutlineInputBorder(),
          errorText: _askPassword ? null : _formError,
        ),
        // The field stays editable during the password step. Disabling it also
        // disables everything in its decoration, which is why the old "Change"
        // button couldn't be tapped (and why the field looked greyed out).
        // Editing the address away from the demo one collapses the password
        // field instead, so a password can never be submitted against an
        // address it doesn't belong to.
        onChanged: (value) {
          if (_askPassword && !isDemoUsername(value)) {
            setState(() {
              _askPassword = false;
              _formError = null;
              _passController.clear();
            });
          }
        },
        onSubmitted: (_) => _submitEmail(),
      ),
      if (_askPassword) ...[
        const SizedBox(height: 12),
        TextField(
          controller: _passController,
          autofocus: true,
          obscureText: true,
          autocorrect: false,
          textInputAction: TextInputAction.go,
          decoration: InputDecoration(
            labelText: "Password",
            border: const OutlineInputBorder(),
            errorText: _formError,
          ),
          onSubmitted: (_) => _submitPassword(),
        ),
      ],
      const SizedBox(height: 20),
      _primaryButton(
        label: _askPassword ? "Continue" : "Next",
        onPressed: _askPassword ? _submitPassword : _submitEmail,
      ),
    ];
  }

  Widget _primaryButton({
    required String label,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        child: Text(label),
      ),
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
