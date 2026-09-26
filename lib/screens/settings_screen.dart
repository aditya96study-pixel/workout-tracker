import 'dart:io';

import 'package:cross_file/cross_file.dart';
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
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withAlpha(120)),
      ),
      child: child,
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
