import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _dashboardUrl =
    "https://secure.touchnet.net/C22566_oneweb/Account/Dashboard";

/// Full-height login popup.
///
/// Pops with the saved cookie header string the instant a valid session is
/// detected (no waiting for the dashboard to render), or with `null` if the
/// user dismisses it manually.
class LoginWebView extends StatefulWidget {
  const LoginWebView({super.key});

  @override
  State<LoginWebView> createState() => _LoginWebViewState();
}

class _LoginWebViewState extends State<LoginWebView> {
  bool _handled = false;
  double _progress = 0;

  /// Only these cookies are needed downstream by the scraper. The
  /// __RequestVerificationToken cookie has a rotating suffix, so it's matched
  /// by prefix.
  bool _isWanted(String name) =>
      name == ".ASPXAUTH" ||
      name == "ASP.NET_OneWebLang" ||
      name == "ROUTEID" ||
      name.startsWith("__RequestVerificationToken");

  Future<void> _checkSession() async {
    if (_handled) return;

    // All four cookies live on the secure.touchnet.net domain, so query that
    // domain regardless of which page (IdP / DUO) is currently showing.
    final cookies =
        await CookieManager.instance().getCookies(url: WebUri(_dashboardUrl));

    bool has(String name) => cookies.any((c) => c.name == name);
    final hasToken =
        cookies.any((c) => c.name.startsWith("__RequestVerificationToken"));

    // .ASPXAUTH is set last (on the post-DUO redirect); the others are set
    // earlier. Require all of them before we close.
    if (!has(".ASPXAUTH") ||
        !has("ASP.NET_OneWebLang") ||
        !has("ROUTEID") ||
        !hasToken) {
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
        bottom: _progress < 1.0
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: _progress),
              )
            : null,
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(_dashboardUrl)),
        // incognito:false + clearCache:false keep WKWebView's persistent
        // cookie store alive, so the DUO "remember this device" cookie and
        // iOS saved-password / Face ID autofill keep working across launches.
        initialSettings: InAppWebViewSettings(
          clearCache: false,
          cacheEnabled: true,
          incognito: false,
          isFraudulentWebsiteWarningEnabled: true,
          transparentBackground: true,
        ),
        onProgressChanged: (controller, progress) {
          setState(() => _progress = progress / 100);
          // Fires repeatedly during the post-login redirect chain, so we can
          // catch .ASPXAUTH before the dashboard finishes painting.
          _checkSession();
        },
        onLoadStart: (controller, url) => _checkSession(),
        onLoadStop: (controller, url) => _checkSession(),
        onUpdateVisitedHistory: (controller, url, isReload) => _checkSession(),
      ),
    );
  }
}
