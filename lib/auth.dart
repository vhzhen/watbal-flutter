import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  await CookieManager.instance().deleteAllCookies();
}

Future<String?> loadSession() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_prefsKey);
}

// ───────────────────────────── silent re-auth ──────────────────────────────

/// No-UI re-login using the WebView's persisted cookie store (DUO's
/// "remember this device" survives `.ASPXAUTH` expiry). Returns the cookie
/// header on success, or null if a visible login is required.
///
/// Critical subtlety: the TouchNet auth flow bounces through CAS/SSO URLs
/// even with valid cookies, so we must NOT bail negatively just because an
/// intermediate `onLoadStop` URL isn't the Dashboard — we'd cancel the
/// silent path before redirects complete and force the popup to appear for
/// what should be a no-op. Only finish positively when we see an
/// authenticated Dashboard; otherwise fall through to the timeout.
Future<String?> trySilentReauth() async {
  final completer = Completer<String?>();
  HeadlessInAppWebView? headless;

  Future<void> tryHarvest(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    if (completer.isCompleted) return;
    if (url == null || !url.toString().contains("Account/Dashboard")) return;
    final html = await controller.getHtml();
    if (html == null ||
        !html.contains('name="__RequestVerificationToken"')) {
      return;
    }
    final header = await _harvestCookieHeader();
    if (header == null) return;
    await saveSession(header);
    if (!completer.isCompleted) completer.complete(header);
  }

  headless = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(_dashboardUrl)),
    initialSettings: InAppWebViewSettings(
      cacheEnabled: true,
      javaScriptEnabled: true,
      sharedCookiesEnabled: true,
    ),
    onLoadStop: (c, url) => tryHarvest(c, url),
    onUpdateVisitedHistory: (c, url, _) => tryHarvest(c, url),
    onReceivedError: (_, req, err) {
      if (req.isForMainFrame ?? false) {
        debugPrint("[silentReauth] main-frame error: ${err.description}");
      }
    },
  );

  await headless.run();
  final result = await completer.future
      .timeout(const Duration(seconds: 18), onTimeout: () => null);
  await headless.dispose();
  return result;
}

// ───────────────────────────── visible login popup ─────────────────────────

bool _isDashboardUrl(WebUri? url) =>
    url != null && url.toString().contains("Account/Dashboard");

/// Full-height login popup. An opaque cover sits over the WebView so the
/// authenticated Dashboard is never briefly visible: the user sees the
/// spinner, then the actual login page, then the popup closes. The cover is
/// lifted only when the WebView lands on a non-Dashboard URL (a real login
/// form). Returns the cookie header on success, or null if the user backed
/// out.
class LoginWebView extends StatefulWidget {
  const LoginWebView({super.key});

  @override
  State<LoginWebView> createState() => _LoginWebViewState();
}

class _LoginWebViewState extends State<LoginWebView> {
  bool _done = false;
  bool _cover = true;
  double _progress = 0;

  Future<void> _evaluate(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    if (_done) return;

    if (!_isDashboardUrl(url)) {
      // On a real login / IdP / DUO page — let the user see it.
      if (_cover && mounted) setState(() => _cover = false);
      return;
    }

    // Dashboard URL could be authenticated Dashboard or login-form-served-
    // at-Dashboard-URL. The anti-forgery token is the reliable signal.
    final html = await controller.getHtml();
    final authed =
        html != null && html.contains('name="__RequestVerificationToken"');
    if (!authed) {
      if (_cover && mounted) setState(() => _cover = false);
      return;
    }

    final header = await _harvestCookieHeader();
    if (header == null) {
      if (_cover && mounted) setState(() => _cover = false);
      return;
    }

    _done = true;
    await saveSession(header);
    if (mounted) Navigator.of(context).pop(header);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Sign in"),
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
            ),
            onProgressChanged: (_, p) => setState(() => _progress = p / 100),
            onLoadStart: (controller, url) {
              // Cover during *any* navigation so we never flash the
              // authenticated Dashboard between redirects.
              if (!_cover && mounted && !_done) {
                setState(() => _cover = true);
              }
            },
            onLoadStop: (c, url) => _evaluate(c, url),
            onUpdateVisitedHistory: (c, url, _) => _evaluate(c, url),
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
