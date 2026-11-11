import 'traffic.dart';
import 'traffic_time.dart';

/// Internal/public normalized tombstone, never a guessed UTIC status code.
/// A release does not need a fabricated location or start/end time.
class TrafficWithdrawal {
  const TrafficWithdrawal({
    required this.source,
    required this.sourceRecordId,
    required this.observedAt,
    this.sourceUpdatedAt,
    this.status = 'cancelled',
  });

  final String source;
  final String sourceRecordId;
  final DateTime observedAt;
  final DateTime? sourceUpdatedAt;
  final String status;
  String get key => '$source:$sourceRecordId';
  bool get explicit => status == 'cancelled' || status == 'expired';
  DateTime get revision => trafficUtc(sourceUpdatedAt ?? observedAt);

  bool blocks(TrafficNotice n) {
    if (n.source != source || (n.sourceRecordId ?? n.id) != sourceRecordId) return false;
    if (explicit) {
      // A later fetch of the same old record cannot undo an explicit release.
      return n.sourceUpdatedAt == null || !trafficUtc(n.sourceUpdatedAt!).isAfter(revision);
    }
    final seen = n.lastSeenAt ?? n.fetchedAt;
    return seen == null || !trafficUtc(seen).isAfter(trafficUtc(observedAt));
  }

  Map<String, dynamic> toJson() => {
    'source': source,
    'sourceRecordId': sourceRecordId,
    'status': status,
    'observedAt': trafficUtc(observedAt).toIso8601String(),
    if (sourceUpdatedAt != null) 'sourceUpdatedAt': trafficUtc(sourceUpdatedAt!).toIso8601String(),
  };

  static TrafficWithdrawal fromJson(Map<String, dynamic> j) {
    final source = j['source'] as String;
    final id = j['sourceRecordId'] as String;
    final status = j['status'] as String;
    if (source.trim().isEmpty || id.trim().isEmpty || !{'cancelled', 'expired', 'missing'}.contains(status)) {
      throw const FormatException('Invalid traffic withdrawal');
    }
    final seen = trafficInstant(j['observedAt'] as String);
    final updated = j['sourceUpdatedAt'] == null ? null : trafficInstant(j['sourceUpdatedAt'] as String);
    if (updated != null && updated.isAfter(seen)) throw const FormatException('Future withdrawal revision');
    return TrafficWithdrawal(
      source: source,
      sourceRecordId: id,
      status: status,
      observedAt: seen,
      sourceUpdatedAt: updated,
    );
  }
}
