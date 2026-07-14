import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watbal/auth.dart';
import 'package:watbal/log_viewer_page.dart';
import 'package:watbal/main.dart';
import 'package:watbal/meal_plan.dart';
import 'package:watbal/scraper.dart';
import 'package:watbal/skeletons.dart';

/// The app's root screen: the all-accounts menu — one tappable hero card per
/// account, in scraped order, regardless of how many accounts exist. Tapping
/// a card opens that account's [_AccountDetailPage] (hero, spending summary,
/// search, history).
///
/// All data (balances, transactions, the account ↔ balance-ID map) lives in a
/// shared [_HomeController] so the menu and any open detail page stay in sync
/// through a single fetch — transactions for every account come from one
/// TransactionsPass call anyway.
class HomePage extends StatefulWidget {
  final List<AccountBalance> accounts;
  final ThemeController theme;
  final ValueChanged<List<AccountBalance>> onAccountsChanged;
  final VoidCallback onSignedOut;

  const HomePage({
    super.key,
    required this.accounts,
    required this.theme,
    required this.onAccountsChanged,
    required this.onSignedOut,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final _HomeController _data;

  // Bottom-nav selection. Visual only for now — tapping highlights a tab but
  // doesn't yet change what's shown.
  int _navIndex = 0;

  @override
  void initState() {
    super.initState();
    _data = _HomeController(
      accounts: widget.accounts,
      onAccountsChanged: widget.onAccountsChanged,
      onSignedOut: _signOut,
    );
    _data.load();
  }

  /// Detail pages are pushed *above* the app root's `home`, so swapping home
  /// out for the LoadingPage on sign-out wouldn't remove them — pop back to
  /// the overview first.
  void _signOut() {
    Navigator.of(context).popUntil((r) => r.isFirst);
    widget.onSignedOut();
  }

  @override
  void didUpdateWidget(HomePage old) {
    super.didUpdateWidget(old);
    // Sync the accounts main.dart hands back down. No notify: the only writer
    // is _HomeController.refresh itself (via onAccountsChanged), which already
    // notified with this same list — and this runs mid-build.
    _data.syncAccounts(widget.accounts);
  }

  @override
  void dispose() {
    _data.dispose();
    super.dispose();
  }

  void _openAccount(AccountBalance account) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _AccountDetailPage(data: _data, account: account),
      ),
    );
  }

  static const _navTitles = ["WatBal", "Analytics", "Extras", "Settings"];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _data,
      builder: (context, _) {
        return Scaffold(
          // The nav bar floats: the body extends behind it (content scrolls
          // past under the pill) instead of stopping at a solid strip. Tab
          // bodies compensate with extra bottom list padding.
          extendBody: true,
          appBar: AppBar(
            title: Text(
              _navTitles[_navIndex],
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          bottomNavigationBar: _BottomNavBar(
            currentIndex: _navIndex,
            onTap: (i) => setState(() => _navIndex = i),
          ),
          // Micro-animation: tab switches (and skeleton → content on the
          // data-driven tabs) fade in with a slight upward drift.
          body: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, 0.01),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            child: KeyedSubtree(
              key: ValueKey("$_navIndex-${_data.txns == null}"),
              child: switch (_navIndex) {
                1 => _AnalyticsView(data: _data),
                2 => _ExtrasView(
                  accounts: _data.accounts,
                  onMealPlanChanged: _data.reloadMealPlan,
                ),
                3 => _SettingsView(
                  theme: widget.theme,
                  data: _data,
                  onSignedOut: _signOut,
                ),
                _ => _dashboard(context),
              },
            ),
          ),
        );
      },
    );
  }

  /// Tab 0: the accounts overview — meal-plan card + one hero per account.
  Widget _dashboard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accounts = _data.accounts;
    // First load (no cached transactions yet) → skeleton the whole tab.
    if (_data.txns == null && _data.error == null) return dashboardSkeleton();
    return RefreshIndicator(
      // Fire-and-forget: returning immediately retracts the pull spinner
      // instead of parking it over the meal-plan card for the whole refresh —
      // the "Updated" pill right below already animates while the refresh is
      // in flight.
      onRefresh: () async {
        unawaited(_data.refresh());
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 140),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _UpdatedPill(
                  refreshing: _data.refreshing,
                  updated: _data.updated,
                  onSurface: true,
                ),
              ],
            ),
          ),
          _MealPlanSection(
            data: _data,
            // Send the user to the Extras tab, where meal-plan setup lives.
            onSetup: () => setState(() => _navIndex = 2),
          ),
          for (var i = 0; i < accounts.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _HeroCard(
              account: accounts[i],
              caption: _caption(accounts[i]),
              onTap: () => _openAccount(accounts[i]),
            ),
          ],
          if (_data.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Center(
                child: Text(
                  _data.error!,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// "12 transactions" under the balance — doubles as the tap affordance.
  /// Blank until the first transactions fetch lands.
  String? _caption(AccountBalance account) {
    final txns = _data.txnsFor(account);
    if (txns == null) return null;
    return "${txns.length} transaction${txns.length == 1 ? '' : 's'}";
  }
}

// ───────────────────────────── shared controller ───────────────────────────

/// Owns everything both pages render: accounts, transactions, the account ↔
/// balance-ID map, and refresh state. One instance per HomePage lifetime,
/// passed into detail pages so a pull-to-refresh on either screen updates
/// both.
class _HomeController extends ChangeNotifier {
  _HomeController({
    required List<AccountBalance> accounts,
    required this.onAccountsChanged,
    required this.onSignedOut,
  }) : _accounts = accounts;

  final Scraper _scraper = Scraper();
  final ValueChanged<List<AccountBalance>> onAccountsChanged;
  final VoidCallback onSignedOut;

  List<AccountBalance> _accounts;
  List<AccountBalance> get accounts => _accounts;

  /// See [_HomePageState.didUpdateWidget] — deliberately no notify.
  void syncAccounts(List<AccountBalance> value) => _accounts = value;

  List<Transaction>? _txns;

  /// All transactions across every account (null while the first load is in
  /// flight). Used by the Analytics tab.
  List<Transaction>? get txns => _txns;

  Map<String, String> _balanceIds = const {};
  DateTime updated = DateTime.now();
  bool refreshing = false;
  String? error;

  /// Sum of every account's current balance, in dollars (accounts that don't
  /// parse are skipped). The anchor for reconstructing balance history.
  double get totalBalance {
    var sum = 0.0;
    for (final a in _accounts) {
      sum += a.amountValue ?? 0;
    }
    return sum;
  }

  MealPlanConfig mealPlan = const MealPlanConfig();

  /// Whether the user dismissed the home-screen "Track your meal plan" CTA.
  /// Only hides that prompt; setup stays available in the Features popup.
  bool mealPlanCtaDismissed = false;

  /// (Re)reads the meal-plan selection + CTA state from prefs — call after the
  /// Extras tab changes either so the dashboard updates immediately.
  Future<void> reloadMealPlan() async {
    mealPlan = await MealPlanConfig.load();
    mealPlanCtaDismissed = await loadMealPlanCtaDismissed();
    notifyListeners();
  }

  /// Hides the setup CTA for good (persisted, and never reset — not on logout
  /// nor on switching the plan back to None). The nudge is a one-time intro.
  Future<void> dismissMealPlanCta() async {
    mealPlanCtaDismissed = true;
    notifyListeners();
    await setMealPlanCtaDismissed(true);
  }

  /// The designated meal-plan account's freshest balance row, or null when no
  /// meal plan is set (or its account is no longer present).
  AccountBalance? get mealPlanAccount {
    final name = mealPlan.accountName;
    if (name == null) return null;
    for (final a in _accounts) {
      if (a.name == name) return a;
    }
    return null;
  }

  /// Pacing snapshot for the designated meal plan, or null when it isn't fully
  /// configured, its account is gone, or transactions haven't loaded yet.
  MealPlanPacing? get mealPlanPacing {
    if (!mealPlan.isConfigured) return null;
    final account = mealPlanAccount;
    final txns = account == null ? null : txnsFor(account);
    final balance = account?.amountValue;
    if (account == null || txns == null || balance == null) return null;
    return MealPlanPacing.compute(
      balance: balance,
      start: mealPlan.start!,
      end: mealPlan.end!,
      txns: txns,
    );
  }

  Future<void> load() async {
    mealPlan = await MealPlanConfig.load();
    mealPlanCtaDismissed = await loadMealPlanCtaDismissed();
    final cookies = await loadSession();
    if (cookies == null) {
      onSignedOut();
      return;
    }
    try {
      // Render whatever the last sync left on disk immediately — the sync
      // below then folds in only what's new.
      final cached = await _scraper.loadCachedTransactions();
      if (cached != null) {
        _txns = cached;
        _balanceIds = await _scraper.ensureBalanceIdMap(cookies);
        notifyListeners();
      }

      _txns = await _scraper.syncTransactions(cookies);
      // syncTransactions just ensured the map is current; this is a cache
      // read, not another request.
      _balanceIds = await _scraper.ensureBalanceIdMap(cookies);
      notifyListeners();
    } catch (e) {
      if (e.toString().contains("Expired")) {
        onSignedOut();
      } else if (_txns == null) {
        // Only surface the failure when there's nothing to show — with the
        // cache on screen, a failed incremental sync is just staleness.
        error = "Couldn't load transactions.";
        notifyListeners();
      }
    }
  }

  Future<void> refresh() async {
    refreshing = true;
    notifyListeners();
    final cookies = await loadSession();
    if (cookies == null) {
      onSignedOut();
      return;
    }
    try {
      final fresh = await _scraper.fetchBalances(cookies);
      _txns = await _scraper.syncTransactions(cookies);
      _balanceIds = await _scraper.ensureBalanceIdMap(cookies);
      _accounts = fresh;
      updated = DateTime.now();
      error = null;
      refreshing = false;
      notifyListeners();
      onAccountsChanged(fresh);
    } catch (e) {
      if (e.toString().contains("Expired")) {
        onSignedOut();
      } else {
        error = "Couldn't refresh.";
        refreshing = false;
        notifyListeners();
      }
    }
  }

  /// Full re-sync: wipe the local transaction cache + balance-ID map, then
  /// refetch everything. With an empty cache, [Scraper.syncTransactions]
  /// starts from its 2000 epoch — the complete history. The tabs fall back to
  /// their skeletons while `txns` is null.
  Future<void> resync() async {
    _txns = null;
    _balanceIds = const {};
    notifyListeners();
    await clearScraperCache();
    await refresh();
  }

  /// The freshest balance row for [account] (a refresh replaces the list, so
  /// a detail page can't hold onto its constructor copy), falling back to the
  /// stale copy if the account vanished from the latest scrape.
  AccountBalance current(AccountBalance account) => _accounts.firstWhere(
    (a) => a.name == account.name,
    orElse: () => account,
  );

  /// Transactions attributed to [account]. Null while the first fetch is in
  /// flight (loading), empty when loaded-but-none.
  ///
  /// Attribution: a transaction row's `Balance` column carries the account's
  /// opaque balance ID, resolved through the CurrentStatement-derived map.
  /// When this account's own ID is unknown (no activity in the current
  /// statement period yet), show everything *not claimed* by another
  /// account's known ID rather than nothing — never silently lose rows.
  List<Transaction>? txnsFor(AccountBalance account) {
    final all = _txns;
    if (all == null) return null;
    final id = _balanceIds[account.name];
    if (id != null) {
      return all.where((t) => t.balanceId == id).toList();
    }
    final claimed = <String>{
      for (final a in _accounts)
        if (a.name != account.name && _balanceIds[a.name] != null)
          _balanceIds[a.name]!,
    };
    return all.where((t) => !claimed.contains(t.balanceId)).toList();
  }
}

// ───────────────────────────── account detail ──────────────────────────────

/// One account's screen: hero, spending summary, search, and the transaction
/// history — every number on it derived only from this account's transactions.
class _AccountDetailPage extends StatefulWidget {
  final _HomeController data;
  final AccountBalance account;

  const _AccountDetailPage({required this.data, required this.account});

  @override
  State<_AccountDetailPage> createState() => _AccountDetailPageState();
}

class _AccountDetailPageState extends State<_AccountDetailPage> {
  String _query = '';

  /// This account's transactions after the search query, newest first.
  List<Transaction> _filtered(List<Transaction> txns) {
    final q = _query.trim().toLowerCase();
    final list = txns.where((t) {
      if (q.isNotEmpty) {
        final hay =
            '${t.label} ${t.terminalLabel} ${t.displayAmount} ${t.dateTime}'
                .toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();
    list.sort((a, b) {
      final da = a.parsedDate, db = b.parsedDate;
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return db.compareTo(da);
    });
    return list;
  }

  /// Flattened rows for the lazy list: a `String` is a date header, a
  /// `Transaction` is a row.
  List<Object> _rows(List<Transaction> filtered) {
    final rows = <Object>[];
    String? current;
    for (final t in filtered) {
      final label = _dayLabel(t.parsedDate);
      if (label != current) {
        rows.add(label);
        current = label;
      }
      rows.add(t);
    }
    return rows;
  }

  /// Total spent (debits only) since [start], within this account.
  double _spentSince(List<Transaction> txns, DateTime start) {
    var sum = 0.0;
    for (final t in txns) {
      if (!t.isDebit) continue;
      final d = t.parsedDate;
      if (d == null || d.isBefore(start)) continue;
      sum += -t.amountValue; // debit values are negative
    }
    return sum;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.data,
      builder: (context, _) {
        final account = widget.data.current(widget.account);
        final txns = widget.data.txnsFor(account);
        return Scaffold(
          appBar: AppBar(
            title: Text(
              account.displayName,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          body: RefreshIndicator(
            onRefresh: widget.data.refresh,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: _HeroCard(
                      account: account,
                      trailing: _UpdatedPill(
                        refreshing: widget.data.refreshing,
                        updated: widget.data.updated,
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(child: _summary(txns)),
                SliverToBoxAdapter(child: _searchFilter(scheme)),
                ..._content(scheme, txns),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _summary(List<Transaction>? txns) {
    final now = DateTime.now();
    final weekStart = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: now.weekday - 1));
    final monthStart = DateTime(now.year, now.month, 1);
    final loaded = txns ?? const <Transaction>[];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: _StatTile(
              label: "This week",
              value: _money(_spentSince(loaded, weekStart)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _StatTile(
              label: "This month",
              value: _money(_spentSince(loaded, monthStart)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _StatTile(
              label: "Transactions",
              value: txns == null ? "…" : "${txns.length}",
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchFilter(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
      child: TextField(
        onChanged: (v) => setState(() => _query = v),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: "Search transactions",
          prefixIcon: const Icon(Icons.search, size: 20),
          filled: true,
          fillColor: scheme.surfaceContainerHighest,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  List<Widget> _content(ColorScheme scheme, List<Transaction>? txns) {
    final error = widget.data.error;
    if (error != null) return [_message(scheme, error)];
    if (txns == null) {
      // Hero + summary above already show real balance data; only the history
      // is still loading, so skeleton just the rows.
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: txnRowsSkeleton(),
          ),
        ),
      ];
    }
    final rows = _rows(_filtered(txns));
    if (rows.isEmpty) {
      return [
        _message(
          scheme,
          _query.trim().isNotEmpty
              ? "No matching transactions."
              : "No transactions yet.",
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 40),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate((context, i) {
            final row = rows[i];
            if (row is String) return _DateHeader(label: row);
            return _TxnTile(t: row as Transaction);
          }, childCount: rows.length),
        ),
      ),
    ];
  }

  Widget _message(ColorScheme scheme, String text) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      ),
    ),
  );
}

// ───────────────────────────── meal-plan dashboard ─────────────────────────

/// The first-page meal-plan slot. Three states: not set up (a CTA to open
/// settings), set up but transactions still loading (a shimmer placeholder),
/// and ready (the pacing card). Always followed by spacing before the account
/// list.
class _MealPlanSection extends StatelessWidget {
  final _HomeController data;
  final VoidCallback onSetup;

  const _MealPlanSection({required this.data, required this.onSetup});

  @override
  Widget build(BuildContext context) {
    final configured =
        data.mealPlan.isConfigured && data.mealPlanAccount != null;

    // Not set up and the CTA was dismissed → show nothing at all (setup still
    // lives in the Features popup).
    if (!configured && data.mealPlanCtaDismissed) {
      return const SizedBox.shrink();
    }

    Widget card;
    if (!configured) {
      card = _MealPlanSetupCard(
        onTap: onSetup,
        onDismiss: data.dismissMealPlanCta,
      );
    } else {
      final pacing = data.mealPlanPacing;
      if (pacing == null) {
        // Configured, but this account's transactions haven't landed yet.
        card = const Shimmer(child: Skeleton(height: 128, radius: 24));
      } else {
        card = _MealPlanCard(
          account: data.mealPlanAccount!,
          pacing: pacing,
          end: data.mealPlan.end!,
        );
      }
    }
    return Padding(padding: const EdgeInsets.only(bottom: 20), child: card);
  }
}

/// Shown when no meal plan is set up yet — invites the user into the Features
/// popup, or can be dismissed with the X (setup stays reachable there).
class _MealPlanSetupCard extends StatelessWidget {
  final VoidCallback onTap;
  final VoidCallback onDismiss;
  const _MealPlanSetupCard({required this.onTap, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.insights_rounded,
                  color: scheme.onPrimaryContainer,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Track your meal plan",
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "See how much you can spend per day to finish on time.",
                      style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                color: scheme.onSurfaceVariant,
                tooltip: "Dismiss",
                visualDensity: VisualDensity.compact,
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The pacing dashboard: how much can be spent per day to finish the plan by
/// term end, a status verdict, and a term-progress bar.
class _MealPlanCard extends StatelessWidget {
  final AccountBalance account;
  final MealPlanPacing pacing;
  final DateTime end;

  const _MealPlanCard({
    required this.account,
    required this.pacing,
    required this.end,
  });

  static const _green = Color(0xFF2E9E5B);
  static const _amber = Color(0xFFC77700);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ended = pacing.status == MealPlanStatus.termEnded;
    final (statusText, statusColor) = switch (pacing.status) {
      MealPlanStatus.onTrack => ("On track", _green),
      MealPlanStatus.tooFast => ("Spending too fast", scheme.error),
      MealPlanStatus.moneyToSpare => ("Money to spare", _amber),
      MealPlanStatus.termEnded => ("Term ended", scheme.onSurfaceVariant),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  "MEAL PLAN · ${account.displayName}",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.1,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              _StatusPill(text: statusText, color: statusColor),
            ],
          ),
          const SizedBox(height: 14),
          if (ended)
            _EndedHeadline(balance: pacing.balance, scheme: scheme)
          else
            _AllowanceHeadline(pacing: pacing, end: end, scheme: scheme),
          const SizedBox(height: 16),
          // Spent bar: fraction of the term-start balance used so far;
          // empty = pot untouched, full = all spent.
          // Micro-animation: eases from empty to its value on appearance.
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: pacing.spentFraction),
            duration: const Duration(milliseconds: 700),
            curve: Curves.easeOutCubic,
            builder: (_, v, _) => ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: v,
                minHeight: 6,
                backgroundColor: scheme.surface,
                valueColor: AlwaysStoppedAnimation(scheme.primary),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            ended
                ? "${_money(pacing.balance)} left over"
                : "${_money(pacing.balance)} left · "
                      "${pacing.daysRemaining} day${pacing.daysRemaining == 1 ? '' : 's'} remaining",
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _AllowanceHeadline extends StatelessWidget {
  final MealPlanPacing pacing;
  final DateTime end;
  final ColorScheme scheme;

  const _AllowanceHeadline({
    required this.pacing,
    required this.end,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              _money(pacing.perDayAllowance),
              style: TextStyle(
                fontFamily: 'BureauGrot',
                fontSize: 40,
                fontWeight: FontWeight.w800,
                letterSpacing: -1,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              "/ day",
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          "to finish by ${_monthDayYear(end)}",
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _EndedHeadline extends StatelessWidget {
  final double balance;
  final ColorScheme scheme;
  const _EndedHeadline({required this.balance, required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          balance <= 0 ? "All used up" : "Term's over",
          style: TextStyle(
            fontFamily: 'BureauGrot',
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          balance <= 0
              ? "You finished your meal plan."
              : "Your term has ended.",
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String text;
  final Color color;
  const _StatusPill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

// ─────────────────────────────── hero card ─────────────────────────────────

/// The balance hero. In the all-accounts menu it's tappable (chevron +
/// transaction count as the affordance); on the detail page it's static and
/// [trailing] is the "Updated …" pill. Micro-animations: the card compresses
/// slightly while pressed, and the balance counts up/down when it changes.
class _HeroCard extends StatefulWidget {
  final AccountBalance account;
  final Widget? trailing;
  final String? caption;
  final VoidCallback? onTap;

  const _HeroCard({
    required this.account,
    this.trailing,
    this.caption,
    this.onTap,
  });

  @override
  State<_HeroCard> createState() => _HeroCardState();
}

class _HeroCardState extends State<_HeroCard> {
  bool _pressed = false;

  AccountBalance get account => widget.account;
  VoidCallback? get onTap => widget.onTap;
  Widget? get trailing => widget.trailing;
  String? get caption => widget.caption;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onContainer = scheme.onPrimaryContainer;
    return AnimatedScale(
      scale: _pressed ? 0.98 : 1,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: Material(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          onTap: onTap,
          onHighlightChanged: onTap == null
              ? null
              : (v) => setState(() => _pressed = v),
          borderRadius: BorderRadius.circular(28),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        account.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: onContainer.withValues(alpha: 0.7),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.4,
                        ),
                      ),
                    ),
                    ?trailing,
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: _AnimatedAmount(
                        amount: account.amount,
                        style: TextStyle(
                          fontFamily: 'BureauGrot',
                          fontSize: 52,
                          fontWeight: FontWeight.w800,
                          color: onContainer,
                          letterSpacing: -1.5,
                        ),
                      ),
                    ),
                    if (onTap != null) ...[
                      const SizedBox(width: 12),
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: onContainer.withValues(alpha: 0.10),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.chevron_right,
                          color: onContainer.withValues(alpha: 0.8),
                          size: 22,
                        ),
                      ),
                    ],
                  ],
                ),
                if (caption != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    caption!,
                    style: TextStyle(
                      fontSize: 12,
                      color: onContainer.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A dollar amount that counts up/down to its new value when the underlying
/// balance changes (no animation on first appearance). Falls back to the raw
/// scraped string when it doesn't parse.
class _AnimatedAmount extends StatelessWidget {
  final String amount;
  final TextStyle style;

  const _AnimatedAmount({required this.amount, required this.style});

  /// "$1234.56" with thousands separators → "$1,234.56".
  static String _grouped(double v) {
    final s = v.toStringAsFixed(2);
    final neg = s.startsWith('-');
    final digits = neg ? s.substring(1) : s;
    final dot = digits.indexOf('.');
    final whole = digits.substring(0, dot);
    final buf = StringBuffer();
    for (var i = 0; i < whole.length; i++) {
      if (i > 0 && (whole.length - i) % 3 == 0) buf.write(',');
      buf.write(whole[i]);
    }
    return "${neg ? '-' : ''}\$$buf${digits.substring(dot)}";
  }

  @override
  Widget build(BuildContext context) {
    final value = double.tryParse(amount.replaceAll(RegExp(r'[^0-9.\-]'), ''));
    if (value == null) {
      return Text(
        amount,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    // TweenAnimationBuilder animates from its *current* value whenever the
    // tween's end changes — so a refresh that moves the balance counts toward
    // the new number, while the first build renders it immediately.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: value, end: value),
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      builder: (_, v, _) => Text(
        _grouped(v),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
  }
}

class _UpdatedPill extends StatelessWidget {
  final bool refreshing;
  final DateTime updated;

  /// True when the pill sits on the page background (the all-accounts menu)
  /// rather than on a hero card, which needs surface-toned colors.
  final bool onSurface;

  const _UpdatedPill({
    required this.refreshing,
    required this.updated,
    this.onSurface = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = onSurface
        ? scheme.onSurfaceVariant
        : scheme.onPrimaryContainer;
    final fg = base.withValues(alpha: onSurface ? 1.0 : 0.8);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: onSurface
            ? scheme.surfaceContainerHighest
            : base.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (refreshing) ...[
            SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 2, color: fg),
            ),
            const SizedBox(width: 6),
            Text("Refreshing…", style: TextStyle(fontSize: 11, color: fg)),
          ] else ...[
            Icon(Icons.schedule, size: 12, color: fg),
            const SizedBox(width: 5),
            Text(
              "Updated ${_relative(updated)}",
              style: TextStyle(fontSize: 11, color: fg),
            ),
          ],
        ],
      ),
    );
  }
}

// ───────────────────────────── formatting ──────────────────────────────────

String _money(double v) => "\$${v.toStringAsFixed(2)}";

const List<String> _monthAbbr = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "Apr 20, 2027" — always includes the year (used for term dates).
String _monthDayYear(DateTime d) =>
    "${_monthAbbr[d.month - 1]} ${d.day}, ${d.year}";

/// "Today" / "Yesterday" / "Mon, Jun 14" (with year if not the current one).
String _dayLabel(DateTime? d) {
  if (d == null) return "Other";
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return "Today";
  if (diff == 1) return "Yesterday";
  const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const mo = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final base = "${wd[day.weekday - 1]}, ${mo[day.month - 1]} ${day.day}";
  return day.year == today.year ? base : "$base, ${day.year}";
}

/// "just now", "5m ago", "2h ago" — keeps the hero from feeling stale.
String _relative(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inSeconds < 30) return "just now";
  if (diff.inMinutes < 1) return "${diff.inSeconds}s ago";
  if (diff.inHours < 1) return "${diff.inMinutes}m ago";
  if (diff.inDays < 1) return "${diff.inHours}h ago";
  return "${diff.inDays}d ago";
}

// ───────────────────────────── summary stat tile ───────────────────────────

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  const _StatTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────── date header ───────────────────────────────

class _DateHeader extends StatelessWidget {
  final String label;
  const _DateHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: scheme.onSurfaceVariant,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

// ─────────────────────────────── transaction row ───────────────────────────

class _TxnTile extends StatelessWidget {
  final Transaction t;
  const _TxnTile({required this.t});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final debit = t.isDebit;
    final accent = debit ? scheme.error : const Color(0xFF2E9E5B);

    final time = t.parsedDate;
    final subtitleParts = <String>[
      if (time != null) _time(time) else t.dateTime,
      if (t.label.isNotEmpty) t.label,
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              debit ? Icons.arrow_downward : Icons.arrow_upward,
              color: accent,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.terminalLabel.isEmpty ? "Transaction" : t.terminalLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitleParts.join("  ·  "),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            t.displayAmount,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }

  String _time(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    return "$h:$m ${d.hour < 12 ? 'AM' : 'PM'}";
  }
}

// ────────────────────────────── analytics tab ──────────────────────────────

/// Tab 1: spending analytics — a reconstructed balance-over-time line chart
/// plus this-month spend vs. the past-year monthly average. An account filter
/// scopes the whole tab to one account or all of them (the default).
class _AnalyticsView extends StatefulWidget {
  final _HomeController data;
  const _AnalyticsView({required this.data});

  @override
  State<_AnalyticsView> createState() => _AnalyticsViewState();
}

class _AnalyticsViewState extends State<_AnalyticsView> {
  /// Raw name of the account the tab is scoped to; null = all accounts.
  String? _account;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final txns = data.txns;
    if (txns == null) return analyticsSkeleton();

    final scheme = Theme.of(context).colorScheme;
    final accounts = data.accounts;

    // Resolve the selection against the current account list (it may have
    // changed across a refresh); an account that vanished falls back to "all".
    AccountBalance? selected;
    for (final acc in accounts) {
      if (acc.name == _account) selected = acc;
    }

    final filteredTxns =
        selected == null ? txns : (data.txnsFor(selected) ?? const []);
    final balance =
        selected == null ? data.totalBalance : (selected.amountValue ?? 0);
    final a = _Analytics.from(filteredTxns, balance);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 140),
      children: [
        if (accounts.length > 1) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text("All accounts"),
                selected: selected == null,
                onSelected: (_) => setState(() => _account = null),
              ),
              for (final acc in accounts)
                ChoiceChip(
                  label: Text(acc.displayName),
                  selected: selected?.name == acc.name,
                  onSelected: (_) => setState(() => _account = acc.name),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (a.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 64),
            child: Column(
              children: [
                Icon(
                  Icons.query_stats_outlined,
                  size: 48,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(height: 12),
                Text(
                  "No spending to analyze yet",
                  style:
                      TextStyle(color: scheme.onSurfaceVariant, fontSize: 15),
                ),
              ],
            ),
          )
        else ...[
          _MonthSummaryCard(a: a),
          const SizedBox(height: 16),
          // Keyed on the filter so switching accounts re-runs the chart's
          // draw-in animation with the new curve.
          _BalanceTrendCard(key: ValueKey(_account), a: a),
          const SizedBox(height: 16),
          _TopMerchantsCard(txns: filteredTxns),
          const SizedBox(height: 16),
          _SpendingPatternsCard(txns: filteredTxns),
        ],
      ],
    );
  }
}

/// Everything the Analytics tab renders, derived once from the transaction
/// list plus the current total balance.
class _Analytics {
  /// (date, balance) after each transaction, oldest→newest, plus a final point
  /// at "now" — the reconstructed balance curve.
  final List<({DateTime date, double value})> balanceSeries;

  final double thisMonthSpend;

  /// Average monthly spend over the past year's completed months (0 if none).
  final double typicalMonthSpend;

  final int thisMonthCount;

  const _Analytics({
    required this.balanceSeries,
    required this.thisMonthSpend,
    required this.typicalMonthSpend,
    required this.thisMonthCount,
  });

  bool get isEmpty => balanceSeries.length < 2 && thisMonthSpend == 0;

  factory _Analytics.from(List<Transaction> txns, double totalBalance) {
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month, 1);

    // Dated transactions, oldest first.
    final dated = txns.where((t) => t.parsedDate != null).toList()
      ..sort((x, y) => x.parsedDate!.compareTo(y.parsedDate!));

    // Reconstruct balance history: current total is the balance after the most
    // recent transaction; walk backwards undoing each one.
    final series = <({DateTime date, double value})>[];
    var running = totalBalance;
    for (var i = dated.length - 1; i >= 0; i--) {
      series.add((date: dated[i].parsedDate!, value: running));
      running -= dated[i].amountValue; // balance just before this txn
    }
    final ordered = series.reversed.toList();
    // Flat segment out to "now" (balance doesn't move without a transaction).
    if (ordered.isNotEmpty) {
      ordered.add((date: now, value: totalBalance));
    }

    // Spending aggregates (debits only; amountValue is negative for debits).
    var thisMonthSpend = 0.0;
    var thisMonthCount = 0;
    final yearStart = DateTime(now.year - 1, now.month, 1);
    var pastYearSpend = 0.0;
    DateTime? firstDebitMonth;
    for (final t in dated) {
      if (!t.isDebit) continue;
      final amt = -t.amountValue;
      final d = t.parsedDate!;
      firstDebitMonth ??= DateTime(d.year, d.month, 1);
      if (!d.isBefore(monthStart)) {
        thisMonthSpend += amt;
        thisMonthCount++;
      } else if (!d.isBefore(yearStart)) {
        pastYearSpend += amt;
      }
    }

    // Typical month = average monthly spend over the past year's completed
    // months (zero-spend months count; a shorter history isn't diluted).
    var typicalMonth = 0.0;
    if (firstDebitMonth != null) {
      final from = firstDebitMonth.isAfter(yearStart) ? firstDebitMonth : yearStart;
      final monthsSpanned =
          (monthStart.year - from.year) * 12 + monthStart.month - from.month;
      if (monthsSpanned > 0) typicalMonth = pastYearSpend / monthsSpanned;
    }

    return _Analytics(
      balanceSeries: ordered,
      thisMonthSpend: thisMonthSpend,
      typicalMonthSpend: typicalMonth,
      thisMonthCount: thisMonthCount,
    );
  }
}

/// "This month you've spent $X" with a comparison to the past-year monthly
/// average.
class _MonthSummaryCard extends StatelessWidget {
  final _Analytics a;
  const _MonthSummaryCard({required this.a});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasTypical = a.typicalMonthSpend > 0;
    final diff = a.thisMonthSpend - a.typicalMonthSpend;
    final up = diff > 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "THIS MONTH YOU'VE SPENT",
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.1,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _money(a.thisMonthSpend),
            style: TextStyle(
              fontFamily: 'BureauGrot',
              fontSize: 40,
              fontWeight: FontWeight.w800,
              letterSpacing: -1,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          if (hasTypical)
            Row(
              children: [
                Icon(
                  up ? Icons.trending_up : Icons.trending_down,
                  size: 16,
                  color: up ? scheme.error : const Color(0xFF2E9E5B),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    "${_money(diff.abs())} ${up ? 'more' : 'less'} than your "
                    "past-year monthly average (${_money(a.typicalMonthSpend)})",
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            )
          else
            Text(
              "Across ${a.thisMonthCount} purchase"
              "${a.thisMonthCount == 1 ? '' : 's'} this month",
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

/// The selectable trailing window for the Top places / Spending patterns
/// cards. Null days = all time.
enum _StatsWindow {
  d30(days: 30, label: "30 days"),
  d90(days: 90, label: "90 days"),
  year(days: 365, label: "Past year"),
  all(days: null, label: "All time");

  final int? days;
  final String label;
  const _StatsWindow({required this.days, required this.label});

  /// Start of the window ending at [now], or null for all time.
  DateTime? cutoff(DateTime now) {
    final w = days;
    return w == null ? null : now.subtract(Duration(days: w));
  }

  /// Whether [d] falls inside the window ending at [now].
  bool contains(DateTime d, DateTime now) {
    final c = cutoff(now);
    return c == null || d.isAfter(c);
  }
}

/// Each analytics card remembers its window selection across sessions, under
/// `stats_window_<id>` (ids: chart / merchants / patterns).
Future<_StatsWindow?> _loadStatsWindow(String id) async {
  final prefs = await SharedPreferences.getInstance();
  final name = prefs.getString('stats_window_$id');
  for (final w in _StatsWindow.values) {
    if (w.name == name) return w;
  }
  return null;
}

Future<void> _saveStatsWindow(String id, _StatsWindow w) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('stats_window_$id', w.name);
}

/// State mixin for a card with a persisted window selection: starts on
/// [defaultWindow], restores the saved choice on mount, and [setWindow]
/// persists changes.
mixin _PersistedWindow<T extends StatefulWidget> on State<T> {
  String get windowPrefId;
  _StatsWindow get defaultWindow;

  late _StatsWindow _window = defaultWindow;

  @override
  void initState() {
    super.initState();
    _loadStatsWindow(windowPrefId).then((w) {
      if (w != null && w != _window && mounted) setState(() => _window = w);
    });
  }

  void setWindow(_StatsWindow w) {
    setState(() => _window = w);
    _saveStatsWindow(windowPrefId, w);
  }
}

/// The compact "30 days ▾" window filter in a stats card's top-right corner.
class _WindowMenu extends StatelessWidget {
  final _StatsWindow value;
  final ValueChanged<_StatsWindow> onChanged;
  const _WindowMenu({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<_StatsWindow>(
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final w in _StatsWindow.values)
          PopupMenuItem(value: w, child: Text(w.label)),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          Icon(
            Icons.arrow_drop_down,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

/// Top 5 merchants in the selected window, each with a proportion bar scaled
/// to the biggest spender on the list.
class _TopMerchantsCard extends StatefulWidget {
  /// The tab's (account-filtered) transactions.
  final List<Transaction> txns;
  const _TopMerchantsCard({required this.txns});

  @override
  State<_TopMerchantsCard> createState() => _TopMerchantsCardState();
}

class _TopMerchantsCardState extends State<_TopMerchantsCard>
    with _PersistedWindow {
  @override
  String get windowPrefId => 'merchants';
  @override
  _StatsWindow get defaultWindow => _StatsWindow.d30;

  List<({String name, double total, int count})> _top() {
    final now = DateTime.now();
    final byMerchant = <String, ({double total, int count})>{};
    for (final t in widget.txns) {
      if (!t.isDebit) continue;
      final d = t.parsedDate;
      if (d == null || !_window.contains(d, now)) continue;
      final name = t.terminalLabel;
      if (name.isEmpty) continue;
      final prev = byMerchant[name] ?? (total: 0.0, count: 0);
      byMerchant[name] =
          (total: prev.total - t.amountValue, count: prev.count + 1);
    }
    final ranked = byMerchant.entries
        .map((e) => (name: e.key, total: e.value.total, count: e.value.count))
        .toList()
      ..sort((x, y) => y.total.compareTo(x.total));
    return ranked.take(5).toList();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final top = _top();
    final max = top.isEmpty ? 0.0 : top.first.total;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  "TOP PLACES",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.1,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              _WindowMenu(value: _window, onChanged: setWindow),
            ],
          ),
          if (top.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                "No purchases in this period",
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
          for (final m in top) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    m.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  "${m.count} visit${m.count == 1 ? '' : 's'}",
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _money(m.total),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: max <= 0 ? 0 : (m.total / max).clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: scheme.surface,
                valueColor: AlwaysStoppedAnimation(scheme.primary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Debit totals per weekday in the selected window as mini bars, plus a
/// caption naming the peak day and — when timestamps allow — the peak time of
/// day.
class _SpendingPatternsCard extends StatefulWidget {
  /// The tab's (account-filtered) transactions.
  final List<Transaction> txns;
  const _SpendingPatternsCard({required this.txns});

  @override
  State<_SpendingPatternsCard> createState() => _SpendingPatternsCardState();
}

class _SpendingPatternsCardState extends State<_SpendingPatternsCard>
    with _PersistedWindow {
  @override
  String get windowPrefId => 'patterns';
  @override
  _StatsWindow get defaultWindow => _StatsWindow.d90;

  static const _dayLetters = ["M", "T", "W", "T", "F", "S", "S"];
  static const _dayNames = [
    "Mondays",
    "Tuesdays",
    "Wednesdays",
    "Thursdays",
    "Fridays",
    "Saturdays",
    "Sundays",
  ];

  /// Debit totals per weekday (index 0 = Monday) in the window, plus the peak
  /// time-of-day phrase — null when too few rows carry a real timestamp.
  (List<double>, String?) _patterns() {
    final now = DateTime.now();
    final weekdaySpend = List<double>.filled(7, 0);
    // Time-of-day buckets: morning / lunch / afternoon / dinner / late night.
    final bucketSpend = List<double>.filled(5, 0);
    var debits = 0, timedDebits = 0;
    for (final t in widget.txns) {
      if (!t.isDebit) continue;
      final d = t.parsedDate;
      if (d == null || !_window.contains(d, now)) continue;
      final amt = -t.amountValue;
      weekdaySpend[d.weekday - 1] += amt;
      debits++;
      // The site omits the time on some rows; parsedDate reads those as
      // exactly midnight, so only real timestamps feed the buckets.
      if (d.hour != 0 || d.minute != 0) {
        timedDebits++;
        bucketSpend[switch (d.hour) {
          >= 6 && < 11 => 0, // morning
          >= 11 && < 14 => 1, // lunch
          >= 14 && < 17 => 2, // afternoon
          >= 17 && < 21 => 3, // dinner
          _ => 4, // late night
        }] += amt;
      }
    }

    // Only call a peak time when at least half the window's debits are
    // actually timestamped — otherwise the buckets are too sparse to trust.
    String? peakTimeLabel;
    if (timedDebits > 0 && timedDebits * 2 >= debits) {
      var peak = 0;
      for (var i = 1; i < bucketSpend.length; i++) {
        if (bucketSpend[i] > bucketSpend[peak]) peak = i;
      }
      peakTimeLabel = const [
        "in the morning",
        "around lunch",
        "in the afternoon",
        "around dinner",
        "late at night",
      ][peak];
    }
    return (weekdaySpend, peakTimeLabel);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (weekdaySpend, peakTimeLabel) = _patterns();
    var peak = 0;
    var max = 0.0;
    for (var i = 0; i < 7; i++) {
      if (weekdaySpend[i] > max) {
        max = weekdaySpend[i];
        peak = i;
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  "SPENDING PATTERNS",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.1,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              _WindowMenu(value: _window, onChanged: setWindow),
            ],
          ),
          if (max <= 0) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                "No purchases in this period",
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
          ] else ...[
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Column(
                        children: [
                          SizedBox(
                            height: 64,
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: FractionallySizedBox(
                                heightFactor:
                                    (weekdaySpend[i] / max).clamp(0.04, 1.0),
                                child: Container(
                                  width: double.infinity,
                                  decoration: BoxDecoration(
                                    color: scheme.primary,
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(4),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _dayLetters[i],
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: i == peak
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: i == peak
                                  ? scheme.onSurface
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              "Most spending on ${_dayNames[peak]}"
              "${peakTimeLabel == null ? '' : ' · usually $peakTimeLabel'}",
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

/// The reconstructed balance-over-time line chart in a titled card, with the
/// same top-right window filter as the stats cards (default: 30 days) and
/// labelled axes.
class _BalanceTrendCard extends StatefulWidget {
  final _Analytics a;
  const _BalanceTrendCard({super.key, required this.a});

  @override
  State<_BalanceTrendCard> createState() => _BalanceTrendCardState();
}

class _BalanceTrendCardState extends State<_BalanceTrendCard>
    with _PersistedWindow {
  @override
  String get windowPrefId => 'chart';
  @override
  _StatsWindow get defaultWindow => _StatsWindow.d30;

  /// The series clipped to the selected window (all time = uncut). Balance is
  /// a step function, so a synthetic point is prepended at the cutoff carrying
  /// the last value from before it — the line always spans the full window,
  /// even for a quiet month.
  List<({DateTime date, double value})> _windowed() {
    final all = widget.a.balanceSeries;
    final cutoff = _window.cutoff(DateTime.now());
    if (cutoff == null) return all;
    final inWindow = all.where((p) => p.date.isAfter(cutoff)).toList();
    ({DateTime date, double value})? boundary;
    for (final p in all) {
      if (p.date.isAfter(cutoff)) break;
      boundary = (date: cutoff, value: p.value);
    }
    return [?boundary, ...inWindow];
  }

  /// X-axis tick label: month-only once the window spans several months, and
  /// month + year ("Sep 2026") when the plotted range crosses a year boundary
  /// so identical month names can't collide.
  String _tick(DateTime d, bool multiYear) {
    final days = _window.days;
    final monthsOnly = days == null || days > 120;
    if (!monthsOnly) return "${_monthAbbr[d.month - 1]} ${d.day}";
    return multiYear
        ? "${_monthAbbr[d.month - 1]} ${d.year}"
        : _monthAbbr[d.month - 1];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    var pts = _windowed();
    if (pts.length < 2) pts = widget.a.balanceSeries;
    final multiYear =
        pts.length >= 2 && pts.first.date.year != pts.last.date.year;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  "BALANCE OVER TIME",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.1,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              _WindowMenu(value: _window, onChanged: setWindow),
            ],
          ),
          const SizedBox(height: 14),
          if (pts.length < 2)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  "Not enough history yet",
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else
            SizedBox(
              height: 190,
              width: double.infinity,
              // Micro-animation: the line draws itself left-to-right when the
              // chart appears or the window changes (keyed on the window).
              child: TweenAnimationBuilder<double>(
                key: ValueKey(_window),
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                builder: (_, progress, _) => CustomPaint(
                  painter: _LineChartPainter(
                    points: pts,
                    line: scheme.primary,
                    fill: scheme.primary.withValues(alpha: 0.12),
                    gridColor: scheme.onSurfaceVariant.withValues(alpha: 0.15),
                    labelStyle: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
                    ),
                    xTickLabel: (d) => _tick(d, multiYear),
                    progress: progress,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A line chart with a soft fill, horizontal price gridlines (Y axis), and
/// date ticks (X axis). Pure Flutter, no dependency.
class _LineChartPainter extends CustomPainter {
  final List<({DateTime date, double value})> points;
  final Color line;
  final Color fill;
  final Color gridColor;
  final TextStyle labelStyle;
  final String Function(DateTime) xTickLabel;

  /// Draw-in progress (0–1): the curve is trimmed to this fraction of its
  /// length so it draws itself left-to-right. Axes render fully regardless.
  final double progress;

  _LineChartPainter({
    required this.points,
    required this.line,
    required this.fill,
    required this.gridColor,
    required this.labelStyle,
    required this.xTickLabel,
    this.progress = 1,
  });

  static const _yTicks = 4;
  static const _xTicks = 4;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    // Gutters reserved for axis labels.
    const leftPad = 44.0, bottomPad = 18.0, topPad = 6.0, rightPad = 6.0;
    final chart = Rect.fromLTRB(
      leftPad,
      topPad,
      size.width - rightPad,
      size.height - bottomPad,
    );

    final minX = points.first.date.millisecondsSinceEpoch.toDouble();
    final maxX = points.last.date.millisecondsSinceEpoch.toDouble();
    var minY = points.first.value, maxY = points.first.value;
    for (final p in points) {
      if (p.value < minY) minY = p.value;
      if (p.value > maxY) maxY = p.value;
    }
    // A flat line needs an artificial range to sit mid-chart.
    if ((maxY - minY).abs() < 0.01) {
      minY -= 1;
      maxY += 1;
    }
    final spanX = (maxX - minX).abs() < 1 ? 1 : maxX - minX;
    final spanY = maxY - minY;

    Offset at(({DateTime date, double value}) p) => Offset(
      chart.left + (p.date.millisecondsSinceEpoch - minX) / spanX * chart.width,
      chart.top + (1 - (p.value - minY) / spanY) * chart.height,
    );

    void drawLabel(String text, Offset center, {bool alignRight = false}) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx = alignRight ? center.dx - tp.width : center.dx - tp.width / 2;
      tp.paint(canvas, Offset(dx, center.dy - tp.height / 2));
    }

    String price(double v) =>
        v.abs() >= 100 ? "\$${v.round()}" : "\$${v.toStringAsFixed(2)}";

    // Y axis: horizontal gridlines with price labels in the left gutter.
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i < _yTicks; i++) {
      final f = i / (_yTicks - 1);
      final v = maxY - f * spanY;
      final y = chart.top + f * chart.height;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
      drawLabel(price(v), Offset(chart.left - 6, y), alignRight: true);
    }

    // X axis: evenly spaced date ticks along the bottom.
    for (var i = 0; i < _xTicks; i++) {
      final f = i / (_xTicks - 1);
      final ms = minX + f * spanX;
      final d = DateTime.fromMillisecondsSinceEpoch(ms.round());
      // Nudge the edge labels inward so they don't clip.
      final x = (chart.left + f * chart.width).clamp(
        chart.left + 14,
        chart.right - 14,
      );
      drawLabel(xTickLabel(d), Offset(x, size.height - bottomPad / 2));
    }

    // The curve itself, clipped to the chart area and trimmed to [progress]
    // of its length for the draw-in animation.
    canvas.save();
    canvas.clipRect(chart.inflate(4));
    final fullPath = Path();
    for (var i = 0; i < points.length; i++) {
      final o = at(points[i]);
      i == 0 ? fullPath.moveTo(o.dx, o.dy) : fullPath.lineTo(o.dx, o.dy);
    }

    var linePath = fullPath;
    var lineEnd = at(points.last);
    if (progress < 1) {
      final trimmed = Path();
      for (final metric in fullPath.computeMetrics()) {
        trimmed.addPath(
          metric.extractPath(0, metric.length * progress),
          Offset.zero,
        );
        final tangent = metric.getTangentForOffset(metric.length * progress);
        if (tangent != null) lineEnd = tangent.position;
      }
      linePath = trimmed;
    }

    final fillPath = Path.from(linePath)
      ..lineTo(lineEnd.dx, chart.bottom)
      ..lineTo(chart.left, chart.bottom)
      ..close();
    canvas.drawPath(fillPath, Paint()..color = fill);
    canvas.drawPath(
      linePath,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(lineEnd, 3.5, Paint()..color = line);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LineChartPainter old) =>
      old.points != points ||
      old.line != line ||
      old.fill != fill ||
      old.progress != progress;
}

// ─────────────────────────────── extras tab ────────────────────────────────

/// The "Extras" tab: capabilities that act on the account (meal-plan tracking,
/// changing the card PIN) — distinct from [_SettingsView], which holds app
/// preferences (theme, logs, sign out).
class _ExtrasView extends StatefulWidget {
  final List<AccountBalance> accounts;

  /// Called after the meal-plan selection or its dates change, so the caller
  /// can refresh the dashboard card.
  final VoidCallback onMealPlanChanged;

  const _ExtrasView({required this.accounts, required this.onMealPlanChanged});

  @override
  State<_ExtrasView> createState() => _ExtrasViewState();
}

class _ExtrasViewState extends State<_ExtrasView> {
  MealPlanConfig _mealPlan = const MealPlanConfig();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadMealPlan();
  }

  Future<void> _loadMealPlan() async {
    final config = await MealPlanConfig.load();
    if (mounted) {
      setState(() {
        _mealPlan = config;
        _loading = false;
      });
    }
  }

  Future<void> _setMealPlanAccount(String? name) async {
    setState(() {
      _mealPlan = name == null
          ? const MealPlanConfig()
          : _mealPlan.copyWith(accountName: name);
    });
    if (name == null) {
      await MealPlanConfig.clear();
    } else {
      await _mealPlan.save();
      // Picking a plan counts as acknowledging the feature, so the home CTA
      // never reappears even if they later switch back to None.
      await setMealPlanCtaDismissed(true);
    }
    widget.onMealPlanChanged();
  }

  Future<void> _pickTermDate(bool isStart) async {
    final initial =
        (isStart ? _mealPlan.start : _mealPlan.end) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      _mealPlan = MealPlanConfig(
        accountName: _mealPlan.accountName,
        start: isStart ? picked : _mealPlan.start,
        end: isStart ? _mealPlan.end : picked,
      );
    });
    await _mealPlan.save();
    widget.onMealPlanChanged();
  }

  /// A tappable date "input field". Unset dates get a primary-coloured border
  /// and "Select date" prompt so it's obvious they're waiting to be filled in;
  /// set dates show the value with a calendar icon, still clearly tappable.
  Widget _termDateField(
    String label,
    DateTime? date,
    VoidCallback onTap,
    ColorScheme scheme,
  ) {
    final isSet = date != null;
    final accent = isSet ? scheme.onSurfaceVariant : scheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(
            color: isSet ? scheme.outlineVariant : scheme.primary,
            width: isSet ? 1 : 1.5,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.calendar_today_outlined, size: 15, color: accent),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    isSet ? _monthDayYear(date) : "Select date",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isSet ? scheme.onSurface : scheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Popup to set a new campus-card PIN: two fields that must match. The PIN
  /// can be any length and mix letters/digits, so no length or numeric
  /// constraint — only that the confirmation matches. Submitting hits the site
  /// and reports success or failure inline.
  Future<void> _showChangePinDialog() async {
    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    var busy = false;
    String? errorText;

    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final scheme = Theme.of(dialogContext).colorScheme;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            Future<void> submit() async {
              final pin = pinController.text;
              final confirm = confirmController.text;
              if (pin.isEmpty) {
                setDialogState(() => errorText = "Enter a new PIN");
                return;
              }
              if (pin != confirm) {
                setDialogState(() => errorText = "PINs don't match");
                return;
              }
              setDialogState(() {
                busy = true;
                errorText = null;
              });
              try {
                final cookies = await loadSession();
                if (cookies == null) throw Exception("Session Expired");
                await Scraper().changeCardPin(cookies, pin);
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop(true);
                }
              } catch (e) {
                setDialogState(() {
                  busy = false;
                  errorText = e.toString().contains("Expired")
                      ? "Your session expired. Sign in again."
                      : "Couldn't change your PIN. Try again.";
                });
              }
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: const Text("Change card PIN"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: pinController,
                    autofocus: true,
                    obscureText: true,
                    enabled: !busy,
                    decoration: const InputDecoration(
                      labelText: "New Card PIN",
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: confirmController,
                    obscureText: true,
                    enabled: !busy,
                    decoration: InputDecoration(
                      labelText: "Re-enter Card PIN",
                      errorText: errorText,
                    ),
                    onSubmitted: busy ? null : (_) => submit(),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: busy
                      ? null
                      : () => Navigator.of(dialogContext).pop(false),
                  child: const Text("Cancel"),
                ),
                FilledButton(
                  onPressed: busy ? null : submit,
                  child: busy
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.onPrimary,
                          ),
                        )
                      : const Text("Save"),
                ),
              ],
            );
          },
        );
      },
    );

    if (changed == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Card PIN changed.")));
    }
  }

  /// The university's online WatCard top-up page.
  static const _depositUrl =
      "https://watcard.uwaterloo.ca/WatCardDeposit/deposit";

  /// Opens the deposit page in a Chrome Custom Tab / SFSafariViewController —
  /// a real browser context (shared cookies, autofillable payment forms), not
  /// the app's scraping WebView.
  Future<void> _openDepositPage(BuildContext context) async {
    try {
      await ChromeSafariBrowser().open(url: WebUri(_depositUrl));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't open the deposit page.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return extrasSkeleton();
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 140),
      children: [
        _SectionCard(
          title: "MEAL PLAN",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Track one account as a meal plan to pace it down by term end.",
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text("None"),
                    selected: _mealPlan.accountName == null,
                    onSelected: (_) => _setMealPlanAccount(null),
                  ),
                  for (final a in widget.accounts)
                    ChoiceChip(
                      label: Text(a.displayName),
                      selected: _mealPlan.accountName == a.name,
                      onSelected: (_) => _setMealPlanAccount(a.name),
                    ),
                ],
              ),
              if (_mealPlan.accountName != null) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _termDateField(
                        "Term start",
                        _mealPlan.start,
                        () => _pickTermDate(true),
                        scheme,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _termDateField(
                        "Term end",
                        _mealPlan.end,
                        () => _pickTermDate(false),
                        scheme,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: "ADD FUNDS",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Top up your WatCard online.",
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: ChoiceChip(
                  label: const Text("Add funds"),
                  selected: false,
                  onSelected: (_) => _openDepositPage(context),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: "CARD PIN",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Set a new PIN for your WatCard.",
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                // Same widget as the "None" meal-plan chip so the font, colour,
                // and border match exactly (it's an action, so it never shows a
                // selected state).
                child: ChoiceChip(
                  label: const Text("Change card PIN"),
                  selected: false,
                  onSelected: (_) => _showChangePinDialog(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The analytics-style "bubble" every Extras/Settings subsection sits in:
/// rounded surface card with an uppercase letter-spaced title.
class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.1,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

// ─────────────────────────────── settings tab ──────────────────────────────

class _SettingsView extends StatefulWidget {
  final ThemeController theme;
  final _HomeController data;
  final VoidCallback onSignedOut;

  const _SettingsView({
    required this.theme,
    required this.data,
    required this.onSignedOut,
  });

  @override
  State<_SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<_SettingsView> {
  String? _widgetAccount;
  bool _loading = true;

  List<AccountBalance> get accounts => widget.data.accounts;

  @override
  void initState() {
    super.initState();
    _loadWidgetAccount();
  }

  Future<void> _loadWidgetAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(kWidgetAccountKey);
    if (!mounted) return;
    setState(() {
      _loading = false;
      // Default to the first account when nothing is saved (or the saved one
      // no longer exists), matching what the scraper actually pushes.
      _widgetAccount = accounts.any((a) => a.name == saved)
          ? saved
          : (accounts.isEmpty ? null : accounts.first.name);
    });
  }

  Future<void> _selectWidgetAccount(String name) async {
    setState(() => _widgetAccount = name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kWidgetAccountKey, name);
    // Re-push immediately so the home-screen widget switches without waiting
    // for the next scrape.
    await Scraper().pushSelectedBalanceToWidget(accounts);
  }

  /// Confirm, then wipe the local cache and refetch the complete history.
  Future<void> _confirmResync() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Re-sync history?"),
        content: const Text(
          "This clears the locally cached transactions and re-downloads your "
          "full transaction history. Use it if anything ever looks wrong.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Re-sync"),
          ),
        ],
      ),
    );
    if (ok == true) await widget.data.resync();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return settingsSkeleton();
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 140),
      children: [
        _SectionCard(
          title: "THEME",
          child: ListenableBuilder(
            listenable: widget.theme,
            builder: (context, _) => Wrap(
              alignment: WrapAlignment.center,
              spacing: 16,
              runSpacing: 16,
              children: AppTheme.values
                  .map(
                    (t) => _ThemeSwatch(
                      option: t,
                      selected: widget.theme.theme == t,
                      onTap: () => widget.theme.set(t),
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
        if (accounts.length > 1) ...[
          const SizedBox(height: 16),
          _SectionCard(
            title: "WIDGET ACCOUNT",
            child: RadioGroup<String>(
              groupValue: _widgetAccount,
              onChanged: (v) {
                if (v != null) _selectWidgetAccount(v);
              },
              child: Column(
                children: accounts
                    .map(
                      (a) => RadioListTile<String>(
                        value: a.name,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(a.displayName),
                        secondary: Text(
                          a.amount,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        _SectionCard(
          title: "LOGS",
          child: Align(
            alignment: Alignment.centerLeft,
            // Bordered chip matching the "None" meal-plan chip.
            child: ChoiceChip(
              label: const Text("View logs"),
              selected: false,
              onSelected: (_) => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const LogViewerPage())),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: "DATA",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Clear the local cache and re-download your full "
                "transaction history.",
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: ListenableBuilder(
                  listenable: widget.data,
                  builder: (context, _) => ChoiceChip(
                    label: Text(
                      widget.data.refreshing ? "Syncing…" : "Re-sync history",
                    ),
                    selected: false,
                    onSelected: widget.data.refreshing
                        ? null
                        : (_) => _confirmResync(),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: "SIGN OUT",
          child: Align(
            alignment: Alignment.centerLeft,
            child: ChoiceChip(
              label: const Text("Sign out"),
              selected: false,
              onSelected: (_) async {
                await clearSession();
                widget.onSignedOut();
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _ThemeSwatch extends StatelessWidget {
  final AppTheme option;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeSwatch({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: option.swatch,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? scheme.primary : scheme.outlineVariant,
                  width: selected ? 3 : 1,
                ),
              ),
              child: selected
                  ? Icon(
                      Icons.check,
                      color: option == AppTheme.light
                          ? Colors.black
                          : Colors.white,
                      size: 22,
                    )
                  : null,
            ),
            const SizedBox(height: 6),
            Text(
              option.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────── bottom nav bar ────────────────────────────

/// Floating, rounded bottom navigation bar. Purely presentational for now:
/// tapping a tab updates the highlighted selection but doesn't change what the
/// screen shows.
class _BottomNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _BottomNavBar({required this.currentIndex, required this.onTap});

  // (unselected icon, selected icon, label)
  static const _items = <(IconData, IconData, String)>[
    (Icons.dashboard_outlined, Icons.dashboard_rounded, 'Dashboard'),
    (Icons.analytics_outlined, Icons.analytics_rounded, 'Analytics'),
    (Icons.extension_outlined, Icons.extension_rounded, 'Extras'),
    (Icons.settings_outlined, Icons.settings_rounded, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(28),
          // Subtle outline so the pill reads against content scrolling
          // behind it (extendBody), whatever the theme.
          border: Border.all(color: scheme.outlineVariant, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            for (var i = 0; i < _items.length; i++)
              _NavItem(
                icon: currentIndex == i ? _items[i].$2 : _items[i].$1,
                label: _items[i].$3,
                selected: currentIndex == i,
                onTap: () => onTap(i),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      // No ripple/highlight: the pill is the only selection feedback, so a tap
      // can never flash a fading splash over the previous selection.
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The newly selected pill pops in with a small overshoot; the old
            // tab's pill still disappears instantly (no lingering fade — see
            // the earlier flash fix). The TweenAnimationBuilder only exists on
            // the selected item, so it mounts (and animates) exactly once per
            // selection change.
            if (selected)
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.8, end: 1),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutBack,
                builder: (_, scale, child) =>
                    Transform.scale(scale: scale, child: child),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, size: 22, color: color),
                ),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, size: 22, color: color),
              ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
