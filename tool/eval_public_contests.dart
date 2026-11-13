import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:liferadar_core/liferadar_core.dart';

/// Read-only live probe. Does not update app assets or publish any feed.
Future<void> main(List<String> args) async {
  final config = args.isEmpty
      ? <String, dynamic>{}
      : jsonDecode(File(args.first).readAsStringSync()) as Map<String, dynamic>;
  final client = http.Client();
  final geo = KakaoContestGeocoder(
    client,
    config['KAKAO_REST_API_KEY'] as String? ?? '',
  );
  final probes = {
    'contest-linkareer': (
      'https://linkareer.com/activity/363236',
      'SVC Seoul 주거생활 AI 해커톤',
    ),
    'contest-allforyoung': (
      'https://www.allforyoung.com/posts/89842',
      '전북 AI 뮤직쇼츠 공모전',
    ),
    'contest-thinkgood': (
      'https://www.thinkcontest.com/thinkgood/user/contest/view.do?contest_pk=112681',
      'KEIT 혁신 아이디어 공모전',
    ),
  };
  final results = <Map<String, dynamic>>[];
  try {
    for (final entry in probes.entries) {
      try {
        final source = entry.key;
        final list = await client
            .get(Uri.parse(PublicContestParser.lists[source]!))
            .timeout(const Duration(seconds: 25));
        if (list.statusCode != 200) {
          throw HttpException('List HTTP ${list.statusCode}');
        }
        final discovered = PublicContestParser.discover(
          source,
          utf8.decode(list.bodyBytes),
        );
        final url = Uri.parse(entry.value.$1);
        final res = await client.get(url).timeout(const Duration(seconds: 25));
        if (res.statusCode != 200) {
          throw HttpException('Detail HTTP ${res.statusCode}');
        }
        final rawFile = File('out/$source-detail.html');
        rawFile.parent.createSync(recursive: true);
        rawFile.writeAsBytesSync(res.bodyBytes);
        final facts = PublicContestParser.detail(
          source,
          ContestCandidate(url, entry.value.$2),
          utf8.decode(res.bodyBytes),
        );
        final venue = PublicContestParser.venue(facts);
        final place = venue == null ? null : await geo.call(venue);
        final events = PublicContestParser.events(
          source,
          facts,
          DateTime.now().toUtc(),
          place: place,
        );
        results.add({
          'source': source,
          'listCandidates': discovered.length,
          'eligibility': PublicContestParser.eligibility(facts),
          'venueQuery': venue,
          'sessions': PublicContestParser.sessions(facts)
              .map((s) => [s.$1.toIso8601String(), s.$2.toIso8601String()])
              .toList(),
          'events': events.map((e) => e.toJson()).toList(),
        });
        stdout.writeln(
          '$source: discovered=${discovered.length}, events=${events.length}, mapped=${events.where((e) => !e.placeless).length}',
        );
      } catch (e) {
        results.add({'source': entry.key, 'error': '$e'});
        stderr.writeln('${entry.key}: ${e.runtimeType}');
        exitCode = 1;
      }
    }
    final out = File('out/public-contest-live.json');
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'checkedAt': DateTime.now().toUtc().toIso8601String(), 'results': results})}\n',
    );
  } finally {
    client.close();
  }
}
