import 'dart:convert';
import '../models/models.dart';
import '../models/news_traffic.dart';
import '../models/transit_strike.dart';
import 'route_matcher.dart';

enum NewsTrafficDecision {
  ignore,
  needsReview,
  reference,
  caution,
  recommend,
  resolved,
}

class NewsTrafficEvaluation {
  const NewsTrafficEvaluation({
    required this.decision,
    required this.timeMatch,
    required this.spaceMatch,
    required this.modeMatch,
    required this.timeBasis,
    required this.reason,
    required this.planId,
    required this.scheduleVersion,
    required this.tripId,
    required this.tripVersion,
    required this.impact,
    required this.evaluatedAt,
  });
  final NewsTrafficDecision decision;
  final String timeMatch, spaceMatch, modeMatch, timeBasis, reason;
  final String planId, scheduleVersion, tripId, tripVersion;
  final NewsTrafficImpact impact;
  final DateTime evaluatedAt;
  static const ruleVersion = 'news-traffic-1.1';
  bool get visible => decision != NewsTrafficDecision.ignore;
  bool get notificationEligible => const [
    NewsTrafficDecision.caution,
    NewsTrafficDecision.recommend,
    NewsTrafficDecision.resolved,
  ].contains(decision);
  String get notificationKey =>
      jsonEncode([planId, impact.id, impact.version, decision.name]);
  Map<String, dynamic> toJson() => {
    'schedule_id': planId,
    'schedule_revision': scheduleVersion,
    'trip_id': tripId,
    'trip_revision': tripVersion,
    'impact_id': impact.id,
    'impact_version': impact.version,
    'event_id': impact.eventId,
    'decision': decision.name,
    'time_match': timeMatch,
    'space_match': spaceMatch,
    'mode_match': modeMatch,
    'time_basis': timeBasis,
    'reason_codes': [reason],
    'evidence_refs': impact.evidence,
    'rule_version': ruleVersion,
    'evaluated_at': evaluatedAt.toIso8601String(),
    'notification_eligible': notificationEligible,
  };
  Insight toInsight() {
    final text = switch (decision) {
      NewsTrafficDecision.resolved =>
        '기존 안내의 해당 영향이 해제되었거나 변경된 일정·이동과 무관해졌습니다.',
      NewsTrafficDecision.needsReview =>
        '날짜·범위·상태 또는 이동 정보가 부족하거나 충돌합니다. 최신 안내를 확인해 주세요.',
      NewsTrafficDecision.reference =>
        '조건부 예고 또는 같은 권역의 참고 정보입니다. 직접 이동 영향은 확정되지 않았습니다.',
      NewsTrafficDecision.caution =>
        '관련 교통 영향이 있으나 세부 시간·이동수단·구간 확인이 필요합니다. 출발 전 안내를 확인해 주세요.',
      NewsTrafficDecision.recommend =>
        '이용할 구간 또는 인근의 교통 영향이 이동 시간과 겹칩니다. 운행·통제 안내를 확인해 주세요.',
      NewsTrafficDecision.ignore => '개인 안내 대상이 아닙니다.',
    };
    final qualifier = impact.assertion == 'forecast'
        ? '출처의 혼잡 전망입니다. '
        : impact.assertion == 'planned'
        ? '예정된 영향입니다. '
        : '';
    return Insight(
      id: 'news-traffic:$planId:${impact.id}',
      kind: InsightKind.planAlert,
      planId: planId,
      notificationKey: notificationKey,
      notificationEligible: notificationEligible,
      title: LocalizedText(
        ko: '${impact.name} — ${decision == NewsTrafficDecision.resolved ? '기존 안내 해제' : '이동 안내'}',
        en: '${impact.name} — travel ${decision == NewsTrafficDecision.resolved ? 'update' : 'notice'}',
      ),
      body: LocalizedText(
        ko: '$qualifier$text',
        en: 'Travel status: ${decision.name}. Check the source for service details.',
      ),
      why: LocalizedText(
        ko: '본문 근거: “${impact.evidence.first['quote']}”',
        en: 'Source evidence: “${impact.evidence.first['quote']}”',
      ),
      confidence: decision == NewsTrafficDecision.recommend ? 0.85 : 0.55,
      signals: [
        Signal(SignalType.traffic, LocalizedText(ko: reason, en: reason)),
      ],
      sources: [SourceLink('뉴스·공개 공지 본문', impact.sourceUrl)],
    );
  }
}

