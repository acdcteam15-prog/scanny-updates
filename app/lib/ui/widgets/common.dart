import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/models.dart';
import '../../state/data_service.dart';
import '../theme.dart';

class ErrorBox extends StatelessWidget {
  final String code;
  final String meaning;
  const ErrorBox({super.key, required this.code, required this.meaning});
  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: s.errorContainer, borderRadius: BorderRadius.circular(14)),
      child: SelectableText('Error $code\n$meaning', style: TextStyle(color: s.onErrorContainer)),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(4, 20, 4, 8),
        child: Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelMedium?.copyWith(color: kAccent, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
      );
}

class Splash extends StatelessWidget {
  const Splash({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(child: ClipRRect(borderRadius: BorderRadius.circular(24), child: Image.asset('assets/logo.png', width: 88, height: 88))),
      );
}

/// The score inside a ring in the colour of the severity, like the Windows dashboard.
class SeverityRing extends StatelessWidget {
  final Severity severity;
  final int score;
  final double size;
  const SeverityRing({super.key, required this.severity, required this.score, this.size = 46});
  @override
  Widget build(BuildContext context) {
    final c = severityColor(severity);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(alignment: Alignment.center, children: [
        SizedBox(width: size, height: size, child: CircularProgressIndicator(value: (score.clamp(0, 100)) / 100, strokeWidth: 4, color: c, backgroundColor: c.withValues(alpha: 0.18))),
        Text('$score', style: TextStyle(fontWeight: FontWeight.w700, fontSize: size * 0.3, color: c)),
      ]),
    );
  }
}

class StatusChip extends StatelessWidget {
  final Status status;
  const StatusChip(this.status, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(99), border: Border.all(color: c.withValues(alpha: 0.5))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (status == Status.solved) Padding(padding: const EdgeInsets.only(right: 4), child: Icon(Icons.check_rounded, size: 13, color: c)),
        Text(kStatusLabel[status] ?? '', style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600, decoration: status == Status.falsePositive ? TextDecoration.lineThrough : null)),
      ]),
    );
  }
}

class Pill extends StatelessWidget {
  final String text;
  final Color? color;
  final IconData? icon;

  /// true: a long text wraps onto a second line instead of being cut or running into its neighbour.
  final bool wrap;
  const Pill(this.text, {super.key, this.color, this.icon, this.wrap = false});
  @override
  Widget build(BuildContext context) {
    final c = color ?? const Color(0xFFB9C2EC);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(99), border: Border.all(color: c.withValues(alpha: 0.4))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) Padding(padding: const EdgeInsets.only(right: 4), child: Icon(icon, size: 12, color: c)),
        if (wrap) Flexible(child: Text(text, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w500))) else Text(text, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w500)),
      ]),
    );
  }
}

class GroupDot extends StatelessWidget {
  final GroupInfo? group;
  final String fallback;
  const GroupDot({super.key, this.group, this.fallback = ''});
  @override
  Widget build(BuildContext context) {
    final c = Color(group?.color ?? 0xFF8F98B7);
    return Pill(group?.name ?? fallback, color: c);
  }
}

/// Shown while the data comes from the phone's saved copy: everything is readable, nothing can be changed.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});
  @override
  Widget build(BuildContext context) {
    final online = context.select<DataService, bool>((d) => d.online);
    if (online) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: const Color(0xFF3A2F10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: const Row(children: [
        Icon(Icons.cloud_off_rounded, size: 18, color: Color(0xFFF2C94C)),
        SizedBox(width: 10),
        Expanded(child: Text('Offline: showing the saved copy. Changes are switched off until the connection is back.', style: TextStyle(fontSize: 12.5, color: Color(0xFFFFE9A8)))),
      ]),
    );
  }
}

void toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}
