// 뉴스 파업 추출의 실측 평가 (실제 네이버 뉴스 검색 + 실제 Gemini).
//
//   NAVER_API_KEY_ID=... NAVER_API_KEY=... GEMINI_API_KEY=... dart run tool/eval_strike_extractor.dart
//
// 기사마다 모델의 판단(관련성·상태·날짜·지역)과 코드 검증 결과(통과/거부 이유)를 출력한다.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:liferadar_core/liferadar_core.dart';

Future<void> main() async {
  final env = Platform.environment;
  final articles = <String, NewsArticle>{};
  for (final q in ['버스 파업', '지하철 파업', '철도 파업']) {
    final res = await http.get(
      Uri.parse('https://naverapihub.apigw.ntruss.com/search/v1/news').replace(
        queryParameters: {'query': q, 'display': '10', 'sort': 'date', 'format': 'json'},
      ),
      headers: {'X-NCP-APIGW-API-KEY-ID': env['NAVER_API_KEY_ID']!, 'X-NCP-APIGW-API-KEY': env['NAVER_API_KEY']!},
    );
    for (final item in (jsonDecode(utf8.decode(res.bodyBytes))['items'] as List)) {
      final a = NewsArticle.fromSearchItem((item as Map).cast<String, dynamic>());
      articles[a.id] = a;
    }
  }
  final sw = Stopwatch()..start();
  final (json, model) = await GeminiClient(apiKey: env['GEMINI_API_KEY']!)
      .generate(StrikeExtractor.requestBody([...articles.values]));
  final rejected = <String, String>{};
  final kept = StrikeExtractor.parseResponse(json, articlesById: articles, model: model, rejected: rejected);
  stdout.writeln('모델 $model · ${sw.elapsedMilliseconds} ms · 기사 ${articles.length}개 → 통과 ${kept.length}개\n');
  for (final s in kept) {
    stdout.writeln('[통과] ${s.status.name.padRight(10)} ${s.mode.name.padRight(6)} ${s.operator} ${s.regions} '
        'start=${s.start?.toIso8601String().substring(0, 10) ?? '-'}\n       "${s.quote}"\n       ${s.articleTitle}');
  }
  stdout.writeln();
  for (final e in rejected.entries) {
    stdout.writeln('[제외] ${e.value.padRight(28)} ${articles[e.key]!.title}');
  }
  final merged = StrikeExtractor.merge(kept);
  stdout.writeln('\n사건으로 묶기: ${kept.length}건 → ${merged.length}건');
  for (final s in merged) {
    stdout.writeln('  ${s.status.name.padRight(10)} ${s.operator} ${s.regions} ${s.start?.toIso8601String().substring(0, 10) ?? '-'} (기사 ${s.sourceCount}개)');
  }
}
