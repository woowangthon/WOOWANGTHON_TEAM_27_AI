/// 국가교통정보센터(ITS) 돌발상황정보 — 전국 고속도로·국도·지방도의 공사·행사·기상·재난.
/// https://www.its.go.kr/opendata/ · 라이선스: 공공누리 — [sourceName].
/// 순수 Dart — 앱(FE)이 기기에서 직접 조회하고, 수집 파이프라인(BE)도 같은 파서를 쓴다.
/// ITS는 해외 IP를 차단해 GitHub Actions에서는 응답이 없으므로 앱이 한국 내 기기에서 조회한다.
library;

import '../models/models.dart';
import '../models/traffic.dart';
import '../models/traffic_time.dart';

class ItsTraffic {
  static const source = 'its';
  static const sourceName = '국가교통정보센터(ITS) · 돌발상황정보';
  static const sourceUrl = 'https://www.its.go.kr';

  static Uri uri(String key) =>
      Uri.parse('https://openapi.its.go.kr:9443/eventInfo?apiKey=$key&type=all&eventType=all&getType=json');

  /// 일정과 관련 있는 유형만. 정체·고장·사고처럼 짧은 돌발은 3시간 수집 주기에 맞지 않아 낡은
  /// 정보가 되므로 제외한다. 이동 중인 도로 작업(`작업`)은 종료 시각이 있을 때만 받는다.
  static TrafficKind? kindOf(String eventType, String detail, {required bool hasEnd}) => switch (eventType) {
    '기상' => TrafficKind.weather,
    '재난' => TrafficKind.other,
    '공사' when detail == '작업' && !hasEnd => null,
    '공사' => TrafficKind.construction,
    _ when detail == '이벤트/홍보' => TrafficKind.event,
    _ => null,
  };

  /// JSON 응답 → 항목 목록. 오류 코드면 [TrafficSourceException].
  static List<Map<String, dynamic>> rows(Map<String, dynamic> json) {
    final header = json['header'] as Map<String, dynamic>?;
    final code = header?['resultCode'];
    if (code != 0 && code != '0') {
      throw TrafficSourceException('$source: $code ${header?['resultMsg'] ?? 'unknown response'}');
    }
    final body = json['body'] as Map<String, dynamic>?;
    if (body == null || body['items'] is! List) throw const TrafficSourceException('its: incomplete envelope');
    return [for (final i in body['items'] as List) (i as Map).cast<String, dynamic>()];
  }

  /// A full successful response is different from a truncated/partial list.
  static bool isComplete(Map<String, dynamic> json) {
    final body = json['body'];
    if (body is! Map ||
        body['items'] is! List ||
        body['totalCount'] is! num ||
        body['totalCount'] != (body['items'] as List).length) {
      return false;
    }
    for (final raw in body['items'] as List) {
      if (raw is! Map) return false;
      final r = raw.cast<String, dynamic>();
      final candidate = kindOf(
        '${r['eventType'] ?? ''}',
        '${r['eventDetailType'] ?? ''}',
        hasEnd: '${r['endDate'] ?? ''}'.isNotEmpty,
      );
      if (candidate != null && parse(r) == null) return false;
    }
    return true;
  }

  /// 항목 하나 → [TrafficNotice]. 대상 유형이 아니거나 위치·시작 시각이 없으면 null.
  static TrafficNotice? parse(Map<String, dynamic> r) {
    String s(String k) => '${r[k] ?? ''}'.trim();
    final start = _at(s('startDate'));
    final end = _at(s('endDate'));
    final kind = kindOf(s('eventType'), s('eventDetailType'), hasEnd: end != null);
    final lng = double.tryParse(s('coordX'));
    final lat = double.tryParse(s('coordY'));
    if (kind == null || start == null || lat == null || lng == null) return null;
    if (!lat.isFinite || !lng.isFinite || lat < 33 || lat > 39 || lng < 124 || lng > 132) return null; // 한국 범위 밖 좌표

    final road = s('roadName');
    final what = [s('eventType'), s('eventDetailType')].where((x) => x.isNotEmpty).toSet().join(' · ');
    final title = road.isEmpty ? what : '[$road] $what';
    final lanes = s('lanesBlocked');
    final detail = [title, if (s('message').isNotEmpty) s('message'), if (lanes.isNotEmpty) '차단 차로: $lanes'].join('\n');
    return TrafficNotice(
      id: 'its-${s('linkId')}-${s('startDate')}',
      kind: kind,
      title: title,
      detail: detail,
      start: start,
      // 출처에서 종료가 시작보다 앞서면 잘못된 값 — 추정하지 않는다.
      end: end != null && end.isAfter(start) ? end : null,
      location: GeoPoint(lat, lng),
      source: source,
      sourceName: sourceName,
      sourceUrl: sourceUrl,
      sourceUrlKind: 'center',
      sourceRecordId: 'its-${s('linkId')}-${s('startDate')}',
      timePrecision: 'minute',
      controlEvidence: explicitRoadControl(s('message')) ? 'confirmed' : 'unconfirmed',
      evidenceText: s('message'),
      evidenceMethod: 'literal-road-control-v2',
      roadName: road.isEmpty ? null : road,
      locationText: road.isEmpty ? null : road,
    );
  }

  /// "20261108142724" → 현지(KST) 시각. 형식이 다르면 null.
  static DateTime? _at(String v) {
    if (!RegExp(r'^(\d{12}|\d{14})$').hasMatch(v)) return null;
    final t = v.padRight(14, '0');
    try {
      return trafficInstant(
        '${t.substring(0, 4)}-${t.substring(4, 6)}-${t.substring(6, 8)}T${t.substring(8, 10)}:${t.substring(10, 12)}:${t.substring(12, 14)}+09:00',
      );
    } catch (_) {
      return null;
    }
  }
}

/// 교통 정보 출처의 오류 응답 (키 오류, 할당량 등).
class TrafficSourceException implements Exception {
  const TrafficSourceException(this.message);
  final String message;
  @override
  String toString() => message;
}
