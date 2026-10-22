import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:workout_tracker/models/workout_log.dart';
import 'package:workout_tracker/services/time_format.dart';

/// Types [keys] one at a time into an empty field, the way a keypad would.
String typeKeys(String keys) {
  final f = MinSecInputFormatter();
  var value = TextEditingValue.empty;
  for (final k in keys.split('')) {
    final next = value.text + k;
    value = f.formatEditUpdate(
      value,
      TextEditingValue(text: next, selection: TextSelection.collapsed(offset: next.length)),
    );
  }
  return value.text;
}

TextEditingValue backspaceAt(String text, int cursor) {
  final f = MinSecInputFormatter();
  final old = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: cursor));
  final next = text.substring(0, cursor - 1) + text.substring(cursor);
  return f.formatEditUpdate(
    old,
    TextEditingValue(text: next, selection: TextSelection.collapsed(offset: cursor - 1)),
  );
}

void main() {
  group('formatMinSec', () {
    test('formats seconds as m:ss', () {
      expect(formatMinSec(0), '0:00');
      expect(formatMinSec(5), '0:05');
      expect(formatMinSec(59), '0:59');
      expect(formatMinSec(60), '1:00');
      expect(formatMinSec(90), '1:30');
      expect(formatMinSec(1800), '30:00');
      expect(formatMinSec(3725), '62:05');
    });

    test('never shows a negative time', () {
      expect(formatMinSec(-4), '0:00');
    });
  });

  group('parseMinSec', () {
    test('reads the mask back into seconds', () {
      expect(parseMinSec(''), isNull);
      expect(parseMinSec('0:05'), 5);
      expect(parseMinSec('1:30'), 90);
      expect(parseMinSec('12:05'), 725);
      expect(parseMinSec('999:59'), 999 * 60 + 59);
    });

    test('round-trips every value formatMinSec produces', () {
      for (final s in [1, 7, 45, 60, 61, 599, 600, 3599, 3600, 59999]) {
        expect(parseMinSec(formatMinSec(s)), s, reason: 'for $s seconds');
      }
    });

    test('a seconds part over 59 simply adds up', () {
      expect(parseMinSec('0:75'), 75);
    });
  });

  group('parseDurationText (imports)', () {
    test('plain numbers are seconds', () {
      expect(parseDurationText('90'), 90);
      expect(parseDurationText('1800'), 1800);
      expect(parseDurationText('45.6'), 46);
    });

    test('m:ss and h:mm:ss', () {
      expect(parseDurationText('1:30'), 90);
      expect(parseDurationText('30:00'), 1800);
      expect(parseDurationText('1:02:03'), 3723);
    });

    test('rejects junk', () {
      expect(parseDurationText(null), isNull);
      expect(parseDurationText(''), isNull);
      expect(parseDurationText('abc'), isNull);
      expect(parseDurationText('1:x'), isNull);
      expect(parseDurationText('-5'), isNull);
      expect(parseDurationText('1:2:3:4'), isNull);
    });
  });

  group('MinSecInputFormatter', () {
    test('fills from the right like a stopwatch', () {
      expect(typeKeys('5'), '0:05');
      expect(typeKeys('45'), '0:45');
      expect(typeKeys('130'), '1:30');
      expect(typeKeys('1234'), '12:34');
      expect(typeKeys('12345'), '123:45');
    });

    test('caps the length at five digits', () {
      expect(typeKeys('123456'), '123:45');
    });

    test('leading zeros are dropped and all-zero clears the field', () {
      expect(typeKeys('0'), '');
      expect(typeKeys('030'), '0:30');
      expect(typeKeys('00'), '');
    });

    test('backspace peels digits off the end', () {
      expect(backspaceAt('1:30', 4).text, '0:13');
      expect(backspaceAt('0:13', 4).text, '0:01');
      expect(backspaceAt('0:01', 4).text, '');
    });

    test('backspacing over the colon deletes the digit before it', () {
      // Cursor just after ':' in "1:30" — removing the colon alone would
      // otherwise be a no-op.
      expect(backspaceAt('1:30', 2).text, '0:30');
      expect(backspaceAt('12:30', 3).text, '1:30');
    });

    test('pasting a formatted time works', () {
      final f = MinSecInputFormatter();
      final v = f.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(text: '2:15', selection: TextSelection.collapsed(offset: 4)),
      );
      expect(v.text, '2:15');
      expect(parseMinSec(v.text), 135);
    });

    test('ignores non-digits', () {
      expect(typeKeys('1a3b0'), '1:30');
    });

    test('cursor always ends up at the end', () {
      final f = MinSecInputFormatter();
      final v = f.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(text: '9', selection: TextSelection.collapsed(offset: 1)),
      );
      expect(v.selection, const TextSelection.collapsed(offset: 4));
    });
  });

  group('restSecondsBetween', () {
    test('rounds to whole seconds', () {
      expect(restSecondsBetween(1000, 91400), 90);
      expect(restSecondsBetween(0, 1499), 1);
    });

    test('null when either set was not timed or the clock went backwards', () {
      expect(restSecondsBetween(null, 5000), isNull);
      expect(restSecondsBetween(5000, null), isNull);
      expect(restSecondsBetween(5000, 4000), isNull);
    });
  });
}
