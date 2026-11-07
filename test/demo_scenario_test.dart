import 'package:test/test.dart';
import 'package:liferadar_core/demo.dart';
import 'package:liferadar_core/liferadar_core.dart';

void main() {
  test('데모 날짜: 11/14까지는 그대로, 이후 주 단위로 이동', () {
    expect(demoShift(DateTime(2026, 11, 7)), Duration.zero);
    expect(demoShift(DateTime(2026, 11, 14, 23)), Duration.zero); // 6일 전 — 아직 그대로
    expect(demoShift(DateTime(2026, 11, 15)), const Duration(days: 7));
    final jan = demoShift(DateTime(2027, 1, 15));
    expect(jan.inDays % 7, 0);
    final trip = samplePlansAt(DateTime(2027, 1, 15)).firstWhere((p) => p.id == 'plan-busan-trip');
    final lead = trip.start.difference(DateTime(2027, 1, 15)).inDays;
    expect(lead, inInclusiveRange(6, 12));
  });

  for (final now in [DateTime(2026, 11, 13, 9), DateTime(2027, 3, 2, 9)]) {
    test('demo hikoyasi ishlaydi ($now)', () {
      final events = sampleEventsAt(now);
      final plans = samplePlansAt(now);
      final ids = [
        for (final i in const InsightEngine().build(
          plans: plans,
          events: events,
          interests: {'ai', 'startup', 'music'},
          now: now,
        ))
          i.id,
      ];
      // 2단계: 부산 출장 + 대형 콘서트
      expect(ids, contains('crowd:plan-busan-trip:ev-busan-concert'));
      // 5단계: 세미나 신청 마감 임박 (알림은 2일 이내에 표시)
      expect(ids, contains('deadline:ev-daejeon-ai-seminar'));
    });
  }

  test('11/13에 세미나 마감 D-2 — 알림 기준에 해당', () {
    final seminar = sampleEventsAt(DateTime(2026, 11, 13)).firstWhere((e) => e.id == 'ev-daejeon-ai-seminar');
    expect(seminar.deadline!.difference(DateTime(2026, 11, 13)).inDays, 2);
  });
}
