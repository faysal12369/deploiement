// The mark of Déploiement (chosen 17/11/2026 among four ideas): an arrow coming down into a server of two units with
// green lights, white on the action blue, flat (no gradient). One drawing for the side panel and for the Windows icon
// (windows/runner/resources/app_icon.ico, made by test/app_icon_test.dart --update-goldens), so both stay the same.
import 'dart:math' as math;

import 'package:flutter/material.dart';

class AppMarkPainter extends CustomPainter {
  const AppMarkPainter({this.background = const Color(0xFF1D63ED)});
  final Color background;

  static const _white = Colors.white, _green = Color(0xFF22C55E), _slot = Color(0x590F2342); // navy at 35 %

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    canvas.save();
    canvas.translate((size.width - s) / 2, (size.height - s) / 2);
    final small = s < 30; // 16, 20, 24 px: no margin, bolder shapes, no slots, so they stay readable
    double u(double v) => v * s;
    Paint fill(Color c) => Paint()..color = c;

    // the tile
    final m = small ? 0.0 : s * .035;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(m, m, s - m, s - m), Radius.circular(s * (small ? .2 : .225))), fill(background));

    // the arrow, down into the server
    final shaft = small ? math.max(2.0, s * .14) : s * .11;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(u(.5) - shaft / 2, u(.13), u(.5) + shaft / 2, u(.3)), Radius.circular(shaft * .3)), fill(_white));
    final head = Path()
      ..moveTo(u(.34), u(.27))
      ..lineTo(u(.66), u(.27))
      ..lineTo(u(.5), u(.42))
      ..close();
    canvas.drawPath(head, fill(_white));
    canvas.drawPath(
      head,
      Paint()
        ..color = _white
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * .035
        ..strokeJoin = StrokeJoin.round,
    );

    // the server: two units, a green light and three slots each
    for (final top in [.47, .66]) {
      final r = Rect.fromLTRB(u(.2), u(top), u(.8), u(top + .155));
      canvas.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(s * .045)), fill(_white));
      canvas.drawCircle(Offset(u(.3), r.center.dy), s * (small ? .045 : .035), fill(_green));
      if (!small) {
        for (final x in [.56, .64, .72]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(u(x), r.center.dy), width: s * .028, height: s * .075), Radius.circular(s * .014)),
            fill(_slot),
          );
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(AppMarkPainter old) => old.background != background;
}

/// The mark at [size] logical pixels.
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 28, this.background = const Color(0xFF1D63ED)});
  final double size;
  final Color background;
  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: size, child: CustomPaint(painter: AppMarkPainter(background: background)));
}
