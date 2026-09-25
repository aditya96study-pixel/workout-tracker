/// Core routine data models.
///
/// A Routine is a named 7-day plan (e.g. "Push Pull Legs").
/// Each Routine has exactly 7 RoutineDay entries (dayIndex 1..7, Mon..Sun by
/// convention but the label is whatever the user typed, e.g. "Push", "Rest").
/// Each RoutineDay has an ordered list of ExerciseDef entries.

enum TrackingType { weights, reps, time, cardio, none }

extension TrackingTypeX on TrackingType {
  String get label {
    switch (this) {
      case TrackingType.weights:
        return 'Weights';
      case TrackingType.reps:
        return 'Reps';
      case TrackingType.time:
        return 'Time';
      case TrackingType.cardio:
        return 'Cardio';
      case TrackingType.none:
        return 'None';
    }
  }

  /// Stable string stored in the database / used in JSON import so renaming
  /// the enum later never breaks old data.
  String get dbValue => name;

  static TrackingType fromDbValue(String value) {
    switch (value.trim().toLowerCase()) {
      case 'weights':
      case 'weight':
        return TrackingType.weights;
      case 'reps':
      case 'rep':
      case 'bodyweight':
      case 'bw':
      case 'count':
      case 'counts':
        return TrackingType.reps;
      case 'time':
      case 'hold':
        return TrackingType.time;
      case 'cardio':
        return TrackingType.cardio;
      case 'none':
      default:
        return TrackingType.none;
    }
  }
}

class Routine {
  final int? id;
  final String name;
  final bool isActive;
  final int createdAtMs;

  Routine({
    this.id,
    required this.name,
    this.isActive = false,
    int? createdAtMs,
  }) : createdAtMs = createdAtMs ?? DateTime.now().millisecondsSinceEpoch;

  Routine copyWith({int? id, String? name, bool? isActive}) => Routine(
        id: id ?? this.id,
        name: name ?? this.name,
        isActive: isActive ?? this.isActive,
        createdAtMs: createdAtMs,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'is_active': isActive ? 1 : 0,
        'created_at': createdAtMs,
      };

  factory Routine.fromMap(Map<String, Object?> map) => Routine(
        id: map['id'] as int?,
        name: map['name'] as String,
        isActive: (map['is_active'] as int) == 1,
        createdAtMs: map['created_at'] as int,
      );
}

class RoutineDay {
  final int? id;
  final int routineId;
  final int dayIndex; // 1..7
  final String dayName; // e.g. "Push", "Rest"

  RoutineDay({
    this.id,
    required this.routineId,
    required this.dayIndex,
    required this.dayName,
  });

  RoutineDay copyWith({int? id, int? routineId, int? dayIndex, String? dayName}) =>
      RoutineDay(
        id: id ?? this.id,
        routineId: routineId ?? this.routineId,
        dayIndex: dayIndex ?? this.dayIndex,
        dayName: dayName ?? this.dayName,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'routine_id': routineId,
        'day_index': dayIndex,
        'day_name': dayName,
      };

  factory RoutineDay.fromMap(Map<String, Object?> map) => RoutineDay(
        id: map['id'] as int?,
        routineId: map['routine_id'] as int,
        dayIndex: map['day_index'] as int,
        dayName: map['day_name'] as String,
      );
}

class ExerciseDef {
  final int? id;
  final int routineDayId;
  final String name;
  final TrackingType type;
  final int targetSets;
  final int sortOrder;

  ExerciseDef({
    this.id,
    required this.routineDayId,
    required this.name,
    required this.type,
    required this.targetSets,
    required this.sortOrder,
  });

  ExerciseDef copyWith({
    int? id,
    int? routineDayId,
    String? name,
    TrackingType? type,
    int? targetSets,
    int? sortOrder,
  }) =>
      ExerciseDef(
        id: id ?? this.id,
        routineDayId: routineDayId ?? this.routineDayId,
        name: name ?? this.name,
        type: type ?? this.type,
        targetSets: targetSets ?? this.targetSets,
        sortOrder: sortOrder ?? this.sortOrder,
      );

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'routine_day_id': routineDayId,
        'name': name,
        'type': type.dbValue,
        'target_sets': targetSets,
        'sort_order': sortOrder,
      };

  factory ExerciseDef.fromMap(Map<String, Object?> map) => ExerciseDef(
        id: map['id'] as int?,
        routineDayId: map['routine_day_id'] as int,
        name: map['name'] as String,
        type: TrackingTypeX.fromDbValue(map['type'] as String),
        targetSets: map['target_sets'] as int,
        sortOrder: map['sort_order'] as int,
      );
}

/// Convenience bundle used by the routine editor and rapid-import feature:
/// a day plus the exercises that belong to it, before/after they have ids.
class DayWithExercises {
  final RoutineDay day;
  final List<ExerciseDef> exercises;

  DayWithExercises({required this.day, required this.exercises});
}
