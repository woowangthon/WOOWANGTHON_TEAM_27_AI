/// 뉴스 기사에서 대중교통 파업 정보를 추출한다 — 팀 문서 「뉴스 파업정보 추출 구현 지침」 기반.
///
/// 검색 결과에는 해외 파업, 드라마, 이미 끝난 파업, "철회 요구" 같은 기사가 섞여 있어 키워드만으로는
/// 구분할 수 없다. 의미 판단은 Gemini가 하고, **코드가 근거를 검증**한다:
/// - 상태 근거 인용이 기사 원문(제목·요약)에 그대로 있어야 한다 → 없으면 버린다
/// - 날짜는 근거 인용에 그 날짜(일)가 있어야 하고, 발행일 기준으로 말이 되는 범위여야 한다 → 아니면 비운다
/// - 지역은 허용 목록 안에서만
/// 순수 Dart (프롬프트·스키마·검증). 전송은 [GeminiClient].
library;

import 'dart:convert';

import '../models/transit_strike.dart';
import '../models/domestic_news.dart';
import 'insight_writer.dart';

/// 검색 API로 받은 기사 (본문 전체가 아니라 제목 + 요약).
class NewsArticle {
  const NewsArticle({
    required this.id,
    required this.title,
    required this.description,
    required this.url,
    required this.publishedAt,
  });

  final String id;
  final String title;
  final String description;
  final String url;
  final DateTime publishedAt;

  /// 모델에 주는 원문 = 검증에 쓰는 원문.
  String get text => '$title\n$description';

  /// 검색 API 응답의 HTML 태그·엔티티를 걷어낸 기사.
  static NewsArticle fromSearchItem(Map<String, dynamic> item) {
    final url = '${item['originallink'] ?? ''}'.isNotEmpty ? '${item['originallink']}' : '${item['link']}';
    return NewsArticle(
      id: InsightWriter.hash(url),
      title: cleanText('${item['title'] ?? ''}'),
      description: cleanText('${item['description'] ?? ''}'),
      url: url,
      publishedAt: _rfc822('${item['pubDate'] ?? ''}') ?? DateTime.now(),
    );
  }

  static String cleanText(String s) => s
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static const _months = {
    'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6, //
    'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
  };

  /// "Fri, 06 Nov 2026 14:30:00 +0900" → 한국 시각.
  static DateTime? _rfc822(String v) {
    final m = RegExp(r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2})').firstMatch(v);
    final month = m == null ? null : _months[m[2]];
    if (m == null || month == null) return null;
    return DateTime(int.parse(m[3]!), month, int.parse(m[1]!), int.parse(m[4]!), int.parse(m[5]!));
  }
}

abstract final class StrikeExtractor {
  static const systemInstruction = '''
You read Korean news search results (title + snippet) and extract PUBLIC TRANSPORT strikes in South Korea that can affect people's travel.
For each item return one object.

related = true only if the item is about a strike (or strike plan) of a Korean public transport service: city bus, intercity bus, subway/metro, railway (KORAIL, KTX, SRT, airport railroad, light rail). Medical, metal, school or general-union strikes, foreign countries, dramas, opinion pieces without a concrete transport strike → related = false and status = "unknown".

status — decide by meaning, NOT keyword priority:
- preparing: strike vote / mediation request, no date yet
- conditional: "교섭이 결렬되면 …일 파업" (a condition is stated)
- scheduled: a strike date is announced/planned ("오는 13일 파업 예고", "20일 이후 총파업 돌입 방침")
- ongoing: the strike has actually started ("첫차부터 파업 돌입", "파업 이틀째")
- deferred: the planned strike was postponed/suspended (유보)
- withdrawn: the strike plan was cancelled (철회했다, 타결로 철회)
- ended: a strike that happened is over (파업 종료, 정상 운행 재개, 파업 사과)
- historical: only past strikes are described (지난해 파업 당시)
- unknown: cannot decide or conflicting
Rules: "철회를 요구했다", "철회를 검토", "합의되면 철회" are NOT withdrawn. "철회하지 않았다" alone is not ongoing. "철회 요구에도 파업 계속" is ongoing. A provisional agreement still pending a union vote is not withdrawn.

status_quote: copy an EXACT contiguous phrase (≤ 80 characters) from the title or snippet that proves the status. Do not paraphrase.
operator: the transport operator or route as written (e.g. 공항철도, 서울교통공사, 부산 시내버스, 코레일); "" if not stated.
mode: bus | subway | rail | unknown.
regions: where the affected service runs (not the reporter's dateline), only from this list: ${'{REGIONS}'}. Airport railroad → 인천, 서울. KORAIL or 전국철도노조 nationwide → 전국. 서울교통공사 → 서울.
start_date / end_date: YYYY-MM-DD resolved with the given published date ("오는 13일" published 2026-11-06 → 2026-11-13; "20일 이후" → start only). Empty string if the text has no date. Never invent a year or month that the text does not support.
date_quote: EXACT phrase containing the start date; "" if no date.
''';

