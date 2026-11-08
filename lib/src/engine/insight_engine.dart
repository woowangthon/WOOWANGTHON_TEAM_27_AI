import '../models/models.dart';
import 'route_matcher.dart';
import '../models/traffic.dart';
import 'taste.dart';
import 'traffic_matcher.dart';

/// "Connect the dots" — 일정 × 행사 × 날씨 × 관심사 → 인사이트 카드.
///
/// 결정론적 (AI 아님): 모든 카드는 명확한 규칙에서 나오고 id가 안정적이어서
/// 다시 계산해도 사용자 피드백이 유지된다.
/// 이후 Gemini는 [Insight.body]/[Insight.why] 문장만 다듬는다 — 사실은 바꾸지 않는다.
class InsightEngine {
  const InsightEngine({
    this.nearbyKm = 15,
    this.deadlineWindowDays = 14,
    this.opportunityWindowDays = 45,
    this.maxGeneralOpportunities = 2,
    this.maxNearbyPerPlan = 2,
    this.crowdKmReal = 3,
    this.maxDeadlines = 3,
    this.maxTrafficPerPlan = 2,
  });

  /// 일정 장소에서 이 거리 이내의 행사를 "근처"로 본다.
  final double nearbyKm;

  /// 신청 마감이 이 기간 안이면 경고한다.
  final int deadlineWindowDays;

  /// 일정과 무관한 기회를 찾는 미래 범위.
  final int opportunityWindowDays;
  final int maxGeneralOpportunities;

  /// 일정 하나당 "근처" 기회 카드 수.
  final int maxNearbyPerPlan;

  /// 동시에 보여주는 마감 카드 수.
  final int maxDeadlines;

  /// 일정 하나당 교통 통제 카드 수. 같은 도로가 여러 구간으로 나뉘어 오므로(ITS)
  /// 제목이 같은 공지는 하나로 보고, 가까운 순으로 이만큼만 보여준다.
  final int maxTrafficPerPlan;

  /// 실제 행사의 "혼잡" 참고는 이 거리 이내에서만 (샘플은 규모가 알려져 있음).
  final double crowdKmReal;

