import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/models.dart';
import '../models/traffic.dart';
import '../models/transit_strike.dart';
import '../models/news_traffic.dart';
import '../models/traffic_time.dart';
import '../engine/insight_engine.dart';
import '../engine/traffic_matcher.dart';
import '../engine/news_traffic_matcher.dart';
import '../engine/route_matcher.dart';
import 'its_traffic.dart';
import 'topis_public.dart';

class TravelSourceCheck {
  const TravelSourceCheck(this.name, this.ok, this.detail, {this.updatedAt});
  final String name, detail;
  final bool ok;
  final DateTime? updatedAt;
}

class TravelImpactReport {
  const TravelImpactReport({
    required this.checkedAt,
    required this.sources,
    required this.insights,
    required this.scheduleVersion,
    this.tripVersion,
    this.route,
  });
  final String scheduleVersion;
  final String? tripVersion;
  static String versionOf(Plan p) => jsonEncode([
    p.id,
    p.start.toIso8601String(),
    p.end.toIso8601String(),
    p.location?.lat,
    p.location?.lng,
    p.locationText,
    p.attendance,
  ]);
  bool matches(Plan p, TripContext? trip) => versionOf(p) == scheduleVersion && trip?.version == tripVersion;
  final DateTime checkedAt;
  final List<TravelSourceCheck> sources;
  final List<Insight> insights;
  final TravelRoute? route;
  bool get incomplete => sources.any((s) => !s.ok);
}

/// Production HTTP checks only. No demo import, canned routes, or sample fallback.
/// A failed source is reported explicitly, never translated to "normal service".
class TravelImpactService {
  TravelImpactService({
    required this.kakaoKey,
    required this.googleKey,
    required this.itsKey,
    http.Client? client,
    this.baseUrl = 'https://raw.githubusercontent.com/woowangthon/WOOWANGTHON_TEAM_27_BE/data',
  }) : _client = client ?? http.Client();
  final String kakaoKey, googleKey, itsKey, baseUrl;
  final http.Client _client;
  final _cache = <String, (DateTime, Map<String, dynamic>)>{};
  final _inflight = <String, Future<Map<String, dynamic>>>{};
  void close() => _client.close();

  Future<http.Response> _get(Uri uri, {Map<String, String>? headers}) async {
    for (var attempt = 0; ; attempt++) {
      try {
        final response = await _client.get(uri, headers: headers).timeout(const Duration(seconds: 25));
        if (attempt == 0 && response.statusCode >= 500) continue;
        return response;
      } catch (_) {
        if (attempt >= 1) rethrow;
      }
    }
  }

  Future<Map<String, dynamic>> _getFeed(String name, DateTime now, bool force) {
    return _loadJson(name, now, force, () => _get(Uri.parse('$baseUrl/$name')));
  }

  Future<Map<String, dynamic>> _loadJson(
    String name,
    DateTime now,
    bool force,
    Future<http.Response> Function() request,
  ) {
    final cached = _cache[name];
    if (!force && cached != null && now.difference(cached.$1) < const Duration(minutes: 5)) {
      return Future.value(cached.$2);
    }
    return _inflight.putIfAbsent(name, () async {
      try {
        final response = await request();
        if (response.statusCode != 200) throw StateError('HTTP ${response.statusCode}');
        final data = (jsonDecode(utf8.decode(response.bodyBytes)) as Map).cast<String, dynamic>();
        _cache[name] = (now, data);
        return data;
      } finally {
        _inflight.remove(name);
      }
    });
  }

  static bool _fresh(DateTime? updated, DateTime now, Duration ttl) =>
      updated != null &&
      !updated.isAfter(now.toUtc().add(const Duration(minutes: 5))) &&
      now.toUtc().difference(updated.toUtc()) <= ttl;
  static bool _url(String? value) {
    final uri = Uri.tryParse(value ?? '');
    return uri != null && const ['https', 'http'].contains(uri.scheme) && uri.host.isNotEmpty;
  }

