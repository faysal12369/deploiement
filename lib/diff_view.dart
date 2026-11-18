// "What changes in this file": the file as it is on the target next to the file on this PC, changed lines in red
// (target) and green (this PC), the part of a line that changed marked darker. Side by side on wide windows, in one
// column on narrow ones (the whole window on the narrowest). Long lines wrap under their own indentation; the
// unchanged lines between the changes open with a click; the code can be selected without its line numbers.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'diff.dart';
import 'i18n.dart';
import 'models.dart';
import 'motion.dart';
import 'operations.dart';
import 'package.dart';
import 'theme.dart';
import 'widgets.dart';

/// Below this width the comparison takes the whole window, in one column.
const _phone = 720.0;

/// From this width it opens side by side.
const _wideEnough = 1000.0;

/// [kind]: A (new on the target), M (changed), D (removed from the target).
/// [versions]: both versions when they are already known; otherwise they are read here and on the target.
Future<void> showFileDiff(BuildContext context, AppSettings settings, Project pr, Target t, String rel, String kind,
        {Future<(Uint8List?, Uint8List?)>? versions}) =>
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .35),
      builder: (_) => DiffDialog(target: t.name, rel: rel, kind: kind, versions: versions ?? fileVersions(settings, pr, t, rel, kind)),
    );

/// Both versions of a file: on the target (null: not there) and on this PC (null: not there).
Future<(Uint8List?, Uint8List?)> fileVersions(AppSettings settings, Project pr, Target t, String rel, String kind) async {
  final local = kind == 'D' ? null : await File(PackageBuilder.localPathOf(pr, t, rel)).readAsBytes();
  final target = kind == 'A' ? null : await Operations(settings, Journal()).fileOnTarget(t, rel);
  return (target, local);
}

class DiffDialog extends StatefulWidget {
  const DiffDialog({super.key, required this.target, required this.rel, required this.kind, required this.versions});
  final String target, rel, kind;
  final Future<(Uint8List?, Uint8List?)> versions;
  @override
  State<DiffDialog> createState() => _DiffDialogState();
}

