import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:workout_tracker/app_state.dart';
import 'package:workout_tracker/db/db_helper.dart';
import 'package:workout_tracker/models/routine.dart';
import 'package:workout_tracker/models/workout_log.dart';
import 'package:workout_tracker/screens/today_screen.dart';
import 'package:workout_tracker/services/app_dates.dart';
import 'package:workout_tracker/theme/theme_provider.dart';

final db = DBHelper.instance;

/// Builds a routine whose day for today is "Back": Row (weights ×2) and
/// Plank (time ×2). Then logs a completed "Back" workout a week ago, with
/// Bench Press added on the day, so there is a "last time" to show.
Future<void> seed() async {
  await db.closeForTesting();
  final file = File(join(await getDatabasesPath(), 'workout_tracker.db'));
  if (file.existsSync()) file.deleteSync();

  final weekday = DateTime.now().weekday;
  final routineId = await db.createRoutine('Split',
      dayNames: [for (var i = 1; i <= 7; i++) i == weekday ? 'Back' : 'Rest $i']);
  await db.setActiveRoutine(routineId);
  final day = (await db.getDays(routineId)).firstWhere((d) => d.dayIndex == weekday);
  await db.addExercise(ExerciseDef(
      routineDayId: day.id!, name: 'Row', type: TrackingType.weights, targetSets: 2, sortOrder: 0));
  await db.addExercise(ExerciseDef(
      routineDayId: day.id!, name: 'Plank', type: TrackingType.time, targetSets: 2, sortOrder: 1));

  final lastWeek = ymd(DateTime.now().subtract(const Duration(days: 7)));
  final exercises = await db.getExercises(day.id!);
  final session = await db.getOrCreateSession(lastWeek, day, 'Split', exercises);
  await db.addAdhocExercise(
      sessionId: session.id!, name: 'Bench Press', type: TrackingType.weights, sets: 1);
  final logs = await db.getSetLogsForSession(session.id!);
  SetLog pick(String name, int set) =>
      logs.firstWhere((l) => l.exerciseName == name && l.setIndex == set);

  await db.updateSetLogs([
    pick('Row', 1).copyWith(checked: true, weightKg: 60.0, reps: 10, checkedAtMs: 1000000),
    pick('Plank', 1).copyWith(checked: true, holdSeconds: 75, checkedAtMs: 1030000),
    pick('Row', 2).copyWith(checked: true, weightKg: 60.0, reps: 9, checkedAtMs: 1090000),
    pick('Plank', 2).copyWith(checked: true, holdSeconds: 70, checkedAtMs: 1090000),
    pick('Bench Press', 1).copyWith(checked: true, weightKg: 80.0, reps: 8, checkedAtMs: 1200000),
  ]);
  await db.completeSession(session.id!);
}

