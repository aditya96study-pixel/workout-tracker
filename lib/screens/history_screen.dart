import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../db/db_helper.dart';
import '../models/routine.dart';
import '../models/week.dart';
import '../models/workout_log.dart';
import '../services/app_dates.dart';
import 'exercise_chart_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'Weeks'), Tab(text: 'Progress')],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [_WeeksTab(), _ProgressTab()],
      ),
    );
  }
}

// -----------------------------------------------------------------------
// Weeks — plan vs. what actually happened
// -----------------------------------------------------------------------

class _WeeksTab extends StatefulWidget {
  const _WeeksTab();

  @override
  State<_WeeksTab> createState() => _WeeksTabState();
}

class _WeeksTabState extends State<_WeeksTab> {
  List<WeekSummary> _weeks = [];
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

    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_weeks.isEmpty) {
      return const _EmptyMessage(
        icon: Icons.calendar_month_outlined,
        title: 'Nothing logged yet',
        body: 'Finish a workout on the Today tab and your week will show up here.',
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount: _weeks.length,
        itemBuilder: (context, i) => _WeekCard(
          summary: _weeks[i],
          onCompleteWeek: () => _completeWeek(_weeks[i]),
          onOpenSession: (s) => _showSession(context, s),
        ),
      ),
    );
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final weeks = await DBHelper.instance.getWeekSummaries();
    if (!mounted) return;
    setState(() {
      _weeks = weeks;
      _loading = false;
    });
  }

  Future<void> _completeWeek(WeekSummary summary) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Complete this week?'),
        content: const Text(
          'Closes the week and freezes its plan so later routine changes can\'t '
          'rewrite it. Any workout still in progress is saved first.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Complete week')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<AppState>().completeWeek(summary.week.weekStart);
    await _load();
  }

  Future<void> _showSession(BuildContext context, WorkoutSession session) async {
    final logs = await DBHelper.instance.getCompletedLogsForSession(session.id!);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _SessionSheet(session: session, logs: logs),
    );
  }
}

class _WeekCard extends StatelessWidget {
  final WeekSummary summary;
  final VoidCallback onCompleteWeek;
  final ValueChanged<WorkoutSession> onOpenSession;

  const _WeekCard({
    required this.summary,
    required this.onCompleteWeek,
    required this.onOpenSession,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final week = summary.week;
    final isCurrent = week.weekStart == currentWeekStart();
    final hasPlan = week.plan.isNotEmpty;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      color: scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withAlpha(120)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(weekHeadline(week.weekStart),
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      Text(
                        '${weekRangeLabel(week.weekStart)} · ${week.routineName}',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (week.closed)
                  Tooltip(
                    message: week.autoClosed ? 'Closed automatically' : 'Closed by you',
                    child: Icon(Icons.lock_outline, size: 16, color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            if (hasPlan) ...[
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: summary.completionRatio,
                        minHeight: 6,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Planned-and-done, not raw total: extras shouldn't cancel
                  // out a missed day and read as a complete week.
                  Text('${summary.plannedDone}/${summary.totalPlanned}',
                      style: theme.textTheme.labelMedium),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: summary.outcomes.map((o) => _OutcomeChip(outcome: o)).toList(),
              ),
              if (summary.totalMissed > 0) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer.withAlpha(120),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _missedSentence(summary),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onErrorContainer),
                  ),
                ),
              ],
            ] else ...[
              Text(
                summary.sessions.isEmpty
                    ? 'Nothing logged this week.'
                    : 'No plan was recorded for this week — showing what was done.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (summary.sessions.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: summary.outcomes.map((o) => _OutcomeChip(outcome: o)).toList(),
                ),
              ],
            ],

            if (summary.sessions.isNotEmpty) ...[
              const SizedBox(height: 4),
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: Text(
                    '${summary.sessions.length} workout${summary.sessions.length == 1 ? '' : 's'}',
                    style: theme.textTheme.labelLarge,
                  ),
                  children: summary.sessions
                      .map((s) => ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              s.autoCompleted ? Icons.nightlight_outlined : Icons.check_circle_outline,
                              size: 18,
                              color: scheme.primary,
                            ),
                            title: Text(s.dayName),
                            subtitle: Text(
                              s.autoCompleted
                                  ? '${shortDateWithWeekday(s.date)} · auto-saved at midnight'
                                  : shortDateWithWeekday(s.date),
                              style: theme.textTheme.labelSmall,
                            ),
                            trailing: const Icon(Icons.chevron_right, size: 18),
                            onTap: () => onOpenSession(s),
                          ))
                      .toList(),
                ),
              ),
            ],

            if (isCurrent && !week.closed)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onCompleteWeek,
                  icon: const Icon(Icons.done_all, size: 18),
                  label: const Text('Complete week'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _missedSentence(WeekSummary summary) {
    final missed = summary.missedDays;
    final parts = missed
        .map((o) => o.missed > 1 ? '${o.dayName} ×${o.missed}' : o.dayName)
        .toList();
    final label = parts.length == 1
        ? parts.first
        : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
    return 'Missed this week: $label.';
  }
}

class _OutcomeChip extends StatelessWidget {
  final DayOutcome outcome;
  const _OutcomeChip({required this.outcome});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    late final Color fg;
    late final Color bg;
    late final IconData icon;
    late final String text;

