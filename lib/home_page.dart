import 'package:flutter/material.dart';

import 'package:watbal/auth.dart';
import 'package:watbal/main.dart';
import 'package:watbal/scraper.dart';

/// The single screen the user lives in. Top: balance hero card. Below:
/// recent transactions list. Whole thing pulls to refresh, refreshing both
/// at once. No tabs, no page swiping — everything important is one glance
/// away.
class HomePage extends StatefulWidget {
  final String balance;
  final ThemeController theme;
  final ValueChanged<String> onBalanceChanged;
  final VoidCallback onSignedOut;

  const HomePage({
    super.key,
    required this.balance,
    required this.theme,
    required this.onBalanceChanged,
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

  @override
  void initState() {
    super.initState();
    _loadTransactions();
  }

  Future<void> _loadTransactions() async {
    final cookies = await loadSession();
    if (cookies == null) {
      widget.onSignedOut();
      return;
    }
    try {
      final now = DateTime.now();
      final txns = await _scraper.fetchTransactions(
        cookies,
        // 5-year window so we always have plenty of recent activity; we cap
        // the display to ~8 rows.
        from: DateTime(now.year - 5, now.month, now.day),
        to: now,
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
      final balance = await _scraper.fetchBalance(cookies);
      final now = DateTime.now();
      final txns = await _scraper.fetchTransactions(
        cookies,
        from: DateTime(now.year - 5, now.month, now.day),
        to: now,
      );
      if (!mounted) return;
      setState(() {
        _txns = txns;
        _updated = DateTime.now();
        _error = null;
        _refreshing = false;
      });
      widget.onBalanceChanged(balance);
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

  @override
  Widget build(BuildContext context) {
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
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _BalanceCard(
              balance: widget.balance,
              updatedAt: _updated,
              refreshing: _refreshing,
            ),
            const SizedBox(height: 24),
            Text(
              "Recent activity",
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            if (_error != null)
              _hint(context, _error!)
            else if (_txns == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_txns!.isEmpty)
              _hint(context, "No recent transactions.")
            else
              ..._txns!.take(8).map((t) => _TxnTile(t: t)),
          ],
        ),
      ),
    );
  }

  Widget _hint(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Text(
            text,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );

  void _showSettings(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => _SettingsDialog(
        theme: widget.theme,
        onSignedOut: () {
          Navigator.of(context).pop();
          widget.onSignedOut();
        },
      ),
    );
  }
}

// ────────────────────────────── balance card ───────────────────────────────

class _BalanceCard extends StatelessWidget {
  final String balance;
  final DateTime updatedAt;
  final bool refreshing;

  const _BalanceCard({
    required this.balance,
    required this.updatedAt,
    required this.refreshing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "FLEXIBLE",
            style: TextStyle(
              color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            balance,
            style: TextStyle(
              fontSize: 48,
              fontWeight: FontWeight.w800,
              color: scheme.onPrimaryContainer,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (refreshing) ...[
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  "Refreshing…",
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                  ),
                ),
              ] else
                Text(
                  "Updated ${_relative(updatedAt)}",
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// "just now", "5m ago", "2h ago", etc. — keeps the card from feeling
  /// stale at a glance.
  String _relative(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 30) return "just now";
    if (diff.inMinutes < 1) return "${diff.inSeconds}s ago";
    if (diff.inHours < 1) return "${diff.inMinutes}m ago";
    if (diff.inDays < 1) return "${diff.inHours}h ago";
    return "${diff.inDays}d ago";
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor:
                (debit ? Colors.red : Colors.green).withValues(alpha: 0.12),
            child: Icon(
              debit ? Icons.arrow_downward : Icons.arrow_upward,
              color: debit ? Colors.red : Colors.green,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  t.dateTime,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Text(
            t.amount,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 15,
              color: debit ? Colors.red : Colors.green,
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────── settings dialog ────────────────────────────

class _SettingsDialog extends StatelessWidget {
  final ThemeController theme;
  final VoidCallback onSignedOut;

  const _SettingsDialog({required this.theme, required this.onSignedOut});

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
              listenable: theme,
              builder: (context, _) => Wrap(
                alignment: WrapAlignment.center,
                spacing: 16,
                runSpacing: 16,
                children: AppTheme.values
                    .map((t) => _ThemeSwatch(
                          option: t,
                          selected: theme.theme == t,
                          onTap: () => theme.set(t),
                        ))
                    .toList(),
              ),
            ),
            const SizedBox(height: 24),
            const Divider(height: 1),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: () async {
                  await clearSession();
                  onSignedOut();
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
