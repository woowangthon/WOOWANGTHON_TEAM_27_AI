import 'package:test/test.dart';
import 'package:liferadar_core/liferadar_core.dart';

final clock = DateTime.utc(2026, 11, 11, 0);
TrafficNotice notice({String id = 'u1', String source = 'utic'}) => TrafficNotice(
  id: id,
  sourceRecordId: id,
  source: source,
  sourceName: source,
  kind: TrafficKind.rally,
  title: '집회 도로 통제',
  detail: '세종대로 부분통제',
  start: clock,
  end: clock.add(const Duration(hours: 3)),
  location: const GeoPoint(37.57, 126.98),
  controlEvidence: 'confirmed',
  evidenceText: '부분통제',
  evidenceMethod: 'synthetic-v1',
  timePrecision: 'minute',
  lastSeenAt: clock,
  fetchedAt: clock,
  roadName: '세종대로',
  direction: '북',
  section: '가~나',
  sourceUrlKind: 'center',
);
Plan plan() => Plan(
  id: 'p',
  title: '방문',
  start: clock.add(const Duration(hours: 2)),
  end: clock.add(const Duration(hours: 3)),
  locationText: '시청',
  city: '서울',
  location: const GeoPoint(37.57, 126.98),
);
void main() {
  test('legacy KST, UTC and explicit offset denote same instant; calendar overflow rejected', () {
    expect(trafficInstant('2026-11-11T09:00:00'), clock);
    expect(trafficInstant('2026-11-11T09:00:00+09:00'), clock);
    expect(trafficInstant('2026-11-11T00:00:00Z'), clock);
    for (final t in [
      '2026-02-30T12:00:00',
      '2026-11-11T24:01:00',
      '2026-11-11',
      '2026-11-11T09:00:00+99:99',
      '2026-11-11T09:00:00+09:60',
    ]) {
      expect(() => trafficInstant(t), throwsFormatException);
    }
    expect(trafficDay(DateTime.utc(2026, 11, 10, 16)), trafficInstant('2026-11-11T00:00:00'));
  });
  test('confirmed, event only, legacy, stale and missing observation gates', () {
    const m = TrafficMatcher();
    expect(m.evaluate(plan(), notice(), clock).decision, TrafficDecision.caution);
    for (final meta in [
      {'controlEvidence': 'unconfirmed'},
      {'evidenceText': null},
      {'lastSeenAt': null},
    ]) {
      expect(m.evaluate(plan(), notice().withMetadata(meta), clock).decision, TrafficDecision.ignore);
    }
    expect(m.evaluate(plan(), notice(), clock.add(const Duration(minutes: 60))).decision, TrafficDecision.caution);
    expect(m.evaluate(plan(), notice(), clock.add(const Duration(minutes: 61))).decision, TrafficDecision.reference);
    expect(notice().isRelevantAt(clock.add(const Duration(hours: 6, seconds: 1))), isFalse);
    expect(
      notice()
          .withMetadata({'lastSeenAt': clock.add(const Duration(seconds: 1)).toIso8601String()})
          .isRelevantAt(clock),
      isFalse,
    );
  });
  test('unknown end, date precision, conflict reference; release/end removes', () {
    const m = TrafficMatcher();
    for (final meta in [
      {'end': null},
      {'timePrecision': 'date'},
      {'conflict': true},
    ]) {
      expect(m.evaluate(plan(), notice().withMetadata(meta), clock).decision, TrafficDecision.reference);
    }
    for (final status in ['cancelled', 'expired', 'missing']) {
      expect(notice().withMetadata({'status': status}).isRelevantAt(clock), isFalse);
    }
    final n = notice().withMetadata({
      'end': null,
      'lastSeenAt': trafficInstant('2026-11-11T23:59:00').toIso8601String(),
    });
    expect(n.isRelevantAt(trafficInstant('2026-11-12T00:00:00')), isFalse);
    expect(notice().isRelevantAt(clock.add(const Duration(hours: 3))), isFalse);
  });
  test('conservative grouping, evidence preservation and stable aliases', () {
    final a = notice(), b = notice(id: 't', source: 'seoul-topis');
    final aliases = <String, String>{};
    final merged = TrafficMerger.merge([a, b], aliases: aliases).single;
    expect(merged.evidenceRefs, hasLength(2));
    expect(TrafficMerger.merge([b], aliases: aliases).single.groupId, merged.groupId);
    for (final meta in [
      {'direction': '남'},
      {'direction': null},
      {'end': null},
      {'start': clock.add(const Duration(hours: 1)).toIso8601String()},
      {'section': null},
    ]) {
      expect(TrafficMerger.merge([a, b.withMetadata(meta)]), hasLength(2));
    }
    expect(
      TrafficMerger.merge([
        a,
        b.withMetadata({
          'direction': null,
          'linkIds': ['1'],
          'linkSystem': null,
        }),
      ]),
      hasLength(2),
    );
  });
  test('location/time mismatch, invalid coordinates and touching boundary', () {
    const m = TrafficMatcher();
    for (final meta in [
      {'lat': 0},
      {'lat': 126.98, 'lng': 37.57},
      {'lat': double.nan},
      {'start': clock.add(const Duration(hours: 2)).toIso8601String()},
    ]) {
      expect(m.evaluate(plan(), notice().withMetadata(meta), clock).decision, TrafficDecision.ignore);
    }
    expect(m.evaluate(plan(), notice().withMetadata({'lat': 35.0}), clock).decision, TrafficDecision.ignore);
  });
  test('engine reference templates, copyWith metadata and UTIC push off', () {
    List<Insight> cards(TrafficNotice n) =>
        const InsightEngine().build(plans: [plan()], events: [], interests: {}, now: clock, traffic: [n]);
    final i = cards(notice()).single;
    expect(i.notificationEligible, isFalse);
    expect(i.copyWith().trafficContext, isNotNull);
    expect(cards(notice().withMetadata({'end': null})).single.title.ko, contains('참고'));
    expect(cards(notice().withMetadata({'controlEvidence': 'unconfirmed'})), isEmpty);
  });
  test('literal evidence negative precedence and URL key redaction boundary', () {
    expect(explicitRoadControl('행사 개최'), isFalse);
    expect(explicitRoadControl('부분통제 해제'), isFalse);
    expect(explicitRoadControl('부분통제'), isTrue);
    expect(safeTrafficUrl('https://www.utic.go.kr/map/map.do?menu=incident'), isTrue);
    expect(safeTrafficUrl('https://www.utic.go.kr/guide/imsOpenData.do?key=synthetic'), isFalse);
  });
  test('saved route modes, passage boundary and mixed-mode grade cap', () {
    TripContext trip(Set<String> modes, {DateTime? passage}) => TripContext(
      id: 't',
      version: '1',
      departure: clock.add(const Duration(minutes: 30)),
      arrival: clock.add(const Duration(minutes: 90)),
      modes: modes,
      points: const [GeoPoint(37.569, 126.98), GeoPoint(37.571, 126.98)],
      passageAt: passage,
    );
    const matcher = TrafficMatcher();
    expect(matcher.evaluate(plan(), notice(), clock, trip: trip({'car'})).decision, TrafficDecision.recommend);
    expect(matcher.evaluate(plan(), notice(), clock, trip: trip({'car', 'bus'})).decision, TrafficDecision.caution);
    expect(matcher.evaluate(plan(), notice(), clock, trip: trip({'subway'})).decision, TrafficDecision.ignore);
    expect(
      matcher
          .evaluate(plan(), notice(), clock, trip: trip({'car'}, passage: clock.add(const Duration(hours: 3))))
          .decision,
      TrafficDecision.ignore,
    );
  });
  test('release conflict downgrades and group split does not reuse card identity', () {
    final a = notice(), b = notice(id: 't', source: 'seoul-topis');
    final aliases = <String, String>{};
    TrafficMerger.merge([a, b], aliases: aliases);
    final split = TrafficMerger.merge([
      a,
      b.withMetadata({'direction': '남'}),
    ], aliases: aliases);
    expect(split.map((n) => n.groupId).toSet(), hasLength(2));
    final conflict = TrafficMerger.merge([
      a,
      b.withMetadata({'status': 'cancelled'}),
    ], now: clock).single;
    expect(conflict.status, 'active');
    expect(conflict.conflict, isTrue);
    expect(const TrafficMatcher().evaluate(plan(), conflict, clock).decision, TrafficDecision.reference);
  });

  test('negative particles, negated verbs and conditional wording never confirm control', () {
    for (final text in [
      '행사 중 도로 통제는 없습니다',
      '도로 통제가 없습니다',
      '도로 통제는 하지 않습니다',
      '차량 통제를 실시하지 않습니다',
      '[통제] 행사 취소',
      '부분통제 가능성이 있습니다',
      '전면통제 여부 미정',
      '통행 금지가 아닙니다',
      '도로 통제 시 우회', '도로 통제 종료', '통행 금지 표지 제거',
      '행사 안내',
    ]) {
      expect(explicitRoadControl(text), isFalse, reason: text);
    }
    expect(
      notice().withMetadata({
        'evidenceMethod': 'literal-road-control-v1',
        'evidenceText': '도로 통제는 없습니다',
      }).hasControlEvidence,
      isFalse,
    );
    for (final text in ['[통제] 세종대로 행사', '양방향 부분통제', '도로 통제 예정', '차로 통제 중', '차량 통제 실시', '우회로 없음 · 도로 통제 예정', '공사 완료 시까지 부분통제', '도로 통제 종료 예정 18:00']) {
      expect(explicitRoadControl(text), isTrue, reason: text);
    }
  });
  test('latest release resolves identity before end/TTL filtering in either order', () {
    final now = clock.add(const Duration(minutes: 30));
    final released = notice().withMetadata({
      'status': 'cancelled',
      'end': now.toIso8601String(),
      'lastSeenAt': now.toIso8601String(),
      'sourceUpdatedAt': now.toIso8601String(),
    });
    for (final records in [
      [notice(), released],
      [released, notice()],
    ]) {
      expect(TrafficMerger.merge(records, now: now).where((n) => n.isRelevantAt(now)), isEmpty);
    }
  });
  test('explicit ID withdrawal beats fresh fetches; only verified newer revision revives', () {
    final at = clock.add(const Duration(minutes: 30));
    final w = TrafficWithdrawal(source: 'utic', sourceRecordId: 'u1', observedAt: at);
    final refetched = notice().withMetadata({'lastSeenAt': at.add(const Duration(minutes: 1)).toIso8601String()});
    expect(TrafficMerger.merge([refetched], now: at.add(const Duration(minutes: 1)), withdrawals: [w]), isEmpty);
    final revised = refetched.withMetadata({'sourceUpdatedAt': at.add(const Duration(minutes: 1)).toIso8601String()});
    expect(TrafficMerger.merge([revised], now: at.add(const Duration(minutes: 1)), withdrawals: [w]), hasLength(1));
    expect(TrafficWithdrawal.fromJson(w.toJson()).blocks(refetched), isTrue);
  });
  test('published group plus newer direct member re-evaluates each original exactly once', () {
    final a = notice(), b = notice(id: 't', source: 'its');
    final published = TrafficMerger.merge([a, b], now: clock).single;
    final at = clock.add(const Duration(minutes: 30));
    final released = b.withMetadata({
      'status': 'cancelled',
      'lastSeenAt': at.toIso8601String(),
      'sourceUpdatedAt': at.toIso8601String(),
      'end': at.toIso8601String(),
    });
    final merged = TrafficMerger.merge([published, released], now: at).single;
    expect(merged.conflict, isTrue);
    expect(merged.evidenceRefs, hasLength(2));
    expect(merged.evidenceRefs.where((e) => e['source'] == 'its').single['status'], 'cancelled');
  });
}
