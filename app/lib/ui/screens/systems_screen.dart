import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../logic/systems.dart';
import '../../models/models.dart';
import '../../state/data_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/empty_explain.dart';
import 'findings_screen.dart';

/// The systems my groups manage, worst first: every system document Scanny for Windows sent, with or without findings (no extra reads).
class SystemsScreen extends StatelessWidget {
  const SystemsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final d = context.watch<DataService>();
    final rows = systemRows(d.systemDocs, d.findings);
    final t = Theme.of(context);
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 6), child: Align(alignment: Alignment.centerLeft, child: Text('Systems', style: t.textTheme.headlineSmall))),
      Expanded(
        child: rows.isEmpty
            ? const EmptyExplain(fallback: 'No systems yet.')
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (c, i) {
                  final r = rows[i];
                  final open = r.open;
                  final w = r.worst;
                  final sev = open.isEmpty ? Severity.low : open.map((x) => x.severity).reduce((a, b) => a.index < b.index ? a : b);
                  return Stagger(
                    index: i,
                    child: PressScale(
                      child: GlowCard(
                    stripe: open.isEmpty ? const Color(0xFF4CD964) : severityColor(sev),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      leading: open.isEmpty ? const Icon(Icons.check_circle_rounded, color: Color(0xFF4CD964), size: 34) : SeverityRing(severity: sev, score: w),
                      title: Text(r.label),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Wrap(spacing: 6, runSpacing: 4, children: [
                          Pill(open.isEmpty ? 'No open findings' : '${open.length} open', color: open.isEmpty ? const Color(0xFF4CD964) : severityColor(sev)),
                          for (final g in r.groups) GroupDot(group: d.group(g), fallback: g),
                        ]),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FindingsScreen(systemId: r.id, title: r.label))),
                    ),
                  ),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}
