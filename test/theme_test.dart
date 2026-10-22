import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:workout_tracker/db/db_helper.dart';
import 'package:workout_tracker/theme/theme_provider.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.setDatabasesPath(
        Directory.systemTemp.createTempSync('workout_tracker_test').path);
  });
  tearDownAll(() => DBHelper.instance.closeForTesting());

  test('defaults match the app before themes existed', () async {
    final p = ThemeProvider();
    await p.load();
    expect(p.mode, ThemeMode.system);
    expect(p.palette, AppPalette.ocean);
    expect(p.vivid, isFalse);
    expect(p.pureBlack, isFalse);
  });

  test('choices are remembered across restarts', () async {
    final p = ThemeProvider();
    await p.load();
    await p.setMode(ThemeMode.dark);
    await p.setPalette(AppPalette.forest);
    await p.setVivid(true);
    await p.setPureBlack(true);

    final restarted = ThemeProvider();
    await restarted.load();
    expect(restarted.mode, ThemeMode.dark);
    expect(restarted.palette, AppPalette.forest);
    expect(restarted.vivid, isTrue);
    expect(restarted.pureBlack, isTrue);
  });

  test('an unknown saved theme falls back to Ocean', () {
    expect(AppPalette.fromName('no-such-theme'), AppPalette.ocean);
    expect(AppPalette.fromName(null), AppPalette.ocean);
  });

  test('every theme gives distinct, readable colours in both modes', () {
    for (final p in AppPalette.values) {
      for (final b in Brightness.values) {
        final s = AppTheme.scheme(b, p);
        // Text on the main accent must stay legible (WCAG AA for large text).
        expect(_contrast(s.primary, s.onPrimary), greaterThan(3.0), reason: '$p $b');
        expect(_contrast(s.surface, s.onSurface), greaterThan(4.5), reason: '$p $b');
      }
    }
    final ocean = AppTheme.scheme(Brightness.light, AppPalette.ocean).primary;
    final forest = AppTheme.scheme(Brightness.light, AppPalette.forest).primary;
    expect(ocean, isNot(forest));
  });

  test('pure black only affects dark mode', () {
    final dark = AppTheme.scheme(Brightness.dark, AppPalette.ocean, pureBlack: true);
    expect(dark.surface, Colors.black);
    final light = AppTheme.scheme(Brightness.light, AppPalette.ocean, pureBlack: true);
    expect(light.surface, isNot(Colors.black));
    expect(AppTheme.dark(pureBlack: true).scaffoldBackgroundColor, Colors.black);
  });
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}
