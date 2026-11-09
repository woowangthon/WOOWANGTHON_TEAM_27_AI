import 'package:test/test.dart';
import 'package:liferadar_core/demo.dart';
import 'package:liferadar_core/liferadar_core.dart';

void main() {
  // 단순화한 서울 → 대전 → 부산 경로 (KTX/경부선 방향에 가깝게).
  const route = [
    GeoPoint(37.5547, 126.9707), // 서울역
    GeoPoint(36.8, 127.15),
    GeoPoint(36.3320, 127.4340), // 대전역
    GeoPoint(35.8, 128.6),
    GeoPoint(35.1151, 129.0403), // 부산역
  ];
  const matcher = RouteMatcher();

  test('haversine: 서울–부산 직선 ~325 km', () {
    final d = RouteMatcher.haversineKm(route.first, route.last);
    expect(d, closeTo(325, 5));
  });

  test('경로 위 점의 거리는 ~0', () {
    expect(RouteMatcher.distanceToPolylineKm(const GeoPoint(36.3320, 127.4340), route), lessThan(0.5));
  });

  test('11월 20일: 대전 AI 세미나는 찾고, 서울 COEX (12월)는 찾지 않는다', () {
    final opps = matcher.match(
      route: route,
      events: sampleEvents,
      interests: {'ai'},
      tripStart: DateTime(2026, 11, 20),
      tripEnd: DateTime(2026, 11, 20, 23, 59),
    );
    final ids = opps.map((o) => o.event.id).toList();
    expect(ids, contains('ev-daejeon-ai-seminar'));
    expect(ids, isNot(contains('ev-coex-dev-conf'))); // 날짜가 맞지 않음
    expect(ids, isNot(contains('ev-busan-ai-expo'))); // 11월 21일
    // AI 관심사가 있으면 세미나가 음악 콘서트보다 위에 있어야 한다
    expect(ids.first, 'ev-daejeon-ai-seminar');
  });

  test('회랑 밖의 행사는 나오지 않는다', () {
    final far = RadarEvent(
      id: 'far',
      title: const LocalizedText(ko: 'x', en: 'x'),
      description: const LocalizedText(ko: 'x', en: 'x'),
      category: EventCategory.meetup,
      tags: const ['ai'],
      start: DateTime(2026, 11, 20, 10),
      end: DateTime(2026, 11, 20, 12),
      venue: 'Gangneung',
      city: 'Gangneung',
      location: const GeoPoint(37.7519, 128.8761), // 강릉 — 경로에서 ~150 km
    );
    final opps = matcher.match(
      route: route,
      events: [far],
      interests: {'ai'},
      tripStart: DateTime(2026, 11, 20),
      tripEnd: DateTime(2026, 11, 21),
    );
    expect(opps, isEmpty);
  });
}
