import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../firebase_options.dart';
import '../../logic/diagnose.dart';
import '../../state/data_service.dart';
import '../theme.dart';
import 'common.dart';

Situation situationOf(DataService d) => Situation(
      email: d.email,
      isAdmin: d.isAdmin,
      groups: d.groups.length,
      findings: d.findings.length,
      systems: d.systemsCount,
      online: d.online,
      errors: d.streamErrors,
      project: DefaultFirebaseOptions.currentPlatform.projectId,
    );

/// Shown instead of a blank list: says why there is nothing, and what to do.
class EmptyExplain extends StatelessWidget {
  final String fallback;
  const EmptyExplain({super.key, this.fallback = 'Nothing here yet.'});

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DataService>();
    final t = Theme.of(context);
    final e = explainEmpty(situationOf(d));
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.inbox_outlined, size: 44, color: t.colorScheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(e?.title ?? fallback, textAlign: TextAlign.center, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          if (e != null) ...[
            const SizedBox(height: 8),
            Text(e.body, textAlign: TextAlign.center, style: TextStyle(color: t.colorScheme.onSurfaceVariant, height: 1.4)),
            if (e.steps.isNotEmpty) ...[
              const SizedBox(height: 14),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (var i = 0; i < e.steps.length; i++) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('${i + 1}.  ${e.steps[i]}', style: const TextStyle(height: 1.4))),
                  ]),
                ),
              ),
            ],
          ],
          const SizedBox(height: 10),
          FilledButton.tonalIcon(icon: const Icon(Icons.refresh_rounded), label: const Text('Reload my access'), onPressed: () async {
            await d.reload();
            if (context.mounted) toast(context, 'Reloaded');
          }),
          TextButton.icon(icon: const Icon(Icons.info_outline_rounded), label: const Text('Connection details'), onPressed: () => showConnectionDetails(context)),
        ]),
      ),
    );
  }
}

/// Everything the phone knows about its own situation, with a Copy button to send to the admin.
Future<void> showConnectionDetails(BuildContext context) {
  final d = Provider.of<DataService>(context, listen: false);
  final s = situationOf(d);
  final rows = <(String, String)>[
    ('Signed in as', s.email),
    ('Role', s.isAdmin ? 'Admin (sees every group)' : 'Member'),
    ('Groups you can see', d.groups.isEmpty ? 'none' : d.groups.map((g) => g.name).join(', ')),
    ('Findings on this phone', '${s.findings}'),
    ('Systems on this phone', '${s.systems}'),
    ('Connection', s.online ? 'online' : 'offline (showing the saved copy)'),
    ('Firebase project', s.project),
    for (final e in s.errors.entries) ('Problem: ${e.key}', e.value),
  ];
  final text = rows.map((r) => '${r.$1}: ${r.$2}').join('\n');
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Connection details', style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: 10),
          for (final r in rows) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text.rich(TextSpan(children: [TextSpan(text: '${r.$1}:  ', style: const TextStyle(color: kTeal, fontWeight: FontWeight.w600)), TextSpan(text: r.$2)]))),
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy and send to your admin'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) toast(ctx, 'Copied');
            },
          ),
        ]),
      ),
    ),
  );
}
