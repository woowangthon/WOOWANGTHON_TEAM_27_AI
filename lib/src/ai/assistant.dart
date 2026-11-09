import 'dart:convert';

import '../engine/route_matcher.dart';
import '../engine/taste.dart';
import '../models/life_stage.dart';
import '../models/models.dart';
import '../models/transit_strike.dart';
import 'gemini_client.dart';

/// 앱 안의 AI 비서 ("LifeRadar에게 물어보기").
///
/// 역할 분담 (AI는 찾고 말하고, 사람은 고른다):
/// 1. **찾기 (코드)** — [AssistantQuery.parse]가 질문에서 날짜·지역·종류·무료·마감·일정 이름을 읽고,
///    [Assistant.retrieve]가 실제 행사 데이터에서 후보를 고른다. AI는 후보 밖의 행사를 볼 수 없다.
/// 2. **말하기 (Gemini)** — 후보·내 일정·신호만 담은 CONTEXT로 짧게 답하고, 추천 행사 id와
///    제안 행동(캘린더 추가·지도 보기)을 JSON으로 돌려준다.
/// 3. **검증 (코드)** — 후보에 없는 id·행동은 버리고, 답에 있는 두 자리 이상 숫자가 CONTEXT에 없으면
///    답 문장을 버리고 규칙 문장으로 바꾼다 (지어낸 날짜·가격 차단).
/// 4. **결정 (사람)** — 행동은 제안일 뿐, 화면에서 사용자가 [추가] / [취소]를 눌러야 실행된다.
///
/// 키가 없거나 할당량이 끝나면 [Assistant.fallback]: 같은 후보로 규칙 문장만 보여준다.
abstract final class Assistant {
  /// AI에게 보여 주는 후보 행사 수.
  static const maxCandidates = 24;

  /// 화면에 카드로 보여 주는 추천 수.
  static const maxCards = 5;

  /// 대화 기억 (최근 턴 수).
  static const maxHistory = 6;

  static const systemInstruction = '''
You are LifeRadar, an AI coworker that looks after a young person's schedule in Korea.
Reply in {LANG}. Be warm, concise (at most 4 short sentences), and practical.

Use ONLY the data in CONTEXT: the user's plans, candidate events (with ids), and signals.
- Never invent events, dates, times, prices, places or links. If CONTEXT has nothing that fits, say so honestly
  and suggest a better question (e.g. a date or a city).
- Recommend at most 5 events by listing their ids in event_ids, best first. Mention why they fit
  (interest, same day as a plan, near a plan, free, deadline soon).
- You may PROPOSE actions; the user confirms them in the app. Allowed: add_to_calendar(event_id), show_on_map(event_id).
  Never say you already added or changed anything.
- Signals marked "news" are news reports, not official notices — say so if you mention them.''';

  // ── 찾기 ──