  Future<TravelImpactReport> check(
    Plan plan, {
    required DateTime now,
    GeoPoint? origin,
    TravelMode mode = TravelMode.car,
    TripContext? trip,
    bool force = false,
  }) async {
    if (plan.source == 'sample') throw ArgumentError('실제 일정만 교통 영향을 확인할 수 있습니다.');
    if (plan.attendance == 'online') {
      return TravelImpactReport(
        checkedAt: now,
        sources: const [TravelSourceCheck('이동 대상', true, '온라인 일정으로 저장되어 이동 영향 알림 대상이 아닙니다.')],
        insights: const [],
        scheduleVersion: TravelImpactReport.versionOf(plan),
        tripVersion: trip?.version,
      );
    }
    final checks = <TravelSourceCheck>[];
    final insights = <Insight>[];
    final notices = <TrafficNotice>[];
    final transitNotices = <(TrafficNotice, String)>[];
    final events = <RadarEvent>[];
    final strikes = <TransitStrike>[];
    final verified = <NewsTrafficImpact>[];
    DateTime? eventUpdated;
    // Independent sources: a failure cannot prevent other real checks.
    await Future.wait([
      () async {
        try {
          final responses = await Future.wait([
            for (final active in ['Y', 'N'])
              _loadJson(
                'topis:$active',
                now,
                force,
                () => _client
                    .post(Uri.parse('https://topis.seoul.go.kr/main/selectAccList.do'), body: {'sIngYn': active})
                    .timeout(const Duration(seconds: 20)),
              ),
          ]);
          var count = 0, rejected = 0;
          for (final j in responses) {
            if (j['rows'] is! List) throw StateError('official source schema changed');
            for (final row in j['rows'] as List) {
              final n = TopisPublic.parse((row as Map).cast<String, dynamic>(), now);
              if (n == null) {
                rejected++;
                continue;
              }
              notices.add(n);
              count++;
              final mode = TopisPublic.transitRestriction(n.detail);
              if (mode != null) transitNotices.add((n, mode));
            }
          }
          checks.add(
            TravelSourceCheck(
              '서울 공식 실시간 돌발·운행 제한',
              rejected == 0,
              '현재·예정 $count건 · 버스 우회/무정차/운행 제한 ${transitNotices.length}건${rejected == 0 ? '' : ' · 일부 항목 미확인'}',
              updatedAt: now,
            ),
          );
        } catch (_) {
          checks.add(const TravelSourceCheck('서울 공식 실시간 돌발·운행 제한', false, '공식 사이트 조회 실패 · 정상 운행으로 판단하지 않습니다.'));
        }
      }(),
      () async {
        try {
          Map<String, dynamic> j;
          try {
            j = await _getFeed('traffic-v2.json', now, force);
          } catch (_) {
            j = await _getFeed('traffic.json', now, force);
          }
          final updated = DateTime.tryParse('${j['generatedAt']}');
          if (j['notices'] is! List || !_fresh(updated, now, const Duration(hours: 24))) {
            throw StateError('stale or invalid');
          }
          for (final row in j['notices'] as List) {
            final raw = (row as Map).cast<String, dynamic>();
            final legacyTopis = raw['source'] == 'seoul-topis' && j['schemaVersion'] != 2;
            final n = TrafficNotice.fromJson({
              ...raw,
              if (legacyTopis) ...{
                'lastSeenAt': updated!.toUtc().toIso8601String(),
                'controlEvidence': explicitRoadControl('${raw['detail']}') ? 'confirmed' : 'unconfirmed',
                'evidenceText': raw['detail'],
                'evidenceMethod': 'literal-road-control-v2',
                'timePrecision': RegExp(r'T\d{2}:\d{2}').hasMatch('${raw['start']}') ? 'minute' : 'unknown',
              },
            });
            if (n.isRelevantAt(now)) notices.add(n);
          }
          checks.add(TravelSourceCheck('TOPIS 도로 통제', true, '${notices.length}건의 유효 공지', updatedAt: updated));
        } catch (_) {
          checks.add(const TravelSourceCheck('TOPIS 도로 통제', false, '수집 실패 또는 24시간 이상 지난 자료'));
        }
      }(),
      () async {
        try {
          if (itsKey.isEmpty) throw StateError('not configured');
          final j = await _loadJson('its', now, force, () => _get(ItsTraffic.uri(itsKey)));
          final rows = ItsTraffic.rows(j);
          final parsed = [
            for (final row in rows)
              ?ItsTraffic.parse(row),
          ];
          notices.addAll(parsed);
          final complete = ItsTraffic.isComplete(j);
          checks.add(
            TravelSourceCheck(
              'ITS 전국 돌발·통제',
              complete,
              '${parsed.length}건의 유효 공지 수신${complete ? '' : ' · 일부 원본 항목을 확인하지 못했습니다.'}',
              updatedAt: now,
            ),
          );
        } catch (_) {
          checks.add(const TravelSourceCheck('ITS 전국 돌발·통제', false, '조회 불가 · 전국 통제 여부 미확인'));
        }
      }(),
      () async {
        try {
          final j = await _getFeed('news.json', now, force);
          final updated = DateTime.tryParse('${j['generatedAt']}');
          if (j['strikes'] is! List || !_fresh(updated, now, const Duration(hours: 24))) {
            throw StateError('stale or invalid');
          }
          for (final row in j['strikes'] as List) {
            final s = TransitStrike.fromJson((row as Map).cast<String, dynamic>());
            if (s.quote.trim().isNotEmpty && _url(s.url)) strikes.add(s);
          }
          if (j['newsTrafficSchemaVersion'] == '1.0') {
            for (final row in j['trafficImpacts'] as List? ?? const []) {
              final impact = NewsTrafficImpact.fromJson((row as Map).cast<String, dynamic>());
              if (!impact.demo && _url(impact.sourceUrl)) verified.add(impact);
            }
          }
          checks.add(
            TravelSourceCheck(
              '파업·운행 제한 보도',
              true,
              '${strikes.length}건의 파업 기록 · 본문 검증 영향 ${verified.length}건',
              updatedAt: updated,
            ),
          );
          if (j['newsTrafficSchemaVersion'] != '1.0') {
            checks.add(
              const TravelSourceCheck('운행 중단·우회·무정차 공지', false, '운영 피드에 본문 검증 자료가 없습니다. 개별 노선의 이용 가능 여부를 확정할 수 없습니다.'),
            );
          }
        } catch (_) {
          checks.add(const TravelSourceCheck('파업·운행 제한 보도', false, '수집 실패 또는 오래된 자료 · 정상 운행을 뜻하지 않습니다.'));
        }
      }(),
      () async {
        try {
          final j = await _getFeed('events.json', now, force);
          eventUpdated = DateTime.tryParse('${j['generatedAt']}');
          if (j['events'] is! List || !_fresh(eventUpdated, now, const Duration(hours: 72))) {
            throw StateError('stale or invalid');
          }
          for (final row in j['events'] as List) {
            final e = RadarEvent.fromJson((row as Map).cast<String, dynamic>());
            if (!e.isSample && !e.placeless && _url(e.url ?? e.registerUrl)) events.add(e);
          }
          checks.add(TravelSourceCheck('공공 행사 일정', true, '${events.length}건 수신', updatedAt: eventUpdated));
        } catch (_) {
          checks.add(const TravelSourceCheck('공공 행사 일정', false, '수집 실패 또는 72시간 이상 지난 자료'));
        }
      }(),
    ]);

    TravelRoute? route;
    final start = origin ?? (trip != null && trip.points.isNotEmpty ? trip.points.first : null);
    if (start != null && plan.location != null) {
      try {
        if (mode == TravelMode.car) {
          final result = await _driving(start, plan.location!, now);
          route = result.$1;
          checks.add(
            TravelSourceCheck(
              '현재 도로 소통',
              true,
              '정체 ${result.$2.toStringAsFixed(1)} km · 서행 ${result.$3.toStringAsFixed(1)} km · 정보 없음 ${result.$5.toStringAsFixed(1)} km',
              updatedAt: now,
            ),
          );
          if (result.$2 > 0 || result.$4.isNotEmpty) {
            final nearDeparture =
                plan.start.difference(now).inMinutes >= 0 && plan.start.difference(now).inMinutes <= 120;
            insights.add(
              Insight(
                id: 'travel:road:${plan.id}',
                planId: plan.id,
                kind: InsightKind.planAlert,
                notificationEligible: nearDeparture,
                notificationKey:
                    'travel:road:${plan.id}:${plan.start.toIso8601String()}:${result.$4.isNotEmpty ? 'blocked' : 'congested'}',
                title: LocalizedText(
                  ko: result.$4.isNotEmpty ? '현재 경로에 통행 불가 구간' : '현재 경로에 정체·지체 구간',
                  en: 'Current road traffic on your route',
                ),
                body: LocalizedText(
                  ko:
                      '현재 조회한 자동차 경로의 정체·지체 구간은 ${result.$2.toStringAsFixed(1)} km입니다. '
                      '${result.$4.isEmpty ? '' : '통행 불가: ${result.$4.join(', ')}. '}현재 관측이며 일정 당일의 예측이 아닙니다.',
                  en: 'Current congestion covers ${result.$2.toStringAsFixed(1)} km. This is a current observation, not a future forecast.',
                ),
                why: const LocalizedText(
                  ko: '카카오모빌리티의 실제 도로별 교통 상태 응답입니다. 행사나 파업이 원인이라고 추정하지 않습니다.',
                  en: 'Observed road traffic from Kakao Mobility; no cause is inferred.',
                ),
                confidence: 0.85,
                sources: const [SourceLink('카카오모빌리티 길찾기', 'https://map.kakao.com/')],
              ),
            );
          }
          if (result.$5 >= route.distanceMeters / 1000) {
            checks.add(const TravelSourceCheck('도로 소통 관측 범위', false, '경로의 교통 상태가 제공되지 않았습니다.'));
          }
        } else {
          final requested = trip?.departure ?? plan.start.subtract(const Duration(hours: 1));
          route = await _transit(start, plan.location!, requested.isBefore(now) ? now : requested);
          checks.add(TravelSourceCheck('대중교통 경로', true, '경로 조회 성공 · 실제 정상 운행을 보장하는 실시간 운행 공지는 아닙니다.', updatedAt: now));
        }
      } catch (_) {
        checks.add(
          TravelSourceCheck(
            mode == TravelMode.car ? '현재 도로 소통' : '대중교통 경로',
            false,
            '경로 조회 실패 · 교통 마비나 운행 중단으로 단정하지 않습니다.',
          ),
        );
      }
    } else {
      checks.add(const TravelSourceCheck('이동 경로', false, '출발지를 선택하면 현재 정체와 경로 주변 영향도 확인할 수 있습니다.'));
    }
    // Live route geometry supplies proximity. The future travel window stays tied
    // to saved trip facts, or the explicit appointment's two-hour candidate window.
    final effectiveTrip =
        trip ??
        (route == null
            ? null
            : TripContext(
                id: 'live:${plan.id}',
                version: now.toIso8601String(),
                departure: plan.start.subtract(const Duration(seconds: 1)),
                arrival: plan.start,
                timeConfirmed: false,
                modes: mode == TravelMode.car ? const {'car'} : route.transportModes,
                points: route.points,
                lines: route.transitLines,
              ));
    if (plan.location == null) checks.add(const TravelSourceCheck('일정 장소', false, '정확한 장소 좌표를 선택해 주세요.'));
    if (plan.attendance != 'online' && plan.start.isAfter(now)) {
      // Without saved times, use the existing candidate window rather than invented departure facts.
      final trafficTrip =
          trip ??
          (effectiveTrip == null
              ? null
              : TripContext(
                  id: effectiveTrip.id,
                  version: effectiveTrip.version,
                  departure: plan.start.subtract(const Duration(hours: 2)),
                  arrival: plan.start,
                  timeConfirmed: false,
                  modes: effectiveTrip.modes,
                  points: effectiveTrip.points,
                  lines: effectiveTrip.lines,
                ));
      insights.addAll(
        const InsightEngine(maxTrafficPerPlan: 5).build(
          plans: [plan],
          events: [],
          interests: {},
          now: now,
          traffic: notices,
          tripsByPlanId: {plan.id: ?trafficTrip},
        ),
      );
      for (final impact in verified) {
        final evaluation = const NewsTrafficMatcher().evaluate(plan, trafficTrip, impact, now);
        if (evaluation.visible) insights.add(evaluation.toInsight());
      }
      // Legacy snippets and event listings do not establish a personal impact.
      // Only full-body verified impacts above can produce news alerts.
      for (final (notice, restrictionMode) in transitNotices) {
        if (trafficTrip != null && trafficTrip.modes.isNotEmpty && !trafficTrip.modes.contains(restrictionMode)) {
          continue;
        }
        final lo = trafficTrip?.departure ?? plan.start.subtract(const Duration(hours: 2));
        final hi = trafficTrip?.arrival ?? plan.start;
        final end = notice.end;
        if (end == null || !TrafficMatcher.overlaps(lo, hi, notice.start, end)) continue;
        final km = trafficTrip != null && trafficTrip.points.length > 1
            ? RouteMatcher.distanceToPolylineKm(notice.location, trafficTrip.points)
            : plan.location == null
            ? double.infinity
            : RouteMatcher.haversineKm(plan.location!, notice.location);
        if (km > 1) continue;
        insights.add(
          Insight(
            id: 'travel:transit:${plan.id}:${notice.id}',
            kind: InsightKind.planAlert,
            planId: plan.id,
            notificationEligible: true,
            notificationKey: 'travel:transit:${plan.id}:${plan.start.toIso8601String()}:${notice.id}:${notice.start}',
            title: LocalizedText(ko: '인근 대중교통 우회·이용 제한 공식 안내', en: 'Official nearby transit restriction'),
            body: LocalizedText(
              ko: '${notice.detail}\n이동 시간대와 ${km.toStringAsFixed(1)} km 이내에서 겹치는 공식 공지입니다. 해당 정류장·역·방향의 이용 가능 여부를 확인하세요. 전체 노선 이용 불가를 뜻하지 않습니다.',
              en: '${notice.detail}\nAn official restriction overlaps the travel window within ${km.toStringAsFixed(1)} km. Check the specific stop, station and direction.',
            ),
            why: const LocalizedText(
              ko: '서울시 TOPIS의 현재·예정 운행 제한 원문과 실제 좌표·시간을 비교했습니다.',
              en: 'Matched the live TOPIS notice location and time.',
            ),
            confidence: 0.8,
            sources: [SourceLink(notice.sourceName, notice.sourceUrl)],
          ),
        );
      }
    }
    final byId = {for (final i in insights) i.id: i};
    return TravelImpactReport(
      checkedAt: now,
      sources: checks,
      insights: byId.values.toList(),
      route: route,
      scheduleVersion: TravelImpactReport.versionOf(plan),
      tripVersion: trip?.version,
    );
  }

