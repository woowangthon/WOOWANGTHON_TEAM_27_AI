import 'dart:convert';

import 'package:test/test.dart';
import 'package:liferadar_core/liferadar_core.dart';

RadarEvent _event({String ko = '연극 [점프x컷]', List<String> tags = const ['culture', 'music']}) => RadarEvent(
      id: 'seoul-1',
      title: LocalizedText(ko: ko, en: ko),
      description: const LocalizedText(ko: '대학로 소극장 공연', en: '대학로 소극장 공연'),
      category: EventCategory.performance,
      tags: tags,
      start: DateTime(2026, 11, 20, 19),
      end: DateTime(2026, 11, 20, 21),
      venue: '대학로',
      city: '서울 종로구',
      location: const GeoPoint(37.58, 127.0),
      source: 'seoul-culture',
    );

Map<String, dynamic> _response(Object items) => {
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

void main() {
  test('캐시 키는 안정적이며 텍스트에 따라 달라진다', () {
    expect(AiEnrich.cacheKey(_event()), AiEnrich.cacheKey(_event()));
    expect(AiEnrich.cacheKey(_event()), isNot(AiEnrich.cacheKey(_event(ko: '다른 제목'))));
    expect(AiEnrich.cacheKey(_event()), hasLength(16));
  });

  test('요청: 구조화 JSON, 태그는 허용 목록에서만', () {
    final body = AiEnrich.requestBody([_event()]);
    final config = body['generationConfig'] as Map;
    expect(config['responseMimeType'], 'application/json');
    final tagEnum = (((config['responseSchema'] as Map)['items'] as Map)['properties'] as Map)['tags']['items']['enum'];
    expect(tagEnum, allowedTags);
    final sent = jsonDecode(((body['contents'] as List).single['parts'] as List).single['text'] as String) as List;
    expect(sent.single['title'], '연극 [점프x컷]');
  });

  test('응답: 알 수 없는 태그와 빈 번역은 버린다', () {
    final r = AiEnrich.parseResponse(_response([
      {'id': 'seoul-1', 'title_en': 'Play: Jump x Cut', 'description_en': 'A small-theater play.', 'tags': ['culture', 'robots']},
      {'id': 'seoul-2', 'title_en': '', 'description_en': '', 'tags': []},
    ]), model: 'm');
    expect(r.keys, ['seoul-1']);
    expect(r['seoul-1']!.tags, ['culture']);
  });

  test('품질: 가나가 섞이거나 번역되지 않은 응답은 거부한다', () {
    final r = AiEnrich.parseResponse(_response([
      {'id': 'a', 'title_en': 'Guソk-Guソk Live', 'description_en': 'Street music.', 'tags': ['music']},
      {'id': 'b', 'title_en': '한동 알럼나이 파운더스', 'description_en': 'Founders.', 'tags': ['startup']},
      {
        'id': 'c',
        'title_en': 'DDP Architecture Tour',
        'description_en': 'A guided tour of 동대문디자인플라자 (DDP), the landmark by Zaha Hadid, covering its curved architecture.',
        'tags': [],
      },
      {'id': 'd', 'title_en': 'Every Corner Live', 'description_en': '서울 곳곳에서 열리는 거리공연입니다.', 'tags': []},
    ]));
    expect(r.keys, ['c']); // c: 설명 안의 한국어 이름 하나 — 허용
  });

  test('적용: 영어 문장, 모델 태그 + 기준 태그; 사실은 바뀌지 않는다', () {
    final e = _event();
    final out = AiEnrich.apply(
      e,
      const Enrichment(titleEn: 'Play: Jump x Cut', descriptionEn: 'A small-theater play.', tags: ['books']),
    );
    expect(out.title.en, 'Play: Jump x Cut');
    expect(out.title.ko, e.title.ko);
    expect(out.tags, ['culture', 'books']); // performance → "culture" 기준 태그, "music"(잘못됨)은 제거
    expect(out.start, e.start);
    expect(out.location.lat, e.location.lat);
    // 모델이 태그를 주지 않으면 — 기존 태그
    expect(AiEnrich.apply(e, const Enrichment(titleEn: 'X', descriptionEn: '', tags: [])).tags, e.tags);
  });
}
