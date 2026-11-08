import 'models.dart';
import '../engine/route_matcher.dart';

/// 뉴스에서 추출한 대중교통 파업 정보 (팀 문서 「뉴스 파업정보 추출 구현 지침」의 핵심 필드).
///
/// 공식 공지가 아니라 **뉴스 보도**이므로 앱에서는 참고 카드로만 보여준다. 모든 값은 기사 본문
/// 근거(인용)가 있어야 하며, 근거 없는 값은 비워 둔다.
enum StrikeStatus { preparing, conditional, scheduled, ongoing, deferred, withdrawn, ended, historical, unknown }

enum TransitMode { bus, subway, rail, unknown }

class TransitStrike {
  const TransitStrike({
    required this.id,
    required this.mode,
    required this.operator,
    required this.regions,
    required this.status,
    required this.quote,
    required this.articleTitle,
    required this.url,
    required this.publishedAt,
    this.start,
    this.end,
    this.dateQuote,
    this.sourceCount = 1,
    this.model,
  });

  /// 기사(또는 같은 사건으로 묶인 기사들)의 안정적인 id.
  final String id;
  final TransitMode mode;

  /// 운영 주체 또는 노선 (예: "공항철도", "서울교통공사"). 기사에 없으면 빈 문자열.
  final String operator;

  /// 정규화한 영향 지역 ([KoreaRegions.names] 중), "전국" 포함.
  final List<String> regions;
  final StrikeStatus status;

  /// 파업 상태의 근거 — 기사에 실제로 있는 문장.
  final String quote;

  /// 날짜만 (시각 없음). 근거가 없으면 null.
  final DateTime? start;
  final DateTime? end;
  final String? dateQuote;

  final String articleTitle;
  final String url;
  final DateTime publishedAt;

  /// 같은 사건을 다룬 기사 수.
  final int sourceCount;
  final String? model;

  /// 앞으로 이동에 영향을 줄 수 있는 상태 (예고·조건부·진행 중). 철회·유보·종료·과거는 경고하지 않는다.
  bool get isActive =>
      status == StrikeStatus.scheduled || status == StrikeStatus.conditional || status == StrikeStatus.ongoing;

  TransitStrike copyWith({int? sourceCount}) => TransitStrike(
        id: id,
        mode: mode,
        operator: operator,
        regions: regions,
        status: status,
        quote: quote,
        articleTitle: articleTitle,
        url: url,
        publishedAt: publishedAt,
        start: start,
        end: end,
        dateQuote: dateQuote,
        sourceCount: sourceCount ?? this.sourceCount,
        model: model,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'mode': mode.name,
        'operator': operator,
        'regions': regions,
        'status': status.name,
        'quote': quote,
        if (start != null) 'start': _ymd(start!),
        if (end != null) 'end': _ymd(end!),
        if (dateQuote != null) 'dateQuote': dateQuote,
        'articleTitle': articleTitle,
        'url': url,
        'publishedAt': publishedAt.toIso8601String(),
        'sourceCount': sourceCount,
        if (model != null) 'model': model,
      };

  static TransitStrike fromJson(Map<String, dynamic> j) => TransitStrike(
        id: j['id'] as String,
        mode: TransitMode.values.asNameMap()[j['mode']] ?? TransitMode.unknown,
        operator: j['operator'] as String? ?? '',
        regions: [for (final r in (j['regions'] as List? ?? const [])) r as String],
        status: StrikeStatus.values.asNameMap()[j['status']] ?? StrikeStatus.unknown,
        quote: j['quote'] as String,
        start: j['start'] == null ? null : DateTime.parse(j['start'] as String),
        end: j['end'] == null ? null : DateTime.parse(j['end'] as String),
        dateQuote: j['dateQuote'] as String?,
        articleTitle: j['articleTitle'] as String,
        url: j['url'] as String,
        publishedAt: DateTime.parse(j['publishedAt'] as String),
        sourceCount: (j['sourceCount'] as num?)?.toInt() ?? 1,
        model: j['model'] as String?,
      );

  static String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

/// 광역 지역 이름과 대표 좌표. 일정 장소가 어느 지역인지 정할 때 쓴다.
abstract final class KoreaRegions {
  static const centers = <String, GeoPoint>{
    '서울': GeoPoint(37.5665, 126.9780),
    '인천': GeoPoint(37.4563, 126.7052),
    '경기': GeoPoint(37.2752, 127.0095),
    '강원': GeoPoint(37.8228, 128.1555),
    '대전': GeoPoint(36.3504, 127.3845),
    '세종': GeoPoint(36.4800, 127.2890),
    '충북': GeoPoint(36.6357, 127.4917),
    '충남': GeoPoint(36.6588, 126.6728),
    '광주': GeoPoint(35.1595, 126.8526),
    '전북': GeoPoint(35.8242, 127.1480),
    '전남': GeoPoint(34.8161, 126.4629),
    '대구': GeoPoint(35.8714, 128.6014),
    '경북': GeoPoint(36.5760, 128.5056),
    '부산': GeoPoint(35.1796, 129.0756),
    '울산': GeoPoint(35.5384, 129.3114),
    '경남': GeoPoint(35.2383, 128.6922),
    '제주': GeoPoint(33.4996, 126.5312),
  };

  /// 모델이 고를 수 있는 지역 값 (광역 + 묶음).
  static const names = [...centersKeys, '수도권', '전국'];
  static const centersKeys = [
    '서울', '인천', '경기', '강원', '대전', '세종', '충북', '충남', '광주', '전북', '전남', //
    '대구', '경북', '부산', '울산', '경남', '제주',
  ];

  static const capital = {'서울', '인천', '경기'};

  /// 좌표가 속한 광역 지역 (가장 가까운 대표 좌표).
  static String regionOf(GeoPoint p) {
    String? best;
    var bestKm = double.infinity;
    centers.forEach((name, c) {
      final km = RouteMatcher.haversineKm(p, c);
      if (km < bestKm) {
        bestKm = km;
        best = name;
      }
    });
    return best!;
  }

  /// [strikeRegions]가 [place]를 포함하는지 ("전국", "수도권" 묶음 포함).
  static bool covers(List<String> strikeRegions, GeoPoint place) {
    if (strikeRegions.contains('전국')) return true;
    final r = regionOf(place);
    if (strikeRegions.contains(r)) return true;
    return strikeRegions.contains('수도권') && capital.contains(r);
  }
}
