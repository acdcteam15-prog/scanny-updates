// Pure Dart: no Flutter and no Firebase imports, so everything here can be tested anywhere.

/// The five states of a finding. The remote names are what Scanny for Windows writes into Firestore.
enum Status { ongoing, acknowledged, solved, falsePositive, accepted }

const Map<Status, String> kStatusRemote = {
  Status.ongoing: 'ongoing',
  Status.acknowledged: 'acknowledged',
  Status.solved: 'solved',
  Status.falsePositive: 'false_positive',
  Status.accepted: 'accepted',
};

const Map<Status, String> kStatusLabel = {
  Status.ongoing: 'On-going',
  Status.acknowledged: 'Acknowledged',
  Status.solved: 'Solved',
  Status.falsePositive: 'False positive',
  Status.accepted: 'Risk accepted',
};

Status statusFromRemote(Object? v) {
  final s = '${v ?? ''}';
  for (final e in kStatusRemote.entries) {
    if (e.value == s) return e.key;
  }
  return Status.ongoing;
}

enum Severity { critical, high, medium, low }

Severity severityOf(Object? v) {
  switch ('${v ?? ''}'.toLowerCase()) {
    case 'critical':
      return Severity.critical;
    case 'high':
      return Severity.high;
    case 'medium':
      return Severity.medium;
    default:
      return Severity.low;
  }
}

String severityLabel(Severity s) => s.name[0].toUpperCase() + s.name.substring(1);

DateTime? toDate(Object? v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  if (v is num) return DateTime.fromMillisecondsSinceEpoch((v * 1000).round());
  return null;
}

String _s(Object? v) => v == null ? '' : '$v';
List<String> _list(Object? v) => v is List ? v.map((e) => '$e').toList() : <String>[];

/// Proof of a fix: the version it was upgraded to, or the restrictive actions taken.
class Proof {
  final bool upgrade;
  final String version;
  final String actions;
  final String by;
  final DateTime? at;
  const Proof({required this.upgrade, this.version = '', this.actions = '', this.by = '', this.at});

  factory Proof.fromMap(Map<dynamic, dynamic> m) => Proof(
        upgrade: m['upgrade'] == true,
        version: _s(m['version']),
        actions: _s(m['actions']),
        by: _s(m['by']),
        at: toDate(m['at']),
      );

  String get text => upgrade ? 'Upgraded to $version' : 'Restricted: $actions';
}

class Accepted {
  final String reason;
  final String until;
  final String by;
  const Accepted({required this.reason, required this.until, this.by = ''});
  factory Accepted.fromMap(Map<dynamic, dynamic> m) => Accepted(reason: _s(m['reason']), until: _s(m['until']), by: _s(m['by']));
}

class Person {
  final String email;
  final String name;
  final String role;
  const Person({required this.email, required this.name, this.role = 'member'});
  factory Person.fromMap(Map<dynamic, dynamic> m) => Person(email: _s(m['email']).toLowerCase(), name: _s(m['name']).isEmpty ? _s(m['email']) : _s(m['name']), role: _s(m['role']).isEmpty ? 'member' : _s(m['role']));
  bool get isAdmin => role == 'admin';
}

class GroupInfo {
  final String id;
  final String name;
  final int color; // ARGB
  final String pushMin;
  final List<Person> people;
  const GroupInfo({required this.id, required this.name, this.color = 0xFF8796FF, this.pushMin = 'critical', this.people = const []});

  factory GroupInfo.fromMap(String id, Map<String, dynamic> m) {
    var c = 0xFF8796FF;
    final raw = _s(m['color']).replaceAll('#', '');
    if (raw.length == 6) c = int.tryParse('FF$raw', radix: 16) ?? c;
    return GroupInfo(
      id: id,
      name: _s(m['name']).isEmpty ? id : _s(m['name']),
      color: c,
      pushMin: _s(m['pushMin']).isEmpty ? 'critical' : _s(m['pushMin']),
      people: (m['people'] is List) ? (m['people'] as List).whereType<Map>().map(Person.fromMap).toList() : <Person>[],
    );
  }
}

/// The setup wizard's security self-test creates temporary groups with these ids. They are never real: hide them everywhere.
bool isTestGroup(String id) => RegExp(r'^rt-[ab]-[a-z0-9]{6}$').hasMatch(id);

