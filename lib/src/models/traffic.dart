import 'models.dart';

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

  /// 행사나 집회로 인한 영향 (팀 판별 로직 문서의 핵심 범위).
  bool get isGathering => kind == TrafficKind.rally || kind == TrafficKind.event;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'detail': detail,
        'start': start.toIso8601String(),
        if (end != null) 'end': end!.toIso8601String(),
        'lat': location.lat,
        'lng': location.lng,
        'source': source,
        'sourceName': sourceName,
        if (sourceUrl != null) 'sourceUrl': sourceUrl,
      };

  static TrafficNotice fromJson(Map<String, dynamic> j) => TrafficNotice(
        id: j['id'] as String,
        kind: TrafficKind.values.asNameMap()[j['kind']] ?? TrafficKind.other,
        title: j['title'] as String,
        detail: j['detail'] as String,
        start: DateTime.parse(j['start'] as String),
        end: j['end'] == null ? null : DateTime.parse(j['end'] as String),
        location: GeoPoint((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble()),
        source: j['source'] as String,
        sourceName: j['sourceName'] as String,
        sourceUrl: j['sourceUrl'] as String?,
      );
}
