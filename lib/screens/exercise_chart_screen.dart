import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../db/db_helper.dart';
import '../models/routine.dart';
import '../services/app_dates.dart';
import '../services/one_rm.dart';
import '../services/time_format.dart';

/// How several sets on the same date collapse into one chart point.
enum _Agg { max, min, sum }

/// One point on the progress chart: the best value achieved on a given date.
class _Point {
  final double x; // days since the first data point
  final String date;
  final double y;
  const _Point(this.x, this.date, this.y);
}

class ExerciseChartScreen extends StatefulWidget {
  final String exerciseName;
  const ExerciseChartScreen({super.key, required this.exerciseName});

  @override
  State<ExerciseChartScreen> createState() => _ExerciseChartScreenState();
}

class _ExerciseChartScreenState extends State<ExerciseChartScreen> {
  final TransformationController _zoom = TransformationController();

  bool _loading = true;
  List<Map<String, Object?>> _rows = [];
  TrackingType _type = TrackingType.weights;
  ChartMetric _metric = ChartMetric.oneRepMax;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _zoom.addListener(_onZoomChanged);
    _load();
  }

  @override
  void dispose() {
    _zoom.removeListener(_onZoomChanged);
    _zoom.dispose();
    super.dispose();
  }

  void _onZoomChanged() {
    final scaled = _zoom.value.getMaxScaleOnAxis() > 1.01;
    if (scaled != _zoomed && mounted) setState(() => _zoomed = scaled);
  }

  Future<void> _load() async {
    final rows = await DBHelper.instance.getHistoryForExercise(widget.exerciseName);
    if (!mounted) return;
    final type = rows.isNotEmpty
        ? TrackingTypeX.fromDbValue(rows.first['type'] as String)
        : TrackingType.weights;
    setState(() {
      _rows = rows;
      _type = type;
      _metric = switch (type) {
        TrackingType.weights => ChartMetric.oneRepMax,
        TrackingType.reps => ChartMetric.repsMax,
        TrackingType.time => ChartMetric.holdSeconds,
        TrackingType.cardio => ChartMetric.cardioDistanceKm,
        TrackingType.none => ChartMetric.oneRepMax,
      };
      _loading = false;
    });
  }

  /// Reduces every checked set to one value per date — the best of that day
  /// for the selected metric. "Best" means highest, except for pace where
  /// faster is lower.
  List<_Point> _computePoints() {
    if (_rows.isEmpty) return const [];
    final byDate = <String, double>{};

    for (final row in _rows) {
      final date = row['date'] as String;
      double? value;
      var agg = _Agg.max;

      switch (_metric) {
        case ChartMetric.oneRepMax:
          final w = (row['weight_kg'] as num?)?.toDouble();
          final reps = (row['reps'] as num?)?.toInt();
          if (w != null && reps != null) {
            value = estimateOneRepMax(weightKg: w, reps: reps);
          }
          break;
        case ChartMetric.repsMax:
          value = (row['reps'] as num?)?.toDouble();
          break;
        case ChartMetric.repsTotal:
          // Every set of the day adds up, rather than the best one winning —
          // 5 sets of 8 push-ups is progress over 4 sets of 8 even though the
          // best set didn't move.
          value = (row['reps'] as num?)?.toDouble();
          agg = _Agg.sum;
          break;
        case ChartMetric.holdSeconds:
          value = (row['hold_seconds'] as num?)?.toDouble();
          break;
        case ChartMetric.cardioDistanceKm:
          value = (row['cardio_distance_km'] as num?)?.toDouble();
          break;
        case ChartMetric.cardioDurationSeconds:
          value = (row['cardio_seconds'] as num?)?.toDouble();
          break;
        case ChartMetric.cardioPaceMinPerKm:
          final paceSecs = (row['cardio_seconds'] as num?)?.toInt();
          final paceKm = (row['cardio_distance_km'] as num?)?.toDouble();
          if (paceSecs != null && paceKm != null) {
            value = computePaceSecondsPerKm(seconds: paceSecs, distanceKm: paceKm);
          }
          agg = _Agg.min;
          break;
      }

      if (value == null || value.isNaN || value.isInfinite) continue;
      final current = byDate[date];
      if (current == null) {
        byDate[date] = value;
      } else {
        byDate[date] = switch (agg) {
          _Agg.max => value > current ? value : current,
          _Agg.min => value < current ? value : current,
          _Agg.sum => current + value,
        };
      }
    }

    final dates = byDate.keys.toList()..sort();
    if (dates.isEmpty) return const [];
    return [
      for (final d in dates) _Point(daysBetween(dates.first, d).toDouble(), d, byDate[d]!)
    ];
  }

  bool get _lowerIsBetter => _metric == ChartMetric.cardioPaceMinPerKm;

  /// Exercise types that can be read more than one way get a toggle; the rest
  /// have a single sensible metric and no selector at all.
  List<ChartMetric> get _metricOptions => switch (_type) {
        TrackingType.cardio => const [
            ChartMetric.cardioDistanceKm,
            ChartMetric.cardioDurationSeconds,
            ChartMetric.cardioPaceMinPerKm,
          ],
        TrackingType.reps => const [ChartMetric.repsMax, ChartMetric.repsTotal],
        _ => const <ChartMetric>[],
      };

  @override
  Widget build(BuildContext context) {
    final points = _computePoints();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.exerciseName, overflow: TextOverflow.ellipsis),
        actions: [
          if (_zoomed)
            IconButton(
              tooltip: 'Reset zoom',
              icon: const Icon(Icons.zoom_out_map),
              onPressed: () => _zoom.value = Matrix4.identity(),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : points.isEmpty
              ? const Center(child: Text('Not enough data yet.'))
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_metricOptions.isNotEmpty) ...[
                        _MetricSelector(
                          options: _metricOptions,
                          value: _metric,
                          onChanged: (m) {
                            _zoom.value = Matrix4.identity();
                            setState(() => _metric = m);
                          },
                        ),
                        const SizedBox(height: 14),
                      ],
                      _StatRow(
                        points: points,
                        unit: _unitSuffix(),
                        lowerIsBetter: _lowerIsBetter,
                        format: _formatValue,
                      ),
                      const SizedBox(height: 18),
                      Text(
                        _metric.label,
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: _Chart(
                          points: points,
                          unitSuffix: _unitSuffix(),
                          zoom: _zoom,
                          format: _formatValue,
                          isDuration: _metric.isDuration,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        points.length < 2
                            ? 'Tap the point for its exact value. Log this exercise on another '
                                'day and the chart becomes zoomable.'
                            : 'Tap a point for its exact value · pinch to zoom, drag to pan',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
    );
  }

  String _formatValue(double v) =>
      _metric.isDuration ? formatMinSec(v.round()) : _StatRow._fmt(v);

  String _unitSuffix() {
    switch (_metric) {
      case ChartMetric.oneRepMax:
        return 'kg';
      case ChartMetric.repsMax:
      case ChartMetric.repsTotal:
        return 'reps';
      case ChartMetric.holdSeconds:
        return 'min';
      case ChartMetric.cardioDistanceKm:
        return 'km';
      case ChartMetric.cardioDurationSeconds:
        return 'min';
      case ChartMetric.cardioPaceMinPerKm:
        return '/km';
    }
  }
}

