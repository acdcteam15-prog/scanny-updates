import 'dart:convert';

import '../models/models.dart';

/// Solved needs proof: the version it was upgraded to, or what was done to restrict the exposure.
/// Same rule as Scanny for Windows and the Firestore security rules. Returns the problem text, or null when fine.
String? solvedProblem({required bool upgrade, required String version, required String actions}) {
  if (upgrade && version.trim().isEmpty) return 'Enter the version it was upgraded to.';
  if (!upgrade && actions.trim().isEmpty) return 'Describe the restrictive actions you took (for example: blocked the port, disabled the service, applied an ACL).';
  return null;
}

/// What this person may do with a finding in this state.
List<Status> allowedTargets(Status from, {required bool isAdmin}) {
  if (from == Status.accepted) return isAdmin ? [Status.ongoing] : const [];
  return [Status.ongoing, Status.acknowledged, Status.solved, Status.falsePositive].where((s) => s != from).toList();
}

class FindingFilter {
  final String query;
  final Set<Severity> severities;
  final Set<Status> statuses; // empty = open ones only
  final String groupId; // '' = every group I can see
  final String mine; // email: only findings assigned to it; '' = everyone
  final bool exploited; // only findings that are actively exploited
  final bool today; // only findings Scanny first saw today
  final bool overdueOnly; // only findings past their due date
  final bool snoozed; // only snoozed findings (they are hidden from the normal open list)
  final String sort; // 'score' (highest priority first) or 'published' (newest CVE first)
  const FindingFilter({this.query = '', this.severities = const {}, this.statuses = const {}, this.groupId = '', this.mine = '', this.exploited = false, this.today = false, this.overdueOnly = false, this.snoozed = false, this.sort = 'score'});

  FindingFilter copyWith({String? query, Set<Severity>? severities, Set<Status>? statuses, String? groupId, String? mine, bool? exploited, bool? today, bool? overdueOnly, bool? snoozed, String? sort}) => FindingFilter(
        query: query ?? this.query,
        severities: severities ?? this.severities,
        statuses: statuses ?? this.statuses,
        groupId: groupId ?? this.groupId,
        mine: mine ?? this.mine,
        exploited: exploited ?? this.exploited,
        today: today ?? this.today,
        overdueOnly: overdueOnly ?? this.overdueOnly,
        snoozed: snoozed ?? this.snoozed,
        sort: sort ?? this.sort,
      );

  bool get isDefault => query.isEmpty && severities.isEmpty && statuses.isEmpty && groupId.isEmpty && mine.isEmpty && !exploited && !today && !overdueOnly && !snoozed && sort == 'score';

  Map<String, dynamic> toMap() => {
        'q': query,
        'sev': severities.map((e) => e.name).toList(),
        'st': statuses.map((e) => e.name).toList(),
        'g': groupId,
        'mine': mine.isNotEmpty,
        'ex': exploited,
        'td': today,
        'ov': overdueOnly,
        'sn': snoozed,
        'so': sort,
      };

  /// [myEmail] is filled in for "assigned to me", so a saved view works for whoever is signed in.
  static FindingFilter fromMap(Map<dynamic, dynamic> m, {String myEmail = ''}) => FindingFilter(
        query: '${m['q'] ?? ''}',
        severities: {for (final n in (m['sev'] is List ? m['sev'] as List : const [])) ...Severity.values.where((v) => v.name == '$n')},
        statuses: {for (final n in (m['st'] is List ? m['st'] as List : const [])) ...Status.values.where((v) => v.name == '$n')},
        groupId: '${m['g'] ?? ''}',
        mine: m['mine'] == true ? myEmail : '',
        exploited: m['ex'] == true,
        today: m['td'] == true,
        overdueOnly: m['ov'] == true,
        snoozed: m['sn'] == true,
        sort: m['so'] == 'published' ? 'published' : 'score',
      );
}

/// A named set of filters kept on this phone.
class SavedView {
  final String name;
  final FindingFilter filter;
  const SavedView(this.name, this.filter);
  String encode() => jsonEncode({'name': name, 'f': filter.toMap()});
  static SavedView? decode(String text, {String myEmail = ''}) {
    try {
      final m = jsonDecode(text);
      if (m is! Map || '${m['name'] ?? ''}'.trim().isEmpty || m['f'] is! Map) return null;
      return SavedView('${m['name']}'.trim(), FindingFilter.fromMap(m['f'] as Map, myEmail: myEmail));
    } catch (_) {
      return null;
    }
  }
}

/// What happened since the person last looked: new findings, and findings someone else changed.
class Changes {
  final int added;
  final int addedCritical;
  final int changedByOthers;
  const Changes(this.added, this.addedCritical, this.changedByOthers);
  bool get any => added + changedByOthers > 0;
}