/// A member's own record: who may sign in, and which groups they belong to.
class Member {
  final String email;
  final String name;
  final String role;
  final List<String> groups;
  final bool active;

  /// The admin switched on "Zero-day watch" for this person (admins always may read the articles).
  final bool watch;
  const Member({required this.email, required this.name, required this.role, required this.groups, required this.active, this.watch = false});
  bool get isAdmin => role == 'admin';
  bool get canWatch => isAdmin || watch;
  factory Member.fromMap(String id, Map<String, dynamic> m) => Member(
        email: id.toLowerCase(),
        name: _s(m['name']).isEmpty ? id : _s(m['name']),
        role: _s(m['role']) == 'admin' ? 'admin' : 'member',
        groups: _list(m['groups']),
        active: m['active'] == true,
        watch: m['watch'] == true,
      );
}

/// Did the admin change which groups (or admin status) this person has? Then the phone must reload its group streams.
bool sameAccess(Member a, Member b) => a.isAdmin == b.isAdmin && a.groups.length == b.groups.length && a.groups.toSet().containsAll(b.groups);

/// A system document of a group (from Scanny for Windows). Findings are separate documents.
class SystemInfo {
  final String id;
  final String name;
  final String version;
  final String type;
  final List<String> groups;
  const SystemInfo({required this.id, required this.name, required this.version, this.type = '', this.groups = const []});
  factory SystemInfo.fromMap(String id, Map<String, dynamic> m, {String group = ''}) =>
      SystemInfo(id: id, name: _s(m['name']), version: _s(m['version']), type: _s(m['type']), groups: group.isEmpty ? const [] : [group]);
}

/// One Zero-day watch article, as Scanny for Windows sends it. [groups] are the ids of the groups whose systems it mentions.
class WatchItem {
  final String id;
  final String title;
  final String feed;
  final String link;
  final String summary;
  final String published;
  final double t;
  final List<String> cves;
  final List<String> groups;
  final bool mine;

  /// Group id -> ids of the systems this article mentions in that group (the names are looked up among the systems this person may read).
  final Map<String, List<String>> mentions;
  const WatchItem({required this.id, required this.title, required this.feed, required this.link, required this.summary, required this.published, required this.t, required this.cves, required this.groups, required this.mine, this.mentions = const {}});
  factory WatchItem.fromMap(String id, Map<String, dynamic> m) => WatchItem(
        id: id,
        title: _s(m['title']),
        feed: _s(m['feed']),
        link: _s(m['link']),
        summary: _s(m['summary']),
        published: _s(m['published']),
        t: (m['t'] is num) ? (m['t'] as num).toDouble() : 0,
        cves: _list(m['cves']),
        groups: _list(m['groups']),
        mine: m['mine'] == true,
        mentions: m['mentions'] is Map ? {for (final e in (m['mentions'] as Map).entries) e.key.toString(): _list(e.value)} : const {},
      );

  /// When it was published; falls back to when Scanny first saw it.
  DateTime get when => DateTime.tryParse(published)?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch((t * 1000).round());
}

class Finding {
  final String fid;
  final String cve;
  final String sid;
  final String system;
  final String sysVersion;
  final Severity severity;
  final int score;
  final double? cvss;
  final double? epss;
  final bool kev;
  final bool poc;
  final String fixed;
  final String headline;
  final String title;
  final String reason;
  final String due; // yyyy-mm-dd or ''
  final String note;
  final DateTime? firstSeen;
  final List<String> steps;
  final List<String> workaround;
  final bool gone;
  final List<String> groups;
  final Status status;
  final Proof? solved;
  final Accepted? accepted;
  final String assignee; // email
  final String assigneeName;
  final String statusBy;
  final String statusByName;
  final DateTime? statusAt;

  /// The source whose record Scanny kept for this CVE, and the other sources that reported the same CVE (shown once, as a tag).
  final String source;
  final List<String> alsoBy;

  const Finding({
    required this.fid,
    required this.cve,
    required this.sid,
    required this.system,
    this.sysVersion = '',
    required this.severity,
    required this.score,
    this.cvss,
    this.epss,
    this.kev = false,
    this.poc = false,
    this.fixed = '',
    this.headline = '',
    this.title = '',
    this.reason = '',
    this.due = '',
    this.note = '',
    this.firstSeen,
    this.steps = const [],
    this.workaround = const [],
    this.gone = false,
    this.groups = const [],
    this.status = Status.ongoing,
    this.solved,
    this.accepted,
    this.assignee = '',
    this.assigneeName = '',
    this.statusBy = '',
    this.statusByName = '',
    this.statusAt,
    this.source = '',
    this.alsoBy = const [],
  });

