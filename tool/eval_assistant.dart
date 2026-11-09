// 앱 AI 비서의 실측 평가 — 실제 행사 데이터(BE의 events.json) + 시연 일정 + 실제 Gemini.
//
//   GEMINI_API_KEY=... dart run tool/eval_assistant.dart [--date=2026-11-11]
//
// 질문마다: 코드가 읽은 조건, 후보 수, AI 답, 추천 카드, 제안 행동, 검증에서 버린 것.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:liferadar_core/demo.dart';
import 'package:liferadar_core/liferadar_core.dart';

const questions = [
  '이번 주말에 서울에서 뭐 하지?',
  'Busan trip 때 갈 만한 곳 있어?',
  '마감 임박한 창업 공고 알려줘',
  '무료 전시 추천해 줘',
  '11월 20일 일정에 영향 줄 만한 거 있어?',
  'Any concerts this week?',
  '입장료 제일 싼 공연이 얼마야?',
];

Future<void> main(List<String> args) async {
  final date = args.where((a) => a.startsWith('--date=')).map((a) => DateTime.parse(a.substring(7))).firstOrNull;
  final now = date ?? DateTime.now();
  final res = await http.get(
    Uri.parse('https://raw.githubusercontent.com/woowangthon/WOOWANGTHON_TEAM_27_BE/data/events.json'),
  );
  final feed = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  final events = [
    for (final j in feed['events'] as List) RadarEvent.fromJson(j as Map<String, dynamic>),
    ...sampleEventsAt(now),
  ];
  final plans = samplePlansAt(now);
  const interests = {'ai', 'startup', 'music', 'art'};
  final client = GeminiClient(apiKey: Platform.environment['GEMINI_API_KEY']!);
  final history = <ChatTurn>[];

  var ok = 0, replaced = 0, dropped = 0;
  for (final question in questions) {
    final query = AssistantQuery.parse(question, now: now, plans: plans);
    final candidates = Assistant.retrieve(query, events: events, interests: interests, now: now);
    final ctx = Assistant.context(query: query, candidates: candidates, plans: plans, now: now, interests: interests);
    final rejected = <String>[];
    final sw = Stopwatch()..start();
    final r = await Assistant.ask(
      client,
      question: question,
      query: query,
      candidates: candidates,
      context: ctx,
      history: history,
      lang: RegExp('[가-힣]').hasMatch(question) ? 'ko' : 'en',
      rejected: rejected,
    );
    r.fromAi ? ok++ : replaced++;
    dropped += rejected.length;
    history
      ..add(ChatTurn(fromUser: true, text: question))
      ..add(ChatTurn(fromUser: false, text: r.text));
    final byId = {for (final e in candidates) e.id: e};
    stdout.writeln('Q: $question');
    stdout.writeln('   조건: ${query.describe()} ${query.categories.map((c) => c.name)} 후보 ${candidates.length}개');
    stdout.writeln('   ${r.model} · ${sw.elapsedMilliseconds} ms · ${r.fromAi ? 'AI 답' : '규칙 문장으로 대체'}');
    stdout.writeln('   A: ${r.text}');
    for (final id in r.eventIds) {
      stdout.writeln('   · ${byId[id]!.title.ko} (${byId[id]!.start.toIso8601String().substring(0, 10)})');
    }
    for (final a in r.actions) {
      stdout.writeln('   → 제안: ${a.type.wire} ${byId[a.eventId]!.title.ko}');
    }
    for (final x in rejected) {
      stdout.writeln('   [검증 제외] $x');
    }
    stdout.writeln();
  }
  stdout.writeln('AI 답 $ok · 규칙 문장 대체 $replaced · 검증에서 버림 $dropped');
}
