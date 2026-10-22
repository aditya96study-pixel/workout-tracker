import 'package:flutter/material.dart';

import '../db/db_helper.dart';

const _kThemeSettingKey = 'theme_mode';
const _kPaletteSettingKey = 'theme_palette';
const _kVividSettingKey = 'theme_vivid';
const _kPureBlackSettingKey = 'theme_pure_black';

/// A named colour theme. Every colour in the app is derived from [seed], so
/// one swatch recolours buttons, ticks, charts and highlights consistently.
enum AppPalette {
  ocean('Ocean', Color(0xFF2F6FED)),
  teal('Lagoon', Color(0xFF00897B)),
  forest('Forest', Color(0xFF2E7D32)),
  sunset('Sunset', Color(0xFFEF6C00)),
  ember('Ember', Color(0xFFD32F2F)),
  rose('Rose', Color(0xFFD81B60)),
  violet('Violet', Color(0xFF7E57C2)),
  graphite('Graphite', Color(0xFF607D8B));

  const AppPalette(this.label, this.seed);
  final String label;
  final Color seed;

  /// Graphite is meant to be colourless, so it uses the greyscale scheme.
  bool get monochrome => this == AppPalette.graphite;

  static AppPalette fromName(String? name) =>
      AppPalette.values.firstWhere((p) => p.name == name, orElse: () => AppPalette.ocean);
}

/// Appearance settings — light/dark, colour theme, vivid colours and pure
/// black — persisted in the settings table so they survive restarts.
/// Defaults match the app before themes existed: Ocean, following the system.
class ThemeProvider extends ChangeNotifier {
  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  AppPalette _palette = AppPalette.ocean;
  AppPalette get palette => _palette;

  bool _vivid = false;
  bool get vivid => _vivid;

  /// True-black backgrounds in dark mode — easier on OLED batteries and
  /// dark gyms.
  bool _pureBlack = false;
  bool get pureBlack => _pureBlack;

  ThemeData get lightTheme => AppTheme.light(palette: _palette, vivid: _vivid);
  ThemeData get darkTheme =>
      AppTheme.dark(palette: _palette, vivid: _vivid, pureBlack: _pureBlack);

  Future<void> load() async {
    final db = DBHelper.instance;
    final saved = await db.getSetting(_kThemeSettingKey);
    _mode = switch (saved) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    _palette = AppPalette.fromName(await db.getSetting(_kPaletteSettingKey));
    _vivid = await db.getSetting(_kVividSettingKey) == '1';
    _pureBlack = await db.getSetting(_kPureBlackSettingKey) == '1';
    notifyListeners();
  }

  Future<void> setPalette(AppPalette palette) async {
    if (_palette == palette) return;
    _palette = palette;
    notifyListeners();
    await DBHelper.instance.setSetting(_kPaletteSettingKey, palette.name);
  }

  Future<void> setVivid(bool value) async {
    if (_vivid == value) return;
    _vivid = value;
    notifyListeners();
    await DBHelper.instance.setSetting(_kVividSettingKey, value ? '1' : '0');
  }

  Future<void> setPureBlack(bool value) async {
    if (_pureBlack == value) return;
    _pureBlack = value;
    notifyListeners();
    await DBHelper.instance.setSetting(_kPureBlackSettingKey, value ? '1' : '0');
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    final value = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await DBHelper.instance.setSetting(_kThemeSettingKey, value);
  }
}

/// Clean, quiet Material 3 themes: flat surfaces, hairline outlines instead of
/// shadows, and one accent colour that both modes derive from.
class AppTheme {
  static ThemeData light({AppPalette palette = AppPalette.ocean, bool vivid = false}) =>
      _build(Brightness.light, palette, vivid: vivid);

  static ThemeData dark({
    AppPalette palette = AppPalette.ocean,
    bool vivid = false,
    bool pureBlack = false,
  }) =>
      _build(Brightness.dark, palette, vivid: vivid, pureBlack: pureBlack);

  static ColorScheme scheme(
    Brightness brightness,
    AppPalette palette, {
    bool vivid = false,
    bool pureBlack = false,
  }) {
    var scheme = ColorScheme.fromSeed(
      seedColor: palette.seed,
      brightness: brightness,
      dynamicSchemeVariant: palette.monochrome
          ? DynamicSchemeVariant.monochrome
          : vivid
              ? DynamicSchemeVariant.vibrant
              : DynamicSchemeVariant.tonalSpot,
    );
    if (pureBlack && brightness == Brightness.dark) {
      // Cards keep a faint lift off the black so they stay distinguishable.
      scheme = scheme.copyWith(
        surface: Colors.black,
        surfaceDim: Colors.black,
        surfaceContainerLowest: Colors.black,
        surfaceContainerLow: const Color(0xFF0B0B0D),
        surfaceContainer: const Color(0xFF111114),
        surfaceContainerHigh: const Color(0xFF18181B),
        surfaceContainerHighest: const Color(0xFF202024),
      );
    }
    return scheme;
  }

  static ThemeData _build(
    Brightness brightness,
    AppPalette palette, {
    bool vivid = false,
    bool pureBlack = false,
  }) {
    final scheme = AppTheme.scheme(brightness, palette, vivid: vivid, pureBlack: pureBlack);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
      chipTheme: ChipThemeData(
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        showCheckmark: false,
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.secondaryContainer,
        elevation: 0,
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
      ),
    );
  }
}