/// Lets real database work finish, then rebuilds.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<SetLog> todayLog(String name, int set) async {
  final rows = await (await db.database).query(
    'set_logs',
    where: 'exercise_name = ? AND set_index = ? AND session_id IN '
        '(SELECT id FROM sessions WHERE date = ?)',
    whereArgs: [name, set, todayYmd()],
  );
  return SetLog.fromMap(rows.single);
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    // Test files run in parallel; each needs its own database file.
    await databaseFactory.setDatabasesPath(
        Directory.systemTemp.createTempSync('workout_tracker_test').path);
  });

  testWidgets('Today: last time\'s rest, min:sec times, and an exercise added for the day',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    await tester.runAsync(seed);
    final appState = AppState();
    await tester.runAsync(appState.init);

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: MaterialApp(theme: AppTheme.light(), home: const TodayScreen()),
    ));
    await settle(tester);

    // Routine exercises, pre-filled from last week, with times as m:ss.
    expect(find.text('Row'), findsOneWidget);
    expect(find.text('Plank'), findsOneWidget);
    expect(find.widgetWithText(TextField, '1:15'), findsOneWidget);
    expect(find.widgetWithText(TextField, '1:10'), findsOneWidget);

    // Last week's rests sit between the sets, greyed.
    expect(find.text('Rest 1:30 last time'), findsOneWidget); // Row
    expect(find.text('Rest 1:00 last time'), findsOneWidget); // Plank

    // --- Add Bench Press for today only -----------------------------------
    await tester.tap(find.text('Add exercise for today'));
    await settle(tester);
    expect(find.text('For this workout only — your routine stays the same. '
        'Sets you tick off count towards its history and charts.'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Exercise name'), 'bench press');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await settle(tester);

    // Reuses the existing spelling, so its history stays on one chart.
    expect(find.text('Bench Press'), findsOneWidget);
    expect(find.text('Added today'), findsOneWidget);
    expect(find.widgetWithText(TextField, '80'), findsWidgets); // pre-filled from last time

    // Adding it again is refused rather than splitting the exercise in two.
    await tester.tap(find.text('Add exercise for today'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Exercise name'), 'Bench Press');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await settle(tester);
    expect(find.text('Bench Press is already in this workout — use "Add set" on it instead.'),
        findsOneWidget);
    expect(find.text('Bench Press'), findsOneWidget);
    // Let the snackbar finish sliding in, time out, and slide away.
    for (final ms in [500, 4000, 1000]) {
      await tester.pump(Duration(milliseconds: ms));
    }

    // The routine itself never changed.
    final routine = (await tester.runAsync(db.getActiveRoutine))!;
    final days = (await tester.runAsync(() => db.getDays(routine.id!)))!;
    final today = days.firstWhere((d) => d.dayIndex == DateTime.now().weekday);
    final routineExercises = (await tester.runAsync(() => db.getExercises(today.id!)))!;
    expect(routineExercises.map((e) => e.name), ['Row', 'Plank']);

    // --- Time entry is min:sec ---------------------------------------------
    await tester.enterText(find.widgetWithText(TextField, '1:15'), '230');
    await settle(tester);
    expect(find.widgetWithText(TextField, '2:30'), findsOneWidget);
    final plank1 = (await tester.runAsync(() => todayLog('Plank', 1)))!;
    expect(plank1.holdSeconds, 150);

    // --- Tick Row 1, Bench 1 (superset), then Row 2 ------------------------
    Finder box(int i) => find.byType(Checkbox).at(i);
    // Checkbox order: Row 1, Row 2, Plank 1, Plank 2, Bench 1.
    await tester.tap(box(0));
    await settle(tester);
    await tester.tap(box(4));
    await settle(tester);
    await tester.tap(box(1));
    await settle(tester);

    // Row's rest is now this workout's, measured from set 1's tick to set 2's
    // regardless of the Bench set in between; last week's is no longer shown.
    expect(find.textContaining(RegExp(r'^Rest 0:0\d$')), findsOneWidget);
    expect(find.text('Rest 1:30 last time'), findsNothing);
    expect(find.text('Rest 1:00 last time'), findsOneWidget); // Plank untouched

    final row1 = (await tester.runAsync(() => todayLog('Row', 1)))!;
    final row2 = (await tester.runAsync(() => todayLog('Row', 2)))!;
    expect(row1.checkedAtMs, isNotNull);
    expect(row2.checkedAtMs, greaterThanOrEqualTo(row1.checkedAtMs!));

    // Unticking set 1 cascades and clears both tick times.
    await tester.tap(box(0));
    await settle(tester);
    expect(find.text('Rest 1:30 last time'), findsOneWidget);
    final cleared = (await tester.runAsync(() => todayLog('Row', 2)))!;
    expect(cleared.checked, isFalse);
    expect(cleared.checkedAtMs, isNull);

    // --- Complete -----------------------------------------------------------
    await tester.tap(find.text('Complete workout'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Finish'));
    await settle(tester);
    expect(find.text('Workout saved to history.'), findsOneWidget);

    final benchHistory = (await tester.runAsync(() => db.getHistoryForExercise('Bench Press')))!;
    expect(benchHistory, hasLength(2)); // last week + today
    expect(benchHistory.last['date'], todayYmd());

    // A finished workout is read-only: no add button, no "last time" hints.
    expect(find.text('Add exercise for today'), findsNothing);
    expect(find.textContaining('last time'), findsNothing);
    expect(find.text('Bench Press'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    appState.dispose();
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(db.closeForTesting);
  });

  testWidgets('switching days quickly never loses the day you land on', (tester) async {
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    await tester.runAsync(seed);
    // Give another day some exercises so switching to it opens a workout.
    final otherIndex = DateTime.now().weekday % 7 + 1;
    await tester.runAsync(() async {
      final routine = (await db.getActiveRoutine())!;
      final other =
          (await db.getDays(routine.id!)).firstWhere((d) => d.dayIndex == otherIndex);
      await db.addExercise(ExerciseDef(
          routineDayId: other.id!, name: 'Squat', type: TrackingType.weights,
          targetSets: 2, sortOrder: 0));
    });
    final appState = AppState();
    await tester.runAsync(appState.init);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: MaterialApp(theme: AppTheme.light(), home: const TodayScreen()),
    ));
    await settle(tester);
    expect(find.text('Row'), findsOneWidget);

    // Switch day while a background reload (as after midnight or an import)
    // starts at the same moment, so two loads overlap.
    await tester.scrollUntilVisible(find.text('Rest $otherIndex'), 80,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('Rest $otherIndex'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rest $otherIndex'));
    await appState.onDataImported();
    await tester.pump();
    await settle(tester);
    expect(find.text('Squat'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Back'), -80,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back'));
    await appState.onDataImported();
    await tester.pump();
    await settle(tester);
    expect(find.text('Row'), findsOneWidget);
    expect(find.text('Squat'), findsNothing);

    // The workout on screen is real: ticking a set lands in the database.
    await tester.tap(find.byType(Checkbox).first);
    await settle(tester);
    final row1 = (await tester.runAsync(() => todayLog('Row', 1)))!;
    expect(row1.checked, isTrue);

    await tester.pumpWidget(const SizedBox());
    appState.dispose();
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(db.closeForTesting);
  });
}
