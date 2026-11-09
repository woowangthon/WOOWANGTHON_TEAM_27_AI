import 'dart:convert';

import '../models/life_stage.dart';
import 'gemini_client.dart';

/// 사용자가 자유롭게 쓴 자기소개에서 상황([LifeStage])과 관심사 태그를 제안한다.
///
/// 원칙 (AI는 제안, 사람은 결정):
/// - 태그는 앱이 준 허용 목록 안에서만 고른다 (스키마 enum + 코드 검사).
/// - 근거는 모델이 **글을 다시 쓰지 않고 단어 번호로 가리킨다**. 앱이 글을 단어로 나눠 번호를 붙여 보내면,
///   모델은 `from`–`to` 번호만 돌려주고 근거 문구는 코드가 사용자의 원문에서 잘라 만든다.
///   → 지어낸 인용이나 깨진 글자가 화면에 나올 수 없다. (처음에는 인용을 직접 쓰게 했는데, 실측에서
///   경량 모델이 한글 인용을 20~30% 깨뜨렸다 — 자모 분리, 엉뚱한 글자. 그래서 번호 방식으로 바꿨다.)
/// - 결과는 바로 저장하지 않는다. 화면에서 사용자가 근거를 보고 직접 켜고 끈 뒤 적용한다.
/// - 키가 없거나 할당량이 끝나면 [keywordFallback] (단순 단어 일치)로 같은 형식의 제안을 만든다.
abstract final class ProfileExtractor {
  /// 너무 긴 글은 자른다 (비용·지연).
  static const maxInputChars = 1200;

  /// 근거 한 개의 최대 단어 수 — 글 전체를 근거로 대는 것을 막는다.
  static const maxSpanWords = 8;

  static const systemInstruction = '''
You read a short self-introduction written by a user of an event-recommendation app in Korea.
The text may be in Korean, English or another language. It is given as numbered words: [0]word [1]word ...

Return JSON with:
- stage: the user's current life situation, one of {STAGES}, or "unknown" if the text does not say.
  student = in school/university; jobSeeker = looking for a job; employee = currently employed;
  founder = running or preparing a startup/business; freelancer = self-employed freelancer.
- stage_from, stage_to: the word numbers (inclusive) that show the stage; -1 if unknown.
- interests: up to 8 items {tag, from, to}. tag MUST be one of the allowed tags below.
  from/to = the word numbers (inclusive, at most 8 words) that show this interest.
  Only include interests the text clearly states or strongly implies. Do not guess from stereotypes
  (e.g. "student" alone does not mean "gaming"). Skip things the user says they dislike.

Allowed tags (tag: meaning):
{TAGS}''';

  /// 글을 공백 기준 단어로 나눈다 (모델이 번호로 가리키는 단위).
  static List<String> words(String text) => clip(text).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  static Map<String, dynamic> requestBody(String text, Map<String, String> allowedTags) {
    final w = words(text);
    return {
      'systemInstruction': {
        'parts': [
          {
            'text': systemInstruction
                .replaceFirst('{STAGES}', LifeStage.values.map((s) => s.name).join(', '))
                .replaceFirst('{TAGS}', [for (final e in allowedTags.entries) '- ${e.key}: ${e.value}'].join('\n')),
          },
        ],
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {
              'text': [for (var i = 0; i < w.length; i++) '[$i]${w[i]}'].join(' '),
            },
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0.1,
        'responseMimeType': 'application/json',
        'responseSchema': {
          'type': 'OBJECT',
          'properties': {
            'stage': {
              'type': 'STRING',
              'enum': [...LifeStage.values.map((s) => s.name), 'unknown'],
            },
            'stage_from': {'type': 'INTEGER'},
            'stage_to': {'type': 'INTEGER'},
            'interests': {
              'type': 'ARRAY',
              'items': {
                'type': 'OBJECT',
                'properties': {
                  'tag': {'type': 'STRING', 'enum': allowedTags.keys.toList()},
                  'from': {'type': 'INTEGER'},
                  'to': {'type': 'INTEGER'},
                },
                'required': ['tag', 'from', 'to'],
              },
            },
          },
          'required': ['stage', 'stage_from', 'stage_to', 'interests'],
        },
      },
    };
  }

  static String clip(String text) {
    final t = text.trim();
    return t.length <= maxInputChars ? t : t.substring(0, maxInputChars);
  }

  /// 단어 번호 [from]–[to] → 원문 문구. 범위가 틀리거나 너무 길면 null.
  static String? span(List<String> words, Object? from, Object? to) {
    if (from is! num || to is! num) return null;
    final a = from.toInt(), b = to.toInt();
    if (a < 0 || b < a || b >= words.length || b - a >= maxSpanWords) return null;
    return words.sublist(a, b + 1).join(' ');
  }

