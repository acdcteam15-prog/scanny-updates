import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../logic/rules.dart';
import '../../models/models.dart';
import '../../state/data_service.dart';
import '../../state/prefs.dart';
import '../widgets/common.dart';
import 'finding_detail_screen.dart';

/// Who changed what, across all my groups: the same audit log Scanny for Windows shows.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});
  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  Stream<List<AuditEntry>>? _stream;
  int _groups = -1;

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DataService>();
    if (_stream == null || _groups != d.groups.length) {
      _groups = d.groups.length;
      _stream = d.activity();
    }
    final t = Theme.of(context);
    final prefs = context.watch<LocalPrefs>();
    final base = DateTime.fromMillisecondsSinceEpoch(prefs.activityBaseMs);
    final read = prefs.activityRead;
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 6), child: Align(alignment: Alignment.centerLeft, child: Text('Activity', style: t.textTheme.headlineSmall))),
      Expanded(
        child: StreamBuilder<List<AuditEntry>>(
          stream: _stream,
          builder: (c, s) {
            final list = s.data ?? const <AuditEntry>[];
            if (list.isEmpty) {
              if (s.connectionState == ConnectionState.waiting) return Center(child: Text('Loading…', style: TextStyle(color: t.colorScheme.onSurfaceVariant)));
              return const EmptyState(icon: Icons.history_rounded, title: 'No activity yet', body: 'Status changes, comments and assignments in your groups show up here.');
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (c, i) {
                final e = list[i];
                final unread = isUnreadActivity(e, d.email, base, read);
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                  leading: Badge(isLabelVisible: unread, smallSize: 10, child: Icon(e.action == 'comment' ? Icons.chat_bubble_outline_rounded : (e.action == 'assign' ? Icons.person_outline_rounded : Icons.flag_outlined))),
                  title: Text('${e.cve}  ${e.system}'.trim(), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  subtitle: Text('${e.text}\n${e.byName} · ${ago(e.at)}'),
                  isThreeLine: true,
                  onTap: () {
                    prefs.markActivityRead(e.id); // this item's dot goes away once it is opened
                    if (d.finding(e.fid) != null) Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FindingDetailScreen(fid: e.fid)));
                  },
                );
              },
            );
          },
        ),
      ),
    ]);
  }
}
