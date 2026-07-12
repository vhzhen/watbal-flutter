import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watbal/scraper.dart';

const String _dashboardUrl =
    "https://secure.touchnet.net/C22566_oneweb/Account/Dashboard";
const String _appGroupId = 'group.com.vincent.watbal';
const String _prefsKey = 'session_cookies';

// ───────────────────────────── cookie persistence ──────────────────────────

/// We need the four wanted cookies in a single `Cookie:` header for the
/// scraper. The `__RequestVerificationToken` cookie has a rotating suffix,
/// so it's matched by prefix.
bool _wanted(String name) =>
    name == ".ASPXAUTH" ||
    name == "ASP.NET_OneWebLang" ||
    name == "ROUTEID" ||
    name.startsWith("__RequestVerificationToken");

/// Reads the four wanted cookies from the WebView's store and joins them into
/// a Cookie header. Returns null when `.ASPXAUTH` is missing — the signal that
/// the user isn't authenticated.
Future<String?> _harvestCookieHeader() async {
  final cookies =
      await CookieManager.instance().getCookies(url: WebUri(_dashboardUrl));
  if (!cookies.any((c) => c.name == ".ASPXAUTH")) return null;
  return cookies
      .where((c) => _wanted(c.name))
      .map((c) => "${c.name}=${c.value}")
      .join("; ");
}

/// Persists the cookie header in two stores: SharedPreferences for the Dart
/// code, and the iOS shared app group so the native widget-refresh task can
/// read it without bridging Flutter.
Future<void> saveSession(String header) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_prefsKey, header);
  try {
    await HomeWidget.setAppGroupId(_appGroupId);
    await HomeWidget.saveWidgetData<String>(_prefsKey, header);
  } catch (_) {
    // Android dev / no app group — non-fatal.
  }
}

/// Clears the session from both stores plus the WebView's cookie jar. The
/// jar matters: leaving `.ASPXAUTH` behind would let the next "sign in" pop
/// straight back into the account.
Future<void> clearSession() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_prefsKey);
  try {
    await HomeWidget.setAppGroupId(_appGroupId);
    await HomeWidget.saveWidgetData<String>(_prefsKey, null);
  } catch (_) {}
  // Cached transactions / account map belong to this login; a different user
  // signing in next must not inherit (or merge into) them. The meal-plan
  // selection + term dates are intentionally *kept* so a returning user doesn't
  // have to reconfigure them every sign-in.
  await clearScraperCache();
  await CookieManager.instance().deleteAllCookies();
}

Future<String?> loadSession() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_prefsKey);
}

/// Deletes every cookie the WebView jar holds for the TouchNet host, leaving
/// the IdP / DUO "remember this device" cookies (a different domain) untouched.
///
/// Two dead-session problems this solves at once:
///
/// 1. **Stale `.ASPXAUTH`.** When the server-side session expires the cookie
///    is *not* removed from the browser — the server just stops honouring it.
///    [LoginWebView] treats the cookie's mere presence as "already
///    authenticated" and would commit that dead session without ever showing
///    the login form.
/// 2. **Cookie build-up → permanent "400 Bad Request".** Each fresh TouchNet
///    session sets a new `__RequestVerificationToken_<suffix>` cookie with a
///    rotating suffix; the old ones are never overwritten or expired, they
///    just accumulate in the persistent jar. The background refresh re-auths
///    several times a day, so after a few weeks the Cookie header outgrows the
///    server's request-header limit and every page — the login form included —
///    comes back 400, surviving app restarts. Reinstalling was the only way
///    out before this prune existed.
///
/// Safe because it only runs when the TouchNet session is already dead: the
/// surviving SSO cookies re-mint every TouchNet cookie on the next pass
/// through the flow, so sign-in stays silent.
Future<void> _clearTouchnetCookies() async {
  final cm = CookieManager.instance();
  final url = WebUri(_dashboardUrl);
  try {
    for (final c in await cm.getCookies(url: url)) {
      final path = (c.path?.isNotEmpty ?? false) ? c.path! : "/";
      await cm.deleteCookie(url: url, name: c.name, path: path);
      // Backstop: getCookies can omit the path (notably on iOS), so also
      // clear the conventional paths TouchNet scopes cookies to.
      for (final p in const ["/", "/C22566_oneweb"]) {
        if (p != path) {
          await cm.deleteCookie(url: url, name: c.name, path: p);
        }
      }
    }
  } catch (_) {
    // No cookie store / nothing to clear — re-auth will surface any real issue.
  }
}

/// HTTP statuses a server answers with when the request headers themselves are
/// the problem — the signature of an overgrown cookie jar (see
/// [_clearTouchnetCookies]). 494 is nginx's pre-431 own code for it.
const Set<int> _headerOverflowStatuses = {400, 413, 431, 494};

