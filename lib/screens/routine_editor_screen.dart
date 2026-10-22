import 'package:flutter/material.dart';

import '../db/db_helper.dart';
import '../models/routine.dart';
import '../widgets/exercise_dialog.dart';

class RoutineEditorScreen extends StatefulWidget {
  final int routineId;
  const RoutineEditorScreen({super.key, required this.routineId});

  @override
  State<RoutineEditorScreen> createState() => _RoutineEditorScreenState();
}

class _RoutineEditorScreenState extends State<RoutineEditorScreen> {
  Routine? _routine;
  List<RoutineDay> _days = [];
  int _selectedDayIndex = 1;
  List<ExerciseDef> _exercises = [];
  Map<int, int> _dayCounts = {};
  List<String> _knownNames = [];
  Map<String, TrackingType> _knownTypes = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final routine = await DBHelper.instance.getRoutine(widget.routineId);
    final days = await DBHelper.instance.getDays(widget.routineId);
    final names = await DBHelper.instance.getKnownExerciseNames();
    final types = await DBHelper.instance.getKnownExerciseTypes();
    final counts = <int, int>{};
    for (final d in days) {
      counts[d.id!] = await DBHelper.instance.countExercises(d.id!);
    }
    if (!mounted) return;
    setState(() {
      _routine = routine;
      _days = days;
      _dayCounts = counts;
      _knownNames = names;
      _knownTypes = types;
    });
    await _loadExercises();
  }

  Future<void> _loadExercises() async {
    if (_days.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final matches = _days.where((d) => d.dayIndex == _selectedDayIndex);
    final day = matches.isNotEmpty ? matches.first : _days.first;
    final exercises = await DBHelper.instance.getExercises(day.id!);
    if (!mounted) return;
    setState(() {
      _exercises = exercises;
      _dayCounts[day.id!] = exercises.length;
      _loading = false;
    });
  }

  RoutineDay get _currentDay {
    final matches = _days.where((d) => d.dayIndex == _selectedDayIndex);
    return matches.isNotEmpty ? matches.first : _days.first;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (_loading && _routine == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_routine == null || _days.isEmpty) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This routine no longer exists.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: _renameRoutine,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                  child: Text(_routine!.name,
                      overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18))),
              const SizedBox(width: 6),
              const Icon(Icons.edit, size: 15),
            ],
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: _onDayMenu,
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'rename_day', child: Text('Rename this day')),
              PopupMenuItem(value: 'copy_day', child: Text('Copy exercises from another day')),
              PopupMenuItem(value: 'clear_day', child: Text('Clear this day')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 46,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              itemCount: _days.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final day = _days[i];
                final selected = day.dayIndex == _selectedDayIndex;
                final count = _dayCounts[day.id] ?? 0;
                return ChoiceChip(
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(day.dayName),
                      if (count > 0) ...[
                        const SizedBox(width: 5),
                        Text('$count',
                            style: TextStyle(
                                fontSize: 11,
                                color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant)),
                      ],
                    ],
                  ),
                  selected: selected,
                  onSelected: (_) {
                    setState(() => _selectedDayIndex = day.dayIndex);
                    _loadExercises();
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Day $_selectedDayIndex · ${_currentDay.dayName}',
                    style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _renameDay(_currentDay),
                  icon: const Icon(Icons.drive_file_rename_outline, size: 16),
                  label: const Text('Rename'),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
              ],
            ),
          ),
          Expanded(
            child: _exercises.isEmpty
                ? _EmptyDay(onAdd: () => _addOrEditExercise(), onCopy: _copyFromDay)
                : ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 90),
                    itemCount: _exercises.length,
                    onReorderItem: _onReorder,
                    itemBuilder: (context, i) {
                      final ex = _exercises[i];
                      return Card(
                        key: ValueKey(ex.id),
                        elevation: 0,
                        margin: const EdgeInsets.only(bottom: 8),
                        color: scheme.surfaceContainerLowest,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: scheme.outlineVariant.withAlpha(120)),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
                          title: Text(ex.name,
                              style: const TextStyle(fontWeight: FontWeight.w500)),
                          subtitle: Text(
                            '${ex.type.label} · ${ex.targetSets} set${ex.targetSets == 1 ? '' : 's'}',
                            style: theme.textTheme.labelSmall,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 20),
                                onPressed: () => _addOrEditExercise(existing: ex),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, size: 20),
                                onPressed: () => _deleteExercise(ex),
                              ),
                              ReorderableDragStartListener(
                                index: i,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 2, right: 8),
                                  child: Icon(Icons.drag_handle,
                                      size: 20, color: scheme.onSurfaceVariant),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEditExercise(),
        icon: const Icon(Icons.add),
        label: const Text('Add exercise'),
      ),
    );
  }

  // ---------------------------------------------------------------------

  /// [newIndex] already accounts for the item being lifted out of the list.
  Future<void> _onReorder(int oldIndex, int newIndex) async {
    final list = List<ExerciseDef>.from(_exercises);
    list.insert(newIndex, list.removeAt(oldIndex));
    setState(() => _exercises = list);
    await DBHelper.instance.reorderExercises(list);
  }

  Future<void> _renameRoutine() async {
    final name = await _promptText(context, title: 'Routine name', initial: _routine!.name);
    if (name == null || name.trim().isEmpty) return;
    await DBHelper.instance.renameRoutine(_routine!.id!, name.trim());
    await _load();
  }

  Future<void> _renameDay(RoutineDay day) async {
    final name = await _promptText(context,
        title: 'Day name', initial: day.dayName, hint: 'e.g. Push, Legs, Rest');
    if (name == null || name.trim().isEmpty) return;
    await DBHelper.instance.renameDay(day.id!, name.trim());
    await _load();
  }

  Future<void> _onDayMenu(String value) async {
    switch (value) {
      case 'rename_day':
        await _renameDay(_currentDay);
        break;
      case 'copy_day':
        await _copyFromDay();
        break;
      case 'clear_day':
        await _clearDay();
        break;
    }
  }

  Future<void> _copyFromDay() async {
    final options = _days.where((d) => d.dayIndex != _selectedDayIndex).toList();
    final source = await showDialog<RoutineDay>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Copy exercises from'),
        children: options
            .map((d) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, d),
                  child: Text('Day ${d.dayIndex} · ${d.dayName}  '
                      '(${_dayCounts[d.id] ?? 0} exercises)'),
                ))
            .toList(),
      ),
    );
    if (source == null || !mounted) return;
    if (_exercises.isNotEmpty) {
      final ok = await _confirm(
        title: 'Replace this day?',
        body: '${_currentDay.dayName} currently has ${_exercises.length} exercises. '
            'They will be replaced by ${source.dayName}\'s.',
        confirmLabel: 'Replace',
      );
      if (ok != true || !mounted) return;
    }
    await DBHelper.instance.copyExercisesToDay(source.id!, _currentDay.id!);
    await _load();
  }

  Future<void> _clearDay() async {
    if (_exercises.isEmpty) return;
    final ok = await _confirm(
      title: 'Clear this day?',
      body: 'Removes all ${_exercises.length} exercises from ${_currentDay.dayName}, '
          'turning it into a rest day. Logged workouts are unaffected.',
      confirmLabel: 'Clear',
    );
    if (ok != true) return;
    for (final ex in _exercises) {
      await DBHelper.instance.deleteExercise(ex.id!);
    }
    await _load();
  }

  Future<void> _addOrEditExercise({ExerciseDef? existing}) async {
    final result = await showDialog<ExerciseFormResult>(
      context: context,
      builder: (context) => ExerciseDialog(
        existing: existing,
        knownNames: _knownNames,
        knownTypes: _knownTypes,
      ),
    );
    if (result == null || !mounted) return;

    if (existing == null) {
      await DBHelper.instance.addExercise(ExerciseDef(
        routineDayId: _currentDay.id!,
        name: result.name,
        type: result.type,
        targetSets: result.sets,
        sortOrder: _exercises.length,
      ));
    } else {
      await DBHelper.instance.updateExercise(existing.copyWith(
        name: result.name,
        type: result.type,
        targetSets: result.sets,
      ));
    }
    await _load();
  }

  Future<void> _deleteExercise(ExerciseDef ex) async {
    await DBHelper.instance.deleteExercise(ex.id!);
    await _load();
  }

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(confirmLabel)),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------

class _EmptyDay extends StatelessWidget {
  final VoidCallback onAdd;
  final VoidCallback onCopy;

  const _EmptyDay({required this.onAdd, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.self_improvement, size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: 10),
            Text(
              'Rest day — no exercises here.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: onCopy,
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('Copy from another day'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<String?> _promptText(BuildContext context,
    {required String title, required String initial, String? hint}) {
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
