import 'package:test/test.dart';
import 'package:liferadar_core/liferadar_core.dart';

RadarEvent _e(String id, EventCategory c, List<String> tags, {int day = 20}) => RadarEvent(
      id: id,
      title: LocalizedText(ko: id, en: id),
      description: const LocalizedText(ko: '', en: ''),
      category: c,
      tags: tags,
      start: DateTime(2026, 11, day, 10),
      end: DateTime(2026, 11, day, 18),
      venue: 'Hall',
      city: 'Seoul',
      location: const GeoPoint(37.5, 127.0),
      source: 'test',
    );

final _jazz = _e('jazz', EventCategory.concert, ['music']);
final _rock = _e('rock', EventCategory.concert, ['music']);
final _aiTalk = _e('ai-talk', EventCategory.conference, ['ai']);
final _aiMeetup = _e('ai-meetup', EventCategory.meetup, ['ai', 'networking']);
final _blues = _e('blues', EventCategory.concert, ['music']);
final _events = {for (final e in [_jazz, _blues, _rock, _aiTalk, _aiMeetup]) e.id: e};

void main() {
  test('insight id → event id', () {
    expect(Taste.eventIdOf('nearby:plan-1:tour-123'), 'tour-123');
    expect(Taste.eventIdOf('deadline:kstartup-9'), 'kstartup-9');
    expect(Taste.eventIdOf('opportunity:ev-x'), 'ev-x');
    expect(Taste.eventIdOf('rain:plan-1:2026-11-8'), isNull);
  });

  test('👎 유사한 행사는 아래로, 👍는 위로 올린다', () {
    final taste = Taste.from({'opportunity:jazz': InsightFeedback.dislike}, _events);
    expect(taste.bias(_rock), lessThan(0)); // 같은 태그 + 카테고리
    expect(taste.bias(_aiTalk), 0); // 관련 없음
    final interests = {'music', 'ai'};
    expect(taste.score(_rock, interests), lessThan(Taste.none.score(_rock, interests)));
    // 평가된 event 자체는 이동하지 않음 (카드는 👎 상태로 유지되며, 취소 가능).
    expect(taste.score(_jazz, interests), Taste.none.score(_jazz, interests));

    final liked = Taste.from({'deadline:ai-talk': InsightFeedback.like}, _events);
    expect(liked.score(_aiMeetup, {'ai', 'networking'}), 1.0);
    expect(liked.score(_aiMeetup, {'ai'}), greaterThan(Taste.none.score(_aiMeetup, {'ai'})));
  });

  test('취향 관심사에 맞지 않는 주제를 추가하지 않는다', () {
    final taste = Taste.from({'opportunity:jazz': InsightFeedback.like}, _events);
    expect(taste.score(_rock, {'ai'}), 0);
  });

  test('InsightEngine: 👎 이후 유사한 콘서트는 추천에서 내려가고, AI가 나온다', () {
    const engine = InsightEngine(maxGeneralOpportunities: 1);
    final now = DateTime(2026, 11, 7);
    final events = [_rock, _aiMeetup];
    final interests = {'music', 'ai'};
    List<String> ids(Taste t) => [
          for (final i in engine.build(plans: const [], events: events, interests: interests, now: now, taste: t)) i.id,
        ];

    expect(ids(Taste.none), ['opportunity:rock']); // music 1.0 > ai 0.5
    // 하나의 👎 — 콘서트는 여전히 앞순위(완전 일치)지만 점수가 하락함.
    final once = Taste.from({'opportunity:jazz': InsightFeedback.dislike}, _events);
    expect(ids(once), ['opportunity:rock']);
    // 두 번째 👎 — 콘서트는 아래로 내려가고, AI meetup이 나옴.
    final twice = Taste.from({
      'opportunity:jazz': InsightFeedback.dislike,
      'deadline:blues': InsightFeedback.dislike,
    }, _events);
    expect(ids(twice), ['opportunity:ai-meetup']);
  });
}