  /// 질문에 맞는 후보 행사 (최대 [limit]개, 좋은 순).
  static List<RadarEvent> retrieve(
    AssistantQuery q, {
    required List<RadarEvent> events,
    required Set<String> interests,
    Taste taste = Taste.none,
    required DateTime now,
    int limit = maxCandidates,
  }) {
    final today = DateTime(now.year, now.month, now.day);
    bool live(RadarEvent e) => !e.end.isBefore(today);
    bool inRange(RadarEvent e) => q.from == null || (e.start.isBefore(q.to!) && !e.end.isBefore(q.from!));
    bool inRegion(RadarEvent e) =>
        q.region == null || (e.placeless ? false : KoreaRegions.covers([q.region!], e.location));
    bool ofKind(RadarEvent e) => q.categories.isEmpty || q.categories.contains(e.category);
    bool free(RadarEvent e) => !q.freeOnly || e.isFree == true;
    bool due(RadarEvent e) =>
        !q.deadlineSoon ||
        (e.deadline != null && !e.deadline!.isBefore(today) && e.deadline!.difference(today).inDays <= 14);
    bool near(RadarEvent e) =>
        q.near == null || (!e.placeless && RouteMatcher.haversineKm(q.near!, e.location) <= q.nearKm);
    int keywordHits(RadarEvent e) {
      final hay = '${e.title.ko} ${e.title.en} ${e.venue} ${e.city}'.toLowerCase();
      return q.keywords.where(hay.contains).length;
    }

    var pool = events.where((e) => live(e) && inRange(e) && inRegion(e) && near(e) && free(e) && due(e)).toList();
    final kinds = pool.where(ofKind).toList();
    if (kinds.isNotEmpty || q.categories.isEmpty) pool = kinds;
    if (q.keywords.isNotEmpty) {
      final hits = pool.where((e) => keywordHits(e) > 0).toList();
      if (hits.isNotEmpty) pool = hits;
    }

    double score(RadarEvent e) => taste.score(e, interests) + 0.5 * keywordHits(e);
    pool.sort((a, b) {
      if (q.deadlineSoon) return a.deadline!.compareTo(b.deadline!);
      final s = score(b).compareTo(score(a));
      if (s != 0) return s;
      DateTime eff(RadarEvent e) => e.start.isBefore(today) ? today : e.start;
      return eff(a).compareTo(eff(b));
    });
    return pool.take(limit).toList();
  }

  // ── 말하기 ──

  /// AI에게 보낼 사실 묶음. 모든 숫자·날짜는 여기서만 나온다.
  static Map<String, dynamic> context({
    required AssistantQuery query,
    required List<RadarEvent> candidates,
    required List<Plan> plans,
    required DateTime now,
    required Set<String> interests,
    LifeStage? stage,
    List<Insight> signals = const [],
    List<TransitStrike> strikes = const [],
  }) {
    final today = DateTime(now.year, now.month, now.day);
    String ymd(DateTime d) => '${d.year}-${_pad(d.month)}-${_pad(d.day)}';
    String hm(DateTime d) => '${_pad(d.hour)}:${_pad(d.minute)}';
    final upcoming = plans.where((p) => !p.end.isBefore(today)).take(12);
    return {
      'today': '${ymd(today)} (${_weekday[today.weekday - 1]})',
      'user': {'interests': interests.toList(), if (stage != null) 'situation': stage.name},
      'understood_query': query.describe(),
      'plans': [
        for (final p in upcoming)
          {
            'title': p.title,
            'date': _sameDay(p.start, p.end) ? ymd(p.start) : '${ymd(p.start)} ~ ${ymd(p.end)}',
            if (!p.isAllDay) 'time': hm(p.start),
            if (p.locationText.isNotEmpty) 'place': p.locationText,
          },
      ],
      'signals': [
        for (final s in signals.take(8))
          {'kind': s.id.startsWith('strike:') ? 'news' : s.kind.name, 'title': s.title.ko, 'why': s.why.ko},
      ],
      'events': [
        for (final e in candidates)
          {
            'id': e.id,
            'title': e.title.ko,
            if (e.title.en != e.title.ko) 'title_en': e.title.en,
            'category': e.category.name,
            'tags': e.tags,
            'date': _sameDay(e.start, e.end) ? '${ymd(e.start)} ${hm(e.start)}' : '${ymd(e.start)} ~ ${ymd(e.end)}',
            if (!e.placeless) 'place': '${e.venue}, ${e.city}' else 'organizer': e.venue,
            if (e.isFree == true) 'free': true,
            if (e.price != null && e.isFree != true) 'price': e.price,
            if (e.deadline != null) 'deadline': ymd(e.deadline!),
          },
      ],
    };
  }

