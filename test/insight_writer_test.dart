import 'dart:convert';

import 'package:test/test.dart';
import 'package:liferadar_core/liferadar_core.dart';

final _today = DateTime(2026, 11, 6);

const _insight = Insight(
  id: 'nearby:p1:e1',
  kind: InsightKind.opportunity,
  planId: 'p1',
  eventIds: ['e1'],
  title: LocalizedText(ko: '부산에 있는 동안: 재즈 페스티벌', en: 'While you are at Busan: Jazz Festival'),
  body: LocalizedText(ko: '11월 8일 해운대에서 열립니다. 일정 장소에서 약 2.4 km.', en: 'On Nov 8 at Haeundae, about 2.4 km from your plan.'),
  why: LocalizedText(ko: '관심사(#music)와 맞습니다.', en: 'It matches your interests (#music).'),
  confidence: 0.8,
);

final _plan = Plan(
  id: 'p1',
  title: 'Busan trip',
  start: DateTime(2026, 11, 8),
  end: DateTime(2026, 11, 9),
  locationText: '부산역',
  city: '부산',
);

Map<String, dynamic> _facts() => InsightWriter.facts(_insight, plan: _plan, interests: {'music'}, today: _today);

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

Map<String, String> _item({String bodyKo = '11월 8일 해운대에서 재즈 공연이 있어요. 부산 일정 중에 들러 보세요.', String bodyEn = 'Jazz at Haeundae on Nov 8, 2.4 km from your plan.'}) => {
      'id': _insight.id,
      'body_ko': bodyKo,
      'body_en': bodyEn,
      'why_ko': '음악을 좋아하시고 그날 부산에 계세요.',
      'why_en': 'You love music and will already be in Busan.',
    };

void main() {
  test('사실: 일정과 관심사가 포함되고 캐시 키가 안정적이다', () {
    final f = _facts();
    expect(f['plan'], containsPair('title', 'Busan trip'));
    expect(f['facts'], containsPair('en', _insight.body.en));
    expect(InsightWriter.cacheKey(f), InsightWriter.cacheKey(_facts()));
    final other = InsightWriter.facts(_insight, interests: {'music'}, today: _today);
    expect(InsightWriter.cacheKey(other), isNot(InsightWriter.cacheKey(f)));
  });

  test('캐시 키는 웹(JS)과 VM에서 같다 — 32비트 연산', () {
    // `flutter test --platform chrome`에서도 같은 값이 나와야 한다.
    expect(InsightWriter.hash('부산 x 2.4'), '7f66113e5bd3995c');
  });

  test('올바른 응답은 받아들인다', () {
    final out = InsightWriter.parseResponse(
      _response([_item()]),
      factsById: {_insight.id: _facts()},
      model: 'm',
    );
    expect(out[_insight.id]!.body.en, contains('Haeundae'));
    expect(out[_insight.id]!.model, 'm');
  });

  test('사실에 없는 숫자(지어낸 값)는 거부한다', () {
    final out = InsightWriter.parseResponse(
      _response([_item(bodyEn: 'Tickets cost 35000 won, 2.4 km away.')]),
      factsById: {_insight.id: _facts()},
      model: 'm',
    );
    expect(out, isEmpty);
  });

  test('한국어 문장이 한국어가 아니거나, 모르는 id, 깨진 JSON — 거부한다', () {
    final facts = {_insight.id: _facts()};
    expect(InsightWriter.parseResponse(_response([_item(bodyKo: 'Jazz on Nov 8')]), factsById: facts, model: 'm'), isEmpty);
    expect(InsightWriter.parseResponse(_response([{..._item(), 'id': 'x'}]), factsById: facts, model: 'm'), isEmpty);
    final broken = {
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': '[{"id": '},
            ],
          },
        },
      ],
    };
    expect(InsightWriter.parseResponse(broken, factsById: facts, model: 'm'), isEmpty);
  });

  test('AI 대상: 교통 통제와 혼잡 참고 카드는 제외한다', () {
    Insight card(String id) => Insight(
          id: id,
          kind: InsightKind.planAlert,
          title: const LocalizedText(ko: 't', en: 't'),
          body: const LocalizedText(ko: 'b', en: 'b'),
          why: const LocalizedText(ko: 'w', en: 'w'),
          confidence: 0.5,
        );
    expect(InsightWriter.isEligible(card('nearby:p:e')), isTrue);
    expect(InsightWriter.isEligible(card('deadline:e')), isTrue);
    expect(InsightWriter.isEligible(card('traffic:p:n')), isFalse);
    expect(InsightWriter.isEligible(card('crowd:p:e')), isFalse);
  });
}
