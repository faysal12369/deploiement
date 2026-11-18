// The Windows icon of Déploiement (asked 17/11/2026: "a good icon"), drawn by lib/app_mark.dart at every size Windows
// asks for, packed as windows/runner/resources/app_icon.ico (PNG entries). With --update-goldens the icon is made
// again; without, the icon in the project must be the one this drawing gives.
// Run: flutter test test/app_icon_test.dart --update-goldens
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:deploiement/app_mark.dart';

const sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];

Future<Uint8List> render(int s, {double scale = 1}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.scale(scale);
  const AppMarkPainter().paint(c, Size(s.toDouble(), s.toDouble()));
  final img = await rec.endRecording().toImage((s * scale).round(), (s * scale).round());
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  return png!.buffer.asUint8List();
}

/// An .ico made of PNG images (Windows Vista and later).
Uint8List ico(Map<int, Uint8List> pngs) {
  final head = BytesBuilder()
    ..add(_u16(0))
    ..add(_u16(1))
    ..add(_u16(pngs.length));
  var offset = 6 + 16 * pngs.length;
  final body = BytesBuilder();
  for (final MapEntry(key: s, value: png) in pngs.entries) {
    head
      ..addByte(s >= 256 ? 0 : s)
      ..addByte(s >= 256 ? 0 : s)
      ..addByte(0)
      ..addByte(0)
      ..add(_u16(1))
      ..add(_u16(32))
      ..add(_u32(png.length))
      ..add(_u32(offset));
    offset += png.length;
    body.add(png);
  }
  return Uint8List.fromList([...head.takeBytes(), ...body.takeBytes()]);
}

List<int> _u16(int v) => [v & 255, v >> 8 & 255];
List<int> _u32(int v) => [v & 255, v >> 8 & 255, v >> 16 & 255, v >> 24 & 255];

void main() {
  testWidgets('the Windows icon is the drawing of the app mark', (tester) async {
    final file = File(p.join('windows', 'runner', 'resources', 'app_icon.ico'));
    final made = await tester.runAsync(() async {
      final pngs = {for (final s in sizes) s: await render(s)};
      // a sheet to look at: every size, and the small ones enlarged without smoothing
      final dir = Directory(p.join('test', 'captures', 'icon'))..createSync(recursive: true);
      for (final s in [16, 24, 32, 48, 256]) {
        File(p.join(dir.path, 'icon_$s.png')).writeAsBytesSync(pngs[s]!);
      }
      return ico(pngs);
    });
    if (autoUpdateGoldenFiles) file.writeAsBytesSync(made!);
    expect(file.readAsBytesSync(), made, reason: 'run with --update-goldens after changing lib/app_mark.dart');
  });
}
