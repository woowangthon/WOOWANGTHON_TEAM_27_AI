// 자기소개 → 상황·관심사 제안의 실측 평가 (실제 Gemini).
//
//   GEMINI_API_KEY=... dart run tool/eval_profile_extractor.dart
//
// 소개글마다 모델 제안, 코드 검증에서 버린 것, 기대와 다른 점(오답·누락)을 출력한다.
// 부정 표현("운동은 싫어요")처럼 인용 검증만으로는 못 거르는 경우도 일부러 넣었다.
import 'dart:io';

import 'package:liferadar_core/liferadar_core.dart';

/// 앱(FE)의 관심사 목록과 같은 태그.
const allowed = {
  'ai': 'AI',
  'developer': 'software development',
  'data': 'data',
  'startup': 'startups',
  'design': 'design',
  'career': 'careers & jobs',
  'student': 'student programs',
  'networking': 'networking',
  'finance': 'money & investing',
  'language': 'foreign languages',
  'books': 'books & talks',
  'music': 'music & concerts',
  'culture': 'culture & festivals',
  'art': 'art & exhibitions',
  'movie': 'movies',
  'photo': 'photography',
  'gaming': 'gaming & esports',
  'sports': 'watching sports',
  'fitness': 'fitness & running',
  'outdoor': 'hiking & camping',
  'travel': 'travel',
  'food': 'food & drinks',
  'family': 'family & kids',
  'pets': 'pets',
  'fashion': 'fashion & beauty',
  'volunteer': 'volunteering',
};

/// (소개글, 기대 상황, 기대 태그)
const cases = <(String, LifeStage?, Set<String>)>[
  ('컴퓨터공학과 3학년이에요. 요즘 AI랑 데이터 분석 공부하고 있고, 해커톤 나가보고 싶어요.', LifeStage.student, {'ai', 'data', 'developer'}),
  ('마케팅 회사 5년 차 직장인입니다. 퇴근 후엔 러닝하고 주말엔 전시회 다녀요. 재테크에도 관심 많아요.', LifeStage.employee, {'fitness', 'art', 'finance'}),
  ('졸업하고 프론트엔드 개발자로 취업 준비 중이에요. 네트워킹 행사나 채용 설명회 정보가 필요해요.', LifeStage.jobSeeker, {'developer', 'career', 'networking'}),
  ('반려견 키우는 프리랜서 디자이너예요. 운동은 별로 안 좋아하고, 카페랑 맛집 탐방이 취미예요.', LifeStage.freelancer, {'pets', 'design', 'food'}),
  (
    'I run a small startup in Seoul. Looking for investor meetups and government startup programs. I also love jazz.',
    LifeStage.founder,
    {'startup', 'networking', 'music'},
  ),
  (
    "Doing a master's degree in Korea. Learning Korean these days, and I like traveling and watching football.",
    LifeStage.student,
    {'language', 'travel', 'sports'},
  ),
  ('그냥 주말에 뭐 할지 추천 받고 싶어요.', null, <String>{}),
];

Future<void> main() async {
  final client = GeminiClient(apiKey: Platform.environment['GEMINI_API_KEY']!);
  var stageOk = 0, tp = 0, fp = 0, fn = 0, dropped = 0;
  for (final (text, stage, expected) in cases) {
    final rejected = <String>[];
    final sw = Stopwatch()..start();
    final s = await ProfileExtractor.extract(client, text, allowedTags: allowed, rejected: rejected);
    final got = s.tags.map((t) => t.tag).toSet();
    if (s.stage == stage) stageOk++;
    tp += got.intersection(expected).length;
    fp += got.difference(expected).length;
    fn += expected.difference(got).length;
    dropped += rejected.length;
    stdout.writeln('「$text」');
    stdout.writeln('  ${s.model} · ${sw.elapsedMilliseconds} ms');
    stdout.writeln(
      '  상황: ${s.stage?.name ?? '-'} ${s.stage == stage ? '✓' : '✗ (기대 ${stage?.name ?? '-'})'}'
      '${s.stageQuote == null ? '' : '  "${s.stageQuote}"'}',
    );
    for (final t in s.tags) {
      stdout.writeln('  ${expected.contains(t.tag) ? '✓' : '?'} ${t.tag.padRight(10)} "${t.quote}"');
    }
    for (final m in expected.difference(got)) {
      stdout.writeln('  - 누락 $m');
    }
    for (final r in rejected) {
      stdout.writeln('  [검증 제외] $r');
    }
    stdout.writeln();
  }
  stdout.writeln('상황 $stageOk/${cases.length} · 태그 일치 $tp · 기대 밖 $fp · 누락 $fn · 검증에서 버림 $dropped');
}
