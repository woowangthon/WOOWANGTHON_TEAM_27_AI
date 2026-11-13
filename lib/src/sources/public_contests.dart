import 'dart:convert';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import '../models/models.dart';

class ContestCandidate {
  const ContestCandidate(this.url, this.title);
  final Uri url;
  final String title;
}

class ContestVenue {
  const ContestVenue(this.name, this.address, this.location);
  final String name, address;
  final GeoPoint location;
}

class ContestFacts {
  const ContestFacts({
    required this.id,
    required this.url,
    required this.title,
    required this.organizer,
    required this.applicationStart,
    required this.deadline,
    required this.lines,
    this.registerUrl,
    this.cancelled = false,
    this.deadlinePrecision = 'date',
  });
  final String id, url, title, organizer;
  final DateTime applicationStart, deadline;
  final List<String> lines;
  final String? registerUrl;
  final bool cancelled;
  final String deadlinePrecision;
}

/// Reads only data shipped to the public, logged-out web page. No private API,
/// authentication, browser impersonation, or access-control bypass.
class PublicContestParser {
  static const lists = {
    'contest-linkareer': 'https://linkareer.com/list/contest',
    'contest-allforyoung': 'https://www.allforyoung.com/posts/contest',
    'contest-thinkgood':
        'https://www.thinkcontest.com/thinkgood/user/contest/index.do',
  };
  static String clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
  static String _s(Object? v) => v is String ? v.trim() : '';
  static Uri? detailUrl(String source, String value) {
    final u = Uri.tryParse(value);
    if (u == null || u.scheme != 'https' || u.userInfo.isNotEmpty) return null;
    final host = u.host.replaceFirst('www.', '');
    final valid = switch (source) {
      'contest-linkareer' =>
        host == 'linkareer.com' && RegExp(r'^/activity/\d+$').hasMatch(u.path),
      'contest-allforyoung' =>
        host == 'allforyoung.com' && RegExp(r'^/posts/\d+$').hasMatch(u.path),
      'contest-thinkgood' =>
        host == 'thinkcontest.com' &&
            u.path == '/thinkgood/user/contest/view.do' &&
            RegExp(r'^\d+$').hasMatch(u.queryParameters['contest_pk'] ?? ''),
      _ => false,
    };
    if (!valid) return null;
    final base = Uri.parse(lists[source]!);
    return Uri(
      scheme: 'https',
      host: base.host,
      path: u.path,
      queryParameters: source == 'contest-thinkgood'
          ? {'contest_pk': u.queryParameters['contest_pk']!}
          : null,
    );
  }

  static Iterable<Map<String, dynamic>> _maps(
    Object? v, [
    int depth = 0,
  ]) sync* {
    if (depth > 80) return;
    if (v is Map<String, dynamic>) {
      yield v;
      for (final child in v.values) {
        yield* _maps(child, depth + 1);
      }
    } else if (v is List) {
      for (final child in v) {
        yield* _maps(child, depth + 1);
      }
    }
  }

  /// React Flight is read as JSON records, never evaluated as JavaScript.
  static Iterable<Map<String, dynamic>> flightMaps(Document doc) sync* {
    final buffer = StringBuffer();
    for (final script in doc.querySelectorAll('script')) {
      final s = script.text.trim();
      const prefix = 'self.__next_f.push(';
      if (!s.startsWith(prefix)) continue;
      final end = s.lastIndexOf(')');
      if (end < prefix.length) continue;
      try {
        final frame = jsonDecode(s.substring(prefix.length, end)) as List;
        if (frame.length > 1 && frame[0] == 1 && frame[1] is String) {
          buffer.write(frame[1]);
        }
      } catch (_) {
        /* unknown frame is not interpreted */
      }
    }
    // Flight T records are UTF-8-byte-length-delimited and can contain newlines
    // or immediately precede a JSON record. Splitting the whole stream by LF
    // loses that JSON record (observed on allforyoung's public detail pages).
    final bytes = utf8.encode(buffer.toString());
    var offset = 0;
    while (offset < bytes.length) {
      if (bytes[offset] == 10) {
        offset++;
        continue;
      }
      var colon = offset;
      while (colon < bytes.length &&
          bytes[colon] != 58 &&
          colon - offset < 24) {
        colon++;
      }
      if (colon >= bytes.length || bytes[colon] != 58) break;
      final start = colon + 1;
      if (start < bytes.length && bytes[start] == 84) {
        var comma = start + 1;
        while (comma < bytes.length &&
            bytes[comma] != 44 &&
            comma - start < 12) {
          comma++;
        }
        if (comma >= bytes.length || bytes[comma] != 44) break;
        final length = int.tryParse(
          ascii.decode(bytes.sublist(start + 1, comma)),
          radix: 16,
        );
        if (length == null || length < 0 || comma + 1 + length > bytes.length) {
          break;
        }
        offset = comma + 1 + length;
        continue;
      }
      var end = start;
      while (end < bytes.length && bytes[end] != 10) {
        end++;
      }
      final payload = utf8.decode(bytes.sublist(start, end));
      if (payload.startsWith('{') || payload.startsWith('[')) {
        try {
          yield* _maps(jsonDecode(payload));
        } catch (_) {
          /* non-JSON record */
        }
      }
      offset = end + 1;
    }
  }

