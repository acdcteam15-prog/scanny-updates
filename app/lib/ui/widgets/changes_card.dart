import 'package:flutter/material.dart';

import '../../logic/rules.dart';
import '../../models/models.dart';
import '../theme.dart';
import 'common.dart';

/// "Since you last looked": new findings and changes by other people, with a close button.
class ChangesCard extends StatelessWidget {
  final Changes changes;
  final DateTime since;
  final VoidCallback onDismiss;
  const ChangesCard({super.key, required this.changes, required this.since, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final parts = <Widget>[
      if (changes.added > 0) Pill('${changes.added} new ${changes.added == 1 ? 'finding' : 'findings'}', color: kAccent, icon: Icons.fiber_new_rounded),
      if (changes.addedCritical > 0) Pill('${changes.addedCritical} critical', color: severityColor(Severity.critical), icon: Icons.priority_high_rounded),
      if (changes.changedByOthers > 0) Pill('${changes.changedByOthers} changed by others', color: kTeal, icon: Icons.sync_alt_rounded),
    ];
    return Stagger(
      index: 0,
      child: Container(
        margin: const EdgeInsets.fromLTRB(14, 4, 14, 6),
        padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 6, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: kAccent.withValues(alpha: 0.1),
          border: Border.all(color: kAccent.withValues(alpha: 0.28)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.auto_awesome_rounded, size: 18, color: kAccent),
            const SizedBox(width: 8),
            Expanded(child: Text('Since you last looked (${ago(since)})', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5))),
            IconButton(visualDensity: VisualDensity.compact, tooltip: 'Dismiss', icon: Icon(Icons.close_rounded, size: 20, color: t.colorScheme.onSurfaceVariant), onPressed: onDismiss),
          ]),
          Padding(padding: const EdgeInsetsDirectional.only(end: 8), child: Wrap(spacing: 6, runSpacing: 6, children: parts)),
        ]),
      ),
    );
  }
}
