import 'dart:async';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kDashboardUrl =
    "https://secure.touchnet.net/C22566_oneweb/Account/Dashboard";

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
Future<String?> trySilentReauth() async {
  final completer = Completer<String?>();
  HeadlessInAppWebView? headless;

  void finish(String? value) {
    if (!completer.isCompleted) completer.complete(value);
  }

  headless = HeadlessInAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(kDashboardUrl)),
    initialSettings: InAppWebViewSettings(
      clearCache: false,
      cacheEnabled: true,
      incognito: false,
    ),
    onLoadStop: (controller, url) async {
      if (completer.isCompleted) return;
      // Authenticated only if the Dashboard rendered with the anti-forgery
      // token (the same gate the scraper needs). Anything else — a redirect
      // to the IdP / login page — means a visible login is required.
      if (url == null || !url.toString().contains("Account/Dashboard")) {
        finish(null);
        return;
      }
      final html = await controller.getHtml();
      if (html == null ||
          !html.contains('name="__RequestVerificationToken"')) {
        finish(null);
        return;
      }
      final header = await harvestSessionHeader();
      if (header == null) {
        finish(null);
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("session_cookies", header);
      finish(header);
    },
    onReceivedError: (controller, request, error) {
      if (request.isForMainFrame ?? false) finish(null);
    },
    onReceivedHttpError: (controller, request, response) {
      if (request.isForMainFrame ?? false) finish(null);
    },
  );

  await headless.run();
  final result = await completer.future
      .timeout(const Duration(seconds: 12), onTimeout: () => null);
  await headless.dispose();
  return result;
}
