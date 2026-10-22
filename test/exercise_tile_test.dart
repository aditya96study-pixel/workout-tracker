import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:workout_tracker/models/routine.dart';
import 'package:workout_tracker/models/workout_log.dart';
import 'package:workout_tracker/services/time_format.dart';
import 'package:workout_tracker/widgets/exercise_tile.dart';

SetLog setLog(int i, TrackingType type,
        {bool checked = false, int? hold, int? checkedAt, bool adhoc = false}) =>
    SetLog(
      id: i,
      sessionId: 1,
      exerciseDefId: adhoc ? null : 1,
      exerciseName: 'Plank',
      type: type,
      setIndex: i,
      checked: checked,
      holdSeconds: hold,
      checkedAtMs: checkedAt,
      adhoc: adhoc,
    );

Future<List<SetLog>> pumpTile(
  WidgetTester tester, {
  required List<SetLog> logs,
  TrackingType type = TrackingType.time,
  bool readOnly = false,
  Map<int, int> previousRest = const {},
  bool adhoc = false,
  int targetSets = 3,
  VoidCallback? onRemoveExercise,
}) async {
  final changes = <SetLog>[];
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: ExerciseTile(
          exercise: ExerciseDef(
              routineDayId: 1, name: 'Plank', type: type, targetSets: targetSets, sortOrder: 0),
          logs: logs,
          readOnly: readOnly,
          previousRest: previousRest,
          isAdhoc: adhoc,
          onRemoveExercise: onRemoveExercise,
          onToggleSet: (_, __) {},
          onFieldChanged: changes.add,
          onAddSet: () {},
          onRemoveSet: (_) {},
        ),
      ),
    ),
  ));
  return changes;
}

void main() {
  testWidgets('time is shown and entered as min:sec', (tester) async {
    final changes = await pumpTile(tester, logs: [
      setLog(1, TrackingType.time, hold: 95, checked: true, checkedAt: 0),
      setLog(2, TrackingType.time),
      setLog(3, TrackingType.time),
    ]);
    expect(find.widgetWithText(TextField, '1:35'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(1), '245');
    await tester.pump();
    expect(find.widgetWithText(TextField, '2:45'), findsOneWidget);
    expect(changes.last.holdSeconds, 165);
    expect(changes.last.id, 2);

    // Clearing the box clears the value, so the set can't be ticked blank.
    await tester.enterText(find.byType(TextField).at(1), '');
    await tester.pump();
    expect(changes.last.holdSeconds, isNull);
  });

  testWidgets('an over-59 seconds entry is tidied when you leave the box', (tester) async {
    final changes = await pumpTile(tester, logs: [
      setLog(1, TrackingType.time, hold: 60),
      setLog(2, TrackingType.time),
    ]);
    await tester.enterText(find.byType(TextField).first, '888');
    await tester.pump();
    // Left alone while typing, but already saved as what it means.
    expect(find.widgetWithText(TextField, '8:88'), findsOneWidget);
    expect(changes.last.holdSeconds, 568);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(find.widgetWithText(TextField, '9:28'), findsOneWidget);
    expect(find.widgetWithText(TextField, '8:88'), findsNothing);
    expect(parseMinSec('9:28'), 568); // display and stored value agree
  });

  testWidgets('ticking a set tidies its time too', (tester) async {
    final toggled = <bool>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ExerciseTile(
          exercise: ExerciseDef(
              routineDayId: 1, name: 'Run', type: TrackingType.cardio, targetSets: 1, sortOrder: 0),
          logs: [
            SetLog(id: 1, sessionId: 1, exerciseDefId: 1, exerciseName: 'Run',
                type: TrackingType.cardio, setIndex: 1, checked: false),
          ],
          readOnly: false,
          onToggleSet: (_, v) => toggled.add(v),
          onFieldChanged: (_) {},
          onAddSet: () {},
          onRemoveSet: (_) {},
        ),
      ),
    ));
    await tester.enterText(find.byType(TextField).first, '2575');
    await tester.pump();
    expect(find.widgetWithText(TextField, '25:75'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(toggled, [true]);
    expect(find.widgetWithText(TextField, '26:15'), findsOneWidget);
  });

  testWidgets('rest: this workout once both sets are ticked, last time until then',
      (tester) async {
    await pumpTile(tester, previousRest: {2: 80, 3: 125}, logs: [
      setLog(1, TrackingType.time, hold: 60, checked: true, checkedAt: 1000),
      setLog(2, TrackingType.time, hold: 60, checked: true, checkedAt: 96000),
      setLog(3, TrackingType.time, hold: 60),
    ]);
    expect(find.text('Rest 1:35'), findsOneWidget); // actual, replaces 1:20
    expect(find.text('Rest 1:20 last time'), findsNothing);
    expect(find.text('Rest 2:05 last time'), findsOneWidget);
  });

  testWidgets('a finished workout shows only its own rest times', (tester) async {
    await pumpTile(tester, readOnly: true, previousRest: {2: 80, 3: 125}, logs: [
      setLog(1, TrackingType.time, hold: 60, checked: true, checkedAt: 0),
      setLog(2, TrackingType.time, hold: 60, checked: true, checkedAt: 61000),
      setLog(3, TrackingType.time, hold: 60),
    ]);
    expect(find.text('Rest 1:01'), findsOneWidget);
    expect(find.textContaining('last time'), findsNothing);
  });

  testWidgets('untimed sets show no rest line', (tester) async {
    await pumpTile(tester, logs: [
      setLog(1, TrackingType.time, hold: 60, checked: true),
      setLog(2, TrackingType.time, hold: 60, checked: true),
    ]);
    expect(find.textContaining('Rest'), findsNothing);
  });

  testWidgets('an added exercise is tagged, removable, and only its last set has ✕',
      (tester) async {
    var removed = false;
    await pumpTile(
      tester,
      adhoc: true,
      targetSets: 0,
      onRemoveExercise: () => removed = true,
      logs: [
        setLog(1, TrackingType.time, hold: 60, adhoc: true),
        setLog(2, TrackingType.time, hold: 60, adhoc: true),
        setLog(3, TrackingType.time, hold: 60, adhoc: true),
      ],
    );
    expect(find.text('Added today'), findsOneWidget);
    expect(find.byTooltip('Remove this set'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove from this workout'));
    expect(removed, isTrue);
  });

  testWidgets('routine exercises keep their usual header', (tester) async {
    await pumpTile(tester, logs: [setLog(1, TrackingType.time, hold: 60)]);
    expect(find.text('Added today'), findsNothing);
    expect(find.byTooltip('Remove from this workout'), findsNothing);
    expect(find.text('Time'), findsOneWidget);
  });
}
