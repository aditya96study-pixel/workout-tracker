import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:workout_tracker/db/db_helper.dart';
import 'package:workout_tracker/models/routine.dart';
import 'package:workout_tracker/models/workout_log.dart';
import 'package:workout_tracker/services/app_dates.dart';
import 'package:workout_tracker/services/history_import.dart';
import 'package:workout_tracker/services/import_export.dart';

final db = DBHelper.instance;

Future<String> dbFilePath() async => join(await getDatabasesPath(), 'workout_tracker.db');

Future<void> freshDatabase() async {
  await db.closeForTesting();
  final path = await dbFilePath();
  final file = File(path);
  if (file.existsSync()) file.deleteSync();
}

/// A routine whose day 1 ("Back") has Row ×3 and Curl ×2, and whose day 2
/// ("Legs") has Squat ×3. Returns the days.
Future<List<RoutineDay>> seedRoutine() async {
  final routineId = await db.createRoutine('Split', dayNames: [
    'Back', 'Legs', 'Rest', 'Rest', 'Rest', 'Rest', 'Rest',
  ]);
  await db.setActiveRoutine(routineId);
  final days = await db.getDays(routineId);
  await db.addExercise(ExerciseDef(
      routineDayId: days[0].id!, name: 'Row', type: TrackingType.weights, targetSets: 3, sortOrder: 0));
  await db.addExercise(ExerciseDef(
      routineDayId: days[0].id!, name: 'Curl', type: TrackingType.weights, targetSets: 2, sortOrder: 1));
  await db.addExercise(ExerciseDef(
      routineDayId: days[1].id!, name: 'Squat', type: TrackingType.weights, targetSets: 3, sortOrder: 0));
  return days;
}

Future<WorkoutSession> openDay(RoutineDay day, {String? date}) async {
  final exercises = await db.getExercises(day.id!);
  return db.getOrCreateSession(date ?? todayYmd(), day, 'Split', exercises);
}

/// Ticks [log] off with numbers, at a chosen moment.
Future<SetLog> tick(SetLog log, {required int atMs, double kg = 50, int reps = 8}) async {
  final updated = log.copyWith(
    checked: true,
    prefilled: false,
    weightKg: kg,
    reps: reps,
    checkedAtMs: atMs,
  );
  await db.updateSetLog(updated);
  await db.recomputeSessionStatus(log.sessionId);
  return updated;
}

