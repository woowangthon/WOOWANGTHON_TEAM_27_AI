import 'package:liferadar_core/liferadar_core.dart';
import 'package:test/test.dart';

final now = DateTime.parse('2026-11-12T00:00:00Z');
RadarEvent contest({String audience = 'general', String status = 'open', DateTime? verified}) => RadarEvent(
  id: 'sotong-contest-test',
  title: const LocalizedText(ko: '아이디어 공모전', en: 'Idea contest'),
  description: const LocalizedText(ko: '접수 공고', en: 'Application notice'),
  category: EventCategory.contest,
  tags: const ['contest'],
  start: DateTime(2026, 11, 10),
  end: DateTime(2026, 11, 20),
  deadline: DateTime(2026, 11, 20),
  venue: '주관기관',
  city: '미확인',
  location: const GeoPoint(37.56, 126.97),
  placeless: true,
  source: 'sotong-contest',
  url: 'https://modu.go.kr',
  deadlinePrecision: 'date',
  applicationStatus: status,
  lastVerifiedAt: verified ?? now,
  eligibilityText: '국민 누구나 (팀 2~4명)',
  audience: audience,
);
void main() {
  test('contest serialization, copy and optional backward compatibility', () {
    final e = contest();
    expect(RadarEvent.fromJson(e.toJson()).toJson(), e.toJson());
    expect(e.copyWith(tags: ['contest', 'student']).lastVerifiedAt, now);
    expect(
      e
          .copyWith(
            title: const LocalizedText(ko: '새 제목', en: 'New title'),
          )
          .audience,
      'general',
    );
    expect(e.copyWith(lastVerifiedAt:()=>null).lastVerifiedAt,isNull);
    expect(e.copyWith(applicationStatus:()=>'cancelled').applicationVisible(now),isFalse);
    expect(e.applicationStatusAt(now),'open');
    final legacy = e.toJson()
      ..remove('applicationStatus')
      ..remove('lastVerifiedAt')
      ..remove('deadlinePrecision')
      ..remove('eligibilityText');
    final parsed = RadarEvent.fromJson(legacy);
    expect(parsed.applicationStatus, isNull);
    expect(parsed.deadlinePrecision, isNull);
  });
  test('date-only deadline inclusive through KST day, exact instant exclusive', () {
    final e = contest();
    expect(e.applicationVisible(DateTime.parse('2026-11-20T14:59:59Z')), isTrue);
    expect(e.applicationVisible(DateTime.parse('2026-11-20T15:00:00Z')), isFalse);
    final precise = RadarEvent.fromJson({
      ...e.toJson(),
      'deadlinePrecision': 'datetime',
      'deadline': '2026-11-20T08:00:00Z',
    });
    expect(precise.applicationVisible(DateTime.parse('2026-11-20T08:00:00Z')), isFalse);
    expect(precise.applicationDate(precise.deadline!).hour, 17);
  });
  test('search recognizes contest, includes general and university but student recommendation excludes restricted', () {
    final q = AssistantQuery.parse('공모전', now: now, plans: []);
    expect(q.categories, contains(EventCategory.contest));
    for (final audience in ['general', 'university']) {
      expect(
        Assistant.retrieve(
          q,
          events: [contest(audience: audience)],
          interests: {'contest'},
          taste: Taste.none.withStage(LifeStage.student),
          now: now,
        ),
        hasLength(1),
      );
    }
    expect(
      Assistant.retrieve(
        q,
        events: [contest(audience: 'restricted')],
        interests: {'contest'},
        taste: Taste.none.withStage(LifeStage.student),
        now: now,
      ),
      isEmpty,
    );
  });
  test('placeless is excluded at shared route engine boundary', () {
    final e = contest();
    expect(
      const RouteMatcher().match(
        route: [e.location, const GeoPoint(37.57, 126.98)],
        events: [e],
        interests: {'contest'},
        tripStart: e.start,
        tripEnd: e.end,
      ),
      isEmpty,
    );
  });
  test('fresh applications generate deadlines, stale/cancelled/closed do not', () {
    List<Insight> build(RadarEvent e) =>
        const InsightEngine().build(plans: [], events: [e], interests: {'contest'}, now: now);
    expect(build(contest()).any((i) => i.kind == InsightKind.deadline), isTrue);
    for (final e in [
      contest(verified: now.subtract(const Duration(hours: 49))),
      contest(status: 'cancelled'),
      contest(status: 'closed'),
    ]) {
      expect(build(e), isEmpty);
    }
    final e = contest();
    final context = Assistant.context(
      query: AssistantQuery.parse('공모전', now: now, plans: []),
      candidates: [e],
      plans: [],
      now: now,
      interests: {'contest'},
    );
    final fact = (context['events'] as List).single as Map;
    expect(fact['eligibilityConfirmedForUser'], isFalse);
    expect(fact['dateMeaning'], contains('application'));
    expect(fact['date'], isNot(contains('00:00')));
  });
}
