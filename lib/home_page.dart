import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watbal/auth.dart';
import 'package:watbal/log_viewer_page.dart';
import 'package:watbal/main.dart';
import 'package:watbal/scraper.dart';

/// The single screen the user lives in — one vertical scroll, no tabs or paging:
/// a balance hero, a light spending summary, an inline search bar, and the
/// transaction history grouped by date, newest first. Pull-to-refresh refreshes
/// balance and history together.
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
  final Scraper _scraper = Scraper();
  List<Transaction>? _txns;
  DateTime _updated = DateTime.now();
  bool _refreshing = false;
  String? _error;

  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  // 5-year window so we always have plenty of recent activity.
  DateTime get _from {
    final now = DateTime.now();
    return DateTime(now.year - 5, now.month, now.day);
  }

  Future<void> _load() async {
    final cookies = await loadSession();
    if (cookies == null) {
      widget.onSignedOut();
      return;
    }
    try {
      final txns = await _scraper.fetchTransactions(
        cookies,
        from: _from,
        to: DateTime.now(),
      );
      if (mounted) setState(() => _txns = txns);
    } catch (e) {
      if (e.toString().contains("Expired")) {
        widget.onSignedOut();
      } else if (mounted) {
        setState(() => _error = "Couldn't load transactions.");
      }
    }
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    final cookies = await loadSession();
    if (cookies == null) {
      widget.onSignedOut();
      return;
    }
    try {
      final accounts = await _scraper.fetchBalances(cookies);
      final txns = await _scraper.fetchTransactions(
        cookies,
        from: _from,
        to: DateTime.now(),
      );
      if (!mounted) return;
      setState(() {
        _txns = txns;
        _updated = DateTime.now();
        _error = null;
        _refreshing = false;
      });
      widget.onAccountsChanged(accounts);
    } catch (e) {
      if (!mounted) return;
      if (e.toString().contains("Expired")) {
        widget.onSignedOut();
      } else {
        setState(() {
          _error = "Couldn't refresh.";
          _refreshing = false;
        });
      }
    }
  }

  // ──────────────────────────── derived data ─────────────────────────────

  /// Transactions after the search query, newest first.
  List<Transaction> get _filtered {
    final q = _query.trim().toLowerCase();
    final list = (_txns ?? []).where((t) {
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
  List<Object> get _rows {
    final rows = <Object>[];
    String? current;
    for (final t in _filtered) {
      final label = _dayLabel(t.parsedDate);
      if (label != current) {
        rows.add(label);
        current = label;
      }
      rows.add(t);
    }
    return rows;
  }

  /// Total spent (debits only) since [start].
  double _spentSince(DateTime start) {
    var sum = 0.0;
    for (final t in (_txns ?? [])) {
      if (!t.isDebit) continue;
      final d = t.parsedDate;
      if (d == null || d.isBefore(start)) continue;
      sum += -t.amountValue; // debit values are negative
    }
    return sum;
  }

  // ──────────────────────────────── build ────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _heroes(scheme)),
            SliverToBoxAdapter(child: _summary(scheme)),
            SliverToBoxAdapter(child: _searchFilter(scheme)),
            ..._content(scheme),
          ],
        ),
      ),
    );
  }

  /// One hero card per account, stacked. With a single account this is the
  /// familiar full-size hero; with several, each gets its own card and only the
  /// first carries the "Updated …" pill (it applies to all of them).
  Widget _heroes(ColorScheme scheme) {
    final accounts = widget.accounts;
    return Column(
      children: [
        for (var i = 0; i < accounts.length; i++)
          Padding(
            padding: EdgeInsets.fromLTRB(16, i == 0 ? 8 : 12, 16, 0),
            child: _heroCard(scheme, accounts[i], showUpdated: i == 0),
          ),
      ],
    );
  }

  Widget _heroCard(
    ColorScheme scheme,
    AccountBalance account, {
    required bool showUpdated,
  }) {
    final onContainer = scheme.onPrimaryContainer;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(28),
      ),
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
              if (showUpdated) _updatedPill(scheme),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            account.amount,
            style: TextStyle(
              fontSize: 52,
              fontWeight: FontWeight.w800,
              color: onContainer,
              letterSpacing: -1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _updatedPill(ColorScheme scheme) {
    final onContainer = scheme.onPrimaryContainer;
    final fg = onContainer.withValues(alpha: 0.8);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: onContainer.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_refreshing) ...[
            SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 2, color: fg),
            ),
            const SizedBox(width: 6),
            Text("Refreshing…",
                style: TextStyle(fontSize: 11, color: fg)),
          ] else ...[
            Icon(Icons.schedule, size: 12, color: fg),
            const SizedBox(width: 5),
            Text("Updated ${_relative(_updated)}",
                style: TextStyle(fontSize: 11, color: fg)),
          ],
        ],
      ),
    );
  }

  Widget _summary(ColorScheme scheme) {
    final now = DateTime.now();
    final weekStart = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    final monthStart = DateTime(now.year, now.month, 1);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: _StatTile(
              label: "This week",
              value: _money(_spentSince(weekStart)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _StatTile(
              label: "This month",
              value: _money(_spentSince(monthStart)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _StatTile(
              label: "Transactions",
              value: "${(_txns ?? const []).length}",
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

  List<Widget> _content(ColorScheme scheme) {
    if (_error != null) return [_message(scheme, _error!)];
    if (_txns == null) {
      return [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ];
    }
    final rows = _rows;
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

  // ───────────────────────────── formatting ──────────────────────────────

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

  void _showSettings(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => _SettingsDialog(
        theme: widget.theme,
        accounts: widget.accounts,
        onSignedOut: () {
          Navigator.of(context).pop();
          widget.onSignedOut();
        },
      ),
    );
  }
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
              debit ? Icons.south_west : Icons.arrow_outward,
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
