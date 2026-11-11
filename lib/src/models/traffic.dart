import 'models.dart';
import 'traffic_time.dart';

/// 공식 출처의 도로·교통 영향 (예: 서울시 TOPIS 돌발정보).
///
/// 사실은 출처 그대로: [detail] — 원문(근거), 시간과 장소 — 출처의 필드.
/// 아무것도 추정하지 않는다: 종료 시각을 모르면 [end] = null.
enum TrafficKind { rally, event, drill, construction, weather, other }

class TrafficNotice {
  const TrafficNotice({
    required this.id,
    required this.kind,
    required this.title,
    required this.detail,
    required this.start,
    required this.location,
    required this.source,
    required this.sourceName,
    this.end,
    this.sourceUrl,
    this.evidenceRefs = const [],
    this.linkIds = const [],
    this.conflict = false,
    this.lastSeenAt,
    this.fetchedAt,
    this.sourceUpdatedAt,
    this.groupId,
    this.linkVersion,
    this.linkSystem,
    this.sourceUrlKind,
    this.controlTypeRaw,
    this.section,
    this.direction,
    this.roadName,
    this.locationText,
    this.evidenceMethod,
    this.evidenceText,
    this.sourceRecordId,
    this.status = 'active',
    this.timePrecision = 'unknown',
    this.controlEvidence = 'unconfirmed',
  });

  final String id;
  final TrafficKind kind;

  /// 원문의 첫 줄 (예: "[통제] 청계천로 차 없는 거리 행사").
  final String title;

  /// 원문 전체 — 사용자에게 근거로 보여준다.
  final String detail;

  /// 영향 시작. 종료는 [end] (반열린 구간 `[start, end)`), 모르면 null.
  final DateTime start;
  final DateTime? end;
  final GeoPoint location;
  final String source;
  final String sourceName;
  final String? sourceUrl;
  final List<Map<String, dynamic>> evidenceRefs;
  final List<String> linkIds;
  final bool conflict;
  final DateTime? lastSeenAt;
  final DateTime? fetchedAt;
  final DateTime? sourceUpdatedAt;
  final String? groupId;
  final String? linkVersion;
  final String? linkSystem;
  final String? sourceUrlKind;
  final String? controlTypeRaw;
  final String? section;
  final String? direction;
  final String? roadName;
  final String? locationText;
  final String? evidenceMethod;
  final String? evidenceText;
  final String? sourceRecordId;
  final String status;
  final String timePrecision;
  final String controlEvidence;

  /// 행사나 집회로 인한 영향 (팀 판별 로직 문서의 핵심 범위).
  bool get isGathering => kind == TrafficKind.rally || kind == TrafficKind.event;

  /// [now] 기준으로 보여줄 공지인지: [horizonDays]일 안에 시작하고, 아직 끝나지 않았다.
  /// 종료 시각이 없으면 시작한 날까지만 유효하다고 본다 (판별 로직: 종료 미상을 무기한 활성화하지 않는다).
  bool isRelevantAt(DateTime now, {int horizonDays = 28}) {
    final at = trafficUtc(now), beginning = trafficUtc(start);
    if (status != 'active' || !validLocation) return false;
    if (!beginning.isBefore(at.add(Duration(days: horizonDays)))) return false;
    if (end != null && !trafficUtc(end!).isAfter(beginning)) return false;
    if (source == 'utic' &&
        (lastSeenAt == null ||
            at.difference(trafficUtc(lastSeenAt!)).isNegative ||
            at.difference(trafficUtc(lastSeenAt!)) > const Duration(hours: 6))) {
      return false;
    }
    if (source != 'utic' &&
        lastSeenAt != null &&
        (trafficUtc(lastSeenAt!).isAfter(at) || at.difference(trafficUtc(lastSeenAt!)) > const Duration(hours: 24))) {
      return false;
    }
    return end == null ? !trafficDay(start).isBefore(trafficDay(now)) : trafficUtc(end!).isAfter(at);
  }

  bool get validLocation =>
      location.lat.isFinite &&
      location.lng.isFinite &&
      location.lat >= 33 &&
      location.lat <= 39 &&
      location.lng >= 124 &&
      location.lng <= 132;
  bool staleAt(DateTime now) =>
      lastSeenAt != null && trafficUtc(now).difference(trafficUtc(lastSeenAt!)) > const Duration(minutes: 60);
  bool get hasControlEvidence =>
      controlEvidence == 'confirmed' &&
      (evidenceText?.isNotEmpty ?? false) &&
      (evidenceMethod?.isNotEmpty ?? false) &&
      (!evidenceMethod!.startsWith('literal-road-control-') || explicitRoadControl(evidenceText!));
  bool referenceAt(DateTime now) =>
      !hasControlEvidence || conflict || end == null || timePrecision != 'minute' || (source == 'utic' && staleAt(now));
  TrafficNotice withMetadata(Map<String, dynamic> values) => TrafficNotice.fromJson({...toJson(), ...values});

