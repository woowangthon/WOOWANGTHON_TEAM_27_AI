import 'models.dart';
import 'domestic_news.dart';

/// Trusted, versioned public transport reference supplied by the backend.
/// Route names from providers are only mapped with region + mode + validity.
class TrafficReference {
  const TrafficReference({
    required this.id,
    required this.raw,
    required this.region,
    required this.mode,
    required this.source,
    required this.asOf,
    this.aliases = const [],
    this.validFrom,
    this.validUntil,
    this.demo = false,
  });
  final String id, raw, region, mode, source;
  final DateTime asOf;
  final DateTime? validFrom, validUntil;
  final List<String> aliases;
  final bool demo;
  factory TrafficReference.fromJson(Map<String, dynamic> json) {
    for (final key in ['id', 'raw', 'region', 'mode', 'source', 'as_of']) {
      if (json[key] is! String || (json[key] as String).isEmpty) {
        throw const FormatException('Invalid transport reference');
      }
    }
    DateTime date(String key) {
      final value = json[key] as String;
      final parsed = DateTime.tryParse(value);
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
          parsed == null ||
          !parsed.toIso8601String().startsWith(value)) {
        throw const FormatException('Invalid reference date');
      }
      return parsed;
    }

    return TrafficReference(
      id: json['id'] as String,
      raw: json['raw'] as String,
      region: json['region'] as String,
      mode: json['mode'] as String,
      source: json['source'] as String,
      asOf: date('as_of'),
      aliases: List<String>.from(json['aliases'] as List? ?? const []),
      validFrom: json['valid_from'] == null ? null : date('valid_from'),
      validUntil: json['valid_until'] == null ? null : date('valid_until'),
      demo: json['demo'] == true,
    );
  }
}

Set<String> resolveTripFacilityIds({
  required List<String> lines,
  required Set<String> modes,
  required String region,
  required DateTime departure,
  required bool demo,
  required List<TrafficReference> references,
}) {
  String normalize(String value) =>
      value.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  final ids = <String>{};
  final day = DateTime(departure.year, departure.month, departure.day);
  for (final line in lines) {
    final candidates = references
        .where(
          (r) =>
              r.demo == demo &&
              r.region == region &&
              modes.contains(r.mode) &&
              !day.isBefore(r.asOf) &&
              (r.validFrom == null || !day.isBefore(r.validFrom!)) &&
              (r.validUntil == null || !day.isAfter(r.validUntil!)) &&
              [
                r.raw,
                ...r.aliases,
              ].any((label) => normalize(label) == normalize(line)),
        )
        .toList();
    // An ambiguous name is not a verified route identity.
    if (candidates.length == 1) ids.add(candidates.single.id);
  }
  return ids;
}

/// Saved route facts, separate from the calendar appointment. Empty mode/ID sets
/// mean unknown; a route label is never silently promoted to a verified ID.
class TripContext {
  const TripContext({
    required this.id,
    required this.version,
    required this.departure,
    required this.arrival,
    this.modes = const {},
    this.facilityIds = const {},
    this.lines = const [],
    this.points = const [],
    this.passageAt,
    this.direction,
    this.section,
    this.timeConfirmed = true,
  });
  final String id, version;
  final DateTime departure, arrival;
  final DateTime? passageAt;
  final String? direction, section;
  final bool timeConfirmed;
  final Set<String> modes, facilityIds;
  final List<String> lines;
  final List<GeoPoint> points;
}

/// Immutable projection of a backend-validated full-body traffic record.
/// The original 11-field strike schema remains in the backend; old news.json
/// strike entries remain compatible and are only unverified reference cards.
class NewsTrafficImpact {
  NewsTrafficImpact._(this._json);
  final Map<String, dynamic> _json;
  String get id => _json['id'] as String;
  String get eventId => _json['event_id'] as String;
  int get version => _json['version'] as int;
  String get type => _json['type'] as String;
  String get status => _json['status'] as String;
  String get assertion => _json['assertion'] as String;
  String get name => _json['event_name'] as String? ?? '교통 영향';
  String get sourceUrl => _json['source_url'] as String;
  bool get conflict => _json['conflict'] == true;
  bool get demo => _json['demo'] == true;
  bool get domestic => DomesticNews.accepts(
    '$name ${evidence.map((e) => e['quote']).join(' ')}',
  );
  bool get hasTransportEvidence => evidence.any((e) {
    final quote = e['quote'] as String;
    if (RegExp(r'혼잡.*(?:없|않|아니)|통제.*(?:없|하지 않)|정상 통행').hasMatch(quote)) {
      return false;
    }
    return switch (type) {
      'STRIKE' => quote.contains('파업'),
      'CONGESTION_FORECAST' =>
        RegExp(r'(?:교통|차량|보행).*혼잡.*(?:예상|전망)').hasMatch(quote),
      'ROAD_CLOSURE' => RegExp(r'(?:도로|차량|대로|구간).*통제').hasMatch(quote),
      'BUS_DETOUR' => RegExp(r'버스.*우회').hasMatch(quote),
      'STOP_SKIP' => quote.contains('무정차'),
      'STATION_RESTRICTION' => RegExp(r'출입구.*폐쇄|역.*이용 제한').hasMatch(quote),
      _ => false,
    };
  });
  // The radius must be supplied by a trusted geographic reference for the
  // affected scope. An event coordinate alone is not an impact area.
  double? get verifiedRadiusKm {
    final radius = _json['affected_radius_m'];
    return radius is num && radius.isFinite && radius > 0 &&
            _json['area_reference_source'] is String &&
            (_json['area_reference_source'] as String).isNotEmpty
        ? radius.toDouble() / 1000
        : null;
  }
  Map<String, dynamic> get period =>
      (_json['period'] as Map).cast<String, dynamic>();
  List<Map<String, dynamic>> get scope => maps(_json['scope']);
  List<Map<String, dynamic>> get evidence => maps(_json['evidence']);
  List<Map<String, dynamic>> get exceptions => maps(_json['exceptions']);
  Set<String> get modes => Set<String>.from(_json['modes'] as List);
  Set<String> get facilityIds => {
    for (final s in scope)
      if (s['reference_id'] is String) s['reference_id'] as String,
  };
  Set<String> get regions => {
    for (final s in scope)
      if (s['region'] is String) s['region'] as String,
  };
  GeoPoint? get verifiedPoint {
    final p = _json['verified_point'];
    if (p is! List ||
        p.length != 2 ||
        _json['point_reference_source'] is! String) {
      return null;
    }
    return GeoPoint((p[0] as num).toDouble(), (p[1] as num).toDouble());
  }

