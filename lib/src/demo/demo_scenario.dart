// 데모용 SAMPLE 데이터 (source: 'sample').
// 실제 행사는 공공 API에서 수집하며, 이 데이터는 시연 시나리오가 항상 재현되도록 유지한다.
// 장소 좌표는 실제(BEXCO, COEX 등)이고 행사 자체는 예시다.
import '../models/models.dart';

const _bexco = GeoPoint(35.1690, 129.1360);
const _asiad = GeoPoint(35.1904, 129.0587);
const _coex = GeoPoint(37.5126, 127.0590);
const _dcc = GeoPoint(36.3754, 127.3913); // Daejeon Convention Center
const _kaist = GeoPoint(36.3721, 127.3604);
const _pangyo = GeoPoint(37.4020, 127.1086);
const _haeundae = GeoPoint(35.1587, 129.1604);
const _gangnam = GeoPoint(37.4979, 127.0276);

final sampleEvents = <RadarEvent>[
  // ── 기술 외 관심사용 (음식, 운동, 게임, 예술) ──
  RadarEvent(
    id: 'ev-seoul-food-fest',
    title: const LocalizedText(ko: '서울 푸드 페스티벌 (샘플)', en: 'Seoul Food Festival (sample)'),
    description: const LocalizedText(
      ko: '전국 맛집과 푸드트럭이 모이는 주말 축제. 가족 단위 방문객 환영.',
      en: 'A weekend festival of local restaurants and food trucks. Families welcome.',
    ),
    category: EventCategory.festival,
    tags: const ['food', 'culture', 'family'],
    start: DateTime(2026, 11, 14, 11),
    end: DateTime(2026, 11, 14, 20),
    venue: 'COEX 야외광장',
    city: 'Seoul',
    location: _coex,
  ),
  RadarEvent(
    id: 'ev-gangnam-run',
    title: const LocalizedText(ko: '강남 나이트 런 5K (샘플)', en: 'Gangnam Night Run 5K (sample)'),
    description: const LocalizedText(
      ko: '퇴근 후 함께 달리는 5km 러닝 모임. 초보자도 참여 가능.',
      en: 'An after-work 5 km group run. Beginners welcome.',
    ),
    category: EventCategory.meetup,
    tags: const ['fitness', 'sports', 'outdoor'],
    start: DateTime(2026, 11, 13, 19, 30),
    end: DateTime(2026, 11, 13, 21),
    venue: '강남역 11번 출구',
    city: 'Seoul',
    location: _gangnam,
    deadline: DateTime(2026, 11, 12),
  ),
  RadarEvent(
    id: 'ev-pangyo-game-art',
    title: const LocalizedText(ko: '판교 게임 아트 전시 (샘플)', en: 'Pangyo Game Art Exhibition (sample)'),
    description: const LocalizedText(
      ko: '국내 게임사의 콘셉트 아트와 인디 게임 시연을 한곳에서.',
      en: 'Concept art from Korean game studios and indie game demos in one place.',
    ),
    category: EventCategory.festival,
    tags: const ['gaming', 'art', 'design'],
    start: DateTime(2026, 11, 22, 10),
    end: DateTime(2026, 11, 22, 18),
    venue: '판교 테크노밸리',
    city: 'Seongnam',
    location: _pangyo,
  ),
  RadarEvent(
    id: 'ev-busan-concert',
    title: const LocalizedText(ko: '부산 대형 콘서트 (샘플)', en: 'Large concert in Busan (sample)'),
    description: const LocalizedText(
      ko: '아시아드 주경기장에서 열리는 대규모 공연. 수만 명의 관람객이 예상됩니다.',
      en: 'A large-scale concert at Asiad Main Stadium. Tens of thousands of visitors expected.',
    ),
    category: EventCategory.concert,
    tags: const ['music', 'culture'],
    start: DateTime(2026, 11, 20, 18),
    end: DateTime(2026, 11, 20, 22),
    venue: '부산 아시아드 주경기장',
    city: 'Busan',
    location: _asiad,
  ),
  RadarEvent(
    id: 'ev-busan-ai-expo',
    title: const LocalizedText(ko: 'AI & 스타트업 엑스포 (샘플)', en: 'AI & Startup Expo (sample)'),
    description: const LocalizedText(
      ko: 'BEXCO에서 열리는 AI 스타트업 전시 및 네트워킹 행사.',
      en: 'AI startup exhibition and networking at BEXCO.',
    ),
    category: EventCategory.conference,
    tags: const ['ai', 'startup'],
    start: DateTime(2026, 11, 21, 10),
    end: DateTime(2026, 11, 21, 18),
    venue: 'BEXCO',
    city: 'Busan',
    location: _bexco,
    deadline: DateTime(2026, 11, 18),
  ),
  RadarEvent(
    id: 'ev-daejeon-ai-seminar',
    title: const LocalizedText(ko: '대전 AI 세미나 (샘플)', en: 'Daejeon AI Seminar (sample)'),
    description: const LocalizedText(
      ko: '대전컨벤션센터에서 열리는 생성형 AI 실무 세미나.',
      en: 'Hands-on generative AI seminar at Daejeon Convention Center.',
    ),
    category: EventCategory.conference,
    tags: const ['ai'],
    start: DateTime(2026, 11, 20, 13),
    end: DateTime(2026, 11, 20, 16),
    venue: '대전컨벤션센터 (DCC)',
    city: 'Daejeon',
    location: _dcc,
    // 시연 5단계: "캘린더에 추가한 세미나의 신청 마감이 2일 남았어요" (알림).
    deadline: DateTime(2026, 11, 15),
  ),
  RadarEvent(
    id: 'ev-kaist-hackathon',
    title: const LocalizedText(ko: '캠퍼스 AI 해커톤 (샘플)', en: 'Campus AI Hackathon (sample)'),
    description: const LocalizedText(
      ko: '48시간 동안 AI 서비스를 만드는 대학생 해커톤.',
      en: 'A 48-hour student hackathon to build AI services.',
    ),
    category: EventCategory.hackathon,
    tags: const ['ai', 'student', 'developer'],
    start: DateTime(2026, 11, 28, 9),
    end: DateTime(2026, 11, 30, 9),
    venue: 'KAIST',
    city: 'Daejeon',
    location: _kaist,
    deadline: DateTime(2026, 11, 21),
  ),
  RadarEvent(
    id: 'ev-coex-dev-conf',
    title: const LocalizedText(ko: 'AI 개발자 컨퍼런스 (샘플)', en: 'AI Developer Conference (sample)'),
    description: const LocalizedText(
      ko: 'COEX에서 열리는 AI 개발자 컨퍼런스. 학생 할인 등록 가능.',
      en: 'AI developer conference at COEX. Student discount available.',
    ),
    category: EventCategory.conference,
    tags: const ['ai', 'developer', 'career'],
    start: DateTime(2026, 12, 3, 9),
    end: DateTime(2026, 12, 4, 18),
    venue: 'COEX',
    city: 'Seoul',
    location: _coex,
    deadline: DateTime(2026, 11, 25),
  ),
  RadarEvent(
    id: 'ev-pangyo-meetup',
    title: const LocalizedText(ko: '판교 스타트업 밋업 (샘플)', en: 'Pangyo Startup Meetup (sample)'),
    description: const LocalizedText(
      ko: '창업자와 개발자가 모이는 저녁 네트워킹.',
      en: 'Evening networking for founders and developers.',
    ),
    category: EventCategory.meetup,
    tags: const ['startup', 'networking', 'career'],
    start: DateTime(2026, 11, 12, 19),
    end: DateTime(2026, 11, 12, 21),
    venue: '판교 테크노밸리',
    city: 'Seongnam',
    location: _pangyo,
  ),
];

