import 'package:test/test.dart';
import 'package:liferadar_core/liferadar_core.dart';

// 테스트는 「집회·마라톤·축제 뉴스의 이동 영향 판별 로직」 문서의 D 사례를 따른다.
// 일정에는 이동수단이 없으므로 → "mode UNKNOWN" → 최고 결과는 CAUTION (§9, 9행).

const _cityHall = GeoPoint(37.5663, 126.9779);
final _now = DateTime(2026, 11, 7, 8);

Plan _plan({DateTime? start, DateTime? end, GeoPoint? at = _cityHall}) {
  final s = start ?? DateTime(2026, 11, 8, 10);
  return Plan(
    id: 'p1',
    title: 'Meeting',
    start: s,
    end: end ?? s.add(const Duration(hours: 1)),
    locationText: '서울시청',
    city: 'Seoul',
    location: at,
  );
}

TrafficNotice _notice({
  required DateTime start,
  DateTime? end,
  GeoPoint at = const GeoPoint(37.5690, 126.9779), // ~300 m 북쪽
  TrafficKind kind = TrafficKind.rally,
}) =>
    TrafficNotice(
      id: 'topis-1',
      kind: kind,
      title: '[통제] 세종대로 집회',
      detail: '[통제] 세종대로 집회\n- 양방향 일부 통제',
      start: start,
      end: end,
      location: at,
      source: 'seoul-topis',
      sourceName: '서울시 TOPIS · 실시간 돌발정보',
      sourceUrl: 'https://topis.seoul.go.kr',
    );

void main() {
  const m = TrafficMatcher();

  test('D07: 일정 전 2시간 구간, 1 km 이내 → CAUTION (이동수단 미확인)', () {
    // 일정 10:00, 구간 [08:00, 10:00); 영향 09:00–12:00.
    final r = m.evaluate(_plan(), _notice(start: DateTime(2026, 11, 8, 9), end: DateTime(2026, 11, 8, 12)), _now);
    expect(r.decision, TrafficDecision.caution);
    expect(r.time, TimeMatch.window);
    expect(r.space, SpaceMatch.nearby);
    expect(r.reasons, contains('MODE_UNKNOWN'));
  });

  test('D02: 시간 불일치 → IGNORE', () {
    final r = m.evaluate(_plan(), _notice(start: DateTime(2026, 11, 8, 12), end: DateTime(2026, 11, 8, 14)), _now);
    expect(r.decision, TrafficDecision.ignore);
  });

  test('D03: 경계만 맞닿으면 겹치지 않는다 ([start, end))', () {
    // 영향 06:00–08:00에 끝나고, 구간은 08:00에 시작한다.
    final ends = m.evaluate(_plan(), _notice(start: DateTime(2026, 11, 8, 6), end: DateTime(2026, 11, 8, 8)), _now);
    expect(ends.decision, TrafficDecision.ignore);
    // 영향이 정확히 일정 시작(10:00)에 시작 — 구간은 10:00에 닫힌다.
    final starts = m.evaluate(_plan(), _notice(start: DateTime(2026, 11, 8, 10), end: DateTime(2026, 11, 8, 12)), _now);
    expect(starts.decision, TrafficDecision.ignore);
  });

  test('1 km보다 멀면 → IGNORE; 일정 장소가 없으면 → NEEDS_REVIEW', () {
    final far = _notice(start: DateTime(2026, 11, 8, 9), end: DateTime(2026, 11, 8, 12), at: const GeoPoint(37.5126, 127.0590));
    expect(m.evaluate(_plan(), far, _now).decision, TrafficDecision.ignore);
    final near = _notice(start: DateTime(2026, 11, 8, 9), end: DateTime(2026, 11, 8, 12));
    expect(m.evaluate(_plan(at: null), near, _now).decision, TrafficDecision.needsReview);
  });

  test('D06: 종일 일정 — 날짜만 (DATE_MATCH → CAUTION)', () {
    final allDay = _plan(start: DateTime(2026, 11, 8), end: DateTime(2026, 11, 9));
    final r = m.evaluate(allDay, _notice(start: DateTime(2026, 11, 8, 14), end: DateTime(2026, 11, 8, 18)), _now);
    expect(r.time, TimeMatch.date);
    expect(r.decision, TrafficDecision.caution);
    final otherDay = _notice(start: DateTime(2026, 11, 9, 14), end: DateTime(2026, 11, 9, 18));
    expect(m.evaluate(allDay, otherDay, _now).decision, TrafficDecision.ignore);
  });

  test('D14: 종료 미상 — 시작 날짜에만, 무기한 활성화하지 않음', () {
    final sameDay = m.evaluate(_plan(), _notice(start: DateTime(2026, 11, 8, 7)), _now);
    expect(sameDay.time, TimeMatch.possible);
    expect(sameDay.decision, TrafficDecision.caution);
    final dayBefore = m.evaluate(_plan(), _notice(start: DateTime(2026, 11, 7, 7)), _now);
    expect(dayBefore.decision, TrafficDecision.ignore);
  });

  test('§9-2: 이미 시작한 일정에는 새 경고 없음', () {
    final r = m.evaluate(
      _plan(start: DateTime(2026, 11, 7, 7)),
      _notice(start: DateTime(2026, 11, 7, 6), end: DateTime(2026, 11, 7, 12)),
      _now,
    );
    expect(r.decision, TrafficDecision.ignore);
  });

  test('InsightEngine: 카드는 템플릿 문장, 출처와 시간 포함; "지연"이라고 하지 않는다', () {
    final list = const InsightEngine().build(
      plans: [_plan()],
      events: const [],
      interests: const {},
      now: _now,
      traffic: [_notice(start: DateTime(2026, 11, 8, 9), end: DateTime(2026, 11, 8, 12))],
    );
    final card = list.singleWhere((i) => i.id == 'traffic:p1:topis-1');
    expect(card.kind, InsightKind.planAlert);
    expect(card.why.ko, contains('서울시 TOPIS'));
    expect(card.why.ko, contains('세종대로 집회'));
    expect(card.signals.first.summary.ko, contains('09:00'));
    expect(card.body.ko, contains('확인해 주세요'));
    expect(card.body.en.toLowerCase(), isNot(contains('delay')));
    expect(card.sources.single.title, '서울시 TOPIS · 실시간 돌발정보');
  });

  test('InsightEngine: 같은 도로의 여러 구간은 카드 하나, 일정당 최대 2개 (가까운 순)', () {
    TrafficNotice road(String id, String title, double lat) => TrafficNotice(
          id: id,
          kind: TrafficKind.construction,
          title: title,
          detail: title,
          start: DateTime(2026, 11, 8, 6),
          end: DateTime(2026, 11, 30),
          location: GeoPoint(lat, 126.9779),
          source: 'its',
          sourceName: '국가교통정보센터(ITS) · 돌발상황정보',
        );
    final list = const InsightEngine().build(
      plans: [_plan()],
      events: const [],
      interests: const {},
      now: _now,
      traffic: [
        road('a1', '[세종대로] 공사', 37.5670), // ~0.1 km
        road('a2', '[세종대로] 공사', 37.5675), // 같은 도로, 다른 구간
        road('b', '[을지로] 공사', 37.5690), // ~0.3 km
        road('c', '[종로] 공사', 37.5700), // ~0.4 km — 한도 초과
      ],
    );
    final ids = [for (final i in list) if (i.id.startsWith('traffic:')) i.id];
    expect(ids, ['traffic:p1:a1', 'traffic:p1:b']);
  });
}