  static Map<String, dynamic> requestBody({
    required String question,
    required Map<String, dynamic> context,
    List<ChatTurn> history = const [],
    String lang = 'ko',
  }) => {
    'systemInstruction': {
      'parts': [
        {'text': systemInstruction.replaceFirst('{LANG}', lang == 'ko' ? 'Korean' : 'English')},
      ],
    },
    'contents': [
      for (final t in history.length > maxHistory ? history.sublist(history.length - maxHistory) : history)
        {
          'role': t.fromUser ? 'user' : 'model',
          'parts': [
            {'text': t.text},
          ],
        },
      {
        'role': 'user',
        'parts': [
          {'text': 'CONTEXT:\n${jsonEncode(context)}\n\nQUESTION:\n$question'},
        ],
      },
    ],
    'generationConfig': {
      'temperature': 0.3,
      'responseMimeType': 'application/json',
      'responseSchema': {
        'type': 'OBJECT',
        'properties': {
          'reply': {'type': 'STRING'},
          'event_ids': {
            'type': 'ARRAY',
            'items': {'type': 'STRING'},
          },
          'actions': {
            'type': 'ARRAY',
            'items': {
              'type': 'OBJECT',
              'properties': {
                'type': {
                  'type': 'STRING',
                  'enum': ['add_to_calendar', 'show_on_map'],
                },
                'event_id': {'type': 'STRING'},
              },
              'required': ['type', 'event_id'],
            },
          },
        },
        'required': ['reply', 'event_ids', 'actions'],
      },
    },
  };

  // ── 검증 ──

  /// 모델 응답 → 검증된 답. [rejected]에는 버린 것과 이유 (평가용).
  static AssistantReply parseResponse(
    Map<String, dynamic> json, {
    required List<RadarEvent> candidates,
    required Map<String, dynamic> context,
    required String fallbackText,
    String? model,
    List<String>? rejected,
  }) {
    final parts = (((json['candidates'] as List?)?.firstOrNull as Map?)?['content'] as Map?)?['parts'] as List?;
    final body = (parts?.firstOrNull as Map?)?['text'] as String?;
    if (body == null) throw const FormatException('empty response');
    final data = jsonDecode(body) as Map<String, dynamic>;
    final byId = {for (final e in candidates) e.id: e};

    final ids = <String>[];
    for (final id in (data['event_ids'] as List? ?? const []).whereType<String>()) {
      if (!byId.containsKey(id)) {
        rejected?.add('event $id: not a candidate');
      } else if (!ids.contains(id) && ids.length < maxCards) {
        ids.add(id);
      }
    }

    final actions = <AssistantAction>[];
    for (final a in (data['actions'] as List? ?? const []).whereType<Map>()) {
      final type = AssistantActionType.byWire(a['type'] as String?);
      final e = byId[a['event_id']];
      if (type == null || e == null) {
        rejected?.add('action ${a['type']} ${a['event_id']}: invalid');
      } else if (type == AssistantActionType.showOnMap && e.placeless) {
        rejected?.add('action show_on_map ${e.id}: no place');
      } else if (!actions.any((x) => x.type == type && x.eventId == e.id) && actions.length < 3) {
        actions.add(AssistantAction(type, e.id));
        if (!ids.contains(e.id)) ids.add(e.id);
      }
    }

    var text = (data['reply'] as String? ?? '').trim();
    var grounded = true;
    final bad = ungroundedNumbers(text, jsonEncode(context));
    if (text.isEmpty || text.length > 700 || bad.isNotEmpty) {
      rejected?.add(text.isEmpty ? 'reply empty' : 'reply numbers not in context: ${bad.join(', ')}');
      text = fallbackText;
      grounded = false;
    }
    return AssistantReply(text: text, eventIds: ids, actions: actions, model: model, grounded: grounded);
  }

  /// 답에 있는 두 자리 이상 숫자 중 CONTEXT에 없는 것 ("11월 20일"의 20, "15,000원" 등).
  /// 한 자리 숫자(개수·순서)는 허용한다.
  static List<String> ungroundedNumbers(String reply, String contextText) {
    final known = RegExp(
      r'\d+',
    ).allMatches(contextText.replaceAll(',', '')).map((m) => int.parse(m[0]!).toString()).toSet();
    return [
      for (final m in RegExp(r'\d[\d,]*').allMatches(reply))
        if (m[0]!.replaceAll(',', '').length >= 2 && !known.contains(int.parse(m[0]!.replaceAll(',', '')).toString()))
          m[0]!,
    ];
  }

