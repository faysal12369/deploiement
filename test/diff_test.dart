// The line comparison: known cases, then random texts whose comparison must rebuild both sides exactly.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:deploiement/diff.dart';

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  test('known cases', () {
    final d = FileDiff.of(bytes('a\nb\nc\nd\n'), bytes('a\nB\nc\nd\ne\n'));
    expect([for (final l in d.lines) '${l.op.name[0]}${l.text}'], ['sa', 'rb', 'aB', 'sc', 'sd', 'ae']);
    expect([d.added, d.removed], [2, 1]);
    expect(FileDiff.of(null, bytes('x\ny')).added, 2, reason: 'new file');
    expect(FileDiff.of(bytes('x\ny'), null).removed, 2, reason: 'removed file');
    expect(FileDiff.of(bytes('a\r\nb\r\n'), bytes('a\nb\n')).onlyLineEndings, true);
    expect(FileDiff.of(Uint8List.fromList([1, 0, 2]), bytes('x')).binary, true);
  });

  test('hunks keep 3 lines around each change and skip the rest', () {
    final a = [for (var i = 1; i <= 100; i++) 'line $i'];
    final b = [...a]..[49] = 'changed 50';
    final h = FileDiff(diffLines(a, b)).hunks();
    expect(h.map((x) => x.skipped), [46, 0, 47]);
    expect(h[1].lines.first.oldNo, 47);
    expect(h[1].lines.where((l) => l.op != Op.same).map((l) => l.text), ['line 50', 'changed 50']);
  });

  test('random texts: the comparison rebuilds both sides', () {
    final r = Random(7);
    for (var round = 0; round < 300; round++) {
      List<String> text() => [for (var i = r.nextInt(60); i > 0; i--) 'l${r.nextInt(8)}'];
      final a = text(), b = text();
      final d = diffLines(a, b);
      expect([for (final l in d) if (l.op != Op.added) l.text], a);
      expect([for (final l in d) if (l.op != Op.removed) l.text], b);
    }
  });

  test('very different big files fall back to "all removed, all added"', () {
    final a = [for (var i = 0; i < 3000; i++) 'a$i'], b = [for (var i = 0; i < 3000; i++) 'b$i'];
    final d = diffLines(a, b, maxEdits: 100);
    expect(d.where((l) => l.op == Op.removed).length, 3000);
    expect(d.where((l) => l.op == Op.added).length, 3000);
  });
}
