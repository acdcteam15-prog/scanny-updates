import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';

enum Access { loading, ok, denied, error }

/// Everything the phone reads from and writes to Firestore.
/// The layout is made by Scanny for Windows: groups/{gid}/{systems|findings|comments|audit}, members/{email}, devices/{id}.
/// Reads are scoped by group, so each person only ever asks for the groups they belong to (admins: all of them).
class DataService extends ChangeNotifier {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  User? _user;
  Access access = Access.loading;
  String? error;
  Member? me;
  List<GroupInfo> groups = [];

  /// False when the data on screen comes from the phone's saved copy only. Changes are then switched off.
  bool online = true;

  final Map<String, Map<String, Finding>> _byGroup = {};
  final List<StreamSubscription<dynamic>> _subs = [];
  Map<String, Finding> _merged = {};
  Timer? _offlineTimer;
  final Map<String, Map<String, SystemInfo>> _systemsByGroup = {};
  final List<StreamSubscription<dynamic>> _groupSubs = [];

  VoidCallback? onFindingsChanged;

  /// Zero-day watch articles (only when the admin switched it on for this person, or for admins).
  List<WatchItem> watchItems = [];
  StreamSubscription<dynamic>? _watchSub;
  bool get canWatch => me?.canWatch ?? false;

  String get email => (_user?.email ?? '').toLowerCase();
  String get displayName => me?.name ?? (_user?.displayName ?? email);
  bool get isAdmin => me?.isAdmin ?? false;

  List<Finding> get findings => _merged.values.toList();

  /// Problems the live streams reported (for example permission-denied), by stream. Shown on the empty screen and in Connection details.
  final Map<String, String> streamErrors = {};
  List<SystemInfo> get systemDocs => [for (final m in _systemsByGroup.values) ...m.values];
  int get systemsCount => {for (final x in systemDocs) x.id}.length;
  Finding? finding(String fid) => _merged[fid];

