/// Gemini로 행사 정보를 보강한다 (수집 파이프라인에서만 — 키가 앱에 들어가지 않는다):
/// - 한국어 이름/설명 → 자연스러운 영어 (영어 UI에서도 이름이 한국어로 남지 않도록)
/// - 내용에 맞는 관심사 태그 (키워드 태거보다 정확)
///
/// 사실(날짜, 장소, 요금)은 바뀌지 않는다 — 모델은 문장과 태그만 제공한다.
/// 순수 Dart: 프롬프트, JSON 스키마, 응답 파싱, 결과 적용이 모두 여기에 있다 (테스트 가능).
library;

import 'dart:convert';

import '../models/models.dart';

/// 허용 태그 (앱의 관심사 목록과 동일). 모델은 이 중에서만 고른다.
const allowedTags = [
  'ai', 'developer', 'data', 'startup', 'design', //
  'contest', 'career', 'student', 'networking', 'finance', 'language', 'books',
  'music', 'culture', 'art', 'movie', 'photo', 'gaming',
  'sports', 'fitness', 'outdoor', 'travel',
  'food', 'family', 'pets', 'fashion', 'volunteer',
];

/// 행사 하나에 대한 모델 결과.
class Enrichment {
  const Enrichment({required this.titleEn, required this.descriptionEn, required this.tags, this.model});

  final String titleEn;
  final String descriptionEn;
  final List<String> tags;
  final String? model;

  Map<String, dynamic> toJson() => {'t': titleEn, 'd': descriptionEn, 'g': tags, if (model != null) 'm': model};

  static Enrichment fromJson(Map<String, dynamic> j) => Enrichment(
        titleEn: j['t'] as String,
        descriptionEn: j['d'] as String,
        tags: [for (final t in (j['g'] as List)) t as String],
        model: j['m'] as String?,
      );
}

class AiEnrich {
  /// 캐시 키: 한국어 텍스트가 바뀌지 않으면 다시 요청하지 않는다 (FNV-1a 64, 안정적).
  ///
  /// BigInt로 계산해 웹(JS)에서도 같은 값이 나온다. 표기는 기존 캐시 파일과 호환되도록
  /// 부호 있는 64비트 정수의 16진수 (예: `-1c9d4b84dd8c2e73`).
  static String cacheKey(RadarEvent e) {
    final mask = (BigInt.one << 64) - BigInt.one;
    final prime = BigInt.parse('100000001b3', radix: 16);
    var h = BigInt.parse('cbf29ce484222325', radix: 16);
    for (final b in utf8.encode('${e.title.ko}\n${e.description.ko}')) {
      h = ((h ^ BigInt.from(b)) * prime) & mask;
    }
    final signed = h >= (BigInt.one << 63) ? h - (BigInt.one << 64) : h;
    return signed.toRadixString(16).padLeft(16, '0');
  }

  static const systemInstruction =
      'You prepare Korean event listings for an English-language lifestyle app used in Korea.\n'
      'For each item:\n'
      '1. title_en: a natural English title. Translate meaningful words (e.g. 구석구석 → "Every Corner"); '
      'keep proper nouns (venues, organizations, performers, festival brand names) in their common '
      'romanized/English form. No quotes or brackets that are not in the original meaning.\n'
      '2. description_en: a faithful, concise English version (max ~3 short sentences). '
      'Do not invent dates, prices, or facts that are not in the text.\n'
      '3. tags: 1-4 interest tags from the allowed list that a person with that interest would '
      'genuinely care about. Prefer fewer, accurate tags. A play is "culture", not "music", unless it is musical.';