  static List<ContestCandidate> discover(String source, String raw) {
    final doc = html.parse(raw);
    final result = <String, ContestCandidate>{};
    void add(String? url, String title) {
      final u = detailUrl(source, url ?? '');
      if (u != null && title.trim().isNotEmpty) {
        result[u.toString()] = ContestCandidate(u, clean(title));
      }
    }

    for (final script in doc.querySelectorAll(
      'script[type="application/ld+json"]',
    )) {
      try {
        for (final m in _maps(jsonDecode(script.text))) {
          if (m['@type'] == 'ListItem') add(m['url'] as String?, _s(m['name']));
        }
      } catch (_) {
        /* other structured data may be malformed */
      }
    }
    if (source == 'contest-allforyoung') {
      for (final m in flightMaps(doc)) {
        if (m['category'] == '공모전' && m['id'] is num && m['title'] is String) {
          add(
            'https://www.allforyoung.com/posts/${m['id']}',
            m['title'] as String,
          );
        }
      }
    }
    if (source == 'contest-thinkgood') {
      for (final e in doc.querySelectorAll(
        '[data-contest_pk][data-reg_type="contest"]',
      )) {
        add(
          'https://www.thinkcontest.com/thinkgood/user/contest/view.do?contest_pk=${e.attributes['data-contest_pk']}',
          e.text,
        );
      }
    }
    if (result.isEmpty) {
      throw FormatException('No public contest list records: $source');
    }
    return result.values.toList();
  }

