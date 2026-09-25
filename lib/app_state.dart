import 'dart:async';

import 'package:flutter/widgets.dart';

import 'db/db_helper.dart';
import 'models/routine.dart';
import 'models/workout_log.dart';
import 'services/app_dates.dart';

/// App-wide state the screens react to: which routine is active, whether a
/// workout is currently in progress, and the day/week rollover clock.
///
/// The rollover is deliberately driven from three places rather than one:
/// a timer set for the next midnight (covers the app being open at 12am),
/// an app-resume hook (covers the phone being asleep at 12am), and a check
/// at startup (covers the app having been killed for days). Between them,
/// an unfinished workout always ends up banked against the date it was
/// actually performed — without a background service, which would mean asking
/// for permissions this app deliberately doesn't want.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  Routine? activeRoutine;
  WorkoutSession? inProgressSession;
  bool loading = true;

  /// Bumped whenever stored data changed in a way the other screens can't see
  /// for themselves — a workout completed, a week closed, a routine edited,
  /// midnight passing. Screens watch it to know they should reload.
  int revision = 0;

  /// Number of workouts the last rollover auto-completed, so the UI can
  /// mention it once and then clear it.
  int pendingAutoSavedCount = 0;

  String _today = todayYmd();
  String get today => _today;

  Timer? _midnightTimer;
  bool _disposed = false;

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    await _runRollover(notify: false);
    await DBHelper.instance.refreshOpenWeekPlan(currentWeekStart());
    await _reload(notify: false);
    loading = false;
    _scheduleMidnightTick();
    _safeNotify();
  }

  @override
  void dispose() {
    _disposed = true;
    _midnightTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Routine
  // ---------------------------------------------------------------------

  Future<void> _reload({bool notify = true}) async {
    activeRoutine = await DBHelper.instance.getActiveRoutine();
    inProgressSession = await DBHelper.instance.getInProgressSession();
    if (notify) _safeNotify();
  }

  Future<void> refresh() => _reload();

  /// Switches the active routine. Returns false (changing nothing) if a
  /// workout is running — the in-progress session belongs to the old
  /// routine's days, so switching out from under it would strand it.
  Future<bool> setActiveRoutine(int routineId) async {
    await _reload(notify: false);
    if (inProgressSession != null) return false;

    await DBHelper.instance.setActiveRoutine(routineId);
    // The current week's plan follows the routine you're actually running.
    await DBHelper.instance.refreshOpenWeekPlan(currentWeekStart());
    revision++;
    await _reload();
    return true;
  }

  /// Called after the routine editor or importer closes, so this week's plan
  /// snapshot picks up whatever changed.
  Future<void> onRoutineEdited() async {
    await DBHelper.instance.refreshOpenWeekPlan(currentWeekStart());
    revision++;
    await _reload();
  }

  // ---------------------------------------------------------------------
  // Workout in progress
  // ---------------------------------------------------------------------

  /// True when a workout is running — day switching is locked while it holds.
  bool get hasWorkoutInProgress => inProgressSession != null;

  /// Refreshes the lock after a set was ticked or cleared. Deliberately does
  /// not bump [revision]: nothing has landed in history yet, and bumping on
  /// every checkbox would reload every screen.
  Future<void> onSessionChanged() => _reload();

  /// A workout was completed or reopened — history and charts are now stale.
  Future<void> onWorkoutFinished() async {
    revision++;
    await _reload();
  }

  Future<void> completeWeek(String weekStart) async {
    await DBHelper.instance.closeWeek(weekStart);
    revision++;
    await _reload();
  }

  /// Finishes a workout that can't be reached from the current routine —
  /// the escape hatch for a session left behind by a routine change.
  Future<void> resolveStrandedWorkout({required bool keep}) async {
    final session = inProgressSession;
    if (session?.id == null) return;
    if (keep) {
      await DBHelper.instance.completeSession(session!.id!);
    } else {
      await DBHelper.instance.deleteSession(session!.id!);
    }
    revision++;
    await _reload();
  }

  // ---------------------------------------------------------------------
  // Day / week rollover
  // ---------------------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Returning from the background is the likeliest moment for the
      // calendar to have moved on without us.
      unawaited(_onResumed());
    }
  }

  Future<void> _onResumed() async {
    await _runRollover();
    _scheduleMidnightTick();
  }

  Future<void> _runRollover({bool notify = true}) async {
    final now = todayYmd();
    final dayChanged = now != _today;
    _today = now;

    var banked = 0;
    try {
      banked = await DBHelper.instance.rolloverStaleSessions(today: now);
    } catch (_) {
      // A rollover that fails (locked database, disk pressure) must not take
      // the timer down with it — the next resume or tick tries again.
      return;
    }

    if (banked > 0) pendingAutoSavedCount = banked;
    if (banked > 0 || dayChanged) {
      revision++;
      await DBHelper.instance.refreshOpenWeekPlan(currentWeekStart());
      await _reload(notify: false);
      if (notify) _safeNotify();
    }
  }

  void consumeAutoSavedNotice() {
    pendingAutoSavedCount = 0;
  }

  void _scheduleMidnightTick() {
    _midnightTimer?.cancel();
    if (_disposed) return;
    // A few seconds past the hour, so the date has unambiguously ticked over
    // by the time the query runs.
    final delay = nextMidnight().difference(DateTime.now()) + const Duration(seconds: 5);
    _midnightTimer = Timer(delay.isNegative ? const Duration(seconds: 5) : delay, () async {
      try {
        await _runRollover();
      } finally {
        // Always re-arm. Losing the timer would silently disable midnight
        // auto-save for the rest of the app's lifetime.
        _scheduleMidnightTick();
      }
    });
  }
}
