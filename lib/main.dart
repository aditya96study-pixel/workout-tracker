import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'screens/history_screen.dart';
import 'screens/routines_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/today_screen.dart';
import 'theme/theme_provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WorkoutTrackerApp());
}

class WorkoutTrackerApp extends StatefulWidget {
  const WorkoutTrackerApp({super.key});

  @override
  State<WorkoutTrackerApp> createState() => _WorkoutTrackerAppState();
}

class _WorkoutTrackerAppState extends State<WorkoutTrackerApp> {
  final ThemeProvider _themeProvider = ThemeProvider();
  final AppState _appState = AppState();

  @override
  void initState() {
    super.initState();
    // Both write straight to SQLite and notify when ready, so the first frame
    // can render immediately with defaults.
    _themeProvider.load();
    _appState.init();
  }

  @override
  void dispose() {
    // Created here rather than by the providers, so disposed here too —
    // AppState in particular has a midnight timer and a lifecycle observer
    // that must be torn down.
    _appState.dispose();
    _themeProvider.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeProvider>.value(value: _themeProvider),
        ChangeNotifierProvider<AppState>.value(value: _appState),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, theme, _) => MaterialApp(
          title: 'Workout Tracker',
          debugShowCheckedModeBanner: false,
          themeMode: theme.mode,
          theme: theme.lightTheme,
          darkTheme: theme.darkTheme,
          home: const RootShell(),
        ),
      ),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  static const _screens = [
    TodayScreen(),
    RoutinesScreen(),
    HistoryScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    if (appState.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      // IndexedStack keeps each tab's scroll position and in-flight state
      // alive as you move between them.
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(
            // A dot on Today is the persistent reminder that a workout is
            // still open, whichever tab you wandered off to.
            icon: Badge(
              isLabelVisible: appState.hasWorkoutInProgress,
              smallSize: 7,
              child: const Icon(Icons.today_outlined),
            ),
            selectedIcon: const Icon(Icons.today),
            label: 'Today',
          ),
          const NavigationDestination(
            icon: Icon(Icons.list_alt_outlined),
            selectedIcon: Icon(Icons.list_alt),
            label: 'Routines',
          ),
          const NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights),
            label: 'History',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
