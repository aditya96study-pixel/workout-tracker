import 'dart:convert';

import '../models/routine.dart';
import 'time_format.dart';

/// Thrown with a message the import screen shows verbatim.
class HistoryImportException implements Exception {
  final String message;
  HistoryImportException(this.message);
  @override
  String toString() => message;
}

/// One logged set, as read out of a backup or a spreadsheet.
class ImportedSet {
  final String exerciseName;
  final TrackingType type;
  final int setIndex;
  final double? weightKg;
  final int? reps;
  final int? holdSeconds;
  final int? cardioSeconds;
  final double? cardioDistanceKm;

  /// When the set was ticked off, if the source recorded it (backups do).
  /// Keeps rest times between sets working after a restore.
  final int? checkedAtMs;

  ImportedSet({
    required this.exerciseName,
    required this.type,
    required this.setIndex,
    this.weightKg,
    this.reps,
    this.holdSeconds,
    this.cardioSeconds,
    this.cardioDistanceKm,
    this.checkedAtMs,
  });
}

/// One day's workout, as read out of a backup or a spreadsheet.
class ImportedSession {
  final String date; // 'yyyy-MM-dd'
  final String dayName;
  final String routineName;
  final List<ImportedSet> sets;

  ImportedSession({
    required this.date,
    required this.dayName,
    required this.routineName,
    required this.sets,
  });
}

class ParsedHistory {
  final List<ImportedSession> sessions;
  final List<String> warnings;
  final String sourceLabel; // 'backup file' / 'CSV'

  ParsedHistory({
    required this.sessions,
    required this.warnings,
    required this.sourceLabel,
  });

  int get totalSets => sessions.fold(0, (n, s) => n + s.sets.length);

  String? get firstDate =>
      sessions.isEmpty ? null : (sessions.map((s) => s.date).toList()..sort()).first;
  String? get lastDate =>
      sessions.isEmpty ? null : (sessions.map((s) => s.date).toList()..sort()).last;

  Set<String> get exerciseNames =>
      {for (final s in sessions) for (final e in s.sets) e.exerciseName};
}

/// The CSV shape the import screen offers for copying.
const String kHistoryCsvTemplate = '''
date,day,exercise,type,set,weight,reps,seconds,distance
2026-08-03,Push,Bench Press,weights,1,60,8,,
2026-08-03,Push,Bench Press,weights,2,62.5,6,,
2026-08-03,Push,Plank,time,1,,,45,
2026-08-05,Pull,Pull Up,reps,1,,12,,
2026-08-05,Pull,Pull Up,reps,2,,10,,
2026-08-07,Cardio,Treadmill Run,cardio,1,,,1800,5.2
''';

/// Prompt for handing a messy workout log to an LLM and getting this CSV back.
String historyCsvPrompt() => '''
Convert my workout log into the exact CSV format below. Rules:
- Output ONLY the CSV, starting with the header row. No commentary, no code fences.
- One row per set. A 3-set exercise becomes 3 rows.
- "date" must be YYYY-MM-DD.
- "day" is the workout name for that date (Push, Pull, Legs, ...). If I don't
  say, use a sensible label or leave it blank.
- "type" must be one of: weights, reps, time, cardio, none.
    weights - weight and reps       -> fill "weight" and "reps"
    reps    - bodyweight count only -> fill "reps"
    time    - a timed hold          -> fill "seconds"
    cardio  - a run/ride            -> fill "seconds" and/or "distance" (km)
  "seconds" can be whole seconds (90) or minutes:seconds (1:30).
- Leave cells blank when they don't apply. Never invent numbers I didn't give.
- Weight is in kilograms. Spell each exercise name identically every time.

Format:
$kHistoryCsvTemplate

My log:
''';

/// Auto-detects a JSON backup vs a CSV and parses accordingly.
ParsedHistory parseHistory(String rawText) {
  final text = rawText.trim();
  if (text.isEmpty) {
    throw HistoryImportException('That file is empty.');
  }
  if (text.startsWith('{') || text.startsWith('[')) {
    return _parseBackupJson(text);
  }
  return _parseHistoryCsv(text);
}

// ---------------------------------------------------------------------------
// The app's own export file
// ---------------------------------------------------------------------------