List<SetLog> adhocRows(List<SetLog> logs, String name) =>
    logs.where((l) => l.adhoc && l.exerciseName == name).toList()
      ..sort((a, b) => a.setIndex.compareTo(b.setIndex));

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Test files run in parallel; each needs its own database file.
    await databaseFactory.setDatabasesPath(
        Directory.systemTemp.createTempSync('workout_tracker_test').path);
  });

  setUp(freshDatabase);
  tearDownAll(() => db.closeForTesting());

  group('schema', () {
    test('a fresh install has the new set_logs columns', () async {
      final d = await db.database;
      final cols = (await d.rawQuery('PRAGMA table_info(set_logs)')).map((r) => r['name']).toSet();
      expect(cols, containsAll(['adhoc', 'checked_at']));
      expect(await d.getVersion(), 3);
    });

    test('upgrading from v2 keeps existing workouts readable', () async {
      // Build a v2 database exactly as the previous release would have.
      final path = await dbFilePath();
      final v2 = await databaseFactoryFfi.openDatabase(path,
          options: OpenDatabaseOptions(
            version: 2,
            onCreate: (d, _) async {
              await d.execute('CREATE TABLE routines (id INTEGER PRIMARY KEY AUTOINCREMENT, '
                  'name TEXT NOT NULL, is_active INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL)');
              await d.execute('CREATE TABLE routine_days (id INTEGER PRIMARY KEY AUTOINCREMENT, '
                  'routine_id INTEGER NOT NULL, day_index INTEGER NOT NULL, day_name TEXT NOT NULL)');
              await d.execute('CREATE TABLE exercises (id INTEGER PRIMARY KEY AUTOINCREMENT, '
                  'routine_day_id INTEGER NOT NULL, name TEXT NOT NULL, type TEXT NOT NULL, '
                  'target_sets INTEGER NOT NULL, sort_order INTEGER NOT NULL)');
              await d.execute('CREATE TABLE sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, '
                  "date TEXT NOT NULL, week_start TEXT NOT NULL DEFAULT '', routine_day_id INTEGER, "
                  "day_name TEXT NOT NULL, routine_name TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'draft', "
                  'created_at INTEGER NOT NULL, completed_at INTEGER, auto_completed INTEGER NOT NULL DEFAULT 0)');
              await d.execute('CREATE TABLE set_logs (id INTEGER PRIMARY KEY AUTOINCREMENT, '
                  'session_id INTEGER NOT NULL, exercise_def_id INTEGER, exercise_name TEXT NOT NULL, '
                  'type TEXT NOT NULL, set_index INTEGER NOT NULL, checked INTEGER NOT NULL DEFAULT 0, '
                  'weight_kg REAL, reps INTEGER, hold_seconds INTEGER, cardio_seconds INTEGER, '
                  'cardio_distance_km REAL, prefilled INTEGER NOT NULL DEFAULT 0, timestamp INTEGER NOT NULL)');
              await d.execute('CREATE TABLE weeks (id INTEGER PRIMARY KEY AUTOINCREMENT, '
                  'week_start TEXT NOT NULL UNIQUE, routine_id INTEGER, routine_name TEXT NOT NULL, '
                  "plan_json TEXT NOT NULL DEFAULT '[]', status TEXT NOT NULL DEFAULT 'open', "
                  'closed_at INTEGER, auto_closed INTEGER NOT NULL DEFAULT 0)');
              await d.execute('CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
            },
          ));
      final sid = await v2.insert('sessions', {
        'date': '2026-10-01', 'week_start': '2026-09-28', 'routine_day_id': null,
        'day_name': 'Push', 'routine_name': 'Old', 'status': 'completed',
        'created_at': 1, 'completed_at': 2, 'auto_completed': 0,
      });
      await v2.insert('set_logs', {
        'session_id': sid, 'exercise_def_id': null, 'exercise_name': 'Plank', 'type': 'time',
        'set_index': 1, 'checked': 1, 'hold_seconds': 75, 'prefilled': 0, 'timestamp': 3,
      });
      await v2.close();

      final logs = await db.getCompletedLogsForSession(sid);
      expect(logs, hasLength(1));
      expect(logs.single.holdSeconds, 75);
      expect(logs.single.adhoc, isFalse);
      expect(logs.single.checkedAtMs, isNull);
      expect(await (await db.database).getVersion(), 3);
      // Untimed history means no previous rest — not a crash.
      expect(await db.getPreviousRestSeconds('Plank', TrackingType.time), isEmpty);
    });
  });

  group('exercises added for one workout', () {
    test('are added without touching the routine', () async {
      final days = await seedRoutine();
      final session = await openDay(days[0]);
      await db.addAdhocExercise(
          sessionId: session.id!, name: 'Bench Press', type: TrackingType.weights, sets: 3);

      final logs = await db.getSetLogsForSession(session.id!);
      final bench = adhocRows(logs, 'Bench Press');
      expect(bench.map((l) => l.setIndex), [1, 2, 3]);
      expect(bench.every((l) => l.exerciseDefId == null && !l.checked), isTrue);
      expect(logs.where((l) => !l.adhoc), hasLength(5)); // Row ×3 + Curl ×2

      // The routine itself is unchanged.
      final routineExercises = await db.getExercises(days[0].id!);
      expect(routineExercises.map((e) => e.name), ['Row', 'Curl']);
      // ...and so is this week's plan.
      final week = await db.getWeek(currentWeekStart());
      expect(week!.plan.firstWhere((p) => p.dayId == days[0].id).exerciseCount, 2);
    });

    test('survive reopening the day (orphan cleanup leaves them alone)', () async {
      final days = await seedRoutine();
      final session = await openDay(days[0]);
      await db.addAdhocExercise(
          sessionId: session.id!, name: 'Bench Press', type: TrackingType.weights, sets: 2);
      final bench = adhocRows(await db.getSetLogsForSession(session.id!), 'Bench Press');
      await tick(bench.first, atMs: 1000);

      // A genuinely orphaned row (its routine exercise deleted) still goes.
      await (await db.database).insert('set_logs', SetLog(
        sessionId: session.id!, exerciseDefId: null, exerciseName: 'Gone',
        type: TrackingType.weights, setIndex: 1, checked: true, weightKg: 1, reps: 1,
      ).toMap());

      final reopened = await openDay(days[0]);
      expect(reopened.id, session.id);
      final logs = await db.getSetLogsForSession(session.id!);
      expect(adhocRows(logs, 'Bench Press'), hasLength(2));
      expect(logs.where((l) => l.exerciseName == 'Gone'), isEmpty);
      expect(reopened.status, SessionStatus.active);
    });

    test('keep a draft alive when switching to another day', () async {
      final days = await seedRoutine();
      final back = await openDay(days[0]);
      await db.addAdhocExercise(
          sessionId: back.id!, name: 'Bench Press', type: TrackingType.weights, sets: 1);
      await openDay(days[1]); // switching days discards untouched drafts
      expect(await db.getSession(back.id!), isNotNull);
      final logs = await db.getSetLogsForSession(back.id!);
      expect(adhocRows(logs, 'Bench Press'), hasLength(1));
    });

    test('count towards history, charts and next time\'s pre-fill', () async {
      final days = await seedRoutine();
      final session = await openDay(days[0], date: '2026-10-19');
      await db.addAdhocExercise(
          sessionId: session.id!, name: 'Bench Press', type: TrackingType.weights, sets: 2);
      final bench = adhocRows(await db.getSetLogsForSession(session.id!), 'Bench Press');
      await tick(bench[0], atMs: 10000, kg: 80, reps: 8);
      await tick(bench[1], atMs: 100000, kg: 82.5, reps: 6);
      await db.completeSession(session.id!);

      expect(await db.getTrackableExerciseNames(), contains('Bench Press'));
      final history = await db.getHistoryForExercise('Bench Press');
      expect(history.map((r) => r['weight_kg']), [80, 82.5]);
      final completed = await db.getCompletedLogsForSession(session.id!);
      expect(completed.where((l) => l.adhoc), hasLength(2));

      // Next time Bench Press shows up — here as part of a different day —
      // last time's numbers carry forward.
      final legs = await openDay(days[1], date: '2026-10-21');
      await db.addAdhocExercise(
          sessionId: legs.id!, name: 'Bench Press', type: TrackingType.weights, sets: 3);
      final next = adhocRows(await db.getSetLogsForSession(legs.id!), 'Bench Press');
      expect(next.map((l) => l.weightKg), [80, 82.5, 82.5]);
      expect(next.every((l) => l.prefilled), isTrue);
    });

    test('can be removed again, releasing the workout lock', () async {
      final days = await seedRoutine();
      final session = await openDay(days[0]);
      await db.addAdhocExercise(
          sessionId: session.id!, name: 'Bench Press', type: TrackingType.weights, sets: 2);
      final bench = adhocRows(await db.getSetLogsForSession(session.id!), 'Bench Press');
      await tick(bench.first, atMs: 1);
      expect((await db.getInProgressSession())?.id, session.id);

      await db.deleteAdhocExercise(
          sessionId: session.id!, name: 'Bench Press', type: TrackingType.weights);
      await db.recomputeSessionStatus(session.id!);
      expect(adhocRows(await db.getSetLogsForSession(session.id!), 'Bench Press'), isEmpty);
      expect(await db.getInProgressSession(), isNull);
      // Routine rows untouched.
      expect(await db.getSetLogsForSession(session.id!), hasLength(5));
    });

    test('does not count against the week plan', () async {
      final days = await seedRoutine();
      final session = await openDay(days[0]);
      await db.addAdhocExercise(
          sessionId: session.id!, name: 'Bench Press', type: TrackingType.weights, sets: 1);
      final bench = adhocRows(await db.getSetLogsForSession(session.id!), 'Bench Press');
      await tick(bench.single, atMs: 1);
      await db.completeSession(session.id!);

      final summary = (await db.getWeekSummaries()).firstWhere(
          (w) => w.week.weekStart == currentWeekStart());
      final back = summary.outcomes.firstWhere((o) => o.dayName == 'Back');
      expect(back.done, 1);
      expect(back.planned, 1);
    });

    test('known types prefer the routine definition, then history', () async {
      final days = await seedRoutine();
      final session = await openDay(days[0]);
      await db.addAdhocExercise(
          sessionId: session.id!, name: 'Plank', type: TrackingType.time, sets: 1);
      final types = await db.getKnownExerciseTypes();
      expect(types['Plank'], TrackingType.time);
      expect(types['Row'], TrackingType.weights);
    });
  });

  group('rest between sets', () {
    test('ticking records the time and completing keeps it', () async {
      final days = await seedRoutine();
      final session = await openDay(days[0], date: '2026-10-19');
      final rows = (await db.getSetLogsForSession(session.id!))
          .where((l) => l.exerciseName == 'Row')
          .toList()
        ..sort((a, b) => a.setIndex.compareTo(b.setIndex));

      // Row sets ticked at 0:00, 1:30 and 3:20 — with Curl sets in between,
      // as in a superset. The Curl ticks mustn't affect Row's rest times.
      await tick(rows[0], atMs: 1000000);
      final curls = (await db.getSetLogsForSession(session.id!))
          .where((l) => l.exerciseName == 'Curl')
          .toList()
        ..sort((a, b) => a.setIndex.compareTo(b.setIndex));
      await tick(curls[0], atMs: 1045000);
      await tick(rows[1], atMs: 1090000);
      await tick(curls[1], atMs: 1150000);
      await tick(rows[2], atMs: 1200000);
      await db.completeSession(session.id!);

      expect(await db.getPreviousRestSeconds('Row', TrackingType.weights), {2: 90, 3: 110});
      expect(await db.getPreviousRestSeconds('Curl', TrackingType.weights), {2: 105});
    });

    test('previous rest comes from the most recent completed workout', () async {
      final days = await seedRoutine();
      final older = await openDay(days[0], date: '2026-10-12');
      var rows = (await db.getSetLogsForSession(older.id!))
          .where((l) => l.exerciseName == 'Curl')
          .toList()
        ..sort((a, b) => a.setIndex.compareTo(b.setIndex));
      await tick(rows[0], atMs: 0);
      await tick(rows[1], atMs: 60000);
      await db.completeSession(older.id!);

      final newer = await openDay(days[0], date: '2026-10-19');
      rows = (await db.getSetLogsForSession(newer.id!))
          .where((l) => l.exerciseName == 'Curl')
          .toList()
        ..sort((a, b) => a.setIndex.compareTo(b.setIndex));
      await tick(rows[0], atMs: 0);
      await tick(rows[1], atMs: 135000);
      await db.completeSession(newer.id!);

      expect(await db.getPreviousRestSeconds('Curl', TrackingType.weights), {2: 135});

      // A workout still in progress is not "previous".
      final today = await openDay(days[0], date: '2026-10-26');
      rows = (await db.getSetLogsForSession(today.id!))
          .where((l) => l.exerciseName == 'Curl')
          .toList()
        ..sort((a, b) => a.setIndex.compareTo(b.setIndex));
      await tick(rows[0], atMs: 0);
      await tick(rows[1], atMs: 10000);
      expect(await db.getPreviousRestSeconds('Curl', TrackingType.weights), {2: 135});
    });

    test('a set left without numbers is unticked and loses its time on completion', () async {
      final days = await seedRoutine();
      final session = await openDay(days[0]);
      final row = (await db.getSetLogsForSession(session.id!))
          .firstWhere((l) => l.exerciseName == 'Row' && l.setIndex == 1);
      await db.updateSetLog(row.copyWith(checked: true, weightKg: null, reps: null, checkedAtMs: 5));
      await db.completeSession(session.id!);
      final after = (await db.getSetLogsForSession(session.id!)).firstWhere((l) => l.id == row.id);
      expect(after.checked, isFalse);
      expect(after.checkedAtMs, isNull);
    });

    test('editing numbers after ticking keeps the tick time', () {
      final log = SetLog(
        sessionId: 1, exerciseDefId: 1, exerciseName: 'Row', type: TrackingType.weights,
        setIndex: 1, checked: true, weightKg: 50, reps: 8, checkedAtMs: 1234,
      );
      expect(log.copyWith(weightKg: 52.5).checkedAtMs, 1234);
      expect(log.copyWith(checked: false, checkedAtMs: null).checkedAtMs, isNull);
    });
  });

  group('routine edited while a workout is open', () {
    test('a type change follows into today\'s sets so they can be ticked', () async {
      final days = await seedRoutine();
      final session = await openDay(days[0]);
      final curl = (await db.getExercises(days[0].id!)).firstWhere((e) => e.name == 'Curl');

      // Switch Curl from weights to time, and rename it, mid-workout.
      await db.updateExercise(curl.copyWith(name: 'Dead Hang', type: TrackingType.time));
      await openDay(days[0]);

      final rows = (await db.getSetLogsForSession(session.id!))
          .where((l) => l.exerciseDefId == curl.id)
          .toList();
      expect(rows, hasLength(2));
      expect(rows.every((l) => l.type == TrackingType.time), isTrue);
      expect(rows.every((l) => l.exerciseName == 'Dead Hang'), isTrue);
      // And with a time entered, the set is tickable.
      expect(rows.first.copyWith(holdSeconds: 40).hasRequiredValue, isTrue);
    });

    test('completed workouts keep the name and type they were done with', () async {
      final days = await seedRoutine();
      final session = await openDay(days[0], date: '2026-10-19');
      final row = (await db.getSetLogsForSession(session.id!))
          .firstWhere((l) => l.exerciseName == 'Curl' && l.setIndex == 1);
      await tick(row, atMs: 1);
      await db.completeSession(session.id!);

      final curl = (await db.getExercises(days[0].id!)).firstWhere((e) => e.name == 'Curl');
      await db.updateExercise(curl.copyWith(name: 'Hammer Curl'));
      await openDay(days[0], date: '2026-10-26');

      final done = await db.getCompletedLogsForSession(session.id!);
      expect(done.single.exerciseName, 'Curl');
    });
  });

  group('imports keep each exercise together', () {
    test('CSV rows interleaved by set come out grouped by exercise', () {
      final parsed = parseHistory('''
date,day,exercise,type,set,weight,reps,seconds,distance
2026-08-03,Push,Bench Press,weights,1,60,8,,
2026-08-03,Push,Plank,time,1,,,45,
2026-08-03,Push,Bench Press,weights,2,62.5,6,,
2026-08-03,Push,Plank,time,2,,,50,
''');
      final sets = parsed.sessions.single.sets;
      expect(sets.map((s) => '${s.exerciseName} ${s.setIndex}'),
          ['Bench Press 1', 'Bench Press 2', 'Plank 1', 'Plank 2']);
    });

    test('a restored backup shows one block per exercise in History', () async {
      final days = await seedRoutine();
      final session = await openDay(days[0], date: '2026-10-19');
      SetLog pick(List<SetLog> logs, String n, int i) =>
          logs.firstWhere((l) => l.exerciseName == n && l.setIndex == i);
      final logs = await db.getSetLogsForSession(session.id!);
      // Superset order: Row 1, Curl 1, Row 2, Curl 2.
      await tick(pick(logs, 'Row', 1), atMs: 1);
      await tick(pick(logs, 'Curl', 1), atMs: 2);
      await tick(pick(logs, 'Row', 2), atMs: 3);
      await tick(pick(logs, 'Curl', 2), atMs: 4);
      await db.completeSession(session.id!);

      final backup = encodeExport(await db.exportAllData());
      await freshDatabase();
      await db.importHistory(parseHistory(backup).sessions);

      final restored = (await db.getWeekSummaries())
          .expand((w) => w.sessions)
          .single;
      final rows = await db.getCompletedLogsForSession(restored.id!);
      expect(rows.map((l) => '${l.exerciseName} ${l.setIndex}'),
          ['Row 1', 'Row 2', 'Curl 1', 'Curl 2']);
    });
  });

  group('backup round trip', () {
    test('export then import keeps added exercises and tick times', () async {
      final days = await seedRoutine();
      final session = await openDay(days[0], date: '2026-10-19');
      await db.addAdhocExercise(
          sessionId: session.id!, name: 'Bench Press', type: TrackingType.weights, sets: 2);
      final bench = adhocRows(await db.getSetLogsForSession(session.id!), 'Bench Press');
      await tick(bench[0], atMs: 1000);
      await tick(bench[1], atMs: 76000);
      await db.completeSession(session.id!);

      final exported = encodeExport(await db.exportAllData());
      final parsed = parseHistory(exported);

      await freshDatabase();
      final result = await db.importHistory(parsed.sessions);
      expect(result.sessionsImported, 1);
      expect(await db.getHistoryForExercise('Bench Press'), hasLength(2));
      expect(await db.getPreviousRestSeconds('Bench Press', TrackingType.weights), {2: 75});
    });

    test('CSV import accepts min:sec in the seconds column', () {
      final parsed = parseHistory('''
date,day,exercise,type,set,weight,reps,seconds,distance
2026-08-03,Core,Plank,time,1,,,1:30,
2026-08-07,Cardio,Run,cardio,1,,,30:00,5.2
2026-08-07,Cardio,Run,cardio,2,,,600,1
''');
      final sets = parsed.sessions.expand((s) => s.sets).toList();
      expect(sets[0].holdSeconds, 90);
      expect(sets[1].cardioSeconds, 1800);
      expect(sets[2].cardioSeconds, 600);
    });
  });
}
