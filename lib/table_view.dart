// One table of the target, read-only, like a database browser: its rows 50 at a time and its columns. Passwords,
// tokens and hashes are masked by the agent.
import 'dart:math';

import 'package:flutter/material.dart';

import 'i18n.dart';
import 'motion.dart';
import 'models.dart';
import 'operations.dart';
import 'theme.dart';
import 'widgets.dart';

Future<void> showTableBrowser(BuildContext context, AppSettings settings, Target t, String table, {Future<Map<String, dynamic>> Function(int offset)? load}) =>
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .35),
      builder: (_) => _TableDialog(t, table, load ?? (offset) => Operations(settings, Journal()).tableData(t, table, offset: offset)),
    );

class _TableDialog extends StatefulWidget {
  const _TableDialog(this.t, this.table, this.load);
  final Target t;
  final String table;
  final Future<Map<String, dynamic>> Function(int offset) load;
  @override
  State<_TableDialog> createState() => _TableDialogState();
}

class _TableDialogState extends State<_TableDialog> {
  int offset = 0;
  bool columnsTab = false;
  late Future<Map<String, dynamic>> data = widget.load(0);

  void _page(int o) => setState(() {
        offset = max(0, o);
        data = widget.load(offset);
      });

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final p = ty.p;
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: SizedBox(
        width: min(1240.0, size.width - 40),
        height: size.height * .86,
        child: FutureBuilder<Map<String, dynamic>>(
          future: data,
          builder: (context, snap) {
            final d = snap.data;
            final count = (d?['count'] as num?)?.toInt() ?? 0;
            final cols = [for (final c in (d?['columns'] as List? ?? [])) (c as Map).cast<String, dynamic>()];
            final rows = [for (final r in (d?['rows'] as List? ?? [])) [for (final v in (r as List)) v?.toString()]];
            Widget tab(String label, bool on, VoidCallback f) => InkWell(
                  onTap: f,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: on ? p.accent : Colors.transparent, width: 2))),
                    child: Text(label, style: ty.strong.copyWith(color: on ? p.ink : p.muted, fontSize: 13.5)),
                  ),
                );
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 16, 10, 0),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${widget.t.name.toUpperCase()}  ·  ${tr('read only').toUpperCase()}', style: ty.caps()),
                      const SizedBox(height: 4),
                      Row(children: [
                        Icon(Icons.table_chart_outlined, size: 18, color: p.muted),
                        const SizedBox(width: 8),
                        SelectableText(widget.table, style: ty.mono(size: 16, weight: FontWeight.w700)),
                        const SizedBox(width: 12),
                        if (d != null) Tag(pl(count, '{n} row', '{n} rows', '{n} ligne', '{n} lignes')),
                        const SizedBox(width: 6),
                        if (d != null) Tag(pl(cols.length, '{n} column', '{n} columns', '{n} colonne', '{n} colonnes')),
                      ]),
                    ]),
                  ),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, size: 18), tooltip: tr('Close')),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 12, top: 6),
                child: Row(children: [
                  tab(tr('Rows'), !columnsTab, () => setState(() => columnsTab = false)),
                  tab(tr('Columns'), columnsTab, () => setState(() => columnsTab = true)),
                  const Spacer(),
                  if (!columnsTab && d != null) ...[
                    Text(count == 0 ? '' : tr('{a}–{b} of {n}', {'a': fmtInt(offset + 1), 'b': fmtInt(min(offset + rows.length, count)), 'n': fmtInt(count)}), style: ty.small),
                    IconButton(onPressed: offset == 0 ? null : () => _page(offset - 50), icon: const Icon(Icons.chevron_left), tooltip: tr('Previous')),
                    IconButton(onPressed: offset + rows.length >= count ? null : () => _page(offset + 50), icon: const Icon(Icons.chevron_right), tooltip: tr('Next')),
                    const SizedBox(width: 10),
                  ],
                ]),
              ),
              Container(height: 1, color: p.rule),
              Expanded(
                child: snap.hasError
                    ? Padding(padding: const EdgeInsets.all(22), child: Text('${snap.error}'.replaceFirst('AgentError: ', ''), style: ty.body.copyWith(color: p.removed)))
                    : d == null
                        ? const Loading()
                        : SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: columnsTab
                                ? DataGrid(
                                    columns: [tr('Column'), tr('Type'), tr('Null'), tr('Key'), tr('Default'), tr('Extra')],
                                    rows: [
                                      for (final c in cols) ['${c['name']}', '${c['type']}', c['null'] == true ? 'YES' : 'NO', '${c['key'] ?? ''}', c['default']?.toString(), '${c['extra'] ?? ''}'],
                                    ],
                                  )
                                : rows.isEmpty
                                    ? Text(tr('Empty table.'), style: ty.small)
                                    : DataGrid(columns: [for (final c in cols) '${c['name']}'], rows: rows),
                          ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}
