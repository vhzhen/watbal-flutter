import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Tiny append-only file logger.
///
/// The home-screen widget is refreshed from a background isolate (the
/// WorkManager task), whose `print`/`debugPrint` output you can't see unless
/// `flutter run` happens to be attached. This writes timestamped lines to a
/// file in the app documents dir instead, so the in-app [LogViewerPage] — and
/// `adb` — can read back what the background refresh actually did.
///
/// Everything here is best-effort: logging must never throw into app logic.
class DebugLog {
  static const _fileName = 'watbal_debug.log';

  /// Cap so the file can't grow without bound; when exceeded we keep the most
  /// recent half.
  static const _maxBytes = 256 * 1024;

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Appends one timestamped line. Mirrors to `debugPrint` so it still shows in
  /// `flutter run` / logcat (`I/flutter`) when attached.
  static Future<void> log(String message) async {
    final line = '${DateTime.now().toIso8601String()}  $message';
    debugPrint('[watbal] $line');
    try {
      final file = await _file();
      await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
      if (await file.length() > _maxBytes) {
        final content = await file.readAsString();
        await file.writeAsString(content.substring(content.length ~/ 2));
      }
    } catch (_) {
      // No writable dir / disk issue — drop the line rather than crash.
    }
  }

  /// Full log contents, newest at the bottom. Empty string when nothing logged.
  static Future<String> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return '';
      return await file.readAsString();
    } catch (e) {
      return 'Could not read log: $e';
    }
  }

  static Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.writeAsString('');
    } catch (_) {}
  }

  /// On-device path, surfaced in the viewer so you can `adb pull` it.
  static Future<String> path() async {
    try {
      return (await _file()).path;
    } catch (e) {
      return 'unavailable: $e';
    }
  }
}
