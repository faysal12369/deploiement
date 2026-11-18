// The files of a simulation: filtered (all / new / changed / removed), grouped by folder; a click shows what changes.
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'i18n.dart';
import 'operations.dart';
import 'theme.dart';
import 'widgets.dart';

class ReportFiles extends StatefulWidget {
  const ReportFiles(this.r, {super.key, required this.onOpen, this.own = const {}});
  final Report r;
  final Set<String> own; // files of this target only (its own config…)
  final void Function(String path, String kind) onOpen;
  @override
  State<ReportFiles> createState() => _ReportFilesState();
}

class _ReportFilesState extends State<ReportFiles> {
  String filter = ''; // '' all, A, M, D
  bool all = false;
  static const shown = 40;

  @override
  Widget build(BuildContext context) {
    final r = widget.r;
    final ty = Ty.of(context);
    final p0 = ty.p;
    final files = [
      for (final f in r.newFiles) ('A', f),
      for (final f in r.changedFiles) ('M', f),
      for (final f in r.removedFiles) ('D', f),
    ];
    final picked = [for (final x in files) if (filter.isEmpty || x.$1 == filter) x]..sort((a, b) => a.$2.toLowerCase().compareTo(b.$2.toLowerCase()));
    final visible = all ? picked : picked.take(shown).toList();
    Color color(String k) => switch (k) { 'A' => p0.added, 'M' => p0.changed, _ => p0.removed };

    Widget chip(String k, String label, int n) {
      final on = filter == k;
      return InkWell(
        onTap: n == 0 && k.isNotEmpty ? null : () => setState(() => filter = k),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: on ? p0.ink : Colors.transparent, width: 2))),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: label.toUpperCase(), style: ty.caps(color: n == 0 && k.isNotEmpty ? p0.faint : (on ? p0.ink : p0.muted))),
            TextSpan(text: '  ${fmtInt(n)}', style: ty.figure(size: 12.5, color: k.isEmpty ? p0.muted : (n == 0 ? p0.faint : color(k)), weight: FontWeight.w600)),
          ])),
        ),
      );
    }

    final rows = <Widget>[];
    String? folder;
    for (final (k, path) in visible) {
      final dir = p.posix.dirname(path);
      if (dir != folder) {
        folder = dir;
        final count = picked.where((x) => p.posix.dirname(x.$2) == dir).length;
        rows.add(Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 2),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: dir == '.' ? tr('(project folder)') : '$dir/', style: ty.mono(size: 12.5, color: p0.muted, weight: FontWeight.w700)),
            TextSpan(text: '   $count', style: ty.figure(size: 12, color: p0.faint)),
          ])),
        ));
      }
      rows.add(InkWell(
        key: ValueKey('file-$path'),
        onTap: () => widget.onOpen(path, k),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          child: Row(children: [
            const SizedBox(width: 14),
            SizedBox(width: 22, child: Text(k, style: ty.mono(color: color(k), weight: FontWeight.w700))),
            Flexible(child: Text(p.posix.basename(path), style: ty.mono(), overflow: TextOverflow.ellipsis)),
            if (widget.own.contains(path)) Padding(padding: const EdgeInsets.only(left: 10), child: Tag(tr('this target\'s own'), icon: Icons.tune, color: p0.accent)),
            const Spacer(),
            Text(k == 'M' ? tr('compare') : tr('view'), style: ty.small.copyWith(color: p0.faint)),
            Icon(Icons.chevron_right, size: 16, color: p0.faint),
          ]),
        ),
      ));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(spacing: 4, children: [
          chip('', tr('All'), files.length),
          chip('A', tr('New'), r.newFiles.length),
          chip('M', tr('Changed'), r.changedFiles.length),
          chip('D', tr('Removed'), r.removedFiles.length),
        ]),
      ),
      ...rows,
      if (picked.length > shown)
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SmallButton(all ? tr('Show less') : tr('Show all {n}', {'n': fmtInt(picked.length)}), onPressed: () => setState(() => all = !all)),
          ),
        ),
    ]);
  }
}
