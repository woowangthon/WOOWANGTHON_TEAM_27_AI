import 'package:test/test.dart';
import 'package:liferadar_core/demo.dart';
import 'package:liferadar_core/liferadar_core.dart';

void main() {
  const engine = InsightEngine();
  final now = DateTime(2026, 11, 6, 10);

  List<Insight> run({Set<String> interests = const {'ai', 'startup'}, Map<String, DailyWeather> weather = const {}}) =>
      engine.build(plans: samplePlans, events: sampleEvents, interests: interests, now: now, weatherByPlanId: weather);

  test('부산 출장 + 아시아드 콘서트 → 혼잡 참고 카드가 맨 앞', () {
    final list = run();
    expect(list.first.id, 'crowd:plan-busan-trip:ev-busan-concert');
    expect(list.first.kind, InsightKind.planAlert);
    expect(list.first.planId, 'plan-busan-trip');
  });

  test('출장 기간의 벡스코 AI 엑스포 → 관심사에 맞는 기회', () {
    final list = run();
    final expo = list.where((i) => i.id == 'nearby:plan-busan-trip:ev-busan-ai-expo');
    expect(expo, hasLength(1));
    expect(expo.first.kind, InsightKind.opportunity);
    expect(expo.first.body.en, contains('BEXCO'));
  });

  test('관심사가 맞지 않으면 기회는 없다 (콘서트 참고 카드는 유지)', () {
    final list = run(interests: {'design'});
    expect(list.any((i) => i.id.startsWith('nearby:')), isFalse);
    expect(list.any((i) => i.id.startsWith('crowd:')), isTrue);
  });

  test('마감 14일 이내 → 마감 카드 (엑스포: 11월 18일, D-12)', () {
    final list = run();
    final d = list.firstWhere((i) => i.id == 'deadline:ev-busan-ai-expo');
    expect(d.title.ko, startsWith('신청 마감 D-12'));
  });

  test('비 예보 → 날씨 경고', () {
    final list = run(weather: {
      'plan-gangnam-meeting': DailyWeather(
        date: DateTime(2026, 11, 10),
        condition: 'Rain',
        type: 'RAIN',
        maxC: 9,
        minC: 4,
        rainChance: 90,
      ),
    });
    final rain = list.firstWhere((i) => i.id.startsWith('rain:plan-gangnam-meeting'));
    expect(rain.confidence, 0.9);
    expect(rain.kind, InsightKind.planAlert);
  });

  test('같은 행사가 여러 번 반복되지 않고 id가 고유하다', () {
    final list = run();
    final ids = list.map((i) => i.id).toList();
    expect(ids.toSet().length, ids.length);
    // AI 엑스포는 "nearby"로 나왔으므로 일반 "opportunity"로 다시 나오면 안 된다
    expect(ids, isNot(contains('opportunity:ev-busan-ai-expo')));
  });

  test('지난 일정은 무시한다', () {
    final list = engine.build(
      plans: samplePlans,
      events: sampleEvents,
      interests: {'ai'},
      now: DateTime(2026, 12, 30),
    );
    expect(list.where((i) => i.planId != null), isEmpty);
  });
}