  /// AI 없이 (키 없음·오류): 같은 후보로 규칙 문장.
  static AssistantReply fallback(AssistantQuery q, List<RadarEvent> candidates, {String lang = 'ko'}) {
    final ids = candidates.take(maxCards).map((e) => e.id).toList();
    return AssistantReply(
      text: fallbackText(q, ids.length, lang: lang),
      eventIds: ids,
    );
  }

  static String fallbackText(AssistantQuery q, int count, {String lang = 'ko'}) {
    final what = q.describe(lang: lang);
    if (lang == 'ko') {
      return count == 0
          ? '${what.isEmpty ? '' : '$what — '}조건에 맞는 행사를 찾지 못했어요. 날짜나 지역을 바꿔 물어봐 주세요.'
          : '${what.isEmpty ? '관심사에 맞는' : what} 행사를 찾았어요. 마음에 드는 것을 골라 보세요.';
    }
    return count == 0
        ? "${what.isEmpty ? '' : '$what — '}I couldn't find matching events. Try another date or city."
        : 'Here are ${what.isEmpty ? 'events matching your interests' : 'events for $what'}. Pick what you like.';
  }

  /// 전체 흐름: 찾기 → Gemini → 검증. 실패하면 예외 (화면은 [fallback]).
  static Future<AssistantReply> ask(
    GeminiClient client, {
    required String question,
    required AssistantQuery query,
    required List<RadarEvent> candidates,
    required Map<String, dynamic> context,
    List<ChatTurn> history = const [],
    String lang = 'ko',
    List<String>? rejected,
  }) async {
    final (json, model) = await client.generate(
      requestBody(question: question, context: context, history: history, lang: lang),
    );
    return parseResponse(
      json,
      candidates: candidates,
      context: context,
      fallbackText: fallbackText(query, candidates.length.clamp(0, maxCards), lang: lang),
      model: model,
      rejected: rejected,
    );
  }

  static const _weekday = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static String _pad(int n) => n.toString().padLeft(2, '0');
}

/// 질문에서 코드로 읽은 조건 (날짜 범위 `[from, to)`, 지역, 종류, 무료, 마감 임박, 일정 근처).
class AssistantQuery {
  const AssistantQuery({
    this.from,
    this.to,
    this.region,
    this.categories = const {},
    this.freeOnly = false,
    this.deadlineSoon = false,
    this.keywords = const [],
    this.plan,
    this.near,
    this.nearKm = 15,
  });

  final DateTime? from, to;
  final String? region;
  final Set<EventCategory> categories;
  final bool freeOnly;
  final bool deadlineSoon;
  final List<String> keywords;

  /// 질문이 가리키는 내 일정 ("부산 여행 때 …").
  final Plan? plan;
  final GeoPoint? near;
  final double nearKm;

  static const _regionAliases = {
    'seoul': '서울', 'busan': '부산', 'incheon': '인천', 'daegu': '대구', 'daejeon': '대전', //
    'gwangju': '광주', 'ulsan': '울산', 'sejong': '세종', 'jeju': '제주', 'gyeonggi': '경기', 'gangwon': '강원',
  };

  static const _kinds = <EventCategory, List<String>>{
    EventCategory.concert: ['콘서트', '공연', '음악', 'concert', 'music'],
    EventCategory.performance: ['연극', '뮤지컬', '무용', 'musical', 'theater', 'theatre', 'play'],
    EventCategory.exhibition: ['전시', '미술', '박물관', 'exhibition', 'museum', 'art'],
    EventCategory.festival: ['축제', 'festival'],
    EventCategory.hackathon: ['해커톤', 'hackathon'],
    EventCategory.conference: ['컨퍼런스', '세미나', '포럼', 'conference', 'seminar', 'forum'],
    EventCategory.meetup: ['밋업', '모임', '네트워킹', 'meetup', 'networking'],
    EventCategory.job: ['채용', '취업', '일자리', 'job', 'hiring', 'career'],
    EventCategory.scholarship: ['장학', 'scholarship'],
    EventCategory.classes: ['강좌', '클래스', '교육', '체험', '수업', 'class', 'workshop', 'course'],
    EventCategory.startupSupport: ['창업', '지원사업', '공고', 'startup', 'founder'],
  };

