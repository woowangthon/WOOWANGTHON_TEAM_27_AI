import '../models/models.dart';
import '../models/traffic.dart';
import 'route_matcher.dart';

/// 공식 교통 영향 × 사용자 일정 → 판정.
///
/// 「집회·마라톤·축제 뉴스의 이동 영향 판별 로직」 문서(§6~§9)의 단순화 구현:
/// - 시간: `[start, end)` 반열린 구간; 이동 기록이 없으면 일정 시작 전
///   [windowHours]시간 (WINDOW_MATCH), 종일 일정은 날짜만 (DATE_MATCH);
/// - 공간: 공지된 위치에서 [nearbyKm] km 이내 (NEARBY), 아니면 NO_MATCH;
/// - 이동수단: 일정에 저장되지 않음 → UNKNOWN, 그래서 최고 결과는 CAUTION.
///   RECOMMEND는 이동수단을 알 때만 (예: 경로 기능의 자동차 경로) — 다음 단계.
/// 같은 입력 → 같은 결과 (외부 호출 없음). "아무것도 추정하지 않는다".
enum TimeMatch { exact, window, date, possible, none, unknown }

enum SpaceMatch { nearby, none, unknown }

enum TrafficDecision { recommend, caution, reference, needsReview, ignore }

class TrafficMatch {
  const TrafficMatch(this.decision, this.time, this.space, this.distanceKm, this.reasons);
  final TrafficDecision decision;
  final TimeMatch time;
  final SpaceMatch space;
  final double? distanceKm;
  final List<String> reasons;
}

class TrafficMatcher {
  const TrafficMatcher({this.windowHours = 2, this.nearbyKm = 1});

  /// 이동 기록이 없을 때의 탐지 구간 (문서: "일정 시작 - 2시간"). 권고가 아니며
  /// "2시간 일찍 출발하세요"로 표시하지 않는다.
  final int windowHours;

  /// "근처" 기준 — 탐지 설정이며 혼잡 확산 반경이 아니다.
  final double nearbyKm;

  static const ruleVersion = '1.0';

  TrafficMatch evaluate(Plan plan, TrafficNotice n, DateTime now) {
    // 문서 §9 2행: 일정이 이미 시작되었으면 새 사전 경고 없음.
    if (!plan.start.isAfter(now)) {
      return const TrafficMatch(TrafficDecision.ignore, TimeMatch.none, SpaceMatch.unknown, null, ['SCHEDULE_INELIGIBLE']);
    }
    final time = matchTime(plan, n);
    final (space, km) = matchSpace(plan, n);
    if (time == TimeMatch.none || space == SpaceMatch.none) {
      return TrafficMatch(TrafficDecision.ignore, time, space, km, const ['NO_OVERLAP']);
    }
    if (time == TimeMatch.unknown || space == SpaceMatch.unknown) {
      return TrafficMatch(TrafficDecision.needsReview, time, space, km, const ['INSUFFICIENT_MATCH_DATA']);
    }
    // 이동수단 미확인 → CAUTION (문서 §9 9행). "지연 확정"이라고 말하지 않는다.
    return TrafficMatch(
      TrafficDecision.caution,
      time,
      space,
      km,
      [
        time == TimeMatch.window ? 'WINDOW_MATCH' : time == TimeMatch.date ? 'DATE_MATCH' : 'POSSIBLE_MATCH',
        'NEARBY',
        'MODE_UNKNOWN',
      ],
    );
  }

  TimeMatch matchTime(Plan plan, TrafficNotice n) {
    if (plan.isAllDay) {
      // 날짜만: 일정 날짜 중 하나가 영향 날짜와 겹치는지.
      final days = <DateTime>[];
      for (var d = _day(plan.start); d.isBefore(plan.end); d = DateTime(d.year, d.month, d.day + 1)) {
        days.add(d);
      }
      return days.any((d) => _coversDay(n, d)) ? TimeMatch.date : TimeMatch.none;
    }
    final windowStart = plan.start.subtract(Duration(hours: windowHours));
    final windowEnd = plan.start;
    final end = n.end;
    if (end == null) {
      // 종료 미상: 무기한 활성화하지 않는다 — 시작 날짜에만, 시작된 경우에만.
      if (_day(n.start) != _day(windowStart) && _day(n.start) != _day(windowEnd)) return TimeMatch.none;
      return n.start.isBefore(windowEnd) ? TimeMatch.possible : TimeMatch.none;
    }
    return overlaps(windowStart, windowEnd, n.start, end) ? TimeMatch.window : TimeMatch.none;
  }

  (SpaceMatch, double?) matchSpace(Plan plan, TrafficNotice n) {
    final at = plan.location;
    if (at == null) return (SpaceMatch.unknown, null);
    final km = RouteMatcher.haversineKm(at, n.location);
    return (km <= nearbyKm ? SpaceMatch.nearby : SpaceMatch.none, km);
  }

  /// 반열린 구간: 경계가 맞닿는 것은 겹침이 아니다.
  static bool overlaps(DateTime aStart, DateTime aEnd, DateTime bStart, DateTime bEnd) =>
      (aStart.isAfter(bStart) ? aStart : bStart).isBefore(aEnd.isBefore(bEnd) ? aEnd : bEnd);

  static bool _coversDay(TrafficNotice n, DateTime day) {
    final next = DateTime(day.year, day.month, day.day + 1);
    final end = n.end;
    if (end == null) return _day(n.start) == day;
    return overlaps(day, next, n.start, end);
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
}