  /// generateContent 요청 본문.
  static Map<String, dynamic> requestBody(List<NewsArticle> articles) => {
        'systemInstruction': {
          'parts': [
            {'text': systemInstruction.replaceFirst('{REGIONS}', KoreaRegions.names.join(', '))},
          ],
        },
        'contents': [
          {
            'role': 'user',
            'parts': [
              {
                'text': jsonEncode([
                  for (final a in articles)
                    {'id': a.id, 'published': _ymd(a.publishedAt), 'title': a.title, 'snippet': a.description},
                ]),
              },
            ],
          },
        ],
        'generationConfig': {
          'temperature': 0.1,
          'responseMimeType': 'application/json',
          'responseSchema': {
            'type': 'ARRAY',
            'items': {
              'type': 'OBJECT',
              'properties': {
                'id': {'type': 'STRING'},
                'related': {'type': 'BOOLEAN'},
                'mode': {
                  'type': 'STRING',
                  'enum': [for (final m in TransitMode.values) m.name],
                },
                'operator': {'type': 'STRING'},
                'regions': {
                  'type': 'ARRAY',
                  'items': {'type': 'STRING', 'enum': KoreaRegions.names},
                },
                'status': {
                  'type': 'STRING',
                  'enum': [for (final s in StrikeStatus.values) s.name],
                },
                'status_quote': {'type': 'STRING'},
                'start_date': {'type': 'STRING'},
                'end_date': {'type': 'STRING'},
                'date_quote': {'type': 'STRING'},
              },
              'required': ['id', 'related', 'mode', 'operator', 'regions', 'status', 'status_quote', 'start_date', 'date_quote'],
            },
          },
        },
      };