// ───────────────────────────── silent re-auth ──────────────────────────────

/// No-UI re-login using the WebView's persisted cookie store (DUO's
/// "remember this device" survives `.ASPXAUTH` expiry). Returns the cookie
/// header on success, or null if a visible login is required.
///
/// Critical subtlety: the TouchNet auth flow bounces through CAS/SSO URLs
/// even with valid cookies, so we must NOT bail negatively just because an
/// intermediate `onLoadStop` URL isn't the Dashboard — that would cancel the
/// silent path before redirects complete and force the popup for what should
/// be a no-op. We finish positively on an authenticated Dashboard, and bail
/// fast only when a page renders a password field (the unambiguous "SSO is
/// dead, the user must sign in" signal). The 12s timeout is just a backstop.
Future<String?> trySilentReauth() async {
  // Start from a clean TouchNet jar. Callers only get here on a dead session
  // ("Session Expired" / no saved session), so nothing of value is lost, and
  // it keeps the jar from ever accumulating to the 400-Bad-Request point.
  await _clearTouchnetCookies();

  final completer = Completer<String?>();
  HeadlessInAppWebView? headless;

  Future<void> evaluate(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    if (completer.isCompleted) return;

    // These callbacks fire-and-forget, so once the completer resolves (success
    // or the 12s timeout) the `finally` below disposes the controller while an
    // in-flight `evaluate` may still be awaiting `getHtml()`. Calling onto a
    // disposed controller throws; with no `await` on the callback that becomes
    // an *unhandled* async exception. Swallow it — by then we already have our
    // answer and are tearing the headless webview down anyway.
    try {
      if (url != null && url.toString().contains("Account/Dashboard")) {
        // Reached the Dashboard. The anti-forgery token confirms we're
        // authenticated (vs. a login form served at the Dashboard URL).
        final html = await controller.getHtml();
        if (html == null ||
            !html.contains('name="__RequestVerificationToken"')) {
          return;
        }
        final header = await _harvestCookieHeader();
        if (header == null) return;
        await saveSession(header);
        if (!completer.isCompleted) completer.complete(header);
        return;
      }

      // Settled on a non-Dashboard page. A rendered password field means the
      // persisted SSO session is dead and the flow is stuck waiting for the
      // user — bail immediately instead of waiting out the timeout. (The CAS
      // /login endpoint 302-redirects a *valid* SSO session straight through
      // without rendering a form, so this only fires when login is truly
      // required.)
      final html = await controller.getHtml();
      if (html != null && html.contains('type="password"')) {
        if (!completer.isCompleted) completer.complete(null);
      }
    } catch (e) {
      debugPrint("[silentReauth] evaluate skipped: $e");
    }
  }

  headless = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(_dashboardUrl)),
    initialSettings: InAppWebViewSettings(
      cacheEnabled: true,
      javaScriptEnabled: true,
      sharedCookiesEnabled: true,
    ),
    onLoadStop: (c, url) => evaluate(c, url),
    onUpdateVisitedHistory: (c, url, _) => evaluate(c, url),
    onReceivedError: (_, req, err) {
      if (req.isForMainFrame ?? false) {
        debugPrint("[silentReauth] main-frame error: ${err.description}");
      }
    },
    onReceivedHttpError: (_, req, res) {
      // A header-overflow status after the TouchNet prune means the bloat is
      // on the SSO domain — nothing the silent path can fix. Fail fast to the
      // visible login (whose own recovery can wipe the whole jar) instead of
      // burning the 12s timeout.
      if ((req.isForMainFrame ?? false) &&
          _headerOverflowStatuses.contains(res.statusCode) &&
          !completer.isCompleted) {
        debugPrint("[silentReauth] main-frame HTTP ${res.statusCode}; bailing");
        completer.complete(null);
      }
    },
  );

  try {
    await headless.run();
    return await completer.future
        .timeout(const Duration(seconds: 12), onTimeout: () => null);
  } catch (e) {
    // Any headless-webview failure must fall through to the visible login
    // popup, never bubble up and leave the user with no way to sign in.
    debugPrint("[silentReauth] failed: $e");
    return null;
  } finally {
    try {
      await headless.dispose();
    } catch (_) {}
  }
}

// ───────────────────────────── visible login popup ─────────────────────────

/// Full-height login popup. An opaque cover sits over the WebView so the
/// authenticated Dashboard is never briefly visible: the user sees the
/// spinner, then the actual login page, then the popup closes.
///
/// Authentication is detected by the `.ASPXAUTH` cookie rather than the
/// rendered Dashboard HTML. The cookie is set on the redirect *into* the
/// Dashboard — before the page paints — so the moment it appears we keep the
/// cover up, stop the load, and pop. The Dashboard never renders. The cover is
/// lifted only on a page with no auth cookie (a real login / IdP / DUO form).
/// Returns the cookie header on success, or null if the user backed out.
class LoginWebView extends StatefulWidget {
  const LoginWebView({super.key});