  Future<(TravelRoute, double, double, List<String>, double)> _driving(GeoPoint a, GeoPoint b, DateTime now) async {
    if (kakaoKey.isEmpty) throw StateError('not configured');
    final uri = Uri.https('apis-navi.kakaomobility.com', '/v1/directions', {
      'origin': '${a.lng},${a.lat}',
      'destination': '${b.lng},${b.lat}',
      'summary': 'false',
    });
    final response = await _client
        .get(uri, headers: {'Authorization': 'KakaoAK $kakaoKey'})
        .timeout(const Duration(seconds: 18));
    if (response.statusCode != 200) throw StateError('route request failed');
    final j = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    final r = (j['routes'] as List).first as Map;
    if (r['result_code'] != 0) throw StateError('route unavailable');
    double congested = 0, slow = 0, unknown = 0;
    final blocked = <String>[], points = <GeoPoint>[];
    for (final section in r['sections'] as List) {
      for (final road in section['roads'] as List) {
        final distance = (road['distance'] as num).toDouble() / 1000;
        final state = road['traffic_state'];
        if (state == 1 || state == 2) congested += distance;
        if (state == 3) slow += distance;
        if (state == 6) blocked.add('${road['name'] ?? '이름 없는 도로'}');
        if (!const [1, 2, 3, 4, 6].contains(state)) unknown += distance;
        final vertices = road['vertexes'] as List;
        for (var i = 0; i + 1 < vertices.length; i += 2) {
          points.add(GeoPoint((vertices[i + 1] as num).toDouble(), (vertices[i] as num).toDouble()));
        }
      }
    }
    final summary = r['summary'] as Map;
    return (
      TravelRoute(
        distanceMeters: (summary['distance'] as num).toInt(),
        durationSeconds: (summary['duration'] as num).toInt(),
        points: points,
      ),
      congested,
      slow,
      blocked.toSet().toList(),
      unknown,
    );
  }

