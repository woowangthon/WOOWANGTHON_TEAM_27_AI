import 'dart:convert';

import 'package:liferadar_core/liferadar_core.dart';
import 'package:test/test.dart';

// 2026-11-06~08 실제 네이버 뉴스 검색 결과를 줄인 예시.
final _airport = NewsArticle.fromSearchItem({
  'title': '공항철도노조 오는 13일 개통 이후 첫 <b>경고파업</b> 예고',
  'description': '필수유지업무 따라 평일 운행률 69.2% 철도는 필수공익사업이어서 파업 당일에도 운행률이 유지된다.',
  'originallink': 'https://news.example.com/a1',
  'link': 'https://n.news.naver.com/a1',
  'pubDate': 'Sun, 08 Nov 2026 09:12:00 +0900',
});
final _nationwide = NewsArticle.fromSearchItem({
  'title': '철도·지하철·공항·학교까지…공공부문 줄파업 예고',
  'description':
      '전국철도지하철노동조합협의회는 20일 이후 공동 총파업에 돌입할 방침이다. 전국철도노조와 서울교통공사노조 등이 참여해',
  'originallink': 'https://news.example.com/a2',
  'pubDate': 'Sun, 08 Nov 2026 07:00:00 +0900',
});
final _drama = NewsArticle.fromSearchItem({
  'title': '‘닥터X’ 김우석 180도 돌변, 왜?',
  'description': '이날 버스정류장 장면에서는 박태경의 과거도 공개됐다.',
  'originallink': 'https://news.example.com/a3',
  'pubDate': 'Sun, 08 Nov 2026 08:00:00 +0900',
});

Map<String, dynamic> _response(List<Map<String, Object>> items) => {
  'candidates': [
    {
      'content': {
        'parts': [
          {'text': jsonEncode(items)},
        ],
      },
    },
  ],
};

Map<String, Object> _item(
  NewsArticle a, {
  bool related = true,
  String status = 'scheduled',
  String quote = '오는 13일 개통 이후 첫 경고파업 예고',
  String start = '2026-11-13',
  String dateQuote = '오는 13일',
  List<String> regions = const ['인천', '서울'],
  String operator = '공항철도',
  String mode = 'rail',
}) => {
  'id': a.id,
  'related': related,
  'mode': mode,
  'operator': operator,
  'regions': regions,
  'status': status,
  'status_quote': quote,
  'start_date': start,
  'end_date': '',
  'date_quote': dateQuote,
};

List<TransitStrike> _parse(
  List<Map<String, Object>> items, {
  Map<String, String>? rejected,
}) => StrikeExtractor.parseResponse(
  _response(items),
  articlesById: {
    for (final a in [_airport, _nationwide, _drama]) a.id: a,
  },
  model: 'm',
  rejected: rejected,
);

