# WatBal

A Flutter app that scrapes a university meal-plan balance (TouchNet OneWeb) and displays it. The Python script (`watbal.py`) was the original prototype and is the authoritative reference for the scraping logic.

## What this app does

1. Opens an in-app WebView pointed at `https://secure.touchnet.net/C22566_oneweb/Account/Dashboard`
2. Waits for the user to log in; detects success by watching for the `.ASPXAUTH` cookie
3. Saves the full cookie header to `SharedPreferences`
4. On subsequent launches, uses the saved cookies to scrape the balance headlessly:
   - GET Dashboard → extract `__RequestVerificationToken`
   - POST KeepAlive with that token
   - POST `/Deposit/Home/Balances` with that token → parse the "FLEXIBLE" row
5. Pushes the balance to a native iOS home-screen widget via `home_widget`

## Project structure

```
watbal.py               # Python prototype — reference for scraping logic
lib/
  main.dart             # App entry point, state management, WebView login flow
  scraper_service.dart  # HTTP scraping + widget update (Dart port of watbal.py)
  balance_display.dart  # Stateless UI widget for the balance number
ios/                    # iOS target (primary platform, currently in active development)
android/                # Android target (planned for the future)
```

## Platform status

- **iOS** — active development, home-screen widget already wired up (`WatBalWidget` / `group.com.vincent.watbal`)
- **Android** — planned; `home_widget` receiver name is `WatBalWidgetReceiver` for when that work begins

## Key dependencies

| Package | Role |
|---|---|
| `flutter_inappwebview` | Login WebView (Playwright equivalent) |
| `http` | Headless HTTP requests (requests equivalent) |
| `html` | HTML parsing (BeautifulSoup equivalent) |
| `shared_preferences` | Persist cookie header across launches |
| `home_widget` | Push balance to native iOS/Android widget |
| `flutter_secure_storage` | Available but currently unused; prefer for secrets if needed |

## Auth / session model

- Session is persisted as a raw `Cookie:` header string in `SharedPreferences` under the key `"session_cookies"`.
- A valid session requires `.ASPXAUTH` plus at least 3 other cookies.
- Session expiry is detected when the Dashboard response no longer contains `__RequestVerificationToken` — the scraper throws `Exception("Session Expired")`, which triggers the login WebView.
- `ASP.NET_OneWebLang` is the cookie the Python prototype watches for; the Flutter app uses `.ASPXAUTH` instead (more reliable signal that auth is complete).

## Scraping flow (do not change the order)

1. GET Dashboard with saved cookies → parse token
2. POST KeepAlive with token (keeps the server-side session alive)
3. POST Balances with token → find "FLEXIBLE" label, grab the dollar amount that follows

## iOS widget

- App group: `group.com.vincent.watbal`
- Widget name (iOS): `WatBalWidget`
- Widget name (Android, future): `WatBalWidgetReceiver`
- Data key written via `home_widget`: `balance_text`

## Common commands

```bash
# Run on iOS simulator
flutter run -d iPhone

# Build iOS release
flutter build ios --release

# Regenerate launcher icons (after changing assets/icon/)
dart run flutter_launcher_icons
```

## Python prototype

`watbal.py` uses Playwright (headless=False) to handle login and `requests` + BeautifulSoup for scraping. It is **not** part of the mobile build but is kept as a reference and can be run standalone:

```bash
pip install playwright requests beautifulsoup4
playwright install chromium
python watbal.py
```
