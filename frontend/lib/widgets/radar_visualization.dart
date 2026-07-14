import 'dart:math';

import 'package:flutter/material.dart';

import '../models/discovery_item.dart';
import '../models/radar_ui_state.dart';

class RadarVisualization extends StatefulWidget {
  final RadarUiState state;
  final String? statusMessage;
  final bool isTracking;
  final DateTime? lastScanAt;
  final List<DiscoveryItem> discoveries;

  const RadarVisualization({
    super.key,
    required this.state,
    this.statusMessage,
    this.isTracking = false,
    this.lastScanAt,
    this.discoveries = const [],
  });

  @override
  State<RadarVisualization> createState() => _RadarVisualizationState();
}

class _RadarVisualizationState extends State<RadarVisualization>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _sweepController;
  late AnimationController _breathController;
  late Animation<double> _breathAnimation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sweepController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );
    _breathController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _breathAnimation = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _breathController, curve: Curves.easeInOutSine),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.isTracking) {
      _sweepController.repeat();
      _breathController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(RadarVisualization oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimations();
  }

  void _syncAnimations() {
    if (widget.isTracking) {
      if (!_sweepController.isAnimating) {
        _sweepController.repeat();
        _breathController.repeat(reverse: true);
      }
    } else {
      _sweepController.stop();
      _breathController.stop();
      _breathController.value = 1.0;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sweepController.dispose();
    _breathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    _syncAnimations();

    return AnimatedBuilder(
      animation: Listenable.merge([_sweepController, _breathController]),
      builder: (context, _) {
        return Container(
          width: 300,
          height: 300,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: brightness == Brightness.dark
                ? Colors.black.withValues(alpha: 0.15)
                : Colors.white.withValues(alpha: 0.1),
          ),
          child: CustomPaint(
              painter: _RadarPainter(
              sweepAngle: _sweepController.value * 2 * pi,
              breathValue: _breathAnimation.value,
              state: widget.state,
              isTracking: widget.isTracking,
              discoveries: widget.discoveries,
              brightness: brightness,
              primaryColor: theme.colorScheme.primary,
              secondaryColor: theme.colorScheme.secondary,
              colorScheme: theme.colorScheme,
            ),
            size: const Size.square(300),
          ),
        );
      },
    );
  }
}

class _BlipData {
  final double angle;
  final double distance;
  final Color color;
  final String id;

  const _BlipData({
    required this.angle,
    required this.distance,
    required this.color,
    required this.id,
  });
}

List<_BlipData> _buildBlips(List<DiscoveryItem> discoveries, ColorScheme cs) {
  final blips = <_BlipData>[];
  final colors = [
    cs.primary,
    cs.secondary,
    cs.tertiary,
    Colors.cyan,
    Colors.greenAccent,
    Colors.amberAccent,
    Colors.pinkAccent,
    Colors.lightBlueAccent,
  ];
  for (int i = 0; i < discoveries.length && i < 8; i++) {
    final d = discoveries[i];
    final hash = d.id.hashCode;
    final angle = (hash.abs() % 6283) / 1000.0;
    final distance = 0.15 + ((hash.abs() + i * 97) % 70) / 100.0;
    blips.add(_BlipData(
      angle: angle,
      distance: distance.clamp(0.12, 0.85),
      color: colors[i % colors.length],
      id: d.id,
    ));
  }
  return blips;
}

class _RadarPainter extends CustomPainter {
  final double sweepAngle;
  final double breathValue;
  final RadarUiState state;
  final bool isTracking;
  final List<DiscoveryItem> discoveries;
  final Brightness brightness;
  final Color primaryColor;
  final Color secondaryColor;
  final ColorScheme colorScheme;

