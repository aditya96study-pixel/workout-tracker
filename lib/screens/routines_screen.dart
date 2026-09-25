import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../db/db_helper.dart';
import '../models/routine.dart';
import 'import_screen.dart';
import 'routine_editor_screen.dart';

class RoutinesScreen extends StatefulWidget {
  const RoutinesScreen({super.key});

  @override
  State<RoutinesScreen> createState() => _RoutinesScreenState();
}

class _RoutinesScreenState extends State<RoutinesScreen> {
  List<Routine> _routines = [];
  Map<int, int> _exerciseCounts = {};
  bool _loading = true;
  int _revisionSeen = -1;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    if (_revisionSeen != appState.revision) {
      _revisionSeen = appState.revision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Routines'),
        actions: [
          IconButton(
            tooltip: 'Rapid import',
            icon: const Icon(Icons.bolt_outlined),
            onPressed: _openImport,
          ),
          IconButton(
            tooltip: 'New routine',
            icon: const Icon(Icons.add),
            onPressed: _createRoutine,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _routines.isEmpty
              ? _EmptyRoutines(onCreate: _createRoutine, onImport: _openImport)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  itemCount: _routines.length,
                  itemBuilder: (context, i) =>
                      _routineCard(context, _routines[i], appState),
                ),
    );
  }

  Widget _routineCard(BuildContext context, Routine r, AppState appState) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isActive = appState.activeRoutine?.id == r.id;
    final count = _exerciseCounts[r.id] ?? 0;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      color: isActive ? scheme.primaryContainer.withAlpha(90) : scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isActive ? scheme.primary.withAlpha(120) : scheme.outlineVariant.withAlpha(120),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: isActive ? null : () => _setActive(r),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            children: [
              Icon(
                isActive ? Icons.check_circle : Icons.radio_button_unchecked,
                color: isActive ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.name,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      isActive
                          ? 'Active · $count exercises'
                          : 'Tap to make active · $count exercises',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (value) => _onMenu(value, r),
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit days & exercises')),
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final routines = await DBHelper.instance.getRoutines();
    final counts = <int, int>{};
    for (final r in routines) {
      if (r.id == null) continue;
      var total = 0;
      for (final d in await DBHelper.instance.getDays(r.id!)) {
        total += await DBHelper.instance.countExercises(d.id!);
      }
      counts[r.id!] = total;
    }
    if (!mounted) return;
    setState(() {
      _routines = routines;
      _exerciseCounts = counts;
      _loading = false;
    });
  }

  Future<void> _openImport() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ImportScreen()));
    if (!mounted) return;
    await context.read<AppState>().onRoutineEdited();
    await _load();
  }

  Future<void> _createRoutine() async {
    final name = await _promptText(context,
        title: 'New routine', hint: 'e.g. Push Pull Legs', initial: '');
    if (name == null || name.trim().isEmpty || !mounted) return;
    final id = await DBHelper.instance.createRoutine(name.trim());

    // A first routine is almost certainly the one you want to run.
    if (!mounted) return;
    final appState = context.read<AppState>();
    if (appState.activeRoutine == null) {
      await appState.setActiveRoutine(id);
    }
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    await _openEditor(id);
  }

  Future<void> _openEditor(int routineId) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => RoutineEditorScreen(routineId: routineId)));
    if (!mounted) return;
    await context.read<AppState>().onRoutineEdited();
    await _load();
  }

  Future<void> _onMenu(String value, Routine r) async {
    switch (value) {
      case 'edit':
        await _openEditor(r.id!);
        break;
      case 'rename':
        final name = await _promptText(context,
            title: 'Rename routine', hint: 'Routine name', initial: r.name);
        if (name == null || name.trim().isEmpty || !mounted) return;
        await DBHelper.instance.renameRoutine(r.id!, name.trim());
        if (!mounted) return;
        await context.read<AppState>().onRoutineEdited();
        await _load();
        break;
      case 'delete':
        await _deleteRoutine(r);
        break;
    }
  }

  Future<void> _deleteRoutine(Routine r) async {
    // Deleting the routine a running workout belongs to would null out that
    // session's day and leave it unreachable, so it's blocked outright.
    if (context.read<AppState>().hasWorkoutInProgress) {
      _snack('Finish the workout in progress before deleting a routine.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete routine?'),
        content: Text('"${r.name}" and its days and exercises will be deleted. '
            'Workouts you already logged stay in History.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await DBHelper.instance.deleteRoutine(r.id!);
    if (!mounted) return;
    await context.read<AppState>().onRoutineEdited();
    await _load();
  }

  Future<void> _setActive(Routine r) async {
    final switched = await context.read<AppState>().setActiveRoutine(r.id!);
    if (!mounted) return;
    if (!switched) {
      _snack('Finish the workout in progress before switching routines.');
      return;
    }
    await _load();
    if (!mounted) return;
    _snack('"${r.name}" is now active.');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
  }
}

Future<String?> _promptText(BuildContext context,
    {required String title, required String hint, required String initial}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save')),
      ],
    ),
  );
}

class _EmptyRoutines extends StatelessWidget {
  final VoidCallback onCreate;
  final VoidCallback onImport;

  const _EmptyRoutines({required this.onCreate, required this.onImport});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.list_alt, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('No routines yet', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Build one day by day, or paste a whole week in at once.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('New routine'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.bolt_outlined),
              label: const Text('Rapid import'),
            ),
          ],
        ),
      ),
    );
  }
}