void main() {
  test('검색 결과 정리: HTML 태그 제거, 발행 시각, URL 해시 id', () {
    expect(_airport.title, '공항철도노조 오는 13일 개통 이후 첫 경고파업 예고');
    expect(_airport.publishedAt, DateTime(2026, 11, 8, 9, 12));
    expect(_airport.id, hasLength(16));
  });

  test('근거가 맞는 예고 파업은 날짜·지역과 함께 통과', () {
    final s = _parse([_item(_airport)]).single;
    expect(s.status, StrikeStatus.scheduled);
    expect(s.start, DateTime(2026, 11, 13));
    expect(s.regions, ['인천', '서울']);
    expect(s.isActive, isTrue);
  });

  test('관련 없음·상태 미상·기사에 없는 인용은 버린다 (이유 기록)', () {
    final rejected = <String, String>{};
    final out = _parse([
      _item(_drama, related: false, status: 'unknown', quote: ''),
      _item(_nationwide, status: 'unknown'),
      _item(_airport, quote: '공항철도 노조가 파업을 철회했다'), // 지어낸 인용
    ], rejected: rejected);
    expect(out, isEmpty);
    expect(
      rejected.values,
      containsAll([
        'unrelated',
        'status unknown',
        'status quote not in article',
      ]),
    );
  });

  test('날짜는 근거 인용에 그 날이 있고 발행일 기준 범위일 때만', () {
    expect(
      _parse([_item(_airport, dateQuote: '평일 운행률 69.2%')]).single.start,
      isNull,
    ); // 인용에 13일 없음
    expect(
      _parse([_item(_airport, start: '2026-11-14')]).single.start,
      isNull,
    ); // 인용의 날과 다름
    expect(
      _parse([_item(_airport, start: '2028-11-13')]).single.start,
      isNull,
    ); // 발행일에서 너무 멂
  });

  test('허용 목록 밖 지역은 버린다', () {
    expect(
      _parse([
        _item(_airport, regions: ['인천', 'Incheon']),
      ]).single.regions,
      ['인천'],
    );
  });

  test('같은 사건 묶기: 날짜 없는 기사도 합치고, 상태는 가장 최근 기사', () {
    TransitStrike s(
      String id,
      DateTime pub,
      StrikeStatus st, {
      DateTime? start,
    }) => TransitStrike(
      id: id,
      mode: TransitMode.rail,
      operator: id == 'c' ? '공항철도 노조' : '공항철도',
      regions: const ['인천'],
      status: st,
      quote: 'q',
      start: start,
      articleTitle: id,
      url: 'u',
      publishedAt: pub,
    );
    final merged = StrikeExtractor.merge([
      s(
        'a',
        DateTime(2026, 11, 6),
        StrikeStatus.scheduled,
        start: DateTime(2026, 11, 13),
      ),
      s('b', DateTime(2026, 11, 7), StrikeStatus.scheduled),
      s('c', DateTime(2026, 11, 12), StrikeStatus.withdrawn), // 이후 철회 보도
    ]);
    expect(merged, hasLength(1));
    expect(merged.single.sourceCount, 3);
    expect(merged.single.status, StrikeStatus.withdrawn);
    expect(merged.single.start, DateTime(2026, 11, 13));
    expect(merged.single.isActive, isFalse);
  });

  test('지역 포함: 전국·수도권 묶음', () {
    const incheon = GeoPoint(37.4563, 126.7052);
    const busan = GeoPoint(35.1587, 129.1604);
    expect(KoreaRegions.regionOf(busan), '부산');
    expect(KoreaRegions.covers(['전국'], busan), isTrue);
    expect(KoreaRegions.covers(['수도권'], incheon), isTrue);
    expect(KoreaRegions.covers(['서울'], busan), isFalse);
  });

  group('InsightEngine 파업 참고 카드', () {
    final trip = Plan(
      id: 'trip',
      title: 'Busan trip',
      start: DateTime(2026, 11, 20, 9),
      end: DateTime(2026, 11, 22, 20),
      locationText: '부산 해운대',
      city: 'Busan',
      location: const GeoPoint(35.1587, 129.1604),
    );
    final strike = _parse([
      _item(
        _nationwide,
        mode: 'subway',
        operator: '전국철도노조·서울교통공사노조',
        quote: '20일 이후 공동 총파업에 돌입할 방침이다',
        start: '2026-11-20',
        dateQuote: '20일 이후',
        regions: ['전국'],
      ),
    ]).single;
    List<Insight> build(List<TransitStrike> s, {DateTime? now}) =>
        const InsightEngine().build(
          plans: [trip],
          events: const [],
          interests: const {},
          now: now ?? DateTime(2026, 11, 8),
          strikes: s,
        );

    test('일정 날짜·지역이 맞으면 참고 카드 (인용·기사 링크, AI 재작성 제외)', () {
      final card = build([
        strike,
      ]).singleWhere((i) => i.id.startsWith('strike:'));
      expect(card.title.ko, contains('파업 예고'));
      expect(card.why.ko, contains('20일 이후 공동 총파업'));
      expect(card.why.ko, contains('참고용'));
      expect(card.sources.single.url, 'https://news.example.com/a2');
      expect(InsightWriter.isEligible(card), isFalse);
    });

    test('날짜가 안 맞거나, 철회됐거나, 일정이 끝났으면 카드 없음', () {
      final otherDay = _parse([_item(_airport)]).single; // 11/13, 인천·서울
      expect(
        build([otherDay]).where((i) => i.id.startsWith('strike:')),
        isEmpty,
      );
      final withdrawn = StrikeExtractor.merge([
        strike,
        TransitStrike.fromJson({
          ...strike.toJson(),
          'id': 'w',
          'status': 'withdrawn',
          'publishedAt': DateTime(2026, 11, 15).toIso8601String(),
        }),
      ]);
      expect(
        build(withdrawn).where((i) => i.id.startsWith('strike:')),
        isEmpty,
      );
      expect(
        build(
          [strike],
          now: DateTime(2026, 11, 23),
        ).where((i) => i.id.startsWith('strike:')),
        isEmpty,
      );
    });
  });

  test('묶기: 수단 표기가 달라도 같은 사건, 대표 기사는 제목에 "파업"이 있는 기사', () {
    TransitStrike s(String title, TransitMode mode, DateTime pub) =>
        TransitStrike(
          id: title,
          mode: mode,
          operator: '공항철도',
          regions: const ['인천'],
          status: StrikeStatus.scheduled,
          quote: 'q',
          start: DateTime(2026, 11, 13),
          articleTitle: title,
          url: 'u-$title',
          publishedAt: pub,
        );
    final merged = StrikeExtractor.merge([
      s('공항철도 13일 경고파업 예고', TransitMode.rail, DateTime(2026, 11, 6)),
      s('주말 칼럼: 겨울의 풍경', TransitMode.subway, DateTime(2026, 11, 8)),
    ]);
    expect(merged.single.sourceCount, 2);
    expect(merged.single.articleTitle, '공항철도 13일 경고파업 예고');
  });
}
