import 'dart:convert';

import '../models/routine.dart';

/// Thrown with a human-readable message the Import screen can show directly.
class ImportException implements Exception {
  final String message;
  ImportException(this.message);
  @override
  String toString() => message;
}

class ParsedImport {
  final String? routineName;
  final List<DayWithExercises> days;
  ParsedImport({required this.routineName, required this.days});
}

/// Copy/pasteable template shown on the Import screen. Feed this to an LLM
/// (or fill it in yourself) with a prompt like:
/// "Fill in this JSON template with my workout plan: <describe your split>"
const String kImportJsonTemplate = '''
{
  "routineName": "Push Pull Legs",
  "days": [
    { "day": 1, "name": "Push", "exercises": [
      { "name": "Bench Press", "type": "weights", "sets": 4 },
      { "name": "Overhead Press", "type": "weights", "sets": 3 },
      { "name": "Plank", "type": "time", "sets": 3 }
    ]},
    { "day": 2, "name": "Pull", "exercises": [
      { "name": "Deadlift", "type": "weights", "sets": 3 },
      { "name": "Pull Up", "type": "reps", "sets": 3 },
      { "name": "Lat Pulldown", "type": "weights", "sets": 3 }
    ]},
    { "day": 3, "name": "Legs", "exercises": [
      { "name": "Squat", "type": "weights", "sets": 4 },
      { "name": "Calf Raise", "type": "weights", "sets": 3 }
    ]},
    { "day": 4, "name": "Push", "exercises": [
      { "name": "Incline Bench Press", "type": "weights", "sets": 4 }
    ]},
    { "day": 5, "name": "Pull", "exercises": [
      { "name": "Barbell Row", "type": "weights", "sets": 4 }
    ]},
    { "day": 6, "name": "Cardio", "exercises": [
      { "name": "Treadmill Run", "type": "cardio", "sets": 1 }
    ]},
    { "day": 7, "name": "Rest", "exercises": [] }
  ]
}
''';

/// type must be exactly one of: weights | reps | time | cardio | none
/// sets is optional for "none"/rest entries (defaults to 1).
const String kImportCsvTemplate = '''
day,dayName,exercise,type,sets
1,Push,Bench Press,weights,4
1,Push,Overhead Press,weights,3
1,Push,Plank,time,3
2,Pull,Deadlift,weights,3
2,Pull,Pull Up,reps,3
2,Pull,Lat Pulldown,weights,3
3,Legs,Squat,weights,4
3,Legs,Calf Raise,weights,3
4,Push,Incline Bench Press,weights,4
5,Pull,Barbell Row,weights,4
6,Cardio,Treadmill Run,cardio,1
7,Rest,,none,1
''';

/// A ready-made prompt to hand an LLM along with your plain-text plan. Keeping
/// it in the app means the format rules and the parser can never drift apart.
String llmPrompt() => '''
Convert my workout plan into the exact JSON format below. Rules:
- Output ONLY the JSON, no commentary, no markdown code fences.
- Include all 7 days. Days I don't train are rest days: give them a name like
  "Rest" and an empty "exercises" array.
- "type" must be exactly one of:
    "weights" - lifted weight and reps
    "reps"    - a count only, for bodyweight work (push-ups, pull-ups, dips)
    "time"    - a timed hold, logged as min:sec (planks, dead hangs, stretches)
    "cardio"  - time and/or distance
    "none"    - no numbers, just tick the set off
  Use "reps" for any bodyweight exercise where weight would be meaningless.
- "sets" is a whole number.
- Keep each exercise's name spelled identically everywhere it appears, so its
  history stays on one chart.

Format:
$kImportJsonTemplate

My plan:
''';

/// Parses either the JSON template or the CSV template. Auto-detects format
/// by attempting JSON first. Throws [ImportException] with a message the UI
/// can show verbatim on any problem.
ParsedImport parseImportText(String rawText) {
  final text = rawText.trim();
  if (text.isEmpty) {
    throw ImportException('Paste some text first.');
  }
  if (text.startsWith('{')) {
    return _parseJson(text);
  }
  return _parseCsv(text);
}