  _RadarPainter({
    required this.sweepAngle,
    required this.breathValue,
    required this.state,
    required this.isTracking,
    required this.discoveries,
    required this.brightness,
    required this.primaryColor,
    required this.secondaryColor,
    required this.colorScheme,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;
    final isDark = brightness == Brightness.dark;

    final bgGlow = isDark ? Colors.blueGrey.shade900 : Colors.grey.shade200;
    final fgDim = isDark ? Colors.white : Colors.black;
    final accentSweep = primaryColor;

    _drawBackground(canvas, center, radius, bgGlow, isDark);
    _drawCrosshairs(canvas, center, radius, fgDim);
    _drawRings(canvas, center, radius, fgDim);
    _drawBlips(canvas, center, radius);
    if (isTracking) {
      _drawSweepBeam(canvas, center, radius, accentSweep);
    }
    _drawCenterNode(canvas, center);
  }

  void _drawBackground(Canvas canvas, Offset center, double radius, Color bgGlow, bool isDark) {
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: radius)));

    final bgPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          bgGlow.withValues(alpha: isDark ? 0.12 : 0.06),
          bgGlow.withValues(alpha: isDark ? 0.06 : 0.03),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, bgPaint);

    canvas.restore();
  }

  void _drawCrosshairs(Canvas canvas, Offset center, double radius, Color fgColor) {
    final crossPaint = Paint()
      ..color = fgColor.withValues(alpha: 0.08)
      ..strokeWidth = 0.5;
    canvas.drawLine(Offset(center.dx - radius, center.dy),
        Offset(center.dx + radius, center.dy), crossPaint);
    canvas.drawLine(Offset(center.dx, center.dy - radius),
        Offset(center.dx, center.dy + radius), crossPaint);
  }

  void _drawRings(Canvas canvas, Offset center, double radius, Color fgColor) {
    for (int i = 1; i <= 3; i++) {
      final ringRadius = radius * (i / 3);
      final ringPaint = Paint()
        ..color = fgColor.withValues(alpha: 0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8;
      _drawDashedCircle(canvas, center, ringRadius, ringPaint);
    }
  }

  void _drawDashedCircle(Canvas canvas, Offset center, double radius, Paint paint) {
    const dashAngle = 0.08;
    const gapAngle = 0.06;
    double angle = 0;
    while (angle < 2 * pi) {
      final start = Offset(
        center.dx + cos(angle) * radius,
        center.dy + sin(angle) * radius,
      );
      final endAngle = angle + dashAngle;
      final end = Offset(
        center.dx + cos(endAngle) * radius,
        center.dy + sin(endAngle) * radius,
      );
      canvas.drawLine(start, end, paint);
      angle += dashAngle + gapAngle;
    }
  }

  void _drawBlips(Canvas canvas, Offset center, double radius) {
    final blips = _buildBlips(discoveries, colorScheme);
    for (final blip in blips) {
      final dx = center.dx + cos(blip.angle) * radius * blip.distance;
      final dy = center.dy + sin(blip.angle) * radius * blip.distance;
      final blipPos = Offset(dx, dy);

      final angleDiff = _normalizedAngleDiff(sweepAngle, blip.angle);
      final sweepWidth = pi / 1.5;
      final opacity = angleDiff < sweepWidth
          ? 1.0 - (angleDiff / sweepWidth) * 0.8
          : 0.2;

      if (opacity < 0.05) continue;

      final dotPaint = Paint()
        ..color = blip.color.withValues(alpha: opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 3);
      canvas.drawCircle(blipPos, 4.5, dotPaint);

      final corePaint = Paint()
        ..color = Colors.white.withValues(alpha: opacity * 0.9);
      canvas.drawCircle(blipPos, 2, corePaint);
    }
  }

  void _drawSweepBeam(Canvas canvas, Offset center, double radius, Color accent) {
    final sweepGradient = SweepGradient(
      center: Alignment.center,
      startAngle: sweepAngle - pi / 1.5,
      endAngle: sweepAngle,
      colors: [
        accent.withValues(alpha: 0),
        accent.withValues(alpha: 0.04),
        accent.withValues(alpha: 0.18),
        accent.withValues(alpha: 0.35),
        accent.withValues(alpha: 0.6),
        accent,
      ],
      stops: const [0.0, 0.3, 0.6, 0.8, 0.95, 1.0],
    ).createShader(Rect.fromCircle(center: center, radius: radius));

    final beamPaint = Paint()..shader = sweepGradient;
    canvas.drawCircle(center, radius, beamPaint);

    final sweepLine = Paint()
      ..color = accent
      ..strokeWidth = 2.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 4);
    final lineEnd = Offset(
      center.dx + cos(sweepAngle) * radius,
      center.dy + sin(sweepAngle) * radius,
    );
    canvas.drawLine(center, lineEnd, sweepLine);

    final glowPaint = Paint()
      ..color = accent.withValues(alpha: 0.15)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
    canvas.drawCircle(lineEnd, 6, glowPaint);
  }

  void _drawCenterNode(Canvas canvas, Offset center) {
    final breathScale = isTracking ? breathValue : 1.0;

    final halo = Paint()
      ..shader = RadialGradient(
        colors: [
          primaryColor.withValues(alpha: 0.25 * breathScale),
          primaryColor.withValues(alpha: 0.08 * breathScale),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(center: center, radius: 28 * breathScale));
    canvas.drawCircle(center, 28 * breathScale, halo);

    final outerDot = Paint()
      ..color = primaryColor.withValues(alpha: 0.7)
      ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 5);
    canvas.drawCircle(center, 7 * breathScale, outerDot);

    final innerDot = Paint()..color = Colors.white;
    canvas.drawCircle(center, 3.5 * breathScale, innerDot);
  }

  double _normalizedAngleDiff(double a, double b) {
    var diff = (a - b) % (2 * pi);
    if (diff < 0) diff += 2 * pi;
    if (diff > pi) diff = 2 * pi - diff;
    return diff;
  }

  @override
  bool shouldRepaint(_RadarPainter oldDelegate) {
    return sweepAngle != oldDelegate.sweepAngle ||
        breathValue != oldDelegate.breathValue ||
        isTracking != oldDelegate.isTracking ||
        state != oldDelegate.state ||
        discoveries.length != oldDelegate.discoveries.length ||
        primaryColor != oldDelegate.primaryColor;
  }
}