  factory Finding.fromMap(String fid, Map<String, dynamic> m) {
    return Finding(
      fid: fid,
      cve: _s(m['cve']),
      sid: _s(m['sid']),
      system: _s(m['sysName']),
      sysVersion: _s(m['sysVersion']),
      severity: severityOf(m['label']),
      score: (m['score'] is num) ? (m['score'] as num).round() : 0,
      cvss: (m['cvss'] is num) ? (m['cvss'] as num).toDouble() : null,
      epss: (m['epss'] is num) ? (m['epss'] as num).toDouble() : null,
      kev: m['kev'] == true,
      poc: m['poc'] == true,
      fixed: _s(m['fixed']),
      headline: _s(m['headline']),
      title: _s(m['title']),
      reason: _s(m['reason']),
      due: _s(m['due']),
      note: _s(m['note']),
      firstSeen: toDate(m['firstSeen']),
      steps: _list(m['steps']),
      workaround: _list(m['workaround']),
      gone: m['gone'] == true || m['stale'] == true,
      groups: _list(m['groups']),
      status: statusFromRemote(m['status']),
      solved: m['solved'] is Map ? Proof.fromMap(m['solved'] as Map) : null,
      accepted: m['accepted'] is Map ? Accepted.fromMap(m['accepted'] as Map) : null,
      assignee: _s(m['assignee']).toLowerCase(),
      assigneeName: _s(m['assigneeName']),
      statusBy: _s(m['statusBy']),
      statusByName: _s(m['statusByName']),
      statusAt: toDate(m['statusAt']),
      source: _s(m['source']),
      alsoBy: _list(m['alsoBy']),
    );
  }

  /// Still needs work: not solved, not a false positive, not an accepted risk.
  bool get isOpen => !gone && (status == Status.ongoing || status == Status.acknowledged);

  bool get overdue {
    if (!isOpen || due.isEmpty) return false;
    final d = DateTime.tryParse(due);
    if (d == null) return false;
    final today = DateTime.now();
    return d.isBefore(DateTime(today.year, today.month, today.day));
  }
}

class Comment {
  final String id;
  final String text;
  final String by;
  final String byName;
  final DateTime? at;
  const Comment({required this.id, required this.text, required this.by, required this.byName, this.at});
  factory Comment.fromMap(String id, Map<String, dynamic> m) => Comment(id: id, text: _s(m['text']), by: _s(m['by']), byName: _s(m['byName']).isEmpty ? _s(m['by']) : _s(m['byName']), at: toDate(m['at']));
}

class AuditEntry {
  final String id;
  final String fid;
  final String cve;
  final String system;
  final String action;
  final String text;
  final String by;
  final String byName;
  final DateTime? at;
  const AuditEntry({required this.id, required this.fid, required this.cve, this.system = '', required this.action, required this.text, required this.by, required this.byName, this.at});
  factory AuditEntry.fromMap(String id, Map<String, dynamic> m) => AuditEntry(
        id: id,
        fid: _s(m['fid']),
        cve: _s(m['cve']),
        system: _s(m['system']),
        action: _s(m['action']),
        text: _s(m['text']),
        by: _s(m['by']),
        byName: _s(m['byName']).isEmpty ? _s(m['by']) : _s(m['byName']),
        at: toDate(m['at']),
      );
}

/// "also: A, B +2" for the small tag; empty when nobody else reported the CVE.
String alsoText(List<String> alsoBy, {int show = 2}) {
  if (alsoBy.isEmpty) return '';
  final more = alsoBy.length > show ? ' +${alsoBy.length - show}' : '';
  return 'also: ${alsoBy.take(show).join(', ')}$more';
}

/// A finding appears once for each group of its system. Two copies can differ for a moment; the newest status wins.
Finding newerOf(Finding a, Finding b) {
  final ta = a.statusAt?.millisecondsSinceEpoch ?? 0;
  final tb = b.statusAt?.millisecondsSinceEpoch ?? 0;
  return tb > ta ? b : a;
}
