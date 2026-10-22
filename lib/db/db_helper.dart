import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/routine.dart';
import '../models/week.dart';
import '../models/workout_log.dart';
import '../services/app_dates.dart';
import '../services/history_import.dart';

/// Single source of truth for all local persistence. Everything in this app
/// lives in one SQLite file on-device (`workout_tracker.db`) — nothing ever
/// leaves the phone.
///
/// Every user action writes through to SQLite immediately rather than being
/// held in memory and flushed later. That's what makes the app crash-safe:
/// if Android kills the process mid-workout, the most you can lose is the
/// keystroke you were typing.
class DBHelper {
  DBHelper._internal();
  static final DBHelper instance = DBHelper._internal();

  /// Bumped to 2 in the "complete workout / weekly history" release, and to 3
  /// for exercises added on the day plus rest times between sets.
  static const int schemaVersion = 3;

  Database? _db;

  /// The open in progress, if any. Two callers at startup — the theme and
  /// the app state both read settings immediately — share it, so the
  /// database is opened, and migrated, exactly once.
  Future<Database>? _opening;

  Future<Database> get database async {
    final open = _db;
    if (open != null) return open;
    return _db = await (_opening ??= _initDB());
  }

  /// Closes and forgets the open database so a test can start fresh.
  @visibleForTesting
  Future<void> closeForTesting() async {
    final pending = _opening;
    _db = null;
    _opening = null;
    if (pending != null) await (await pending).close();
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'workout_tracker.db');
    return openDatabase(
      path,
      version: schemaVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  // ---------------------------------------------------------------------
  // Schema
  // ---------------------------------------------------------------------

  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();

    batch.execute('''
      CREATE TABLE routines (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE routine_days (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        routine_id INTEGER NOT NULL,
        day_index INTEGER NOT NULL,
        day_name TEXT NOT NULL,
        FOREIGN KEY (routine_id) REFERENCES routines (id) ON DELETE CASCADE
      )
    ''');

    batch.execute('''
      CREATE TABLE exercises (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        routine_day_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        target_sets INTEGER NOT NULL,
        sort_order INTEGER NOT NULL,
        FOREIGN KEY (routine_day_id) REFERENCES routine_days (id) ON DELETE CASCADE
      )
    ''');

    batch.execute('''
      CREATE TABLE sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        date TEXT NOT NULL,
        week_start TEXT NOT NULL DEFAULT '',
        routine_day_id INTEGER,
        day_name TEXT NOT NULL,
        routine_name TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'draft',
        created_at INTEGER NOT NULL,
        completed_at INTEGER,
        auto_completed INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (routine_day_id) REFERENCES routine_days (id) ON DELETE SET NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE set_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        exercise_def_id INTEGER,
        exercise_name TEXT NOT NULL,
        type TEXT NOT NULL,
        set_index INTEGER NOT NULL,
        checked INTEGER NOT NULL DEFAULT 0,
        weight_kg REAL,
        reps INTEGER,
        hold_seconds INTEGER,
        cardio_seconds INTEGER,
        cardio_distance_km REAL,
        prefilled INTEGER NOT NULL DEFAULT 0,
        adhoc INTEGER NOT NULL DEFAULT 0,
        checked_at INTEGER,
        timestamp INTEGER NOT NULL,
        FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE,
        FOREIGN KEY (exercise_def_id) REFERENCES exercises (id) ON DELETE SET NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE weeks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        week_start TEXT NOT NULL UNIQUE,
        routine_id INTEGER,
        routine_name TEXT NOT NULL,
        plan_json TEXT NOT NULL DEFAULT '[]',
        status TEXT NOT NULL DEFAULT 'open',
        closed_at INTEGER,
        auto_closed INTEGER NOT NULL DEFAULT 0
      )
    ''');

    batch.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    _createIndexes(batch);
    await batch.commit(noResult: true);
  }

  void _createIndexes(Batch batch) {
    batch.execute('CREATE INDEX IF NOT EXISTS idx_days_routine ON routine_days (routine_id)');
    batch.execute('CREATE INDEX IF NOT EXISTS idx_exercises_day ON exercises (routine_day_id)');
    batch.execute('CREATE INDEX IF NOT EXISTS idx_sessions_date ON sessions (date)');
    batch.execute('CREATE INDEX IF NOT EXISTS idx_sessions_week ON sessions (week_start)');
    batch.execute('CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions (status)');
    batch.execute('CREATE INDEX IF NOT EXISTS idx_logs_session ON set_logs (session_id)');
    batch.execute('CREATE INDEX IF NOT EXISTS idx_logs_exercise_name ON set_logs (exercise_name)');
  }