/// Pure, no I/O. Mismatches take precedence over unknown/conditional fields.
class NewsTrafficMatcher {
  const NewsTrafficMatcher({this.nearbyKm = 1, this.candidateHours = 2});
  final double nearbyKm;
  final int candidateHours;

  NewsTrafficEvaluation evaluate(
    Plan plan,
    TripContext? trip,
    NewsTrafficImpact impact,
    DateTime now, {
    String? previousDecision,
  }) {
    final (time, basis) = matchTime(plan, trip, impact.period);
    final space = matchSpace(plan, trip, impact);
    final knownModes = trip?.modes ?? const <String>{};
    final mode = knownModes.isEmpty || impact.modes.isEmpty
        ? 'UNKNOWN'
        : knownModes.intersection(impact.modes).isNotEmpty
        ? 'APPLICABLE'
        : 'NOT_APPLICABLE';
    final hadNotice =
        previousDecision != null &&
        !['ignore', 'resolved'].contains(previousDecision);
    NewsTrafficDecision stop() =>
        hadNotice ? NewsTrafficDecision.resolved : NewsTrafficDecision.ignore;
    var decision = NewsTrafficDecision.needsReview;
    var reason = 'INSUFFICIENT_MATCH_DATA';
    if (impact.demo != (plan.source == 'sample')) {
      decision = NewsTrafficDecision.ignore;
      reason = 'DEMO_LIVE_SEPARATION';
    } else if (!impact.conflict &&
        ['WITHDRAWN', 'ENDED', 'NORMAL'].contains(impact.status)) {
      decision = stop();
      reason = 'IMPACT_RELEASED';
    } else if (plan.attendance == 'online' || !plan.start.isAfter(now)) {
      decision = stop();
      reason = 'SCHEDULE_INELIGIBLE';
    } else if (time == 'NO_MATCH' ||
        space == 'NO_MATCH' ||
        mode == 'NOT_APPLICABLE') {
      decision = stop();
      reason = 'NO_OVERLAP';
    } else if (impact.conflict ||
        impact.status == 'UNKNOWN' ||
        time == 'UNKNOWN' ||
        space == 'UNKNOWN') {
      reason = 'AMBIGUOUS_CORE_FIELDS';
    } else if (impact.status == 'CONDITIONAL') {
      decision = NewsTrafficDecision.reference;
      reason = 'CONDITION_UNCONFIRMED';
    } else if (space == 'REGION_ONLY') {
      decision = NewsTrafficDecision.reference;
      reason = 'REGION_ONLY';
    } else if (['DATE_MATCH', 'POSSIBLE_MATCH'].contains(time) ||
        mode == 'UNKNOWN' ||
        basis == 'CANDIDATE_WINDOW' ||
        space == 'SCOPE_UNCONFIRMED' ||
        (space == 'NEARBY' && knownModes.length > 1)) {
      decision = NewsTrafficDecision.caution;
      reason = 'TIME_MODE_OR_LEG_UNCERTAIN';
    } else {
      decision = NewsTrafficDecision.recommend;
      reason = 'RELEVANT_TRANSPORT_IMPACT';
    }
    // Normal service is scoped: it must cover the WHOLE saved trip (or passage)
    // and intersect verified facilities. Partial overlaps cannot erase a warning.
    if (!impact.conflict &&
        trip != null &&
        !['IGNORE', 'NO_MATCH'].contains(time)) {
      for (final ex in impact.exceptions) {
        if (ex['value'] != 'normal' || ex['assertion'] == 'unknown') continue;
        final scope = NewsTrafficImpact.maps(ex['scope']);
        final ids = {
          for (final s in scope)
            if (s['reference_id'] is String) s['reference_id'] as String,
        };
        final p = (ex['period'] as Map).cast<String, dynamic>();
        final start = _instant(p['start'] as Map),
            end = _instant(p['end'] as Map);
        final lo = _wall(trip.passageAt ?? trip.departure),
            hi = _wall(trip.passageAt ?? trip.arrival);
        if (ids.intersection(trip.facilityIds).isNotEmpty &&
            _facilityMatch(trip, scope) == 'ROUTE_MATCH' &&
            start != null &&
            end != null &&
            !lo.isBefore(start) &&
            (trip.passageAt != null ? hi.isBefore(end) : !hi.isAfter(end))) {
          decision = stop();
          reason = 'NORMAL_SERVICE_EXCEPTION';
        }
      }
    }
    return NewsTrafficEvaluation(
      decision: decision,
      timeMatch: time,
      timeBasis: basis,
      spaceMatch: space,
      modeMatch: mode,
      reason: reason,
      planId: plan.id,
      scheduleVersion:
          '${plan.start.toIso8601String()}:${plan.end.toIso8601String()}:${plan.locationText}:${plan.attendance}',
      tripId: trip?.id ?? '${plan.id}:trip',
      tripVersion: trip?.version ?? 'unknown',
      impact: impact,
      evaluatedAt: now,
    );
  }

