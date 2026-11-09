import '../models/life_stage.dart';
import '../models/models.dart';

/// 사용자 피드백(👍 / 👎 / 숨기기)으로부터 학습된 취향.
///
/// 각 평가는 해당 행사의 태그와 카테고리에 가중치를 추가한다. 이후 다른
/// 행사들은 [bias]를 통해 위나 아래로 이동된다: 예를 들어 👎를 누른 축제와 유사한
/// 축제는 낮게 내려간다. 순수 Dart, 결정론적 (테스트 가능, 서버로 이전 가능).
///
/// [stage](사용자의 지금 상황)가 있으면 그 상황에 맞는 행사를 조금 올린다 — 관심사에 없더라도
/// (예: 학생에게 장학금 공고) 낮은 점수로 후보에 들어온다.
class Taste {
  const Taste._(this._tags, this._categories, this.rated, [this.stage]);

  static const none = Taste._({}, {}, {});

  /// 사용자의 지금 상황 (온보딩·설정에서 고름). null = 정보 없음.
  final LifeStage? stage;

  /// 상황에 맞는 행사: 관심사 일치가 있으면 +[_stageBoost], 없으면 [_stageOnly].
  static const _stageBoost = 0.15;
  static const _stageOnly = 0.2;

  /// 같은 피드백 취향에 상황만 바꾼 것.
  Taste withStage(LifeStage? s) => Taste._(_tags, _categories, rated, s);

  final Map<String, double> _tags;
  final Map<EventCategory, double> _categories;

  /// 평가된 행사들. 해당 카드는 평가된 상태로 유지됨 (취소 가능).
  final Set<String> rated;

  /// 단일 평가의 이동 정도 및 최대 영향.
  static const _step = 0.4;
  static const _cap = 1.0;

  /// [feedback]: 인사이트 id → 평가. [events]: id → 행사.
  factory Taste.from(Map<String, InsightFeedback> feedback, Map<String, RadarEvent> events) {
    final tags = <String, double>{};
    final categories = <EventCategory, double>{};
    final rated = <String>{};
    for (final entry in feedback.entries) {
      final eventId = eventIdOf(entry.key);
      final e = eventId == null ? null : events[eventId];
      if (e == null) continue;
      final w = switch (entry.value) {
        InsightFeedback.like => 1.0,
        InsightFeedback.dislike => -1.0,
        InsightFeedback.hidden => -0.5,
      };
      rated.add(e.id);
      for (final t in e.tags) {
        tags[t] = (tags[t] ?? 0) + w;
      }
      categories[e.category] = (categories[e.category] ?? 0) + w;
    }
    double clamp(double v) => (v * _step).clamp(-_cap, _cap);
    return Taste._(
      {for (final e in tags.entries) e.key: clamp(e.value)},
      {for (final e in categories.entries) e.key: clamp(e.value)},
      rated,
    );
  }

  bool get isEmpty => _tags.isEmpty && _categories.isEmpty;

  /// −1..1: 유사한 행사들에 부여된 평가. 태그 평균 60%, 카테고리 40%.
  double bias(RadarEvent e) {
    if (isEmpty) return 0;
    final tagAvg = e.tags.isEmpty ? 0.0 : e.tags.map((t) => _tags[t] ?? 0).reduce((a, b) => a + b) / e.tags.length;
    return (0.6 * tagAvg + 0.4 * (_categories[e.category] ?? 0)).clamp(-1.0, 1.0);
  }

  /// 관심사 적합도 (0..1) + 취향. 관심사에 전혀 맞지 않으면 0으로 남아 취향이 새로운
  /// 주제를 추가하지 않고 순서만 변경함. 평가된 event 자체는 자동으로 이동하지 않음.
  double score(RadarEvent e, Set<String> interests) {
    final fitsStage = stage?.fits(e) ?? false;
    final interest = e.tags.isEmpty ? 0.0 : e.tags.where(interests.contains).length / e.tags.length;
    if (interest == 0) return fitsStage && !rated.contains(e.id) ? _stageOnly : 0;
    if (rated.contains(e.id)) return interest;
    return (interest + bias(e) + (fitsStage ? _stageBoost : 0)).clamp(0.0, 1.0);
  }

  /// 인사이트 id에서 행사 id 추출: `nearby:<plan>:<event>`, `crowd:…`, `deadline:<event>`, `opportunity:<event>`.
  static String? eventIdOf(String insightId) {
    final kind = insightId.split(':').first;
    if (!const {'nearby', 'crowd', 'deadline', 'opportunity'}.contains(kind)) return null;
    return insightId.substring(insightId.lastIndexOf(':') + 1);
  }
}
