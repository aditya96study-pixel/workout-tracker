/// Minutes-and-seconds helpers. Every duration in the app — holds, cardio,
/// pace, rest between sets — is shown as `m:ss`, while the database keeps
/// plain whole seconds so nothing stored had to change.
library;

import 'package:flutter/services.dart';

/// `90` → `1:30`, `5` → `0:05`, `3725` → `62:05`.
///
/// Minutes are deliberately never rolled up into hours: one format
/// everywhere is easier to read at a glance than switching mid-list.
String formatMinSec(int totalSeconds) {
  final s = totalSeconds < 0 ? 0 : totalSeconds;
  final minutes = s ~/ 60;
  final seconds = s % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// Reads what the [MinSecInputFormatter] puts in a field back into seconds.
///
/// The field is a stopwatch-style mask, so the last two digits are seconds
/// and anything before them is minutes: `1:30` → 90, `12:05` → 725. Returns
/// null for an empty field. A seconds part above 59 (only ever seen briefly
/// while typing) simply adds up, so `0:75` is 75 seconds.
int? parseMinSec(String text) {
  final digits = text.replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return null;
  final padded = digits.padLeft(3, '0');
  final minutes = int.parse(padded.substring(0, padded.length - 2));
  final seconds = int.parse(padded.substring(padded.length - 2));
  return minutes * 60 + seconds;
}

/// Lenient duration parser for imported files: `90` is seconds, `1:30` is
/// minutes:seconds, `1:02:03` is hours:minutes:seconds. Returns null for
/// anything else.
int? parseDurationText(String? raw) {
  if (raw == null) return null;
  final t = raw.trim();
  if (t.isEmpty) return null;
  if (!t.contains(':')) {
    final v = int.tryParse(t) ?? double.tryParse(t)?.round();
    if (v == null || v < 0) return null;
    return v;
  }
  final parts = t.split(':');
  if (parts.length > 3 || parts.any((p) => !RegExp(r'^\d+$').hasMatch(p.trim()))) {
    return null;
  }
  var total = 0;
  for (final p in parts) {
    total = total * 60 + int.parse(p.trim());
  }
  return total;
}

/// Turns a plain digit keypad into an `m:ss` entry, like a microwave or a
/// stopwatch: typing 1, 3, 0 shows `0:01`, `0:13`, `1:30`. Backspace peels
/// digits off the right-hand end.
///
/// Done this way because Android's number pad has no `:` key, and asking
/// for minutes and seconds in two separate boxes would crowd the row.
class MinSecInputFormatter extends TextInputFormatter {
  /// Five digits is 999:59 — far beyond any hold or run.
  static const int maxDigits = 5;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final oldDigits = _digits(oldValue.text);
    var digits = _digits(newValue.text);

    // Deleting only the ':' would otherwise leave the digits unchanged and
    // the keypress would appear to do nothing; treat it as deleting the
    // digit in front of it instead.
    if (digits == oldDigits &&
        newValue.text.length < oldValue.text.length &&
        digits.isNotEmpty) {
      final cursor = newValue.selection.baseOffset.clamp(0, newValue.text.length);
      final before = _digits(newValue.text.substring(0, cursor)).length;
      final drop = before > 0 ? before - 1 : 0;
      digits = digits.substring(0, drop) + digits.substring(drop + 1);
    }

    digits = digits.replaceFirst(RegExp(r'^0+'), '');
    if (digits.isEmpty) return TextEditingValue.empty;
    if (digits.length > maxDigits) return oldValue;

    final padded = digits.padLeft(3, '0');
    final text =
        '${padded.substring(0, padded.length - 2)}:${padded.substring(padded.length - 2)}';
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  static String _digits(String s) => s.replaceAll(RegExp(r'\D'), '');
}
