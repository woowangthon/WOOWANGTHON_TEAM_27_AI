/// Traffic JSON without an offset is a Korean wall clock, independently of host TZ.
DateTime trafficInstant(String value) {
  final s = value.trim();
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?(Z|[+-]\d{2}:\d{2})?$').hasMatch(s)) {
    throw const FormatException('Invalid traffic time');
  }
  final zone = RegExp(r'([+-])(\d{2}):(\d{2})$').firstMatch(s);
  if (zone != null && (int.parse(zone[2]!) > 23 || int.parse(zone[3]!) > 59)) {
    throw const FormatException('Invalid traffic offset');
  }
  final explicit = RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(s);
  final result = DateTime.parse(explicit ? s : '$s+09:00').toUtc();
  // DateTime.parse normalizes invalid calendar dates. Check wall components too.
  final offset = explicit ? DateTime.parse(s).timeZoneOffset : const Duration(hours: 9);
  final suffix = RegExp(r'([+-])(\d{2}):(\d{2})$').firstMatch(s);
  final wall = result.add(
    suffix == null
        ? offset
        : Duration(minutes: (suffix[1] == '-' ? -1 : 1) * (int.parse(suffix[2]!) * 60 + int.parse(suffix[3]!))),
  );
  final p = RegExp(r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?').firstMatch(s)!;
  final values = [wall.year, wall.month, wall.day, wall.hour, wall.minute, wall.second];
  for (var i = 0; i < values.length; i++) {
    if (values[i] != int.parse(p[i + 1] ?? '0')) throw const FormatException('Invalid calendar time');
  }
  return result;
}

/// Legacy Dart constructors represent KST wall time; explicit UTC remains an instant.
DateTime trafficUtc(DateTime d) => d.isUtc
    ? d
    : DateTime.utc(
        d.year,
        d.month,
        d.day,
        d.hour,
        d.minute,
        d.second,
        d.millisecond,
        d.microsecond,
      ).subtract(const Duration(hours: 9));
DateTime trafficKst(DateTime d) => trafficUtc(d).add(const Duration(hours: 9));
DateTime trafficDay(DateTime d) {
  final k = trafficKst(d);
  return DateTime.utc(k.year, k.month, k.day).subtract(const Duration(hours: 9));
}

bool safeTrafficUrl(String? value) {
  final u = value == null ? null : Uri.tryParse(value);
  if (u == null || !{'http', 'https'}.contains(u.scheme) || u.userInfo.isNotEmpty || u.fragment.isNotEmpty) {
    return false;
  }
  if (!{'www.utic.go.kr', 'utic.go.kr', 'topis.seoul.go.kr', 'www.its.go.kr'}.contains(u.host)) return false;
  return !u.queryParameters.keys.any((k) => RegExp(r'key|token|secret|auth', caseSensitive: false).hasMatch(k));
}

/// Conservative literal rule v2. Negative/conditional/ambiguous notices never
/// become confirmed just because an earlier part contains a positive keyword.
bool explicitRoadControl(String text) {
  final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  // Releases or cancellations conflict with a positive control phrase.
  if (RegExp(r'해제|철회|취소').hasMatch(normalized)) return false;
  const control = r'(?:통제|통행\s*금지)';
  const particle = r'(?:은|는|이|가|를|을|도)?';
  final prefix = '$control\\s*$particle\\s*';
  final negative = RegExp(
    '$prefix'
    r'(?:(?:구간|계획|예정)\s*)?'
    r'(?:(?:실시|시행|진행|실행)(?:되)?\s*)?'
    r'(?:없|않|아니|아닌|아닙|아님|하지|하진|되지|안\s*(?:함|합|하)|미실시|미시행|미확정|미정|불필요)',
  );
  final conditional = RegExp(
    '$prefix'
    r'(?:여부|검토|가능|조건부|시(?=\s|$)|하면|한다면|할\s*(?:수|때|경우)|될\s*(?:수|경우))',
  );
  final finished = RegExp(
    '$prefix'
    r'(?:종료|완료)(?!\s*(?:예정|시|후|까지))',
  );
  final signWork = RegExp(
    '$control'
    r'\s*(?:표지판?|표지)\s*(?:제거|철거|설치|보수)',
  );
  if (negative.hasMatch(normalized) ||
      conditional.hasMatch(normalized) ||
      finished.hasMatch(normalized) ||
      signWork.hasMatch(normalized) ||
      RegExp(r'(?:미|비|무)\s*통제').hasMatch(normalized)) {
    return false;
  }
  return RegExp(r'\[통제\]|전면\s*통제|부분\s*통제|차량\s*통제|도로\s*통제|차로\s*통제|통행\s*금지').hasMatch(normalized);
}
