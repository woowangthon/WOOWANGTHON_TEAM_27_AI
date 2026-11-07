/// LifeRadar 도메인 모델 — 앱(FE), 수집 파이프라인(BE), 엔진이 공유한다.
library;

class GeoPoint {
  const GeoPoint(this.lat, this.lng);
  final double lat;
  final double lng;
}

/// Ko/En 텍스트. UI 언어에 따라 선택한다.
class LocalizedText {
  const LocalizedText({required this.ko, required this.en});
  final String ko;
  final String en;

  String of(String languageCode) => languageCode == 'ko' ? ko : en;
}

enum EventCategory {
  conference,
  hackathon,
  concert,
  festival,
  meetup,
  job,
  scholarship,
  performance, // 연극, 뮤지컬, 무용, 영화
  exhibition,
  classes, // 교육 / 체험
  startupSupport, // 창업 지원 공고 (K-Startup)
}

class RadarEvent {
  const RadarEvent({
    required this.id,
    required this.title,
    required this.description,
    required this.category,
    required this.tags,
    required this.start,
    required this.end,
    required this.venue,
    required this.city,
    required this.location,
    this.url,
    this.registerUrl,
    this.deadline,
    this.source = 'sample',
    this.sourceName,
    this.imageUrl,
    this.isFree,
    this.price,
    this.placeless = false,
  });

  final String id;
  final LocalizedText title;
  final LocalizedText description;
  final EventCategory category;
  final List<String> tags;
  final DateTime start;
  final DateTime end;
  final String venue;
  final String city;
  final GeoPoint location;
  final String? url;
  final String? registerUrl;
  final DateTime? deadline;

  /// 'sample' 또는 데이터 출처 키 (예: 'seoul-culture').
  final String source;

  /// 사용자에게 보여줄 출처 이름 (공공누리 라이선스 요구 사항 — 출처 표시).
  final String? sourceName;
  final String? imageUrl;
  final bool? isFree;
  final String? price;

  /// 정확한 장소가 없음 (예: 전국 대상 공고). [location]은 지역 중심일 뿐:
  /// 지도, 경로, "근처" 카드에는 나오지 않는다; [start]–[end] = 접수 기간.
  final bool placeless;

  bool get isSample => source == 'sample';

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': {'ko': title.ko, 'en': title.en},
        'description': {'ko': description.ko, 'en': description.en},
        'category': category.name,
        'tags': tags,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'venue': venue,
        'city': city,
        'lat': location.lat,
        'lng': location.lng,
        if (url != null) 'url': url,
        if (registerUrl != null) 'registerUrl': registerUrl,
        if (deadline != null) 'deadline': deadline!.toIso8601String(),
        'source': source,
        if (sourceName != null) 'sourceName': sourceName,
        if (imageUrl != null) 'imageUrl': imageUrl,
        if (isFree != null) 'isFree': isFree,
        if (price != null) 'price': price,
        if (placeless) 'placeless': true,
      };

  static RadarEvent fromJson(Map<String, dynamic> j) {
    LocalizedText lt(Object? v) {
      final m = (v as Map?)?.cast<String, dynamic>() ?? const {};
      final ko = m['ko'] as String? ?? '';
      return LocalizedText(ko: ko, en: m['en'] as String? ?? ko);
    }

    return RadarEvent(
      id: j['id'] as String,
      title: lt(j['title']),
      description: lt(j['description']),
      category: EventCategory.values.asNameMap()[j['category']] ?? EventCategory.festival,
      tags: [for (final t in (j['tags'] as List? ?? const [])) t as String],
      start: DateTime.parse(j['start'] as String),
      end: DateTime.parse(j['end'] as String),
      venue: j['venue'] as String? ?? '',
      city: j['city'] as String? ?? '',
      location: GeoPoint((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble()),
      url: j['url'] as String?,
      registerUrl: j['registerUrl'] as String?,
      deadline: j['deadline'] == null ? null : DateTime.parse(j['deadline'] as String),
      source: j['source'] as String? ?? 'unknown',
      sourceName: j['sourceName'] as String?,
      imageUrl: j['imageUrl'] as String?,
      isFree: j['isFree'] as bool?,
      price: j['price'] as String?,
      placeless: j['placeless'] as bool? ?? false,
    );
  }
}

class Plan {
  const Plan({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.locationText,
    required this.city,
    this.location,
    this.source = 'sample',
    this.note,
    this.htmlLink,
  });

  final String id;
  final String title;
  final DateTime start;
  final DateTime end;
  final String locationText;
  final String city;
  final GeoPoint? location;

  /// 'sample' | 'gcal' (Google 캘린더) | 'local' (앱에서 직접 추가).
  final String source;
  final String? note;

  /// Google 캘린더의 일정 페이지 ('gcal'만).
  final String? htmlLink;

  /// 앱에서 수정/삭제 가능 여부 (캘린더 일정은 Google 캘린더에서 수정).
  bool get isEditable => source == 'local' || source == 'gcal';

  /// 종일: 00:00에 시작해 최소 23시간 지속.
  bool get isAllDay => start.hour == 0 && start.minute == 0 && end.difference(start).inHours >= 23;

