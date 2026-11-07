import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liferadar_core/liferadar_core.dart';
import 'package:test/test.dart';

void main() {
  test('키가 없으면 호출하지 않고 예외', () async {
    final c = GeminiClient(apiKey: '');
    expect(c.isConfigured, isFalse);
    await expectLater(c.generate({}), throwsA(isA<GeminiException>()));
  });

  test('기본 모델이 실패하면 예비 모델로 넘어가고, 응답한 모델 이름을 돌려준다', () async {
    final called = <String>[];
    final c = GeminiClient(
      apiKey: 'k',
      client: MockClient((r) async {
        called.add(r.url.pathSegments.last);
        expect(r.url.queryParameters['key'], 'k'); // 새 형식 키는 쿼리로 전달
        return called.length == 1
            ? http.Response('busy', 429)
            : http.Response(jsonEncode({'candidates': []}), 200);
      }),
    );
    final (_, model) = await c.generate({'contents': []});
    expect(called, hasLength(2));
    expect(model, GeminiClient.defaultModels[1]);
  });

  test('모든 모델이 실패하면 GeminiException', () async {
    final c = GeminiClient(apiKey: 'k', client: MockClient((_) async => http.Response('down', 503)));
    await expectLater(c.generate({}), throwsA(isA<GeminiException>()));
  });
}
