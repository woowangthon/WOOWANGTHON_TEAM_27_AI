import 'dart:math' as math;
import '../models/models.dart';
import '../models/traffic.dart';
import '../models/traffic_time.dart';

/// Normalizes the JSON used by TOPIS's public current/planned incident map.
/// Coordinates are explicitly EPSG:5181 in the publisher's map configuration.
class TopisPublic {
  static DateTime? instant(dynamic date, dynamic time) {
    final d = '$date', t = '$time';
    if (!RegExp(r'^\d{8}$').hasMatch(d) || !RegExp(r'^\d{4}(?:\d{2})?$').hasMatch(t)) return null;
    final hh = t.padRight(6, '0');
    try {
      return trafficInstant(
        '${d.substring(0, 4)}-${d.substring(4, 6)}-${d.substring(6)}T${hh.substring(0, 2)}:${hh.substring(2, 4)}:${hh.substring(4)}+09:00',
      );
    } catch (_) {
      return null;
    }
  }

  static TrafficNotice? parse(Map<String, dynamic> row, DateTime now) {
    final x = row['posX'], y = row['posY'];
    final id = row['accId'];
    final start = instant(row['occrDate'], row['occrTime']);
    final end = instant(row['clrDate'], row['clrTime']);
    final stamp = '${row['nowTime'] ?? ''}';
    final updated = stamp.length == 12 ? instant(stamp.substring(0, 8), stamp.substring(8)) : null;
    if (id == null ||
        x is! num ||
        y is! num ||
        !x.isFinite ||
        !y.isFinite ||
        start == null ||
        updated == null ||
        trafficUtc(now).difference(updated).abs() > const Duration(minutes: 15))
      return null;
    final at = tmToWgs84(x.toDouble(), y.toDouble());
    if (at.lat < 33 || at.lat > 39 || at.lng < 124 || at.lng > 132) return null;
    final detail = '${row['accInfo'] ?? ''}'.replaceAll(r'\r', '').replaceAll(r'\n', '\n').replaceAll('\r', '').trim();
    if (detail.isEmpty) return null;
    final kind = switch (row['accType']) {
      'A10' => row['accDtype'] == '10B02' ? TrafficKind.rally : TrafficKind.event,
      'A04' => TrafficKind.construction,
      'A09' => TrafficKind.weather,
      _ => TrafficKind.other,
    };
    final controlled = const ['009', '010'].contains(row['accRoadCode']) || explicitRoadControl(detail);
    return TrafficNotice(
      id: 'topis-$id',
      kind: kind,
      title: detail.split('\n').first,
      detail: detail,
      start: start,
      end: end != null && end.isAfter(start) ? end : null,
      location: at,
      source: 'seoul-topis',
      sourceName: '서울시 TOPIS 실시간 공개 공지',
      sourceUrl: 'https://topis.seoul.go.kr/?accId=$id',
      lastSeenAt: updated,
      fetchedAt: now.toUtc(),
      timePrecision: 'minute',
      controlEvidence: controlled ? 'confirmed' : 'unconfirmed',
      evidenceText: detail,
      evidenceMethod: 'topis-public-road-code-and-text',
      sourceRecordId: '$id',
    );
  }

  static String? transitRestriction(String detail) {
    if (RegExp(r'해제|정상\s*운행|무정차[^.\n]*종료|운행\s*중단[^.\n]*(취소|없|않)').hasMatch(detail)) return null;
    if (RegExp(r'버스[^.\n]*(우회|무정차|운행\s*(중단|중지))').hasMatch(detail)) return 'bus';
    if (RegExp(r'무정차|역사?\s*폐쇄|지하철[^.\n]*운행\s*(중단|중지)').hasMatch(detail)) return 'subway';
    if (RegExp(r'(열차|철도)[^.\n]*운행\s*(중단|중지)').hasMatch(detail)) return 'rail';
    return null;
  }

  // Shared GRS80 inverse projection is appended from the existing BE parser.

  static GeoPoint tmToWgs84(double x, double y) {
    const a = 6378137.0;
    const f = 1 / 298.257222101;
    const k0 = 1.0;
    const lat0 = 38 * math.pi / 180;
    const lon0 = 127 * math.pi / 180;
    const fe = 200000.0;
    const fn = 500000.0;
    const e2 = f * (2 - f);
    final ep2 = e2 / (1 - e2);

    double meridian(double phi) =>
        a *
        ((1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * e2 * e2 * e2 / 256) * phi -
            (3 * e2 / 8 + 3 * e2 * e2 / 32 + 45 * e2 * e2 * e2 / 1024) * math.sin(2 * phi) +
            (15 * e2 * e2 / 256 + 45 * e2 * e2 * e2 / 1024) * math.sin(4 * phi) -
            (35 * e2 * e2 * e2 / 3072) * math.sin(6 * phi));

    final m = meridian(lat0) + (y - fn) / k0;
    final mu = m / (a * (1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * e2 * e2 * e2 / 256));
    final e1 = (1 - math.sqrt(1 - e2)) / (1 + math.sqrt(1 - e2));
    final phi1 =
        mu +
        (3 * e1 / 2 - 27 * math.pow(e1, 3) / 32) * math.sin(2 * mu) +
        (21 * e1 * e1 / 16 - 55 * math.pow(e1, 4) / 32) * math.sin(4 * mu) +
        (151 * math.pow(e1, 3) / 96) * math.sin(6 * mu) +
        (1097 * math.pow(e1, 4) / 512) * math.sin(8 * mu);

    final sin1 = math.sin(phi1);
    final cos1 = math.cos(phi1);
    final tan1 = math.tan(phi1);
    final n1 = a / math.sqrt(1 - e2 * sin1 * sin1);
    final t1 = tan1 * tan1;
    final c1 = ep2 * cos1 * cos1;
    final r1 = a * (1 - e2) / math.pow(1 - e2 * sin1 * sin1, 1.5);
    final d = (x - fe) / (n1 * k0);

    final lat =
        phi1 -
        (n1 * tan1 / r1) *
            (d * d / 2 -
                (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * ep2) * math.pow(d, 4) / 24 +
                (61 + 90 * t1 + 298 * c1 + 45 * t1 * t1 - 252 * ep2 - 3 * c1 * c1) * math.pow(d, 6) / 720);
    final lon =
        lon0 +
        (d -
                (1 + 2 * t1 + c1) * math.pow(d, 3) / 6 +
                (5 - 2 * c1 + 28 * t1 - 3 * c1 * c1 + 8 * ep2 + 24 * t1 * t1) * math.pow(d, 5) / 120) /
            cos1;
    return GeoPoint(lat * 180 / math.pi, lon * 180 / math.pi);
  }
}
