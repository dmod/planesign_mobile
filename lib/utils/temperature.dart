/// Parses output from `/usr/bin/vcgencmd measure_temp`.
///
/// Typical formats:
/// - `temp=43.2'C`
/// - `temp=43.2'C\n`
/// - `43.2` (already cleaned)
double? parseVcgencmdTemperatureC(String raw) {
  final s = raw.trim();
  if (s.isEmpty || s == 'No value' || s == 'No reading' || s == 'Unknown') return null;

  final match = RegExp(r'(-?\d+(?:\.\d+)?)').firstMatch(s);
  if (match == null) return null;
  return double.tryParse(match.group(1)!);
}

/// Formats vcgencmd output into a human readable string like `43.2 °C`.
String formatRpiTemperature(String raw) {
  final celsius = parseVcgencmdTemperatureC(raw);
  if (celsius == null) {
    final s = raw.trim();
    return s.isEmpty ? 'Unknown' : s;
  }

  final rounded = (celsius * 10).roundToDouble() / 10;
  final showDecimal = (rounded % 1) != 0;
  final number = showDecimal ? rounded.toStringAsFixed(1) : rounded.toStringAsFixed(0);
  return '$number °C';
}