  static List<String> htmlLines(String raw) {
    final doc = html.parse(
      raw
          .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
          .replaceAll(
            RegExp(r'</(?:p|div|li|tr|h[1-6])\s*>', caseSensitive: false),
            '\n',
          ),
    );
    for (final e in doc.querySelectorAll('script,style')) {
      e.remove();
    }
    return (doc.body?.text ?? '')
        .split('\n')
        .map(clean)
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static void _richLines(Object? value, List<String> lines) {
    if (value is! Map) return;
    final text = StringBuffer();
    void visit(Object? node) {
      if (node is! Map) return;
      if (node['type'] == 'text') text.write(_s(node['text']));
      if (node['type'] == 'hardBreak') text.write('\n');
      for (final c in node['content'] as List? ?? const []) {
        visit(c);
      }
      if (['paragraph', 'heading', 'listItem'].contains(node['type'])) {
        text.write('\n');
      }
    }

    visit(value);
    lines.addAll(
      text.toString().split('\n').map(clean).where((s) => s.isNotEmpty),
    );
  }

  static DateTime _civilMillis(Object? value) {
    if (value is! num) throw FormatException('Missing recruitment timestamp');
    final d = DateTime.fromMillisecondsSinceEpoch(
      value.toInt(),
      isUtc: true,
    ).add(const Duration(hours: 9));
    return DateTime(d.year, d.month, d.day);
  }

  static DateTime _civil(String s) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:$|[ T])').firstMatch(s);
    if (m == null) throw FormatException('Invalid reception date');
    final d = DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    if (d.year != int.parse(m[1]!) ||
        d.month != int.parse(m[2]!) ||
        d.day != int.parse(m[3]!)) {
      throw FormatException('Invalid reception date');
    }
    return d;
  }

  static ContestFacts detail(
    String source,
    ContestCandidate candidate,
    String raw,
  ) {
    final u = detailUrl(source, candidate.url.toString());
    if (u == null) throw FormatException('Untrusted detail URL');
    final doc = html.parse(raw);
    late String id, title, organizer;
    late DateTime begin, deadline;
    String? register;
    var lines = <String>[];
    var cancelled = false;
    var precision = 'date';
    if (source == 'contest-linkareer') {
      final script = doc.querySelector('script#__NEXT_DATA__');
      if (script == null) throw FormatException('Missing public activity data');
      final data = jsonDecode(script.text) as Map;
      final ap = (data['props'] as Map)['pageProps']['__APOLLO_STATE__'] as Map;
      id = u.pathSegments.last;
      final activity = ap['Activity:$id'] as Map;
      if (activity['type'] != 3) throw FormatException('Not a contest');
      title = _s(activity['title']);
      organizer = _s(activity['organizationName']);
      begin = _civilMillis(activity['recruitStartAt']);
      deadline = _civilMillis(activity['recruitCloseAt']);
      final close = DateTime.fromMillisecondsSinceEpoch(
        (activity['recruitCloseAt'] as num).toInt(),
        isUtc: true,
      );
      final closeKst = close.add(const Duration(hours: 9));
      if (closeKst.hour != 23 || closeKst.minute != 59) {
        deadline = close;
        precision = 'datetime';
      }
      final ref = (activity['detailText'] as Map)['__ref'];
      lines = htmlLines(_s((ap[ref] as Map)['text']));
      cancelled = activity['status'] == 'CANCELLED';
      // Homepage is not necessarily an application form. Keep it as source only.
    } else if (source == 'contest-allforyoung') {
      id = u.pathSegments.last;
      final item = flightMaps(doc)
          .where(
            (m) =>
                '${m['id']}' == id &&
                m['content'] is Map &&
                m.containsKey('start_date'),
          )
          .firstOrNull;
      if (item == null) throw FormatException('Missing public post data');
      title = _s(item['title']);
      organizer = _s(item['organization']);
      begin = _civil(_s(item['start_date']));
      deadline = _civil(_s(item['end_at']));
      if (_s(item['end_at']).contains('T')) {
        final value = _s(item['end_at']);
        deadline = DateTime.parse(
          RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(value)
              ? value
              : '$value+09:00',
        ).toUtc();
        precision = 'datetime';
      }
      _richLines(item['content'], lines);
      register = _s(item['apply_url']);
    } else if (source == 'contest-thinkgood') {
      id = u.queryParameters['contest_pk']!;
      String fact(String label) {
        for (final e in doc.querySelectorAll('.tit')) {
          if (clean(e.text) == label) {
            return clean(e.parent?.querySelector('.txt')?.text ?? '');
          }
        }
        return '';
      }

      title = candidate.title;
      organizer = fact('주최');
      final days = RegExp(
        r'\d{4}-\d{2}-\d{2}',
      ).allMatches(fact('접수기간')).map((m) => m[0]!).toList();
      if (days.length != 2) throw FormatException('Unclear reception interval');
      begin = _civil(days.first);
      deadline = _civil(days.last);
      final timed = RegExp(
        r'(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})',
      ).allMatches(fact('접수기간')).toList();
      if (timed.length == 2) {
        deadline = DateTime.parse(
          '${timed.last[1]}T${timed.last[2]}:00+09:00',
        ).toUtc();
        precision = 'datetime';
      }
      final body = doc.querySelector('#contest_content');
      if (body == null) throw FormatException('Missing public contest body');
      lines = htmlLines(body.innerHtml);
    } else {
      throw FormatException('Unknown contest source');
    }
    if (title.isEmpty ||
        organizer.isEmpty ||
        lines.isEmpty ||
        deadline.isBefore(begin)) {
      throw FormatException('Incomplete contest facts');
    }
    final ru = Uri.tryParse(register ?? '');
    return ContestFacts(
      id: id,
      url: u.toString(),
      title: title,
      organizer: organizer,
      applicationStart: begin,
      deadline: deadline,
      lines: lines,
      cancelled: cancelled,
      deadlinePrecision: precision,
      registerUrl: ru?.scheme == 'https' && ru!.host.isNotEmpty
          ? ru.toString()
          : null,
    );
  }

  static String? eligibility(ContestFacts f) {
    for (final line in f.lines) {
      final m = RegExp(
        r'(?:(?:참가|참여|응모|지원|모집)\s*(?:대상|자격)|(?:^|[•·●■\s])대상)\s*[:：]\s*(.+)',
      ).firstMatch(line);
      if (m != null && m[1]!.length >= 3 && m[1]!.length < 350) {
        return m[1]!.trim();
      }
    }
    for (var i = 0; i < f.lines.length; i++) {
      final line = f.lines[i];
      final m = RegExp(
        r'(?:참가|참여|응모|지원|모집)\s*(?:대상|자격)|(?:^|[•·●■\s])대상\s*[:：]',
      ).firstMatch(line);
      if (m == null) continue;
      final rest = line
          .substring(m.end)
          .replaceFirst(RegExp(r'^[\s:：]+'), '')
          .trim();
      if (rest.length >= 3 &&
          rest.length < 350 &&
          !RegExp(r'^(?:및|규모)').hasMatch(rest)) {
        return rest;
      }
      if (i + 1 < f.lines.length) {
        final next = f.lines[i + 1].replaceFirst(RegExp(r'^[•·●\s]+'), '');
        if (next.length >= 3 && next.length < 350 && !next.startsWith('■')) {
          return next;
        }
      }
    }
    return null;
  }

  /// Only explicit onsite sessions are eligible. A hybrid interval never
  /// becomes a continuous physical event across its online days.
  static List<(DateTime, DateTime)> sessions(ContestFacts f) {
    final hybrid =
        f.lines.any((s) => s.contains('온라인')) &&
        f.lines.any((s) => RegExp('대면|오프라인').hasMatch(s));
    final result = <(DateTime, DateTime)>[];
    int? scheduleYear;
    var section = false;
    for (final line in f.lines) {
      if (RegExp(r'^[■●]').hasMatch(line)) {
        section =
            RegExp('행사|대회|일시|기간.*장소').hasMatch(line) &&
            !RegExp('모집|접수').hasMatch(line);
      }
      if (RegExp('접수|모집|결과.*발표|심사기간').hasMatch(line)) continue;
      final explicitYear = RegExp(r'(20\d{2})\s*[년./-]').firstMatch(line);
      final onsite = RegExp('대면|오프라인|현장|본선|대회s*일시|행사s*일시').hasMatch(line);
      if ((section || onsite || line.contains('일시')) && explicitYear != null) {
        scheduleYear = int.parse(explicitYear[1]!);
      }
      if (scheduleYear == null ||
          (hybrid ? !onsite : !(onsite || section || line.contains('일시')))) {
        continue;
      }
      if (line.contains('온라인') && !onsite) continue;
      final dates = <DateTime>[];
      final re = RegExp(
        r'(?:(20\d{2})\s*[년./-]\s*)?(\d{1,2})\s*[월./-]\s*(\d{1,2})\s*일?',
      );
      for (final m in re.allMatches(line)) {
        final year = int.parse(m[1] ?? '$scheduleYear');
        final month = int.parse(m[2]!);
        final day = int.parse(m[3]!);
        final d = DateTime(year, month, day);
        if (d.year == year && d.month == month && d.day == day) dates.add(d);
      }
      if (dates.isNotEmpty &&
          dates.length <= 2 &&
          !dates.last.isBefore(dates.first)) {
        final pair = (dates.first, dates.last);
        if (!result.contains(pair)) result.add(pair);
      }
    }
    return result;
  }

  static String? venue(ContestFacts f) {
    final values = <String>{};
    for (final line in f.lines) {
      final m = RegExp(
        r'(?:대면\s*)?(?:행사|대회|개최|본선)?\s*장소\s*[:：]\s*(.+)',
      ).firstMatch(line);
      if (m != null) {
        final v = m[1]!.trim();
        if (v.length >= 4 && !RegExp('추후|미정|예정|온라인|주최|문의').hasMatch(v)) {
          values.add(v);
        }
      }
    }
    return values.length == 1 ? values.single : null;
  }

  static List<RadarEvent> events(
    String source,
    ContestFacts f,
    DateTime now, {
    ContestVenue? place,
  }) {
    final eligible = eligibility(f);
    if (eligible == null) throw FormatException('Eligibility needs review');
    final schedule = sessions(f);
    final physical = place != null && schedule.isNotEmpty && venue(f) != null;
    final intervals = physical ? schedule : [(f.applicationStart, f.deadline)];
    final tags = <String>[
      'contest',
      if (RegExp(r'AI|인공지능', caseSensitive: false).hasMatch(f.title)) 'ai',
      if (RegExp('창업|스타트업|해커톤').hasMatch(f.title)) 'startup',
    ];
    return [
      for (final interval in intervals)
        RadarEvent(
          id: '$source-${f.id}-${physical ? '${interval.$1.year}${interval.$1.month.toString().padLeft(2, '0')}${interval.$1.day.toString().padLeft(2, '0')}' : 'notice'}',
          title: LocalizedText(ko: f.title, en: f.title),
          description: LocalizedText(
            ko: '${f.organizer}\n참가자격: $eligible\n${physical ? '현장 일정과 장소 확인. 세부 참가 조건은 원문을 확인하세요.' : '현장 날짜 또는 장소 미확인. 온라인 제출·접수 안내는 원문을 확인하세요.'}',
            en: f.organizer,
          ),
          category: EventCategory.contest,
          tags: tags,
          start: interval.$1,
          end: interval.$2,
          applicationStart: f.applicationStart,
          deadline: f.deadline,
          deadlinePrecision: f.deadlinePrecision,
          eventDatePrecision: physical ? 'date' : null,
          venue: physical ? '${place.name} · ${place.address}' : f.organizer,
          city: physical ? place.address.split(' ').first : '미확인',
          location: physical ? place.location : const GeoPoint(0, 0),
          placeless: !physical,
          url: f.url,
          registerUrl: f.registerUrl,
          source: source,
          sourceName: sourceNames[source],
          applicationStatus: f.cancelled ? 'cancelled' : 'open',
          eligibilityText: eligible,
          lastVerifiedAt: now.toUtc(),
          verificationTtlHours: 192,
          participationMode: physical
              ? (f.lines.any((s) => s.contains('온라인')) ? 'hybrid' : 'onsite')
              : 'unknown',
        ),
    ];
  }

  static const sourceNames = {
    'contest-linkareer': '링커리어',
    'contest-thinkgood': '씽굿',
    'contest-allforyoung': '요즘것들',
  };
}

