// Line differences between the file on the target and the file on this PC (Myers' algorithm), grouped in hunks
// with a few lines of context — for "what a deployment changes in this file".
import 'dart:convert';
import 'dart:typed_data';

enum Op { same, removed, added }

class DiffLine {
  const DiffLine(this.op, this.text, this.oldNo, this.newNo);
  final Op op;
  final String text;
  final int? oldNo; // line number on the target
  final int? newNo; // line number on this PC
}

/// A part of the comparison: changed lines with [context] lines around them, or a run of unchanged lines skipped.
class Hunk {
  Hunk(this.lines, {this.skipped = 0, this.hidden = const []});
  final List<DiffLine> lines;
  final int skipped; // > 0: this many unchanged lines are not shown here
  final List<DiffLine> hidden; // those unchanged lines, to show them on demand
}

class FileDiff {
  FileDiff(this.lines, {this.binary = false, this.onlyLineEndings = false, this.oldSize = 0, this.newSize = 0});
  final List<DiffLine> lines;
  final bool binary;
  final bool onlyLineEndings; // same text, only CRLF / LF differ
  final int oldSize, newSize;
  int get added => lines.where((l) => l.op == Op.added).length;
  int get removed => lines.where((l) => l.op == Op.removed).length;

  /// Compares two versions of a file (null: the file does not exist on that side).
  factory FileDiff.of(Uint8List? target, Uint8List? local) {
    bool isBinary(Uint8List? b) => b != null && b.take(8000).contains(0);
    if (isBinary(target) || isBinary(local)) {
      return FileDiff(const [], binary: true, oldSize: target?.length ?? 0, newSize: local?.length ?? 0);
    }
    List<String> lines(Uint8List? b) {
      if (b == null || b.isEmpty) return const [];
      final t = utf8.decode(b, allowMalformed: true).replaceAll('\r\n', '\n');
      final l = t.split('\n');
      if (l.isNotEmpty && l.last.isEmpty) l.removeLast();
      return l;
    }

    final a = lines(target), b = lines(local);
    final d = diffLines(a, b);
    return FileDiff(d,
        onlyLineEndings: target != null && local != null && d.every((x) => x.op == Op.same) && !_sameBytes(target, local),
        oldSize: target?.length ?? 0,
        newSize: local?.length ?? 0);
  }

  /// The changes with [context] unchanged lines around them; long unchanged runs become one "skipped" hunk.
  List<Hunk> hunks({int context = 3}) {
    final out = <Hunk>[];
    final changed = [for (var i = 0; i < lines.length; i++) if (lines[i].op != Op.same) i];
    if (changed.isEmpty) return out;
    var i = 0;
    var c = 0;
    while (c < changed.length) {
      final start = (changed[c] - context).clamp(0, lines.length);
      var end = changed[c];
      while (c + 1 < changed.length && changed[c + 1] - end <= 2 * context + 1) {
        end = changed[++c];
      }
      end = (end + context + 1).clamp(0, lines.length);
      if (start > i) out.add(Hunk(const [], skipped: start - i, hidden: lines.sublist(i, start)));
      out.add(Hunk(lines.sublist(start, end)));
      i = end;
      c++;
    }
    if (i < lines.length) out.add(Hunk(const [], skipped: lines.length - i, hidden: lines.sublist(i)));
    return out;
  }
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Myers' diff of two lists of lines. Common start and end are taken out first; when the middle differs too much
/// (more than [maxEdits] changes), it is shown as removed then added instead of being searched line by line.
List<DiffLine> diffLines(List<String> a, List<String> b, {int maxEdits = 4000}) {
  var pre = 0;
  while (pre < a.length && pre < b.length && a[pre] == b[pre]) {
    pre++;
  }
  var suf = 0;
  while (suf < a.length - pre && suf < b.length - pre && a[a.length - 1 - suf] == b[b.length - 1 - suf]) {
    suf++;
  }
  final ma = a.sublist(pre, a.length - suf), mb = b.sublist(pre, b.length - suf);
  final ops = <Op>[
    for (var i = 0; i < pre; i++) Op.same,
    ...(_myers(ma, mb, maxEdits) ?? [for (final _ in ma) Op.removed, for (final _ in mb) Op.added]),
    for (var i = 0; i < suf; i++) Op.same,
  ];
  final out = <DiffLine>[];
  var x = 0, y = 0;
  for (final op in ops) {
    switch (op) {
      case Op.same:
        out.add(DiffLine(op, a[x], x + 1, y + 1));
        x++;
        y++;
      case Op.removed:
        out.add(DiffLine(op, a[x], x + 1, null));
        x++;
      case Op.added:
        out.add(DiffLine(op, b[y], null, y + 1));
        y++;
    }
  }
  return out;
}

List<Op>? _myers(List<String> a, List<String> b, int maxEdits) {
  final n = a.length, m = b.length;
  if (n == 0) return [for (final _ in b) Op.added];
  if (m == 0) return [for (final _ in a) Op.removed];
  final max = n + m;
  final off = max + 1;
  final v = Int32List(2 * max + 3);
  final trace = <Int32List>[]; // v at the start of each step d, for k in [-d-1, d+1]
  var found = false;
  for (var d = 0; d <= max && d <= maxEdits && !found; d++) {
    trace.add(Int32List.sublistView(Int32List.fromList(v.sublist(off - d - 1, off + d + 2))));
    for (var k = -d; k <= d; k += 2) {
      var x = (k == -d || (k != d && v[off + k - 1] < v[off + k + 1])) ? v[off + k + 1] : v[off + k - 1] + 1;
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[off + k] = x;
      if (x >= n && y >= m) {
        found = true;
        break;
      }
    }
  }
  if (!found) return null;
  final ops = <Op>[];
  var x = n, y = m;
  for (var d = trace.length - 1; d >= 0; d--) {
    final t = trace[d];
    int at(int k) => t[k + d + 1];
    final k = x - y;
    final prevK = (k == -d || (k != d && at(k - 1) < at(k + 1))) ? k + 1 : k - 1;
    final prevX = at(prevK);
    final prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      ops.add(Op.same);
      x--;
      y--;
    }
    if (d > 0) ops.add(x == prevX ? Op.added : Op.removed);
    x = prevX;
    y = prevY;
  }
  return ops.reversed.toList();
}