  @override
  State<LoginWebView> createState() => _LoginWebViewState();
}

class _LoginWebViewState extends State<LoginWebView> {
  bool _done = false;
  bool _cover = true;
  double _progress = 0;
  int _recoveries = 0;
  String _url = _dashboardUrl;

  void _trackUrl(WebUri? url) {
    if (url == null || !mounted) return;
    final s = url.toString();
    if (s != _url) setState(() => _url = s);
  }

  /// Last-resort self-heal for a login page that itself answers with a
  /// header-overflow status (see [_headerOverflowStatuses]) — the state that
  /// used to require reinstalling the app. Two escalating steps: drop the
  /// TouchNet cookies (cheap — the SSO cookies survive, so sign-in stays
  /// silent), then, if it still fails, wipe the whole jar (costs one full DUO
  /// sign-in, the price of getting unstuck). Capped so a server that 400s for
  /// unrelated reasons just shows its error page instead of looping.
  Future<void> _recoverFromHeaderOverflow(
    InAppWebViewController controller,
    WebResourceRequest request,
    WebResourceResponse response,
  ) async {
    if (_done ||
        !(request.isForMainFrame ?? false) ||
        !_headerOverflowStatuses.contains(response.statusCode) ||
        _recoveries >= 2) {
      return;
    }
    _recoveries++;
    debugPrint(
        "[login] HTTP ${response.statusCode}; recovery attempt $_recoveries");
    if (_recoveries == 1) {
      await _clearTouchnetCookies();
    } else {
      await CookieManager.instance().deleteAllCookies();
    }
    if (_done || !mounted) return;
    await controller.loadUrl(
      urlRequest: URLRequest(url: WebUri(_dashboardUrl)),
    );
  }

  Future<void> _evaluate(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    if (_done) return;

    // The `.ASPXAUTH` cookie is set on the redirect *into* the Dashboard, so
    // it's available as early as onLoadStart — before the page paints.
    final header = await _harvestCookieHeader();
    if (header != null) {
      // Authenticated. Keep the cover up so the Dashboard is never visible.
      if (!_cover && mounted) setState(() => _cover = true);

      // Finalize only once the full session is present (`.ASPXAUTH` plus the
      // 3 other wanted cookies). On the rare early event where only the auth
      // cookie exists, stay covered and wait for the next event.
      if (header.split("; ").length >= 4) {
        _done = true;
        await controller.stopLoading();
        await saveSession(header);
        if (mounted) Navigator.of(context).pop(header);
      }
      return;
    }

    // No auth cookie → a real login / IdP / DUO page (or the login form served
    // at the Dashboard URL). Reveal it so the user can sign in.
    if (_cover && mounted) setState(() => _cover = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final secure = _url.startsWith("https");
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Sign in", style: TextStyle(fontSize: 16)),
            const SizedBox(height: 2),
            Row(
              children: [
                Icon(
                  secure ? Icons.lock_outline : Icons.info_outline,
                  size: 12,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    _url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(null),
        ),
        bottom: (_progress < 1.0 && !_cover)
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: _progress),
              )
            : null,
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(_dashboardUrl)),
            initialSettings: InAppWebViewSettings(
              cacheEnabled: true,
              isFraudulentWebsiteWarningEnabled: true,
              // Password autofill: on Android O+ the system autofill service
              // (e.g. Google Password Manager) fills WebView login forms, but
              // only when the WebView is a real view in the hierarchy — that's
              // hybrid composition. Both are package defaults; set explicitly so
              // saved-password autofill can't regress if a default changes.
              // saveFormData lets the login also *offer* to save new passwords.
              useHybridComposition: true,
              saveFormData: true,
            ),
            onProgressChanged: (_, p) => setState(() => _progress = p / 100),
            onLoadStart: (controller, url) {
              _trackUrl(url);
              // Cover during *any* navigation so we never flash the
              // authenticated Dashboard between redirects.
              if (!_cover && mounted && !_done) {
                setState(() => _cover = true);
              }
            },
            onLoadStop: (c, url) {
              _trackUrl(url);
              _evaluate(c, url);
            },
            onUpdateVisitedHistory: (c, url, _) {
              _trackUrl(url);
              _evaluate(c, url);
            },
            onReceivedHttpError: _recoverFromHeaderOverflow,
          ),
          if (_cover)
            Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              alignment: Alignment.center,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    "Checking your session…",
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
