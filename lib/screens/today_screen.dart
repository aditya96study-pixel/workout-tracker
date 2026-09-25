import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../db/db_helper.dart';
import '../models/routine.dart';
import '../models/workout_log.dart';
import '../services/app_dates.dart';
import '../widgets/exercise_tile.dart';

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  int? _routineId;
  int _revisionSeen = -1;
  String? _daySeen;

  List<RoutineDay> _days = [];
  int? _selectedDayIndex;
  List<ExerciseDef> _exercises = [];
  WorkoutSession? _session;
  Map<int, List<SetLog>> _logsByExercise = {};
  Map<int, int> _weekDayCounts = {};
  bool _loading = true;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final routine = appState.activeRoutine;

    if (routine == null) return const _NoRoutineState();

    // Once the calendar day changes, yesterday's selection is stale — drop it
    // so the reload picks today's day instead of silently re-opening
    // yesterday's workout on the wrong date.
    if (_daySeen != appState.today) {
      _daySeen = appState.today;
      _selectedDayIndex = null;
    }

    // Reload when the active routine changes, or when something happened
    // behind our back (midnight rollover, week closed elsewhere).
    if (_routineId != routine.id || _revisionSeen != appState.revision) {
      _routineId = routine.id;
      _revisionSeen = appState.revision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadDays(routine.id!);
      });
    }

    _showAutoSavedNoticeIfNeeded(appState);

    final session = _session;
    final inProgress = appState.inProgressSession;

    // A workout can end up unreachable from the current routine — its routine
    // was deleted, or swapped while it was running. It would otherwise lock
    // every day forever with no way to finish it, so it gets its own banner.
    final strandedSession = (inProgress != null &&
            (inProgress.routineDayId == null ||
                !_days.any((d) => d.id == inProgress.routineDayId)))
        ? inProgress
        : null;
    final lockedToDay = strandedSession != null ? null : inProgress?.routineDayId;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(routine.name, style: const TextStyle(fontSize: 18)),
            Text(
              shortDateWithWeekday(appState.today),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.normal,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: _onMenuSelected,
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'week', child: Text('Complete this week')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (strandedSession != null)
                  _StrandedBanner(
                    session: strandedSession,
                    onResolve: _busy ? null : _resolveStranded,
                  ),
                _DaySelector(
                  days: _days,
                  selectedIndex: _selectedDayIndex,
                  lockedToRoutineDayId: lockedToDay,
                  weekDayCounts: _weekDayCounts,
                  onSelect: _onSelectDay,
                  onBlocked: _explainLock,
                ),
                if (session != null && session.isCompleted)
                  _CompletedBanner(session: session, onReopen: _busy ? null : _reopen),
                Expanded(
                  child: _exercises.isEmpty
                      ? const _RestDayState()
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                          itemCount: _exercises.length,
                          itemBuilder: (context, i) {
                            final ex = _exercises[i];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: ExerciseTile(
                                key: ValueKey('${session?.id}_${ex.id}'),
                                exercise: ex,
                                logs: _logsByExercise[ex.id] ?? const [],
                                readOnly: session?.isCompleted ?? false,
                                onToggleSet: _toggleSet,
                                onFieldChanged: _onFieldChanged,
                                onAddSet: () => _addSet(ex),
                                onRemoveSet: _removeSet,
                              ),
                            );
                          },
                        ),
                ),
                if (_exercises.isNotEmpty && session != null && !session.isCompleted)
                  _CompleteBar(
                    doneSets: _doneSetCount,
                    totalSets: _totalSetCount,
                    enabled: !_busy && _doneSetCount > 0,
                    onComplete: _completeWorkout,
                  ),
              ],
            ),
    );
  }

  // ---------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------

  Future<void> _loadDays(int routineId) async {
    final days = await DBHelper.instance.getDays(routineId);
    if (!mounted) return;
    final appState = context.read<AppState>();

    if (days.isEmpty) {
      setState(() {
        _days = days;
        _loading = false;
      });
      return;
    }

    // A reachable workout in progress owns the screen: jump straight to its
    // day. An unreachable one (routine deleted or switched) falls through to
    // the normal selection and is handled by the stranded banner instead.
    int? target;
    final inProgress = appState.inProgressSession;
    if (inProgress?.routineDayId != null) {
      final match = days.where((d) => d.id == inProgress!.routineDayId);
      if (match.isNotEmpty) target = match.first.dayIndex;
    }
    target ??= _selectedDayIndex;
    if (target == null || !days.any((d) => d.dayIndex == target)) {
      final weekday = DateTime.now().weekday; // 1..7, Mon..Sun
      target = days.any((d) => d.dayIndex == weekday) ? weekday : days.first.dayIndex;
    }

    setState(() {
      _days = days;
      _selectedDayIndex = target;
    });
    await _loadDay();
  }

  Future<void> _loadDay() async {
    final dayIndex = _selectedDayIndex;
    if (_days.isEmpty || dayIndex == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (mounted) setState(() => _loading = true);

    final matches = _days.where((d) => d.dayIndex == dayIndex);
    final day = matches.isNotEmpty ? matches.first : _days.first;

    final exercises = await DBHelper.instance.getExercises(day.id!);
    if (!mounted) return;
    final routine = context.read<AppState>().activeRoutine;
    if (routine == null) return;

    WorkoutSession? session;
    Map<int, List<SetLog>> grouped = {};

    // Rest days get no session row at all — there's nothing to record, and
    // creating one would make the week summary think a workout happened. If
    // the day was emptied while a workout on it was open, that session goes
    // too, which is what releases the day lock.
    if (exercises.isEmpty) {
      await DBHelper.instance.discardOpenSessionForDay(todayYmd(), day.id!);
    } else {
      session = await DBHelper.instance.getOrCreateSession(
        todayYmd(),
        day,
        routine.name,
        exercises,
      );
      final logs = await DBHelper.instance.getSetLogsForSession(session.id!);
      for (final ex in exercises) {
        grouped[ex.id!] = logs.where((l) => l.exerciseDefId == ex.id).toList()
          ..sort((a, b) => a.setIndex.compareTo(b.setIndex));
      }
    }

    final counts = await DBHelper.instance.getCompletedDayCountsForWeek(currentWeekStart());
    if (!mounted) return;

    setState(() {
      _exercises = exercises;
      _session = session;
      _logsByExercise = grouped;
      _weekDayCounts = counts;
      _loading = false;
    });
    await context.read<AppState>().onSessionChanged();
  }

  // ---------------------------------------------------------------------
  // Day switching
  // ---------------------------------------------------------------------

  Future<void> _onSelectDay(int dayIndex) async {
    if (_selectedDayIndex == dayIndex) return;
    setState(() => _selectedDayIndex = dayIndex);
    await _loadDay();
  }

  void _explainLock() {
    final name = context.read<AppState>().inProgressSession?.dayName ?? 'this workout';
    _snack('Finish or reopen "$name" before switching days.');
  }

  // ---------------------------------------------------------------------
  // Set interactions
  // ---------------------------------------------------------------------

  int get _doneSetCount =>
      _logsByExercise.values.fold(0, (sum, logs) => sum + logs.where((l) => l.checked).length);

  int get _totalSetCount =>
      _logsByExercise.values.fold(0, (sum, logs) => sum + logs.length);

  Future<void> _toggleSet(SetLog log, bool checked) async {
    if (checked && !log.hasRequiredValue) {
      _snack('Enter this set\'s numbers before ticking it off.');
      return;
    }
    final exId = log.exerciseDefId;
    if (exId == null) return;
    final exLogs = _logsByExercise[exId];
    if (exLogs == null) return;
    final idx = exLogs.indexWhere((l) => l.id == log.id);
    if (idx == -1) return;

    final updates = <SetLog>[];
    if (checked) {
      updates.add(log.copyWith(checked: true, prefilled: false));
    } else {
      // Cascade: unchecking a set clears every set after it, keeping the
      // completed sets an unbroken run from set 1.
      for (var i = idx; i < exLogs.length; i++) {
        if (exLogs[i].checked || i == idx) {
          updates.add(exLogs[i].copyWith(checked: false));
        }
      }
    }

    _applyLocalUpdates(exId, updates);
    await DBHelper.instance.updateSetLogs(updates);
    await _syncSessionStatus();
  }

  /// Writes a keystroke straight through to SQLite. Deliberately does nothing
  /// else.
  ///
  /// It's tempting to uncheck a completed set the moment its numbers stop
  /// being valid, but every edit passes through an invalid state: changing 60
  /// to 62.5 means clearing the box first. Reacting to that would untick the
  /// set — and cascade through the sets after it — while you're still typing.
  /// A checked set left without numbers is instead cleaned up once, at the
  /// moment the workout is completed.
  Future<void> _onFieldChanged(SetLog updated) async {
    final exId = updated.exerciseDefId;
    if (exId == null) return;
    _applyLocalUpdates(exId, [updated]);
    await DBHelper.instance.updateSetLog(updated);
  }

  void _applyLocalUpdates(int exId, List<SetLog> updates) {
    if (!mounted) return;
    setState(() {
      final list = List<SetLog>.from(_logsByExercise[exId] ?? const []);
      for (final u in updates) {
        final i = list.indexWhere((l) => l.id == u.id);
        if (i != -1) list[i] = u;
      }
      _logsByExercise[exId] = list;
    });
  }

  Future<void> _addSet(ExerciseDef ex) async {
    final session = _session;
    if (session == null) return;
    final exLogs = _logsByExercise[ex.id] ?? const <SetLog>[];
    final last = exLogs.isNotEmpty ? exLogs.last : null;
    // Highest existing index + 1, not count + 1 — otherwise removing a middle
    // set and adding another would reuse an index that's already taken.
    final nextIndex =
        exLogs.fold<int>(0, (m, l) => l.setIndex > m ? l.setIndex : m) + 1;

    final created = await DBHelper.instance.addExtraSetLog(SetLog(
      sessionId: session.id!,
      exerciseDefId: ex.id,
      exerciseName: ex.name,
      type: ex.type,
      setIndex: nextIndex,
      checked: false,
      // Seed from the previous set so an extra set isn't an empty row.
      weightKg: last?.weightKg,
      reps: last?.reps,
      holdSeconds: last?.holdSeconds,
      cardioSeconds: last?.cardioSeconds,
      cardioDistanceKm: last?.cardioDistanceKm,
      prefilled: true,
    ));
    if (!mounted) return;
    setState(() => _logsByExercise[ex.id!] = [...exLogs, created]);
  }

  Future<void> _removeSet(SetLog log) async {
    final exId = log.exerciseDefId;
    if (exId == null) return;
    await DBHelper.instance.deleteSetLog(log.id!);
    if (!mounted) return;
    setState(() {
      _logsByExercise[exId] =
          (_logsByExercise[exId] ?? const <SetLog>[]).where((l) => l.id != log.id).toList();
    });
    await _syncSessionStatus();
  }

  /// Pushes draft/active back through the DB and refreshes the app-wide lock.
  Future<void> _syncSessionStatus() async {
    final session = _session;
    if (session?.id == null) return;
    await DBHelper.instance.recomputeSessionStatus(session!.id!);
    final refreshed = await DBHelper.instance.getSession(session.id!);
    if (!mounted) return;
    setState(() => _session = refreshed);
    await context.read<AppState>().onSessionChanged();
  }

  // ---------------------------------------------------------------------
  // Completing
  // ---------------------------------------------------------------------

  Future<void> _completeWorkout() async {
    final session = _session;
    if (session?.id == null) return;

    final done = _doneSetCount;
    final total = _totalSetCount;
    if (done < total) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Finish this workout?'),
          content: Text(
            'You\'ve ticked off $done of $total sets. The remaining ${total - done} '
            'won\'t be recorded.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep going')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Finish')),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }

    setState(() => _busy = true);
    await DBHelper.instance.completeSession(session!.id!);
    if (!mounted) return;
    // Bumps the revision, which reloads this screen and un-stales the
    // History and Progress tabs sitting alive in the IndexedStack.
    await context.read<AppState>().onWorkoutFinished();
    if (!mounted) return;
    setState(() => _busy = false);
    _snack('Workout saved to history.');
  }

  Future<void> _reopen() async {
    final session = _session;
    if (session?.id == null) return;
    setState(() => _busy = true);
    await DBHelper.instance.reopenSession(session!.id!);
    if (!mounted) return;
    await context.read<AppState>().onWorkoutFinished();
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _resolveStranded() async {
    final appState = context.read<AppState>();
    final name = appState.inProgressSession?.dayName ?? 'workout';
    final keep = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unfinished workout'),
        content: Text(
          '"$name" is still open but no longer belongs to your active routine. '
          'Save what was ticked off, or discard it?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Discard')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save it')),
        ],
      ),
    );
    if (keep == null || !mounted) return;
    setState(() => _busy = true);
    await appState.resolveStrandedWorkout(keep: keep);
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(keep ? 'Saved to history.' : 'Discarded.');
  }

  Future<void> _onMenuSelected(String value) async {
    if (value != 'week') return;
    final weekStart = currentWeekStart();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Complete this week?'),
        content: Text(
          'Closes ${weekRangeLabel(weekStart)} and files it in History. Any workout '
          'still in progress is saved first. Weeks also close on their own every '
          'Monday — this is just the early finish.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Complete week')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<AppState>().completeWeek(weekStart);
    if (!mounted) return;
    _snack('Week closed. See it under History → Weeks.');
  }

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------

  void _showAutoSavedNoticeIfNeeded(AppState appState) {
    final count = appState.pendingAutoSavedCount;
    if (count <= 0) return;
    appState.consumeAutoSavedNotice();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _snack(count == 1
          ? 'An unfinished workout was saved automatically at midnight.'
          : '$count unfinished workouts were saved automatically at midnight.');
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 3)));
  }
}