    if (outcome.unplanned) {
      fg = scheme.onTertiaryContainer;
      bg = scheme.tertiaryContainer;
      icon = Icons.add_circle_outline;
      text = '${outcome.dayName} ${outcome.done}× (extra)';
    } else if (outcome.missed > 0) {
      fg = scheme.onErrorContainer;
      bg = scheme.errorContainer;
      icon = Icons.remove_circle_outline;
      text = '${outcome.dayName} ${outcome.done}/${outcome.planned}';
    } else {
      fg = scheme.onPrimaryContainer;
      bg = scheme.primaryContainer;
      icon = Icons.check_circle_outline;
      text = outcome.extra > 0
          ? '${outcome.dayName} ${outcome.done}/${outcome.planned} (+${outcome.extra})'
          : '${outcome.dayName} ${outcome.done}/${outcome.planned}';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 5),
          Text(text, style: TextStyle(fontSize: 12, color: fg, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

/// One exercise's worth of sets inside a completed workout.
class _ExerciseBlock {
  final int? defId;
  final String name;
  final List<SetLog> logs = [];
  _ExerciseBlock(this.defId, this.name);
}

/// Splits a session's logs into one block per exercise.
///
/// Rows keep their routine exercise id, so a lift programmed twice on the same
/// day stays two blocks. Once that routine is deleted the ids go null
/// (ON DELETE SET NULL), and the fallback is a contiguous run of the same
/// name — which still separates the two instances, because their rows were
/// written consecutively.
List<_ExerciseBlock> _groupIntoBlocks(List<SetLog> logs) {
  final blocks = <_ExerciseBlock>[];
  for (final log in logs) {
    _ExerciseBlock? target;
    if (log.exerciseDefId != null) {
      for (final b in blocks) {
        if (b.defId == log.exerciseDefId) {
          target = b;
          break;
        }
      }
    } else if (blocks.isNotEmpty &&
        blocks.last.defId == null &&
        blocks.last.name == log.exerciseName) {
      target = blocks.last;
    }
    if (target == null) {
      target = _ExerciseBlock(log.exerciseDefId, log.exerciseName);
      blocks.add(target);
    }
    target.logs.add(log);
  }
  return blocks;
}

/// Breakdown of one completed workout, grouped by exercise.
class _SessionSheet extends StatelessWidget {
  final WorkoutSession session;
  final List<SetLog> logs;

  const _SessionSheet({required this.session, required this.logs});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final blocks = _groupIntoBlocks(logs);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Text(session.dayName, style: theme.textTheme.titleLarge),
            Text(
              '${shortDateWithWeekday(session.date)} · ${session.routineName}',
              style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            if (blocks.isEmpty)
              Text('No sets were recorded.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant))
            else
              ...blocks.map((block) => Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(block.name,
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        ...block.logs.map((log) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 1),
                              child: Text(
                                'Set ${log.setIndex}   ${_describe(log)}',
                                style: theme.textTheme.bodyMedium
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            )),
                      ],
                    ),
                  )),
          ],
        ),
      ),
    );
  }

  String _describe(SetLog log) {
    switch (log.type) {
      case TrackingType.weights:
        final w = log.weightKg;
        final r = log.reps;
        if (w == null || r == null) return '—';
        return '${_num(w)} kg × $r';
      case TrackingType.reps:
        return log.reps != null ? '${log.reps} reps' : '—';
      case TrackingType.time:
        return log.holdSeconds != null ? '${log.holdSeconds} sec' : '—';
      case TrackingType.cardio:
        final parts = <String>[];
        if (log.cardioSeconds != null) {
          parts.add('${(log.cardioSeconds! / 60).toStringAsFixed(1)} min');
        }
        if (log.cardioDistanceKm != null) parts.add('${_num(log.cardioDistanceKm!)} km');
        return parts.isEmpty ? '—' : parts.join(' · ');
      case TrackingType.none:
        return 'done';
    }
  }

  static String _num(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}

// -----------------------------------------------------------------------
// Progress — per-exercise charts
// -----------------------------------------------------------------------

class _ProgressTab extends StatefulWidget {
  const _ProgressTab();

  @override
  State<_ProgressTab> createState() => _ProgressTabState();
}

class _ProgressTabState extends State<_ProgressTab> {
  List<String> _names = [];
  bool _loading = true;
  int _revisionSeen = -1;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    if (_revisionSeen != appState.revision) {
      _revisionSeen = appState.revision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }

    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_names.isEmpty) {
      return const _EmptyMessage(
        icon: Icons.show_chart,
        title: 'No progress data yet',
        body: 'Tick sets off and complete a workout — each exercise then gets its own chart here.',
      );
    }

    final filtered = _query.isEmpty
        ? _names
        : _names.where((n) => n.toLowerCase().contains(_query.toLowerCase())).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: TextField(
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search exercises',
              prefixIcon: const Icon(Icons.search, size: 20),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              itemCount: filtered.length,
              itemBuilder: (context, i) {
                final name = filtered[i];
                return Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 8),
                  color: Theme.of(context).colorScheme.surfaceContainerLowest,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant.withAlpha(120)),
                  ),
                  child: ListTile(
                    title: Text(name),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ExerciseChartScreen(exerciseName: name),
                    )),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final names = await DBHelper.instance.getTrackableExerciseNames();
    if (!mounted) return;
    setState(() {
      _names = names;
      _loading = false;
    });
  }
}

class _EmptyMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _EmptyMessage({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              body,
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
