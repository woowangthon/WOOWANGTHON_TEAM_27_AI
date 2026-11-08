/// LifeRadar 핵심 모듈 — 도메인 모델, 판단 엔진, AI.
///
/// - 모델: 행사·일정·인사이트·교통 통제 ([RadarEvent], [Plan], [Insight], [TrafficNotice])
/// - 엔진 (결정론적 규칙): [InsightEngine], [RouteMatcher], [TrafficMatcher], [Taste]
/// - 교통 출처: [ItsTraffic] 국가교통정보센터 돌발상황 파서 (앱이 직접 조회)
/// - AI (Gemini): [InsightWriter] 카드 문장 + 근거 검증, [AiEnrich] 번역·태깅, [GeminiClient]
library;

export 'src/ai/event_enricher.dart';
export 'src/ai/gemini_client.dart';
export 'src/ai/insight_writer.dart';
export 'src/engine/insight_engine.dart';
export 'src/engine/route_matcher.dart';
export 'src/engine/taste.dart';
export 'src/engine/traffic_matcher.dart';
export 'src/models/models.dart';
export 'src/models/traffic.dart';
export 'src/sources/its_traffic.dart';
