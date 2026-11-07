/// LifeRadar 핵심 모듈 — 도메인 모델, 판단 엔진, AI.
///
/// - 모델: 행사·일정·인사이트·교통 통제 ([RadarEvent], [Plan], [Insight], [TrafficNotice])
/// - 엔진 (결정론적 규칙): [InsightEngine], [RouteMatcher], [TrafficMatcher], [Taste]
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
