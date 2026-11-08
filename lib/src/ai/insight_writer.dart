/// Gemini를 사용해 Insight 카드의 텍스트 작성 ("why for you").
///
/// 규칙([InsightEngine])이 팩트를 선택함: 어떤 일정, 어떤 행사, 거리, 날짜, 확률.
/// 모델은 이 팩트만을 바탕으로 [Insight.body]와 [Insight.why]를 자연어로 다시 작성함.
/// 응답 검증: 팩트에 없는 숫자가 포함되거나 텍스트가 비어 있으면 해당 카드는
/// 규칙 텍스트 상태로 유지됨. 따라서 AI가 실수하더라도 카드가 잘못되지 않음.
///
/// 순수 Dart: Flutter·HTTP를 쓰지 않는다 (프롬프트, 스키마, 캐시 키, 검증).
/// 전송은 [GeminiClient]가 담당하므로 앱·서버 프록시 어디서든 같은 검증을 쓴다.
library;

import 'dart:convert';

import '../models/models.dart';

/// 프롬프트나 스키마 변경 시 버전을 올려야 함: 기존 캐시는 자동으로 만료됨.
const insightPromptVersion = 3;

/// 모델이 쓴 문장.
class InsightWriting {
  const InsightWriting({required this.body, required this.why, required this.model});

  final LocalizedText body;
  final LocalizedText why;
  final String model;

  Map<String, dynamic> toJson() => {'bk': body.ko, 'be': body.en, 'wk': why.ko, 'we': why.en, 'm': model};

  static InsightWriting fromJson(Map<String, dynamic> j) => InsightWriting(
        body: LocalizedText(ko: j['bk'] as String, en: j['be'] as String),
        why: LocalizedText(ko: j['wk'] as String, en: j['we'] as String),
        model: j['m'] as String,
      );
}

abstract final class InsightWriter {
  /// AI가 다시 쓰지 않는 카드.
  /// - `traffic:` 공식 교통 통제 — 출처 문장을 템플릿 그대로 보여준다.
  /// - `crowd:` 근처 대형 행사 참고 — 평가에서 모델이 "이동 경로에 영향"처럼 확인되지 않은
  ///   교통 영향을 덧붙이는 사례가 나왔다 (숫자 검증으로는 잡히지 않음). 그래서 제외한다.
  /// - `strike:` 뉴스 파업 참고 — 기사 인용을 그대로 보여준다.
  static bool isEligible(Insight insight) =>
      !insight.id.startsWith('traffic:') && !insight.id.startsWith('crowd:') && !insight.id.startsWith('strike:');

  static const systemInstruction =
      'You write the text of insight cards for LifeRadar, a lifestyle assistant for people living in Korea. '
      'Each card connects the user\'s own plans and interests with events, deadlines or weather.\n'
      'For each input item write, in both Korean and English:\n'
      '- body: 1-2 short sentences. Say what is happening and one concrete thing the user can do.\n'
      '- why: 1 sentence. Explain why this matters to THIS user, linking their plan and/or interests '
      'to the event or weather. Be specific, not generic.\n'
      '"facts" is a plain rule-based summary: use it for facts only and do NOT copy its wording. '
      'Never write generic lines like "Matches your interests (...)". Mention the user\'s plan by its title or place '
      'when there is one, and say what the event actually is (from event.about / category).\n'
      'Strict rules:\n'
      '1. Use only facts in the item (facts, signals, plan, event, user_interests). Never invent dates, times, '
      'prices, distances, percentages, capacities or claims. Any number you write must appear in the item.\n'
      '2. Event names: use title_en in English and title_ko in Korean. In English text, write Korean place, '
      'venue and city names in their common English/romanized form (부산 해운대 → "Haeundae, Busan", '
      '대전컨벤션센터 → "Daejeon Convention Center"); no Hangul in English text. In Korean text keep them in Korean.\n'
      '3. Korean: natural, polite 해요체. English: friendly and plain. No emojis, no hashtags, no quotes around the whole text.\n'
      '4. Do not mention AI, confidence scores or data sources.';

