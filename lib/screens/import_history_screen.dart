import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../db/db_helper.dart';
import '../services/app_dates.dart';
import '../services/history_import.dart';

/// Brings past workouts in, either from a backup this app exported or from a
/// spreadsheet of older training logged elsewhere.
class ImportHistoryScreen extends StatefulWidget {
  const ImportHistoryScreen({super.key});

  @override
  State<ImportHistoryScreen> createState() => _ImportHistoryScreenState();
}

class _ImportHistoryScreenState extends State<ImportHistoryScreen> {
  final _pasteCtrl = TextEditingController();

  ParsedHistory? _parsed;
  String? _error;
  String? _fileName;
  bool _busy = false;
  bool _showPaste = false;

  @override
  void dispose() {
    _pasteCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await FilePicker.pickFile();
      if (file == null) {
        if (mounted) setState(() => _busy = false);
        return; // cancelled
      }
      final bytes = await file.readAsBytes();
      // allowMalformed keeps a stray byte from a spreadsheet export from
      // taking down the whole import.
      final text = utf8.decode(bytes, allowMalformed: true);
      _parse(text, fileName: file.name);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not read that file: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _parse(String text, {String? fileName}) {
    setState(() {
      _error = null;
      _parsed = null;
      _fileName = fileName;
    });
    try {
      final parsed = parseHistory(text);
      setState(() => _parsed = parsed);
    } on HistoryImportException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not read that data: $e');
    }
  }

  Future<void> _import() async {
    final parsed = _parsed;
    if (parsed == null) return;
    setState(() => _busy = true);

    final result = await DBHelper.instance.importHistory(parsed.sessions);
    if (!mounted) return;
    await context.read<AppState>().onDataImported();
    if (!mounted) return;
    setState(() => _busy = false);

    final plural = result.sessionsImported == 1 ? '' : 's';
    final lines = <String>[
      '${result.sessionsImported} workout$plural and ${result.setsImported} sets added.',
    ];
    if (result.skipped.isNotEmpty) {
      lines.add('${result.skipped.length} were already on record and were '
          'left untouched.');
    }

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import finished'),
        content: Text(lines.join('\n\n')),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$what copied'), duration: const Duration(seconds: 1)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final parsed = _parsed;

    return Scaffold(
      appBar: AppBar(title: const Text('Import history')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text('Two things can be imported here:', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          _Bullet(
            icon: Icons.settings_backup_restore,
            title: 'A backup from this app',
            body: 'The JSON file from Settings → Export history, on this phone or an old one.',
          ),
          _Bullet(
            icon: Icons.table_chart_outlined,
            title: 'A CSV of older workouts',
            body: 'Training you logged in a spreadsheet or another app before this one.',
          ),

          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _pickFile,
            icon: const Icon(Icons.folder_open),
            label: const Text('Choose a file'),
          ),
          const SizedBox(height: 6),
          Center(
            child: TextButton(
              onPressed: () => setState(() => _showPaste = !_showPaste),
              child: Text(_showPaste ? 'Hide paste box' : 'or paste the text instead'),
            ),
          ),
          if (_showPaste) ...[
            TextField(
              controller: _pasteCtrl,
              maxLines: 8,
              minLines: 4,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                hintText: 'Paste CSV or backup JSON here…',
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : () => _parse(_pasteCtrl.text),
              icon: const Icon(Icons.visibility_outlined),
              label: const Text('Preview'),
            ),
          ],

          if (_error != null) ...[
            const SizedBox(height: 16),
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

          if (parsed != null) ...[
            const SizedBox(height: 20),
            _PreviewCard(parsed: parsed, fileName: _fileName),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _import,
              icon: _busy
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download_done),
              label: Text('Import ${parsed.sessions.length} '
                  'workout${parsed.sessions.length == 1 ? '' : 's'}'),
            ),
            const SizedBox(height: 6),
            Text(
              'Nothing already on record is touched, and importing the same file '
              'twice adds nothing the second time.',
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],

          const SizedBox(height: 28),
          Text('CSV format', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            'One row per set. Column order doesn\'t matter and extra columns are '
            'ignored — only "date" and "exercise" are required. Dates are read as '
            'YYYY-MM-DD, or day-first for 03/08/2026. Check the date range in the '
            'preview before importing.',
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          _CopyBlock(
            title: 'CSV template',
            content: kHistoryCsvTemplate,
            onCopy: () => _copy(kHistoryCsvTemplate, 'Template'),
          ),
          const SizedBox(height: 8),
          _CopyBlock(
            title: 'LLM prompt',
            subtitle: 'Paste this plus your old log into any LLM',
            content: historyCsvPrompt(),
            onCopy: () => _copy(historyCsvPrompt(), 'Prompt'),
          ),
        ],
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  final ParsedHistory parsed;
  final String? fileName;

  const _PreviewCard({required this.parsed, required this.fileName});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final first = parsed.firstDate;
    final last = parsed.lastDate;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withAlpha(120)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fact_check_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  fileName ?? 'Read from ${parsed.sourceLabel}',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Stat(label: 'Workouts', value: '${parsed.sessions.length}'),
          _Stat(label: 'Sets', value: '${parsed.totalSets}'),
          _Stat(label: 'Exercises', value: '${parsed.exerciseNames.length}'),
          if (first != null && last != null)
            _Stat(
              label: 'Date range',
              value: first == last
                  ? shortDateWithWeekday(first)
                  : '${shortDate(first)} → ${shortDate(last)}',
              emphasise: true,
            ),
          if (parsed.warnings.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '${parsed.warnings.length} row${parsed.warnings.length == 1 ? '' : 's'} skipped',
              style: theme.textTheme.labelMedium?.copyWith(color: scheme.error),
            ),
            const SizedBox(height: 4),
            ...parsed.warnings.take(5).map((w) => Text(
                  '• $w',
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                )),
            if (parsed.warnings.length > 5)
              Text('• …and ${parsed.warnings.length - 5} more',
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasise;

  const _Stat({required this.label, required this.value, this.emphasise = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(label,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: emphasise ? scheme.primary : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _Bullet({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
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
                Text(body,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyBlock extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String content;
  final VoidCallback onCopy;

  const _CopyBlock({
    required this.title,
    this.subtitle,
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
          title: Text(title, style: theme.textTheme.titleSmall),
          subtitle: subtitle == null ? null : Text(subtitle!, style: theme.textTheme.labelSmall),
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