  List<Insight> build({
    required List<Plan> plans,
    required List<RadarEvent> events,
    required Set<String> interests,
    required DateTime now,
    Map<String, DailyWeather> weatherByPlanId = const {},
    Taste taste = Taste.none,
    List<TrafficNotice> traffic = const [],
    TrafficMatcher trafficMatcher = const TrafficMatcher(),
  }) {
    // 관심사 적합도 + 피드백으로 학습한 취향 (👍 비슷한 것은 위로, 👎 아래로).
    double interestOf(RadarEvent e) => taste.score(e, interests);
    final today = DateTime(now.year, now.month, now.day);
    final out = <Insight>[];
    final usedEventIds = <String>{};

    for (final plan in plans) {
      if (plan.end.isBefore(today)) continue;
      final where = plan.locationText.isNotEmpty ? plan.locationText : plan.title;

      // 1) 일정 기간 + 근처 행사.
      // 실제 데이터에서는 한 지역에 행사가 수십 개 — 일정마다 가장 중요한 것만:
      // "혼잡" 참고 1개(가장 가까운 것) + 기회 [maxNearbyPerPlan]개(가장 잘 맞는 것).
      if (plan.location != null) {
        final crowdCandidates = <(RadarEvent, double)>[];
        final nearbyCandidates = <(RadarEvent, double, double)>[];
        for (final e in events) {
          if (e.placeless) continue; // 주소 없는 공고는 "근처"가 될 수 없다
          if (!_overlaps(plan.start, plan.end, e.start, e.end)) continue;
          final km = RouteMatcher.haversineKm(plan.location!, e.location);
          if (km > nearbyKm) continue;
          final interest = interestOf(e);
          if (_isCrowd(e, km)) {
            crowdCandidates.add((e, km));
          } else if (interest > 0) {
            nearbyCandidates.add((e, km, interest));
          }
        }
        crowdCandidates.sort((a, b) => a.$2.compareTo(b.$2));
        nearbyCandidates.sort((a, b) => b.$3 != a.$3 ? b.$3.compareTo(a.$3) : a.$2.compareTo(b.$2));

        for (final (e, km) in crowdCandidates.take(1)) {
          usedEventIds.add(e.id);
          out.add(
            Insight(
              id: 'crowd:${plan.id}:${e.id}',
              kind: InsightKind.planAlert,
              planId: plan.id,
              eventIds: [e.id],
              // "행사 개최 사실만으로 이동 영향 판정 금지" (판별 로직 D08/E01): 참고 수준 —
              // 교통 영향은 확인되지 않았으며 알림을 보내지 않는다 (앱의 알림 규칙).
              title: LocalizedText(
                ko: '${_dateKo(_on(e, plan.start))} $where 일정 — 근처 대형 행사',
                en: 'Large event near $where on ${_dateEn(_on(e, plan.start))}',
              ),
              body: LocalizedText(
                ko:
                    '같은 날 약 ${km.toStringAsFixed(1)} km 거리에서 "${e.title.ko}" 행사가 열립니다. '
                    '출발 전에 교통 통제나 혼잡 안내가 있는지 확인해 보세요.',
                en:
                    '"${e.title.en}" takes place about ${km.toStringAsFixed(1)} km away the same day. '
                    'Check for traffic or crowd notices before you go.',
              ),
              why: const LocalizedText(
                ko: '방문 일정과 같은 날 근처에서 대규모 행사가 열립니다. 공식 교통 영향 정보는 아직 확인되지 않았습니다.',
                en: 'A large event is happening near your plan that day. No official traffic impact has been confirmed yet.',
              ),
              confidence: _round(0.4 + 0.3 * (1 - km / nearbyKm)),
              signals: [
                Signal(SignalType.event, LocalizedText(ko: e.venue, en: e.venue)),
                const Signal(SignalType.traffic, LocalizedText(ko: '교통 영향 미확인', en: 'Traffic impact unconfirmed')),
              ],
              sources: [_source(e)],
            ),
          );
        }
        for (final (e, km, interest) in nearbyCandidates.take(maxNearbyPerPlan)) {
          usedEventIds.add(e.id);
          out.add(
            Insight(
              id: 'nearby:${plan.id}:${e.id}',
              kind: InsightKind.opportunity,
              planId: plan.id,
              eventIds: [e.id],
              title: LocalizedText(ko: '$where에 있는 동안: ${e.title.ko}', en: 'While you are at $where: ${e.title.en}'),
              body: LocalizedText(
                ko: '${_dateKo(_on(e, plan.start))} ${e.venue}에서 열립니다. 일정 장소에서 약 ${km.toStringAsFixed(1)} km.',
                en: 'On ${_dateEn(_on(e, plan.start))} at ${e.venue}, about ${km.toStringAsFixed(1)} km from your plan.',
              ),
              why: LocalizedText(
                ko: '관심사(${_tags(e, interests)})와 맞고, 이미 그 지역에 계실 예정입니다.',
                en: 'It matches your interests (${_tags(e, interests)}) and you will already be nearby.',
              ),
              confidence: _round(0.45 + 0.35 * interest + 0.2 * (1 - km / nearbyKm)),
              signals: [
                Signal(SignalType.event, LocalizedText(ko: e.venue, en: e.venue)),
                if (e.deadline != null && !e.deadline!.isBefore(today))
                  Signal(
                    SignalType.deadline,
                    LocalizedText(
                      ko: '신청 마감 ${_dateKo(e.deadline!)}',
                      en: 'Registration closes ${_dateEn(e.deadline!)}',
                    ),
                  ),
              ],
              sources: [_source(e)],
            ),
          );
        }
      }

      // 1b) 공식 교통 영향 (TOPIS·ITS) — 일정 장소 근처, 일정 시작 전. 문장은 템플릿: 사실은 출처에서,
      // Gemini가 다시 쓰지 않는다 (앱의 AI 문장 단계에서 제외). 이동수단 미확인 → CAUTION만.
      final trafficHits = <(TrafficNotice, TrafficMatch)>[
        for (final n in traffic)
          if (trafficMatcher.evaluate(plan, n, now) case final m when m.decision == TrafficDecision.caution) (n, m),
      ]..sort((a, b) => a.$2.distanceKm!.compareTo(b.$2.distanceKm!));
      final shownTitles = <String>{};
      for (final (n, m) in trafficHits) {
        if (shownTitles.length >= maxTrafficPerPlan) break;
        if (!shownTitles.add(n.title)) continue; // 같은 도로의 다른 구간
        out.add(_trafficCard(plan, where, n, m));
      }

      // 2) 일정 날의 비
      final w = weatherByPlanId[plan.id];
      if (w != null && w.likelyRain) {
        out.add(
          Insight(
            id: 'rain:${plan.id}:${_ymd(w.date)}',
            kind: InsightKind.planAlert,
            planId: plan.id,
            title: LocalizedText(
              ko: '${_dateKo(w.date)} $where — 비 예보',
              en: 'Rain expected at $where on ${_dateEn(w.date)}',
            ),
            body: LocalizedText(
              ko: '강수 확률 ${w.rainChance}%. 우산을 챙기고 야외 일정은 시간을 조정해 보세요.',
              en: '${w.rainChance}% chance of rain. Bring an umbrella and adjust outdoor plans.',
            ),
            why: const LocalizedText(
              ko: '일정 당일 해당 장소의 일별 예보에서 비 가능성이 높게 나타났습니다.',
              en: 'The daily forecast for your plan location shows a high chance of rain.',
            ),
            confidence: _round((w.rainChance ?? 60) / 100),
            signals: [
              Signal(
                SignalType.weather,
                LocalizedText(
                  ko: '${w.maxC ?? '-'}° / ${w.minC ?? '-'}° · ☔ ${w.rainChance}%',
                  en: '${w.maxC ?? '-'}° / ${w.minC ?? '-'}° · ☔ ${w.rainChance}%',
                ),
              ),
            ],
            sources: const [SourceLink('Google Weather', null)],
          ),
        );
      }
    }

    // 3) 관심사에 맞는 행사 — 신청 마감 임박.
    // 창업 공고는 수십 개 — 가장 잘 맞고, 그다음 가장 급한 [maxDeadlines]개.
    final deadlineCandidates = <(RadarEvent, int)>[];
    for (final e in events) {
      final d = e.deadline;
      if (d == null || interestOf(e) == 0) continue;
      final left = DateTime(d.year, d.month, d.day).difference(today).inDays;
      if (left < 0 || left > deadlineWindowDays) continue;
      deadlineCandidates.add((e, left));
    }
    deadlineCandidates.sort((a, b) {
      final byInterest = interestOf(b.$1).compareTo(interestOf(a.$1));
      return byInterest != 0 ? byInterest : a.$2.compareTo(b.$2);
    });
    for (final (e, left) in deadlineCandidates.take(maxDeadlines)) {
      final d = e.deadline!;
      out.add(
        Insight(
          id: 'deadline:${e.id}',
          kind: InsightKind.deadline,
          eventIds: [e.id],
          title: LocalizedText(
            ko: '${left == 0 ? '오늘 신청 마감' : '신청 마감 D-$left'}: ${e.title.ko}',
            en:
                '${switch (left) {
                  0 => 'Registration closes today',
                  1 => 'Registration closes tomorrow',
                  _ => 'Registration closes in $left days',
                }}: ${e.title.en}',
          ),
          body: e.placeless
              ? LocalizedText(
                  ko: '${e.venue.isEmpty ? '' : '${e.venue} · '}${e.city} 공고의 접수가 ${_dateKo(d)}에 마감됩니다.',
                  en:
                      'Applications for this ${e.city} program${e.venue.isEmpty ? '' : ' by ${e.venue}'} '
                      'close on ${_dateEn(d)}.',
                )
              : LocalizedText(
                  ko: '${_dateKo(e.start)} ${e.city}에서 열리는 행사의 신청이 ${_dateKo(d)}에 마감됩니다.',
                  en: 'Registration for this ${_dateEn(e.start)} event in ${e.city} closes on ${_dateEn(d)}.',
                ),
          why: LocalizedText(
            ko: '관심사(${_tags(e, interests)})와 맞는 행사이며, 마감을 놓치면 참가할 수 없습니다.',
            en: 'It matches your interests (${_tags(e, interests)}); missing the deadline means missing it.',
          ),
          confidence: _round(0.5 + 0.4 * interestOf(e)),
          signals: [
            Signal(
              SignalType.deadline,
              LocalizedText(
                ko: left == 0 ? 'D-DAY' : 'D-$left',
                en: switch (left) {
                  0 => 'Today',
                  1 => '1 day left',
                  _ => '$left days left',
                },
              ),
            ),
            Signal(SignalType.event, LocalizedText(ko: e.venue, en: e.venue)),
          ],
          sources: [_source(e)],
        ),
      );
      usedEventIds.add(e.id);
    }

    // 4) 일정과 무관하게 관심사에 가장 잘 맞는 가까운 시기의 행사
    final horizon = today.add(Duration(days: opportunityWindowDays));
    final general =
        events
            .where((e) => !usedEventIds.contains(e.id))
            .where((e) => !e.end.isBefore(today) && e.start.isBefore(horizon))
            .where((e) => interestOf(e) > 0)
            .toList()
          ..sort((a, b) {
            final s = interestOf(b).compareTo(interestOf(a));
            return s != 0 ? s : a.start.compareTo(b.start);
          });
    for (final e in general.take(maxGeneralOpportunities)) {
      out.add(
        Insight(
          id: 'opportunity:${e.id}',
          kind: InsightKind.opportunity,
          eventIds: [e.id],
          title: LocalizedText(ko: '새로운 기회: ${e.title.ko}', en: 'New opportunity: ${e.title.en}'),
          body: LocalizedText(
            ko: '${_dateKo(_on(e, today))} ${e.city} ${e.venue}에서 열립니다.',
            en: '${_dateEn(_on(e, today))} at ${e.venue}, ${e.city}.',
          ),
          why: LocalizedText(
            ko: '관심사(${_tags(e, interests)})와 일치합니다.',
            en: 'Matches your interests (${_tags(e, interests)}).',
          ),
          confidence: _round(0.4 + 0.4 * interestOf(e)),
          signals: [Signal(SignalType.event, LocalizedText(ko: e.venue, en: e.venue))],
          sources: [_source(e)],
        ),
      );
    }

    return rank(out);
  }

  Insight _trafficCard(Plan plan, String where, TrafficNotice n, TrafficMatch m) {
    final (whatKo, whatEn) = switch (n.kind) {
      TrafficKind.rally => ('집회', 'a rally'),
      TrafficKind.event => ('행사', 'an event'),
      TrafficKind.drill => ('훈련', 'a drill'),
      TrafficKind.construction => ('공사', 'construction'),
      TrafficKind.weather => ('기상', 'weather'),
      TrafficKind.other => ('돌발 상황', 'an incident'),
    };
    String hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final end = n.end;
    final periodKo = '${_dateKo(n.start)} ${hm(n.start)} ~ ${end == null ? '종료 시각 미확인' : '${_dateKo(end)} ${hm(end)}'}';
    final periodEn = '${_dateEn(n.start)} ${hm(n.start)} – ${end == null ? 'end time not announced' : '${_dateEn(end)} ${hm(end)}'}';
    final km = m.distanceKm!.toStringAsFixed(1);
    final whenKo = switch (m.time) {
      TimeMatch.window => '일정 시작 전 시간대에',
      TimeMatch.date => '일정 날짜에',
      _ => '일정 날짜에 (시간 확인 필요)',
    };
    final whenEn = switch (m.time) {
      TimeMatch.window => 'in the hours before your plan starts',
      TimeMatch.date => 'on your plan day',
      _ => 'on your plan day (check the time)',
    };
    return Insight(
      id: 'traffic:${plan.id}:${n.id}',
      kind: InsightKind.planAlert,
      planId: plan.id,
      title: LocalizedText(ko: '$where 인근 $whatKo 통제', en: 'Road control near $where ($whatEn)'),
      // 판별 로직 §12 "이동수단 미확인" 문구 — 지연·통행 불가를 단정하지 않는다.
      body: LocalizedText(
        ko: '$whenKo 일정 장소 인근(약 $km km)에 도로 통제가 예고되어 있습니다. '
            '이용하실 교통수단과 접근 경로에 영향이 있는지 확인해 주세요.',
        en: 'A road control is announced about $km km from your plan $whenEn. '
            'Check whether it affects how you plan to get there.',
      ),
      why: LocalizedText(
        ko: '${n.sourceName} 공식 정보: "${n.title}" ($periodKo)',
        en: 'Official notice from ${n.sourceName}: "${n.title}" ($periodEn)',
      ),
      confidence: m.time == TimeMatch.window ? 0.7 : 0.55,
      signals: [
        Signal(SignalType.traffic, LocalizedText(ko: periodKo, en: periodEn)),
        Signal(SignalType.event, LocalizedText(ko: n.title, en: n.title)),
      ],
      sources: [SourceLink(n.sourceName, n.sourceUrl)],
    );
  }

  /// 일정 관련 경고와 마감을 먼저, 이후 신뢰도 순.
  static List<Insight> rank(List<Insight> list) {
    int priority(InsightKind k) => switch (k) {
      InsightKind.planAlert => 0,
      InsightKind.deadline => 1,
      InsightKind.opportunity => 2,
      InsightKind.route => 3,
    };
    return [...list]..sort((a, b) {
      final p = priority(a.kind).compareTo(priority(b.kind));
      return p != 0 ? p : b.confidence.compareTo(a.confidence);
    });
  }

  /// 사람이 몰리는 행사: 짧은 행사 (≤ 3일; 몇 달씩 하는 전시·스케이트장이 아님).
  /// 샘플은 규모가 알려져 있다 (경기장 콘서트). 실제 데이터에는 수용 인원이 없으므로
  /// 작은 공연장의 공연은 혼잡이 아니다 — 그래서 가까운 축제만.
  bool _isCrowd(RadarEvent e, double km) {
    if (e.end.difference(e.start).inDays > 3) return false;
    if (e.isSample) return e.category == EventCategory.concert || e.category == EventCategory.festival;
    return e.category == EventCategory.festival && km <= crowdKmReal;
  }

  /// 행사가 이미 시작되었다면 (몇 달씩 하는 전시) [from] 날짜,
  /// 아니면 행사 시작일. "5월 1일"처럼 지난 날짜가 나오지 않게 한다.
  static DateTime _on(RadarEvent e, DateTime from) {
    final day = DateTime(from.year, from.month, from.day);
    return e.start.isBefore(day) ? day : e.start;
  }

  static bool _overlaps(DateTime aStart, DateTime aEnd, DateTime bStart, DateTime bEnd) {
    final a0 = DateTime(aStart.year, aStart.month, aStart.day);
    final a1 = DateTime(aEnd.year, aEnd.month, aEnd.day, 23, 59);
    return !bEnd.isBefore(a0) && !bStart.isAfter(a1);
  }

  static String _tags(RadarEvent e, Set<String> interests) =>
      e.tags.where(interests.contains).map((t) => '#$t').join(' ');

  static SourceLink _source(RadarEvent e) =>
      SourceLink(e.isSample ? 'Sample data' : (e.sourceName ?? e.source), e.url ?? e.registerUrl);

  static double _round(double v) => (v.clamp(0.0, 0.99) * 100).round() / 100;

  static const _monthsEn = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static String _dateKo(DateTime d) => '${d.month}월 ${d.day}일';
  static String _dateEn(DateTime d) => '${_monthsEn[d.month - 1]} ${d.day}';
  static String _ymd(DateTime d) => '${d.year}-${d.month}-${d.day}';
}