  /// 단일 카드에 대해 모델에 전달되는 팩트(JSON). 캐시 키도 이를 기반으로 생성됨.
  static Map<String, dynamic> facts(
    Insight insight, {
    Plan? plan,
    RadarEvent? event,
    Set<String> interests = const {},
    required DateTime today,
  }) =>
      {
        'id': insight.id,
        'kind': insight.kind.name,
        'today': _ymd(today),
        'facts': {
          'headline': insight.title.en,
          'en': insight.body.en,
          'ko': insight.body.ko,
          'rule': insight.why.en,
        },
        'signals': [for (final s in insight.signals) s.summary.en],
        if (plan != null)
          'plan': {
            'title': plan.title,
            if (plan.locationText.isNotEmpty) 'place': plan.locationText,
            'start': _ymd(plan.start),
            'end': _ymd(plan.end),
          },
        if (event != null)
          'event': {
            'title_ko': event.title.ko,
            'title_en': event.title.en,
            'category': event.category.name,
            'about': _clip(event.description.en, 280),
            if (event.venue.isNotEmpty) 'venue': event.venue,
            if (event.city.isNotEmpty) 'city': event.city,
            'start': _ymd(event.start),
            'end': _ymd(event.end),
            if (event.deadline != null) 'registration_deadline': _ymd(event.deadline!),
            'tags': event.tags,
          },
        'user_interests': [
          for (final t in event?.tags ?? const <String>[])
            if (interests.contains(t)) t,
        ],
      };

  /// 팩트가 변경되지 않으면 재요청하지 않음. 두 가지 초기값을 사용한 FNV-1a 32 → 16 hex.
  /// 32비트 연산만 사용: 웹(JS)과 Android에서 동일한 결과 산출.
  static String cacheKey(Map<String, dynamic> facts) => hash('v$insightPromptVersion\n${jsonEncode(facts)}');

  static String hash(String text) {
    final bytes = utf8.encode(text);
    return _fnv32(bytes, 0x811c9dc5) + _fnv32(bytes, 0x050c5d1f);
  }

  static String _fnv32(List<int> bytes, int seed) {
    var h = seed;
    for (final b in bytes) {
      h ^= b;
      // h * 16777619 (= 2^24 + 403) — JS에서 정밀도 손실을 방지하기 위해 나누어 곱함.
      h = (((h << 24) & 0xFFFFFFFF) + h * 403) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  static Map<String, dynamic> requestBody(List<Map<String, dynamic>> items) => {
        'systemInstruction': {
          'parts': [
            {'text': systemInstruction},
          ],
        },
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': jsonEncode(items)},
            ],
          },
        ],
        'generationConfig': {
          'temperature': 0.4,
          'responseMimeType': 'application/json',
          'responseSchema': {
            'type': 'ARRAY',
            'items': {
              'type': 'OBJECT',
              'properties': {
                'id': {'type': 'STRING'},
                'body_ko': {'type': 'STRING'},
                'body_en': {'type': 'STRING'},
                'why_ko': {'type': 'STRING'},
                'why_en': {'type': 'STRING'},
              },
              'required': ['id', 'body_ko', 'body_en', 'why_ko', 'why_en'],
            },
          },
        },
      };

  /// 모델 응답 → id별 텍스트. 검증을 통과하지 못한 항목은 제외됨 (규칙 텍스트 유지).
  static Map<String, InsightWriting> parseResponse(
    Map<String, dynamic> json, {
    required Map<String, Map<String, dynamic>> factsById,
    required String model,
  }) {
    final parts = (((json['candidates'] as List?)?.firstOrNull as Map?)?['content'] as Map?)?['parts'] as List?;
    final raw = parts?.map((p) => (p as Map)['text'] ?? '').join();
    if (raw == null || raw.isEmpty) return const {};
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const {};
    }
    if (decoded is! List) return const {};
    final out = <String, InsightWriting>{};
    for (final item in decoded) {
      if (item is! Map) continue;
      final id = item['id'];
      final facts = factsById[id];
      if (id is! String || facts == null) continue;
      String field(String k) => (item[k] is String ? item[k] as String : '').trim();
      final texts = [field('body_ko'), field('body_en'), field('why_ko'), field('why_en')];
      if (!texts.every((t) => isGrounded(t, facts))) continue;
      if (!_hangul.hasMatch(texts[0]) || !_hangul.hasMatch(texts[2])) continue; // ko 텍스트는 한국어로 작성
      out[id] = InsightWriting(
        body: LocalizedText(ko: texts[0], en: texts[1]),
        why: LocalizedText(ko: texts[2], en: texts[3]),
        model: model,
      );
    }
    return out;
  }

  /// 텍스트 사용 가능 여부: 비어 있지 않고, 너무 길지 않으며, 모든 숫자가 팩트에 존재하는지 확인.
  static bool isGrounded(String text, Map<String, dynamic> facts) {
    if (text.isEmpty || text.length > 320) return false;
    final source = jsonEncode(facts);
    for (final m in _number.allMatches(text)) {
      if (!source.contains(m.group(0)!)) return false;
    }
    return true;
  }

  static final _number = RegExp(r'\d+(?:\.\d+)?');
  static final _hangul = RegExp(r'[가-힣]');

  static String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String _clip(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';
}
