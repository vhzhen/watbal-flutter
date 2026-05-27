import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kDashboardUrl =
    "https://secure.touchnet.net/C22566_oneweb/Account/Dashboard";

const String _kAppGroupId = 'group.com.vincent.watbal';

/// Persists the cookie header in both stores: SharedPreferences for the
/// in-app Dart code, and the shared app group (via home_widget) so the
/// native iOS background-refresh task can read it without bridging Flutter.
Future<void> saveSessionHeader(String header) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString("session_cookies", header);
  try {
    await HomeWidget.setAppGroupId(_kAppGroupId);
    await HomeWidget.saveWidgetData<String>('session_cookies', header);
  } catch (e) {
    debugPrint("[saveSessionHeader] app-group mirror failed: $e");
  }
}

/// Clears the cookie header from both stores. Use on sign-out.
Future<void> clearSessionHeader() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('session_cookies');
  try {
    await HomeWidget.setAppGroupId(_kAppGroupId);
    await HomeWidget.saveWidgetData<String>('session_cookies', null);
  } catch (e) {
    debugPrint("[clearSessionHeader] app-group clear failed: $e");
  }
}

/// The only cookies the scraper needs. The __RequestVerificationToken cookie
/// has a rotating suffix, so it's matched by prefix.
bool isWantedCookie(String name) =>
    name == ".ASPXAUTH" ||
    name == "ASP.NET_OneWebLang" ||
    name == "ROUTEID" ||
    name.startsWith("__RequestVerificationToken");

/// Reads the wanted cookies for the TouchNet domain and joins them into a
/// Cookie header. Returns null when the session cookie (.ASPXAUTH) is absent.
Future<String?> harvestSessionHeader() async {
  final cookies =
      await CookieManager.instance().getCookies(url: WebUri(kDashboardUrl));
  if (!cookies.any((c) => c.name == ".ASPXAUTH")) return null;
  return cookies
      .where((c) => isWantedCookie(c.name))
      .map((c) => "${c.name}=${c.value}")
      .join("; ");
}

/// Attempts a no-UI re-login using the WebView's persisted cookie store
/// (the DUO "remember this device" + .ASPXAUTH cookies that survive a scraper
/// session expiry). Returns the saved cookie header on success, or null if
/// the persisted session is gone and a visible login is required.
///
/// Renders nothing on screen, so there is no Dashboard flash.
///
/// Behaviour note: the TouchNet auth flow bounces through intermediate CAS /
/// SSO URLs even when cookies are valid (Dashboard → /login/check → IdP →
/// Dashboard). We must NOT finish negatively just because an intermediate
/// `onLoadStop` URL isn't `Account/Dashboard` — we'd cancel the silent path
/// before the redirect chain completes and force the visible popup to appear
/// for what should be a no-op login. Only finish positively when we see an
/// authenticated Dashboard, or fall through to the timeout otherwise.
Future<String?> trySilentReauth() async {
  final completer = Completer<String?>();
  HeadlessInAppWebView? headless;

  void finishOnce(String? value) {
    if (!completer.isCompleted) completer.complete(value);
  }

  Future<void> tryHarvest(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    if (completer.isCompleted) return;
    // Not at the Dashboard yet — could be mid-redirect through the SSO /
    // CAS chain. Keep waiting; another navigation will follow. The overall
    // timeout below catches the case where we get stuck on a login form.
    if (url == null || !url.toString().contains("Account/Dashboard")) {
      return;
    }
    // On the Dashboard URL: authenticated only if the anti-forgery token
    // is rendered. ASP.NET will sometimes serve the login form *at* the
    // Dashboard URL when unauthenticated, so URL alone isn't enough.
    final html = await controller.getHtml();
    if (html == null ||
        !html.contains('name="__RequestVerificationToken"')) {
      return; // stale session — let the timeout fall through to visible login
    }
    final header = await harvestSessionHeader();
    if (header == null) return;
    await saveSessionHeader(header);
    finishOnce(header);
  }

  headless = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(kDashboardUrl)),
    initialSettings: InAppWebViewSettings(
      clearCache: false,
      cacheEnabled: true,
      incognito: false,
      javaScriptEnabled: true,
      // Share cookies with the visible WebView's store — without this the
      // headless context can't see the DUO-remembered .ASPXAUTH cookie.
      sharedCookiesEnabled: true,
    ),
    // Use both callbacks: some redirects only fire `onUpdateVisitedHistory`
    // (client-side / pushState navigations) while real page loads fire
    // `onLoadStop`. Cover both so we don't miss the moment we land on
    // Dashboard.
    onLoadStop: (controller, url) => tryHarvest(controller, url),
    onUpdateVisitedHistory: (controller, url, isReload) =>
        tryHarvest(controller, url),
    onReceivedError: (controller, request, error) {
      // Subresource errors are noise (analytics, ads, fonts). Only a hard
      // main-frame failure means there's no way forward — even then, give
      // the rest of the chain a chance via the overall timeout instead of
      // killing the whole silent attempt. Log and continue.
      if (request.isForMainFrame ?? false) {
        debugPrint("[silentReauth] main-frame error: ${error.description}");
      }
    },
    onReceivedHttpError: (controller, request, response) {
      if (request.isForMainFrame ?? false) {
        debugPrint(
          "[silentReauth] main-frame HTTP ${response.statusCode}",
        );
      }
    },
  );

  await headless.run();
  // 18s — generous enough to absorb a slow IdP round-trip on cellular, short
  // enough that a truly dead session falls back to visible login promptly.
  final result = await completer.future
      .timeout(const Duration(seconds: 18), onTimeout: () => null);
  await headless.dispose();
  return result;
}
