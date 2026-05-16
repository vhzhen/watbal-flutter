import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _prefsKey = 'app_theme';

enum AppThemeOption { light, dark, green, orange }

extension AppThemeOptionX on AppThemeOption {
  String get label => switch (this) {
        AppThemeOption.light => 'Light',
        AppThemeOption.dark => 'Dark',
        AppThemeOption.green => 'Green',
        AppThemeOption.orange => 'Orange',
      };

  /// Colour shown in the settings picker swatch.
  Color get swatch => switch (this) {
        AppThemeOption.light => Colors.white,
        AppThemeOption.dark => const Color(0xFF1C1C1E),
        AppThemeOption.green => const Color(0xFF2E7D32),
        AppThemeOption.orange => const Color(0xFFEF6C00),
      };

  ThemeData get themeData => switch (this) {
        AppThemeOption.light => _make(Colors.blue, Brightness.light),
        AppThemeOption.dark => _make(Colors.blue, Brightness.dark),
        AppThemeOption.green => _make(Colors.green, Brightness.light),
        AppThemeOption.orange => _make(Colors.deepOrange, Brightness.light),
      };
}

ThemeData _make(Color seed, Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      centerTitle: true,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
      ),
    ),
  );
}

/// Holds the active theme and persists it across launches.
class ThemeController extends ChangeNotifier {
  AppThemeOption _option = AppThemeOption.light;
  AppThemeOption get option => _option;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_prefsKey);
    _option = AppThemeOption.values.firstWhere(
      (o) => o.name == name,
      orElse: () => AppThemeOption.light,
    );
    notifyListeners();
  }

  Future<void> set(AppThemeOption option) async {
    if (option == _option) return;
    _option = option;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, option.name);
  }
}

/// Makes the [ThemeController] available to the whole widget tree.
class ThemeScope extends InheritedNotifier<ThemeController> {
  const ThemeScope({
    super.key,
    required ThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static ThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    assert(scope != null, 'ThemeScope not found in context');
    return scope!.notifier!;
  }

  /// Reads the controller without subscribing — safe to call from a tap
  /// handler and to pass across route boundaries (e.g. into a dialog).
  static ThemeController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<ThemeScope>();
    assert(scope != null, 'ThemeScope not found in context');
    return scope!.notifier!;
  }
}
