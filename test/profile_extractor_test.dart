import 'dart:convert';

import 'package:liferadar_core/liferadar_core.dart';
import 'package:test/test.dart';

const _allowed = {
  'ai': 'AI',
  'startup': 'startups',
  'music': 'music & concerts',
  'career': 'careers & jobs',
  'gaming': 'games',
};

const _text = '컴퓨터공학과 3학년 학생이에요. 요즘 AI 공부를 하고 있고, 주말엔 재즈 공연 보러 다녀요. 졸업 후 취업도 고민 중!';

Map<String, dynamic> _response(Map<String, Object> data) => {
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

RadarEvent _e(String id, EventCategory c, List<String> tags) => RadarEvent(
  id: id,
  title: LocalizedText(ko: id, en: id),
  description: const LocalizedText(ko: '', en: ''),
  category: c,
  tags: tags,
  start: DateTime(2026, 11, 20, 10),
  end: DateTime(2026, 11, 20, 18),
  venue: 'Hall',
  city: 'Seoul',
  location: const GeoPoint(37.5, 127.0),
  source: 'test',
);

void main() {
  test('근거는 단어 번호 → 원문에서 잘라 만든다; 범위가 틀리면·허용 밖 태그는 버린다', () {
    // 0 컴퓨터공학과 1 3학년 2 학생이에요. 3 요즘 4 AI 5 공부를 6 하고 7 있고, 8 주말엔 9 재즈 10 공연 …
    final rejected = <String>[];
    final s = ProfileExtractor.parseResponse(
      _response({
        'stage': 'student',
        'stage_from': 1,
        'stage_to': 2,
        'interests': [
          {'tag': 'ai', 'from': 4, 'to': 5},
          {'tag': 'music', 'from': 9, 'to': 10},
          {'tag': 'career', 'from': 15, 'to': 17},
          {'tag': 'gaming', 'from': 40, 'to': 41}, // 글 밖 번호
          {'tag': 'startup', 'from': 0, 'to': 17}, // 근거가 너무 김 (글 전체)
          {'tag': 'fashion', 'from': 0, 'to': 0}, // 허용 목록 밖
          {'tag': 'ai', 'from': 4, 'to': 4}, // 중복
        ],
      }),
      text: _text,
      allowedTags: _allowed,
      model: 'm',
      rejected: rejected,
    );
    expect(s.stage, LifeStage.student);
    expect(s.stageQuote, '3학년 학생이에요.');
    expect(s.tags.map((t) => (t.tag, t.quote)), [('ai', 'AI 공부를'), ('music', '재즈 공연'), ('career', '취업도 고민 중!')]);
    expect(s.fromAi, isTrue);
    expect(rejected, ['gaming: bad span 40-41', 'startup: bad span 0-17', 'fashion: not allowed']);

    final noStage = ProfileExtractor.parseResponse(
      _response({'stage': 'founder', 'stage_from': -1, 'stage_to': -1, 'interests': <Object>[]}),
      text: _text,
      allowedTags: _allowed,
    );
    expect(noStage.stage, isNull);
    expect(noStage.isEmpty, isTrue);
  });

  test('요청: 단어 번호를 붙인 글, 허용 태그와 상황이 스키마 enum으로', () {
    final body = ProfileExtractor.requestBody(_text, _allowed);
    final schema = body['generationConfig']['responseSchema'] as Map;
    final tagEnum = schema['properties']['interests']['items']['properties']['tag']['enum'] as List;
    expect(tagEnum, _allowed.keys.toList());
    expect(schema['properties']['stage']['enum'], contains('jobSeeker'));
    expect(jsonEncode(body), contains('careers & jobs'));
    expect(jsonEncode(body), contains('[4]AI'));
  });

  test('AI 없이: 키워드 일치로 같은 형식의 제안', () {
    final s = ProfileExtractor.keywordFallback(
      _text,
      keywords: {
        'ai': ['AI', '인공지능'],
        'music': ['공연', '음악'],
        'gaming': ['게임'],
      },
    );
    expect(s.stage, LifeStage.student); // "취업도 고민 중"은 구직 키워드("취업 준비")가 아니다
    expect(s.tags.map((t) => t.tag), ['ai', 'music']);
    expect(s.fromAi, isFalse);
  });

  test('상황(LifeStage)이 순위를 올린다: 관심사가 없어도 학생에게 장학금', () {
    final scholarship = _e('sch', EventCategory.scholarship, ['student']);
    final concert = _e('c', EventCategory.concert, ['music']);
    final aiTalk = _e('ai', EventCategory.conference, ['ai']);
    const interests = {'ai'};
    expect(Taste.none.score(scholarship, interests), 0);
    final student = Taste.none.withStage(LifeStage.student);
    expect(student.score(scholarship, interests), greaterThan(0));
    expect(student.score(concert, interests), 0);
    // 관심사 일치가 상황만 맞는 것보다 위.
    expect(student.score(aiTalk, interests), greaterThan(student.score(scholarship, interests)));
    expect(LifeStage.founder.fits(_e('k', EventCategory.startupSupport, const [])), isTrue);
  });
}