class ContestCollection {
  const ContestCollection(
    this.events,
    this.replacedUrls,
    this.issues,
    this.complete, {
    this.reviewedUrls = const {},
  });
  final List<RadarEvent> events;
  final Set<String> replacedUrls;
  final List<String> issues;
  final bool complete;
  final Set<String> reviewedUrls;
}

class PublicContestCollector {
  PublicContestCollector(
    this.client, {
    this.geocode,
    this.limit = 12,
    this.spacing = const Duration(milliseconds: 750),
    this.timeout = const Duration(seconds: 15),
    Future<void> Function(Duration)? sleep,
  }) : sleep = sleep ?? Future<void>.delayed;
  final http.Client client;
  final Future<ContestVenue?> Function(String)? geocode;
  final int limit;
  final Duration spacing, timeout;
  final Future<void> Function(Duration) sleep;
  Future<String> _get(Uri uri) async {
    final response = await client
        .get(
          uri,
          headers: {'User-Agent': 'LifeRadar/1.0 (public contest metadata)'},
        )
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw http.ClientException('HTTP ${response.statusCode}', uri);
    }
    if (response.bodyBytes.length > 4 * 1024 * 1024) {
      throw FormatException('Oversized contest document');
    }
    return utf8.decode(response.bodyBytes);
  }

  Future<ContestCollection> collect(
    String source,
    DateTime now, {
    List<RadarEvent> previous = const [],
    Set<String> recentChecks = const {},
  }) async {
    final list = await _get(Uri.parse(PublicContestParser.lists[source]!));
    final discovered = PublicContestParser.discover(source, list);
    final candidates = <String, ContestCandidate>{};
    // Known active notices are rechecked; absence from a new list is not deletion.
    for (final e in previous.where(
      (e) => e.source == source && e.applicationVisible(now),
    )) {
      final uri = PublicContestParser.detailUrl(source, e.url ?? '');
      if (uri != null) {
        candidates[uri.toString()] = ContestCandidate(uri, e.title.ko);
      }
    }
    for (final c in discovered) {
      candidates.putIfAbsent(c.url.toString(), () => c);
    }
    final checked = <String>{};
    final reviewed = <String>{};
    final events = <RadarEvent>[];
    final issues = <String>[];
    var failed = false;
    var attempted = 0;
    var remaining = false;
    for (final c in candidates.values) {
      if (recentChecks.contains(c.url.toString())) continue;
      final known = previous
          .where((e) => e.source == source && e.url == c.url.toString())
          .toList();
      if (known.isNotEmpty &&
          known.every(
            (e) =>
                e.lastVerifiedAt != null &&
                now.toUtc().difference(e.lastVerifiedAt!.toUtc()) <
                    const Duration(days: 6),
          )) {
        continue;
      }
      if (attempted >= limit) {
        remaining = true;
        break;
      }
      attempted++;
      await sleep(spacing);
      try {
        final facts = PublicContestParser.detail(source, c, await _get(c.url));
        final venue = PublicContestParser.venue(facts);
        ContestVenue? place;
        if (venue != null &&
            PublicContestParser.sessions(facts).isNotEmpty &&
            geocode != null) {
          place = await geocode!(venue);
        }
        events.addAll(
          PublicContestParser.events(source, facts, now, place: place),
        );
        checked.add(c.url.toString());
      } on http.ClientException catch (e) {
        failed = true;
        issues.add('${c.url}: ${e.message}');
        // Stop source on access denial rather than trying other pages.
        if (e.message.contains('403') ||
            e.message.contains('401') ||
            e.message.contains('429')) {
          remaining = true;
          break;
        }
      } on FormatException catch (e) {
        if (e.message == 'Eligibility needs review' ||
            e.message == 'Not a contest') {
          reviewed.add(c.url.toString());
        } else {
          failed = true;
        }
        issues.add('${c.url}: ${e.message}');
      } catch (e) {
        failed = true;
        issues.add('${c.url}: ${e.runtimeType}');
      }
    }
    return ContestCollection(
      events,
      checked,
      issues,
      !remaining && !failed,
      reviewedUrls: reviewed,
    );
  }
}

