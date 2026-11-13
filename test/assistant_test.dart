import 'dart:convert';

import 'package:liferadar_core/liferadar_core.dart';
import 'package:test/test.dart';

final _now = DateTime(2026, 11, 11, 10); // 수요일

RadarEvent _e(
  String id,
  EventCategory c, {
  required DateTime start,
  List<String> tags = const [],
  GeoPoint at = const GeoPoint(37.5665, 126.9780), // 서울
  bool free = false,
  DateTime? deadline,
  bool placeless = false,
}) => RadarEvent(
  id: id,
  title: LocalizedText(ko: id, en: id),
  description: const LocalizedText(ko: '', en: ''),
  category: c,
  tags: tags,
  start: start,
  end: deadline ?? start.add(const Duration(hours: 3)), // 공고: 접수 기간 = 마감까지
  venue: 'Hall',
  city: 'City',
  location: at,
  source: 'test',
  isFree: free,
  deadline: deadline,
  placeless: placeless,
);

const _busan = GeoPoint(35.1587, 129.1604);
final _trip = Plan(
  id: 'trip',
  title: 'Busan trip',
  start: DateTime(2026, 11, 20, 9),
  end: DateTime(2026, 11, 22, 20),
  locationText: '부산 해운대',
  city: 'Busan',
  location: _busan,
);

final _events = [
  _e('jazz-sat', EventCategory.concert, start: DateTime(2026, 11, 14, 19), tags: ['music'], free: true),
  _e('expo-busan', EventCategory.conference, start: DateTime(2026, 11, 20, 10), tags: ['ai'], at: _busan),
  _e('far-busan', EventCategory.festival, start: DateTime(2026, 11, 28, 10), at: _busan),
  _e(
    'kstartup',
    EventCategory.startupSupport,
    start: DateTime(2026, 11, 1),
    deadline: DateTime(2026, 11, 13),
    placeless: true,
  ),
  _e('old', EventCategory.concert, start: DateTime(2026, 11, 1, 19)),
];

