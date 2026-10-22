import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../db/db_helper.dart';
import '../services/import_export.dart';
import 'import_history_screen.dart';
import '../theme/theme_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _exporting = false;

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final data = await DBHelper.instance.exportAllData();
      final json = encodeExport(data);
      final dir = await getApplicationDocumentsDirectory();
      final stamp =
          DateTime.now().toIso8601String().split('.').first.replaceAll(':', '-');
      final file = File('${dir.path}/workout_history_$stamp.json');
      await file.writeAsString(json);
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: 'Workout history export',
          subject: 'Workout history export',
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final themeProvider = context.watch<ThemeProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _SectionLabel('Appearance'),
          _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ThemeMode>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode_outlined, size: 18),
                        label: Text('Light'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode_outlined, size: 18),
                        label: Text('Dark'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: Icon(Icons.brightness_auto_outlined, size: 18),
                        label: Text('Auto'),
                      ),
                    ],
                    selected: {themeProvider.mode},
                    onSelectionChanged: (s) => themeProvider.setMode(s.first),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  themeProvider.mode == ThemeMode.system
                      ? 'Following your phone\'s theme.'
                      : 'Locked to ${themeProvider.mode == ThemeMode.dark ? 'dark' : 'light'} mode.',
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 18),
                Text('Colour theme', style: theme.textTheme.labelLarge),
                const SizedBox(height: 10),
                _PaletteGrid(
                  selected: themeProvider.palette,
                  vivid: themeProvider.vivid,
                  onSelect: themeProvider.setPalette,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _Panel(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.palette_outlined),
                  title: const Text('Vivid colours'),
                  subtitle: Text(themeProvider.palette.monochrome
                      ? 'Graphite is always greyscale'
                      : 'Stronger, more saturated accents'),
                  value: themeProvider.vivid && !themeProvider.palette.monochrome,
                  onChanged: themeProvider.palette.monochrome ? null : themeProvider.setVivid,
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                SwitchListTile(
                  secondary: const Icon(Icons.contrast),
                  title: const Text('Pure black dark mode'),
                  subtitle: const Text('True black backgrounds — easier on OLED screens'),
                  value: themeProvider.pureBlack,
                  onChanged: themeProvider.setPureBlack,
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),
          _SectionLabel('Your data'),
          _Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.ios_share),
                  title: const Text('Export history'),
                  subtitle: const Text(
                      'Saves every completed workout as a JSON file and opens the share sheet'),
                  trailing: _exporting
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.chevron_right),
                  onTap: _exporting ? null : _export,
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('Import history'),
                  subtitle: const Text(
                      'Restore a backup, or bring in older workouts from a CSV'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const ImportHistoryScreen(),
                  )),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),
          _SectionLabel('How it works'),
          _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                _InfoRow(
                  icon: Icons.lock_outline,
                  title: 'Fully offline',
                  body:
                      'Everything lives in a database on this phone. The app has no internet '
                      'permission and no data ever leaves the device.',
                ),
                SizedBox(height: 14),
                _InfoRow(
                  icon: Icons.bedtime_outlined,
                  title: 'Midnight auto-save',
                  body:
                      'A workout left running is saved automatically when the day rolls over, '
                      'dated to the day you actually did it — even if the app was closed.',
                ),
                SizedBox(height: 14),
                _InfoRow(
                  icon: Icons.history,
                  title: 'Smart defaults',
                  body:
                      'Each set opens pre-filled with what you did last time. Greyed numbers '
                      'are carried forward; tick the set to keep them or type over them.',
                ),
                SizedBox(height: 14),
                _InfoRow(
                  icon: Icons.calculate_outlined,
                  title: 'Estimated 1RM',
                  body: 'Charts use the Epley formula: weight × (1 + reps ÷ 30).',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One swatch per colour theme, previewed in the current brightness so what
/// you tap is what you get.
class _PaletteGrid extends StatelessWidget {
  final AppPalette selected;
  final bool vivid;
  final ValueChanged<AppPalette> onSelect;

  const _PaletteGrid({required this.selected, required this.vivid, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    return LayoutBuilder(builder: (context, constraints) {
      // Four to a row on a phone; never so narrow the names get cut off.
      final perRow = (constraints.maxWidth / 72).floor().clamp(3, 8);
      final width = constraints.maxWidth / perRow;
      return Wrap(
        runSpacing: 12,
        children: [
          for (final p in AppPalette.values)
            SizedBox(
              width: width,
              child: _Swatch(
                palette: p,
                scheme: AppTheme.scheme(brightness, p, vivid: vivid),
                selected: p == selected,
                onTap: () => onSelect(p),
              ),
            ),
        ],
      );
    });
  }
}

class _Swatch extends StatelessWidget {
  final AppPalette palette;
  final ColorScheme scheme;
  final bool selected;
  final VoidCallback onTap;

  const _Swatch({
    required this.palette,
    required this.scheme,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: '${palette.label} colour theme',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 44,
                height: 44,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? theme.colorScheme.onSurface : Colors.transparent,
                    width: 2,
                  ),
                ),
                // Half primary, half its container: shows the accent and the
                // softer tone it pairs with.
                child: ClipOval(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: ColoredBox(color: scheme.primary)),
                      Expanded(child: ColoredBox(color: scheme.primaryContainer)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                palette.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  color: selected ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  const _Panel({required this.child, this.padding = const EdgeInsets.all(16)});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A Material rather than a coloured box: list tiles and switches inside
    // draw their tap ripple on the nearest Material, and a coloured box in
    // between hid it — tapping Export gave no visual feedback at all.
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: scheme.surfaceContainerLowest,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant.withAlpha(120)),
        ),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _InfoRow({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(body,
                  style:
                      theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }
}
