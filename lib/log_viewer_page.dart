import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:watbal/debug_log.dart';

/// Read-only view of the [DebugLog] file. Reachable from Settings → "View
/// logs". Lets you watch what the background widget-refresh actually did
/// (balance fetched, errors, widget pushes) without `flutter run` attached.
class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  String _contents = "";
  String _path = "";
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final contents = await DebugLog.read();
    final path = await DebugLog.path();
    if (!mounted) return;
    setState(() {
      _contents = contents;
      _path = path;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final empty = _contents.trim().isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text("Logs"),
        actions: [
          IconButton(
            tooltip: "Reload",
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
          IconButton(
            tooltip: "Copy",
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: empty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: _contents));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Log copied")),
                      );
                    }
                  },
          ),
          IconButton(
            tooltip: "Clear",
            icon: const Icon(Icons.delete_outline),
            onPressed: empty
                ? null
                : () async {
                    await DebugLog.clear();
                    await _reload();
                  },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: SelectableText(
                    _path,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: empty
                      ? Center(
                          child: Text(
                            "No logs yet.",
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        )
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText(
                            _contents,
                            style: const TextStyle(
                              fontFamily: "monospace",
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}
