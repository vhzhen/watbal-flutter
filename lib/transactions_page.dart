import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watbal/app_theme.dart';
import 'package:watbal/scraper_service.dart';
import 'package:watbal/settings_sheet.dart';
import 'package:watbal/transaction.dart';

class TransactionsPage extends StatefulWidget {
  final VoidCallback onSessionLost;

  const TransactionsPage({super.key, required this.onSessionLost});

  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<TransactionsPage> {
  final ScraperService _scraper = ScraperService();

  /// Keys for persisting the user's last-selected date range across launches.
  /// We store the *preset* when one is active (e.g. "30", "90", "365") so a
  /// rolling window like "30 days" stays rolling next launch; otherwise we
  /// store an explicit start/end pair for custom ranges.
  static const _kPresetKey = 'txn_range_preset_days';
  static const _kStartKey = 'txn_range_start_ms';
  static const _kEndKey = 'txn_range_end_ms';

  late DateTimeRange _range = DateTimeRange(
    start: DateTime.now().subtract(const Duration(days: 90)),
    end: DateTime.now(),
  );

  List<Transaction> _txns = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restoreRangeAndLoad();
  }

  /// Reads the saved preset/custom range from prefs (if any) and kicks off
  /// the initial load. Falls back to the 90-day default if nothing's stored.
  Future<void> _restoreRangeAndLoad() async {
    final prefs = await SharedPreferences.getInstance();
    final preset = prefs.getInt(_kPresetKey);
    if (preset != null) {
      // Recompute rolling window from "now" so "30 days" stays rolling.
      _range = DateTimeRange(
        start: DateTime.now().subtract(Duration(days: preset)),
        end: DateTime.now(),
      );
    } else {
      final startMs = prefs.getInt(_kStartKey);
      final endMs = prefs.getInt(_kEndKey);
      if (startMs != null && endMs != null) {
        _range = DateTimeRange(
          start: DateTime.fromMillisecondsSinceEpoch(startMs),
          end: DateTime.fromMillisecondsSinceEpoch(endMs),
        );
      }
    }
    if (mounted) _load();
  }

  Future<void> _savePreset(int days) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPresetKey, days);
    await prefs.remove(_kStartKey);
    await prefs.remove(_kEndKey);
  }

  Future<void> _saveCustom(DateTimeRange range) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPresetKey);
    await prefs.setInt(_kStartKey, range.start.millisecondsSinceEpoch);
    await prefs.setInt(_kEndKey, range.end.millisecondsSinceEpoch);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final prefs = await SharedPreferences.getInstance();
    final cookies = prefs.getString("session_cookies");
    if (cookies == null) {
      widget.onSessionLost();
      return;
    }

    try {
      final txns = await _scraper.fetchTransactions(
        cookies,
        _range.start,
        _range.end,
      );
      if (mounted) {
        setState(() {
          _txns = txns;
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      if (e.toString().contains("Expired")) {
        widget.onSessionLost();
      } else {
        setState(() {
          _error = "Couldn't load transactions. Pull to retry.";
          _loading = false;
        });
      }
    }
  }

  void _applyPreset(int days) {
    setState(() {
      _range = DateTimeRange(
        start: DateTime.now().subtract(Duration(days: days)),
        end: DateTime.now(),
      );
    });
    _savePreset(days);
    _load();
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _range,
      firstDate: DateTime(2015),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _range = picked);
      await _saveCustom(picked);
      _load();
    }
  }

  String _shortDate(DateTime d) =>
      "${d.month}/${d.day}/${d.year % 100}";

  bool _presetActive(int days) {
    final now = DateTime.now();
    return _range.end.difference(now).inDays.abs() < 1 &&
        _range.start.difference(now.subtract(Duration(days: days))).inDays.abs() <
            1;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Transactions",
            style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => showSettingsDialog(
              context,
              controller: ThemeScope.read(context),
              onSignOut: widget.onSessionLost,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _rangeBar(),
          const Divider(height: 1),
          Expanded(child: _list()),
        ],
      ),
    );
  }

  Widget _rangeBar() {
    final scheme = Theme.of(context).colorScheme;
    Widget chip(String text, bool active, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: Text(text),
            selected: active,
            onSelected: (_) => onTap(),
            selectedColor: scheme.primary,
            labelStyle: TextStyle(
              color: active ? scheme.onPrimary : scheme.onSurface,
              fontWeight: FontWeight.w500,
            ),
            backgroundColor: scheme.surfaceContainerHighest,
            side: BorderSide.none,
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: _pickRange,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.calendar_today,
                      size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    "${_shortDate(_range.start)}  –  ${_shortDate(_range.end)}",
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.keyboard_arrow_down,
                      size: 18, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                chip("30 days", _presetActive(30), () => _applyPreset(30)),
                chip("90 days", _presetActive(90), () => _applyPreset(90)),
                chip("1 year", _presetActive(365), () => _applyPreset(365)),
                chip("Custom", false, _pickRange),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _list() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final muted = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontSize: 16,
    );

    return RefreshIndicator(
      onRefresh: _load,
      child: (_error != null)
          ? ListView(
              children: [
                const SizedBox(height: 120),
                Center(child: Text(_error!, style: muted)),
              ],
            )
          : _txns.isEmpty
              ? ListView(
                  children: [
                    const SizedBox(height: 120),
                    Center(
                      child: Text("No transactions in this range",
                          style: muted),
                    ),
                  ],
                )
              : ListView.separated(
                  itemCount: _txns.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1),
                  itemBuilder: (context, i) => _tile(_txns[i]),
                ),
    );
  }

  Widget _tile(Transaction t) {
    final debit = t.isDebit;
    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        backgroundColor:
            (debit ? Colors.red : Colors.green).withValues(alpha: 0.12),
        child: Icon(
          debit ? Icons.arrow_downward : Icons.arrow_upward,
          color: debit ? Colors.red : Colors.green,
          size: 20,
        ),
      ),
      title: Text(
        t.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        "${t.dateTime}\n${t.terminalLabel}",
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      isThreeLine: true,
      trailing: Text(
        t.amount,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 15,
          color: debit ? Colors.red : Colors.green,
        ),
      ),
    );
  }
}