class _DiffDialogState extends State<DiffDialog> {
  late final Future<FileDiff> diff = widget.versions.then((v) => FileDiff.of(v.$1, v.$2));
  bool? sideBySide; // null: by the width of the window
  final opened = <int>{}; // unchanged runs opened by a click (their hunk)
  final scroll = ScrollController();

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final size = MediaQuery.sizeOf(context);
    final full = size.width < _phone;
    final canSplit = widget.kind == 'M' && !full;
    final split = canSplit && (sideBySide ?? size.width >= _wideEnough);
    return Dialog(
      insetPadding: full ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      shape: full ? const RoundedRectangleBorder() : null,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: full ? size.width : min(1320.0, size.width - 48),
        height: full ? size.height : null,
        child: FutureBuilder<FileDiff>(
          future: diff,
          builder: (context, snap) => Column(
            mainAxisSize: full ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _head(context, snap.data, canSplit, split),
              Container(height: 1, color: p.rule),
              ..._body(context, snap, split, full),
            ],
          ),
        ),
      ),
    );
  }

  Widget _head(BuildContext context, FileDiff? d, bool canSplit, bool split) {
    final ty = Ty.of(context);
    final p = ty.p;
    final rel = widget.rel;
    final cut = rel.lastIndexOf('/') + 1;
    final (kindText, kindColor) = switch (widget.kind) {
      'A' => (tr('New file'), p.added),
      'D' => (tr('Removed file'), p.removed),
      _ => (tr('Changed file'), p.changed),
    };
    final facts = <Widget>[
      if (d != null && !d.binary && !d.onlyLineEndings && d.added + d.removed > 0) _Stats(d.added, d.removed),
      if (widget.kind != 'M')
        Text(widget.kind == 'A' ? tr('New file: it is not on the target yet') : tr('Removed: the deployment deletes it from the target'), style: ty.small),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 10, 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Tag(kindText, color: kindColor),
              SelectableText.rich(TextSpan(children: [
                if (cut > 0) TextSpan(text: rel.substring(0, cut), style: ty.mono(size: 14, color: p.muted)),
                TextSpan(text: rel.substring(cut), style: ty.mono(size: 14, weight: FontWeight.w700)),
              ])),
            ]),
            if (facts.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 16, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: facts),
            ],
          ]),
        ),
        if (canSplit) ...[
          const SizedBox(width: 12),
          _ViewSwitch(split: split, onChanged: (v) => setState(() => sideBySide = v)),
        ],
        const SizedBox(width: 4),
        IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, size: 19), tooltip: tr('Close')),
      ]),
    );
  }

  List<Widget> _body(BuildContext context, AsyncSnapshot<FileDiff> snap, bool split, bool full) {
    final ty = Ty.of(context);
    final p = ty.p;
    List<Widget> note(String s, {Color? color}) =>
        [Padding(padding: const EdgeInsets.fromLTRB(20, 22, 20, 26), child: Text(s, style: ty.body.copyWith(color: color ?? p.muted)))];
    if (snap.hasError) return note('${snap.error}'.replaceFirst('AgentError: ', ''), color: p.removed);
    final d = snap.data;
    if (d == null) return [const SizedBox(height: 180, child: Loading())];
    if (d.binary) return note(tr('Binary file (image, archive…): {a} on the target → {b} on this PC.', {'a': _kb(d.oldSize), 'b': _kb(d.newSize)}));
    if (d.onlyLineEndings) return note(tr('Same text: only the line endings differ (Windows CRLF / Unix LF).'));
    if (d.lines.isEmpty || d.added + d.removed == 0) return note(tr('No difference.'));

    final biggest = d.lines.fold(0, (m, l) => max(m, max(l.oldNo ?? 0, l.newNo ?? 0)));
    final gutter = 18 + '$biggest'.length * 7.4;
    final rows = <Widget Function()>[];
    final hunks = d.hunks();
    for (var hi = 0; hi < hunks.length; hi++) {
      final h = hunks[hi];
      if (h.skipped > 0 && !opened.contains(hi)) {
        rows.add(() => _Skipped(h.skipped, onOpen: () => setState(() => opened.add(hi))));
        continue;
      }
      final lines = h.skipped > 0 ? h.hidden : h.lines;
      var i = 0;
      while (i < lines.length) {
        final l = lines[i];
        if (l.op == Op.same) {
          rows.add(split ? () => _Pair(l, l, gutter) : () => _UnifiedLine(l, gutter));
          i++;
          continue;
        }
        // a run of removed lines and the run of added lines that follows: face to face, the changed part marked
        final del = <DiffLine>[], add = <DiffLine>[];
        while (i < lines.length && lines[i].op == Op.removed) {
          del.add(lines[i++]);
        }
        while (i < lines.length && lines[i].op == Op.added) {
          add.add(lines[i++]);
        }
        final marks = [for (var j = 0; j < min(del.length, add.length); j++) _changedPart(_tabs(del[j].text), _tabs(add[j].text))];
        if (split) {
          for (var j = 0; j < max(del.length, add.length); j++) {
            final left = j < del.length ? del[j] : null, right = j < add.length ? add[j] : null;
            final m = j < marks.length ? marks[j] : null;
            rows.add(() => _Pair(left, right, gutter, markLeft: m?.$1, markRight: m?.$2));
          }
        } else {
          for (var j = 0; j < del.length; j++) {
            final m = j < marks.length ? marks[j] : null;
            rows.add(() => _UnifiedLine(del[j], gutter, mark: m?.$1));
          }
          for (var j = 0; j < add.length; j++) {
            final m = j < marks.length ? marks[j] : null;
            rows.add(() => _UnifiedLine(add[j], gutter, mark: m?.$2));
          }
        }
      }
    }
    // a short comparison: the window fits it; a long one: the window is as tall as it can be
    final tall = full || rows.length > 400;
    final list = Scrollbar(
      controller: scroll,
      thumbVisibility: true,
      child: SelectionArea(
        child: ListView.builder(
          controller: scroll,
          shrinkWrap: !tall,
          padding: const EdgeInsets.only(bottom: 8),
          itemCount: rows.length,
          itemBuilder: (_, i) => rows[i](),
        ),
      ),
    );
    return [
      _Sides(widget.target, split: split),
      Container(height: 1, color: p.rule),
      tall ? Expanded(child: list) : Flexible(child: list),
    ];
  }

  static String _kb(int b) => b < 1024 ? '$b B' : '${fmtInt((b / 1024).round())} KB';
}

String _tabs(String s) => s.replaceAll('\t', '    ');

/// The part of two versions of a line that differs (their common start and end left out), when they look alike;
/// null when they have little in common (then the whole line is the change).
((int, int), (int, int))? _changedPart(String a, String b) {
  var pre = 0;
  while (pre < a.length && pre < b.length && a.codeUnitAt(pre) == b.codeUnitAt(pre)) {
    pre++;
  }
  var suf = 0;
  while (suf < a.length - pre && suf < b.length - pre && a.codeUnitAt(a.length - 1 - suf) == b.codeUnitAt(b.length - 1 - suf)) {
    suf++;
  }
  final da = a.length - pre - suf, db = b.length - pre - suf;
  if (pre + suf == 0 || da + db > .7 * (a.length + b.length)) return null;
  return ((pre, pre + da), (pre, pre + db));
}

bool _dark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

