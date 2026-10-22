import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/routine.dart';
import '../models/workout_log.dart';
import '../services/time_format.dart';

/// One exercise card on the Today screen: a row of set checkboxes, each
/// locked until the previous set is checked, plus the numeric inputs that
/// match the exercise's tracking type.
///
/// Locking rule: set N is only checkable once set N-1 is checked (set 1 is
/// always checkable). Unchecking a set also unchecks every later set for the
/// same exercise, so completed sets always form an unbroken run from set 1.
/// Because the rule is scoped to a single exercise, you can move freely
/// between exercises mid-superset without any explicit grouping UI.
///
/// Between two sets sits the rest taken between them: the time from ticking
/// one off to ticking the next, however many other exercises were done in
/// between. Until the later set is ticked, last time's rest is shown greyed,
/// the same way last time's numbers are.
class ExerciseTile extends StatefulWidget {
  final ExerciseDef exercise;
  final List<SetLog> logs; // ordered by set index
  final bool readOnly;
  final void Function(SetLog log, bool checked) onToggleSet;
  final void Function(SetLog updated) onFieldChanged;
  final VoidCallback onAddSet;
  final void Function(SetLog log) onRemoveSet;

  /// Last time's rest before each set, keyed by set position (2 = between
  /// sets 1 and 2). See [DBHelper.getPreviousRestSeconds].
  final Map<int, int> previousRest;

  /// An exercise added to this workout only, not part of the routine.
  final bool isAdhoc;
  final VoidCallback? onRemoveExercise;

  const ExerciseTile({
    super.key,
    required this.exercise,
    required this.logs,
    required this.readOnly,
    required this.onToggleSet,
    required this.onFieldChanged,
    required this.onAddSet,
    required this.onRemoveSet,
    this.previousRest = const {},
    this.isAdhoc = false,
    this.onRemoveExercise,
  });

  @override
  State<ExerciseTile> createState() => _ExerciseTileState();
}

class _ExerciseTileState extends State<ExerciseTile> {
  /// Controllers are keyed by set-log id and seeded once from the stored
  /// value. Every keystroke writes straight through to SQLite, so the stored
  /// value and the field can't drift apart while the tile is alive.
  final Map<String, TextEditingController> _controllers = {};