/// Current / best / change. The current value doubles as the chart's direct
/// label, which is why no number is drawn on the points themselves.
class _StatRow extends StatelessWidget {
  final List<_Point> points;
  final String unit;
  final bool lowerIsBetter;
  final String Function(double) format;

  const _StatRow({
    required this.points,
    required this.unit,
    required this.lowerIsBetter,
    required this.format,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final latest = points.last.y;
    final best = lowerIsBetter
        ? points.map((p) => p.y).reduce((a, b) => a < b ? a : b)
        : points.map((p) => p.y).reduce((a, b) => a > b ? a : b);

    double? delta;
    if (points.length >= 2) delta = latest - points[points.length - 2].y;
    final improved = delta == null ? null : (lowerIsBetter ? delta < 0 : delta > 0);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Latest',
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 2),
              Text(
                '${format(latest)} $unit',
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(shortDate(points.last.date),
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Best',
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 2),
              Text('${format(best)} $unit',
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        if (delta != null && delta.abs() > 0.0001)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('vs last time',
                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(
                      delta > 0 ? Icons.arrow_upward : Icons.arrow_downward,
                      size: 15,
                      color: improved == true ? scheme.primary : scheme.error,
                    ),
                    const SizedBox(width: 2),
                    Flexible(
                      child: Text(
                        format(delta.abs()),
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: improved == true ? scheme.primary : scheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _fmt(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(1);
  }
}

class _MetricSelector extends StatelessWidget {
  final List<ChartMetric> options;
  final ChartMetric value;
  final ValueChanged<ChartMetric> onChanged;
  const _MetricSelector({
    required this.options,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ChartMetric>(
      showSelectedIcon: false,
      segments: options
          .map((m) => ButtonSegment(value: m, label: Text(_shortLabel(m))))
          .toList(),
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }

  static String _shortLabel(ChartMetric m) {
    switch (m) {
      case ChartMetric.cardioDistanceKm:
        return 'Distance';
      case ChartMetric.cardioDurationSeconds:
        return 'Duration';
      case ChartMetric.cardioPaceMinPerKm:
        return 'Pace';
      case ChartMetric.repsMax:
        return 'Best set';
      case ChartMetric.repsTotal:
        return 'Total';
      default:
        return m.label;
    }
  }
}

class _Chart extends StatelessWidget {
  final List<_Point> points;
  final String unitSuffix;
  final TransformationController zoom;
  final String Function(double) format;

  /// Y values are seconds: axis ticks land on round times (0:30, 1:00, ...)
  /// rather than wherever plain-number spacing would put them.
  final bool isDuration;

  const _Chart({
    required this.points,
    required this.unitSuffix,
    required this.zoom,
    required this.format,
    required this.isDuration,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final line = scheme.primary;

    final spots = [for (final p in points) FlSpot(p.x, p.y)];
    final ys = points.map((p) => p.y);
    final minY = ys.reduce((a, b) => a < b ? a : b);
    final maxY = ys.reduce((a, b) => a > b ? a : b);
    final yPad = (maxY - minY).abs() * 0.18 + (maxY == minY ? (maxY.abs() * 0.1 + 1) : 0.5);

    // A single point still needs a span, otherwise the plot area collapses.
    final maxX = points.last.x;
    final xPad =
        points.length < 2 ? 1.0 : (maxX * 0.04).clamp(0.4, 3.0).toDouble();
    final yInterval = isDuration ? _durationInterval((maxY + yPad) - (minY - yPad)) : null;

    return LineChart(
      LineChartData(
        minX: -xPad,
        maxX: maxX + xPad,
        minY: minY - yPad,
        maxY: maxY + yPad,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: yInterval,
          getDrawingHorizontalLine: (value) => FlLine(
            color: scheme.outlineVariant.withAlpha(90),
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 46,
              interval: yInterval,
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  isDuration ? _durationLabel(value, yInterval!) : _axisNumber(value),
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              interval: _bottomInterval(),
              getTitlesWidget: (value, meta) {
                // The left edge sits just before the first point, which is
                // already labelled at x = 0; labelling the edge too printed
                // the first date twice, one on top of the other.
                if (value == meta.min && value < 0) return const SizedBox.shrink();
                // Only label x positions that correspond to a real session.
                final matches = points.where((p) => (p.x - value).abs() < 0.5);
                if (matches.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    shortDate(matches.first.date),
                    style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                  ),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          enabled: true,
          handleBuiltInTouches: true,
          touchTooltipData: LineTouchTooltipData(
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            tooltipBorderRadius: BorderRadius.circular(8),
            getTooltipColor: (_) => scheme.inverseSurface,
            getTooltipItems: (touched) => touched.map((s) {
              final matches = points.where((p) => (p.x - s.x).abs() < 0.001);
              final date = matches.isEmpty ? '' : shortDate(matches.first.date);
              return LineTooltipItem(
                '$date\n',
                TextStyle(
                  color: scheme.onInverseSurface.withAlpha(190),
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                ),
                children: [
                  TextSpan(
                    text: '${format(s.y)} $unitSuffix',
                    style: TextStyle(
                      color: scheme.onInverseSurface,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: false,
            barWidth: 2,
            color: line,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
                radius: 4,
                color: line,
                // A surface-coloured ring keeps overlapping points readable.
                strokeWidth: 2,
                strokeColor: scheme.surface,
              ),
            ),
            belowBarData: BarAreaData(show: true, color: line.withAlpha(28)),
          ),
        ],
      ),
      // Zoom/pan is handled natively by fl_chart. Wrapping the chart in an
      // InteractiveViewer (the previous approach) fights the chart's own
      // gesture arena and swallows both the pinch and the tap-to-read —
      // which is why pinching appeared to do nothing.
      transformationConfig: FlTransformationConfig(
        scaleAxis: FlScaleAxis.horizontal,
        minScale: 1,
        maxScale: 10,
        panEnabled: true,
        scaleEnabled: points.length > 1,
        transformationController: zoom,
      ),
    );
  }

  double _bottomInterval() {
    if (points.length < 2) return 1.0;
    final span = points.last.x;
    if (span <= 0) return 1.0;
    // Aim for roughly five labels across the axis.
    final raw = span / 5;
    return raw < 1 ? 1.0 : raw.ceilToDouble();
  }

  /// Only round steps get a label. The chart also labels its top and bottom
  /// edges, which for a duration would read as odd times like 1:18.
  static String _durationLabel(double value, double interval) {
    if (value < 0) return '';
    final steps = value / interval;
    if ((steps - steps.round()).abs() > 0.001) return '';
    return formatMinSec(value.round());
  }

  /// A round step in seconds that gives roughly four to six ticks.
  static double _durationInterval(double span) {
    const steps = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200];
    final target = span / 5;
    for (final step in steps) {
      if (step >= target) return step.toDouble();
    }
    return steps.last.toDouble();
  }

  static String _axisNumber(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(1);
  }
}
