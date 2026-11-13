import 'dart:convert';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liferadar_core/liferadar_core.dart';
import 'package:test/test.dart';

const source = 'contest-linkareer';
final now = DateTime.utc(2026, 11, 13);
final candidate = ContestCandidate(
  Uri.parse('https://linkareer.com/activity/42'),
  '한빛 해커톤',
);
String linkDetail({String? body, int closeHour = 23}) =>
    '<script id="__NEXT_DATA__" type="application/json">${jsonEncode({
      'props': {
        'pageProps': {
          '__APOLLO_STATE__': {
            'Activity:42': {
              'type': 3,
              'title': '한빛 AI 해커톤',
              'organizationName': '한빛 운영국',
              'recruitStartAt': DateTime.utc(2026, 11, 1, 0).millisecondsSinceEpoch,
              'recruitCloseAt': DateTime.utc(2026, 11, 29, closeHour - 9, 59).millisecondsSinceEpoch,
              'detailText': {'__ref': 'ActivityText:7'},
              'status': 'OPEN',
            },
            'ActivityText:7': {'text': body ?? '<p>참가대상: 대학 재학생 및 휴학생, 팀 2~4명</p>'
                    '<p>■ 행사 기간 및 장소</p><p>기간: 2026.12.7 ~ 2026.12.11</p>'
                    '<p>대면 장소: 한빛컨벤션센터 지하 1층</p><p>운영: 대면과 온라인 병행</p>'
                    '<p>12.7: 대면 프로그램</p><p>12.8 ~ 12.10: 온라인 활동</p><p>12.11: 대면 최종 발표</p>'},
          },
        },
      },
    })}</script>';
String listHtml([String host = 'linkareer.com']) =>
    '<script type="application/ld+json">${jsonEncode({
      '@type': 'ItemList',
      'itemListElement': [
        {'@type': 'ListItem', 'name': '한빛 공모전', 'url': 'https://$host/activity/42'},
      ],
    })}</script>';

