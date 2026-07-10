import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watbal/auth.dart';
import 'package:watbal/log_viewer_page.dart';
import 'package:watbal/main.dart';
import 'package:watbal/scraper.dart';

/// SharedPreferences key holding the raw name of the account the user starred
/// in the all-accounts menu. At most one account is starred; it sorts to the
/// top of the menu and is the one the app auto-opens on launch. Absent = no
/// star (the first account is the launch default).
const String _starredAccountKey = 'starred_account';

/// The app's root screen. What it shows depends on how many accounts exist:
///
/// - **One account** — no menu to speak of; renders that account's
///   [_AccountDetailPage] (hero, spending summary, search, history) directly.
/// - **Several** — the all-accounts menu: one tappable hero card per account,
///   starred account first, star toggle in each card's top-right. On launch
///   it immediately auto-opens the starred (or first) account's detail page,
///   so the menu is what the back button reveals.
///
/// All data (balances, transactions, the account ↔ balance-ID map, the star)
/// lives in a shared [_HomeController] so the menu and any open detail page
/// stay in sync through a single fetch — transactions for every account come
/// from one TransactionsPass call anyway.
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

  @override
  void initState() {
    super.initState();
    _data = _HomeController(
      accounts: widget.accounts,
      onAccountsChanged: widget.onAccountsChanged,
      onSignedOut: _signOut,
    );
    _data.load();
    _autoOpenDefault();
  }

  /// Launch behavior for multi-account users: land on the starred (or first)
  /// account's detail page with the all-accounts menu underneath, so the app
  /// opens on the numbers that matter and back reveals the menu. Zero-length
  /// forward transition = the app appears to open directly on the detail.
  Future<void> _autoOpenDefault() async {
    await _data.loadStarred();
    if (!mounted || widget.accounts.length <= 1) return;
    final account = _data.defaultAccount;
    if (account == null) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, _, _) => _AccountDetailPage(
          data: _data,
          account: account,
          theme: widget.theme,
        ),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: const Duration(milliseconds: 200),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
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
        builder: (_) => _AccountDetailPage(
          data: _data,
          account: account,
          theme: widget.theme,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: _data,
      builder: (context, _) {
        // A lone account needs no menu — its detail page *is* the app.
        if (_data.accounts.length == 1) {
          return _AccountDetailPage(
            data: _data,
            account: _data.accounts.first,
            theme: widget.theme,
          );
        }
        final accounts = _data.sortedAccounts;
        return Scaffold(
          appBar: AppBar(
            title: const Text(
              "WatBal",
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => _showSettings(context),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: _data.refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
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
                for (var i = 0; i < accounts.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  _HeroCard(
                    account: accounts[i],
                    trailing: _StarButton(
                      starred: _data.starred == accounts[i].name,
                      onTap: () => _data.toggleStar(accounts[i].name),
                    ),
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
          ),
        );
      },
    );
  }

  /// "12 transactions" under the balance — doubles as the tap affordance.
  /// Blank until the first transactions fetch lands.
  String? _caption(AccountBalance account) {
    final txns = _data.txnsFor(account);
    if (txns == null) return null;
    return "${txns.length} transaction${txns.length == 1 ? '' : 's'}";
  }

  void _showSettings(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => _SettingsDialog(
        theme: widget.theme,
        accounts: _data.accounts,
        onSignedOut: () {
          Navigator.of(context).pop();
          _signOut();
        },
      ),
    );
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

  /// Raw name of the starred account, or null. At most one.
  String? _starred;
  String? get starred => _starred;

  Future<void> loadStarred() async {
    final prefs = await SharedPreferences.getInstance();
    _starred = prefs.getString(_starredAccountKey);
    notifyListeners();
  }

  /// Stars [name] (unstarring whatever held the star), or unstars it when it
  /// already holds the star.
  Future<void> toggleStar(String name) async {
    _starred = _starred == name ? null : name;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (_starred == null) {
      await prefs.remove(_starredAccountKey);
    } else {
      await prefs.setString(_starredAccountKey, _starred!);
    }
  }

  /// Accounts in menu order: the starred one first, the rest as scraped.
  List<AccountBalance> get sortedAccounts {
    final list = List.of(_accounts);
    final i = list.indexWhere((a) => a.name == _starred);
    if (i > 0) list.insert(0, list.removeAt(i));
    return list;
  }

  /// The account the app opens on: starred if set (and still present),
  /// otherwise the first. Null only when there are no accounts at all.
  AccountBalance? get defaultAccount => _accounts.isEmpty
      ? null
      : _accounts.firstWhere(
          (a) => a.name == _starred,
          orElse: () => _accounts.first,
        );

  List<Transaction>? _txns;
  Map<String, String> _balanceIds = const {};
  DateTime updated = DateTime.now();
  bool refreshing = false;
  String? error;

  Future<void> load() async {
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
  final ThemeController theme;

  const _AccountDetailPage({
    required this.data,
    required this.account,
    required this.theme,
  });

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
            // Settings must be reachable here: with one account (or after the
            // launch auto-open) this page is what the user lands on.
            actions: [
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => showDialog(
                  context: context,
                  builder: (dialogContext) => _SettingsDialog(
                    theme: widget.theme,
                    accounts: widget.data.accounts,
                    onSignedOut: () {
                      Navigator.of(dialogContext).pop();
                      widget.data.onSignedOut();
                    },
                  ),
                ),
              ),
            ],
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
    final weekStart = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
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
      return [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: CircularProgressIndicator()),
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
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              final row = rows[i];
              if (row is String) return _DateHeader(label: row);
              return _TxnTile(t: row as Transaction);
            },
            childCount: rows.length,
          ),
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