  /// v1 → v2. Adds the workout-lifecycle columns and the weeks table, then
  /// backfills sensible values for data logged under v1.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v1 had no notion of an unfinished workout, so everything already in
      // the table was, by definition, finished — hence the 'completed'
      // default here versus 'draft' in _onCreate. SQLite can't alter a column
      // default without rebuilding the table, so upgraded and fresh installs
      // keep different defaults forever. Harmless only because every insert
      // path passes `status` explicitly; keep it that way.
      await db.execute(
          "ALTER TABLE sessions ADD COLUMN status TEXT NOT NULL DEFAULT 'completed'");
      await db.execute("ALTER TABLE sessions ADD COLUMN week_start TEXT NOT NULL DEFAULT ''");
      await db.execute('ALTER TABLE sessions ADD COLUMN completed_at INTEGER');
      await db.execute(
          'ALTER TABLE sessions ADD COLUMN auto_completed INTEGER NOT NULL DEFAULT 0');
      await db.execute(
          'ALTER TABLE set_logs ADD COLUMN prefilled INTEGER NOT NULL DEFAULT 0');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS weeks (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          week_start TEXT NOT NULL UNIQUE,
          routine_id INTEGER,
          routine_name TEXT NOT NULL,
          plan_json TEXT NOT NULL DEFAULT '[]',
          status TEXT NOT NULL DEFAULT 'open',
          closed_at INTEGER,
          auto_closed INTEGER NOT NULL DEFAULT 0
        )
      ''');

      // A v1 session with nothing checked off was an artifact of merely
      // opening a day, not a workout. Drop those rather than import them as
      // phantom completed workouts.
      await db.execute('''
        DELETE FROM sessions WHERE id NOT IN (
          SELECT DISTINCT session_id FROM set_logs WHERE checked = 1
        )
      ''');

      // Derive each surviving session's Monday. SQLite's 'weekday 0' modifier
      // advances to the next Sunday, so backing off 6 days lands on that
      // week's Monday for every day of the week.
      await db.execute(
          "UPDATE sessions SET week_start = date(date, 'weekday 0', '-6 days')");
      await db.execute('UPDATE sessions SET completed_at = created_at WHERE completed_at IS NULL');

      // Give historical weeks a row so they show up in the new History tab.
      // Their plan is recorded as empty because v1 never captured one — the
      // UI says so explicitly rather than inventing a plan retroactively.
      final now = DateTime.now().millisecondsSinceEpoch;
      final thisWeek = currentWeekStart();
      await db.rawInsert('''
        INSERT OR IGNORE INTO weeks
          (week_start, routine_id, routine_name, plan_json, status, closed_at, auto_closed)
        SELECT week_start, NULL, MIN(routine_name), '[]', 'closed', ?, 1
        FROM sessions
        WHERE week_start != '' AND week_start != ?
        GROUP BY week_start
      ''', [now, thisWeek]);

      final batch = db.batch();
      _createIndexes(batch);
      await batch.commit(noResult: true);
    }
    if (oldVersion < 3) {
      // Both columns are additive. Existing rows read as routine rows with no
      // recorded tick time, which simply means no rest time is shown for them.
      await db.execute('ALTER TABLE set_logs ADD COLUMN adhoc INTEGER NOT NULL DEFAULT 0');
      await db.execute('ALTER TABLE set_logs ADD COLUMN checked_at INTEGER');
    }
  }

  // ---------------------------------------------------------------------
  // Routines
  // ---------------------------------------------------------------------

  static const defaultDayNames = [
    'Day 1', 'Day 2', 'Day 3', 'Day 4', 'Day 5', 'Day 6', 'Day 7',
  ];

  /// Creates a routine with exactly 7 days. Returns the new routine id.
  Future<int> createRoutine(String name, {List<String>? dayNames}) async {
    final db = await database;
    final names = dayNames ?? defaultDayNames;
    assert(names.length == 7, 'A routine must have exactly 7 days');
    late int routineId;
    await db.transaction((txn) async {
      routineId = await txn.insert('routines', Routine(name: name).toMap());
      for (var i = 0; i < 7; i++) {
        await txn.insert('routine_days', {
          'routine_id': routineId,
          'day_index': i + 1,
          'day_name': names[i],
        });
      }
    });
    return routineId;
  }

  Future<List<Routine>> getRoutines() async {
    final db = await database;
    final rows = await db.query('routines', orderBy: 'created_at ASC');
    return rows.map(Routine.fromMap).toList();
  }

  Future<Routine?> getRoutine(int routineId) async {
    final db = await database;
    final rows = await db.query('routines', where: 'id = ?', whereArgs: [routineId], limit: 1);
    if (rows.isEmpty) return null;
    return Routine.fromMap(rows.first);
  }

  Future<Routine?> getActiveRoutine() async {
    final db = await database;
    final rows = await db.query('routines', where: 'is_active = 1', limit: 1);
    if (rows.isEmpty) return null;
    return Routine.fromMap(rows.first);
  }

  /// Marks [routineId] as the single active routine (single-tap switch).
  Future<void> setActiveRoutine(int routineId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update('routines', {'is_active': 0});
      await txn.update('routines', {'is_active': 1}, where: 'id = ?', whereArgs: [routineId]);
    });
  }

  Future<void> renameRoutine(int routineId, String newName) async {
    final db = await database;
    await db.update('routines', {'name': newName}, where: 'id = ?', whereArgs: [routineId]);
  }

  Future<void> deleteRoutine(int routineId) async {
    final db = await database;
    await db.delete('routines', where: 'id = ?', whereArgs: [routineId]);
  }

  // ---------------------------------------------------------------------
  // Days & exercises
  // ---------------------------------------------------------------------

  Future<List<RoutineDay>> getDays(int routineId) async {
    final db = await database;
    final rows = await db.query('routine_days',
        where: 'routine_id = ?', whereArgs: [routineId], orderBy: 'day_index ASC');
    return rows.map(RoutineDay.fromMap).toList();
  }

  Future<void> renameDay(int dayId, String newName) async {
    final db = await database;
    await db.update('routine_days', {'day_name': newName}, where: 'id = ?', whereArgs: [dayId]);
  }

  Future<List<ExerciseDef>> getExercises(int dayId) async {
    final db = await database;
    final rows = await db.query('exercises',
        where: 'routine_day_id = ?', whereArgs: [dayId], orderBy: 'sort_order ASC');
    return rows.map(ExerciseDef.fromMap).toList();
  }

  Future<int> countExercises(int dayId) async {
    final db = await database;
    final result = await db
        .rawQuery('SELECT COUNT(*) AS c FROM exercises WHERE routine_day_id = ?', [dayId]);
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> addExercise(ExerciseDef ex) async {
    final db = await database;
    return db.insert('exercises', ex.toMap());
  }

  Future<void> updateExercise(ExerciseDef ex) async {
    final db = await database;
    await db.update('exercises', ex.toMap(), where: 'id = ?', whereArgs: [ex.id]);
  }

  Future<void> deleteExercise(int exerciseId) async {
    final db = await database;
    await db.delete('exercises', where: 'id = ?', whereArgs: [exerciseId]);
  }

  Future<void> reorderExercises(List<ExerciseDef> newOrder) async {
    final db = await database;
    final batch = db.batch();
    for (var i = 0; i < newOrder.length; i++) {
      batch.update('exercises', {'sort_order': i}, where: 'id = ?', whereArgs: [newOrder[i].id]);
    }
    await batch.commit(noResult: true);
  }

  /// Replaces [toDayId]'s exercises with a copy of [fromDayId]'s.
  ///
  /// Splits like Push/Pull/Legs repeat the same day twice a week, so building
  /// day 4 by hand after day 1 is pure retyping — and retyping is how exercise
  /// names drift apart and split their own history in two.
  Future<void> copyExercisesToDay(int fromDayId, int toDayId) async {
    final db = await database;
    final source = await getExercises(fromDayId);
    await db.transaction((txn) async {
      await txn.delete('exercises', where: 'routine_day_id = ?', whereArgs: [toDayId]);
      for (var i = 0; i < source.length; i++) {
        final e = source[i];
        await txn.insert('exercises', {
          'routine_day_id': toDayId,
          'name': e.name,
          'type': e.type.dbValue,
          'target_sets': e.targetSets,
          'sort_order': i,
        });
      }
    });
  }

  /// All distinct exercise names ever used in any routine — powers the
  /// autocomplete in the routine editor so the same lift is always spelled
  /// the same way, which is what keeps its history on one chart.
  Future<List<String>> getKnownExerciseNames() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT DISTINCT name FROM exercises
      UNION
      SELECT DISTINCT exercise_name AS name FROM set_logs
      ORDER BY name COLLATE NOCASE ASC
    ''');
    return rows.map((r) => r['name'] as String).toList();
  }

  // ---------------------------------------------------------------------
  // Rapid import — always creates a brand-new routine so nothing existing
  // is ever silently overwritten.
  // ---------------------------------------------------------------------

  Future<int> importRoutine(String routineName, List<DayWithExercises> days) async {
    final db = await database;
    assert(days.length == 7, 'Import must contain exactly 7 days');
    late int routineId;
    await db.transaction((txn) async {
      routineId = await txn.insert('routines', Routine(name: routineName).toMap());
      for (final d in days) {
        final dayId = await txn.insert('routine_days', {
          'routine_id': routineId,
          'day_index': d.day.dayIndex,
          'day_name': d.day.dayName,
        });
        for (var i = 0; i < d.exercises.length; i++) {
          final e = d.exercises[i];
          await txn.insert('exercises', {
            'routine_day_id': dayId,
            'name': e.name,
            'type': e.type.dbValue,
            'target_sets': e.targetSets,
            'sort_order': i,
          });
        }
      }
    });
    return routineId;
  }

  // ---------------------------------------------------------------------
  // Sessions — the workout lifecycle
  // ---------------------------------------------------------------------

  Future<WorkoutSession?> getSession(int sessionId) async {
    final db = await database;
    final rows = await db.query('sessions', where: 'id = ?', whereArgs: [sessionId], limit: 1);
    if (rows.isEmpty) return null;
    return WorkoutSession.fromMap(rows.first);
  }

  /// The one workout currently in progress, if any. Only ever returns an
  /// `active` session — this is what locks day switching on the Today screen.
  Future<WorkoutSession?> getInProgressSession() async {
    final db = await database;
    final rows = await db.query('sessions',
        where: 'status = ?', whereArgs: ['active'], orderBy: 'created_at DESC', limit: 1);
    if (rows.isEmpty) return null;
    return WorkoutSession.fromMap(rows.first);
  }

  /// Opens [day] for [date], resuming an existing session for that day/date
  /// if there is one and creating a fresh pre-filled draft if there isn't.
  ///
  /// Newly-added routine exercises are reconciled in on the way through, so
  /// editing your routine mid-week doesn't leave today's workout missing
  /// rows. Existing rows are never touched, which is what makes resuming an
  /// interrupted workout lossless.
  Future<WorkoutSession> getOrCreateSession(
    String date,
    RoutineDay day,
    String routineName,
    List<ExerciseDef> exercises,
  ) async {
    final db = await database;
    final weekStart = weekStartOfYmd(date);
    await ensureWeek(weekStart);

    final existingRows = await db.query(
      'sessions',
      where: 'date = ? AND routine_day_id = ?',
      whereArgs: [date, day.id],
      orderBy: 'created_at DESC',
      limit: 1,
    );

    if (existingRows.isNotEmpty) {
      final session = WorkoutSession.fromMap(existingRows.first);
      await _reconcileExercises(session, exercises);
      await _discardAbandonedDrafts(exceptId: session.id);
      // Reconciling can flip the status (e.g. dropping orphaned checked rows
      // takes a session back to draft), so re-read rather than hand back the
      // copy we loaded before that ran.
      return await getSession(session.id!) ?? session;
    }

    // Smart defaults are looked up before opening the transaction — they read
    // from the same database, and sqflite would deadlock on a nested read.
    final fills = <int, Map<int, Map<String, Object?>>>{};
    for (final ex in exercises) {
      if (ex.id != null) fills[ex.id!] = await _smartDefaultsFor(ex.name, ex.type);
    }

    late int sessionId;
    final now = DateTime.now().millisecondsSinceEpoch;
    // One transaction, so a process kill can never leave a session holding a
    // partial set of rows — it either exists complete or not at all.
    await db.transaction((txn) async {
      sessionId = await txn.insert('sessions', {
        'date': date,
        'week_start': weekStart,
        'routine_day_id': day.id,
        'day_name': day.dayName,
        'routine_name': routineName,
        'status': SessionStatus.draft.dbValue,
        'created_at': now,
        'completed_at': null,
        'auto_completed': 0,
      });
      for (final ex in exercises) {
        await _insertSetLogs(
          txn,
          sessionId,
          exerciseDefId: ex.id,
          name: ex.name,
          type: ex.type,
          defaults: fills[ex.id] ?? const {},
          fromIndex: 1,
          toIndex: ex.targetSets,
        );
      }
    });
    await _discardAbandonedDrafts(exceptId: sessionId);

    return WorkoutSession(
      id: sessionId,
      date: date,
      weekStart: weekStart,
      routineDayId: day.id,
      dayName: day.dayName,
      routineName: routineName,
      status: SessionStatus.draft,
    );
  }

  /// Brings an already-open session back in line with a routine that has been
  /// edited underneath it: new exercises gain rows, exercises whose set count
  /// went up are topped up, and rows orphaned by a deleted exercise are
  /// dropped.
  ///
  /// Dropping orphans matters more than it looks. `exercise_def_id` is
  /// ON DELETE SET NULL, so a deleted exercise leaves its checked rows behind;
  /// the Today screen can no longer render them, but they still count as
  /// "checked", which would pin the session in the `active` state and lock
  /// every day of the week with no reachable way to finish it.
  ///
  /// Exercises added on the day also have no `exercise_def_id`, but they are
  /// flagged `adhoc` and the Today screen renders them, so they're left alone.
  Future<void> _reconcileExercises(WorkoutSession session, List<ExerciseDef> exercises) async {
    if (session.isCompleted || session.id == null) return;
    final db = await database;

    await db.delete('set_logs',
        where: 'session_id = ? AND exercise_def_id IS NULL AND adhoc = 0',
        whereArgs: [session.id]);

    // An exercise renamed or switched to another tracking type in the
    // routine while today's workout was open must carry its rows along.
    // Otherwise the card asks for, say, a time while the set is checked for
    // reps and can never be ticked — and a rename would land in history
    // under the old name.
    for (final ex in exercises) {
      if (ex.id == null) continue;
      await db.update(
        'set_logs',
        {'exercise_name': ex.name, 'type': ex.type.dbValue},
        where: 'session_id = ? AND exercise_def_id = ? AND (exercise_name != ? OR type != ?)',
        whereArgs: [session.id, ex.id, ex.name, ex.type.dbValue],
      );
    }

    final rows = await db.rawQuery(
      'SELECT exercise_def_id AS id, MAX(set_index) AS top, COUNT(*) AS n '
      'FROM set_logs WHERE session_id = ? AND adhoc = 0 GROUP BY exercise_def_id',
      [session.id],
    );
    final topBy = <int, int>{};
    final countBy = <int, int>{};
    for (final r in rows) {
      final id = (r['id'] as num?)?.toInt();
      if (id == null) continue;
      topBy[id] = (r['top'] as num?)?.toInt() ?? 0;
      countBy[id] = (r['n'] as num?)?.toInt() ?? 0;
    }

    for (final ex in exercises) {
      if (ex.id == null) continue;
      final existingCount = countBy[ex.id] ?? 0;
      if (existingCount >= ex.targetSets) continue; // includes the 0-vs-0 case
      final defaults = await _smartDefaultsFor(ex.name, ex.type);
      final from = (topBy[ex.id] ?? 0) + 1;
      final needed = ex.targetSets - existingCount;
      await _insertSetLogs(
        db,
        session.id!,
        exerciseDefId: ex.id,
        name: ex.name,
        type: ex.type,
        defaults: defaults,
        fromIndex: from,
        toIndex: from + needed - 1,
      );
    }

    await recomputeSessionStatus(session.id!);
  }

  Future<void> _insertSetLogs(
    DatabaseExecutor db,
    int sessionId, {
    required int? exerciseDefId,
    required String name,
    required TrackingType type,
    required Map<int, Map<String, Object?>> defaults,
    required int fromIndex,
    required int toIndex,
    bool adhoc = false,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var s = fromIndex; s <= toIndex; s++) {
      // Only carry a row forward if a number relevant to *this* tracking type
      // actually came through. Otherwise the row is flagged pre-filled while
      // every box on screen is empty, and the UI promises carried-forward
      // values that aren't there.
      final values = _relevantDefaults(_pickDefaultForSet(defaults, s), type);
      final prefilled = values.isNotEmpty;

      await db.insert('set_logs', {
        'session_id': sessionId,
        'exercise_def_id': exerciseDefId,
        'exercise_name': name,
        'type': type.dbValue,
        'set_index': s,
        'checked': 0,
        'weight_kg': values['weight_kg'],
        'reps': values['reps'],
        'hold_seconds': values['hold_seconds'],
        'cardio_seconds': values['cardio_seconds'],
        'cardio_distance_km': values['cardio_distance_km'],
        'prefilled': prefilled ? 1 : 0,
        'adhoc': adhoc ? 1 : 0,
        'checked_at': null,
        'timestamp': now,
      });
    }
  }

  /// [fill] if it carries a value this tracking type actually uses, else an
  /// empty map — which reads back as "no defaults" for every column.
  Map<String, Object?> _relevantDefaults(Map<String, Object?>? fill, TrackingType type) {
    if (fill == null) return const {};
    final relevant = switch (type) {
      TrackingType.weights => fill['weight_kg'] != null || fill['reps'] != null,
      TrackingType.reps => fill['reps'] != null,
      TrackingType.time => fill['hold_seconds'] != null,
      TrackingType.cardio =>
        fill['cardio_seconds'] != null || fill['cardio_distance_km'] != null,
      TrackingType.none => false,
    };
    return relevant ? fill : const {};
  }

  /// Drops a non-completed session for a day that has become a rest day, so
  /// emptying a day mid-workout releases the day lock instead of stranding it.
  Future<void> discardOpenSessionForDay(String date, int routineDayId) async {
    final db = await database;
    await db.delete(
      'sessions',
      where: 'date = ? AND routine_day_id = ? AND status != ?',
      whereArgs: [date, routineDayId, SessionStatus.completed.dbValue],
    );
  }

  /// Deletes drafts the user walked away from without entering anything.
  ///
  /// A draft where numbers were typed by hand, or an exercise was added for
  /// the day, is kept, so flicking between days to check your plan never
  /// throws away work in progress.
  Future<void> _discardAbandonedDrafts({int? exceptId}) async {
    final db = await database;
    await db.rawDelete('''
      DELETE FROM sessions
      WHERE status = 'draft'
        AND id != ?
        AND id NOT IN (
          SELECT DISTINCT session_id FROM set_logs
          WHERE checked = 1
             OR adhoc = 1
             OR (prefilled = 0 AND (
                  weight_kg IS NOT NULL OR reps IS NOT NULL OR hold_seconds IS NOT NULL
                  OR cardio_seconds IS NOT NULL OR cardio_distance_km IS NOT NULL))
        )
    ''', [exceptId ?? -1]);
  }

  /// Re-derives draft vs active from whether anything is checked off.
  /// Completed sessions are left alone. Returns the resulting status.
  Future<SessionStatus> recomputeSessionStatus(int sessionId) async {
    final db = await database;
    final session = await getSession(sessionId);
    if (session == null) return SessionStatus.draft;
    if (session.isCompleted) return SessionStatus.completed;

    final result = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM set_logs WHERE session_id = ? AND checked = 1',
      [sessionId],
    );
    final checked = Sqflite.firstIntValue(result) ?? 0;
    final next = checked > 0 ? SessionStatus.active : SessionStatus.draft;
    if (next != session.status) {
      await db.update('sessions', {'status': next.dbValue},
          where: 'id = ?', whereArgs: [sessionId]);
    }
    return next;
  }

  /// Finishes a workout. [auto] marks it as closed by the midnight rollover
  /// rather than by the user.
  Future<void> completeSession(int sessionId, {bool auto = false}) async {
    final db = await database;

    // Tick-then-clear leaves a checked set with no numbers. The Today screen
    // deliberately doesn't react to that while you're typing, so it's cleaned
    // up here instead: a set with nothing in it wasn't performed, and letting
    // it through would put a blank row in history and a null in the charts.
    await db.rawUpdate('''
      UPDATE set_logs SET checked = 0, checked_at = NULL
      WHERE session_id = ? AND checked = 1 AND (
             (type = 'weights' AND (weight_kg IS NULL OR weight_kg <= 0
                                    OR reps IS NULL OR reps <= 0))
          OR (type = 'reps' AND (reps IS NULL OR reps <= 0))
          OR (type = 'time' AND (hold_seconds IS NULL OR hold_seconds <= 0))
          OR (type = 'cardio' AND (cardio_seconds IS NULL OR cardio_seconds <= 0)
                              AND (cardio_distance_km IS NULL OR cardio_distance_km <= 0))
      )
    ''', [sessionId]);

    await db.update(
      'sessions',
      {
        'status': SessionStatus.completed.dbValue,
        'completed_at': DateTime.now().millisecondsSinceEpoch,
        'auto_completed': auto ? 1 : 0,
      },
      where: 'id = ?',
      whereArgs: [sessionId],
    );
    // Numbers that were only ever pre-filled and never confirmed shouldn't
    // masquerade as typed data once the workout is in the books.
    await db.update(
      'set_logs',
      {'prefilled': 0},
      where: 'session_id = ? AND checked = 1',
      whereArgs: [sessionId],
    );
  }

  /// Re-opens a completed workout for editing (typo fixes after the fact).
  Future<void> reopenSession(int sessionId) async {
    final db = await database;
    await db.update(
      'sessions',
      {'status': SessionStatus.active.dbValue, 'completed_at': null, 'auto_completed': 0},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
    await recomputeSessionStatus(sessionId);
  }

  Future<void> deleteSession(int sessionId) async {
    final db = await database;
    await db.delete('sessions', where: 'id = ?', whereArgs: [sessionId]);
  }

  /// Midnight rollover, also run at every app start and resume.
  ///
  /// A workout left running past midnight is banked against the day it was
  /// actually performed, so your history stays honest even if the phone was
  /// off for three days. Untouched drafts from previous days are dropped —
  /// nothing was done in them.
  ///
  /// Returns how many sessions were auto-completed, so the UI can tell you.
  Future<int> rolloverStaleSessions({String? today}) async {
    final db = await database;
    final cutoff = today ?? todayYmd();
    final now = DateTime.now().millisecondsSinceEpoch;

    final banked = await db.rawUpdate('''
      UPDATE sessions
      SET status = 'completed', completed_at = ?, auto_completed = 1
      WHERE status = 'active' AND date < ?
    ''', [now, cutoff]);

    await db.rawDelete("DELETE FROM sessions WHERE status = 'draft' AND date < ?", [cutoff]);

    await autoCloseFinishedWeeks();
    return banked;
  }

  // ---------------------------------------------------------------------
  // Set logs
  // ---------------------------------------------------------------------

  Future<List<SetLog>> getSetLogsForSession(int sessionId) async {
    final db = await database;
    final rows = await db.query('set_logs',
        where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'set_index ASC, id ASC');
    return rows.map(SetLog.fromMap).toList();
  }

  Future<void> updateSetLog(SetLog log) async {
    final db = await database;
    await db.update('set_logs', log.toMap(), where: 'id = ?', whereArgs: [log.id]);
  }

  /// Writes several set rows in one batch — used by the checkbox cascade so
  /// unchecking set 2 of 5 can't half-apply if the app dies mid-write.
  Future<void> updateSetLogs(List<SetLog> logs) async {
    if (logs.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final log in logs) {
      batch.update('set_logs', log.toMap(), where: 'id = ?', whereArgs: [log.id]);
    }
    await batch.commit(noResult: true);
  }

  /// Adds one more set to an in-progress session, beyond the routine default.
  Future<SetLog> addExtraSetLog(SetLog template) async {
    final db = await database;
    final id = await db.insert('set_logs', template.toMap());
    return SetLog(
      id: id,
      sessionId: template.sessionId,
      exerciseDefId: template.exerciseDefId,
      exerciseName: template.exerciseName,
      type: template.type,
      setIndex: template.setIndex,
      checked: false,
      weightKg: template.weightKg,
      reps: template.reps,
      holdSeconds: template.holdSeconds,
      cardioSeconds: template.cardioSeconds,
      cardioDistanceKm: template.cardioDistanceKm,
      prefilled: template.prefilled,
      adhoc: template.adhoc,
    );
  }

  Future<void> deleteSetLog(int logId) async {
    final db = await database;
    await db.delete('set_logs', where: 'id = ?', whereArgs: [logId]);
  }

  // ---------------------------------------------------------------------
  // Exercises added on the day
  // ---------------------------------------------------------------------

  /// Adds [name] to one workout only, without touching the routine. Its sets
  /// are pre-filled from the last time it was done, like any other exercise,
  /// and once ticked they count towards history and charts like any other.
  Future<void> addAdhocExercise({
    required int sessionId,
    required String name,
    required TrackingType type,
    required int sets,
  }) async {
    final db = await database;
    // Read before the transaction opens — a nested read deadlocks sqflite.
    final defaults = await _smartDefaultsFor(name, type);
    await db.transaction((txn) async {
      await _insertSetLogs(
        txn,
        sessionId,
        exerciseDefId: null,
        name: name,
        type: type,
        defaults: defaults,
        fromIndex: 1,
        toIndex: sets,
        adhoc: true,
      );
    });
  }

  /// Removes an exercise added on the day, and every set logged against it.
  Future<void> deleteAdhocExercise({
    required int sessionId,
    required String name,
    required TrackingType type,
  }) async {
    final db = await database;
    await db.delete(
      'set_logs',
      where: 'session_id = ? AND adhoc = 1 AND exercise_name = ? AND type = ?',
      whereArgs: [sessionId, name, type.dbValue],
    );
  }

  /// The tracking type each known exercise name was last set up with, so
  /// picking a familiar name when adding an exercise also picks its type —
  /// a mismatched type would split that exercise's history in two.
  ///
  /// The routine's own definition wins over logged history, since that's the
  /// one you most recently chose.
  Future<Map<String, TrackingType>> getKnownExerciseTypes() async {
    final db = await database;
    final types = <String, TrackingType>{};
    final logged = await db.rawQuery('''
      SELECT exercise_name AS name, type, MAX(id) AS last
      FROM set_logs GROUP BY exercise_name ORDER BY last ASC
    ''');
    for (final r in logged) {
      types[r['name'] as String] = TrackingTypeX.fromDbValue(r['type'] as String);
    }
    final defined = await db.rawQuery('SELECT name, type FROM exercises ORDER BY id ASC');
    for (final r in defined) {
      types[r['name'] as String] = TrackingTypeX.fromDbValue(r['type'] as String);
    }
    return types;
  }

  // ---------------------------------------------------------------------
  // Rest between sets
  // ---------------------------------------------------------------------

  /// The rest taken before each set the last time [exerciseName] was done,
  /// keyed by the set's position: 2 is the rest between the first and second
  /// sets, 3 between the second and third, and so on.
  ///
  /// Comes from the same workout the pre-filled weights and reps come from.
  /// Sets that weren't timed (logged before this existed, or imported) are
  /// simply missing from the map.
  Future<Map<int, int>> getPreviousRestSeconds(String exerciseName, TrackingType type) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT id, exercise_def_id, adhoc, set_index, checked_at
      FROM set_logs
      WHERE checked = 1
        AND exercise_name = ?
        AND type = ?
        AND session_id = (
          SELECT s.id FROM sessions s
          JOIN set_logs l ON l.session_id = s.id
          WHERE l.exercise_name = ? AND l.type = ? AND l.checked = 1
            AND s.status = 'completed'
          ORDER BY s.date DESC, s.created_at DESC
          LIMIT 1
        )
      ORDER BY id ASC
    ''', [exerciseName, type.dbValue, exerciseName, type.dbValue]);
    if (rows.isEmpty) return const {};

    // A lift programmed twice on one day leaves two runs of sets in the same
    // workout; interleaving them would produce nonsense gaps, so only the
    // first one is used.
    String blockOf(Map<String, Object?> r) =>
        (r['adhoc'] as int?) == 1 ? 'adhoc' : 'def:${r['exercise_def_id']}';
    final first = blockOf(rows.first);
    final sets = rows.where((r) => blockOf(r) == first).toList()
      ..sort((a, b) {
        final byIndex = (a['set_index'] as int).compareTo(b['set_index'] as int);
        return byIndex != 0 ? byIndex : (a['id'] as int).compareTo(b['id'] as int);
      });

    final rest = <int, int>{};
    for (var i = 1; i < sets.length; i++) {
      final gap = restSecondsBetween(
        (sets[i - 1]['checked_at'] as num?)?.toInt(),
        (sets[i]['checked_at'] as num?)?.toInt(),
      );
      if (gap != null) rest[i + 1] = gap;
    }
    return rest;
  }

  // ---------------------------------------------------------------------
  // Smart defaults — carry last time's numbers forward
  // ---------------------------------------------------------------------

  /// The checked sets of the most recent *completed* session that contained
  /// [exerciseName], keyed by set index.
  ///
  /// Matching on name rather than on the routine's exercise id is deliberate:
  /// it means the same lift carries its numbers forward across routine edits,
  /// across routine switches, and across a week where it appears twice.
  Future<Map<int, Map<String, Object?>>> _smartDefaultsFor(
      String exerciseName, TrackingType type) async {
    if (type == TrackingType.none) return {};
    final db = await database;
    // Matching on tracking type as well as name matters when a name gets
    // reused with a different type: without it the "previous" row comes back
    // populated only in the other type's columns, i.e. all nulls for this one.
    final rows = await db.rawQuery('''
      SELECT set_index, weight_kg, reps, hold_seconds, cardio_seconds, cardio_distance_km
      FROM set_logs
      WHERE checked = 1
        AND exercise_name = ?
        AND type = ?
        AND session_id = (
          SELECT s.id FROM sessions s
          JOIN set_logs l ON l.session_id = s.id
          WHERE l.exercise_name = ? AND l.type = ? AND l.checked = 1
            AND s.status = 'completed'
          ORDER BY s.date DESC, s.created_at DESC
          LIMIT 1
        )
      ORDER BY set_index ASC
    ''', [exerciseName, type.dbValue, exerciseName, type.dbValue]);

    final map = <int, Map<String, Object?>>{};
    for (final row in rows) {
      map[(row['set_index'] as num).toInt()] = row;
    }
    return map;
  }

  /// Exact set match if last time had that many sets, otherwise the closest
  /// lower set (so set 4 of a new 4-set week inherits from last week's set 3).
  Map<String, Object?>? _pickDefaultForSet(
      Map<int, Map<String, Object?>> defaults, int setIndex) {
    if (defaults.isEmpty) return null;
    final exact = defaults[setIndex];
    if (exact != null) return exact;
    final lower = defaults.keys.where((k) => k < setIndex).toList()..sort();
    if (lower.isNotEmpty) return defaults[lower.last];
    final all = defaults.keys.toList()..sort();
    return defaults[all.first];
  }

  // ---------------------------------------------------------------------
  // Weeks
  // ---------------------------------------------------------------------

  Future<WorkoutWeek?> getWeek(String weekStart) async {
    final db = await database;
    final rows =
        await db.query('weeks', where: 'week_start = ?', whereArgs: [weekStart], limit: 1);
    if (rows.isEmpty) return null;
    return WorkoutWeek.fromMap(rows.first);
  }

  /// Ensures a row exists for [weekStart], snapshotting the currently active
  /// routine as that week's plan.
  Future<WorkoutWeek> ensureWeek(String weekStart) async {
    final db = await database;
    final existing = await getWeek(weekStart);
    if (existing != null) return existing;

    final routine = await getActiveRoutine();
    final plan = await _snapshotPlan(routine);
    await db.insert(
      'weeks',
      {
        'week_start': weekStart,
        'routine_id': routine?.id,
        'routine_name': routine?.name ?? 'No routine',
        'plan_json': jsonEncode(plan.map((p) => p.toJson()).toList()),
        'status': 'open',
        'closed_at': null,
        'auto_closed': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return (await getWeek(weekStart))!;
  }

  Future<List<PlannedDay>> _snapshotPlan(Routine? routine) async {
    if (routine?.id == null) return [];
    final days = await getDays(routine!.id!);
    final plan = <PlannedDay>[];
    for (final d in days) {
      plan.add(PlannedDay(
        dayIndex: d.dayIndex,
        dayId: d.id,
        dayName: d.dayName,
        exerciseCount: await countExercises(d.id!),
      ));
    }
    return plan;
  }

  /// Keeps the *current, still-open* week's plan in step with the routine as
  /// you edit it or switch routines. Closed weeks are frozen forever, which
  /// is what stops a routine change in March from rewriting January.
  Future<void> refreshOpenWeekPlan(String weekStart) async {
    final db = await database;
    final week = await getWeek(weekStart);
    if (week == null) {
      await ensureWeek(weekStart);
      return;
    }
    if (week.closed) return;

    final routine = await getActiveRoutine();
    final plan = await _snapshotPlan(routine);
    await db.update(
      'weeks',
      {
        'routine_id': routine?.id,
        'routine_name': routine?.name ?? 'No routine',
        'plan_json': jsonEncode(plan.map((p) => p.toJson()).toList()),
      },
      where: 'week_start = ?',
      whereArgs: [weekStart],
    );
  }

  /// Closes out a week. Any workout still running inside it is completed
  /// first so nothing is left dangling.
  Future<void> closeWeek(String weekStart, {bool auto = false}) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    final active = await db.query('sessions',
        where: 'week_start = ? AND status = ?', whereArgs: [weekStart, 'active']);
    for (final row in active) {
      await completeSession(row['id'] as int, auto: auto);
    }
    // Only drop drafts nothing was entered into. A draft where numbers were
    // typed by hand is work in progress, and closing the week early shouldn't
    // silently bin it.
    await db.rawDelete('''
      DELETE FROM sessions
      WHERE week_start = ? AND status = 'draft'
        AND id NOT IN (
          SELECT DISTINCT session_id FROM set_logs
          WHERE checked = 1
             OR adhoc = 1
             OR (prefilled = 0 AND (
                  weight_kg IS NOT NULL OR reps IS NOT NULL OR hold_seconds IS NOT NULL
                  OR cardio_seconds IS NOT NULL OR cardio_distance_km IS NOT NULL))
        )
    ''', [weekStart]);

    await db.update(
      'weeks',
      {'status': 'closed', 'closed_at': now, 'auto_closed': auto ? 1 : 0},
      where: 'week_start = ?',
      whereArgs: [weekStart],
    );
  }

  Future<void> reopenWeek(String weekStart) async {
    final db = await database;
    await db.update('weeks', {'status': 'open', 'closed_at': null, 'auto_closed': 0},
        where: 'week_start = ?', whereArgs: [weekStart]);
  }

  /// Closes any week that is over. Runs on every app start, resume and
  /// midnight tick, so weeks roll over on their own without you doing
  /// anything — Complete Week is the manual "I'm done early" shortcut.
  Future<void> autoCloseFinishedWeeks() async {
    final db = await database;
    final thisWeek = currentWeekStart();
    final stale = await db.query('weeks',
        where: 'status = ? AND week_start < ?', whereArgs: ['open', thisWeek]);
    for (final row in stale) {
      await closeWeek(row['week_start'] as String, auto: true);
    }
  }

  /// Week-by-week summaries, newest first, for the History tab.
  Future<List<WeekSummary>> getWeekSummaries({int limit = 52}) async {
    final db = await database;
    final weekRows =
        await db.query('weeks', orderBy: 'week_start DESC', limit: limit);

    final summaries = <WeekSummary>[];
    for (final row in weekRows) {
      final week = WorkoutWeek.fromMap(row);
      final sessionRows = await db.query(
        'sessions',
        where: 'week_start = ? AND status = ?',
        whereArgs: [week.weekStart, 'completed'],
        orderBy: 'date DESC, created_at DESC',
      );
      final sessions = sessionRows.map(WorkoutSession.fromMap).toList();

      // Resolve each session to its planned day by routine day id first, so a
      // day renamed mid-week doesn't show up as one missed day plus one
      // unplanned extra. Fall back to the name the session snapshotted.
      final planByDayId = {
        for (final p in week.plan)
          if (p.dayId != null) p.dayId!: p,
      };
      final done = <String, int>{};
      for (final s in sessions) {
        final matched = s.routineDayId != null ? planByDayId[s.routineDayId] : null;
        final label = matched?.dayName ?? s.dayName;
        done[label] = (done[label] ?? 0) + 1;
      }
      final planned = week.plannedCounts;

      // Union of planned and performed day names: planned-but-not-done
      // surfaces as missed, done-but-not-planned surfaces as unplanned.
      final names = <String>{...planned.keys, ...done.keys}.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      summaries.add(WeekSummary(
        week: week,
        sessions: sessions,
        outcomes: names
            .map((n) => DayOutcome(
                  dayName: n,
                  planned: planned[n] ?? 0,
                  done: done[n] ?? 0,
                ))
            .toList(),
      ));
    }
    return summaries;
  }

  /// How many times each routine day has already been completed inside
  /// [weekStart], keyed by routine day id. Drives the little tick marks on
  /// the Today screen's day chips.
  Future<Map<int, int>> getCompletedDayCountsForWeek(String weekStart) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT routine_day_id AS day_id, COUNT(*) AS c
      FROM sessions
      WHERE week_start = ? AND status = 'completed' AND routine_day_id IS NOT NULL
      GROUP BY routine_day_id
    ''', [weekStart]);
    return {
      for (final r in rows) (r['day_id'] as num).toInt(): (r['c'] as num).toInt(),
    };
  }

  /// Per-exercise breakdown of one completed session, for the history detail
  /// sheet. Returns only the sets that were actually checked off.
  Future<List<SetLog>> getCompletedLogsForSession(int sessionId) async {
    final db = await database;
    final rows = await db.query('set_logs',
        where: 'session_id = ? AND checked = 1',
        whereArgs: [sessionId],
        orderBy: 'id ASC');
    return rows.map(SetLog.fromMap).toList();
  }

  // ---------------------------------------------------------------------
  // Progress / analytics
  // ---------------------------------------------------------------------

  /// Distinct trackable exercise names that have at least one checked set in
  /// a completed session — the picker on the History → Progress tab.
  Future<List<String>> getTrackableExerciseNames() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT DISTINCT l.exercise_name AS name
      FROM set_logs l
      JOIN sessions s ON s.id = l.session_id
      WHERE l.checked = 1 AND l.type != 'none' AND s.status = 'completed'
      ORDER BY name COLLATE NOCASE ASC
    ''');
    return rows.map((r) => r['name'] as String).toList();
  }

  /// Every checked set for one exercise, joined to its session date, oldest
  /// first. Sessions are included regardless of which routine or day they
  /// came from, so an exercise trained twice in a week contributes both
  /// sessions to the chart.
  Future<List<Map<String, Object?>>> getHistoryForExercise(String exerciseName) async {
    final db = await database;
    return db.rawQuery('''
      SELECT s.date AS date, s.day_name AS day_name, s.id AS session_id,
             l.weight_kg AS weight_kg, l.reps AS reps,
             l.hold_seconds AS hold_seconds, l.cardio_seconds AS cardio_seconds,
             l.cardio_distance_km AS cardio_distance_km, l.type AS type,
             l.set_index AS set_index, l.timestamp AS timestamp
      FROM set_logs l
      JOIN sessions s ON s.id = l.session_id
      WHERE l.exercise_name = ? AND l.checked = 1 AND s.status = 'completed'
      ORDER BY s.date ASC, s.created_at ASC, l.set_index ASC
    ''', [exerciseName]);
  }

  // ---------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------

  Future<String?> getSetting(String key) async {
    final db = await database;
    final rows = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) async {
    final db = await database;
    await db.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ---------------------------------------------------------------------
  // History import
  // ---------------------------------------------------------------------

  /// Writes parsed history in as completed sessions.
  ///
  /// Imported sessions carry no `routine_day_id`: they're a record of what was
  /// done, not something tied to a day of the routine you happen to be running
  /// now. Everything history and the charts need — exercise name, tracking
  /// type, day name — is already denormalised onto the rows themselves, so
  /// they read correctly without it.
  ///
  /// A date+day that already has a completed workout is skipped rather than
  /// duplicated, which makes importing the same file twice a no-op.
  Future<HistoryImportResult> importHistory(List<ImportedSession> incoming) async {
    final db = await database;

    final existingRows = await db.rawQuery(
        "SELECT date, day_name FROM sessions WHERE status = 'completed'");
    final existing = {
      for (final r in existingRows) '${r['date']}|${r['day_name']}',
    };

    final toInsert = <ImportedSession>[];
    final skipped = <String>[];
    for (final s in incoming) {
      final key = '${s.date}|${s.dayName}';
      if (existing.contains(key)) {
        skipped.add('${s.date} (${s.dayName})');
      } else {
        existing.add(key); // guards duplicates inside the file itself
        toInsert.add(s);
      }
    }

    // Week rows are created before the transaction opens: they read the active
    // routine, and a nested read through this class inside a sqflite
    // transaction deadlocks.
    for (final weekStart in {for (final s in toInsert) weekStartOfYmd(s.date)}) {
      await _ensureWeekForImport(weekStart);
    }

    var sets = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      for (final s in toInsert) {
        final sessionId = await txn.insert('sessions', {
          'date': s.date,
          'week_start': weekStartOfYmd(s.date),
          'routine_day_id': null,
          'day_name': s.dayName,
          'routine_name': s.routineName,
          'status': SessionStatus.completed.dbValue,
          'created_at': now,
          'completed_at': now,
          'auto_completed': 0,
        });
        for (final e in s.sets) {
          await txn.insert('set_logs', {
            'session_id': sessionId,
            'exercise_def_id': null,
            'exercise_name': e.exerciseName,
            'type': e.type.dbValue,
            'set_index': e.setIndex,
            'checked': 1,
            'weight_kg': e.weightKg,
            'reps': e.reps,
            'hold_seconds': e.holdSeconds,
            'cardio_seconds': e.cardioSeconds,
            'cardio_distance_km': e.cardioDistanceKm,
            'prefilled': 0,
            'adhoc': e.block == 'adhoc' ? 1 : 0,
            'checked_at': e.checkedAtMs,
            'timestamp': now,
          });
          sets++;
        }
      }
    });

    return HistoryImportResult(
      sessionsImported: toInsert.length,
      setsImported: sets,
      skipped: skipped,
    );
  }

  /// A week row for imported history. Past weeks are recorded closed with an
  /// empty plan — there is no honest way to say what was "planned" months ago,
  /// and the History tab says so rather than inventing one. The current week
  /// goes through the normal path so it keeps its live plan.
  Future<void> _ensureWeekForImport(String weekStart) async {
    final db = await database;
    if (weekStart == currentWeekStart()) {
      await ensureWeek(weekStart);
      return;
    }
    final existing = await getWeek(weekStart);
    if (existing != null) return;
    await db.insert(
      'weeks',
      {
        'week_start': weekStart,
        'routine_id': null,
        'routine_name': 'Imported',
        'plan_json': '[]',
        'status': 'closed',
        'closed_at': DateTime.now().millisecondsSinceEpoch,
        'auto_closed': 1,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // ---------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------

  Future<Map<String, Object?>> exportAllData() async {
    final db = await database;
    return {
      'exportedAt': DateTime.now().toIso8601String(),
      'schemaVersion': schemaVersion,
      'routines': await db.query('routines'),
      'routineDays': await db.query('routine_days'),
      'exercises': await db.query('exercises'),
      'weeks': await db.query('weeks'),
      'sessions': await db.query('sessions', where: "status = 'completed'"),
      'setLogs': await db.rawQuery('''
        SELECT l.* FROM set_logs l
        JOIN sessions s ON s.id = l.session_id
        WHERE l.checked = 1 AND s.status = 'completed'
        ORDER BY l.session_id ASC, l.id ASC
      '''),
    };
  }
}