ParsedImport _parseJson(String text) {
  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (e) {
    throw ImportException('That doesn\'t look like valid JSON: $e');
  }
  if (decoded is! Map || decoded['days'] is! List) {
    throw ImportException('JSON must have a top-level "days" array.');
  }
  final routineName = decoded['routineName'] as String?;
  final daysRaw = decoded['days'] as List;

  final Map<int, DayWithExercises> byIndex = {};
  for (final entry in daysRaw) {
    if (entry is! Map) {
      throw ImportException('Each item in "days" must be an object.');
    }
    final dayIndex = _asInt(entry['day']);
    if (dayIndex == null || dayIndex < 1 || dayIndex > 7) {
      throw ImportException(
          'Each day needs a "day" number from 1 to 7 (found: ${entry['day']}).');
    }
    final dayName = (entry['name'] as String?)?.trim();
    if (dayName == null || dayName.isEmpty) {
      throw ImportException('Day $dayIndex is missing a "name".');
    }
    final exercisesRaw = (entry['exercises'] as List?) ?? const [];
    final exercises = <ExerciseDef>[];
    for (var i = 0; i < exercisesRaw.length; i++) {
      final exRaw = exercisesRaw[i];
      if (exRaw is! Map) {
        throw ImportException('Exercises must be objects (day $dayIndex).');
      }
      final name = (exRaw['name'] as String?)?.trim();
      if (name == null || name.isEmpty) {
        throw ImportException('An exercise on day $dayIndex is missing a "name".');
      }
      final type = TrackingTypeX.fromDbValue((exRaw['type'] as String?) ?? 'none');
      final sets = _asInt(exRaw['sets']) ?? 1;
      exercises.add(ExerciseDef(
        routineDayId: 0, // filled in by DBHelper.importRoutine
        name: name,
        type: type,
        targetSets: sets < 1 ? 1 : sets,
        sortOrder: i,
      ));
    }
    byIndex[dayIndex] = DayWithExercises(
      day: RoutineDay(routineId: 0, dayIndex: dayIndex, dayName: dayName),
      exercises: exercises,
    );
  }

  _assertAllSevenDays(byIndex);
  return ParsedImport(
    routineName: routineName,
    days: [for (var i = 1; i <= 7; i++) byIndex[i]!],
  );
}

ParsedImport _parseCsv(String text) {
  final lines = text
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.isEmpty) {
    throw ImportException('No CSV rows found.');
  }
  // Skip a header row if present.
  var startIndex = 0;
  if (lines.first.toLowerCase().startsWith('day,')) {
    startIndex = 1;
  }

  final Map<int, DayWithExercises> byIndex = {};
  for (var li = startIndex; li < lines.length; li++) {
    final row = _splitCsvRow(lines[li]);
    if (row.length < 4) {
      throw ImportException(
          'Row ${li + 1} needs at least day,dayName,exercise,type columns: "${lines[li]}"');
    }
    final dayIndex = _asInt(row[0]);
    if (dayIndex == null || dayIndex < 1 || dayIndex > 7) {
      throw ImportException('Row ${li + 1}: "day" must be a number from 1 to 7.');
    }
    final dayName = row[1].trim();
    if (dayName.isEmpty) {
      throw ImportException('Row ${li + 1}: dayName is missing.');
    }
    final exerciseName = row[2].trim();
    final type = TrackingTypeX.fromDbValue(row[3].trim());
    final sets = row.length > 4 ? (_asInt(row[4]) ?? 1) : 1;

    final existing = byIndex[dayIndex] ??
        DayWithExercises(
          day: RoutineDay(routineId: 0, dayIndex: dayIndex, dayName: dayName),
          exercises: [],
        );
    if (exerciseName.isNotEmpty) {
      existing.exercises.add(ExerciseDef(
        routineDayId: 0,
        name: exerciseName,
        type: type,
        targetSets: sets < 1 ? 1 : sets,
        sortOrder: existing.exercises.length,
      ));
    }
    byIndex[dayIndex] = existing;
  }

  _assertAllSevenDays(byIndex);
  return ParsedImport(
    routineName: null,
    days: [for (var i = 1; i <= 7; i++) byIndex[i]!],
  );
}

void _assertAllSevenDays(Map<int, DayWithExercises> byIndex) {
  final missing = [for (var i = 1; i <= 7; i++) i].where((i) => !byIndex.containsKey(i));
  if (missing.isNotEmpty) {
    throw ImportException(
        'Missing day(s) ${missing.join(', ')} — a routine needs all 7 days '
        '(use type "none" with 0 exercises for rest days).');
  }
}

List<String> _splitCsvRow(String line) {
  // Minimal CSV splitter: handles plain comma-separated values and
  // "quoted, values" (no embedded-quote escaping needed for this template).
  final result = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') {
      inQuotes = !inQuotes;
    } else if (c == ',' && !inQuotes) {
      result.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(c);
    }
  }
  result.add(buffer.toString());
  return result;
}

int? _asInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString().trim());
}

/// Pretty-printed JSON export text, ready to save/share.
String encodeExport(Map<String, Object?> data) {
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert(data);
}
