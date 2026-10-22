/// Estimated one-rep max using the Epley formula, the standard, simple
/// formula most lifting apps default to:
///   1RM = weight * (1 + reps / 30)
/// At reps == 1 this correctly returns the weight itself.
double estimateOneRepMax({required double weightKg, required int reps}) {
  if (weightKg <= 0 || reps <= 0) return 0;
  if (reps == 1) return weightKg;
  return weightKg * (1 + reps / 30);
}

/// Which numeric metric a history chart is plotting for a given exercise.
enum ChartMetric {
  oneRepMax,
  repsMax,
  repsTotal,
  holdSeconds,
  cardioDistanceKm,
  cardioDurationSeconds,
  cardioPaceMinPerKm,
}

extension ChartMetricX on ChartMetric {
  String get label {
    switch (this) {
      case ChartMetric.oneRepMax:
        return 'Estimated 1RM (kg)';
      case ChartMetric.repsMax:
        return 'Best set (reps)';
      case ChartMetric.repsTotal:
        return 'Total reps per session';
      case ChartMetric.holdSeconds:
        return 'Hold time (min:sec)';
      case ChartMetric.cardioDistanceKm:
        return 'Distance (km)';
      case ChartMetric.cardioDurationSeconds:
        return 'Duration (min:sec)';
      case ChartMetric.cardioPaceMinPerKm:
        return 'Pace (min:sec per km)';
    }
  }

  /// Metrics whose values are durations in seconds, shown as min:sec.
  bool get isDuration =>
      this == ChartMetric.holdSeconds ||
      this == ChartMetric.cardioDurationSeconds ||
      this == ChartMetric.cardioPaceMinPerKm;
}

/// Pace in seconds per km, so it can be shown as min:sec like every other
/// duration. Returns null if distance is zero (can't compute).
double? computePaceSecondsPerKm({required int seconds, required double distanceKm}) {
  if (distanceKm <= 0) return null;
  return seconds / distanceKm;
}
