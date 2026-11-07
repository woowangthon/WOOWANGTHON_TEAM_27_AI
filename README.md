# LifeRadar AI — 판단 엔진과 AI 모듈

> **WOOWANGTHON TEAM 27** · 2026 AI 우왕톤 · 주제 *"AI는 동료가 될 수 있을까?"*
>
> 저장소: [FE (Flutter 앱)](https://github.com/woowangthon/WOOWANGTHON_TEAM_27_FE) · [BE (데이터 파이프라인)](https://github.com/woowangthon/WOOWANGTHON_TEAM_27_BE) · **AI (이 저장소)**

**LifeRadar는 내 일정을 챙기는 AI 동료입니다.** 캘린더 일정과 관심사를 실제 행사·교통 통제·날씨와 연결해 "왜 나에게 중요한지"를 먼저 알려주고, 갈지·캘린더에 넣을지는 사용자가 결정합니다.

이 저장소는 그 판단을 내리는 **핵심 모듈(`liferadar_core`, 순수 Dart 패키지)** 입니다. 앱(FE)과 수집 파이프라인(BE)이 같은 코드를 git 의존성으로 사용합니다.

## 핵심 원칙: AI가 사실을 만들지 않게

동료가 믿을 만하려면 틀린 날짜나 없는 행사를 말하면 안 됩니다. 그래서 역할을 나눴습니다.

```
 공공 API 원본 사실 ──▶  규칙 엔진 (코드)  ──▶  Gemini (언어만)  ──▶  검증 (코드)  ──▶  카드
 날짜·장소·요금·링크      무엇을 보여줄지 결정     이유를 자연어로 설명    숫자·언어·형식 확인     통과 못 하면
                         (결정론적, 테스트됨)     (구조화 JSON 응답)     실패 시 규칙 문장 유지   규칙 문장 그대로
```

| 단계 | 담당 | 하는 일 | 하지 않는 일 |
|---|---|---|---|
| 사실 | 공공 API (BE가 수집) | 행사 날짜·장소·요금·신청 링크, 공식 통제 시간 | — |
| 판단 | **규칙 엔진** (`InsightEngine`, `RouteMatcher`, `TrafficMatcher`, `Taste`) | 어떤 일정과 어떤 행사를 연결할지, 거리·기간·점수·순서 | AI 호출 없음 |
| 설명 | **Gemini** (`InsightWriter`) | 엔진이 고른 사실로 "왜 나에게 중요한지"를 한국어·영어로 작성 | 행사 선택, 숫자 생성, 알림 결정 |
| 번역 | **Gemini** (`AiEnrich`, BE에서 실행) | 한국어 행사명·설명 → 영어, 허용된 26개 관심사 태그 선택 | 날짜·장소·요금 변경 |
| 검증 | **코드** | 응답의 숫자가 입력 사실에 있는지, 한국어 문장이 한국어인지, id·형식이 맞는지 | — |

## AI 활용 상세

### 1. 카드 설명 문장 — `InsightWriter`
- **입력**: 카드 하나당 사실 묶음(JSON) — 일정 제목·장소·날짜, 행사 이름·소개·장소·마감, 일치하는 관심사, 규칙 문장.
- **출력**: `responseSchema`로 강제한 JSON `{id, body_ko, body_en, why_ko, why_en}`.
- **검증** (`parseResponse`, `isGrounded`):
  - 문장 속 **모든 숫자가 입력 사실에 존재**해야 한다 → 지어낸 가격·거리·날짜 차단
  - 한국어 문장에 한글이 있어야 하고, 길이 제한(320자), 알 수 없는 id·깨진 JSON은 버린다
  - 통과하지 못한 카드는 **규칙 문장을 그대로** 보여준다 (AI가 틀려도 카드는 틀리지 않음)
- **AI 대상 제한** (`isEligible`): 공식 교통 통제 카드와 혼잡 참고 카드는 AI가 다시 쓰지 않는다 (아래 평가 참고).
- **비용·속도**: 상위 6개 카드만, 사실이 같으면 다시 요청하지 않도록 캐시 키(`cacheKey`) 사용. 캐시 키는 32비트 연산 FNV-1a 두 개로 만들어 **웹(JS)과 Android에서 같은 값**이 나온다 (테스트로 고정).

### 2. 행사 번역·태깅 — `AiEnrich`
- 서울시 문화행사 데이터에는 영어 제목이 없어, 수집 단계에서 Gemini가 영어 이름·설명과 관심사 태그를 만든다.
- 태그는 **허용 목록(enum)** 안에서만, 카테고리의 기준 태그는 모델이 빠뜨려도 유지한다.
- **품질 검사**: 일본어 가나·한자가 섞였거나 번역되지 않은(한글 비율이 높은) 응답은 거부하고 다시 요청한다.
- 결과는 원문 해시로 캐시해 **새 행사만** 요청한다 (실제 운영: 635건 중 하루 신규 약 15건).

### 3. 전송 — `GeminiClient`
- 기본 모델이 실패(할당량·과부하)하면 예비 모델로 넘어간다. 모델마다 1회만 시도해 UI가 오래 기다리지 않는다.

## 실측 평가 (실제 Gemini API)

`tool/eval_insight_writer.dart` — 시연 시나리오의 규칙 카드를 실제 Gemini로 다시 쓰고 검증 결과를 비교한다.

```bash
GEMINI_API_KEY=... dart run tool/eval_insight_writer.dart --date=2026-11-07
```

**2026-11-08 실행 결과**: `gemini-3.1-flash-lite`(기본 모델 할당량 초과로 예비 모델 응답), 약 5.1초, **검증 통과 6/6**.

| 카드 | 규칙 문장 | AI 문장 |
|---|---|---|
| 마감: 대전 AI 세미나 | 관심사(#ai)와 맞는 행사이며, 마감을 놓치면 참가할 수 없습니다. | 평소 AI 분야에 관심이 많으셔서 이번 세미나가 유익한 기회가 될 것입니다. |
| 근처: 벡스코 AI 엑스포 | 관심사(#ai #startup)와 맞고, 이미 그 지역에 계실 예정입니다. | 여행 일정 중에 관심 분야인 AI와 스타트업 행사가 가까운 곳에서 열려 방문하기 좋습니다. |
| 기회: 서울 푸드 페스티벌 | 관심사(#food #culture)와 일치합니다. | 평소 음식과 문화에 관심이 많으셔서 이번 페스티벌이 즐거운 시간이 될 것입니다. |

**평가에서 발견한 한계와 조치**
- 혼잡 참고 카드(근처 대형 행사)에서 모델이 *"이동 경로에 영향을 줄 수 있습니다"* 라는 **확인되지 않은 교통 영향**을 덧붙였다. 문장에 숫자가 없어 숫자 검증을 통과했다.
- 우리 판별 규칙은 *"행사 개최 사실만으로 이동 영향을 판정하지 않는다"* 이므로, 이 카드와 공식 교통 통제 카드는 **AI 대상에서 제외**했다 (`InsightWriter.isEligible`, 테스트 포함).
- 남은 한계: 숫자 검증은 정성적인 과장(예: "꼭 가야 할")을 막지 못한다. 그래서 AI는 사실을 고르지 않고, 문장 길이와 대상 카드를 제한하며, 모든 카드에 출처와 ✨ AI 표시를 붙인다.

## 판단 엔진 (결정론적 규칙)

| 모듈 | 역할 | 핵심 규칙 |
|---|---|---|
| `InsightEngine` | 일정 × 행사 × 날씨 × 관심사 → 카드 | 일정 기간·15 km 이내 행사, 신청 마감 14일 이내, 일정 날 비 예보, 일정과 무관한 관심 행사. 일정마다 카드 수 제한, 같은 행사 중복 없음, id 고정(피드백 유지) |
| `RouteMatcher` | 출발→도착 경로 주변 기회 | 폴리라인 단순화(2500→~400점) → 같은 날짜 + 경로 15 km 회랑 → 점수 = 관심사 60% + 가까움 40%. 대중교통은 가장 가까운 역에서의 투영점으로 우회 거리 계산 |
| `TrafficMatcher` | 공식 교통 통제 × 일정 | 팀 문서 「집회·마라톤·축제 이동 영향 판별 로직」 §6~§9: 반열린 구간 `[start, end)`, 일정 전 2시간 탐지 구간, 1 km 인근, 종료 미상은 시작 날짜에만, 이동수단 미확인이면 최대 `CAUTION` |
| `Taste` | 👍/👎/숨기기 → 취향 | 평가한 행사의 태그·카테고리에 ±0.4 가중치 → 비슷한 행사의 점수 이동. 관심사 밖의 주제는 추가하지 않음, 평가한 카드 자체는 그대로(취소 가능) |
| `demo` | 시연 시나리오 | 부산 출장·대전 세미나 등 `샘플` 데이터. 날짜가 지나면 주 단위로 자동 이동해 시연이 낡지 않음 |

## 구조

```
lib/
├── liferadar_core.dart        # 공개 API
├── demo.dart                  # 시연 시나리오
└── src/
    ├── models/                # RadarEvent, Plan, Insight, TrafficNotice …
    ├── engine/                # InsightEngine, RouteMatcher, TrafficMatcher, Taste
    ├── ai/                    # InsightWriter, AiEnrich, GeminiClient
    └── demo/                  # 시나리오 데이터
test/                          # 41개 테스트
tool/eval_insight_writer.dart  # 실제 API 평가
```

## 사용

```yaml
# pubspec.yaml (FE, BE)
dependencies:
  liferadar_core:
    git:
      url: https://github.com/woowangthon/WOOWANGTHON_TEAM_27_AI.git
      ref: main
```

```dart
import 'package:liferadar_core/liferadar_core.dart';

final cards = const InsightEngine().build(plans: plans, events: events, interests: {'ai'}, now: DateTime.now());
final eligible = cards.where(InsightWriter.isEligible).take(6).toList();
final facts = {for (final c in eligible) c.id: InsightWriter.facts(c, today: today)};
final (json, model) = await GeminiClient(apiKey: key).generate(InsightWriter.requestBody([...facts.values]));
final written = InsightWriter.parseResponse(json, factsById: facts, model: model); // 검증 통과분만
```

## 테스트

```bash
dart pub get
dart analyze --fatal-infos
dart test
```

41개 테스트 (GitHub Actions CI): 인사이트 규칙, 경로 회랑·투영, 교통 판별 사례(D02·D03·D06·D07·D14), 취향 재정렬, AI 응답 검증(지어낸 숫자 거부, 깨진 JSON, 언어), 캐시 키 웹/VM 일치, Gemini 예비 모델 전환, 시연 날짜 이동.

## 직접 구현 범위와 외부 기술

- **직접 구현**: 모든 모델, 규칙 엔진, 프롬프트와 JSON 스키마, 응답 검증, 캐시, 평가 도구, 테스트.
- **외부 기술**: Google Gemini API (`gemini-3.5-flash-lite`, 예비 `gemini-3.1-flash-lite`), Dart `http`.
- **개발 도구**: 개발 과정에서 AI 코딩 도우미(Claude)를 사용했으며 커밋에 공동 작성자로 표시했습니다.

## 미적용·미검증

- 사람이 직접 라벨링한 정답셋으로 AI 문장 품질을 정량 평가하지는 않았다 (위 평가는 시나리오 6개 카드 기준).
- 뉴스 기사(파업·집회) 추출은 판별 규칙만 설계되어 있고 구현하지 않았다.
- `TrafficMatcher`의 경로 단위 `ROUTE_MATCH`와 `RECOMMEND`는 이동수단 정보가 필요해 다음 단계로 남겼다.

## 개발 기록

2026-11-05 개인 작업 저장소에서 개발을 시작해 2026-11-08 팀 저장소로 이전했습니다. 이후 작업은 이 저장소에서 이어집니다.
