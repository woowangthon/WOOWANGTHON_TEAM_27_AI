import 'models.dart';

/// 사용자의 지금 상황. 관심사와 별개로 "지금 나에게 필요한 것"의 순위를 조금 올린다.
///
/// 예: 학생 → 장학금·학생 프로그램, 구직 중 → 채용·네트워킹, 창업 → 창업 지원 공고.
/// 선택하지 않아도 앱은 동작한다 (null = 정보 없음).
enum LifeStage {
  student(
    LocalizedText(ko: '학생', en: 'Student'),
    {'student', 'career', 'language'},
    {EventCategory.scholarship, EventCategory.hackathon, EventCategory.contest},
  ),
  jobSeeker(LocalizedText(ko: '구직 중', en: 'Job seeking'), {'career', 'networking'}, {EventCategory.job}),
  employee(
    LocalizedText(ko: '직장인', en: 'Working'),
    {'networking', 'books', 'finance'},
    {EventCategory.conference, EventCategory.classes},
  ),
  founder(
    LocalizedText(ko: '창업·창업 준비', en: 'Founder'),
    {'startup', 'networking'},
    {EventCategory.startupSupport, EventCategory.meetup},
  ),
  freelancer(
    LocalizedText(ko: '프리랜서', en: 'Freelancer'),
    {'design', 'developer', 'networking'},
    {EventCategory.meetup, EventCategory.classes},
  ),
  other(LocalizedText(ko: '기타', en: 'Other'), {}, {});

  const LifeStage(this.label, this.tags, this.categories);

  final LocalizedText label;

  /// 이 상황에서 특히 도움이 되는 관심사 태그.
  final Set<String> tags;

  /// 이 상황에서 특히 도움이 되는 행사 종류.
  final Set<EventCategory> categories;

  /// 행사가 이 상황에 맞는지.
  bool fits(RadarEvent e) => !(this == LifeStage.student && e.isApplication && (e.audience == 'restricted' || e.audience == 'unknown')) && (categories.contains(e.category) || e.tags.any(tags.contains));

  static LifeStage? byName(String? name) => name == null ? null : values.asNameMap()[name];
}
