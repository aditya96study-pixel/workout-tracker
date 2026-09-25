import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../db/db_helper.dart';
import '../models/routine.dart';
import '../services/import_export.dart';

/// Rapid import: paste a filled-in JSON (or CSV) template — for example one
/// you asked an LLM to fill out from your plain-text plan — and create a full
/// 7-day routine in one go.
///
/// Import always creates a *new* routine, never overwrites an existing one,
/// and shows a preview before anything is saved.
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final _textCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  ParsedImport? _parsed;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _textCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _preview() {
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      _parsed = null;
    });
    try {
      final parsed = parseImportText(_textCtrl.text);
      setState(() {
        _parsed = parsed;
        if (_nameCtrl.text.trim().isEmpty && parsed.routineName != null) {
          _nameCtrl.text = parsed.routineName!;
        }
      });
    } on ImportException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not read that text: $e');
    }
  }

  Future<void> _save() async {
    final parsed = _parsed;
    if (parsed == null) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the routine a name first.');
      return;
    }

    setState(() => _saving = true);
    final id = await DBHelper.instance.importRoutine(name, parsed.days);
    if (!mounted) return;

    final total = parsed.days.fold<int>(0, (s, d) => s + d.exercises.length);
    final setActive = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Routine imported'),
        content: Text('"$name" created with $total exercises across 7 days. '
            'Make it your active routine now?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Set active')),
        ],
      ),
    );
    if (setActive == true && mounted) {
      // Routed through AppState rather than the DB directly, so the
      // "don't switch routines mid-workout" guard actually applies here too.
      final switched = await context.read<AppState>().setActiveRoutine(id);
      if (!mounted) return;
      if (!switched) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(
            content: Text(
                'Routine saved, but not activated — finish the workout in progress first.'),
          ));
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('$what copied'),
        duration: const Duration(seconds: 1),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Rapid import')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            'Paste a filled-in template to build a whole week at once.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'The usual flow: copy the prompt below, paste it into any LLM along with '
            'your workout notes, then paste what it gives back into the box at the '
            'bottom of this screen.',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),

          _CopyCard(
            title: 'Ready-made LLM prompt',
            subtitle: 'Copy this, then paste your plan under it',
            icon: Icons.auto_awesome_outlined,
            content: llmPrompt(),
            onCopy: () => _copy(llmPrompt(), 'Prompt'),
          ),
          const SizedBox(height: 8),
          _CopyCard(
            title: 'JSON template',
            subtitle: 'Recommended format',
            icon: Icons.data_object,
            content: kImportJsonTemplate,
            onCopy: () => _copy(kImportJsonTemplate, 'JSON template'),
          ),
          const SizedBox(height: 8),
          _CopyCard(
            title: 'CSV template',
            subtitle: 'One row per exercise',
            icon: Icons.table_rows_outlined,
            content: kImportCsvTemplate,
            onCopy: () => _copy(kImportCsvTemplate, 'CSV template'),
          ),

          const SizedBox(height: 24),
          Text('Paste your filled-in template',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _textCtrl,
            maxLines: 10,
            minLines: 6,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: InputDecoration(
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              hintText: 'Paste JSON or CSV here…',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: _preview,
            icon: const Icon(Icons.visibility_outlined),
            label: const Text('Preview'),
          ),

          if (_error != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_error!, style: TextStyle(color: scheme.onErrorContainer)),
                  ),
                ],
              ),
            ),
          ],

          if (_parsed != null) ...[
            const SizedBox(height: 20),
            Text('Preview',
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtrl,
              decoration: InputDecoration(
                labelText: 'Routine name',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),
            ..._parsed!.days.map((d) => Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 6),
                  color: scheme.surfaceContainerLowest,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: scheme.outlineVariant.withAlpha(120)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Day ${d.day.dayIndex} · ${d.day.dayName}',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(
                          d.exercises.isEmpty
                              ? 'Rest day'
                              : d.exercises
                                  .map((e) =>
                                      '${e.name} · ${e.type.label} · ${e.targetSets} sets')
                                  .join('\n'),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                )),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save as new routine'),
            ),
          ],
        ],
      ),
    );
  }
}

class _CopyCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final String content;
  final VoidCallback onCopy;

  const _CopyCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.content,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withAlpha(120)),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(icon, size: 20, color: scheme.primary),
          title: Text(title, style: theme.textTheme.titleSmall),
          subtitle: Text(subtitle, style: theme.textTheme.labelSmall),
          trailing: IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy, size: 20),
            onPressed: onCopy,
          ),
          children: [
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                content,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
