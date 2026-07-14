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
3. The app opens on an all-accounts menu: a meal-plan pacing dashboard on top
   (see below), then tappable balance hero cards (scraped order, shown even
   with a single account). Tapping a card opens that account's detail page
   (hero, spending summary, search, transactions grouped by date — all computed
   from that account's transactions only, via the balance-ID map). Also pushes
   to home-screen widgets.
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
                       # the visible LoginWebView, clearSession, TouchNet
                       # cookie-jar pruning (_clearTouchnetCookies)
  scraper.dart         # All HTTP scraping (balance + transactions), the
                       # Transaction model, and reloadWatBalWidgets()
  home_page.dart       # HomePage (all-accounts menu + meal-plan dashboard) +
                       # per-account detail page, shared _HomeController (txns +
                       # balance-ID map + meal-plan config), settings dialog
  loading_page.dart    # Cold-start splash + branded sign-in screen; try saved
                       # cookies -> silent re-auth -> login
  meal_plan.dart       # MealPlanConfig (designated account + term dates) and
                       # MealPlanPacing.compute (per-day allowance + verdict)
  skeletons.dart       # Pure-Flutter shimmer skeletons (Skeleton, Shimmer,
                       # txnRowsSkeleton) for first-load states
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
  password.
- **Cookie-jar hygiene:** each fresh TouchNet session sets a new
  `__RequestVerificationToken_<suffix>` cookie (rotating suffix) that never
  expires or overwrites — left alone they accumulate until the Cookie header
  exceeds the server's limit and everything (login page included) 400s, which
  only a reinstall used to fix. `trySilentReauth()` therefore starts by wiping
  all TouchNet-host cookies (`_clearTouchnetCookies` — SSO/DUO cookies are on
  the IdP domain and survive); this also removes the stale `.ASPXAUTH` that
  `LoginWebView` would mistake for a completed login. As a backstop,
  `LoginWebView` self-heals on a main-frame 400/413/431/494: first prune
  TouchNet cookies, then wipe the whole jar (one full DUO sign-in).
- **Password autofill:** the visible `LoginWebView` participates in Android's
  system autofill (Google Password Manager etc.) so saved passwords for the
  SSO domain are offered in the form. Requirements, all set: hybrid composition
  + `saveFormData` on the WebView (auth.dart, explicit though both are package
  defaults), `android:importantForAutofill="yes"` on `MainActivity` (manifest),
  and the login is shown as a **full-screen route** (loading_page.dart), *not*
  a modal bottom sheet — the sheet's window/IME handling suppresses the autofill
  bar. Actual credentials come from the device's autofill service, matched by
  web domain — nothing is stored by the app. The AppBar shows a live URL bar
  (lock icon + current URL) so the domain is visible. iOS WKWebView offers
  Keychain autofill natively, no config.

## Scraping flow (order matters — see scraper.dart)

1. `GET /Account/Dashboard` → parse `__RequestVerificationToken`.
2. `POST /Layout/KeepAlive` with the token (resets the sliding session).
3. `POST /Deposit/Home/Balances` → parse every row of the "Available Balances"
   table into `AccountBalance { name, amount }` (a user may hold more than one
   account type). `displayName` maps the site's "FLEXIBLE" → "FLEX DOLLARS";
   any other account is title-cased. The app shows one hero per account; the
   widget shows the user-chosen account (pref key `widget_account`, default =
   first account), pushed as `balance_text` + `balance_label`.
4. Transactions are synced **incrementally**: all rows live in a local cache
   (pref `cached_transactions`, JSON, newest first, plus an isolate-static
   memo). `syncTransactions` computes FromDate = newest cached row's date − 1
   day (empty cache → 03/09/2000), fetches only that window via
   `fetchTransactions` (`POST /TransactionHistory/TransactionsPass`, 1000-row
   cap, rows from `#transaction-history-result-table`), then merges: fresh
   rows are authoritative for the window, cached rows strictly before it are
   kept. The UI renders `loadCachedTransactions()` instantly before syncing;
   a failed sync with a cache on screen is silent staleness, not an error.
   `clearScraperCache()` (called by `clearSession`) wipes cache + map on
   sign-out. `Transaction` exposes `label` (type), `terminalLabel` (merchant),
   `displayAmount`, `isDebit`, `parsedDate`, `amountValue`, `balanceId` (the
   `Balance` column — the site's opaque account number, e.g. FLEXIBLE=5), and
   `toJson`/`fromJson` for the cache.
5. Account attribution: `POST /TransactionHistory/CurrentStatement` returns one
   card per account holding both its name and rows carrying its balance ID —
   the only place the two co-occur. `fetchBalanceIdMap` parses that into a
   name→ID map, persisted as JSON in pref `account_balance_ids` (and an
   isolate-static cache). `ensureBalanceIdMap` (called from `fetchTransactions`)
   re-fetches only when the map is empty or a scraped row carries an unknown ID
   (new account type); IDs still unknown after a re-fetch (account inactive this
   statement period) are remembered so they can't re-trigger fetches every
   refresh. Map stores are written to the debug log (`map:` prefix). Raw names
   → UI names via top-level `accountDisplayName()` ("FLEXIBLE" → "FLEX
   DOLLARS").

## Bottom navigation

`HomePage` hosts a floating rounded bottom nav (`_BottomNavBar`) with four tabs;
`_navIndex` selects the body via a `switch`:
- **Dashboard** (`_dashboard`): the accounts overview — meal-plan card + hero
  cards. Tapping a hero pushes `_AccountDetailPage` (its own route, no nav bar).
- **Analytics** (`_AnalyticsView`): intentionally blank placeholder for now.
- **Extras** (`_ExtrasView`): meal-plan setup (see below), Add funds (opens
  the WatCard deposit page `watcard.uwaterloo.ca/WatCardDeposit/deposit` in a
  `ChromeSafariBrowser` custom tab), and Change card PIN. The home meal-plan
  CTA jumps here (`_navIndex = 2`).
- **Settings** (`_SettingsView`): theme picker, widget account (when >1
  account), View logs, re-sync history, Sign out. Takes the shared
  `_HomeController` (for re-sync), not a bare accounts list.

Extras/Settings are plain scrollable tab bodies (formerly modal dialogs); the
AppBar title tracks the tab and has no action icons. The Scaffold sets
`extendBody: true` so content scrolls *behind* the floating pill instead of
stopping at a solid strip beside it — every tab body (and its skeleton) must
therefore end with ~140px of bottom list padding to clear the bar.

**Analytics tab** (`_AnalyticsView` + `_Analytics.from`): spending insights
derived from the transaction cache, scoped by an account filter at the top —
"All accounts" (default, totals summed) or any single account (chips hidden
with one account; a selection that disappears after a refresh falls back to
all). The whole tab recomputes per filter, and the chart re-keys so it redraws. A **balance-over-time line chart**
(`_LineChartPainter`, pure-Flutter `CustomPaint`) is reconstructed by taking the
current total balance and walking transactions backwards (`balance_before =
balance_after − amountValue`, since debit `amountValue` is negative). The chart
has labelled axes (price gridlines on Y; 4 date ticks on X, month-only labels
once the window spans several months — with the year appended, "Sep 2026",
when the plotted range crosses years) and the same `_StatsWindow`/`_WindowMenu`
top-right filter as the stats cards (default 30 days; all time = uncut);
a synthetic point is prepended at the window cutoff so the step-function
line always spans the full window. Plus a "this month you've spent $X" card
comparing to the **past-year monthly average** (spend over the last 12
completed months ÷ months spanned — clamped to when the data starts, so
zero-spend months count but a short history isn't diluted). Below the chart:
a **Top places** card (top 5 merchants by debit total, grouped by
`terminalLabel`, with proportion bars) and a **Spending patterns** card
(per-weekday debit totals as mini bars + a peak time-of-day phrase —
computed only from rows with a real timestamp, and omitted when fewer than
half the window's debits have one, since the site leaves some rows at
midnight). Each card has its own trailing-window filter in its top-right
corner (`_StatsWindow` popup via `_WindowMenu`: 30 days / 90 days / past
year / all time; defaults 30d and 90d respectively), computes from the
tab's filtered txns inside the card, and shows a "No purchases in this
period" line when its window is empty.

**Section cards**: every Extras/Settings subsection (Meal plan, Card PIN,
Theme, Widget account, Logs, Sign out) sits in a `_SectionCard` — the
analytics-style bubble (surfaceContainerHighest, radius 24, uppercase
letter-spaced title) — for cross-tab consistency.

**Re-sync history** (Settings → Data): `_HomeController.resync()` nulls the
in-memory txns (tabs drop to skeletons), calls `clearScraperCache()`, then
`refresh()` — the empty cache makes `syncTransactions` refetch from the 2000
epoch, i.e. the complete history, and re-derive the balance-ID map.

**Skeletons per tab**: each tab shows a shimmer placeholder while its data
loads — `dashboardSkeleton`/`analyticsSkeleton` gate on `_data.txns == null`
(first load, before cache), `extrasSkeleton`/`settingsSkeleton` on the view's
own `_loading` flag (prefs read). All in `skeletons.dart`.

**Micro-animations** (all implicit/one-shot, no controllers): tab bodies swap
via `AnimatedSwitcher` (220ms fade + tiny upward drift; key includes the
loading flag so skeleton→content also fades); the selected nav pill pops in
with `easeOutBack` (only the *new* pill animates — the old one vanishes
instantly, deliberate: an exit fade reads as a flash); hero cards compress to
0.98 while pressed (`AnimatedScale` + `InkWell.onHighlightChanged`); the hero
balance counts up/down on change (`_AnimatedAmount`, TweenAnimationBuilder —
no animation on first render since begin == end); the meal-plan spent bar eases
to its value; the analytics line chart draws itself left-to-right via
`PathMetric.extractPath` (`progress` on `_LineChartPainter`, re-keyed per
span).

## Change card PIN

Extras → "Change card PIN" opens a two-field popup (New / Re-enter, must
match; PINs are any length and may mix letters/digits, so no numeric or length
constraint). `Scraper.changeCardPin` POSTs `__RequestVerificationToken` +
`ChangeCardPINModel.NewCardPIN` + `...RepeatNewCardPIN` to
`/Account/ChangeCardPIN` with `followRedirects = false`: the site confirms
success with a **302** to `/Account/Personal` and signals rejection by
re-rendering the form (200), so non-302 is treated as an error.

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

`AppTheme { light, dark, purple, gold }` (main.dart), Material 3
`ColorScheme.fromSeed` (vibrant variant). Widgets mirror these via the
`app_theme` key — the native theme maps (`WidgetTheme.named` in
`WatBalWidgetReceiver.kt`, shared by all Android widgets; the Swift switch in
`WatBalWidget.swift`) hardcode each theme's `primaryContainer`/`onPrimaryContainer`
hex and **fall back to light** for an unknown name, so a new app theme is safe
even before the native maps learn it (the retired `green` case still lives in
the native maps harmlessly). Purple = `deepPurple` seed
(container #EBDDFF / onContainer #5B00C5); its widget background lives in
`res/drawable/watbal_widget_bg_purple.xml`. Gold = the UWaterloo palette
(#F2EDA8 / #FAE102 / #FDD34C / #EAAA01 + black/white): a *light* scheme
seeded from the deep gold #EAAA01, then `copyWith` forces the brand colors
exactly — primaryContainer #FDD34C with black text (heroes / widget bg,
`watbal_widget_bg_gold.xml`), secondaryContainer pale #F2EDA8, surface
white. UI must use
`Theme.of(context).colorScheme` — no hardcoded colors.

**Fonts** (UWaterloo brand, downloaded from uwaterloo.ca and converted
woff2→ttf; files in `assets/fonts/`, registered in pubspec): body text is
**Typ1451** (regular + medium w500) via `ThemeData.fontFamily`, so every
plain `TextStyle` inherits it. Titles are **Bureau Grot** — `BureauGrot`
(Light w300 + Book) on the textTheme display/headline/titleLarge slots
(AppBar picks up titleLarge) and on hand-rolled headings + the big money
figures (hero 52px, meal-plan per-day + month-spend 40px).
`BureauGrotCondensed` (Book only) is registered but currently unused. The
families have no bold faces, so
`w800` declarations render the Book weight; an unregistered family falls
back to the platform default.

## Meal-plan tracking

A meal plan is a fixed pot to *finish* by term end (unlike FLEX). The user
designates **one** account as the meal plan and sets its term start/end in the
**Extras** tab (`meal_plan.dart`: `MealPlanConfig`, prefs `meal_plan_account` /
`_start` / `_end`). `MealPlanPacing.compute` derives the
per-day allowance (`balance / daysRemaining`), a recent pace (debits over a
trailing 14-day window), a spent fraction for the card's progress bar
(spend since term start ÷ the term-start balance, which is reconstructed by
undoing all on/after-start transactions from the current balance — pre-term
spending never counts), and a status verdict (on track / spending too fast /
money to spare / term ended) by projecting the run-out date against term end
(±5-day slack). The first page shows `_MealPlanCard` at the top of the accounts
list — a setup CTA when unconfigured, a shimmer while its txns load, else the
pacing dashboard. The CTA is a **one-time nudge**: pref
`meal_plan_cta_dismissed` is set true when the user taps its X *or* picks any
account, and is **never reset** — not on sign-out, not on switching back to
None — so once acknowledged it never returns. Only the designated account is
treated as a meal plan. The selection, term dates, and CTA flag all **persist
across sign-out** (unlike the transaction cache / balance-ID map, which
`clearSession` wipes) so a returning user doesn't reconfigure;
`MealPlanConfig.clear` (the "None" choice) only drops the selection.

## Loading states

First-load placeholders use pure-Flutter shimmer (`skeletons.dart`, no
dependency): the account-detail history shows `txnRowsSkeleton()` while
transactions load (hero + summary already have balance data); the meal-plan
card shimmers until its account's txns arrive. Cold start / sign-in is a
branded splash + `Sign In` screen in `loading_page.dart` (auth logic unchanged
— saved cookies → `trySilentReauth` → `LoginWebView`).

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
