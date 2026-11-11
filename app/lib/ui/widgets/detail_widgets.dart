import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../theme.dart';
import 'common.dart';

Duration _dur(BuildContext c, int ms) => MediaQuery.of(c).disableAnimations ? Duration.zero : Duration(milliseconds: ms);

/// CVSS score (0 to 10) on a half ring that sweeps up to the value, in the colour of its band.
class CvssGauge extends StatelessWidget {
  final double score;
  const CvssGauge({super.key, required this.score});

  static Severity band(double s) => s >= 9 ? Severity.critical : (s >= 7 ? Severity.high : (s >= 4 ? Severity.medium : Severity.low));

  @override
  Widget build(BuildContext context) {
    final color = severityColor(band(score));
    final target = score.clamp(0.0, 10.0) / 10;
    return SizedBox(
      width: 132,
      height: 88,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: target),
        duration: _dur(context, 1000),
        curve: Curves.easeOutCubic,
        builder: (c, v, _) => Stack(alignment: Alignment.bottomCenter, children: [
          Positioned.fill(child: CustomPaint(painter: _ArcPainter(v, color))),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text((v * 10).toStringAsFixed(1), style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: color, height: 1.05)),
              Text('CVSS', style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  final double v; // 0..1
  final Color color;
  _ArcPainter(this.v, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 10.0;
    final rect = Rect.fromCircle(center: Offset(size.width / 2, size.height - 6), radius: size.width / 2 - stroke);
    canvas.drawArc(rect, math.pi, math.pi, false, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = const Color(0x1FB9C2EC));
    if (v > 0) {
      canvas.drawArc(rect, math.pi, math.pi * v, false, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _ArcPainter old) => old.v != v || old.color != color;
}

/// EPSS (the chance of exploitation in the next 30 days) as a bar that fills in.
class EpssBar extends StatelessWidget {
  final double value; // 0..1
  const EpssBar({super.key, required this.value});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('Chance of exploitation (EPSS)', style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis)),
        Text('${(value * 100).toStringAsFixed(1)}%', style: const TextStyle(fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: value.clamp(0.0, 1.0)),
          duration: _dur(context, 900),
          curve: Curves.easeOutCubic,
          builder: (c, x, _) => LinearProgressIndicator(value: x, minHeight: 8, color: kTeal, backgroundColor: kTeal.withValues(alpha: 0.15)),
        ),
      ),
    ]);
  }
}

class TimelineEvent {
  final IconData icon;
  final String text;
  final String sub;
  final Color? color;
  const TimelineEvent({required this.icon, required this.text, required this.sub, this.color});
}

/// Newest first: a dot per event joined by a line. Events fade in one after another.
class Timeline extends StatelessWidget {
  final List<TimelineEvent> events;
  const Timeline({super.key, required this.events});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(children: [
      for (var i = 0; i < events.length; i++)
        Stagger(
          index: i,
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: 28,
                child: Column(children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: (events[i].color ?? t.colorScheme.onSurfaceVariant).withValues(alpha: 0.16)),
                    child: Icon(events[i].icon, size: 15, color: events[i].color ?? t.colorScheme.onSurfaceVariant),
                  ),
                  if (i < events.length - 1) Expanded(child: Container(width: 2, margin: const EdgeInsets.symmetric(vertical: 3), color: const Color(0x24FFFFFF))),
                ]),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(events[i].text, style: const TextStyle(fontSize: 13.5, height: 1.3)),
                    const SizedBox(height: 2),
                    Text(events[i].sub, style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant)),
                  ]),
                ),
              ),
            ]),
          ),
        ),
    ]);
  }
}
