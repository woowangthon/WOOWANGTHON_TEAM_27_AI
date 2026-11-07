// Gemini 카드 문장 작성의 실측 평가 (실제 API 호출).
//
//   GEMINI_API_KEY=... dart run tool/eval_insight_writer.dart [--date=2026-11-07]
//
// 시연 시나리오로 규칙 카드를 만들고, Gemini가 다시 쓴 문장이 근거 검증을 몇 개 통과하는지
// 카드별로 출력한다 (규칙 문장 ↔ AI 문장 비교). 무료 할당량을 아끼기 위해 요청은 1회.
import 'dart:convert';
import 'dart:io';

import 'package:liferadar_core/demo.dart';
import 'package:liferadar_core/liferadar_core.dart';

Future<void> main(List<String> args) async {
  final key = Platform.environment['GEMINI_API_KEY'] ?? '';
  if (key.isEmpty) {
    stderr.writeln('GEMINI_API_KEY 환경 변수가 필요합니다.');
    exit(64);
  }
  final dateArg = args.firstWhere((a) => a.startsWith('--date='), orElse: () => '--date=2026-11-07');
  final now = DateTime.parse(dateArg.substring(7));
  const interests = {'ai', 'startup', 'music', 'culture', 'food'};

  final events = sampleEventsAt(now);
  final plans = samplePlansAt(now);
  final cards = const InsightEngine().build(plans: plans, events: events, interests: interests, now: now);
  final facts = <String, Map<String, dynamic>>{
    for (final i in cards.where(InsightWriter.isEligible).take(6))
      i.id: InsightWriter.facts(
        i,
        plan: plans.where((p) => p.id == i.planId).firstOrNull,
        event: i.eventIds.isEmpty ? null : events.where((e) => e.id == i.eventIds.first).firstOrNull,
        interests: interests,
        today: DateTime(now.year, now.month, now.day),
      ),
  };

  final sw = Stopwatch()..start();
  final (json, model) = await GeminiClient(apiKey: key).generate(InsightWriter.requestBody([...facts.values]));
  final accepted = InsightWriter.parseResponse(json, factsById: facts, model: model);
  stdout.writeln('모델 $model · ${sw.elapsedMilliseconds} ms · 검증 통과 ${accepted.length}/${facts.length}\n');

  final raw = ((json['candidates'] as List).first as Map)['content']['parts'] as List;
  final items = jsonDecode(raw.map((p) => (p as Map)['text'] ?? '').join()) as List;
  for (final item in items.cast<Map<String, dynamic>>()) {
    final id = item['id'] as String;
    final ok = accepted.containsKey(id);
    stdout.writeln('[${ok ? '통과' : '거부'}] $id');
    stdout.writeln('  규칙 : ${cards.firstWhere((c) => c.id == id).why.ko}');
    stdout.writeln('  AI   : ${item['why_ko']}');
    stdout.writeln('  AI en: ${item['why_en']}\n');
  }
}