// ─────────────────────────────── hero card ─────────────────────────────────

/// The balance hero. In the all-accounts menu it's tappable (chevron +
/// transaction count as the affordance) with the star toggle as [trailing];
/// on the detail page it's static and [trailing] is the "Updated …" pill.
class _HeroCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onContainer = scheme.onPrimaryContainer;
    return Material(
      color: scheme.primaryContainer,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        onTap: onTap,
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
                    child: Text(
                      account.amount,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
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
    );
  }
}

/// The star toggle in a menu hero's top-right. Filled = this account leads
/// the menu and is the launch default.
class _StarButton extends StatelessWidget {
  final bool starred;
  final VoidCallback onTap;

  const _StarButton({required this.starred, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final onContainer = Theme.of(context).colorScheme.onPrimaryContainer;
    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Icon(
          starred ? Icons.star_rounded : Icons.star_outline_rounded,
          size: 24,
          color: starred ? onContainer : onContainer.withValues(alpha: 0.55),
        ),
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
    final base = onSurface ? scheme.onSurfaceVariant : scheme.onPrimaryContainer;
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
            Text("Updated ${_relative(updated)}",
                style: TextStyle(fontSize: 11, color: fg)),
          ],
        ],
      ),
    );
  }
}

// ───────────────────────────── formatting ──────────────────────────────────

String _money(double v) => "\$${v.toStringAsFixed(2)}";

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
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
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
                      fontWeight: FontWeight.w600, fontSize: 15),
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

// ────────────────────────────── settings dialog ────────────────────────────

class _SettingsDialog extends StatefulWidget {
  final ThemeController theme;
  final List<AccountBalance> accounts;
  final VoidCallback onSignedOut;

  const _SettingsDialog({
    required this.theme,
    required this.accounts,
    required this.onSignedOut,
  });

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  String? _widgetAccount;

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
      // Default to the first account when nothing is saved (or the saved one
      // no longer exists), matching what the scraper actually pushes.
      _widgetAccount = widget.accounts.any((a) => a.name == saved)
          ? saved
          : (widget.accounts.isEmpty ? null : widget.accounts.first.name);
    });
  }

  Future<void> _selectWidgetAccount(String name) async {
    setState(() => _widgetAccount = name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kWidgetAccountKey, name);
    // Re-push immediately so the home-screen widget switches without waiting
    // for the next scrape.
    await Scraper().pushSelectedBalanceToWidget(widget.accounts);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text("Settings",
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        )),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text("Theme",
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                )),
            const SizedBox(height: 16),
            ListenableBuilder(
              listenable: widget.theme,
              builder: (context, _) => Wrap(
                alignment: WrapAlignment.center,
                spacing: 16,
                runSpacing: 16,
                children: AppTheme.values
                    .map((t) => _ThemeSwatch(
                          option: t,
                          selected: widget.theme.theme == t,
                          onTap: () => widget.theme.set(t),
                        ))
                    .toList(),
              ),
            ),
            if (widget.accounts.length > 1) ...[
              const SizedBox(height: 24),
              Text("Widget account",
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  )),
              const SizedBox(height: 4),
              RadioGroup<String>(
                groupValue: _widgetAccount,
                onChanged: (v) {
                  if (v != null) _selectWidgetAccount(v);
                },
                child: Column(
                  children: widget.accounts
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
            ],
            const SizedBox(height: 24),
            const Divider(height: 1),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LogViewerPage()),
                  );
                },
                icon: const Icon(Icons.description_outlined),
                label: const Text("View logs"),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onSurfaceVariant,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: () async {
                  await clearSession();
                  widget.onSignedOut();
                },
                icon: const Icon(Icons.logout),
                label: const Text("Sign out"),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.primary,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ),
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