/// The background of a line, of its number, of the part that changed.
Color? _rowTint(BuildContext context, Op op) {
  final p = Palette.of(context), d = _dark(context);
  return switch (op) {
    Op.removed => p.removed.withValues(alpha: d ? .13 : .07),
    Op.added => p.added.withValues(alpha: d ? .12 : .08),
    Op.same => null,
  };
}

Color _gutterTint(BuildContext context, Op op) {
  final p = Palette.of(context), d = _dark(context);
  return switch (op) {
    Op.removed => p.removed.withValues(alpha: d ? .24 : .14),
    Op.added => p.added.withValues(alpha: d ? .22 : .16),
    Op.same => p.sunken,
  };
}

Color _markTint(BuildContext context, Op op) {
  final p = Palette.of(context), d = _dark(context);
  return op == Op.removed ? p.removed.withValues(alpha: d ? .34 : .22) : p.added.withValues(alpha: d ? .30 : .24);
}

/// +added −removed, and five squares in proportion.
class _Stats extends StatelessWidget {
  const _Stats(this.added, this.removed);
  final int added, removed;
  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final p = ty.p;
    final total = added + removed;
    var g = total == 0 ? 0 : (5 * added / total).round();
    var r = total == 0 ? 0 : 5 - g;
    if (added > 0 && g == 0) (g, r) = (1, 4);
    if (removed > 0 && r == 0) (g, r) = (4, 1);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('+${fmtInt(added)}', style: ty.figure(color: p.added, weight: FontWeight.w600)),
      const SizedBox(width: 8),
      Text('−${fmtInt(removed)}', style: ty.figure(color: p.removed, weight: FontWeight.w600)),
      const SizedBox(width: 10),
      for (var i = 0; i < 5; i++)
        Container(
          width: 9,
          height: 9,
          margin: const EdgeInsets.only(right: 2),
          decoration: BoxDecoration(color: i < g ? p.added : (i < g + r ? p.removed : p.rule), borderRadius: BorderRadius.circular(2)),
        ),
      const SizedBox(width: 8),
      Text(tr('lines'), style: ty.small),
    ]);
  }
}

/// Side by side or one column.
class _ViewSwitch extends StatelessWidget {
  const _ViewSwitch({required this.split, required this.onChanged});
  final bool split;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final p = ty.p;
    Widget seg(bool value, IconData icon, String label) {
      final on = value == split;
      return Material(
        key: ValueKey(value ? 'diff-split' : 'diff-unified'),
        color: on ? p.surface : Colors.transparent,
        elevation: on ? 1 : 0,
        shadowColor: Colors.black.withValues(alpha: .25),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: on ? null : () => onChanged(value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 15, color: on ? p.accent : p.muted),
              const SizedBox(width: 6),
              Text(label, style: ty.button.copyWith(fontSize: 12.5, color: on ? p.ink : p.muted)),
            ]),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: p.sunken, border: Border.all(color: p.rule), borderRadius: BorderRadius.circular(9)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg(true, Icons.vertical_split_outlined, tr('Side by side')),
        const SizedBox(width: 2),
        seg(false, Icons.view_agenda_outlined, tr('One column')),
      ]),
    );
  }
}

/// Which side is which: the target in red, this PC in green.
class _Sides extends StatelessWidget {
  const _Sides(this.target, {required this.split});
  final String target;
  final bool split;
  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final p = ty.p;
    Widget label(Color c, String sign, String text, String? sub) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          child: Row(mainAxisSize: split ? MainAxisSize.max : MainAxisSize.min, children: [
            Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: c.withValues(alpha: .14), borderRadius: BorderRadius.circular(4)),
              child: Text(sign, style: ty.mono(size: 12, weight: FontWeight.w700, color: c).copyWith(height: 1)),
            ),
            const SizedBox(width: 8),
            Text(text.toUpperCase(), style: ty.caps()),
            if (sub != null) ...[
              const SizedBox(width: 8),
              Flexible(child: Text(sub, style: ty.small.copyWith(color: p.faint), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
          ]),
        );
    final left = label(p.removed, '−', tr('On the target'), target), right = label(p.added, '+', tr('On this PC'), null);
    return Container(
      color: p.sunken,
      child: split
          ? IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: left),
                Container(width: 1, color: p.rule),
                Expanded(child: right),
              ]),
            )
          : Wrap(children: [left, right]),
    );
  }
}