ParsedHistory _parseBackupJson(String text) {
  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (e) {
    throw HistoryImportException('That doesn\'t look like a valid backup file: $e');
  }
  if (decoded is! Map) {
    throw HistoryImportException('A backup file should be a JSON object.');
  }

  final sessionRows = (decoded['sessions'] as List?) ?? const [];
  final logRows = (decoded['setLogs'] as List?) ?? const [];
  if (sessionRows.isEmpty) {
    throw HistoryImportException(
        'No workouts in that file. Make sure it came from Settings → Export history.');
  }

  final warnings = <String>[];

  // Logs reference their session by the id it had in the old database.
  final logsBySession = <Object, List<Map>>{};
  for (final raw in logRows) {
    if (raw is! Map) continue;
    if ((raw['checked'] as num?)?.toInt() != 1) continue;
    final sid = raw['session_id'];
    if (sid == null) continue;
    logsBySession.putIfAbsent(sid, () => []).add(raw);
  }

  final sessions = <ImportedSession>[];
  for (final raw in sessionRows) {
    if (raw is! Map) continue;
    final date = _normaliseDate(raw['date']?.toString());
    if (date == null) {
      warnings.add('Skipped a workout with an unreadable date (${raw['date']}).');
      continue;
    }
    final logs = logsBySession[raw['id']] ?? const [];
    if (logs.isEmpty) continue; // nothing was actually recorded

    final sets = <ImportedSet>[];
    for (final l in logs) {
      final name = (l['exercise_name'] as String?)?.trim();
      if (name == null || name.isEmpty) continue;
      sets.add(ImportedSet(
        exerciseName: name,
        type: TrackingTypeX.fromDbValue((l['type'] as String?) ?? 'none'),
        setIndex: (l['set_index'] as num?)?.toInt() ?? 1,
        weightKg: (l['weight_kg'] as num?)?.toDouble(),
        reps: (l['reps'] as num?)?.toInt(),
        holdSeconds: (l['hold_seconds'] as num?)?.toInt(),
        cardioSeconds: (l['cardio_seconds'] as num?)?.toInt(),
        cardioDistanceKm: (l['cardio_distance_km'] as num?)?.toDouble(),
        checkedAtMs: (l['checked_at'] as num?)?.toInt(),
      ));
    }
    if (sets.isEmpty) continue;
    sets.sort((a, b) => a.setIndex.compareTo(b.setIndex));

    sessions.add(ImportedSession(
      date: date,
      dayName: (raw['day_name'] as String?)?.trim().isNotEmpty == true
          ? (raw['day_name'] as String).trim()
          : 'Imported',
      routineName: (raw['routine_name'] as String?)?.trim().isNotEmpty == true
          ? (raw['routine_name'] as String).trim()
          : 'Imported',
      sets: sets,
    ));
  }

  if (sessions.isEmpty) {
    throw HistoryImportException('That backup has no completed workouts in it.');
  }
  return ParsedHistory(
      sessions: sessions, warnings: warnings, sourceLabel: 'backup file');
}

// ---------------------------------------------------------------------------
// Spreadsheet CSV
// ---------------------------------------------------------------------------

const _aliases = <String, List<String>>{
  'date': ['date', 'day_date', 'workoutdate', 'workout_date'],
  'day': ['day', 'dayname', 'day_name', 'workout', 'split'],
  'exercise': ['exercise', 'name', 'movement', 'lift'],
  'type': ['type', 'tracking', 'trackingtype', 'tracking_type'],
  'set': ['set', 'setindex', 'set_index', 'setno', 'set_no', 'setnumber'],
  'weight': ['weight', 'weightkg', 'weight_kg', 'kg', 'load'],
  'reps': ['reps', 'rep', 'count', 'counts', 'repetitions'],
  'seconds': ['seconds', 'secs', 'sec', 'time', 'duration', 'holdseconds', 'hold_seconds'],
  'distance': ['distance', 'distancekm', 'distance_km', 'km'],
  'routine': ['routine', 'routinename', 'routine_name', 'plan'],
};