  @override
  void didUpdateWidget(covariant ExerciseTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Drop controllers for sets that no longer exist, so add/remove cycles
    // don't accumulate live controllers for the life of the tile.
    final liveIds = widget.logs.map((l) => l.id).whereType<int>().toSet();
    _controllers.removeWhere((key, controller) {
      final id = int.tryParse(key.split('_').first);
      if (id != null && liveIds.contains(id)) return false;
      controller.dispose();
      return true;
    });
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _ctrl(SetLog log, String field, String? initial) {
    return _controllers.putIfAbsent(
      '${log.id}_$field',
      () => TextEditingController(text: initial ?? ''),
    );
  }

  bool _canCheck(int index) => index == 0 || widget.logs[index - 1].checked;

  int get _checkedCount => widget.logs.where((l) => l.checked).length;

  bool get _hasPrefill => widget.logs.any((l) => l.prefilled && !l.checked);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final done = _checkedCount;
    final total = widget.logs.length;
    final allDone = total > 0 && done == total;

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: allDone ? scheme.primary.withAlpha(90) : scheme.outlineVariant.withAlpha(120),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    widget.exercise.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: allDone ? scheme.primary : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 4),
                  child: Text(
                    '$done/$total',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: allDone ? scheme.primary : scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (widget.isAdhoc && !widget.readOnly && widget.onRemoveExercise != null)
                  SizedBox(
                    height: 28,
                    width: 32,
                    child: IconButton(
                      tooltip: 'Remove from this workout',
                      padding: EdgeInsets.zero,
                      iconSize: 18,
                      icon: Icon(Icons.delete_outline, color: scheme.onSurfaceVariant),
                      onPressed: widget.onRemoveExercise,
                    ),
                  ),
              ],
            ),
            _buildSubtitle(context),
            const SizedBox(height: 8),
            for (var i = 0; i < widget.logs.length; i++) ...[
              if (i > 0) _buildRestRow(context, i),
              _buildSetRow(context, i),
            ],
            if (_hasPrefill && !widget.readOnly)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 2),
                child: Row(
                  children: [
                    Icon(Icons.history, size: 13, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        'Greyed numbers are last time\'s — edit or just tick to keep',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            if (!widget.readOnly)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: widget.onAddSet,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add set'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// "Weights", plus an "Added today" tag on an exercise that isn't part of
  /// the routine.
  Widget _buildSubtitle(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasType = widget.exercise.type != TrackingType.none;
    if (!hasType && !widget.isAdhoc) return const SizedBox.shrink();
    return Row(
      children: [
        if (hasType)
          Text(
            widget.exercise.type.label,
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        if (hasType && widget.isAdhoc) const SizedBox(width: 6),
        if (widget.isAdhoc)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'Added today',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onTertiaryContainer, fontSize: 10),
            ),
          ),
      ],
    );
  }

  /// The rest between set [index] - 1 and set [index]. Shows this workout's
  /// rest once both are ticked, last time's (greyed) until then, and nothing
  /// when neither is known.
  Widget _buildRestRow(BuildContext context, int index) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final before = widget.logs[index - 1];
    final after = widget.logs[index];

    final int? seconds;
    final bool isCurrent;
    if (after.checked) {
      seconds = before.checked
          ? restSecondsBetween(before.checkedAtMs, after.checkedAtMs)
          : null;
      isCurrent = true;
    } else {
      seconds = widget.readOnly ? null : widget.previousRest[index + 1];
      isCurrent = false;
    }
    if (seconds == null) return const SizedBox.shrink();

    final color = isCurrent ? scheme.primary : scheme.onSurfaceVariant.withAlpha(150);
    final label = isCurrent
        ? 'Rest ${formatMinSec(seconds)}'
        : 'Rest ${formatMinSec(seconds)} last time';

    return Padding(
      padding: const EdgeInsets.only(left: 30, top: 1, bottom: 1),
      child: Semantics(
        label: isCurrent
            ? 'Rested ${formatMinSec(seconds)} before set ${index + 1}'
            : 'Last time rested ${formatMinSec(seconds)} before set ${index + 1}',
        excludeSemantics: true,
        child: Row(
          children: [
            Icon(Icons.timer_outlined, size: 12, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSetRow(BuildContext context, int index) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final log = widget.logs[index];
    final canCheck = _canCheck(index);
    final locked = !widget.readOnly && !log.checked && !canCheck;
    // Sets beyond the routine's count can be removed. An added exercise has
    // no routine count, so only its last set offers that — removing the
    // whole exercise is the bin icon in its header.
    final isExtra = widget.isAdhoc
        ? index == widget.logs.length - 1 && widget.logs.length > 1
        : index >= widget.exercise.targetSets;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            child: Row(
              children: [
                if (locked)
                  Icon(Icons.lock_outline, size: 13, color: scheme.onSurfaceVariant.withAlpha(140))
                else
                  Text(
                    '${index + 1}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: log.checked ? scheme.primary : scheme.onSurfaceVariant,
                      fontWeight: log.checked ? FontWeight.w600 : null,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: _buildInputs(log, locked: locked)),
          if (isExtra && !widget.readOnly)
            IconButton(
              tooltip: 'Remove this set',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              icon: const Icon(Icons.close),
              onPressed: () => widget.onRemoveSet(log),
            ),
          Semantics(
            label: locked
                ? 'Set ${index + 1}, locked until set $index is done'
                : 'Set ${index + 1}',
            child: Checkbox(
              value: log.checked,
              onChanged: (widget.readOnly || locked)
                  ? null
                  : (value) => widget.onToggleSet(log, value ?? false),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputs(SetLog log, {required bool locked}) {
    switch (widget.exercise.type) {
      case TrackingType.weights:
        return Row(
          children: [
            Expanded(
              flex: 5,
              child: _numField(
                log: log,
                field: 'weight',
                initial: _fmtNum(log.weightKg),
                suffix: 'kg',
                locked: locked,
                onParsed: (text) =>
                    log.copyWith(weightKg: _parseDouble(text), prefilled: false),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text('×', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
            Expanded(
              flex: 4,
              child: _numField(
                log: log,
                field: 'reps',
                initial: log.reps?.toString(),
                suffix: 'reps',
                locked: locked,
                integer: true,
                onParsed: (text) =>
                    log.copyWith(reps: _parseInt(text), prefilled: false),
              ),
            ),
          ],
        );

      case TrackingType.reps:
        // Bodyweight work: a count and nothing else.
        return _numField(
          log: log,
          field: 'reps',
          initial: log.reps?.toString(),
          suffix: 'reps',
          locked: locked,
          integer: true,
          onParsed: (text) => log.copyWith(reps: _parseInt(text), prefilled: false),
        );

      case TrackingType.time:
        return _numField(
          log: log,
          field: 'hold',
          initial: _fmtTime(log.holdSeconds),
          suffix: 'min',
          locked: locked,
          time: true,
          onParsed: (text) =>
              log.copyWith(holdSeconds: parseMinSec(text), prefilled: false),
        );

      case TrackingType.cardio:
        return Row(
          children: [
            Expanded(
              child: _numField(
                log: log,
                field: 'cardioSec',
                initial: _fmtTime(log.cardioSeconds),
                suffix: 'min',
                locked: locked,
                time: true,
                onParsed: (text) =>
                    log.copyWith(cardioSeconds: parseMinSec(text), prefilled: false),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _numField(
                log: log,
                field: 'cardioKm',
                initial: _fmtNum(log.cardioDistanceKm),
                suffix: 'km',
                locked: locked,
                onParsed: (text) =>
                    log.copyWith(cardioDistanceKm: _parseDouble(text), prefilled: false),
              ),
            ),
          ],
        );

      case TrackingType.none:
        return const SizedBox(height: 40);
    }
  }

  Widget _numField({
    required SetLog log,
    required String field,
    required String? initial,
    required String suffix,
    required bool locked,
    required SetLog Function(String text) onParsed,
    bool integer = false,
    bool time = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final muted = log.prefilled && !log.checked;

    return TextField(
      controller: _ctrl(log, field, initial),
      enabled: !widget.readOnly && !locked,
      keyboardType: time
          ? TextInputType.number
          : TextInputType.numberWithOptions(decimal: !integer),
      inputFormatters: time
          ? [MinSecInputFormatter()]
          : [
              FilteringTextInputFormatter.allow(integer ? RegExp(r'[0-9]') : RegExp(r'[0-9.]')),
              if (!integer) _SingleDecimalFormatter(),
            ],
      style: TextStyle(
        fontSize: 15,
        color: muted ? scheme.onSurfaceVariant.withAlpha(150) : null,
        fontFeatures: time ? const [FontFeature.tabularFigures()] : null,
      ),
      decoration: InputDecoration(
        isDense: true,
        hintText: time ? '0:00' : null,
        hintStyle: TextStyle(color: scheme.onSurfaceVariant.withAlpha(110)),
        suffixText: suffix,
        suffixStyle: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      onChanged: (text) => widget.onFieldChanged(onParsed(text)),
    );
  }

  /// Text that isn't a usable number yet — "12." mid-typing, or an empty
  /// field — resolves to null, which clears the stored value.
  ///
  /// Storing null rather than keeping the old number is the safe choice: it
  /// makes [SetLog.hasRequiredValue] false, so the set can't be ticked while
  /// the box shows something the database doesn't agree with. Keeping the old
  /// value would let a carried-forward weight be logged as if it had been
  /// confirmed, with a different number visible on screen.
  static double? _parseDouble(String text) {
    final v = double.tryParse(text.trim());
    if (v == null || v < 0 || v.isNaN || v.isInfinite) return null;
    return v;
  }

  static int? _parseInt(String text) {
    final v = int.tryParse(text.trim());
    if (v == null || v < 0) return null;
    return v;
  }

  static String? _fmtTime(int? seconds) => seconds == null ? null : formatMinSec(seconds);

  /// Trims the pointless '.0' off whole numbers so the field reads "60" not
  /// "60.0" when last week's weight is carried forward.
  static String? _fmtNum(double? v) {
    if (v == null) return null;
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toString();
  }
}

/// Keeps a decimal field to at most one '.' and two decimal places, so it's
/// impossible to type something like "1.2.3" that no parser will accept.
class _SingleDecimalFormatter extends TextInputFormatter {
  static final _valid = RegExp(r'^\d*\.?\d{0,2}$');

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.isEmpty || _valid.hasMatch(newValue.text)) return newValue;
    return oldValue;
  }
}
