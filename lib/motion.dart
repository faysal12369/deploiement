// Movement, kept short and quiet: cards that slide in, figures that count up, a loader while the app works, a check
// that pops when a deployment is done. Nothing moves when Windows' "Animation effects" are off.
import 'dart:math';

import 'package:flutter/material.dart';

import 'i18n.dart';
import 'theme.dart';

bool _still(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// Fades and slides its child in, after [index] × 60 ms (at most 420 ms).
class Appear extends StatefulWidget {
  const Appear({super.key, required this.child, this.index = 0, this.dy = 14});
  final Widget child;
  final int index;
  final double dy;
  @override
  State<Appear> createState() => _AppearState();
}

class _AppearState extends State<Appear> with SingleTickerProviderStateMixin {
  late final c = AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
  late final a = CurvedAnimation(parent: c, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: min(widget.index * 60, 420)), () {
      if (mounted) c.forward();
    });
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_still(context)) return widget.child;
    return AnimatedBuilder(
      animation: a,
      child: widget.child,
      builder: (_, child) => Opacity(
        opacity: a.value,
        child: Transform.translate(offset: Offset(0, (1 - a.value) * widget.dy), child: child),
      ),
    );
  }
}

/// A figure that counts up to its value ("1 364"); text that is not a number is shown as it is.
class CountUp extends StatelessWidget {
  const CountUp(this.value, {super.key, required this.style});
  final String value;
  final TextStyle style;
  @override
  Widget build(BuildContext context) {
    final n = int.tryParse(value.replaceAll(' ', ''));
    if (n == null || n == 0 || _still(context)) return Text(value, style: style);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: n.toDouble()),
      duration: Duration(milliseconds: 500 + min(n, 400)),
      curve: Curves.easeOutCubic,
      builder: (_, v, _) => Text(fmtInt(v.round()), style: style),
    );
  }
}

/// A check (or a cross) that pops in.
class PopIn extends StatelessWidget {
  const PopIn({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if (_still(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 650),
      curve: Curves.elasticOut,
      child: child,
      builder: (_, v, child) => Transform.scale(scale: .4 + .6 * v, child: Opacity(opacity: v.clamp(0, 1), child: child)),
    );
  }
}

/// The loader of Déploiement: an arc turning around an arrow that rises, like a package leaving.
class DeployLoader extends StatefulWidget {
  const DeployLoader({super.key, this.size = 46, this.color});
  final double size;
  final Color? color;
  @override
  State<DeployLoader> createState() => _DeployLoaderState();
}

class _DeployLoaderState extends State<DeployLoader> with SingleTickerProviderStateMixin {
  late final c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = widget.color ?? p.accent;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: c,
        builder: (_, _) {
          final t = c.value;
          final rise = Curves.easeInOut.transform(t < .5 ? t * 2 : 2 - t * 2); // up then down
          return CustomPaint(
            painter: _ArcPainter(t, color, p.rule),
            child: Center(
              child: Transform.translate(
                offset: Offset(0, 3 - rise * 6),
                child: Icon(Icons.upload_rounded, size: widget.size * .46, color: color),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.t, this.color, this.track);
  final double t;
  final Color color, track;
  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(3, 3, size.width - 6, size.height - 6);
    canvas.drawArc(r, 0, 2 * pi, false, Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3);
    final sweep = pi * (.35 + .45 * sin(t * pi)); // grows and shrinks while it turns
    canvas.drawArc(r, t * 2 * pi - pi / 2, sweep, false, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3);
  }

  @override
  bool shouldRepaint(_ArcPainter o) => o.t != t;
}

/// Three dots that breathe one after the other: "working…".
class Dots extends StatefulWidget {
  const Dots({super.key, this.color, this.size = 6});
  final Color? color;
  final double size;
  @override
  State<Dots> createState() => _DotsState();
}

class _DotsState extends State<Dots> with SingleTickerProviderStateMixin {
  late final c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Palette.of(context).accent;
    return AnimatedBuilder(
      animation: c,
      builder: (_, _) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < 3; i++)
          Container(
            width: widget.size,
            height: widget.size,
            margin: EdgeInsets.only(right: i < 2 ? widget.size * .6 : 0),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: .25 + .75 * max(0, sin((c.value - i * .18) * 2 * pi))),
            ),
          ),
      ]),
    );
  }
}

/// "Loading…" with the loader, centred.
class Loading extends StatelessWidget {
  const Loading({super.key, this.text});
  final String? text;
  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const DeployLoader(size: 40),
        const SizedBox(height: 12),
        Text(text ?? tr('Loading…'), style: ty.small),
      ]),
    );
  }
}
