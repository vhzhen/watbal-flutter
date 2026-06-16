# WatBal

A Flutter app that scrapes a university meal-plan balance + transaction history
(TouchNet OneWeb) and shows it in-app and on home-screen widgets. Android is the
actively developed platform; iOS has a native widget + background-refresh path
but is lower priority.

## What the app does

1. First run: opens an in-app WebView at
   `https://secure.touchnet.net/C22566_oneweb/Account/Dashboard`. Detects login
   success by the `.ASPXAUTH` cookie and saves the full cookie header.
2. Later runs: scrapes headlessly with the saved cookies — all account balances
   and recent transactions.
3. Shows it on a single scrollable home screen (balance hero, spending summary,
   search, transactions grouped by date) and pushes it to home-screen widgets.
4. Refreshes in the background so the widgets stay current without opening the
   app — re-authenticating silently when the session expires.

## Project structure

```
watbal.py   # Python prototype (Playwright + requests). Balance-only; NOT
            # authoritative for transactions. Kept as reference, not in the build.
lib/
  main.dart            # Entry point, app root, themes (AppTheme), lifecycle,
                       # WorkManager background callback (the re-auth lives here)
  auth.dart            # Cookie persistence, silent re-auth (trySilentReauth),
                       # the visible LoginWebView, clearSession/clearAuthCookie
  scraper.dart         # All HTTP scraping (balance + transactions), the
                       # Transaction model, and reloadWatBalWidgets()
  home_page.dart       # The main UI (single scroll), settings dialog
  loading_page.dart    # Cold-start: try saved cookies -> silent re-auth -> login
  debug_log.dart       # File logger (works from the background isolate)
  log_viewer_page.dart # In-app log viewer (Settings -> View logs)
android/  # Active. 3 widgets + WorkManager background refresh (see below).
ios/      # Native widget (WatBalWidget) + BalanceRefresher (BGAppRefreshTask).
```

## Auth / session model

- Session = a raw `Cookie:` header string in `SharedPreferences` key
  `session_cookies` (also mirrored into `home_widget` shared data for the iOS
  native task). A valid session = `.ASPXAUTH` + at least 3 other cookies.
- Expiry is detected when the Dashboard response lacks
  `__RequestVerificationToken` → scraper throws `Exception("Session Expired")`.
- **Two sessions exist:** the short-lived TouchNet `.ASPXAUTH` (~15 min sliding),
  and the long-lived university SSO/DUO "remember this device" cookies, which
  live only in the WebView cookie jar. The SSO cookies let `trySilentReauth()`
  (a headless WebView replaying the SSO flow) get a fresh `.ASPXAUTH` with no
  password. Stale `.ASPXAUTH` after expiry is cleared via `clearAuthCookie()` so
  `LoginWebView` doesn't mistake its presence for a completed login.

## Scraping flow (order matters — see scraper.dart)

1. `GET /Account/Dashboard` → parse `__RequestVerificationToken`.
2. `POST /Layout/KeepAlive` with the token (resets the sliding session).
3. `POST /Deposit/Home/Balances` → parse every row of the "Available Balances"
   table into `AccountBalance { name, amount }` (a user may hold more than one
   account type). `displayName` maps the site's "FLEXIBLE" → "FLEX DOLLARS";
   any other account is title-cased. The app shows one hero per account; the
   widget shows the user-chosen account (pref key `widget_account`, default =
   first account), pushed as `balance_text` + `balance_label`.
4. Transactions: `POST /TransactionHistory/TransactionsPass` (5-year window, 1000
   rows) → rows from `#transaction-history-result-table`. `Transaction` exposes
   `label` (type), `terminalLabel` (merchant), `displayAmount`, `isDebit`,
   `parsedDate`, `amountValue`.

## Background refresh

- **Android:** WorkManager periodic task (id `com.vincent.watbal.refresh`), 15-min
  floor, `ExistingPeriodicWorkPolicy.update`. The callback (`_workmanagerCallback`
  in main.dart) runs in a background isolate and, on `Session Expired`, calls
  `trySilentReauth()` — a **headless WebView works in the WorkManager isolate**,
  confirmed — then retries. Guards: skip if another run was <60s ago (Doze fires
  bursts); skip entirely if no widget is placed (`getInstalledWidgets()`).