  static const _stop = {
    '이번',
    '주말',
    '오늘',
    '내일',
    '다음',
    '주',
    '달',
    '뭐',
    '할',
    '갈',
    '만한',
    '곳',
    '추천',
    '해줘',
    '알려줘',
    '찾아줘',
    '있어',
    '있나요',
    '어디',
    '좀',
    '때',
    '근처',
    '행사',
    '일정',
    '무료',
    '마감',
    '임박',
    '하지',
    '할까',
    '나',
    '내',
    '수',
    '있는',
    'what',
    'to',
    'do',
    'this',
    'next',
    'weekend',
    'today',
    'tomorrow',
    'week',
    'month',
    'any',
    'events',
    'event',
    'near',
    'free',
    'deadline',
    'recommend',
    'find',
    'me',
    'my',
    'in',
    'on',
    'for',
    'the',
    'a',
    'is',
    'are',
    'there',
  };

  /// 질문 → 조건. [plans]에서 제목이 질문에 들어간 일정을 찾아 그 날짜·장소를 조건으로 쓴다.
  static AssistantQuery parse(String question, {required DateTime now, List<Plan> plans = const []}) {
    final q = question.toLowerCase();
    final today = DateTime(now.year, now.month, now.day);
    DateTime d(int add) => today.add(Duration(days: add));
    DateTime? from, to;
    Plan? plan;

    // 일정 이름 ("Busan trip", "부산 출장"): 제목의 단어 절반 이상이 질문에 있으면.
    for (final p in plans.where((p) => !p.end.isBefore(today))) {
      final words = p.title.toLowerCase().split(RegExp(r'\s+')).where((w) => w.length >= 2).toList();
      if (words.isNotEmpty && words.where(q.contains).length * 2 >= words.length) {
        plan = p;
        break;
      }
    }

    final md = RegExp(r'(\d{1,2})\s*월\s*(\d{1,2})\s*일').firstMatch(q);
    final dOnly = RegExp(r'(?<![\d월])(\d{1,2})\s*일').firstMatch(q);
    if (q.contains('오늘') || q.contains('today')) {
      (from, to) = (today, d(1));
    } else if (q.contains('내일') || q.contains('tomorrow')) {
      (from, to) = (d(1), d(2));
    } else if (q.contains('주말') || q.contains('weekend')) {
      final sat = today.weekday == DateTime.sunday ? today : d(DateTime.saturday - today.weekday);
      (from, to) = (sat, DateTime(sat.year, sat.month, sat.day + (today.weekday == DateTime.sunday ? 1 : 2)));
    } else if (q.contains('다음 주') || q.contains('다음주') || q.contains('next week')) {
      (from, to) = (d(7), d(14));
    } else if (q.contains('이번 주') || q.contains('이번주') || q.contains('this week')) {
      (from, to) = (today, d(7));
    } else if (q.contains('이번 달') || q.contains('이번달') || q.contains('this month')) {
      (from, to) = (today, d(31));
    } else if (md != null) {
      final m = int.parse(md[1]!), day = int.parse(md[2]!);
      var date = DateTime(today.year, m, day);
      if (date.isBefore(today.subtract(const Duration(days: 31)))) date = DateTime(today.year + 1, m, day);
      (from, to) = (date, DateTime(date.year, date.month, date.day + 1));
    } else if (dOnly != null) {
      final day = int.parse(dOnly[1]!);
      var date = DateTime(today.year, today.month, day);
      if (date.isBefore(today)) date = DateTime(today.year, today.month + 1, day);
      (from, to) = (date, DateTime(date.year, date.month, date.day + 1));
    } else if (plan != null) {
      from = DateTime(plan.start.year, plan.start.month, plan.start.day);
      to = DateTime(plan.end.year, plan.end.month, plan.end.day + 1);
    }

    // "11월 20일 일정에 …": 이름 대신 날짜로 가리킨 내 일정 — 그날 걸쳐 있는 일정.
    if (plan == null && from != null && (q.contains('일정') || q.contains('plan') || q.contains('trip'))) {
      for (final p in plans) {
        if (p.start.isBefore(to!) && !p.end.isBefore(from)) {
          plan = p;
          break;
        }
      }
    }

    String? region;
    for (final name in KoreaRegions.names) {
      if (name != '전국' && q.contains(name)) region = name;
    }
    _regionAliases.forEach((en, ko) {
      if (q.contains(en)) region = ko;
    });

    final categories = {
      for (final e in _kinds.entries)
        if (e.value.any(q.contains)) e.key,
    };

    final keywords = [
      for (final w in q.split(RegExp(r'[\s,.?!·]+')))
        if (w.length >= 2 &&
            !_stop.contains(w) &&
            !RegExp(r'\d').hasMatch(w) &&
            !KoreaRegions.names.contains(w) &&
            !_regionAliases.containsKey(w) &&
            !_kinds.values.any((ks) => ks.contains(w)) &&
            !(plan?.title.toLowerCase().contains(w) ?? false))
          w,
    ];

    return AssistantQuery(
      from: from,
      to: to,
      region: plan == null ? region : null,
      categories: categories,
      freeOnly: q.contains('무료') || q.contains('free'),
      deadlineSoon: q.contains('마감') || q.contains('deadline') || q.contains('due'),
      keywords: keywords,
      plan: plan,
      near: plan?.location,
    );
  }