final samplePlans = <Plan>[
  Plan(
    id: 'plan-gangnam-meeting',
    title: 'Team meeting',
    start: DateTime(2026, 11, 10, 14),
    end: DateTime(2026, 11, 10, 16),
    locationText: '강남역',
    city: 'Seoul',
    location: _gangnam,
  ),
  Plan(
    id: 'plan-busan-trip',
    title: 'Busan trip',
    start: DateTime(2026, 11, 20, 9),
    end: DateTime(2026, 11, 22, 20),
    locationText: '부산 해운대',
    city: 'Busan',
    location: _haeundae,
  ),
];

/// 데모 시나리오가 낡지 않도록: 부산 출장은 오늘로부터 최소 [_minLeadDays]일 뒤여야 한다
/// (날씨 예보와 "마감 임박" 카드가 동작하도록). 날짜가 지나면 모든
/// 샘플을 주 단위로 앞당긴다 — 요일과 서로 간의 간격은 유지된다.
/// 심사위원이 11/14 이후에 APK를 열어도 데모 카드가 나타난다.
const _minLeadDays = 6;
final _demoAnchor = DateTime(2026, 11, 20); // 부산 출장 시작

Duration demoShift(DateTime now) {
  final gap = _demoAnchor.difference(DateTime(now.year, now.month, now.day)).inDays;
  if (gap >= _minLeadDays) return Duration.zero;
  return Duration(days: 7 * ((_minLeadDays - gap) / 7).ceil());
}

/// [now]에 맞춰 이동한 샘플 행사.
List<RadarEvent> sampleEventsAt(DateTime now) {
  final d = demoShift(now);
  if (d == Duration.zero) return sampleEvents;
  return [
    for (final e in sampleEvents)
      RadarEvent(
        id: e.id,
        title: e.title,
        description: e.description,
        category: e.category,
        tags: e.tags,
        start: e.start.add(d),
        end: e.end.add(d),
        venue: e.venue,
        city: e.city,
        location: e.location,
        url: e.url,
        registerUrl: e.registerUrl,
        deadline: e.deadline?.add(d),
        source: e.source,
        sourceName: e.sourceName,
        imageUrl: e.imageUrl,
        isFree: e.isFree,
        price: e.price,
        placeless: e.placeless,
      ),
  ];
}

/// [now]에 맞춰 이동한 샘플 일정.
List<Plan> samplePlansAt(DateTime now) {
  final d = demoShift(now);
  if (d == Duration.zero) return samplePlans;
  return [for (final p in samplePlans) p.copyWith(start: p.start.add(d), end: p.end.add(d))];
}
