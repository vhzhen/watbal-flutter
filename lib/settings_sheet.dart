import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watbal/app_theme.dart';

/// Centered settings dialog (covers the middle of the screen, not a page).
///
/// [controller] is passed in rather than looked up from context: the dialog
/// lives in the navigator overlay where the ThemeScope InheritedWidget isn't
/// reliably resolvable.
Future<void> showSettingsDialog(
  BuildContext context, {
  required ThemeController controller,
  required VoidCallback onSignOut,
}) {
  return showDialog(
    context: context,
    builder: (_) =>
        _SettingsDialog(controller: controller, onSignOut: onSignOut),
  );
}

class _SettingsDialog extends StatelessWidget {
  final ThemeController controller;
  final VoidCallback onSignOut;

  const _SettingsDialog({required this.controller, required this.onSignOut});

  Future<void> _signOut(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('session_cookies');
    // Clearing the WebView's cookie store is required: otherwise the
    // persisted .ASPXAUTH would let the login popup auto-close and log the
    // user straight back in.
    await CookieManager.instance().deleteAllCookies();
    if (context.mounted) Navigator.of(context).pop();
    onSignOut();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  "Settings",
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              "Theme",
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            // Rebuilds on theme change so the checkmark follows the choice.
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) => SizedBox(
                width: double.infinity,
                child: Wrap(
                  alignment: WrapAlignment.center,
                  runAlignment: WrapAlignment.center,
                  spacing: 16,
                  runSpacing: 16,
                  children: AppThemeOption.values
                      .map((o) => _ThemeChoice(
                            option: o,
                            selected: controller.option == o,
                            onTap: () => controller.set(o),
                          ))
                      .toList(),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Divider(height: 1),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: () => _signOut(context),
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

class _ThemeChoice extends StatelessWidget {
  final AppThemeOption option;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeChoice({
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
                      color: option == AppThemeOption.light
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