  /// 모델 응답 → 검증된 제안. [rejected]에는 버린 제안과 이유를 남긴다 (평가용).
  static ProfileSuggestion parseResponse(
    Map<String, dynamic> json, {
    required String text,
    required Map<String, String> allowedTags,
    String? model,
    List<String>? rejected,
  }) {
    final raw = (((json['candidates'] as List?)?.firstOrNull as Map?)?['content'] as Map?)?['parts'] as List?;
    final body = (raw?.firstOrNull as Map?)?['text'] as String?;
    if (body == null) throw const FormatException('empty response');
    final data = jsonDecode(body) as Map<String, dynamic>;
    final w = words(text);

    var stage = LifeStage.byName(data['stage'] as String?);
    String? stageQuote;
    if (stage != null) {
      stageQuote = span(w, data['stage_from'], data['stage_to']);
      if (stageQuote == null) {
        rejected?.add('stage ${stage.name}: bad span ${data['stage_from']}-${data['stage_to']}');
        stage = null;
      }
    }

    final tags = <TagSuggestion>[];
    for (final item in (data['interests'] as List? ?? const [])) {
      if (item is! Map) continue;
      final tag = item['tag'] as String? ?? '';
      final quote = span(w, item['from'], item['to']);
      if (!allowedTags.containsKey(tag)) {
        rejected?.add('$tag: not allowed');
      } else if (quote == null) {
        rejected?.add('$tag: bad span ${item['from']}-${item['to']}');
      } else if (tags.every((t) => t.tag != tag)) {
        tags.add(TagSuggestion(tag, quote));
      }
    }
    return ProfileSuggestion(stage: stage, stageQuote: stageQuote, tags: tags, model: model);
  }

  /// Gemini로 제안을 받는다. 실패하면 예외 — 화면은 [keywordFallback]을 쓴다.
  /// 제안이 **전부** 검증에서 떨어진 응답은 한 번만 다시 요청한다.
  static Future<ProfileSuggestion> extract(
    GeminiClient client,
    String text, {
    required Map<String, String> allowedTags,
    List<String>? rejected,
  }) async {
    ProfileSuggestion? out;
    for (var attempt = 0; attempt < 2; attempt++) {
      final dropped = <String>[];
      final (json, model) = await client.generate(requestBody(text, allowedTags));
      out = parseResponse(json, text: text, allowedTags: allowedTags, model: model, rejected: dropped);
      rejected?.addAll(dropped);
      if (!(out.isEmpty && dropped.isNotEmpty)) break;
    }
    return out!;
  }

  /// AI 없이: 글에 키워드가 있으면 제안 (근거 = 찾은 키워드). [keywords]: 태그 → 단어들.
  static ProfileSuggestion keywordFallback(
    String text, {
    required Map<String, List<String>> keywords,
    Map<LifeStage, List<String>> stageKeywords = defaultStageKeywords,
  }) {
    final lower = clip(text).toLowerCase();
    String? hit(List<String> words) {
      for (final w in words) {
        if (lower.contains(w.toLowerCase())) return w;
      }
      return null;
    }

    LifeStage? stage;
    String? stageQuote;
    for (final e in stageKeywords.entries) {
      final w = hit(e.value);
      if (w != null) {
        stage = e.key;
        stageQuote = w;
        break;
      }
    }
    return ProfileSuggestion(
      stage: stage,
      stageQuote: stageQuote,
      tags: [
        for (final e in keywords.entries)
          if (hit(e.value) case final w?) TagSuggestion(e.key, w),
      ],
    );
  }

  static const defaultStageKeywords = <LifeStage, List<String>>{
    LifeStage.jobSeeker: ['취준', '취업 준비', '구직', '이직 준비', 'job hunting', 'looking for a job', 'job seeker'],
    LifeStage.founder: ['창업', '스타트업 대표', '예비창업', 'founder', 'my startup', 'own business'],
    LifeStage.freelancer: ['프리랜서', 'freelance'],
    LifeStage.student: ['학생', '대학생', '대학원', '학교', '전공', 'student', 'university', 'college'],
    LifeStage.employee: ['직장인', '회사원', '회사에', '재직', 'employee', 'work at', 'working at'],
  };
}

class TagSuggestion {
  const TagSuggestion(this.tag, this.quote);
  final String tag;

  /// 근거: 사용자 글에 있는 문구.
  final String quote;
}

class ProfileSuggestion {
  const ProfileSuggestion({this.stage, this.stageQuote, this.tags = const [], this.model});

  final LifeStage? stage;
  final String? stageQuote;
  final List<TagSuggestion> tags;

  /// 응답한 Gemini 모델. null = 키워드 일치 (AI 아님).
  final String? model;

  bool get isEmpty => stage == null && tags.isEmpty;
  bool get fromAi => model != null;
}
