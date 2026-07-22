# WatBal

A Flutter app for University of Waterloo students to track meal plan balances and transaction history. Scrapes TouchNet OneWeb and displays account data in-app and on home-screen widgets that refresh in the background.

Android is the primary platform; iOS has native widget and background refresh support but is lower priority.

## Features

- **Account balances** — scrapes all WatCard accounts (Flex, Meal Plan, etc.) and displays them as tappable hero cards
- **Transaction history** — full history with search, date grouping, and per-account filtering via incremental sync
- **Meal plan pacing** — configurable dashboard showing per-day allowance, spending pace, and an on-track/overspending verdict based on term dates
- **Home-screen widgets** — native widgets on both Android (3 sizes: full with transactions, 2×2 tile, 1×1 tile) and iOS (SwiftUI widget with balance + transactions)
- **Background refresh** — widgets update without opening the app; silently re-authenticates when the session expires
- **Analytics** — balance-over-time chart, top merchants, spending patterns by weekday/time, with configurable time windows
- **Theming** — Light, Dark, Purple, and Gold (UWaterloo brand) themes using Material 3, with UWaterloo brand fonts (Typ1451 + Bureau Grot)
- **Password autofill** — integrates with system credential managers (Google Password Manager on Android, Keychain on iOS)

## How It Works

### Authentication

1. **First launch:** an in-app WebView opens the TouchNet OneWeb dashboard. Login success is detected by the `.ASPXAUTH` cookie, and the full cookie header is saved.
2. **Subsequent launches:** the app scrapes headlessly with saved cookies — no WebView needed.
3. **Session expiry:** detected when the dashboard response lacks `__RequestVerificationToken`. The app silently re-authenticates using the longer-lived university SSO/DUO cookies in the WebView cookie jar — no password re-entry required.
4. **Cookie hygiene:** rotating `__RequestVerificationToken_*` cookies are pruned on re-auth to prevent header overflow (which causes 400 errors).

### Scraping

1. `GET /Account/Dashboard` — parse the request verification token
2. `POST /Layout/KeepAlive` — reset the sliding session window (~15 min)
3. `POST /Deposit/Home/Balances` — parse all account balances
4. `POST /TransactionHistory/TransactionsPass` — incremental transaction sync (fetches only since the newest cached row)
5. `POST /TransactionHistory/CurrentStatement` — maps account names to balance IDs for per-account filtering

### Background Refresh

| Platform | Mechanism | Notes |
|----------|-----------|-------|
| Android | WorkManager periodic task (15-min floor) | Can silently re-auth via headless WebView in background isolate |
| iOS | `BGAppRefreshTask` (native Swift, primary) + WorkManager one-off (fallback) | Native path uses URLSession only — cannot re-auth without app open |

Both are OS-throttled. Not real-time.

## Project Structure

```
lib/
  main.dart            # Entry point, themes, lifecycle, WorkManager callback
  auth.dart            # Cookie persistence, silent re-auth, LoginWebView
  scraper.dart         # HTTP scraping (balances + transactions), widget data push
  home_page.dart       # All-accounts menu, account detail, bottom nav, analytics
  loading_page.dart    # Cold-start splash, sign-in flow
  meal_plan.dart       # Meal plan config + pacing computation
  skeletons.dart       # Shimmer loading placeholders
  debug_log.dart       # File logger (works from background isolate)
  log_viewer_page.dart # In-app log viewer

android/               # 3 widget receivers + WorkManager setup
ios/
  Runner/BalanceRefresher.swift   # Native BGAppRefreshTask
  WatBalWidget/                   # SwiftUI widget extension

watbal.py              # Python prototype (reference only, not in build)
```

## Navigation

The app uses a floating bottom nav bar with four tabs:

- **Dashboard** — account hero cards + meal plan pacing card
- **Analytics** — balance chart, top merchants, spending patterns
- **Extras** — meal plan setup, add funds (opens WatCard deposit page), change card PIN
- **Settings** — theme picker, widget account selection, debug logs, re-sync history, sign out

## Dependencies

| Package | Role |
|---------|------|
| `flutter_inappwebview` | Login + silent re-auth WebView |
| `http` | Headless HTTP scraping |
| `html` | HTML parsing |
| `shared_preferences` | Cookie / theme / config persistence |
| `home_widget` | Push data to native widgets |
| `workmanager` | Background refresh scheduling |
| `path_provider` | Debug log file location |

## Getting Started

### Prerequisites

- Flutter SDK ≥ 3.11.5
- Android SDK (for Android builds)
- Xcode (for iOS builds)

### Run

```bash
# Install dependencies
flutter pub get

# Run on connected device / emulator
flutter run

# Run on a specific Android emulator
flutter run -d emulator-5554
```

### Build

```bash
# Android APK
flutter build apk --debug

# iOS (requires Xcode + signing)
flutter build ios
```

### Other Commands

```bash
# Dart analysis
flutter analyze lib/

# Regenerate launcher icons
dart run flutter_launcher_icons
```

## Build Notes

- `android/app/build.gradle.kts` pins `androidx.glance` to 1.1.1 (home_widget pulls an alpha requiring AGP 9 / compileSdk 37)
- Debug signing config is reused for release builds
- AndroidManifest opts out of Impeller (`EnableImpeller=false`) for WebView compatibility on emulators
- KGP deprecation warnings during build are benign