  /// generateContent 요청 본문 (구조화된 JSON 응답).
  static Map<String, dynamic> requestBody(List<RadarEvent> batch) => {
        'systemInstruction': {
          'parts': [
            {'text': systemInstruction},
          ],
        },
        'contents': [
          {
            'role': 'user',
            'parts': [
              {
                'text': jsonEncode([
                  for (final e in batch)
                    {
                      'id': e.id,
                      'category': e.category.name,
                      'title': e.title.ko,
                      'description': e.description.ko,
                    },
                ]),
              },
            ],
          },
        ],
        'generationConfig': {
          'temperature': 0.2,
          'responseMimeType': 'application/json',
          'responseSchema': {
            'type': 'ARRAY',
            'items': {
              'type': 'OBJECT',
              'properties': {
                'id': {'type': 'STRING'},
                'title_en': {'type': 'STRING'},
                'description_en': {'type': 'STRING'},
                'tags': {
                  'type': 'ARRAY',
                  'items': {'type': 'STRING', 'enum': allowedTags},
                },
              },
              'required': ['id', 'title_en', 'description_en', 'tags'],
            },
          },
        },
      };

  /// 모델 응답 → id별 결과. 알 수 없는 태그와 빈 번역은 버린다.
  static Map<String, Enrichment> parseResponse(Map<String, dynamic> json, {String? model}) {
    final text = (((json['candidates'] as List?)?.firstOrNull as Map?)?['content'] as Map?)?['parts'] as List?;
    final raw = text?.map((p) => (p as Map)['text'] ?? '').join();
    if (raw == null || raw.isEmpty) return const {};
    final out = <String, Enrichment>{};
    for (final item in jsonDecode(raw) as List) {
      final m = (item as Map).cast<String, dynamic>();
      final title = (m['title_en'] as String? ?? '').trim();
      final desc = (m['description_en'] as String? ?? '').trim();
      // 품질 검사: 번역되지 않았거나 다른 문자가 섞인 응답은 캐시에 넣지 않는다
      // (다시 요청한다). 예: "Guソk-Guソk Live" 또는 한국어 이름을 그대로 반환한 경우.
      if (!isCleanEnglish(title, maxHangul: 0) || !isCleanEnglish(desc, maxHangul: 0.15)) continue;
      out[m['id'] as String] = Enrichment(
        titleEn: title,
        descriptionEn: desc,
        tags: {for (final t in (m['tags'] as List? ?? const [])) if (allowedTags.contains(t)) t as String}.toList(),
        model: model,
      );
    }
    return out;
  }

  /// 일본어 가나/한자가 없고 한글 비율이 [maxHangul]을 넘지 않는다.
  static bool isCleanEnglish(String text, {required double maxHangul}) {
    if (text.isEmpty) return maxHangul > 0; // 설명은 비어 있을 수 있지만 이름은 안 된다
    if (RegExp(r'[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff]').hasMatch(text)) return false;
    final letters = RegExp(r'[A-Za-z\uac00-\ud7af]').allMatches(text).length;
    if (letters == 0) return false;
    final hangul = RegExp(r'[\uac00-\ud7af]').allMatches(text).length;
    return hangul / letters <= maxHangul;
  }

  /// 카테고리의 "기준" 태그 — 모델이 빼먹어도 유지한다 (필터와 순서가 안정되도록).
  static String? anchorTag(EventCategory c) => switch (c) {
        EventCategory.concert => 'music',
        EventCategory.exhibition => 'art',
        EventCategory.festival || EventCategory.performance => 'culture',
        EventCategory.contest => 'contest',
        EventCategory.startupSupport => 'startup',
        EventCategory.hackathon => 'developer',
        EventCategory.job => 'career',
        _ => null,
      };

  /// 결과를 행사에 적용: 영어 문장 + 모델 태그 (+ 기준 태그).
  /// 모델이 태그를 주지 않으면 기존(키워드) 태그를 유지한다.
  static RadarEvent apply(RadarEvent e, Enrichment r) {
    final anchor = anchorTag(e.category);
    final tags = r.tags.isEmpty ? e.tags : {?anchor, ...r.tags}.toList();
    return RadarEvent.fromJson({
      ...e.toJson(),
      'title': {'ko': e.title.ko, 'en': r.titleEn},
      'description': {'ko': e.description.ko, 'en': r.descriptionEn.isEmpty ? e.description.ko : r.descriptionEn},
      'tags': tags,
    });
  }
}