/// Unique exact venue/address match only. A region name never becomes a pin.
class KakaoContestGeocoder {
  KakaoContestGeocoder(this.client, this.key);
  final http.Client client;
  final String key;
  final _cache = <String, Future<ContestVenue?>>{};
  Future<ContestVenue?> call(String name) =>
      _cache.putIfAbsent(name, () => _find(name));
  static String normalized(String s) => s
      .toLowerCase()
      .replaceAll('seoul', '서울')
      .replaceAll(RegExp('특별자치도|특별자치시|특별시|광역시'), '')
      .replaceAll(
        RegExp(r'(?:지하\s*)?\d+\s*층|\bb\d+\b', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'[^a-z0-9가-힣]'), '');
  Future<ContestVenue?> _find(String venue) async {
    if (key.isEmpty ||
        RegExp(
          r'^(?:서울|부산|대구|인천|대전|광주|울산|세종|전국)(?:시|특별시|광역시)?$',
        ).hasMatch(venue.trim())) {
      return null;
    }
    final query = venue
        .replaceAll(
          RegExp(r'(?:지하\s*)?\d+\s*층|\bB\d+\b', caseSensitive: false),
          '',
        )
        .trim();
    final address = RegExp(
      r'(?:서울|부산|대구|인천|대전|광주|울산|세종|경기|강원|충청|충남|충북|전라|전남|전북|경상|경남|경북|제주).*(?:로|길)\s*\d',
    ).hasMatch(query);
    final uri = Uri.https(
      'dapi.kakao.com',
      address
          ? '/v2/local/search/address.json'
          : '/v2/local/search/keyword.json',
      {'query': query, 'size': '10'},
    );
    final res = await client
        .get(uri, headers: {'Authorization': 'KakaoAK $key'})
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final docs =
        ((jsonDecode(utf8.decode(res.bodyBytes)) as Map)['documents'] as List)
            .cast<Map>();
    final matches = address
        ? docs
        : docs
              .where(
                (d) => normalized('${d['place_name']}') == normalized(query),
              )
              .toList();
    if (matches.length != 1) return null;
    final d = matches.single;
    final lat = double.tryParse('${d['y']}');
    final lng = double.tryParse('${d['x']}');
    if (lat == null ||
        lng == null ||
        !lat.isFinite ||
        !lng.isFinite ||
        lat < 33 ||
        lat > 39 ||
        lng < 124 ||
        lng > 132) {
      return null;
    }
    final roadMap = d['road_address'];
    final road = address && roadMap is Map
        ? roadMap['address_name']
        : d['road_address_name'];
    final full = road is String && road.isNotEmpty
        ? road
        : '${d['address_name'] ?? ''}';
    if (full.isEmpty) return null;
    if (address && !normalized(query).contains(normalized(full))) return null;
    return ContestVenue(venue, full, GeoPoint(lat, lng));
  }
}