  /// Google Calendar event id (`gcal-<id>` → `<id>`).
  String? get calendarEventId => source == 'gcal' && id.startsWith('gcal-') ? id.substring(5) : null;

  Plan copyWith({
    String? id,
    String? title,
    DateTime? start,
    DateTime? end,
    String? locationText,
    String? city,
    GeoPoint? Function()? location,
    String? source,
    String? Function()? note,
  }) =>
      Plan(
        id: id ?? this.id,
        title: title ?? this.title,
        start: start ?? this.start,
        end: end ?? this.end,
        locationText: locationText ?? this.locationText,
        city: city ?? this.city,
        location: location == null ? this.location : location(),
        source: source ?? this.source,
        note: note == null ? this.note : note(),
        htmlLink: htmlLink,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'locationText': locationText,
        'city': city,
        if (location != null) 'lat': location!.lat,
        if (location != null) 'lng': location!.lng,
        'source': source,
        if (note != null) 'note': note,
      };

  static Plan fromJson(Map<String, dynamic> j) => Plan(
        id: j['id'] as String,
        title: j['title'] as String,
        start: DateTime.parse(j['start'] as String),
        end: DateTime.parse(j['end'] as String),
        locationText: j['locationText'] as String? ?? '',
        city: j['city'] as String? ?? '',
        location: j['lat'] == null ? null : GeoPoint((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble()),
        source: j['source'] as String? ?? 'local',
        note: j['note'] as String?,
      );
}

enum InsightKind { planAlert, opportunity, route, deadline }

enum SignalType { event, weather, traffic, deadline }

class Signal {
  const Signal(this.type, this.summary);
  final SignalType type;
  final LocalizedText summary;
}

class SourceLink {
  const SourceLink(this.title, this.url);
  final String title;
  final String? url;
}

enum InsightFeedback { like, dislike, hidden }

class Insight {
  const Insight({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.why,
    required this.confidence,
    this.planId,
    this.eventIds = const [],
    this.signals = const [],
    this.sources = const [],
    this.feedback,
    this.aiModel,
  });

  final String id;
  final InsightKind kind;
  final LocalizedText title;
  final LocalizedText body;
  final LocalizedText why;
  final double confidence;
  final String? planId;
  final List<String> eventIds;
  final List<Signal> signals;
  final List<SourceLink> sources;
  final InsightFeedback? feedback;

  /// [body]/[why]를 Gemini가 썼다면 모델 이름 (UI의 "AI" 표시). 사실은 여전히 규칙에서 온다.
  final String? aiModel;

  Insight copyWith({InsightFeedback? feedback, LocalizedText? body, LocalizedText? why, String? aiModel}) => Insight(
        id: id,
        kind: kind,
        title: title,
        body: body ?? this.body,
        why: why ?? this.why,
        confidence: confidence,
        planId: planId,
        eventIds: eventIds,
        signals: signals,
        sources: sources,
        feedback: feedback ?? this.feedback,
        aiModel: aiModel ?? this.aiModel,
      );
}

/// 검색으로 찾은 장소 (Kakao Local).
class Place {
  const Place({required this.name, required this.address, required this.location});
  final String name;
  final String address;
  final GeoPoint location;
}

enum TravelMode { car, transit }

/// 경로: 자동차 (Kakao Mobility) 또는 대중교통 (Google Routes).
class TravelRoute {
  const TravelRoute({
    required this.distanceMeters,
    required this.durationSeconds,
    this.points = const [],
    this.mode = TravelMode.car,
    this.transitLines = const [],
  });
  final int distanceMeters;
  final int durationSeconds;
  final List<GeoPoint> points;
  final TravelMode mode;

  /// 예: ["KTX 경부"] — 대중교통만.
  final List<String> transitLines;
}

/// 경로 주변 기회: 행사 + 경로에서의 거리 + 추가 이동.
class RouteOpportunity {
  const RouteOpportunity({
    required this.event,
    required this.distanceFromRouteKm,
    required this.score,
    this.detourKm,
    this.detourMinutes,
  });
  final RadarEvent event;
  final double distanceFromRouteKm;
  final double score;
  final double? detourKm;
  final int? detourMinutes;

  RouteOpportunity withDetour(double km, int minutes) => RouteOpportunity(
        event: event,
        distanceFromRouteKm: distanceFromRouteKm,
        score: score,
        detourKm: km,
        detourMinutes: minutes,
      );
}

/// 일별 날씨 예보 (Google Weather, 약 10일 앞까지).
class DailyWeather {
  const DailyWeather({
    required this.date,
    required this.condition,
    required this.type,
    this.maxC,
    this.minC,
    this.rainChance,
  });

  final DateTime date;

  /// 사람이 읽는 상태 ("구름 없음", "Sunny") — 요청한 언어로.
  final String condition;

  /// Google WeatherCondition.type: CLEAR, CLOUDY, RAIN, SNOW, ...
  final String type;
  final int? maxC;
  final int? minC;

  /// 강수 확률, %.
  final int? rainChance;

  bool get likelyRain => (rainChance ?? 0) >= 60;
}