  (String, String) matchTime(
    Plan plan,
    TripContext? trip,
    Map<String, dynamic> period,
  ) {
    if (trip?.timeConfirmed == false) trip = null;
    final basis = trip?.passageAt != null
        ? 'PASSAGE'
        : trip != null
        ? 'WHOLE_TRIP'
        : 'CANDIDATE_WINDOW';
    final lo = _wall(
      trip?.passageAt ??
          trip?.departure ??
          plan.start.subtract(Duration(hours: candidateHours)),
    );
    final hi = _wall(trip?.passageAt ?? trip?.arrival ?? plan.start);
    final a = period['start'] as Map, b = period['end'] as Map;
    final date = a['date'] as String?;
    if (date == null || hi.isBefore(lo)) return ('UNKNOWN', basis);
    final first = DateTime.parse(date),
        last = DateTime.parse((b['date'] as String?) ?? date);
    final lowDay = DateTime(lo.year, lo.month, lo.day),
        highDay = DateTime(hi.year, hi.month, hi.day);
    if (highDay.isBefore(first) ||
        (b['open_ended'] != true && lowDay.isAfter(last))) {
      return ('NO_MATCH', basis);
    }
    final start = _instant(a), end = _instant(b);
    if (start == null) return ('DATE_MATCH', basis);
    if (hi.isBefore(start) ||
        (hi == start && basis != 'PASSAGE') ||
        (end != null && !lo.isBefore(end))) {
      return ('NO_MATCH', basis);
    }
    if (end == null) return ('POSSIBLE_MATCH', basis);
    return (
      basis == 'CANDIDATE_WINDOW' ? 'WINDOW_MATCH' : 'EXACT_MATCH',
      basis,
    );
  }

  String matchSpace(Plan plan, TripContext? trip, NewsTrafficImpact impact) {
    if (trip != null &&
        impact.facilityIds.isNotEmpty &&
        trip.facilityIds.isNotEmpty) {
      if (impact.facilityIds.intersection(trip.facilityIds).isNotEmpty) {
        return _facilityMatch(trip, impact.scope);
      }
      if ([
        'STRIKE',
        'BUS_DETOUR',
        'STOP_SKIP',
        'STATION_RESTRICTION',
      ].contains(impact.type)) {
        return 'NO_MATCH';
      }
    }
    final point = impact.verifiedPoint;
    if (point != null &&
        plan.location != null &&
        RouteMatcher.haversineKm(point, plan.location!) <= nearbyKm) {
      return 'NEARBY';
    }
    // A provider polyline supplies proximity only, never a verified road/line ID.
    if (point != null &&
        trip != null &&
        trip.points.length > 1 &&
        RouteMatcher.distanceToPolylineKm(point, trip.points) <= nearbyKm) {
      return 'NEARBY';
    }
    if (impact.regions.isNotEmpty && plan.location != null) {
      return KoreaRegions.covers(impact.regions.toList(), plan.location!)
          ? 'REGION_ONLY'
          : 'NO_MATCH';
    }
    return 'UNKNOWN';
  }

  static String _facilityMatch(
    TripContext trip,
    List<Map<String, dynamic>> scope,
  ) {
    var uncertain = false;
    for (final item in scope) {
      if (!trip.facilityIds.contains(item['reference_id'])) continue;
      var mismatch = false, unknown = false;
      for (final pair in [
        (item['direction'], trip.direction),
        (item['section'], trip.section),
      ]) {
        if (pair.$1 == null) continue;
        if (pair.$2 == null) {
          unknown = true;
        } else if (pair.$1 != pair.$2) {
          mismatch = true;
        }
      }
      if (mismatch) continue;
      if (!unknown) return 'ROUTE_MATCH';
      uncertain = true;
    }
    return uncertain ? 'SCOPE_UNCONFIRMED' : 'NO_MATCH';
  }

  static DateTime _wall(DateTime value) {
    final t = value.isUtc ? value.add(const Duration(hours: 9)) : value;
    return DateTime(t.year, t.month, t.day, t.hour, t.minute, t.second);
  }

  static DateTime? _instant(Map time) =>
      time['date'] != null && time['time'] != null
      ? DateTime.tryParse('${time['date']}T${time['time']}')
      : null;
}
