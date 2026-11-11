// Pure Dart: the Systems list. A system shows up when Scanny for Windows sent its document, even if it has no finding at all.
import '../models/models.dart';

class SystemRow {
  final String id;
  final String name;
  final String version;
  final List<String> groups;
  final List<Finding> findings;
  const SystemRow({required this.id, required this.name, required this.version, required this.groups, required this.findings});

  List<Finding> get open => findings.where((f) => f.isOpen).toList();
  int get worst => open.fold(0, (w, f) => f.score > w ? f.score : w);
  String get label => '$name $version'.trim();
}

/// [docs]: system documents by id (from every group I can see). [findings]: what the phone received.
List<SystemRow> systemRows(Iterable<SystemInfo> docs, Iterable<Finding> findings) {
  final bySid = <String, List<Finding>>{};
  for (final f in findings) {
    if (f.gone) continue;
    bySid.putIfAbsent(f.sid, () => []).add(f);
  }
  final out = <String, SystemRow>{};
  for (final d in docs) {
    final prev = out[d.id];
    out[d.id] = SystemRow(id: d.id, name: d.name, version: d.version, groups: {...?prev?.groups, ...d.groups}.toList(), findings: bySid[d.id] ?? const []);
  }
  for (final e in bySid.entries) {
    if (out.containsKey(e.key)) continue;                       // a finding whose system document did not arrive: still show the system
    final f0 = e.value.first;
    out[e.key] = SystemRow(id: e.key, name: f0.system, version: f0.sysVersion, groups: f0.groups, findings: e.value);
  }
  final rows = out.values.toList();
  rows.sort((a, b) {
    final c = b.worst.compareTo(a.worst);
    return c != 0 ? c : a.label.toLowerCase().compareTo(b.label.toLowerCase());
  });
  return rows;
}
