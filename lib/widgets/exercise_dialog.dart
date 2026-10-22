import 'package:flutter/material.dart';

import '../models/routine.dart';

/// What the exercise dialog hands back on Save.
class ExerciseFormResult {
  final String name;
  final TrackingType type;
  final int sets;
  ExerciseFormResult(this.name, this.type, this.sets);
}

/// Name + tracking type + set count. Shared by the routine editor and the
/// Today screen's "Add exercise", so both behave and look the same.
class ExerciseDialog extends StatefulWidget {
  final ExerciseDef? existing;
  final List<String> knownNames;

  /// Last-used tracking type per known name. Choosing a suggested name picks
  /// its type too, so an added "Plank" logs time like it always has instead
  /// of starting a separate weights history.
  final Map<String, TrackingType> knownTypes;

  final String? title;
  final String? subtitle;
  final String confirmLabel;

  const ExerciseDialog({
    super.key,
    this.existing,
    required this.knownNames,
    this.knownTypes = const {},
    this.title,
    this.subtitle,
    this.confirmLabel = 'Save',
  });

  @override
  State<ExerciseDialog> createState() => _ExerciseDialogState();
}

class _ExerciseDialogState extends State<ExerciseDialog> {
  /// Owned by the Autocomplete widget, captured here so Save can read it.
  TextEditingController? _fieldCtrl;
  late TrackingType _type;
  late int _sets;

  @override
  void initState() {
    super.initState();
    _type = widget.existing?.type ?? TrackingType.weights;
    _sets = widget.existing?.targetSets ?? 3;
  }

  void _adoptKnownType(String name) {
    // Only for new exercises: editing one shouldn't have its type flipped
    // just because its name was re-picked from the list.
    if (widget.existing != null) return;
    final known = widget.knownTypes[name];
    if (known != null && known != _type) setState(() => _type = known);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title ?? (widget.existing == null ? 'Add exercise' : 'Edit exercise')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.subtitle != null) ...[
              Text(
                widget.subtitle!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
            ],
            // Suggesting names you've used before is what keeps one lift's
            // history on one chart instead of split across near-duplicates.
            Autocomplete<String>(
              initialValue: TextEditingValue(text: widget.existing?.name ?? ''),
              optionsBuilder: (value) {
                final q = value.text.trim().toLowerCase();
                if (q.isEmpty) return const Iterable<String>.empty();
                return widget.knownNames.where(
                    (n) => n.toLowerCase().contains(q) && n.toLowerCase() != q);
              },
              onSelected: _adoptKnownType,
              fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
                // The Autocomplete owns this controller (and disposes it);
                // we only hold the reference so Save can read the text.
                _fieldCtrl = controller;
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  autofocus: widget.existing == null,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Exercise name',
                    hintText: 'e.g. Bench Press',
                  ),
                );
              },
            ),
            const SizedBox(height: 18),
            Text('Track', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: TrackingType.values
                  .map((t) => ChoiceChip(
                        label: Text(t.label),
                        selected: _type == t,
                        onSelected: (_) => setState(() => _type = t),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 6),
            Text(
              typeHint(_type),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Text('Sets', style: Theme.of(context).textTheme.labelMedium),
                const Spacer(),
                IconButton.filledTonal(
                  onPressed: _sets > 1 ? () => setState(() => _sets--) : null,
                  icon: const Icon(Icons.remove, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
                SizedBox(
                  width: 40,
                  child: Text('$_sets',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                IconButton.filledTonal(
                  onPressed: _sets < 20 ? () => setState(() => _sets++) : null,
                  icon: const Icon(Icons.add, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final name = (_fieldCtrl?.text ?? '').trim();
            if (name.isEmpty) {
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(const SnackBar(content: Text('Give the exercise a name.')));
              return;
            }
            Navigator.pop(context, ExerciseFormResult(name, _type, _sets));
          },
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }

  static String typeHint(TrackingType t) {
    switch (t) {
      case TrackingType.weights:
        return 'Logs kilograms × reps, and charts your estimated 1RM.';
      case TrackingType.reps:
        return 'Just a count — push-ups, pull-ups, any bodyweight work.';
      case TrackingType.time:
        return 'Logs a hold in min:sec — planks, dead hangs, stretches.';
      case TrackingType.cardio:
        return 'Logs time (min:sec) and distance, and charts pace.';
      case TrackingType.none:
        return 'No numbers — just tick the set off when it\'s done.';
    }
  }
}
