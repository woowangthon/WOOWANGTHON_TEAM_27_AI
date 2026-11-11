// Runs without Flutter, API keys or network calls (dart pub get once first).
import 'dart:convert';
import 'dart:io';
import 'package:liferadar_core/src/models/models.dart';
import 'package:liferadar_core/src/models/news_traffic.dart';
import 'package:liferadar_core/src/models/traffic.dart';
import 'package:liferadar_core/src/models/transit_strike.dart';
import 'package:liferadar_core/src/engine/news_traffic_matcher.dart';
import 'package:liferadar_core/src/engine/traffic_matcher.dart';
import 'package:liferadar_core/src/engine/insight_engine.dart';

int passed = 0;
void check(String name, bool condition) {
  if (!condition) throw StateError('FAIL: $name');
  passed++;
}

void main(List<String> args) {
  const matcher = NewsTrafficMatcher();
  final now = DateTime(2026, 11, 7);
  final reference = TrafficReference.fromJson({
    'id': 'fixture:101',
    'raw': '101번 버스',
    'region': '서울',
    'mode': 'bus',
    'source': 'synthetic test reference v1',
    'as_of': '2026-11-07',
    'valid_until': '2026-11-30',
    'aliases': ['101'],
  });
  Set<String> resolve(
    String region, {
    DateTime? at,
    List<TrafficReference>? refs,
  }) => resolveTripFacilityIds(
    lines: ['101'],
    modes: {'bus'},
    region: region,
    departure: at ?? DateTime(2026, 11, 10),
    demo: false,
    references: refs ?? [reference],
  );
  check(
    'verified provider alias mapping',
    resolve('서울').contains('fixture:101'),
  );
  check('same bus number in another city cannot match', resolve('부산').isEmpty);
  check(
    'expired reference cannot match',
    resolve('서울', at: DateTime(2026, 12, 1)).isEmpty,
  );
  check(
    'ambiguous reference cannot match',
    resolve('서울', refs: [reference, reference]).isEmpty,
  );
  final plan = Plan(
    id: 'p',
    title: '미팅',
    start: DateTime(2026, 11, 10, 10),
    end: DateTime(2026, 11, 10, 11),
    locationText: '서울시청',
    city: '서울',
    location: const GeoPoint(37.5663, 126.9779),
  );
  TripContext trip({
    Set<String> modes = const {'bus'},
    int hour = 9,
    Set<String> ids = const {'demo:seoul:bus:101'},
    String? direction,
  }) => TripContext(
    id: 'trip',
    version: '1',
    departure: DateTime(2026, 11, 10, hour),
    arrival: DateTime(2026, 11, 10, hour, 40),
    modes: modes,
    facilityIds: ids,
    direction: direction,
  );
  Map<String, dynamic> time(String? date, String? value) => {
    'raw': null,
    'date': date,
    'time': value,
    'timezone': 'Asia/Seoul',
    'basis': 'explicit',
    'assertion': 'planned',
    'open_ended': null,
  };
  final raw = <String, dynamic>{
    'id': 'i',
    'event_id': 'e',
    'version': 1,
    'type': 'STRIKE',
    'status': 'ANNOUNCED',
    'assertion': 'planned',
    'event_name': '서울 버스 파업',
    'source_url': 'https://example.com/fixture',
    'body_verified': true,
    'demo': true,
    'conflict': false,
    'period': {
      'start': time('2026-11-10', '08:00'),
      'end': time('2026-11-10', '11:00'),
    },
    'scope': [
      {'region': '서울', 'reference_id': 'demo:seoul:bus:101', 'raw': '101번 버스'},
    ],
    'modes': ['bus'],
    'exceptions': [],
    'evidence': [
      {'quote': '서울 101번 버스 파업 예고'},
    ],
  };
  NewsTrafficImpact impact([Map<String, dynamic> changes = const {}]) =>
      NewsTrafficImpact.fromJson({...raw, ...changes});
  NewsTrafficEvaluation evaluate({
    TripContext? route,
    Map<String, dynamic> changes = const {},
    Plan? schedule,
    String? previous,
  }) => matcher.evaluate(
    schedule ?? plan,
    route,
    impact(changes),
    now,
    previousDecision: previous,
  );
  check(
    'E28 route + time + mode',
    evaluate(route: trip()).decision == NewsTrafficDecision.recommend,
  );
  final directedScope = [
    {'region': '서울', 'reference_id': 'demo:seoul:bus:101', 'direction': '상행'},
  ];
  check(
    'unknown direction cannot become direct recommendation',
    evaluate(route: trip(), changes: {'scope': directedScope}).decision ==
        NewsTrafficDecision.caution,
  );
  check(
    'opposite direction is unrelated',
    evaluate(
          route: trip(direction: '하행'),
          changes: {'scope': directedScope},
        ).decision ==
        NewsTrafficDecision.ignore,
  );
  check(
    'E29 exact time mismatch',
    evaluate(route: trip(hour: 12)).decision == NewsTrafficDecision.ignore,
  );
  check(
    'E30 road-only mode mismatch beats unknown date',
    evaluate(
          route: trip(modes: {'subway'}),
          changes: {
            'type': 'ROAD_CLOSURE',
            'modes': ['car', 'bus'],
            'period': {'start': time(null, null), 'end': time(null, null)},
          },
        ).decision ==
        NewsTrafficDecision.ignore,
  );
  check(
    'E31 end boundary is exclusive',
    evaluate(route: trip(hour: 11)).decision == NewsTrafficDecision.ignore,
  );
  check(
    'same region is reference only',
    evaluate().decision == NewsTrafficDecision.reference,
  );
  check('reference never notifies', !evaluate().notificationEligible);
  check(
    'conditional never promotes',
    evaluate(route: trip(), changes: {'status': 'CONDITIONAL'}).decision ==
        NewsTrafficDecision.reference,
  );
  check(
    'unknown mode stays caution',
    evaluate(route: trip(modes: {})).decision == NewsTrafficDecision.caution,
  );
  check(
    'different verified bus ID ignored',
    evaluate(route: trip(ids: {'demo:other'})).decision ==
        NewsTrafficDecision.ignore,
  );
  check(
    'withdrawal resolves same pair',
    evaluate(
          route: trip(),
          changes: {'status': 'WITHDRAWN'},
          previous: 'recommend',
        ).decision ==
        NewsTrafficDecision.resolved,
  );
  check(
    'withdrawal alone creates no new warning',
    evaluate(route: trip(), changes: {'status': 'WITHDRAWN'}).decision ==
        NewsTrafficDecision.ignore,
  );
  check(
    'conflict is review',
    evaluate(route: trip(), changes: {'conflict': true}).decision ==
        NewsTrafficDecision.needsReview,
  );
  check(
    'review never notifies',
    !evaluate(route: trip(), changes: {'conflict': true}).notificationEligible,
  );
  check(
    'online schedule ignored',
    evaluate(
          route: trip(),
          schedule: plan.copyWith(attendance: 'online'),
        ).decision ==
        NewsTrafficDecision.ignore,
  );
  check(
    'already started ignored',
    matcher.evaluate(plan, trip(), impact(), plan.start).decision ==
        NewsTrafficDecision.ignore,
  );
  check(
    'demo cannot affect live schedule',
    evaluate(
          route: trip(),
          schedule: plan.copyWith(source: 'local'),
        ).decision ==
        NewsTrafficDecision.ignore,
  );
  final range = {
    'start': time('2026-11-09', null),
    'end': time('2026-11-13', null),
  };
  check(
    'multi-day date-only period includes later day',
    evaluate(route: trip(), changes: {'period': range}).decision ==
        NewsTrafficDecision.caution,
  );
  check(
    'unknown dates review',
    evaluate(
          route: trip(),
          changes: {
            'period': {'start': time(null, null), 'end': time(null, null)},
          },
        ).decision ==
        NewsTrafficDecision.needsReview,
  );
  final fullNormal = {
    'value': 'normal',
    'assertion': 'planned',
    'scope': raw['scope'],
    'period': {
      'start': time('2026-11-10', '09:00'),
      'end': time('2026-11-10', '10:00'),
    },
  };
  check(
    'normal exception covers entire trip',
    evaluate(
          route: trip(),
          changes: {
            'exceptions': [fullNormal],
          },
        ).decision ==
        NewsTrafficDecision.ignore,
  );
  check(
    'partial normal exception does not erase disruption',
    evaluate(
          route: trip(),
          changes: {
            'exceptions': [
              {
                ...fullNormal,
                'period': {
                  'start': time('2026-11-10', '09:00'),
                  'end': time('2026-11-10', '09:15'),
                },
              },
            ],
          },
        ).decision ==
        NewsTrafficDecision.recommend,
  );
  final near = {
    'scope': [
      {'region': '서울', 'reference_id': null},
    ],
    'verified_point': [37.5663, 126.9779],
    'point_reference_source': 'synthetic test reference',
  };
  check(
    'verified nearby, no trip gives caution',
    evaluate(changes: near).decision == NewsTrafficDecision.caution,
  );
  final a = evaluate(route: trip()),
      b = evaluate(route: trip(), changes: {'version': 2});
  check(
    'same input stable notification key',
    a.notificationKey == evaluate(route: trip()).notificationKey,
  );
  check(
    'semantic version produces new notification key',
    a.notificationKey != b.notificationKey,
  );
  check(
    'AI copy keeps notification policy',
    a.toInsight().copyWith().notificationKey == a.notificationKey,
  );
  check(
    'decision contains evidence and rule version',
    a.toJson()['evidence_refs'] != null &&
        a.toJson()['rule_version'] == NewsTrafficEvaluation.ruleVersion,
  );
  for (final changes in [
    {'body_verified': false},
    {'status': 'made_up'},
    {
      'period': {'start': time('2026-02-30', null), 'end': time(null, null)},
    },
    {
      'period': {
        'start': time('2026-11-11', '10:00'),
        'end': time('2026-11-10', '09:00'),
      },
    },
    {
      'verified_point': [100, 200],
    },
  ]) {
    var rejected = false;
    try {
      impact(changes);
    } on FormatException {
      rejected = true;
    }
    check('malformed feed rejected: ${changes.keys.first}', rejected);
  }
  final legacy = TransitStrike(
    id: 's',
    mode: TransitMode.bus,
    operator: '서울버스노조',
    regions: ['서울'],
    status: StrikeStatus.scheduled,
    quote: '11일부터 13일까지 파업',
    articleTitle: '파업',
    url: 'https://example.com',
    publishedAt: now,
    start: DateTime(2026, 11, 9),
    end: DateTime(2026, 11, 13),
  );
  check(
    'legacy strike end-date regression',
    const InsightEngine()
        .build(
          plans: [plan],
          events: [],
          interests: {},
          now: now,
          strikes: [legacy],
        )
        .any((i) => i.id.startsWith('strike:')),
  );
  final official = TrafficNotice(
    id: 'n',
    kind: TrafficKind.rally,
    title: '공식 통제',
    detail: '차량 통제',
    start: DateTime(2026, 11, 10, 8),
    end: DateTime(2026, 11, 10, 9),
    location: plan.location!,
    source: 'topis',
    sourceName: 'TOPIS',
  );
  check(
    'official saved trip mismatch',
    const TrafficMatcher()
            .evaluate(plan, official, now, trip: trip())
            .decision ==
        TrafficDecision.ignore,
  );
  check(
    'official subway mismatch',
    const TrafficMatcher()
            .evaluate(
              plan,
              official,
              now,
              trip: trip(hour: 8, modes: {'subway'}),
            )
            .decision ==
        TrafficDecision.ignore,
  );
  if (args.isNotEmpty) {
    final json = jsonDecode(File(args.first).readAsStringSync()) as Map;
    final feed = (json['trafficImpacts'] as List)
        .map(
          (e) => NewsTrafficImpact.fromJson((e as Map).cast<String, dynamic>()),
        )
        .toList();
    check('Python publisher to Dart consumer', feed.isNotEmpty);
    check(
      'published strike directly matches saved trip',
      matcher
              .evaluate(
                plan,
                trip(),
                feed.firstWhere((i) => i.type == 'STRIKE'),
                now,
              )
              .decision ==
          NewsTrafficDecision.recommend,
    );
  }
  stdout.writeln(
    'PASS: $passed traffic extraction/route/notification-policy checks',
  );
}
