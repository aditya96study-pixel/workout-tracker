import 'routine.dart';

/// Lifecycle of one workout session.
///
/// * [draft] — the day has been opened and its set rows exist (possibly
///   pre-filled from last time), but nothing has been checked off yet.
///   Drafts are disposable: switching days or crossing midnight discards
///   them, and they never appear in history.
/// * [active] — at least one set is checked. This is the "workout in
///   progress" state that locks day switching.
/// * [completed] — finished, either by the Complete Workout button or by
///   the automatic midnight rollover. Counts towards history and charts.
enum SessionStatus { draft, active, completed }

extension SessionStatusX on SessionStatus {
  String get dbValue => name;

  static SessionStatus fromDbValue(String? value) {
    switch (value) {
      case 'draft':
        return SessionStatus.draft;
      case 'active':
        return SessionStatus.active;
      case 'completed':
      default:
        // Rows migrated from schema v1 predate this column and were always
        // effectively finished, so they default to completed.
        return SessionStatus.completed;
    }
  }
}

/// One execution of a routine day on a given calendar date.
///
/// dayName/routineName are snapshotted so history stays readable even if the
/// routine is renamed, restructured, or deleted later.
class WorkoutSession {
  final int? id;
  final String date; // 'yyyy-MM-dd' — the day it was actually performed
  final String weekStart; // 'yyyy-MM-dd' Monday of that date's week
  final int? routineDayId;
  final String dayName;
  final String routineName;
  final SessionStatus status;
  final int createdAtMs;
  final int? completedAtMs;

  /// True when the midnight rollover finished this session rather than the
  /// user pressing Complete Workout. Surfaced in history so an auto-saved
  /// workout is never mistaken for one you deliberately closed out.
  final bool autoCompleted;

  WorkoutSession({
    this.id,
    required this.date,
    required this.weekStart,
    required this.routineDayId,
    required this.dayName,
    required this.routineName,
    this.status = SessionStatus.draft,
    int? createdAtMs,
    this.completedAtMs,
    this.autoCompleted = false,
  }) : createdAtMs = createdAtMs ?? DateTime.now().millisecondsSinceEpoch;

  bool get isDraft => status == SessionStatus.draft;
  bool get isActive => status == SessionStatus.active;
  bool get isCompleted => status == SessionStatus.completed;

  WorkoutSession copyWith({
    SessionStatus? status,
    int? completedAtMs,
    bool? autoCompleted,
  }) =>
      WorkoutSession(
        id: id,
        date: date,
        weekStart: weekStart,
        routineDayId: routineDayId,
        dayName: dayName,
        routineName: routineName,
        status: status ?? this.status,
        createdAtMs: createdAtMs,
        completedAtMs: completedAtMs ?? this.completedAtMs,
        autoCompleted: autoCompleted ?? this.autoCompleted,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'date': date,
        'week_start': weekStart,
        'routine_day_id': routineDayId,
        'day_name': dayName,
        'routine_name': routineName,
        'status': status.dbValue,
        'created_at': createdAtMs,
        'completed_at': completedAtMs,
        'auto_completed': autoCompleted ? 1 : 0,
      };

  factory WorkoutSession.fromMap(Map<String, Object?> map) => WorkoutSession(
        id: map['id'] as int?,
        date: map['date'] as String,
        weekStart: (map['week_start'] as String?) ?? '',
        routineDayId: map['routine_day_id'] as int?,
        dayName: map['day_name'] as String,
        routineName: map['routine_name'] as String,
        status: SessionStatusX.fromDbValue(map['status'] as String?),
        createdAtMs: map['created_at'] as int,
        completedAtMs: map['completed_at'] as int?,
        autoCompleted: (map['auto_completed'] as int?) == 1,
      );
}

/// Sentinel that lets [SetLog.copyWith] tell "leave this field alone" apart
/// from "explicitly set this field back to null". Without it, clearing a
/// weight or reps box in the UI would silently keep the old stored value.
const Object _unset = Object();

/// A single logged set.
///
/// Exercise identity is denormalized (name + type snapshotted) so history and
/// charts stay correct even if the routine's exercise list changes later.
/// [exerciseDefId] is kept when available so the Today screen can match logs
/// back to the live routine exercise.
class SetLog {
  final int? id;
  final int sessionId;
  final int? exerciseDefId;
  final String exerciseName;
  final TrackingType type;
  final int setIndex; // 1-based
  final bool checked;
  final double? weightKg;
  final int? reps;
  final int? holdSeconds;
  final int? cardioSeconds;
  final double? cardioDistanceKm;
  final int timestampMs;

  /// True while the value shown came from the previous session's numbers and
  /// the user hasn't confirmed it by checking the set off yet. Purely a UI
  /// hint so pre-filled figures look different from ones you typed.
  final bool prefilled;

  /// True for an exercise added to this one workout on the day, outside the
  /// routine (e.g. bench press slipped into a back day). These rows have no
  /// [exerciseDefId], so this flag is what keeps them from being mistaken
  /// for rows orphaned by a deleted routine exercise. Within a session an
  /// ad-hoc exercise is identified by its name and type.
  final bool adhoc;

  /// When this set was ticked off, or null while it isn't. The gap between
  /// two consecutive sets of the same exercise is the rest shown between
  /// them — whatever else was done in the meantime.
  final int? checkedAtMs;

