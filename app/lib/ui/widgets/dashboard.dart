import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../logic/rules.dart';
import '../../models/models.dart';
import '../theme.dart';

/// The top of the Findings screen: a ring with the open findings by severity, the counts (tap one to filter),
/// and a line of new findings per day. Everything draws itself in once and is still when Android's "remove animations" is on.
class DashboardHeader extends StatelessWidget {
  final Counts counts;
  final List<int> daily;
  final Set<Severity> selected;
  final bool online;
  final ({int cur, int prev}) trend;
  final ValueChanged<Severity> onToggle;
  const DashboardHeader({super.key, required this.counts, required this.daily, required this.selected, required this.online, required this.trend, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final still = MediaQuery.of(context).disableAnimations;
    final dur = still ? Duration.zero : const Duration(milliseconds: 900);
    final today = daily.isEmpty ? 0 : daily.last;
    final vals = <int>[counts.critical, counts.high, counts.medium, counts.low];
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [kSurface2, kSurface]),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Column(children: [
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(
            width: 112,
            height: 112,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: dur,
              curve: Curves.easeOutCubic,
              builder: (c, p, _) => Stack(alignment: Alignment.center, children: [
                Positioned.fill(child: CustomPaint(painter: _RingPainter(vals, p))),
                if (counts.open == 0)
                  Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.check_rounded, color: Color(0xFF4CD964), size: 30),
                    Text('All clear', style: TextStyle(fontSize: 11, color: t.colorScheme.onSurfaceVariant)),
                  ])
                else
                  Column(mainAxisSize: MainAxisSize.min, children: [
                    _CountText(counts.open, dur, const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, height: 1.05)),
                    Text('open', style: TextStyle(fontSize: 11, color: t.colorScheme.onSurfaceVariant)),
                  ]),
              ]),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(children: [
              for (var i = 0; i < Severity.values.length; i++) _legend(context, Severity.values[i], vals[i], dur),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: Text(
              today > 0 ? 'New per day, last 14 days  ·  $today today' : 'New per day, last 14 days',
              style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          _LiveDot(online: online),
        ]),
        const SizedBox(height: 6),
        SizedBox(
          height: 44,
          width: double.infinity,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: still ? Duration.zero : const Duration(milliseconds: 1100),
            curve: Curves.easeOutCubic,
            builder: (c, p, _) => CustomPaint(painter: _SparkPainter(daily, p)),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Builder(builder: (ctx) {
            final diff = trend.cur - trend.prev;
            final color = diff > 0 ? severityColor(Severity.critical) : (diff < 0 ? severityColor(Severity.low) : t.colorScheme.onSurfaceVariant);
            final text = diff == 0 ? '= same as last week' : (diff > 0 ? '▲ $diff more than last week' : '▼ ${-diff} fewer than last week');
            return Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13)));
          }),
          Text('${trend.cur} new in 7 days', style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant)),
        ]),
      ]),
    );
  }

  Widget _legend(BuildContext context, Severity s, int n, Duration dur) {
    final c = severityColor(s);
    final on = selected.contains(s);
    return Semantics(
      button: true,
      selected: on,
      label: '${severityLabel(s)}: $n open',
      excludeSemantics: true,
      onTap: () => onToggle(s),
      child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onToggle(s),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: c.withValues(alpha: on ? 0.26 : 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.withValues(alpha: on ? 0.9 : 0.25)),
        ),
        child: Row(children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          SizedBox(width: 30, child: _CountText(n, dur, TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c))),
          Expanded(child: Text(severityLabel(s), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5))),
        ]),
      ),
    ),
    );
  }
}

/// A number that counts up from 0 the first time and glides to the new value when it changes.
class _CountText extends StatelessWidget {
  final int value;
  final Duration dur;
  final TextStyle style;
  const _CountText(this.value, this.dur, this.style);
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: value.toDouble()),
        duration: dur,
        curve: Curves.easeOutCubic,
        builder: (c, v, _) => Text('${v.round()}', style: style),
      );
}

/// "Live" with a breathing dot while online, "Offline copy" in amber when the saved copy is shown.
class _LiveDot extends StatefulWidget {
  final bool online;
  const _LiveDot({required this.online});
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final run = widget.online && !MediaQuery.of(context).disableAnimations;
    if (run && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!run && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void didUpdateWidget(covariant _LiveDot old) {
    super.didUpdateWidget(old);
    if (old.online != widget.online) didChangeDependencies();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.online ? kTeal : const Color(0xFFF2C94C);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      AnimatedBuilder(
        animation: _c,
        builder: (c, _) => Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color.withValues(alpha: widget.online ? 1 - 0.65 * _c.value : 1), shape: BoxShape.circle),
        ),
      ),
      const SizedBox(width: 6),
      Text(widget.online ? 'Live' : 'Offline copy', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
    ]);
  }
}

class _RingPainter extends CustomPainter {
  final List<int> vals; // critical, high, medium, low
  final double p; // 0..1 draw-in
  _RingPainter(this.vals, this.p);

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 9.0;
    final center = size.center(Offset.zero);
    final r = (math.min(size.width, size.height) - stroke) / 2;
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = const Color(0x1FB9C2EC);
    canvas.drawCircle(center, r, base);
    final total = vals.fold<int>(0, (a, b) => a + b);
    if (total == 0) {
      canvas.drawCircle(center, r, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = const Color(0x804CD964));
      return;
    }
    final parts = vals.where((v) => v > 0).length;
    final gap = parts > 1 ? 0.06 : 0.0;
    final rect = Rect.fromCircle(center: center, radius: r);
    var start = -math.pi / 2;
    for (var i = 0; i < vals.length; i++) {
      if (vals[i] == 0) continue;
      final full = 2 * math.pi * vals[i] / total;
      final sweep = math.max(0.0, full - gap) * p;
      canvas.drawArc(
        rect,
        start + gap / 2,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.butt
          ..color = severityColor(Severity.values[i]),
      );
      start += full;
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.p != p || !listEquals(old.vals, vals);
}

class _SparkPainter extends CustomPainter {
  final List<int> v;
  final double p; // 0..1 reveal from left to right
  _SparkPainter(this.v, this.p);

  @override
  void paint(Canvas canvas, Size size) {
    if (v.length < 2 || size.width <= 0) return;
    const pad = 3.0;
    final mx = math.max(1, v.reduce(math.max)).toDouble();
    final dx = (size.width - 2 * pad) / (v.length - 1);
    Offset pt(int i) => Offset(pad + i * dx, size.height - pad - (v[i] / mx) * (size.height - 2 * pad));
    final line = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < v.length; i++) {
      line.lineTo(pt(i).dx, pt(i).dy);
    }
    final area = Path.from(line)
      ..lineTo(pt(v.length - 1).dx, size.height)
      ..lineTo(pt(0).dx, size.height)
      ..close();
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * p, size.height));
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [kAccent.withValues(alpha: 0.35), kAccent.withValues(alpha: 0)]).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = kAccent,
    );
    canvas.restore();
    if (p >= 1) canvas.drawCircle(pt(v.length - 1), 3.2, Paint()..color = kAccent);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) => old.p != p || !listEquals(old.v, v);
}