ParsedHistory _parseHistoryCsv(String text) {
  final lines = text
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.length < 2) {
    throw HistoryImportException(
        'That CSV needs a header row and at least one row of data.');
  }

  // Header-driven, so column order doesn't matter and extra columns are fine.
  final header = splitCsvRow(lines.first).map((h) => _key(h)).toList();
  final col = <String, int>{};
  for (final entry in _aliases.entries) {
    for (var i = 0; i < header.length; i++) {
      if (entry.value.contains(header[i])) {
        col[entry.key] = i;
        break;
      }
    }
  }
  if (!col.containsKey('date') || !col.containsKey('exercise')) {
    throw HistoryImportException(
        'The header row needs at least a "date" column and an "exercise" column. '
        'Found: ${header.join(', ')}');
  }

  String? cell(List<String> row, String name) {
    final i = col[name];
    if (i == null || i >= row.length) return null;
    final v = row[i].trim();
    return v.isEmpty ? null : v;
  }

  final warnings = <String>[];
  // Preserves the order dates first appear, so the preview reads naturally.
  final grouped = <String, List<ImportedSet>>{};
  final meta = <String, List<String>>{}; // key -> [date, dayName, routineName]
  final autoIndex = <String, int>{}; // key + exercise -> running set number

  for (var i = 1; i < lines.length; i++) {
    final row = splitCsvRow(lines[i]);
    final rawDate = cell(row, 'date');
    final date = _normaliseDate(rawDate);
    if (date == null) {
      warnings.add('Row ${i + 1}: skipped, unreadable date "${rawDate ?? ''}".');
      continue;
    }
    final exercise = cell(row, 'exercise');
    if (exercise == null) {
      warnings.add('Row ${i + 1}: skipped, no exercise name.');
      continue;
    }

    final weight = _toDouble(cell(row, 'weight'));
    final reps = _toInt(cell(row, 'reps'));
    final seconds = parseDurationText(cell(row, 'seconds'));
    final distance = _toDouble(cell(row, 'distance'));

    final typeText = cell(row, 'type');
    final type = typeText != null
        ? TrackingTypeX.fromDbValue(typeText)
        : _inferType(weight: weight, reps: reps, seconds: seconds, distance: distance);

    final dayName = cell(row, 'day') ?? 'Imported';
    final key = '$date|$dayName';
    meta.putIfAbsent(key, () => [date, dayName, cell(row, 'routine') ?? 'Imported']);

    final idxKey = '$key|$exercise';
    final explicitIndex = _toInt(cell(row, 'set'));
    final setIndex = explicitIndex ?? ((autoIndex[idxKey] ?? 0) + 1);
    autoIndex[idxKey] = setIndex;

    grouped.putIfAbsent(key, () => []).add(ImportedSet(
          exerciseName: exercise,
          type: type,
          setIndex: setIndex,
          // Only keep the fields this type actually uses, so a stray column
          // can't smuggle a distance onto a bench press.
          weightKg: type == TrackingType.weights ? weight : null,
          reps: (type == TrackingType.weights || type == TrackingType.reps) ? reps : null,
          holdSeconds: type == TrackingType.time ? seconds : null,
          cardioSeconds: type == TrackingType.cardio ? seconds : null,
          cardioDistanceKm: type == TrackingType.cardio ? distance : null,
        ));
  }

  if (grouped.isEmpty) {
    throw HistoryImportException(
        'No usable rows found.${warnings.isEmpty ? '' : ' ${warnings.first}'}');
  }

  final sessions = <ImportedSession>[];
  for (final entry in grouped.entries) {
    final m = meta[entry.key]!;
    final sets = entry.value..sort((a, b) => a.setIndex.compareTo(b.setIndex));
    sessions.add(ImportedSession(
      date: m[0],
      dayName: m[1],
      routineName: m[2],
      sets: sets,
    ));
  }
  sessions.sort((a, b) => a.date.compareTo(b.date));
  return ParsedHistory(sessions: sessions, warnings: warnings, sourceLabel: 'CSV');
}

TrackingType _inferType({
  double? weight,
  int? reps,
  int? seconds,
  double? distance,
}) {
  if (distance != null) return TrackingType.cardio;
  if (weight != null && reps != null) return TrackingType.weights;
  if (weight != null) return TrackingType.weights;
  if (reps != null) return TrackingType.reps;
  if (seconds != null) return TrackingType.time;
  return TrackingType.none;
}

String _key(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');

/// Accepts `2026-08-03` and day-first `03/08/2026` or `03-08-2026`.
///
/// Day-first is assumed for the slash/dash forms rather than month-first,
/// and the import screen states that plainly and shows the resulting date
/// range — silently guessing the wrong way round would corrupt every date in
/// the file with nothing on screen to catch it.
String? _normaliseDate(String? raw) {
  if (raw == null) return null;
  final t = raw.trim();
  if (t.isEmpty) return null;

  final iso = RegExp(r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})').firstMatch(t);
  if (iso != null) {
    return _build(int.parse(iso.group(1)!), int.parse(iso.group(2)!), int.parse(iso.group(3)!));
  }
  final dmy = RegExp(r'^(\d{1,2})[-/](\d{1,2})[-/](\d{4})$').firstMatch(t);
  if (dmy != null) {
    return _build(int.parse(dmy.group(3)!), int.parse(dmy.group(2)!), int.parse(dmy.group(1)!));
  }
  return null;
}

String? _build(int y, int m, int d) {
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  // Round-trip through DateTime so 31 February is rejected rather than stored.
  final dt = DateTime(y, m, d);
  if (dt.year != y || dt.month != m || dt.day != d) return null;
  return '${y.toString().padLeft(4, '0')}-'
      '${m.toString().padLeft(2, '0')}-'
      '${d.toString().padLeft(2, '0')}';
}

double? _toDouble(String? s) {
  if (s == null) return null;
  final v = double.tryParse(s.replaceAll(',', '.'));
  if (v == null || v < 0 || v.isNaN || v.isInfinite) return null;
  return v;
}

int? _toInt(String? s) {
  if (s == null) return null;
  final v = int.tryParse(s) ?? double.tryParse(s)?.round();
  if (v == null || v < 0) return null;
  return v;
}

/// Minimal CSV field splitter: plain commas, plus "quoted, fields".
List<String> splitCsvRow(String line) {
  final result = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') {
      if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
        buffer.write('"');
        i++;
      } else {
        inQuotes = !inQuotes;
      }
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

/// Outcome of writing a parsed history into the database.
class HistoryImportResult {
  final int sessionsImported;
  final int setsImported;

  /// Workouts already on record for that date and day name. Re-importing the
  /// same file is therefore harmless — it adds nothing the second time.
  final List<String> skipped;

  HistoryImportResult({
    required this.sessionsImported,
    required this.setsImported,
    required this.skipped,
  });
}