  bool get isEmpty =>
      from == null &&
      region == null &&
      categories.isEmpty &&
      !freeOnly &&
      !deadlineSoon &&
      keywords.isEmpty &&
      plan == null;

  /// 사람이 읽는 조건 요약 ("11/20 · 부산 · 무료").
  String describe({String lang = 'ko'}) {
    final parts = <String>[
      if (plan != null) plan!.title,
      if (from != null)
        to!.difference(from!).inDays <= 1
            ? '${from!.month}/${from!.day}'
            : '${from!.month}/${from!.day}–${to!.subtract(const Duration(days: 1)).month}/${to!.subtract(const Duration(days: 1)).day}',
      ?region,
      if (freeOnly) lang == 'ko' ? '무료' : 'free',
      if (deadlineSoon) lang == 'ko' ? '마감 임박' : 'deadline soon',
    ];
    return parts.join(' · ');
  }
}

/// 대화 한 턴 (기억용).
class ChatTurn {
  const ChatTurn({required this.fromUser, required this.text});
  final bool fromUser;
  final String text;
}

enum AssistantActionType {
  addToCalendar('add_to_calendar'),
  showOnMap('show_on_map');

  const AssistantActionType(this.wire);
  final String wire;

  static AssistantActionType? byWire(String? w) {
    for (final t in values) {
      if (t.wire == w) return t;
    }
    return null;
  }
}

/// 제안된 행동 — 사용자가 확인해야 실행된다.
class AssistantAction {
  const AssistantAction(this.type, this.eventId);
  final AssistantActionType type;
  final String eventId;
}

class AssistantReply {
  const AssistantReply({
    required this.text,
    this.eventIds = const [],
    this.actions = const [],
    this.model,
    this.grounded = true,
  });

  final String text;
  final List<String> eventIds;
  final List<AssistantAction> actions;

  /// 응답한 Gemini 모델. null = 규칙 문장 (AI 아님).
  final String? model;

  /// 답 문장이 검증을 통과했는지 (false면 규칙 문장으로 바뀐 것).
  final bool grounded;

  bool get fromAi => model != null && grounded;
}

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