Changes changesSince(Iterable<Finding> all, DateTime since, String myEmail) {
  var a = 0, c = 0, o = 0;
  final me = myEmail.toLowerCase();
  for (final f in all) {
    if (f.gone) continue;
    final fs = f.firstSeen;
    if (fs != null && fs.isAfter(since)) {
      a++;
      if (f.severity == Severity.critical) c++;
      continue;
    }
    final sa = f.statusAt;
    if (sa != null && sa.isAfter(since) && f.statusBy.isNotEmpty && f.statusBy.toLowerCase() != me) o++;
  }
  return Changes(a, c, o);
}

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// New findings per day for the last [days] days (oldest first, today last), counted by the day Scanny first saw them.
List<int> dailyCounts(Iterable<Finding> all, {int days = 14, DateTime? now}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final out = List<int>.filled(days, 0);
  for (final f in all) {
    final t = f.firstSeen;
    if (t == null || f.gone) continue;
    final l = t.toLocal();
    final back = (today.difference(DateTime(l.year, l.month, l.day)).inHours / 24).round();
    if (back >= 0 && back < days) out[days - 1 - back]++;
  }
  return out;
}

List<Finding> applyFilter(Iterable<Finding> all, FindingFilter f, {DateTime? now}) {
  final q = f.query.trim().toLowerCase();
  final nowT = now ?? DateTime.now();
  final out = all.where((x) {
    if (x.gone) return false;
    if (f.statuses.isEmpty ? !x.isOpen : !f.statuses.contains(x.status)) return false;
    if (f.snoozed ? !x.snoozedAt(nowT) : (f.statuses.isEmpty && x.snoozedAt(nowT))) return false;
    if (f.severities.isNotEmpty && !f.severities.contains(x.severity)) return false;
    if (f.groupId.isNotEmpty && !x.groups.contains(f.groupId)) return false;
    if (f.mine.isNotEmpty && x.assignee != f.mine.toLowerCase()) return false;
    if (f.exploited && !x.kev) return false;
    if (f.overdueOnly && !x.overdue) return false;
    if (f.today && (x.firstSeen == null || !_sameDay(x.firstSeen!.toLocal(), nowT))) return false;
    if (q.isNotEmpty && !('${x.cve} ${x.system} ${x.headline} ${x.title}'.toLowerCase().contains(q))) return false;
    return true;
  }).toList();
  if (f.sort == 'published') {
    out.sort((a, b) {
      final p = b.published.compareTo(a.published); // newest CVE first, unknown dates last
      return p != 0 ? p : b.score.compareTo(a.score);
    });
  } else {
    out.sort((a, b) => b.score.compareTo(a.score));
  }
  return out;
}

class Counts {
  final int critical;
  final int high;
  final int medium;
  final int low;
  final int overdue;
  final int exploited;
  const Counts(this.critical, this.high, this.medium, this.low, this.overdue, this.exploited);
  int get open => critical + high + medium + low;
}

Counts countOpen(Iterable<Finding> all) {
  var c = 0, h = 0, m = 0, l = 0, o = 0, k = 0;
  for (final f in all) {
    if (!f.isOpen || f.snoozed) continue;
    switch (f.severity) {
      case Severity.critical:
        c++;
      case Severity.high:
        h++;
      case Severity.medium:
        m++;
      case Severity.low:
        l++;
    }
    if (f.overdue) o++;
    if (f.kev) k++;
  }
  return Counts(c, h, m, l, o, k);
}

String csvCell(String v) {
  final needs = v.contains(',') || v.contains('"') || v.contains('\n') || v.contains('\r');
  final t = v.replaceAll('"', '""');
  return needs ? '"$t"' : t;
}

/// One row per finding, for the export of a group. [groupName] turns an id into its display name.
String findingsCsv(Iterable<Finding> items, String Function(String) groupName) {
  const head = ['CVE', 'Severity', 'Score', 'System', 'Version', 'Groups', 'Status', 'Assigned to', 'Due', 'Exploited', 'Fixed in', 'Proof', 'Summary'];
  final b = StringBuffer(head.join(','))..write('\r\n');
  for (final f in items) {
    final proof = f.solved != null ? f.solved!.text : (f.accepted != null ? 'Accepted until ${f.accepted!.until}: ${f.accepted!.reason}' : '');
    b.write([
      f.cve,
      severityLabel(f.severity),
      '${f.score}',
      f.system,
      f.sysVersion,
      f.groups.map(groupName).join(' / '),
      kStatusLabel[f.status] ?? '',
      f.assigneeName.isNotEmpty ? f.assigneeName : f.assignee,
      f.due,
      f.kev ? 'yes' : '',
      f.fixed,
      proof,
      f.headline.isNotEmpty ? f.headline : f.title,
    ].map(csvCell).join(','));
    b.write('\r\n');
  }
  return b.toString();
}

