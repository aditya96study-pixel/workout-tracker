/// Date helpers. Everything in the app stores dates as plain local-calendar
/// 'yyyy-MM-dd' strings, never UTC timestamps, so a workout logged at 11pm
/// stays on the day you actually did it regardless of timezone or DST.
library;

/// 'yyyy-MM-dd' for a DateTime.
String ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Parses a 'yyyy-MM-dd' string into a local midnight DateTime.
DateTime parseYmd(String s) {
  final parts = s.split('-');
  return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
}

/// Today's local calendar date as 'yyyy-MM-dd'.
String todayYmd() => ymd(DateTime.now());

/// The Monday of the week containing [date], as 'yyyy-MM-dd'.
///
/// Uses DateTime's own day-overflow normalization rather than Duration
/// arithmetic, so this can never be knocked off by a daylight-saving shift.
String weekStartOf(DateTime date) {
  final monday = DateTime(date.year, date.month, date.day - (date.weekday - 1));
  return ymd(monday);
}

/// The Monday of the week containing the 'yyyy-MM-dd' string [date].
String weekStartOfYmd(String date) => weekStartOf(parseYmd(date));

/// This week's Monday as 'yyyy-MM-dd'.
String currentWeekStart() => weekStartOf(DateTime.now());

/// The Sunday that ends the week beginning at 'yyyy-MM-dd' [weekStart].
String weekEndOfYmd(String weekStart) {
  final monday = parseYmd(weekStart);
  return ymd(DateTime(monday.year, monday.month, monday.day + 6));
}

/// Whole calendar days from [fromYmd] to [toYmd].
///
/// Normalises through UTC first: a local-time `difference()` across a
/// daylight-saving change is an hour short, and `inDays` truncates that down
/// to the previous day — which would silently stack two chart points on top
/// of each other every spring.
int daysBetween(String fromYmd, String toYmd) {
  final a = parseYmd(fromYmd);
  final b = parseYmd(toYmd);
  return DateTime.utc(b.year, b.month, b.day)
      .difference(DateTime.utc(a.year, a.month, a.day))
      .inDays;
}

/// Next local midnight (start of tomorrow).
DateTime nextMidnight() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day + 1);
}

const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// '12 Aug' — compact date label for chart axes and list rows.
String shortDate(String ymdDate) {
  final d = parseYmd(ymdDate);
  return '${d.day} ${_monthNames[d.month - 1]}';
}

/// 'Mon 12 Aug' — used in week summaries.
String shortDateWithWeekday(String ymdDate) {
  final d = parseYmd(ymdDate);
  return '${_weekdayNames[d.weekday - 1]} ${d.day} ${_monthNames[d.month - 1]}';
}

/// '12 Aug – 18 Aug' for a week beginning at [weekStart].
String weekRangeLabel(String weekStart) =>
    '${shortDate(weekStart)} – ${shortDate(weekEndOfYmd(weekStart))}';

/// 'This week' / 'Last week' / the date range, for week list headers.
String weekHeadline(String weekStart) {
  final current = currentWeekStart();
  if (weekStart == current) return 'This week';
  final lastMonday = parseYmd(current);
  final previous = ymd(DateTime(lastMonday.year, lastMonday.month, lastMonday.day - 7));
  if (weekStart == previous) return 'Last week';
  return weekRangeLabel(weekStart);
}

/// '18:32' local clock time from a millisecond timestamp.
String clockTime(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
