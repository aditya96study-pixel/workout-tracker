import 'dart:convert';

import 'workout_log.dart';

/// One entry of a week's plan snapshot: "on this week's plan, the day called
/// 'Push' appeared twice and had 5 exercises".
class PlannedDay {
  final int dayIndex;

  /// The routine_days row this came from. Lets a session be matched back to
  /// its planned day even after the day has been renamed mid-week — matching
  /// on name alone would report the old name as an extra and the new one as
  /// missed. Null for plans snapshotted before this field existed.
  final int? dayId;
  final String dayName;
  final int exerciseCount;

  PlannedDay({
    required this.dayIndex,
    required this.dayId,
    required this.dayName,
    required this.exerciseCount,
  });

  Map<String, Object?> toJson() => {
        'dayIndex': dayIndex,
        'dayId': dayId,
        'dayName': dayName,
        'exerciseCount': exerciseCount,
      };

  factory PlannedDay.fromJson(Map<String, Object?> json) => PlannedDay(
        dayIndex: (json['dayIndex'] as num).toInt(),
        dayId: (json['dayId'] as num?)?.toInt(),
        dayName: json['dayName'] as String,
        exerciseCount: (json['exerciseCount'] as num?)?.toInt() ?? 0,
      );
}

/// A calendar week, with the routine plan snapshotted at the moment the week
/// began.
///
/// Snapshotting matters: without it, editing or switching your routine in
/// March would silently rewrite what January "should" have looked like, and
/// the missed-workout analysis for past weeks would be nonsense.
class WorkoutWeek {
  final int? id;
  final String weekStart; // 'yyyy-MM-dd' Monday
  final int? routineId;
  final String routineName;
  final List<PlannedDay> plan;
  final bool closed;
  final int? closedAtMs;

  /// True when the week was rolled over automatically because a new week
  /// started, rather than closed by the Complete Week button.
  final bool autoClosed;

  WorkoutWeek({
    this.id,
    required this.weekStart,
    required this.routineId,
    required this.routineName,
    required this.plan,
    this.closed = false,
    this.closedAtMs,
    this.autoClosed = false,
  });

  /// Planned occurrences per day name, ignoring rest days (days with no
  /// exercises), which aren't something you can "miss".
  Map<String, int> get plannedCounts {
    final counts = <String, int>{};
    for (final d in plan) {
      if (d.exerciseCount == 0) continue;
      counts[d.dayName] = (counts[d.dayName] ?? 0) + 1;
    }
    return counts;
  }

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'week_start': weekStart,
        'routine_id': routineId,
        'routine_name': routineName,
        'plan_json': jsonEncode(plan.map((p) => p.toJson()).toList()),
        'status': closed ? 'closed' : 'open',
        'closed_at': closedAtMs,
        'auto_closed': autoClosed ? 1 : 0,
      };

  factory WorkoutWeek.fromMap(Map<String, Object?> map) {
    final rawPlan = map['plan_json'] as String?;
    var plan = <PlannedDay>[];
    if (rawPlan != null && rawPlan.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawPlan);
        if (decoded is List) {
          plan = decoded
              .whereType<Map>()
              .map((e) => PlannedDay.fromJson(e.cast<String, Object?>()))
              .toList();
        }
      } catch (_) {
        // A corrupt snapshot shouldn't take down the History tab — an empty
        // plan just means "nothing was scheduled", which reads sensibly.
        plan = <PlannedDay>[];
      }
    }
    return WorkoutWeek(
      id: map['id'] as int?,
      weekStart: map['week_start'] as String,
      routineId: map['routine_id'] as int?,
      routineName: map['routine_name'] as String,
      plan: plan,
      closed: (map['status'] as String?) == 'closed',
      closedAtMs: map['closed_at'] as int?,
      autoClosed: (map['auto_closed'] as int?) == 1,
    );
  }
}

/// How one named day of the plan actually went this week.
class DayOutcome {
  final String dayName;
  final int planned;
  final int done;

  DayOutcome({required this.dayName, required this.planned, required this.done});

  int get missed => planned > done ? planned - done : 0;
  int get extra => done > planned ? done - planned : 0;

  /// A day that was done at least as many times as planned.
  bool get onTrack => planned > 0 && done >= planned;

  /// A day that was never scheduled this week but got done anyway — happens
  /// when you switch routines mid-week or improvise.
  bool get unplanned => planned == 0 && done > 0;
}

/// Everything the History tab needs to describe one week.
class WeekSummary {
  final WorkoutWeek week;
  final List<WorkoutSession> sessions; // completed sessions, newest first
  final List<DayOutcome> outcomes;

  WeekSummary({
    required this.week,
    required this.sessions,
    required this.outcomes,
  });

  int get totalPlanned => outcomes.fold(0, (sum, o) => sum + o.planned);

  /// Every completed session this week, extras included.
  int get totalDone => outcomes.fold(0, (sum, o) => sum + o.done);

  int get totalMissed => outcomes.fold(0, (sum, o) => sum + o.missed);

  /// Planned sessions that were actually done, ignoring extras.
  ///
  /// Counting extras here would let three Legs sessions cancel out a skipped
  /// Push day and report the week as complete while the card underneath says
  /// "Missed: Push" — so the bar deliberately caps each day at its plan.
  int get plannedDone => outcomes.fold(0, (sum, o) => sum + (o.done < o.planned ? o.done : o.planned));

  List<DayOutcome> get missedDays => outcomes.where((o) => o.missed > 0).toList();

  /// 0..1 completion against the plan.
  double get completionRatio {
    if (totalPlanned == 0) return totalDone > 0 ? 1.0 : 0.0;
    return plannedDone / totalPlanned;
  }
}
