import 'package:flutter/material.dart';

import '../../logic/rules.dart';
import '../../models/models.dart';
import '../theme.dart';
import 'common.dart';

/// "Do this today": the few findings that matter most right now. Tap one to open it.
class TodayCard extends StatelessWidget {
  final List<TodayItem> items;
  final ValueChanged<Finding> onOpen;
  const TodayCard({super.key, required this.items, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Stagger(
      index: 1,
      child: Container(
        margin: const EdgeInsets.fromLTRB(14, 2, 14, 8),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), color: kSurface, border: Border.all(color: const Color(0x14FFFFFF))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.bolt_rounded, size: 18, color: kAccent),
            const SizedBox(width: 6),
            Text('DO THIS TODAY', style: t.textTheme.labelMedium?.copyWith(color: kAccent, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
          ]),
          const SizedBox(height: 4),
          for (final x in items)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => onOpen(x.f),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
                child: Row(children: [
                  Container(width: 10, height: 10, decoration: BoxDecoration(color: severityColor(x.f.severity), shape: BoxShape.circle)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${x.f.cve}  ${x.f.system}'.trim(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                      Text(x.f.headline.isNotEmpty ? x.f.headline : x.f.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: t.colorScheme.onSurfaceVariant)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Pill(x.why, color: (x.rank >= 3) ? const Color(0xFFFF5C6C) : const Color(0xFFFF9F43)),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}