void main() {
  test('Generic deadline notices include contests without narrowing to startup support', () {
    final query = AssistantQuery.parse('마감 임박한 공고 알려줘', now: _now);
    final contest = RadarEvent.fromJson({
      ..._events.firstWhere((e) => e.id == 'kstartup').toJson(),
      'id': 'contest-deadline',
      'category': 'contest',
      'applicationStatus': 'open',
      'lastVerifiedAt': _now.toIso8601String(),
    });
    final results = Assistant.retrieve(query, events: [contest], interests: const {}, now: _now);
    expect(results.map((e) => e.id), contains('contest-deadline'));
    expect(AssistantQuery.parse('창업 공고 알려줘', now: _now).categories, contains(EventCategory.startupSupport));
  });

  group('질문 읽기 (코드)', () {
    test('이번 주말 · 무료 · 콘서트', () {
      final q = AssistantQuery.parse('이번 주말 무료 콘서트 있어?', now: _now);
      expect(q.from, DateTime(2026, 11, 14));
      expect(q.to, DateTime(2026, 11, 16));
      expect(q.freeOnly, isTrue);
      expect(q.categories, {EventCategory.concert});
    });

    test('날짜 "11월 20일", 지역 영어 이름, 마감', () {
      expect(AssistantQuery.parse('11월 20일에 뭐 하지', now: _now).from, DateTime(2026, 11, 20));
      expect(AssistantQuery.parse('anything in Busan?', now: _now).region, '부산');
      expect(AssistantQuery.parse('마감 임박한 공고', now: _now).deadlineSoon, isTrue);
    });

    test('일정 이름 → 그 일정의 날짜와 장소 근처', () {
      final q = AssistantQuery.parse('Busan trip 때 갈 만한 곳?', now: _now, plans: [_trip]);
      expect(q.plan?.id, 'trip');
      expect(q.from, DateTime(2026, 11, 20));
      expect(q.to, DateTime(2026, 11, 23));
      expect(q.near, _busan);
    });

    test('날짜로 가리킨 일정 ("11월 20일 일정에 …")', () {
      final q = AssistantQuery.parse('11월 20일 일정에 영향 줄 만한 거 있어?', now: _now, plans: [_trip]);
      expect(q.plan?.id, 'trip');
      expect(q.from, DateTime(2026, 11, 20));
      expect(q.near, _busan);
    });
  });

  group('후보 찾기 (코드)', () {
    List<String> find(String question) => Assistant.retrieve(
      AssistantQuery.parse(question, now: _now, plans: [_trip]),
      events: _events,
      interests: const {'ai', 'music'},
      now: _now,
    ).map((e) => e.id).toList();

    test('조건에 맞는 실제 행사만, 지난 행사는 없음', () {
      expect(find('이번 주말 무료 콘서트'), ['jazz-sat']);
      expect(find('Busan trip 때 갈 만한 곳'), ['expo-busan']); // 28일 축제는 일정 밖
      expect(find('마감 임박한 공고'), ['kstartup']);
      expect(find('콘서트'), isNot(contains('old')));
    });

    test('조건에 맞는 종류가 없으면 무관한 행사로 대체하지 않는다', () {
      expect(find('이번 주말 해커톤'), isEmpty);
    });

    test('일반 대화와 일치하지 않는 검색어에 추천을 반복하지 않는다', () {
      expect(find('바보'), isEmpty);
      expect(find('안녕하세요'), isEmpty);
      expect(find('없는행사이름'), isEmpty);
    });
  });

  group('답 검증 (코드)', () {
    final q = AssistantQuery.parse('Busan trip 때 갈 만한 곳', now: _now, plans: [_trip]);
    final candidates = [_events[1], _events[3]];
    final ctx = Assistant.context(query: q, candidates: candidates, plans: [_trip], now: _now, interests: const {'ai'});

    Map<String, dynamic> resp(Map<String, Object> data) => {
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': jsonEncode(data)},
            ],
          },
        },
      ],
    };

    AssistantReply parse(Map<String, Object> data, List<String> rejected) => Assistant.parseResponse(
      resp(data),
      candidates: candidates,
      context: ctx,
      fallbackText: 'FALLBACK',
      model: 'm',
      rejected: rejected,
    );

    test('후보에 없는 id·행동은 버리고, 장소 없는 공고는 지도 보기 불가', () {
      final rejected = <String>[];
      final r = parse({
        'reply': '11월 20일 부산 일정 중에 expo-busan이 열려요.',
        'event_ids': ['expo-busan', 'made-up'],
        'actions': [
          {'type': 'add_to_calendar', 'event_id': 'expo-busan'},
          {'type': 'show_on_map', 'event_id': 'kstartup'},
          {'type': 'delete_everything', 'event_id': 'expo-busan'},
        ],
      }, rejected);
      expect(r.fromAi, isTrue);
      expect(r.eventIds, ['expo-busan']);
      expect(r.actions.single.type, AssistantActionType.addToCalendar);
      expect(rejected, hasLength(3));
    });

    test('CONTEXT에 없는 숫자(지어낸 가격·날짜)가 있으면 답 문장을 규칙 문장으로', () {
      final rejected = <String>[];
      final r = parse({
        'reply': '입장료는 15,000원이고 11월 21일 오후 3시에 시작해요.',
        'event_ids': ['expo-busan'],
        'actions': <Object>[],
      }, rejected);
      expect(r.text, 'FALLBACK');
      expect(r.fromAi, isFalse);
      expect(r.eventIds, ['expo-busan']); // 카드는 실제 데이터라 그대로
      expect(rejected.single, contains('15,000'));
    });

    test('숫자 검사: 한 자리 개수는 허용', () {
      expect(Assistant.ungroundedNumbers('3개 찾았어요', '{}'), isEmpty);
      expect(Assistant.ungroundedNumbers('20일', '"2026-11-20"'), isEmpty);
      expect(Assistant.ungroundedNumbers('25일', '"2026-11-20"'), ['25']);
    });

    test('AI 없이: 같은 후보로 규칙 문장', () {
      final r = Assistant.fallback(q, candidates);
      expect(r.fromAi, isFalse);
      expect(r.eventIds, ['expo-busan', 'kstartup']);
      expect(r.text, contains('Busan trip'));
    });
  });
}