  SetLog({
    this.id,
    required this.sessionId,
    required this.exerciseDefId,
    required this.exerciseName,
    required this.type,
    required this.setIndex,
    required this.checked,
    this.weightKg,
    this.reps,
    this.holdSeconds,
    this.cardioSeconds,
    this.cardioDistanceKm,
    this.prefilled = false,
    this.adhoc = false,
    this.checkedAtMs,
    int? timestampMs,
  }) : timestampMs = timestampMs ?? DateTime.now().millisecondsSinceEpoch;

  /// Which exercise card this row belongs to within its session: the routine
  /// exercise's id, or name + type for an ad-hoc exercise. Null for a row
  /// whose routine exercise has since been deleted.
  String? get exerciseKey {
    if (adhoc) return adhocKey(exerciseName, type);
    return exerciseDefId == null ? null : routineKey(exerciseDefId!);
  }

  static String routineKey(int exerciseDefId) => 'r:$exerciseDefId';
  static String adhocKey(String name, TrackingType type) => 'a:${type.dbValue}:$name';

  /// Whether this set carries the numbers its tracking type requires.
  bool get hasRequiredValue {
    switch (type) {
      case TrackingType.weights:
        return weightKg != null && weightKg! > 0 && reps != null && reps! > 0;
      case TrackingType.reps:
        return reps != null && reps! > 0;
      case TrackingType.time:
        return holdSeconds != null && holdSeconds! > 0;
      case TrackingType.cardio:
        return (cardioSeconds != null && cardioSeconds! > 0) ||
            (cardioDistanceKm != null && cardioDistanceKm! > 0);
      case TrackingType.none:
        return true;
    }
  }

  /// Pass a value to set it, pass `null` to clear it, omit it to keep it.
  SetLog copyWith({
    bool? checked,
    Object? weightKg = _unset,
    Object? reps = _unset,
    Object? holdSeconds = _unset,
    Object? cardioSeconds = _unset,
    Object? cardioDistanceKm = _unset,
    bool? prefilled,
    int? setIndex,
    Object? checkedAtMs = _unset,
  }) =>
      SetLog(
        id: id,
        sessionId: sessionId,
        exerciseDefId: exerciseDefId,
        exerciseName: exerciseName,
        type: type,
        setIndex: setIndex ?? this.setIndex,
        checked: checked ?? this.checked,
        weightKg: identical(weightKg, _unset) ? this.weightKg : weightKg as double?,
        reps: identical(reps, _unset) ? this.reps : reps as int?,
        holdSeconds: identical(holdSeconds, _unset) ? this.holdSeconds : holdSeconds as int?,
        cardioSeconds:
            identical(cardioSeconds, _unset) ? this.cardioSeconds : cardioSeconds as int?,
        cardioDistanceKm: identical(cardioDistanceKm, _unset)
            ? this.cardioDistanceKm
            : cardioDistanceKm as double?,
        prefilled: prefilled ?? this.prefilled,
        adhoc: adhoc,
        checkedAtMs: identical(checkedAtMs, _unset) ? this.checkedAtMs : checkedAtMs as int?,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'session_id': sessionId,
        'exercise_def_id': exerciseDefId,
        'exercise_name': exerciseName,
        'type': type.dbValue,
        'set_index': setIndex,
        'checked': checked ? 1 : 0,
        'weight_kg': weightKg,
        'reps': reps,
        'hold_seconds': holdSeconds,
        'cardio_seconds': cardioSeconds,
        'cardio_distance_km': cardioDistanceKm,
        'prefilled': prefilled ? 1 : 0,
        'adhoc': adhoc ? 1 : 0,
        'checked_at': checkedAtMs,
        'timestamp': timestampMs,
      };

  factory SetLog.fromMap(Map<String, Object?> map) => SetLog(
        id: map['id'] as int?,
        sessionId: map['session_id'] as int,
        exerciseDefId: map['exercise_def_id'] as int?,
        exerciseName: map['exercise_name'] as String,
        type: TrackingTypeX.fromDbValue(map['type'] as String),
        setIndex: map['set_index'] as int,
        checked: (map['checked'] as int) == 1,
        weightKg: (map['weight_kg'] as num?)?.toDouble(),
        reps: (map['reps'] as num?)?.toInt(),
        holdSeconds: (map['hold_seconds'] as num?)?.toInt(),
        cardioSeconds: (map['cardio_seconds'] as num?)?.toInt(),
        cardioDistanceKm: (map['cardio_distance_km'] as num?)?.toDouble(),
        prefilled: (map['prefilled'] as int?) == 1,
        adhoc: (map['adhoc'] as int?) == 1,
        checkedAtMs: (map['checked_at'] as num?)?.toInt(),
        timestampMs: map['timestamp'] as int,
      );
}

/// Whole seconds between ticking off one set and ticking off the next, or
/// null if either wasn't timed (or the clock went backwards).
int? restSecondsBetween(int? earlierCheckedAtMs, int? laterCheckedAtMs) {
  if (earlierCheckedAtMs == null || laterCheckedAtMs == null) return null;
  if (laterCheckedAtMs < earlierCheckedAtMs) return null;
  return ((laterCheckedAtMs - earlierCheckedAtMs) / 1000).round();
}
