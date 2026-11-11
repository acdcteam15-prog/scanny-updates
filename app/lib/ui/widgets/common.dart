import 'dart:math' as math;

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
  final IconData? icon;
  const SectionTitle(this.text, {super.key, this.icon});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(4, 20, 4, 8),
        child: Row(children: [
          if (icon != null) Padding(padding: const EdgeInsetsDirectional.only(end: 8), child: Icon(icon, size: 17, color: kAccent)),
          Expanded(child: Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelMedium?.copyWith(color: kAccent, fontWeight: FontWeight.w700, letterSpacing: 0.8))),
        ]),
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

// ------------------------------------------------------------------------------------------------ motion (Phase 1)
// Built-in widgets only (no new packages). Every effect is switched off when Android's "remove animations" is on.

bool _still(BuildContext c) => MediaQuery.of(c).disableAnimations;

/// Fade and slide up, each item a little after the one before (first 10 only, so a long list never waits).
class Stagger extends StatelessWidget {
  final int index;
  final Widget child;
  const Stagger({super.key, required this.index, required this.child});
  @override
  Widget build(BuildContext context) {
    if (index > 9 || _still(context)) return child;
    final delay = index * 40;
    final total = 420 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
      builder: (c, v, ch) => Opacity(opacity: v.clamp(0.0, 1.0), child: Transform.translate(offset: Offset(0, 14 * (1 - v)), child: ch)),
      child: child,
    );
  }
}

/// A small press-in on touch. It only listens, so the child's own tap and ripple keep working.
class PressScale extends StatefulWidget {
  final Widget child;
  const PressScale({super.key, required this.child});
  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;
  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (_) => _set(true),
        onPointerUp: (_) => _set(false),
        onPointerCancel: (_) => _set(false),
        child: AnimatedScale(scale: _down && !_still(context) ? 0.985 : 1, duration: const Duration(milliseconds: 140), curve: Curves.easeOut, child: widget.child),
      );
}

/// The card shell: rounded border, a colour stripe on the leading edge, and (when [glow] is on) a slow pulsing glow
/// that stops after three pulses so it never distracts.
class GlowCard extends StatefulWidget {
  final Color stripe;
  final bool glow;
  final Widget child;
  const GlowCard({super.key, required this.stripe, required this.child, this.glow = false});
  @override
  State<GlowCard> createState() => _GlowCardState();
}

class _GlowCardState extends State<GlowCard> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started && widget.glow && !_still(context)) {
      _started = true;
      _c.repeat(reverse: true, count: 6);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (c, ch) {
        final k = widget.glow ? (0.14 + 0.2 * math.sin(_c.value * math.pi / 2)) : 0.0;
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: Color.alphaBlend(widget.stripe.withValues(alpha: widget.glow ? 0.06 : 0.03), t.colorScheme.surfaceContainerLow),
            border: Border.all(color: widget.glow ? widget.stripe.withValues(alpha: 0.7) : t.colorScheme.outlineVariant.withValues(alpha: 0.4)),
            boxShadow: widget.glow ? [BoxShadow(color: widget.stripe.withValues(alpha: k), blurRadius: 10 + 14 * _c.value)] : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: Stack(children: [
              Material(type: MaterialType.transparency, child: ch),
              PositionedDirectional(start: 0, top: 0, bottom: 0, width: 4, child: IgnorePointer(child: ColoredBox(color: widget.stripe))),
            ]),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// A friendly empty screen: a soft illustration that floats gently, a title, a line of help, and an optional button.
class EmptyState extends StatefulWidget {
  final IconData icon;
  final Color? color;
  final String title;
  final String? body;
  final String? actionLabel;
  final VoidCallback? onAction;
  const EmptyState({super.key, required this.icon, required this.title, this.color, this.body, this.actionLabel, this.onAction});
  @override
  State<EmptyState> createState() => _EmptyStateState();
}

class _EmptyStateState extends State<EmptyState> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_still(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = widget.color ?? kAccent;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AnimatedBuilder(
            animation: _c,
            builder: (ctx, ch) => Transform.translate(offset: Offset(0, -6 * Curves.easeInOut.transform(_c.value)), child: ch),
            child: Container(
              width: 118,
              height: 118,
              alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, color: c.withValues(alpha: 0.08), border: Border.all(color: c.withValues(alpha: 0.16))),
              child: Container(
                width: 78,
                height: 78,
                alignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, color: c.withValues(alpha: 0.16)),
                child: Icon(widget.icon, size: 38, color: c),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(widget.title, textAlign: TextAlign.center, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          if (widget.body != null) ...[
            const SizedBox(height: 8),
            Text(widget.body!, textAlign: TextAlign.center, style: TextStyle(color: t.colorScheme.onSurfaceVariant, height: 1.4)),
          ],
          if (widget.actionLabel != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: widget.onAction, child: Text(widget.actionLabel!)),
          ],
        ]),
      ),
    );
  }
}
