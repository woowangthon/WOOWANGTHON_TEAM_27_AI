import '../models/traffic.dart';
import '../models/traffic_time.dart';
import '../models/traffic_withdrawal.dart';
import 'route_matcher.dart';

/// Conservative grouping. Missing direction/link namespace never means equality.
class TrafficMerger {
  static bool sameControl(TrafficNotice a, TrafficNotice b) {
    if (!a.hasControlEvidence ||
        !b.hasControlEvidence ||
        a.end == null ||
        b.end == null ||
        a.timePrecision != 'minute' ||
        b.timePrecision != 'minute') {
      return false;
    }
    if (a.kind != b.kind ||
        a.roadName == null ||
        a.roadName != b.roadName ||
        a.direction == null ||
        a.direction != b.direction) {
      return false;
    }
    if (trafficUtc(a.start).difference(trafficUtc(b.start)).abs() > const Duration(minutes: 30)) return false;
    final release = {'cancelled', 'expired'}.contains(a.status) || {'cancelled', 'expired'}.contains(b.status);
    if (!release &&
        (!trafficUtc(a.start).isBefore(trafficUtc(b.end!)) || !trafficUtc(b.start).isBefore(trafficUtc(a.end!)))) {
      return false;
    }
    final linked =
        a.linkSystem != null &&
        a.linkVersion != null &&
        a.linkSystem == b.linkSystem &&
        a.linkVersion == b.linkVersion &&
        a.linkIds.any(b.linkIds.contains);
    return linked ||
        (a.section != null &&
            a.section == b.section &&
            a.evidenceText == b.evidenceText &&
            RouteMatcher.haversineKm(a.location, b.location) <= .2);
  }

  /// Resolve a source's duplicate original IDs before any destructive storage.
  /// This deliberately does not group sources or filter expired release facts.
  static List<TrafficNotice> latestOriginals(Iterable<TrafficNotice> input) {
    final originals = <String, TrafficNotice>{};
    for (final n in input) {
      final key = '${n.source}:${n.sourceRecordId ?? n.id}';
      final old = originals[key];
      DateTime version(TrafficNotice v) => trafficUtc(v.sourceUpdatedAt ?? v.lastSeenAt ?? v.fetchedAt ?? v.start);
      final oldReleased = old != null && {'cancelled', 'expired'}.contains(old.status);
      if (old == null ||
          version(n).isAfter(version(old)) ||
          (version(n) == version(old) && (!oldReleased || n.status != 'active'))) {
        originals[key] = n;
      }
    }
    return originals.values.toList();
  }

  static List<TrafficNotice> merge(
    Iterable<TrafficNotice> input, {
    Map<String, String>? aliases,
    DateTime? now,
    Iterable<TrafficWithdrawal> withdrawals = const [],
  }) {
    // Resolve original identities, including expired releases, before relevance.
    // Re-expand published groups so a direct-device record cannot hide or
    // duplicate a newer member of an already grouped backend notice.
    final records = input.expand(
      (n) => n.evidenceRefs.isEmpty
          ? [n]
          : [
              for (final e in n.evidenceRefs) TrafficNotice.fromJson(e).withMetadata({'groupId': n.groupId}),
            ],
    );
    final originals = latestOriginals(records);
    final sorted = originals.where((n) {
      if (n.status == 'active' &&
          withdrawals.any((w) => (now == null || !trafficUtc(w.observedAt).isAfter(trafficUtc(now))) && w.blocks(n))) {
        return false;
      }
      if (now == null) return true;
      if (n.status == 'missing') return false;
      if (n.status == 'cancelled' || n.status == 'expired') {
        // Retain release evidence while it is fresh, even when its end is now.
        final seen = n.lastSeenAt ?? n.fetchedAt;
        if (seen == null) return true;
        final age = trafficUtc(now).difference(trafficUtc(seen));
        return !age.isNegative && age <= Duration(hours: n.source == 'utic' ? 6 : 24);
      }
      return n.isRelevantAt(now);
    }).toList()..sort((a, b) => a.id.compareTo(b.id));
    final groups = <List<TrafficNotice>>[];
    for (final n in sorted) {
      final found = groups.where((g) => g.every((a) => sameControl(a, n))).firstOrNull;
      if (found == null) {
        groups.add([n]);
      } else {
        found.add(n);
      }
    }
    final usedGroups = <String>{};
    return [for (final group in groups) _represent(group, aliases, usedGroups)];
  }

  static TrafficNotice _represent(List<TrafficNotice> group, Map<String, String>? aliases, Set<String> usedGroups) {
    final ids = group.map((n) => n.id).toList()..sort();
    var groupId = ids.map((id) => aliases?[id]).nonNulls.firstOrNull ?? group.first.groupId ?? ids.first;
    if (usedGroups.contains(groupId)) {
      groupId = ids.firstWhere((id) => !usedGroups.contains(id), orElse: () => 'group:${ids.first}');
    }
    usedGroups.add(groupId);
    for (final id in ids) {
      aliases?[id] = groupId;
    }
    group.sort((a, b) => trafficUtc(b.lastSeenAt ?? b.start).compareTo(trafficUtc(a.lastSeenAt ?? a.start)));
    final representative = group.where((n) => n.status == 'active').firstOrNull ?? group.first;
    // A released independent source conflicts with an active source: stop warnings.
    final conflict =
        group.any((n) => {'cancelled', 'expired'}.contains(n.status)) && group.any((n) => n.status == 'active');
    return representative.withMetadata({
      'groupId': groupId,
      'conflict': conflict || group.any((n) => n.conflict),
      'evidenceRefs': [
        for (final n in group)
          if (n.evidenceRefs.isEmpty) {...n.toJson()} else ...n.evidenceRefs,
      ],
    });
  }
}
