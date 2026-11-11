// Plain Dart checks for the pure logic (no packages needed):  dart run tool/check_logic.dart
import 'dart:convert';
import 'dart:io';

import '../lib/logic/pdf_lite.dart';
import '../lib/logic/diagnose.dart';
import '../lib/logic/systems.dart';
import '../lib/logic/watch.dart';
import '../lib/logic/resume.dart';
import '../lib/logic/rules.dart';
import '../lib/models/models.dart';

var _fails = 0;
void ok(bool c, String m) {
  if (!c) {
    _fails++;
    print('  FAIL $m');
  } else {
    print('  ok   $m');
  }
}

Finding f(String cve, String label, {String status = 'ongoing', int score = 50, List<String> groups = const ['net'], Map<String, dynamic> extra = const {}}) =>
    Finding.fromMap('s1_$cve', {'cve': cve, 'sid': 's1', 'sysName': 'Core switch', 'label': label, 'score': score, 'status': status, 'groups': groups, ...extra});

void main() {
  print('status names');
  ok(statusFromRemote('false_positive') == Status.falsePositive && statusFromRemote('solved') == Status.solved && statusFromRemote(null) == Status.ongoing, 'remote names map both ways');
  for (final s in Status.values) {
    ok(statusFromRemote(kStatusRemote[s]) == s, 'round trip ${s.name}');
  }
  print('proof of fix');
  ok(solvedProblem(upgrade: true, version: '', actions: '') != null, 'upgrade without a version is refused');
  ok(solvedProblem(upgrade: true, version: ' 2.1 ', actions: '') == null, 'upgrade with a version is fine');
  ok(solvedProblem(upgrade: false, version: '', actions: '  ') != null, 'restriction without actions is refused');
  ok(solvedProblem(upgrade: false, version: '', actions: 'Blocked 443') == null, 'restriction with actions is fine');
  print('who can change what');
  ok(allowedTargets(Status.ongoing, isAdmin: false).contains(Status.solved) && !allowedTargets(Status.ongoing, isAdmin: false).contains(Status.ongoing), 'on-going can go to the other three');
  ok(allowedTargets(Status.accepted, isAdmin: false).isEmpty && allowedTargets(Status.accepted, isAdmin: true).length == 1, 'accepted risk: only an admin can reopen it');
  print('parsing a finding like Scanny for Windows writes it');
  final x = Finding.fromMap('s1_CVE-1', {
    'cve': 'CVE-1', 'sid': 's1', 'sysName': 'Core switch', 'sysVersion': '17.9', 'label': 'critical', 'score': 95.0, 'cvss': 9.8, 'epss': 0.5, 'kev': true, 'fixed': '17.9.5',
    'firstSeen': 1790000000.5, 'groups': ['net', 'srv'], 'status': 'solved', 'steps': ['Upgrade'], 'assignee': 'Ali@Example.com', 'assigneeName': 'Ali',
    'solved': {'upgrade': true, 'version': '17.9.5', 'actions': '', 'by': 'Ali', 'at': DateTime(2026, 11, 9)},
  });
  ok(x.severity == Severity.critical && x.score == 95 && x.kev && x.groups.length == 2 && x.assignee == 'ali@example.com', 'fields');
  ok(x.solved != null && x.solved!.text == 'Upgraded to 17.9.5' && !x.isOpen, 'solved proof is read, and it is not open');
  ok(x.firstSeen != null && x.firstSeen!.year == 2026, 'epoch seconds become a date');
  ok(Finding.fromMap('a', {'gone': true}).isOpen == false && Finding.fromMap('a', {'stale': true}).gone, 'gone/stale findings are closed');
  final p = Finding.fromMap('a', {'status': 'accepted', 'accepted': {'reason': 'lab', 'until': '2027-01-01', 'by': 'Boss'}});
  ok(p.accepted?.until == '2027-01-01' && !p.isOpen, 'accepted risk is read');
  print('filters');
  final all = [f('A', 'critical', score: 95), f('B', 'high', score: 70, groups: ['srv']), f('C', 'medium', status: 'acknowledged', score: 40), f('D', 'low', status: 'solved', score: 10), f('E', 'high', status: 'false_positive', score: 60)];
  ok(applyFilter(all, const FindingFilter()).map((e) => e.cve).join() == 'ABC', 'default: open ones, highest score first');
  ok(applyFilter(all, const FindingFilter(statuses: {Status.solved})).length == 1, 'solved filter');
  ok(applyFilter(all, const FindingFilter(severities: {Severity.critical, Severity.high})).length == 2, 'severity filter');
  ok(applyFilter(all, const FindingFilter(groupId: 'srv')).map((e) => e.cve).join() == 'B', 'group filter');
  ok(applyFilter(all, const FindingFilter(query: 'core')).length == 3, 'search by system name');
  ok(applyFilter([f('M', 'high', extra: {'assignee': 'ali@example.com'}), f('N', 'high')], const FindingFilter(mine: 'Ali@example.com')).length == 1, 'only mine');
  final c = countOpen(all);
  ok(c.critical == 1 && c.high == 1 && c.medium == 1 && c.open == 3, 'counts');
  print('dashboard');
  final nowT = DateTime(2026, 11, 11, 15);
  final fa = f('A', 'high', extra: {'kev': true, 'firstSeen': DateTime(2026, 11, 11, 1)});
  final fb = f('B', 'critical', extra: {'due': '2000-01-01', 'firstSeen': DateTime(2026, 11, 9, 23)});
  final fc = f('C', 'high', status: 'solved', extra: {'firstSeen': DateTime(2026, 10, 1)});
  final dc = dailyCounts([fa, fb, fc], now: nowT);
  ok(dc.length == 14 && dc.last == 1 && dc[11] == 1 && dc.fold<int>(0, (x, y) => x + y) == 2, 'daily counts: today last, older than 14 days left out');
  ok(applyFilter([fa, fb, fc], const FindingFilter(exploited: true)).map((e) => e.cve).join() == 'A', 'exploited filter');
  ok(applyFilter([fa, fb, fc], const FindingFilter(overdueOnly: true)).map((e) => e.cve).join() == 'B', 'overdue filter');
  ok(applyFilter([fa, fb, fc], const FindingFilter(today: true), now: nowT).map((e) => e.cve).join() == 'A', 'new today filter');
  print('share a finding');
  final sh = findingShareText(f('CVE-2026-1', 'critical', extra: {'sysVersion': '17.9', 'headline': 'Remote code execution', 'kev': true, 'fixed': '17.9.5'}));
  ok(sh.startsWith('CVE-2026-1  Critical (exploited in the wild)\nCore switch 17.9\nRemote code execution\nFixed in 17.9.5\n') && sh.endsWith('https://nvd.nist.gov/vuln/detail/CVE-2026-1'), 'share text lines');
  ok(!findingShareText(f('CVE-2', 'low')).contains('Fixed in'), 'no fixed version: no line');
  print('snooze, saved views, what changed');
  final sn = f('SN', 'high', extra: {'snoozeUntil': DateTime(2026, 11, 20)});
  final nowS = DateTime(2026, 11, 11);
  ok(sn.snoozedAt(nowS) && !sn.snoozedAt(DateTime(2026, 11, 21)), 'snoozed only until its date');
  ok(applyFilter([sn, f('OK', 'high')], const FindingFilter(), now: nowS).map((e) => e.cve).join() == 'OK', 'snoozed findings leave the normal open list');
  ok(applyFilter([sn, f('OK', 'high')], const FindingFilter(snoozed: true), now: nowS).map((e) => e.cve).join() == 'SN', 'the Snoozed filter shows only them');
  ok(applyFilter([sn], FindingFilter(statuses: Status.values.toSet()), now: nowS).length == 1, 'Everything still includes them');
  ok(countOpen([f('FAR', 'high', extra: {'snoozeUntil': DateTime(2100)}), f('OK2', 'critical')]).open == 1, 'counts skip snoozed ones');
  final view = SavedView('Mine, exploited', const FindingFilter(severities: {Severity.critical, Severity.high}, mine: 'x@y.z', exploited: true, snoozed: false, statuses: {Status.solved}));
  final back = SavedView.decode(view.encode(), myEmail: 'ali@example.com');
  ok(back != null && back.name == 'Mine, exploited' && back.filter.severities.length == 2 && back.filter.mine == 'ali@example.com' && back.filter.exploited && back.filter.statuses.contains(Status.solved), 'a saved view round trips and uses the signed-in email');
  ok(SavedView.decode('not json') == null && SavedView.decode('{"name":"","f":{}}') == null, 'bad saved views are ignored');
  ok(const FindingFilter().isDefault && !const FindingFilter(today: true).isDefault, 'default filter detection');
  final since = DateTime(2026, 11, 10, 12);
  final c1 = f('N1', 'critical', extra: {'firstSeen': DateTime(2026, 11, 11, 1)});
  final c2 = f('N2', 'low', extra: {'firstSeen': DateTime(2026, 11, 10, 20)});
  final c3 = f('CH', 'high', extra: {'firstSeen': DateTime(2026, 10, 1), 'statusAt': DateTime(2026, 11, 11), 'statusBy': 'sara@example.com'});
  final c4 = f('MY', 'high', extra: {'firstSeen': DateTime(2026, 10, 1), 'statusAt': DateTime(2026, 11, 11), 'statusBy': 'Ali@Example.com'});
  final ch = changesSince([c1, c2, c3, c4], since, 'ali@example.com');
  ok(ch.added == 2 && ch.addedCritical == 1 && ch.changedByOthers == 1 && ch.any, 'what changed counts new findings and other people\'s changes, not mine');
  ok(!changesSince([c3], DateTime(2026, 11, 12), 'x').any, 'nothing new since a later time');
  print('trend and do this today');
  final tNow = DateTime(2026, 11, 11, 15);
  final w1 = f('W1', 'high', extra: {'firstSeen': DateTime(2026, 11, 10)});
  final w2 = f('W2', 'high', extra: {'firstSeen': DateTime(2026, 11, 8)});
  final w3 = f('W3', 'high', extra: {'firstSeen': DateTime(2026, 11, 1)});
  final tr = weekTrend([w1, w2, w3], now: tNow);
  ok(tr.cur == 2 && tr.prev == 1, 'this week 2, the week before 1');
  final kevF = f('K', 'critical', score: 95, extra: {'kev': true});
  final ovF = f('O2', 'high', score: 60, extra: {'due': '2020-01-01'});
  final hi = f('H', 'high', score: 75);
  final low = f('L', 'low', score: 10);
  final snz = f('S', 'critical', score: 99, extra: {'kev': true, 'snoozeUntil': DateTime(2100)});
  final tl = todayList([low, hi, ovF, kevF, snz], now: tNow);
  ok(tl.map((e) => e.f.cve).join(',') == 'K,O2,H', 'exploited first, then overdue, then high score; low and snoozed left out');
  ok(tl.map((e) => e.why).join(',') == 'Exploited,Overdue,Score 75', 'the reason shown for each');
  ok(todayList([low, f('M', 'medium', score: 40)], now: tNow).isEmpty && todayList([kevF, ovF, hi], now: tNow, n: 2).length == 2, 'a calm day is empty; the list is capped');
  print('published, references, sort, ask AI');
  final pf = Finding.fromMap('x', {
    'cve': 'CVE-1', 'label': 'high', 'published': '2025-07-24T12:00:00Z',
    'refs': [
      {'url': 'https://a.example/x', 'tags': ['Vendor Advisory', 'Patch', '', 'a', 'b', 'c']},
      {'url': 'javascript:alert(1)'},
      {'url': 'ftp://x'},
      'junk',
      {'tags': []},
    ],
  });
  ok(pf.published == '2025-07-24' && Finding.fromMap('y', {'cve': 'C'}).published == '' && Finding.fromMap('y', {'cve': 'C'}).refs.isEmpty, 'published date is cut to the day; missing is empty');
  ok(pf.refs.length == 1 && pf.refs.first.url == 'https://a.example/x' && pf.refs.first.tags.join(',') == 'Vendor Advisory,Patch,a,b', 'only web links are kept, at most 4 tags each');
  ok(refLabel('https://www.cisa.gov/known-exploited-vulnerabilities-catalog?field_cve=CVE-2025-20281').startsWith('cisa.gov/known-exploited') && refLabel('https://x.example/${'a' * 200}').length <= 58, 'link labels are short');
  final sa = f('SA', 'high', score: 90, extra: {'published': '2024-01-01'});
  final sb = f('SB', 'high', score: 10, extra: {'published': '2026-05-05'});
  final sc = f('SC', 'high', score: 50);
  ok(applyFilter([sa, sb, sc], const FindingFilter()).map((e) => e.cve).join(',') == 'SA,SC,SB', 'default sort: highest priority');
  ok(applyFilter([sa, sb, sc], const FindingFilter(sort: 'published')).map((e) => e.cve).join(',') == 'SB,SA,SC', 'newest published first, unknown date last');
  ok(!const FindingFilter(sort: 'published').isDefault && FindingFilter.fromMap(const FindingFilter(sort: 'published').toMap()).sort == 'published' && FindingFilter.fromMap({'so': 'weird'}).sort == 'score', 'the sort is part of a saved view');
  ok(aiHistory([('1', 'a'), ('2', ''), ('3', 'c'), ('4', 'd')]) == 'Q: 3\nA: c\nQ: 4\nA: d' && aiHistory(const []) == '', 'chat history: last two answered turns');
  print('activity red dots');
  final tBase = DateTime(2026, 11, 11, 12);
  AuditEntry au(String id, String by, DateTime? at) => AuditEntry(id: id, fid: 'x', cve: 'C', action: 'status', text: 't', by: by, byName: by, at: at);
  final ea1 = au('a1', 'ali@x.com', tBase.add(const Duration(seconds: 5)));
  final ea2 = au('a2', 'BADER@x.com', tBase.add(const Duration(seconds: 6)));
  final ea3 = au('a3', 'ali@x.com', tBase.subtract(const Duration(seconds: 1)));
  final ea4 = au('a4', 'ali@x.com', tBase.add(const Duration(seconds: 9)));
  const rd = {'a4'};
  ok(isUnreadActivity(ea1, 'bader@x.com', tBase, rd), 'somebody else, after the first launch, not opened: unread');
  ok(!isUnreadActivity(ea2, 'bader@x.com', tBase, rd) && !isUnreadActivity(ea3, 'bader@x.com', tBase, rd) && !isUnreadActivity(ea4, 'bader@x.com', tBase, rd) && !isUnreadActivity(au('n', 'a', null), 'b', tBase, rd), 'my own, older, already opened, or not dated yet: not unread');
  ok(activityDot([ea1, ea2, ea3, ea4], 'bader@x.com', tBase, rd, DateTime.fromMillisecondsSinceEpoch(0)), 'the tab has a dot');
  ok(!activityDot([ea1, ea2, ea3, ea4], 'bader@x.com', tBase, rd, tBase.add(const Duration(seconds: 5))) && activityDot([ea1], 'bader@x.com', tBase, rd, tBase.add(const Duration(seconds: 4))), 'the tab dot clears when the tab was opened after the item arrived');
  ok(addRead(['a', 'b'], 'b').join() == 'ab' && addRead(['a'], 'b').join() == 'ab' && addRead([for (var i = 0; i < 400; i++) 'i$i'], 'new').length == 400, 'the list of opened items is kept short');
  print('article search and advisory findings');
  WatchItem mkArt(String id, String title, String summary, String text, {List<String> cves = const [], String feed = 'CIS'}) =>
      WatchItem(id: id, title: title, feed: feed, link: 'https://x/$id', summary: summary, published: '', t: 1, cves: cves, groups: const [], mine: false, text: text);
  final art1 = mkArt('1', 'Fortinet Multiple Products (CVE-2026-126xxx et al.)', 'Multiple vulnerabilities across various Fortinet products', 'SYSTEMS AFFECTED:\nFortiManager 7.6.0 through 7.6.7\nSQL Injection (CVE-2026-126262)', cves: ['CVE-2026-126262']);
  final art2 = mkArt('2', 'Gardening news', 'tomatoes', 'Nothing about networks here');
  ok(watchMatchesQuery(art1, '') && watchMatchesQuery(art1, 'fortimanager') && watchMatchesQuery(art1, 'FORTIMANAGER 7.6') && !watchMatchesQuery(art2, 'fortimanager') && watchMatchesQuery(art1, 'cve-2026-126262'), 'search: every word, any case, in the title, the summary, the text inside or the CVE list');
  ok(!watchMatchesQuery(art1, 'fortimanager tomatoes') && watchMatchesQuery(art2, 'tomatoes nothing'), 'every word must be found');
  ok(watchSnippet(art1, 'fortimanager').contains('FortiManager 7.6.0 through 7.6.7') && watchSnippet(art1, 'fortinet') == '' && watchSnippet(art1, '') == '' && watchSnippet(art2, 'networks').contains('networks'), 'a snippet only when the match is in the text');
  ok(filterWatch([art1, art2], mode: WatchMode.all, myGroups: const {}, isAdmin: true, read: const {}, query: 'fortimanager').map((e) => e.id).join() == '1', 'the filter uses the search');
  final adv = Finding.fromMap('s1_ADV-2026-133', {
    'cve': 'ADV-2026-133', 'label': 'high', 'sysName': 'FortiManager', 'sysVersion': '7.6.2', 'title': 'Fortinet Multiple Products', 'status': 'ongoing',
    'advisory': {'id': 'ADV-2026-133', 'title': 'Fortinet Multiple Products', 'link': 'https://cis.example/2026-133', 'feed': 'CIS', 'version': '7.6.2', 'cves': ['CVE-2026-126170', 'CVE-2026-126262'], 'affected': ['FortiManager 7.6.0 through 7.6.7']},
  });
  ok(adv.advisory != null && adv.advisory!.cves.length == 2 && adv.advisory!.affected.first.startsWith('FortiManager') && Finding.fromMap('x', {'cve': 'C'}).advisory == null && advisoryFrom('junk') == null, 'advisory data is read');
  ok(findingShareText(adv) == 'ADV-2026-133  High\nFortinet Multiple Products\nLists FortiManager 7.6.2 as affected\n2 CVEs\nhttps://cis.example/2026-133', 'sharing an advisory finding: its article, not an NVD page');
  ok(WatchItem.fromMap('9', {'title': 't', 'text': 'inside'}).text == 'inside' && WatchItem.fromMap('9', {'title': 't'}).text == '', 'the text of an article is read');
  print('overdue');
  ok(f('O', 'high', extra: {'due': '2020-01-01'}).overdue && !f('P', 'high', extra: {'due': '2999-01-01'}).overdue && !f('Q', 'high', status: 'solved', extra: {'due': '2020-01-01'}).overdue, 'overdue only while open');
  print('two copies');
  final a1 = f('Z', 'high', extra: {'statusAt': DateTime(2026, 1, 1)});
  final a2 = f('Z', 'high', status: 'solved', extra: {'statusAt': DateTime(2026, 2, 1)});
  ok(newerOf(a1, a2).status == Status.solved && newerOf(a2, a1).status == Status.solved, 'the newest status wins');
  print('sources');
  final dup = f('S', 'high', extra: {'source': 'NIST NVD', 'alsoBy': ['CISA KEV', 'Exploit news', 'Vendor blog']});
  ok(dup.source == 'NIST NVD' && dup.alsoBy.length == 3, 'source and "also reported by" are read');
  ok(alsoText(dup.alsoBy) == 'also: CISA KEV, Exploit news +1' && alsoText(const []) == '' && alsoText(['A']) == 'also: A', 'the small tag text');
  ok(f('T', 'low').alsoBy.isEmpty && f('T', 'low').source == '', 'no source data: no tag');
  print('systems');
  Finding ff(String sid, String sys, int score, {Status st = Status.ongoing, bool gone = false}) => Finding.fromMap('$sid-$score', {'cve': 'CVE-$score', 'sid': sid, 'sysName': sys, 'sysVersion': '1.0', 'label': 'high', 'score': score, 'status': kStatusRemote[st], 'gone': gone, 'groups': ['network']});
  final docs = [const SystemInfo(id: 's1', name: 'Core switch', version: '17.9', groups: ['network']), const SystemInfo(id: 's2', name: 'Quiet box', version: '2.0', groups: ['network']), const SystemInfo(id: 's1', name: 'Core switch', version: '17.9', groups: ['servers'])];
  final srows = systemRows(docs, [ff('s1', 'Core switch', 80), ff('s1', 'Core switch', 40, st: Status.solved), ff('s3', 'Orphan', 90), ff('s2', 'Quiet box', 50, gone: true)]);
  ok(srows.map((r) => r.id).join() == 's3s1s2', 'worst first; a system with no finding still shows; a finding without its system document still shows');
  ok(srows.last.open.isEmpty && srows.last.label == 'Quiet box 2.0', 'a system with no open finding is listed as clean (a "gone" finding does not count)');
  ok(srows[1].groups.toSet().containsAll(['network', 'servers']) && srows[1].findings.length == 2, 'a system in two groups appears once with both groups');
  ok(systemRows(const [], const []).isEmpty, 'nothing at all: empty list');
  const mA = Member(email: 'a@b.com', name: 'A', role: 'member', groups: ['x'], active: true);
  ok(sameAccess(mA, const Member(email: 'a@b.com', name: 'A2', role: 'member', groups: ['x'], active: true)) && !sameAccess(mA, const Member(email: 'a@b.com', name: 'A', role: 'member', groups: ['x', 'y'], active: true)) && !sameAccess(mA, const Member(email: 'a@b.com', name: 'A', role: 'admin', groups: ['x'], active: true)) && !sameAccess(mA, const Member(email: 'a@b.com', name: 'A', role: 'member', groups: ['y'], active: true)), 'a change of groups or role means: reload; a change of name does not');
  print('diagnose');
  Situation sit({bool admin = false, int groups = 1, int findings = 0, int systems = 0, bool online = true, Map<String, String> errors = const {}}) => Situation(email: 'a@b.com', isAdmin: admin, groups: groups, findings: findings, systems: systems, online: online, errors: errors, project: 'scanny-x');
  ok(explainEmpty(sit(findings: 3)) == null, 'with data there is nothing to explain');
  ok(explainEmpty(sit(groups: 0))!.title == 'No group is assigned to you' && explainEmpty(sit(groups: 0))!.steps.first.contains('a@b.com'), 'a member with no group is told to ask for one');
  ok(explainEmpty(sit(admin: true, groups: 0))!.title.startsWith('Scanny for Windows has not sent') && explainEmpty(sit(admin: true, groups: 0))!.steps.any((x) => x.contains('scanny-x')), 'an admin with no groups: Windows has not synced, same project');
  ok(explainEmpty(sit(errors: {'findings g1': '[cloud_firestore/permission-denied] x'}))!.title.contains('refused'), 'permission-denied is explained first');
  ok(explainEmpty(sit(groups: 2, systems: 0))!.title.contains('no systems'), 'groups without systems');
  ok(explainEmpty(sit(groups: 2, systems: 4))!.title == 'No open findings', 'systems but no findings is good news');
  ok(explainEmpty(sit(online: false))!.title == 'No connection yet', 'offline with no saved copy');
  print('watch');
  final wm = Member.fromMap('Ali@Example.com', {'name': 'Ali', 'role': 'member', 'groups': ['network'], 'active': true, 'watch': true});
  ok(wm.watch && wm.canWatch && !wm.isAdmin, 'member with the switch on can read the articles');
  ok(!Member.fromMap('b@x.com', {'role': 'member', 'active': true}).canWatch && Member.fromMap('c@x.com', {'role': 'admin', 'active': true}).canWatch, 'no switch: no articles; admins always');
  WatchItem wi(String id, String feed, double t, {bool mine = false, List<String> groups = const [], String pub = ''}) => WatchItem.fromMap(id, {'title': 'T$id', 'feed': feed, 'link': 'https://x.example/$id', 'summary': 's', 'published': pub, 't': t, 'cves': ['CVE-2026-1'], 'groups': groups, 'mine': mine});
  final items = [wi('a', 'Cisco PSIRT', 100, mine: true, groups: ['network']), wi('b', 'Hacker News', 300), wi('c', 'Cisco PSIRT', 200, mine: true, groups: ['servers']), wi('d', 'Hacker News', 50, pub: '2026-11-10T10:00:00Z')];
  ok(wi('x', 'F', 5).cves.length == 1 && wi('x', 'F', 5).t == 5, 'article fields are read');
  ok(filterWatch(items, mode: WatchMode.all, myGroups: {'network'}, isAdmin: false, read: {}).map((i) => i.id).join() == 'dbca', 'newest first; the published date beats the time Scanny saw it');
  ok(filterWatch(items, mode: WatchMode.mine, myGroups: {'network'}, isAdmin: false, read: {}).map((i) => i.id).join() == 'a', 'mentions: only articles that mention MY groups');
  ok(filterWatch(items, mode: WatchMode.mine, myGroups: {'network'}, isAdmin: true, read: {}).map((i) => i.id).join() == 'ca', 'an admin sees every mention');
  ok(filterWatch(items, mode: WatchMode.unread, myGroups: {}, isAdmin: false, read: {'b', 'd'}).map((i) => i.id).join() == 'ca', 'unread hides what this phone opened');
  ok(filterWatch(items, mode: WatchMode.all, myGroups: {}, isAdmin: false, read: {}, feed: 'Cisco PSIRT').length == 2, 'feed filter');
  ok(articleOpenFrom('browser') == ArticleOpen.browser && articleOpenFrom('reader') == ArticleOpen.reader && articleOpenFrom(null) == ArticleOpen.reader && articleOpenFrom('weird') == ArticleOpen.reader, 'the open-articles choice defaults to the reader');
  const page = '<html><head><title>Fallback</title><meta property="og:title" content="Chrome fixes a zero-day &amp; more"></head><body><nav><p>Subscribe to our newsletter please</p></nav><script>var x=1;</script>'
      '<article><h1>Chrome fixes a zero-day</h1><p>Google released an update on Monday that patches nine vulnerabilities, one of them exploited in the wild.</p><h2>Who is affected</h2>'
      '<p>All users of Chrome before 99 are affected by CVE-2026-0001 &mdash; update now. It&#39;s urgent.</p><ul><li>Windows</li><li>macOS</li></ul><pre>chrome --version</pre>'
      '<p>Same line</p><p>Same line</p></article><footer><p>Copyright notice that must not appear.</p></footer></body></html>';
  final art = extractArticle(page);
  ok(art.title == 'Chrome fixes a zero-day & more', 'title from og:title, entities decoded');
  ok(art.blocks.first.kind == 'h' && art.blocks.first.text == 'Chrome fixes a zero-day' && art.readable, 'headings and paragraphs are kept');
  ok(art.blocks.where((b) => b.kind == 'li').length == 2 && art.blocks.any((b) => b.kind == 'pre'), 'list items and code are kept');
  ok(!art.blocks.any((b) => b.text.contains('newsletter') || b.text.contains('Copyright') || b.text.contains('var x')), 'menus, scripts and footers are dropped');
  ok(art.blocks.any((b) => b.text.contains("- update now. It's urgent.")), 'numeric and named entities');
  ok(art.blocks.where((b) => b.text == 'Same line').length == 1, 'repeated lines are shown once');
  final bare = extractArticle('<html><body><div><h2>Heading</h2><p>short</p><p>${'A long enough paragraph about the problem. ' * 3}</p></div></body></html>');
  ok(bare.blocks.map((b) => b.kind).join() == 'hp', 'a page without <article> keeps headings and real paragraphs only');
  ok(!extractArticle('<html><body><p>tiny</p></body></html>').readable && !extractArticle('').readable, 'a page with no text is not readable (the screen then shows the summary)');
  print('pdf');
  final rows = [for (var i = 0; i < 120; i++) ['CVE-2026-${1000 + i}', 'Critical 9${i % 10}', 'Core switch 17.9 (Network) \u0627\u0644\u0634\u0628\u0643\u0629', 'On-going', '2026-12-01', 'A long summary (with parentheses) and a back\\slash that has to wrap onto several lines because it is far too long for the column ' * 2]];
  final pdf = buildTablePdf(title: 'Scanny - Network', subtitle: 'Created now', head: const ['CVE', 'Severity', 'System', 'Status', 'Due', 'Summary'], rows: rows, widths: const [70, 52, 170, 66, 56, 260]);
  final txt = latin1.decode(pdf);
  ok(txt.startsWith('%PDF-1.4') && txt.trimRight().endsWith('%%EOF'), 'pdf header and trailer');
  final count = int.parse(RegExp(r'/Count (\d+)').firstMatch(txt)!.group(1)!);
  ok(count >= 3, 'many rows run onto several pages ($count pages)');
  final xrefAt = int.parse(RegExp(r'startxref\n(\d+)').firstMatch(txt)!.group(1)!);
  ok(txt.substring(xrefAt).startsWith('xref'), 'startxref points at the xref table');
  final entries = RegExp(r'(\d{10}) 00000 n ').allMatches(txt.substring(xrefAt)).map((m) => int.parse(m.group(1)!)).toList();
  var good = entries.isNotEmpty;
  for (var i = 0; i < entries.length; i++) {
    if (!txt.substring(entries[i]).startsWith('${i + 1} 0 obj')) good = false;
  }
  ok(good && entries.length == 4 + count * 2, 'every xref offset points at its object (${entries.length} objects)');
  ok(!txt.contains('\u0627') && txt.contains('?'), 'non-Latin text is replaced by ? and the file stays plain ASCII for those characters');
  ok(txt.contains('\\(with') || txt.contains('\\(') , 'parentheses and backslashes are escaped');
  ok(wrapText('aaaa bbbb cccc dddd eeee ffff', 9, 2).length == 2 && wrapText('x' * 40, 10, 3).length == 3 && wrapText('', 10, 3).length == 1, 'wrapping');
  final empty = latin1.decode(buildTablePdf(title: 'T', subtitle: 'S', head: const ['A'], rows: const [], widths: const [1]));
  ok(empty.contains('No findings for this choice'), 'an empty export still makes a valid page');
  File('/tmp/check.pdf').writeAsBytesSync(pdf);
  print('csv');
  final csv = findingsCsv([f('CVE-9', 'critical', extra: {'headline': 'RCE, remote "bad"', 'assigneeName': 'Ali'})], (g) => g == 'net' ? 'Network' : g);
  final lines = csv.trim().split('\r\n');
  ok(lines.length == 2 && lines[0].startsWith('CVE,Severity') && lines[1].contains('"RCE, remote ""bad"""') && lines[1].contains('Network') && lines[1].contains('Ali'), 'csv escaping and group names');
  print('time and pin');
  ok(ago(DateTime(2026, 1, 1), now: DateTime(2026, 1, 1, 0, 5)) == '5 min ago' && ago(null) == '', 'relative time');
  ok(hashPinText('١٢٣٤') == '1234' && hashPinText('۱۲۳۴') == '1234', 'arabic digits in a PIN');
  print('share text');
  final mi = WatchItem.fromMap('m1', {'title': 'T', 'feed': 'F', 'link': '', 'summary': '', 'published': '', 't': 1, 'cves': [], 'groups': ['g1'], 'mine': true, 'mentions': {'g1': ['s1'], 'g2': ['s2', 's3']}});
  String nm(String id) => {'s1': 'wordpress'}[id] ?? '';
  ok(mentionedIds(mi, {'g1'}, false).join(',') == 's1' && mentionLabel(mentionedIds(mi, {'g1'}, false), nm) == 'Mentions wordpress', 'one system is named');
  ok(mentionedIds(mi, {'g1'}, true).length == 3 && mentionLabel(mentionedIds(mi, {'g1'}, true), nm) == 'Mentions 3 systems', 'several systems are counted (admin sees all groups)');
  ok(mentionedIds(mi, {'g9'}, false).isEmpty && !mentionsMe(mi, {'g9'}, false) && mentionLabel([], nm) == 'Mentions your systems' && mentionLabel(['s9'], nm) == 'Mentions 1 system', 'other groups stay hidden');
  ok(isTestGroup('rt-a-eu4kzp') && isTestGroup('rt-b-qf6pew') && !isTestGroup('net') && !isTestGroup('rt-a-evil') && !isTestGroup('_unassigned'), 'wizard self-test groups are hidden, real ones are not');
  final shareItem = WatchItem(id: 'w1', title: '  Chrome zero-day fixed ', feed: 'Vendor', link: ' https://example.com/a ', summary: '', published: '', t: 0, cves: const [], groups: const [], mine: false);
  ok(shareText(shareItem) == 'Chrome zero-day fixed\nhttps://example.com/a', 'shared text is the title and the link on its own line');
  print('update resume');
  final pm = PartMeta(key: '1.3.0+30', url: 'https://x/Scanny.apk', total: 1000);
  ok(PartMeta.tryParse(pm.toJson())!.total == 1000 && PartMeta.tryParse('junk') == null && PartMeta.tryParse(null) == null, 'meta round trip and bad data');
  ok(resumeFrom(meta: pm, key: '1.3.0+30', url: 'https://x/Scanny.apk', partLength: 400, total: 1000) == 400, 'continues from the saved byte');
  ok(resumeFrom(meta: pm, key: '1.3.1+31', url: 'https://x/Scanny.apk', partLength: 400, total: 1000) == 0, 'another version starts again');
  ok(resumeFrom(meta: pm, key: '1.3.0+30', url: 'https://y/Scanny.apk', partLength: 400, total: 1000) == 0, 'another address starts again');
  ok(resumeFrom(meta: pm, key: '1.3.0+30', url: 'https://x/Scanny.apk', partLength: 1200, total: 1000) == 0 && resumeFrom(meta: null, key: 'k', url: 'u', partLength: 5, total: 9) == 0 && resumeFrom(meta: pm, key: '1.3.0+30', url: 'https://x/Scanny.apk', partLength: 0, total: 1000) == 0, 'impossible parts start again');
  ok(rangeHeader(0) == null && rangeHeader(400) == 'bytes=400-', 'range header');
  ok(totalFromContentRange('bytes 400-999/1000') == 1000 && totalFromContentRange('bytes */1000') == 1000 && totalFromContentRange(null) == null && totalFromContentRange('bytes 1-2/*') == null, 'content-range total');
  ok([0, 1, 2, 3, 4, 9].map(retrySeconds).join(',') == '2,4,8,16,30,30', 'retry waits grow and stop at 30 s');
  ok(isRetryable('SocketException: x') && isRetryable('HTTP 503') && isRetryable('HTTP 429') && !isRetryable('HTTP 404') && !isRetryable('corrupt') && !isRetryable('The update address is not https.'), 'which errors are tried again');
  ok(megabytes(5 * 1024 * 1024) == '5.0' && megabytes(60 * 1024 * 1024) == '60', 'megabytes text');
  print(_fails == 0 ? '\nALL LOGIC CHECKS PASSED' : '\n$_fails FAILED');
  if (_fails != 0) throw StateError('failed');
}
