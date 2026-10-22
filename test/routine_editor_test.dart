import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:workout_tracker/db/db_helper.dart';
import 'package:workout_tracker/models/routine.dart';
import 'package:workout_tracker/screens/routine_editor_screen.dart';

final db = DBHelper.instance;

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await databaseFactory.setDatabasesPath(
        Directory.systemTemp.createTempSync('workout_tracker_test').path);
  });

  testWidgets('routine editor: adding and editing an exercise still works', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    final routineId = (await tester.runAsync(() async {
      await db.closeForTesting();
      final id = await db.createRoutine('Split');
      final days = await db.getDays(id);
      // A name already in use elsewhere, with its own tracking type.
      await db.addExercise(ExerciseDef(
          routineDayId: days[1].id!, name: 'Plank', type: TrackingType.time,
          targetSets: 3, sortOrder: 0));
      return id;
    }))!;

    await tester.pumpWidget(MaterialApp(home: RoutineEditorScreen(routineId: routineId)));
    await settle(tester);

    // Add: picking a known name from the suggestions picks its type too.
    await tester.tap(find.text('Add exercise').last);
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Exercise name'), 'Pla');
    await settle(tester);
    await tester.tap(find.text('Plank').last);
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle(tester);

    final day1 = (await tester.runAsync(() async => db.getExercises((await db.getDays(routineId)).first.id!)))!;
    expect(day1.single.name, 'Plank');
    expect(day1.single.type, TrackingType.time);
    expect(day1.single.targetSets, 3);

    // Edit: changing the type by hand sticks.
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await settle(tester);
    expect(find.text('Edit exercise'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Reps'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle(tester);

    final edited = (await tester.runAsync(() async => db.getExercises((await db.getDays(routineId)).first.id!)))!;
    expect(edited.single.type, TrackingType.reps);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(db.closeForTesting);
  });
}