void main() {
  test('public activity separates reception and hybrid physical dates', () {
    final f = PublicContestParser.detail(source, candidate, linkDetail());
    expect(PublicContestParser.eligibility(f), contains('팀 2~4명'));
    expect(PublicContestParser.sessions(f), [
      (DateTime(2026, 12, 7), DateTime(2026, 12, 7)),
      (DateTime(2026, 12, 11), DateTime(2026, 12, 11)),
    ]);
    final events = PublicContestParser.events(
      source,
      f,
      now,
      place: const ContestVenue(
        '한빛컨벤션센터',
        '서울 마포구 한빛로 10',
        GeoPoint(37.55, 126.92),
      ),
    );
    expect(events, hasLength(2));
    expect(events.every((e) => !e.placeless), isTrue);
    expect(events.every((e) => e.applicationStatusAt(now) == 'open'), isTrue);
    expect(events.map((e) => e.id).toSet(), hasLength(2));
    expect(PublicContestParser.events(source, f, now).single.placeless, isTrue);
  });
  test(
    'explicit closing hour retained; no venue/date inferred from organizer',
    () {
      final f = PublicContestParser.detail(
        source,
        candidate,
        linkDetail(
          closeHour: 18,
          body: '<p>참가자격: 국민 누구나</p><p>주최 주소: 서울시청</p>',
        ),
      );
      expect(f.deadlinePrecision, 'datetime');
      expect(f.deadline.hour, 9);
      final e = PublicContestParser.events(source, f, now).single;
      expect(e.placeless, isTrue);
      expect(e.location.lat, 0);
      expect(PublicContestParser.venue(f), isNull);
    },
  );
  test(
    'public post Flight handles UTF8 byte-delimited text before adjacent JSON across frames',
    () {
      const text = '공고 본문\n안내';
      final post = {
        'id': 77,
        'category': '공모전',
        'title': '한빛 영상 공모전',
        'organization': '한빛기관',
        'start_date': '2026-11-02',
        'end_at': '2026-11-19',
        'content': {
          'type': 'doc',
          'content': [
            {
              'type': 'paragraph',
              'content': [
                {'type': 'text', 'text': '■ 지원 자격'},
              ],
            },
            {
              'type': 'paragraph',
              'content': [
                {'type': 'text', 'text': '누구나 참여 가능'},
              ],
            },
          ],
        },
      };
      final stream =
          '4:T${utf8.encode(text).length.toRadixString(16)},${text}5:${jsonEncode({
            'state': {'data': post},
          })}\n';
      final split = stream.length ~/ 2;
      String frame(String s) =>
          '<script>self.__next_f.push(${jsonEncode([1, s])})</script>';
      final raw =
          frame(stream.substring(0, split)) + frame(stream.substring(split));
      expect(
        PublicContestParser.flightMaps(
          html.parse(raw),
        ).any((m) => m['id'] == 77),
        isTrue,
      );
      final f = PublicContestParser.detail(
        'contest-allforyoung',
        ContestCandidate(
          Uri.parse('https://www.allforyoung.com/posts/77'),
          'fallback',
        ),
        raw,
      );
      expect(f.title, '한빛 영상 공모전');
      expect(PublicContestParser.eligibility(f), '누구나 참여 가능');
      expect(
        PublicContestParser.discover(
          'contest-allforyoung',
          raw,
        ).single.url.path,
        '/posts/77',
      );
    },
  );
  test(
    'Thinkgood uses body and reception DOM; site publisher address is ignored',
    () {
      final f = PublicContestParser.detail(
        'contest-thinkgood',
        ContestCandidate(
          Uri.parse(
            'https://thinkcontest.com/thinkgood/user/contest/view.do?contest_pk=2',
          ),
          '한빛 대회',
        ),
        '<div><div class="tit">주최</div><div class="txt">한빛기관</div></div>'
            '<div><div class="tit">접수기간</div><div class="txt">2026-11-04 00:00 ~ 2026-11-17 18:00</div></div>'
            '<div id="contest_content"><p>응모자격: 대한민국 국민 누구나</p></div>'
            '<footer>장소: 사이트 운영회사 주소</footer>',
      );
      expect(f.deadline, DateTime.utc(2026, 11, 17, 9));
      expect(PublicContestParser.venue(f), isNull);
    },
  );
  test(
    'discovery rejects lookalike host, untrusted links and empty changed markup',
    () {
      expect(
        PublicContestParser.discover(source, listHtml()).single.url.host,
        'linkareer.com',
      );
      for (final value in [
        'https://linkareer.com.evil.test/activity/42',
        'http://linkareer.com/activity/42',
        'https://x@linkareer.com/activity/42',
      ]) {
        expect(PublicContestParser.detailUrl(source, value), isNull);
      }
      expect(
        () => PublicContestParser.discover(source, listHtml('evil.test')),
        throwsFormatException,
      );
      expect(
        () => PublicContestParser.discover(source, '<html>login</html>'),
        throwsFormatException,
      );
    },
  );
  test(
    'partial detail failure preserves previous URL and 403 stops further requests',
    () async {
      var details = 0;
      final list =
          '<script type="application/ld+json">${jsonEncode({
            '@type': 'ItemList',
            'itemListElement': [
              for (final id in [42, 43]) {'@type': 'ListItem', 'name': '공모전', 'url': 'https://linkareer.com/activity/$id'},
            ],
          })}</script>';
      final collector = PublicContestCollector(
        MockClient((r) async {
          if (r.url.path == '/list/contest') return http.Response.bytes(utf8.encode(list), 200);
          details++;
          return http.Response('blocked', 403);
        }),
        sleep: (_) async {},
      );
      final report = await collector.collect(source, now);
      expect(details, 1);
      expect(report.complete, isFalse);
      expect(report.replacedUrls, isEmpty);
    },
  );
  test(
    'geocoder refuses ambiguous matches and region-only locations',
    () async {
      var calls = 0;
      final geo = KakaoContestGeocoder(
        MockClient((_) async {
          calls++;
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'documents': [
                for (var i = 0; i < 2; i++)
                  {
                    'place_name': '한빛센터',
                    'x': '126.92',
                    'y': '37.55',
                    'address_name': '서울 마포구',
                  },
              ],
            })),
            200,
          );
        }),
        'test-key',
      );
      expect(await geo.call('서울'), isNull);
      expect(calls, 0);
      expect(await geo.call('한빛센터'), isNull);
      expect(calls, 1);
    },
  );
}