String ago(DateTime? t, {DateTime? now}) {
  if (t == null) return '';
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays < 30) return '${d.inDays} d ago';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

String hashPinText(String pin) {
  // Western, Arabic-Indic and Persian digits all count as the same PIN.
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  final b = StringBuffer();
  for (final r in pin.runes) {
    final ch = String.fromCharCode(r);
    final a = arabic.indexOf(ch);
    final p = persian.indexOf(ch);
    b.write(a >= 0 ? '$a' : (p >= 0 ? '$p' : ch));
  }
  return b.toString();
}

/// The text shared for a finding: CVE and severity, the system, the headline, the fixed version, and the public advisory link.
String findingShareText(Finding f) {
  final sys = '${f.system} ${f.sysVersion}'.trim();
  final a = f.advisory;
  if (a != null) {
    // an advisory finding: the article is the link, and it lists CVEs
    return [
      '${f.cve}  ${severityLabel(f.severity)}',
      if (a.title.isNotEmpty) a.title,
      if (sys.isNotEmpty) 'Lists $sys as affected',
      if (a.cves.isNotEmpty) '${a.cves.length} CVEs',
      if (a.link.isNotEmpty) a.link,
    ].join('\n');
  }
  final head = f.headline.isNotEmpty ? f.headline : f.title;
  return [
    '${f.cve}  ${severityLabel(f.severity)}${f.kev ? ' (exploited in the wild)' : ''}',
    if (sys.isNotEmpty) sys,
    if (head.isNotEmpty) head,
    if (f.fixed.isNotEmpty) 'Fixed in ${f.fixed}',
    'https://nvd.nist.gov/vuln/detail/${f.cve}',
  ].join('\n');
}

/// New findings in the last 7 days against the 7 days before.
({int cur, int prev}) weekTrend(Iterable<Finding> all, {DateTime? now}) {
  final d = dailyCounts(all, days: 14, now: now);
  int sum(List<int> x) => x.fold<int>(0, (a, b) => a + b);
  return (cur: sum(d.sublist(7)), prev: sum(d.sublist(0, 7)));
}

class TodayItem {
  final Finding f;
  final String why;
  final int rank;
  const TodayItem(this.f, this.why, this.rank);
}

/// The few findings to deal with first: actively exploited and overdue before the rest, then by score. A calm day gives an empty list.
List<TodayItem> todayList(Iterable<Finding> all, {DateTime? now, int n = 3}) {
  final t = now ?? DateTime.now();
  final out = <TodayItem>[];
  for (final f in all) {
    if (!f.isOpen || f.snoozedAt(t)) continue;
    final rank = (f.kev ? 4 : 0) + (f.overdue ? 3 : 0) + (f.poc ? 1 : 0);
    if (rank == 0 && f.score < 70) continue;
    out.add(TodayItem(f, f.kev ? 'Exploited' : (f.overdue ? 'Overdue' : (f.poc ? 'Public exploit' : 'Score ${f.score}')), rank));
  }
  out.sort((a, b) {
    final r = b.rank.compareTo(a.rank);
    if (r != 0) return r;
    final s = b.f.score.compareTo(a.f.score);
    return s != 0 ? s : a.f.cve.compareTo(b.f.cve);
  });
  return out.take(n).toList();
}

/// The last turns of an Ask AI chat as plain text, so the next answer can refer to them.
String aiHistory(Iterable<(String, String)> turns) {
  final t = [for (final x in turns) if (x.$2.isNotEmpty) 'Q: ${x.$1}\nA: ${x.$2}'];
  final s = t.length > 2 ? t.sublist(t.length - 2) : t;
  final text = s.join('\n');
  return text.length > 1500 ? text.substring(0, 1500) : text;
}

/// Activity of somebody else, newer than the first launch, that was not opened yet: it gets its own red dot.
bool isUnreadActivity(AuditEntry e, String me, DateTime base, Set<String> read) {
  final at = e.at;
  return at != null && at.isAfter(base) && e.by.toLowerCase() != me.toLowerCase() && !read.contains(e.id);
}

/// The dot on the Activity tab: something unread arrived since the tab was last opened.
bool activityDot(Iterable<AuditEntry> entries, String me, DateTime base, Set<String> read, DateTime seen) =>
    entries.any((e) => isUnreadActivity(e, me, base, read) && e.at!.isAfter(seen));

List<String> addRead(Iterable<String> ids, String id) {
  final out = [...ids.where((x) => x != id), id];
  return out.length > 400 ? out.sublist(out.length - 400) : out;
}
