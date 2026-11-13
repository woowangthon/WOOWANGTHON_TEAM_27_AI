import 'dart:math' as math;

import '../models/models.dart';

/// 경로 회랑 주변의 행사 찾기 (결정론적 — AI 아님).
/// 단계: 경로 단순화 → 날짜·회랑(거리) 필터 → 관심사·가까움 점수.
class RouteMatcher {
  const RouteMatcher({this.corridorKm = 15, this.sampleKm = 1.0});

  /// 경로에서의 최대 거리.
  final double corridorKm;

  /// 폴리라인을 이 간격으로 줄인다 (2500점 → ~400).
  final double sampleKm;

  /// [tripStart]..[tripEnd] 기간에 열리고 경로에서 [corridorKm] 이내인 행사.
  /// 점수 = 관심사 적합도(60%) + 가까움(40%). 내림차순.
  List<RouteOpportunity> match({
    required List<GeoPoint> route,
    required List<RadarEvent> events,
    required Set<String> interests,
    required DateTime tripStart,
    required DateTime tripEnd,
    double Function(RadarEvent, Set<String>)? interestScore,
  }) {
    if (route.length < 2) return [];
    final samples = sample(route, sampleKm);
    final result = <RouteOpportunity>[];
    for (final e in events) {
      if (e.placeless) continue;
      final overlaps = !e.end.isBefore(tripStart) && !e.start.isAfter(tripEnd);
      if (!overlaps) continue;
      final d = distanceToPolylineKm(e.location, samples);
      if (d > corridorKm) continue;
      final interest = (interestScore ?? _defaultInterest)(e, interests);
      final proximity = 1 - d / corridorKm;
      result.add(RouteOpportunity(
        event: e,
        distanceFromRouteKm: d,
        score: 0.6 * interest + 0.4 * proximity,
      ));
    }
    result.sort((a, b) => b.score.compareTo(a.score));
    return result;
  }

  static double _defaultInterest(RadarEvent e, Set<String> interests) {
    if (e.tags.isEmpty) return 0;
    return e.tags.where(interests.contains).length / e.tags.length;
  }

  /// [stepKm]마다 점 하나만 남긴다 (첫 점과 마지막 점은 항상 유지).
  static List<GeoPoint> sample(List<GeoPoint> pts, double stepKm) {
    if (pts.length <= 2) return pts;
    final out = <GeoPoint>[pts.first];
    var acc = 0.0;
    for (var i = 1; i < pts.length - 1; i++) {
      acc += haversineKm(pts[i - 1], pts[i]);
      if (acc >= stepKm) {
        out.add(pts[i]);
        acc = 0;
      }
    }
    out.add(pts.last);
    return out;
  }

  /// 폴리라인에서 [p]에 가장 가까운 점 (대중교통 우회용: "이 역에서 내리세요").
  /// 선분 위의 투영점을 반환하므로 점이 드문 KTX 선에서도 정확하다.
  static GeoPoint nearestPointOnPolyline(GeoPoint p, List<GeoPoint> line) {
    if (line.length == 1) return line.first;
    var best = line.first;
    var bestD = double.infinity;
    for (var i = 0; i + 1 < line.length; i++) {
      final a = line[i], b = line[i + 1];
      final dx = b.lng - a.lng, dy = b.lat - a.lat;
      final len2 = dx * dx + dy * dy;
      final t = len2 == 0 ? 0.0 : (((p.lng - a.lng) * dx + (p.lat - a.lat) * dy) / len2).clamp(0.0, 1.0);
      final c = GeoPoint(a.lat + t * dy, a.lng + t * dx);
      final d = haversineKm(p, c);
      if (d < bestD) {
        bestD = d;
        best = c;
      }
    }
    return best;
  }

  /// 점에서 폴리라인까지의 최단 거리 (각 선분에 투영).
  static double distanceToPolylineKm(GeoPoint p, List<GeoPoint> line) {
    var best = double.infinity;
    for (var i = 0; i + 1 < line.length; i++) {
      best = math.min(best, _distanceToSegmentKm(p, line[i], line[i + 1]));
    }
    return line.length == 1 ? haversineKm(p, line.first) : best;
  }

  /// 짧은 거리용 평면(equirectangular) 투영 — 한국 범위에서는 충분히 정확하다.
  static double _distanceToSegmentKm(GeoPoint p, GeoPoint a, GeoPoint b) {
    const r = 6371.0;
    final lat0 = _rad((a.lat + b.lat) / 2);
    double x(GeoPoint q) => _rad(q.lng) * math.cos(lat0) * r;
    double y(GeoPoint q) => _rad(q.lat) * r;
    final ax = x(a), ay = y(a), bx = x(b), by = y(b), px = x(p), py = y(p);
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var t = len2 == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final cx = ax + t * dx, cy = ay + t * dy;
    return math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
  }

  static double haversineKm(GeoPoint a, GeoPoint b) {
    const r = 6371.0;
    final dLat = _rad(b.lat - a.lat), dLng = _rad(b.lng - a.lng);
    final h = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_rad(a.lat)) * math.cos(_rad(b.lat)) * math.pow(math.sin(dLng / 2), 2);
    return 2 * r * math.asin(math.sqrt(h));
  }

  static double _rad(double deg) => deg * math.pi / 180;
}