// -----------------------------------------------------------------------
// Pieces
// -----------------------------------------------------------------------

class _DaySelector extends StatelessWidget {
  final List<RoutineDay> days;
  final int? selectedIndex;
  final int? lockedToRoutineDayId;
  final Map<int, int> weekDayCounts;
  final ValueChanged<int> onSelect;
  final VoidCallback onBlocked;

  const _DaySelector({
    required this.days,
    required this.selectedIndex,
    required this.lockedToRoutineDayId,
    required this.weekDayCounts,
    required this.onSelect,
    required this.onBlocked,
  });

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            itemCount: days.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final day = days[i];
              final selected = day.dayIndex == selectedIndex;
              final blocked = lockedToRoutineDayId != null && day.id != lockedToRoutineDayId;
              final doneCount = weekDayCounts[day.id] ?? 0;

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: blocked ? onBlocked : null,
                child: ChoiceChip(
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (doneCount > 0) ...[
                        Icon(Icons.check, size: 14, color: scheme.primary),
                        const SizedBox(width: 4),
                      ],
                      Text(day.dayName),
                      if (doneCount > 1) ...[
                        const SizedBox(width: 3),
                        Text('×$doneCount',
                            style: TextStyle(fontSize: 11, color: scheme.primary)),
                      ],
                    ],
                  ),
                  selected: selected,
                  // A blocked chip stays visible but inert; the tap is caught
                  // by the wrapper above so we can explain why.
                  onSelected: blocked ? null : (_) => onSelect(day.dayIndex),
                ),
              );
            },
          ),
        ),
        if (lockedToRoutineDayId != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
            child: Row(
              children: [
                Icon(Icons.lock_outline, size: 13, color: scheme.onSurfaceVariant),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    'Workout in progress — days unlock when you finish it',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _CompleteBar extends StatelessWidget {
  final int doneSets;
  final int totalSets;
  final bool enabled;
  final VoidCallback onComplete;

  const _CompleteBar({
    required this.doneSets,
    required this.totalSets,
    required this.enabled,
    required this.onComplete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ratio = totalSets == 0 ? 0.0 : doneSets / totalSets;

    return Material(
      color: scheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: ratio,
                        minHeight: 6,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text('$doneSets/$totalSets sets',
                      style: Theme.of(context).textTheme.labelMedium),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: enabled ? onComplete : null,
                  icon: const Icon(Icons.check_circle_outline),
                  label: Text(enabled ? 'Complete workout' : 'Tick a set to start'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompletedBanner extends StatelessWidget {
  final WorkoutSession session;
  final VoidCallback? onReopen;

  const _CompletedBanner({required this.session, required this.onReopen});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final at = session.completedAtMs;
    final label = session.autoCompleted
        ? 'Saved automatically at midnight'
        : at != null
            ? 'Completed at ${clockTime(at)}'
            : 'Completed';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle, size: 18, color: scheme.onPrimaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: TextStyle(color: scheme.onPrimaryContainer, fontSize: 13)),
          ),
          TextButton(onPressed: onReopen, child: const Text('Reopen')),
        ],
      ),
    );
  }
}

/// Escape hatch for a workout that can't be reached from the current routine.
/// Without it the day lock would hold forever with nothing to unlock it.
class _StrandedBanner extends StatelessWidget {
  final WorkoutSession session;
  final VoidCallback? onResolve;

  const _StrandedBanner({required this.session, required this.onResolve});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '"${session.dayName}" is still unfinished from another routine',
              style: TextStyle(color: scheme.onTertiaryContainer, fontSize: 13),
            ),
          ),
          TextButton(onPressed: onResolve, child: const Text('Resolve')),
        ],
      ),
    );
  }
}

class _RestDayState extends StatelessWidget {
  const _RestDayState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.self_improvement, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('Rest day', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'No exercises on this day. Add some from the Routines tab if that\'s wrong.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoRoutineState extends StatelessWidget {
  const _NoRoutineState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Today')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.fitness_center, size: 44, color: scheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text('No active routine', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                'Create or import a routine from the Routines tab, then tap it to make it active.',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