/// Unchanged lines left out between two changes: a click shows them.
class _Skipped extends StatelessWidget {
  const _Skipped(this.n, {required this.onOpen});
  final int n;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final p = ty.p;
    return Material(
      color: p.sunken,
      child: InkWell(
        onTap: onOpen,
        child: Container(
          decoration: BoxDecoration(border: Border.symmetric(horizontal: BorderSide(color: p.rule))),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 14),
          child: Row(children: [
            Icon(Icons.unfold_more, size: 16, color: p.accent),
            const SizedBox(width: 8),
            Text(pl(n, 'Show {n} unchanged line', 'Show {n} unchanged lines', 'Afficher {n} ligne inchangée', 'Afficher {n} lignes inchangées'),
                style: ty.small.copyWith(color: p.accent, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

/// A line number (not selected with the code).
class _No extends StatelessWidget {
  const _No(this.n, {required this.width, required this.color});
  final int? n;
  final double width;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    return SelectionContainer.disabled(
      child: Container(
        width: width,
        color: color,
        padding: const EdgeInsets.only(right: 8, top: 1),
        alignment: Alignment.topRight,
        child: Text(n == null ? '' : '$n', style: ty.mono(size: 11.5, color: ty.p.faint).copyWith(height: 12.5 * 1.55 / 11.5)),
      ),
    );
  }
}

class _Sign extends StatelessWidget {
  const _Sign(this.op);
  final Op op;
  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    return SelectionContainer.disabled(
      child: Padding(
        padding: const EdgeInsets.only(top: 1),
        child: SizedBox(
          width: 20,
          child: Text(switch (op) { Op.removed => '−', Op.added => '+', Op.same => '' },
              textAlign: TextAlign.center, style: ty.mono(weight: FontWeight.w700, color: op == Op.removed ? ty.p.removed : ty.p.added)),
        ),
      ),
    );
  }
}

/// The text of a line: its indentation stays put and the rest wraps under it; [mark] (the part that changed) darker.
class _Code extends StatelessWidget {
  const _Code(this.text, this.op, {this.mark});
  final String text;
  final Op op;
  final (int, int)? mark;
  @override
  Widget build(BuildContext context) {
    final style = Ty.of(context).mono();
    final t = _tabs(text);
    var lead = 0;
    while (lead < t.length && lead < 40 && t.codeUnitAt(lead) == 32) {
      lead++;
    }
    if (lead == t.length) return Text(t.isEmpty ? ' ' : t, style: style);
    final body = t.substring(lead);
    final m = mark;
    final spans = <TextSpan>[];
    if (m == null || op == Op.same || m.$2 <= lead || m.$1 >= m.$2) {
      spans.add(TextSpan(text: body));
    } else {
      final a = max(m.$1, lead) - lead, b = min(m.$2, t.length) - lead;
      spans
        ..add(TextSpan(text: body.substring(0, a)))
        ..add(TextSpan(text: body.substring(a, b), style: TextStyle(backgroundColor: _markTint(context, op))))
        ..add(TextSpan(text: body.substring(b)));
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (lead > 0) Text(t.substring(0, lead), style: style),
      Expanded(child: Text.rich(TextSpan(style: style, children: spans))),
    ]);
  }
}

/// One line in one column: number on the target, number on this PC, sign, text.
class _UnifiedLine extends StatelessWidget {
  const _UnifiedLine(this.l, this.gutter, {this.mark});
  final DiffLine l;
  final double gutter;
  final (int, int)? mark;
  @override
  Widget build(BuildContext context) {
    final g = _gutterTint(context, l.op);
    return Container(
      color: _rowTint(context, l.op),
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _No(l.oldNo, width: gutter, color: g),
          _No(l.newNo, width: gutter, color: g),
          _Sign(l.op),
          Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(2, 1, 16, 1), child: _Code(l.text, l.op, mark: mark))),
        ]),
      ),
    );
  }
}

/// One row side by side: the line on the target (left) and on this PC (right); a missing side is hatched.
class _Pair extends StatelessWidget {
  const _Pair(this.left, this.right, this.gutter, {this.markLeft, this.markRight});
  final DiffLine? left, right;
  final double gutter;
  final (int, int)? markLeft, markRight;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget side(DiffLine? l, bool isLeft) {
      if (l == null) return const Expanded(child: _Hatch());
      return Expanded(
        child: Container(
          color: _rowTint(context, l.op),
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _No(isLeft ? l.oldNo : l.newNo, width: gutter, color: _gutterTint(context, l.op)),
            _Sign(l.op),
            Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(2, 1, 14, 1), child: _Code(l.text, l.op, mark: isLeft ? markLeft : markRight))),
          ]),
        ),
      );
    }

    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        side(left, true),
        Container(width: 1, color: p.rule),
        side(right, false),
      ]),
    );
  }
}

/// No line on this side: light diagonal stripes.
class _Hatch extends StatelessWidget {
  const _Hatch();
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ColoredBox(color: p.sunken, child: CustomPaint(painter: _HatchPainter(p.rule)));
  }
}

class _HatchPainter extends CustomPainter {
  _HatchPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    canvas.clipRect(Offset.zero & size);
    for (var x = 0.0; x < size.width + size.height; x += 8) {
      canvas.drawLine(Offset(x, 0), Offset(x - size.height, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_HatchPainter old) => old.color != color;
}
