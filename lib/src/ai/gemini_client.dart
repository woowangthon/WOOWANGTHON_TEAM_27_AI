import 'dart:convert';

import 'package:http/http.dart' as http;

/// Gemini `generateContent` 호출. 기본 모델이 바쁘면 예비 모델로 넘어간다.
///
/// 프롬프트·스키마·검증은 [InsightWriter], [EventEnricher]에 있고, 이 클래스는 전송만 담당한다.
/// 앱(FE)과 수집 파이프라인(BE)이 같은 클라이언트를 사용한다.
class GeminiClient {
  GeminiClient({required String apiKey, http.Client? client, this.models = defaultModels, this.timeout = const Duration(seconds: 25)})
      : _key = apiKey,
        _client = client ?? http.Client();

  static const defaultModels = ['gemini-3.5-flash-lite', 'gemini-3.1-flash-lite'];

  final String _key;
  final http.Client _client;
  final List<String> models;
  final Duration timeout;

  bool get isConfigured => _key.isNotEmpty;

  /// 응답 JSON과 응답한 모델 이름. UI가 오래 기다리지 않도록 모델마다 한 번만 시도한다.
  Future<(Map<String, dynamic>, String)> generate(Map<String, dynamic> body) async {
    if (!isConfigured) throw const GeminiException('GEMINI_API_KEY missing');
    final payload = jsonEncode(body);
    Object? lastError;
    for (final model in models) {
      try {
        final res = await _client
            .post(
              // "AQ."로 시작하는 새 형식 키는 ?key= 쿼리로만 동작한다.
              Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent')
                  .replace(queryParameters: {'key': _key}),
              headers: {'Content-Type': 'application/json'},
              body: payload,
            )
            .timeout(timeout);
        if (res.statusCode == 200) {
          return (jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>, model);
        }
        lastError = 'HTTP ${res.statusCode} ($model)';
      } catch (e) {
        lastError = e;
      }
    }
    throw GeminiException('$lastError');
  }
}

class GeminiException implements Exception {
  const GeminiException(this.message);
  final String message;
  @override
  String toString() => 'GeminiException: $message';
}