  Future<TravelRoute> _transit(GeoPoint a, GeoPoint b, DateTime departure) async {
    if (googleKey.isEmpty) throw StateError('not configured');
    Map<String, dynamic> loc(GeoPoint p) => {
      'location': {
        'latLng': {'latitude': p.lat, 'longitude': p.lng},
      },
    };
    final response = await _client
        .post(
          Uri.parse('https://routes.googleapis.com/directions/v2:computeRoutes'),
          headers: {
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': googleKey,
            'X-Goog-FieldMask':
                'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline,routes.legs.steps.transitDetails.transitLine',
          },
          body: jsonEncode({
            'origin': loc(a),
            'destination': loc(b),
            'travelMode': 'TRANSIT',
            'departureTime': departure.toUtc().toIso8601String(),
            'languageCode': 'ko',
          }),
        )
        .timeout(const Duration(seconds: 18));
    if (response.statusCode != 200) throw StateError('transit request failed');
    final routes = (jsonDecode(utf8.decode(response.bodyBytes)) as Map)['routes'] as List?;
    if (routes == null || routes.isEmpty) throw StateError('no transit route returned');
    final r = routes.first as Map;
    final modes = <String>{}, lines = <String>[];
    for (final leg in r['legs'] as List? ?? const []) {
      for (final step in leg['steps'] as List? ?? const []) {
        final line = step['transitDetails']?['transitLine'];
        if (line == null) continue;
        final mode = switch (line['vehicle']?['type']) {
          'BUS' || 'INTERCITY_BUS' || 'TROLLEYBUS' => 'bus',
          'SUBWAY' || 'METRO_RAIL' || 'TRAM' || 'MONORAIL' => 'subway',
          'RAIL' || 'HEAVY_RAIL' || 'HIGH_SPEED_TRAIN' || 'COMMUTER_TRAIN' || 'LONG_DISTANCE_TRAIN' => 'rail',
          _ => null,
        };
        if (mode != null) modes.add(mode);
        if (line['name'] is String) lines.add(line['name'] as String);
      }
    }
    return TravelRoute(
      mode: TravelMode.transit,
      durationSeconds: int.parse((r['duration'] as String).replaceAll('s', '')),
      distanceMeters: (r['distanceMeters'] as num?)?.toInt() ?? 0,
      points: decodePolyline(r['polyline']['encodedPolyline'] as String),
      transitLines: lines,
      transportModes: modes,
    );
  }

  static List<GeoPoint> decodePolyline(String encoded) {
    var index = 0, lat = 0, lng = 0;
    int component() {
      var value = 0, shift = 0, byte = 0;
      do {
        if (index >= encoded.length || shift > 30) throw const FormatException('Invalid route geometry');
        byte = encoded.codeUnitAt(index++) - 63;
        value |= (byte & 31) << shift;
        shift += 5;
      } while (byte >= 32);
      return (value & 1) == 1 ? -((value >> 1) + 1) : value >> 1;
    }

    final points = <GeoPoint>[];
    while (index < encoded.length) {
      lat += component();
      lng += component();
      points.add(GeoPoint(lat / 1e5, lng / 1e5));
    }
    return points;
  }
}