  GroupInfo? group(String id) {
    for (final g in groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  String groupName(String id) => id == '_unassigned' ? 'Unassigned' : (group(id)?.name ?? id);

  /// Groups this person may read and write.
  List<String> get myGroupIds => groups.map((g) => g.id).toList();

  List<Person> get people {
    final seen = <String, Person>{};
    for (final g in groups) {
      for (final p in g.people) {
        seen[p.email] = p;
      }
    }
    return seen.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  int systemCount(String gid) => _systemsByGroup[gid]?.length ?? 0;
  List<String> get systemKeys {
    final all = <String>{};
    for (final m in _systemsByGroup.values) {
      all.addAll(m.keys);
    }
    return all.toList();
  }

  // ------------------------------------------------------------------ attach / detach
  Future<void> attach(User u) async {
    if (_user?.uid == u.uid && access != Access.error) return;
    detach(notify: false);
    _user = u;
    access = Access.loading;
    error = null;
    notifyListeners();
    try {
      final snap = await _db.collection('members').doc(email).get();
      if (!snap.exists) {
        access = Access.denied;
        notifyListeners();
        return;
      }
      final m = Member.fromMap(snap.id, snap.data() ?? {});
      if (!m.active) {
        access = Access.denied;
        notifyListeners();
        return;
      }
      me = m;
      await _startGroups();
      if (m.canWatch) _listenWatch();
      _listenMe();
      access = Access.ok;
    } on FirebaseException catch (e) {
      access = Access.error;
      error = '${e.code}: ${e.message ?? ''}';
    } catch (e) {
      access = Access.error;
      error = '$e';
    }
    notifyListeners();
  }

  Future<List<GroupInfo>> _loadGroups(Member m) async {
    final out = <GroupInfo>[];
    if (m.isAdmin) {
      final q = await _db.collection('groups').get();
      for (final d in q.docs) {
        if (isTestGroup(d.id)) continue;
        out.add(GroupInfo.fromMap(d.id, d.data()));
      }
    } else {
      for (final id in m.groups) {
        final d = await _db.collection('groups').doc(id).get();
        if (d.exists) out.add(GroupInfo.fromMap(d.id, d.data() ?? {}));
      }
    }
    out.sort((a, b) {
      if (a.id == '_unassigned') return 1;
      if (b.id == '_unassigned') return -1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  /// (Re)loads the groups this person may see and starts one stream per group. Called at sign-in, when the admin changes the groups of this
  /// person while the app is open, and by "Reload".
  Future<void> _startGroups() async {
    for (final x in _groupSubs) {
      x.cancel();
    }
    _groupSubs.clear();
    _byGroup.clear();
    _systemsByGroup.clear();
    _merged = {};
    streamErrors.clear();
    final m = me;
    if (m == null) return;
    groups = await _loadGroups(m);
    for (final g in groups) {
      _listen(g.id);
    }
    notifyListeners();
    onFindingsChanged?.call();
  }

  /// Reads my member record again (groups, admin, Zero-day watch) and restarts the group streams.
  Future<void> reload() async {
    if (_user == null) return;
    try {
      final snap = await _db.collection('members').doc(email).get();
      if (snap.exists) {
        final had = canWatch;
        me = Member.fromMap(snap.id, snap.data() ?? {});
        if (canWatch && !had) _listenWatch();
        if (!canWatch && had) _stopWatch();
      }
      await _startGroups();
    } on FirebaseException catch (e) {
      streamErrors['reload'] = '${e.code}: ${e.message ?? ''}';
      notifyListeners();
    }
  }

  void _listen(String gid) {
    final col = _db.collection('groups').doc(gid);
    _groupSubs.add(col.collection('findings').snapshots(includeMetadataChanges: true).listen((s) {
      _trackOnline(s.metadata.isFromCache);
      final map = <String, Finding>{};
      for (final d in s.docs) {
        map[d.id] = Finding.fromMap(d.id, _plain(d.data()));
      }
      _byGroup[gid] = map;
      streamErrors.remove('findings $gid');
      _remerge();
    }, onError: (Object e) {
      debugPrint('findings $gid: $e');
      streamErrors['findings $gid'] = '$e';
      notifyListeners();
    }));
    _groupSubs.add(col.collection('systems').snapshots().listen((s) {
      _systemsByGroup[gid] = {for (final d in s.docs) d.id: SystemInfo.fromMap(d.id, _plain(d.data()), group: gid)};
      streamErrors.remove('systems $gid');
      notifyListeners();
    }, onError: (Object e) {
      debugPrint('systems $gid: $e');
      streamErrors['systems $gid'] = '$e';
      notifyListeners();
    }));
  }

  void _listenWatch() {
    _watchSub?.cancel();
    _watchSub = _db.collection('watch').orderBy('t', descending: true).limit(60).snapshots().listen((s) {
      watchItems = [for (final d in s.docs) WatchItem.fromMap(d.id, _plain(d.data()))];
      notifyListeners();
    }, onError: (Object e) {
      debugPrint('watch: $e');
    });
  }

  void _stopWatch() {
    _watchSub?.cancel();
    _watchSub = null;
    watchItems = [];
  }

  /// My own member record: the admin can switch Zero-day watch on or off for me while the app is open.
  void _listenMe() {
    _subs.add(_db.collection('members').doc(email).snapshots().listen((s) {
      if (!s.exists || me == null) return;
      final had = canWatch;
      final before = me!;
      me = Member.fromMap(s.id, s.data() ?? {});
      if (canWatch && !had) _listenWatch();
      if (!canWatch && had) _stopWatch();
      if (!sameAccess(before, me!)) {
        _startGroups();
      } else {
        notifyListeners();
      }
    }, onError: (Object e) {
      debugPrint('member: $e');
    }));
  }

  void _trackOnline(bool fromCache) {
    if (!fromCache) {
      _offlineTimer?.cancel();
      _offlineTimer = null;
      if (!online) {
        online = true;
        notifyListeners();
      }
    } else if (online && _offlineTimer == null) {
      _offlineTimer = Timer(const Duration(seconds: 6), () {
        _offlineTimer = null;
        online = false;
        notifyListeners();
      });
    }
  }

  void _remerge() {
    final out = <String, Finding>{};
    for (final m in _byGroup.values) {
      for (final e in m.entries) {
        final cur = out[e.key];
        out[e.key] = cur == null ? e.value : newerOf(cur, e.value);
      }
    }
    _merged = out;
    notifyListeners();
    onFindingsChanged?.call();
  }

  void detach({bool notify = true}) {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    for (final x in _groupSubs) {
      x.cancel();
    }
    _groupSubs.clear();
    _stopWatch();
    _offlineTimer?.cancel();
    _offlineTimer = null;
    _byGroup.clear();
    _systemsByGroup.clear();
    streamErrors.clear();
    _merged = {};
    _user = null;
    me = null;
    groups = [];
    online = true;
    access = Access.loading;
    if (notify) notifyListeners();
  }

  @override
  void dispose() {
    detach(notify: false);
    super.dispose();
  }

  // ------------------------------------------------------------------ writes
  void _needOnline() {
    if (!online) throw StateError('You are offline. Findings are read-only until the connection is back.');
    if (_user == null || me == null) throw StateError('Not signed in.');
  }

  /// Groups of this finding that this person may write to. Scanny for Windows copies the change to the other groups.
  List<String> _writable(Finding f) {
    final mine = myGroupIds.toSet();
    final out = f.groups.where(mine.contains).toList();
    return out.isEmpty ? f.groups.where((g) => isAdmin).toList() : out;
  }

  String _newId(String p) => '$p${DateTime.now().millisecondsSinceEpoch}${_user!.uid.substring(0, 3)}';

  DocumentReference<Map<String, dynamic>> _fRef(String gid, String fid) => _db.collection('groups').doc(gid).collection('findings').doc(fid);

  void _audit(WriteBatch b, String gid, String id, Finding f, String action, String text, [Map<String, dynamic>? detail]) {
    b.set(_db.collection('groups').doc(gid).collection('audit').doc(id), {
      'fid': f.fid,
      'cve': f.cve,
      'system': f.system,
      'action': action,
      'text': text,
      'by': email,
      'byName': displayName,
      'at': FieldValue.serverTimestamp(),
      if (detail != null) 'detail': detail,
    });
  }

  Future<void> setStatus(Finding f, Status to, {Proof? proof}) async {
    _needOnline();
    final gids = _writable(f);
    if (gids.isEmpty) throw StateError('You cannot change this finding.');
    final b = _db.batch();
    final aid = _newId('a');
    final now = DateTime.now();
    for (final gid in gids) {
      b.update(_fRef(gid, f.fid), {
        'status': kStatusRemote[to],
        'solved': to == Status.solved && proof != null
            ? {'upgrade': proof.upgrade, 'version': proof.version.trim(), 'actions': proof.actions.trim(), 'by': displayName, 'at': Timestamp.fromDate(now)}
            : FieldValue.delete(),
        'statusAt': FieldValue.serverTimestamp(),
        'statusBy': email,
        'statusByName': displayName,
      });
      final text = '${kStatusLabel[f.status]} -> ${kStatusLabel[to]}${to == Status.solved && proof != null ? ': ${proof.text}' : ''}';
      _audit(b, gid, aid, f, 'status', text, {'from': kStatusRemote[f.status], 'to': kStatusRemote[to]});
    }
    await b.commit();
  }

  Future<void> setAssignee(Finding f, Person? p) async {
    _needOnline();
    final gids = _writable(f);
    if (gids.isEmpty) throw StateError('You cannot change this finding.');
    final b = _db.batch();
    final aid = _newId('a');
    for (final gid in gids) {
      b.update(_fRef(gid, f.fid), {
        'assignee': p?.email ?? '',
        'assigneeName': p?.name ?? '',
        'statusAt': FieldValue.serverTimestamp(),
        'statusBy': email,
        'statusByName': displayName,
      });
      _audit(b, gid, aid, f, 'assign', p == null ? 'Assignment removed' : 'Assigned to ${p.name}');
    }
    await b.commit();
  }

  Future<void> addComment(Finding f, String text) async {
    _needOnline();
    final t = text.trim();
    if (t.isEmpty) throw StateError('Write a comment first.');
    final gids = _writable(f);
    if (gids.isEmpty) throw StateError('You cannot comment on this finding.');
    final b = _db.batch();
    final cid = _newId('c');
    final aid = _newId('a');
    for (final gid in gids) {
      b.set(_db.collection('groups').doc(gid).collection('comments').doc(cid), {
        'fid': f.fid,
        'cve': f.cve,
        'text': t.length > 2000 ? t.substring(0, 2000) : t,
        'by': email,
        'byName': displayName,
        'at': FieldValue.serverTimestamp(),
      });
      _audit(b, gid, aid, f, 'comment', 'Commented: ${t.length > 160 ? t.substring(0, 160) : t}');
    }
    await b.commit();
  }

  // ------------------------------------------------------------------ comments, history, activity
  String _readGroup(Finding f) {
    final mine = myGroupIds.toSet();
    for (final g in f.groups) {
      if (mine.contains(g)) return g;
    }
    return f.groups.isNotEmpty ? f.groups.first : '_unassigned';
  }

  Stream<List<Comment>> comments(Finding f) {
    return _db.collection('groups').doc(_readGroup(f)).collection('comments').where('fid', isEqualTo: f.fid).snapshots().map((s) {
      final l = s.docs.map((d) => Comment.fromMap(d.id, _plain(d.data()))).toList();
      l.sort((a, b) => (a.at ?? DateTime.now()).compareTo(b.at ?? DateTime.now()));
      return l;
    });
  }

  Stream<List<AuditEntry>> history(Finding f) {
    return _db.collection('groups').doc(_readGroup(f)).collection('audit').where('fid', isEqualTo: f.fid).snapshots().map((s) {
      final l = s.docs.map((d) => AuditEntry.fromMap(d.id, _plain(d.data()))).toList();
      l.sort((a, b) => (b.at ?? DateTime.now()).compareTo(a.at ?? DateTime.now()));
      return l;
    });
  }

  /// The latest changes across all my groups (each group's newest 40, merged).
  Stream<List<AuditEntry>> activity() {
    final c = StreamController<List<AuditEntry>>();
    final per = <String, List<AuditEntry>>{};
    final subs = <StreamSubscription<dynamic>>[];
    void emit() {
      final seen = <String, AuditEntry>{};
      for (final l in per.values) {
        for (final e in l) {
          seen[e.id] = e;
        }
      }
      final all = seen.values.toList()..sort((a, b) => (b.at ?? DateTime.now()).compareTo(a.at ?? DateTime.now()));
      if (!c.isClosed) c.add(all.take(100).toList());
    }

    for (final g in groups) {
      subs.add(_db.collection('groups').doc(g.id).collection('audit').orderBy('at', descending: true).limit(40).snapshots().listen((s) {
        per[g.id] = s.docs.map((d) => AuditEntry.fromMap(d.id, _plain(d.data()))).toList();
        emit();
      }, onError: (Object e) => debugPrint('activity ${g.id}: $e')));
    }
    c.onCancel = () {
      for (final s in subs) {
        s.cancel();
      }
    };
    return c.stream;
  }

  /// Firestore timestamps become DateTime so the pure-Dart models can read them.
  static Map<String, dynamic> _plain(Map<String, dynamic> m) {
    dynamic conv(dynamic v) {
      if (v is Timestamp) return v.toDate();
      if (v is Map) return v.map((k, x) => MapEntry('$k', conv(x)));
      if (v is List) return v.map(conv).toList();
      return v;
    }

    return conv(m) as Map<String, dynamic>;
  }
}