  Map<String, dynamic> toJson() => {
    'id': id,
    'evidenceRefs': evidenceRefs,
    'linkIds': linkIds,
    'conflict': conflict,
    if (lastSeenAt != null) 'lastSeenAt': trafficUtc(lastSeenAt!).toIso8601String(),
    if (fetchedAt != null) 'fetchedAt': trafficUtc(fetchedAt!).toIso8601String(),
    if (sourceUpdatedAt != null) 'sourceUpdatedAt': trafficUtc(sourceUpdatedAt!).toIso8601String(),
    if (groupId != null) 'groupId': groupId,
    if (linkVersion != null) 'linkVersion': linkVersion,
    if (linkSystem != null) 'linkSystem': linkSystem,
    if (sourceUrlKind != null) 'sourceUrlKind': sourceUrlKind,
    if (controlTypeRaw != null) 'controlTypeRaw': controlTypeRaw,
    if (section != null) 'section': section,
    if (direction != null) 'direction': direction,
    if (roadName != null) 'roadName': roadName,
    if (locationText != null) 'locationText': locationText,
    if (evidenceMethod != null) 'evidenceMethod': evidenceMethod,
    if (evidenceText != null) 'evidenceText': evidenceText,
    if (sourceRecordId != null) 'sourceRecordId': sourceRecordId,
    'status': status,
    'timePrecision': timePrecision,
    'controlEvidence': controlEvidence,
    'kind': kind.name,
    'title': title,
    'detail': detail,
    'start': trafficUtc(start).toIso8601String(),
    'end': end == null ? null : trafficUtc(end!).toIso8601String(),
    'lat': location.lat,
    'lng': location.lng,
    'source': source,
    'sourceName': sourceName,
    if (sourceUrl != null) 'sourceUrl': sourceUrl,
  };

  static TrafficNotice fromJson(Map<String, dynamic> j) => TrafficNotice(
    id: j['id'] as String,
    evidenceRefs: [
      for (final e in (j['evidenceRefs'] as List? ?? const []))
        TrafficNotice.fromJson({...(e as Map).cast<String, dynamic>(), 'evidenceRefs': const []}).toJson(),
    ],
    linkIds: (j['linkIds'] as List? ?? const []).cast<String>(),
    conflict: j['conflict'] as bool? ?? false,
    lastSeenAt: j['lastSeenAt'] == null ? null : trafficInstant(j['lastSeenAt'] as String),
    fetchedAt: j['fetchedAt'] == null ? null : trafficInstant(j['fetchedAt'] as String),
    sourceUpdatedAt: j['sourceUpdatedAt'] == null ? null : trafficInstant(j['sourceUpdatedAt'] as String),
    groupId: j['groupId'] as String?,
    linkVersion: j['linkVersion'] as String?,
    linkSystem: j['linkSystem'] as String?,
    sourceUrlKind: j['sourceUrlKind'] as String?,
    controlTypeRaw: j['controlTypeRaw'] as String?,
    section: j['section'] as String?,
    direction: j['direction'] as String?,
    roadName: j['roadName'] as String?,
    locationText: j['locationText'] as String?,
    evidenceMethod: j['evidenceMethod'] as String?,
    evidenceText: j['evidenceText'] as String?,
    sourceRecordId: j['sourceRecordId'] as String?,
    status: j['status'] as String? ?? 'active',
    timePrecision: j['timePrecision'] as String? ?? 'unknown',
    controlEvidence: j['controlEvidence'] as String? ?? 'unconfirmed',
    kind: TrafficKind.values.asNameMap()[j['kind']] ?? TrafficKind.other,
    title: j['title'] as String,
    detail: j['detail'] as String,
    start: trafficInstant(j['start'] as String),
    end: j['end'] == null ? null : trafficInstant(j['end'] as String),
    location: GeoPoint((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble()),
    source: j['source'] as String,
    sourceName: j['sourceName'] as String,
    sourceUrl: j['sourceUrl'] as String?,
  );
}