  /// 모델 응답 → 검증을 통과한 파업 정보 (관련 없거나 근거가 없는 기사는 빠진다).
  /// [rejected]에는 버린 이유를 기록한다 (평가·디버깅용).
  static List<TransitStrike> parseResponse(
    Map<String, dynamic> json, {
    required Map<String, NewsArticle> articlesById,
    required String model,
    Map<String, String>? rejected,
  }) {
    final parts = (((json['candidates'] as List?)?.firstOrNull as Map?)?['content'] as Map?)?['parts'] as List?;
    final raw = parts?.map((p) => (p as Map)['text'] ?? '').join();
    if (raw == null || raw.isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (decoded is! List) return const [];

    final out = <TransitStrike>[];
    for (final item in decoded.whereType<Map>()) {
      final article = articlesById[item['id']];
      if (article == null) continue;
      void reject(String why) => rejected?[article.id] = why;
      if (item['related'] != true) {
        reject('unrelated');
        continue;
      }
      if (!DomesticNews.accepts(article.text)) {
        reject('domestic transport subject not established');
        continue;
      }
      final status = StrikeStatus.values.asNameMap()[item['status']] ?? StrikeStatus.unknown;
      if (status == StrikeStatus.unknown) {
        reject('status unknown');
        continue;
      }
      final quote = '${item['status_quote'] ?? ''}'.trim();
      if (!isGrounded(quote, article.text)) {
        reject('status quote not in article');
        continue;
      }
      final regions = [
        for (final r in (item['regions'] as List? ?? const []))
          if (KoreaRegions.names.contains(r)) r as String,
      ];
      final dateQuote = '${item['date_quote'] ?? ''}'.trim();
      final start = groundedDate('${item['start_date'] ?? ''}', dateQuote, article);
      final endRaw = DateTime.tryParse('${item['end_date'] ?? ''}');
      final end = start != null && endRaw != null && !endRaw.isBefore(start) && _plausible(endRaw, article) ? endRaw : null;
      out.add(TransitStrike(
        id: article.id,
        mode: TransitMode.values.asNameMap()[item['mode']] ?? TransitMode.unknown,
        operator: '${item['operator'] ?? ''}'.trim(),
        regions: regions,
        status: status,
        quote: quote,
        start: start,
        end: end,
        dateQuote: start == null ? null : dateQuote,
        articleTitle: article.title,
        url: article.url,
        publishedAt: article.publishedAt,
        model: model,
      ));
    }
    return out;
  }

  /// 인용이 기사 원문에 그대로 있는가 (공백 차이와 말줄임표는 무시).
  /// [minLength]: 상태 근거는 4자 이상 (너무 짧은 인용은 근거가 되지 못한다), 날짜 근거는 "13일"처럼 짧아도 된다.
  static bool isGrounded(String quote, String text, {int minLength = 4}) {
    String norm(String s) => s.replaceAll('…', '').replaceAll('...', '').replaceAll(RegExp(r'\s+'), ' ').trim();
    final q = norm(quote);
    return q.length >= minLength && norm(text).contains(q);
  }

  /// 날짜는 (1) 형식이 맞고 (2) 근거 인용이 기사에 있으며 (3) 인용에 그 날(일)이 적혀 있고
  /// (4) 발행일 기준으로 말이 되는 범위일 때만 인정한다.
  static DateTime? groundedDate(String value, String dateQuote, NewsArticle article) {
    final d = DateTime.tryParse(value);
    if (d == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return null;
    if (!isGrounded(dateQuote, article.text, minLength: 2)) return null;
    if (!RegExp('(?<!\\d)${d.day}일').hasMatch(dateQuote)) return null;
    return _plausible(d, article) ? d : null;
  }

  static bool _plausible(DateTime d, NewsArticle a) {
    final pub = DateTime(a.publishedAt.year, a.publishedAt.month, a.publishedAt.day);
    return !d.isBefore(pub.subtract(const Duration(days: 7))) && !d.isAfter(pub.add(const Duration(days: 90)));
  }

  /// 같은 사건(운영 주체·수단·시작일)을 다룬 기사들을 하나로 묶는다. 상태는 가장 최근 기사를 따른다
  /// — 예고 뒤에 철회 기사가 나왔다면 철회.
  /// 날짜가 없는 기사는 같은 운영 주체·수단의 날짜 있는 사건이 하나뿐이면 그 사건에 합친다.
  /// 대표 기사는 가장 최근 기사이고, 날짜는 그룹 안에서 근거가 있는 날짜를 쓴다.
  static List<TransitStrike> merge(List<TransitStrike> strikes) {
    // 수단은 묶기 기준에서 뺀다: 같은 공항철도 기사를 모델이 rail/subway로 다르게 표기할 수 있다.
    String base(TransitStrike s) => s.operator.replaceAll(RegExp(r'\s|\(주\)|㈜|주식회사|노동조합|노조|지부'), '');
    String key(TransitStrike s) => '${base(s)}|${s.start == null ? '-' : _ymd(s.start!)}';

    final dated = <String, Set<String>>{};
    for (final s in strikes.where((s) => s.start != null)) {
      dated.putIfAbsent(base(s), () => {}).add(key(s));
    }
    final groups = <String, List<TransitStrike>>{};
    for (final s in strikes) {
      final candidates = dated[base(s)];
      final k = s.start == null && candidates != null && candidates.length == 1 ? candidates.single : key(s);
      groups.putIfAbsent(k, () => []).add(s);
    }
    return [
      for (final g in groups.values) _representative(g),
    ]..sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
  }

  /// 대표 기사: 가장 최근 기사의 상태를 따르되, 제목에 "파업"이 있는 기사를 우선한다
  /// (파업을 지나가듯 언급한 칼럼이 대표 링크가 되지 않게).
  static TransitStrike _representative(List<TransitStrike> group) {
    group.sort((a, b) => a.publishedAt.compareTo(b.publishedAt));
    final latestAny = group.last;
    final titled = group.where((s) => s.articleTitle.contains('파업')).toList();
    final latest = titled.isNotEmpty && titled.last.status == latestAny.status ? titled.last : latestAny;
    final withDate = group.lastWhere((s) => s.start != null, orElse: () => latest);
    return TransitStrike(
      id: latest.id,
      mode: latest.mode,
      operator: latest.operator,
      regions: latest.regions,
      status: latest.status,
      quote: latest.quote,
      start: withDate.start,
      end: withDate.end,
      dateQuote: withDate.dateQuote,
      articleTitle: latest.articleTitle,
      url: latest.url,
      publishedAt: latest.publishedAt,
      sourceCount: group.length,
      model: latest.model,
    );
  }

  static String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
