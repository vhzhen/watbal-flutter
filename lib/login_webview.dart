import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _dashboardUrl =
    "https://secure.touchnet.net/C22566_oneweb/Account/Dashboard";

bool _isDashboard(WebUri? url) =>
    url != null && url.toString().contains("Account/Dashboard");

/// Full-height login popup.
///
/// An opaque cover sits over the WebView so the authenticated Dashboard is
/// never visible: the user only ever sees the spinner or an actual login
/// page. The cover is lifted only when a login page is reached; it drops back
/// down the moment we navigate back toward the Dashboard, so the popup closes
/// straight from the spinner with no Dashboard flash.
///
/// Success is gated on the anti-forgery token being present in the Dashboard
/// HTML (the same thing the scraper needs) — checking cookie presence alone is
/// unreliable because the cookie names survive session expiry and cause a
/// stale-session spin.
class LoginWebView extends StatefulWidget {
  const LoginWebView({super.key});

  @override
  State<LoginWebView> createState() => _LoginWebViewState();
}

class _LoginWebViewState extends State<LoginWebView> {
  bool _handled = false;
  bool _cover = true; // opaque overlay hiding the WebView
  double _progress = 0;

  bool _isWanted(String name) =>
      name == ".ASPXAUTH" ||
      name == "ASP.NET_OneWebLang" ||
      name == "ROUTEID" ||
      name.startsWith("__RequestVerificationToken");

  Future<void> _evaluate(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    if (_handled) return;

    if (!_isDashboard(url)) {
      // On a login / IdP / DUO page — let the user see and interact with it.
      if (_cover && mounted) setState(() => _cover = false);
      return;
    }

    // On the Dashboard URL: is it the real authenticated page or the login
    // page served there? The token is only present when authenticated.
    final html = await controller.getHtml();
    final authed =
        html != null && html.contains('name="__RequestVerificationToken"');

    if (!authed) {
      if (_cover && mounted) setState(() => _cover = false);
      return;
    }

    final cookies =
        await CookieManager.instance().getCookies(url: WebUri(_dashboardUrl));
    if (!cookies.any((c) => c.name == ".ASPXAUTH")) {
      if (_cover && mounted) setState(() => _cover = false);
      return;
    }

    _handled = true;
    final header = cookies
        .where((c) => _isWanted(c.name))
        .map((c) => "${c.name}=${c.value}")
        .join("; ");
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("session_cookies", header);
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
              clearCache: false,
              cacheEnabled: true,
              incognito: false,
              isFraudulentWebsiteWarningEnabled: true,
            ),
            onProgressChanged: (controller, progress) {
              setState(() => _progress = progress / 100);
            },
            onLoadStart: (controller, url) {
              // Re-cover before the authenticated Dashboard can paint.
              if (_isDashboard(url) && !_cover && mounted) {
                setState(() => _cover = true);
              }
            },
            onLoadStop: (controller, url) => _evaluate(controller, url),
            onUpdateVisitedHistory: (controller, url, isReload) =>
                _evaluate(controller, url),
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