- **iOS:** native `BalanceRefresher` (`BGAppRefreshTask`, id
  `com.vincent.watbal.refresh.app`) is the primary path — pure URLSession, no
  WebView, so it **cannot** silently re-auth (needs an app open). A workmanager
  one-off `BGProcessingTask` is a secondary path.
- Both are OS-throttled (~15 min+, delayed by Doze / app-usage budget). Not
  real-time.

## Widgets

Shared `home_widget` data keys (app group / android prefs `group.com.vincent.watbal`):
`balance_text`, `balance_label` (selected account's display name, shown as the
widget title), `transactions_json`, `last_updated`, `app_theme`.
`reloadWatBalWidgets()` (scraper.dart) broadcasts a reload to every receiver.

| Platform | Name | Content |
|---|---|---|
| Android | `WatBalWidgetReceiver` | Balance + "Updated…" + scrollable transaction list |
| Android | `WatBalMediumWidgetReceiver` | 2x2 balance tile |
| Android | `WatBalSmallWidgetReceiver` | 1x1 balance tile |
| iOS | `WatBalWidget` (SwiftUI) | Balance + transactions |

**Key Android widget gotchas (learned the hard way):**
- The full widget's transaction list is a `RemoteViewsService` collection
  (`TransactionsWidgetService`). Android won't bind that service from a
  background broadcast, so a full `updateAppWidget` from the background gets
  dropped. Fix: `onUpdate` pushes balance/time via `partiallyUpdateAppWidget`
  (no adapter, no service bind) so the text stays fresh in the background; the
  **list itself only reliably refreshes in the foreground** (app open). The
  1x1/2x2 tiles have no collection, so they update fine in the background.
- Rapid-fire `updateWidget` broadcasts get coalesced by the launcher and can
  freeze the display — keep updates spaced (resume refresh is throttled to 10s;
  app-close does a single `touchWidget`).
- Widget-picker order follows **manifest `<receiver>` declaration order** on this
  launcher (not label). 2x2 is declared before 1x1 so it lists first; labels are
  also set as a fallback for alphabetical launchers.

## Themes

`AppTheme { light, dark, green }` (main.dart), Material 3 `ColorScheme.fromSeed`
(vibrant variant). Widgets mirror these via the `app_theme` key. UI must use
`Theme.of(context).colorScheme` — no hardcoded colors.

## Logging / debugging

- `DebugLog` (debug_log.dart) appends timestamped lines to `watbal_debug.log` in
  the app documents dir — works from the **background isolate** where
  `debugPrint` isn't visible. Instrumented prefixes: `bg:`, `resume:`, `widget:`.
- In-app viewer: Settings (gear) → **View logs** (`LogViewerPage`).
- Native widget renders log under logcat tag `WatBalWidget`
  (`adb logcat -s WatBalWidget`).

## Key dependencies

| Package | Role |
|---|---|
| `flutter_inappwebview` | Login + silent-reauth WebView |
| `http` | Headless HTTP scraping |
| `html` | HTML parsing |
| `shared_preferences` | Persist cookies / theme |
| `home_widget` | Push data to native widgets |
| `workmanager` | Android/iOS background refresh |
| `path_provider` | Location of the debug-log file |
| `flutter_secure_storage` | Present but unused |

## Build notes / constraints

- `android/app/build.gradle.kts` pins `androidx.glance` to 1.1.1 (home_widget
  pulls an alpha needing AGP 9 / compileSdk 37). Debug signing config is reused
  for release. `applicationId` is still the placeholder `com.example.watbal`.
- AndroidManifest opts out of Impeller (`EnableImpeller=false`) so the WebView
  renders on emulators. KGP deprecation warnings during build are benign.

## Common commands

```bash
flutter run -d emulator-5554       # run on Android emulator
flutter build apk --debug          # validate Android (Kotlin + resources)
flutter analyze lib/               # Dart analysis
dart run flutter_launcher_icons    # regenerate icons after changing assets/icon/
```

## Conventions

- **Git:** commits are attributed solely to the user — do **not** add a
  `Co-Authored-By: Claude` trailer. Branch off main only if asked; the user
  commits directly to `main`.