  Map<String, dynamic> toJson() => _json;

  factory NewsTrafficImpact.fromJson(Map<String, dynamic> json) {
    // Fail closed on malformed/legacy candidates; never infer verified status.
    if (json['body_verified'] != true ||
        json['id'] is! String ||
        json['event_id'] is! String ||
        json['version'] is! int ||
        (json['version'] as int) < 1 ||
        !const [
          'STRIKE',
          'ROAD_CLOSURE',
          'BUS_DETOUR',
          'STOP_SKIP',
          'STATION_RESTRICTION',
          'CONGESTION_FORECAST',
        ].contains(json['type']) ||
        !const [
          'ANNOUNCED',
          'CONDITIONAL',
          'WITHDRAWN',
          'ENDED',
          'NORMAL',
          'UNKNOWN',
        ].contains(json['status']) ||
        !const [
          'planned',
          'forecast',
          'actual',
          'unknown',
        ].contains(json['assertion']) ||
        json['source_url'] is! String ||
        json['period'] is! Map ||
        json['scope'] is! List ||
        json['modes'] is! List ||
        json['evidence'] is! List ||
        maps(json['evidence']).isEmpty) {
      throw const FormatException('Invalid full-body traffic record');
    }
    for (final edge in ['start', 'end']) {
      final time = (json['period'] as Map)[edge];
      if (time is! Map || time['timezone'] != 'Asia/Seoul') {
        throw const FormatException('Invalid impact period');
      }
      final date = time['date'];
      if (date != null && (date is! String || !_validDate(date))) {
        throw const FormatException('Invalid impact date');
      }
      final hour = time['time'];
      if (hour != null &&
          (hour is! String ||
              !RegExp(
                r'^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$',
              ).hasMatch(hour))) {
        throw const FormatException('Invalid impact time');
      }
    }
    for (final mode in json['modes'] as List) {
      if (!const [
        'car',
        'taxi',
        'bus',
        'subway',
        'rail',
        'walk',
      ].contains(mode)) {
        throw const FormatException('Invalid mode');
      }
    }
    final period = json['period'] as Map;
    final a = period['start'] as Map, b = period['end'] as Map;
    if (a['date'] != null &&
        b['date'] != null &&
        ('${a['date']}'.compareTo('${b['date']}') > 0 ||
            (a['date'] == b['date'] &&
                a['time'] != null &&
                b['time'] != null &&
                '${a['time']}'.compareTo('${b['time']}') >= 0))) {
      throw const FormatException('Reversed impact period');
    }
    final point = json['verified_point'];
    if (point != null &&
        (point is! List ||
            point.length != 2 ||
            point[0] is! num ||
            point[1] is! num ||
            !(point[0] as num).isFinite ||
            !(point[1] as num).isFinite ||
            (point[0] as num).abs() > 90 ||
            (point[1] as num).abs() > 180 ||
            json['point_reference_source'] is! String)) {
      throw const FormatException('Unverified point');
    }
    for (final e in maps(json['evidence'])) {
      if (e['quote'] is! String || (e['quote'] as String).isEmpty) {
        throw const FormatException('Missing evidence');
      }
    }
    return NewsTrafficImpact._(Map<String, dynamic>.unmodifiable(json));
  }

  static List<Map<String, dynamic>> maps(dynamic v) => v is List
      ? v.map((e) => (e as Map).cast<String, dynamic>()).toList()
      : const [];
  static bool _validDate(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
    final parsed = DateTime.tryParse(value);
    return parsed != null && parsed.toIso8601String().startsWith(value);
  }
}
