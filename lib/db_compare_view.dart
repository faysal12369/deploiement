// "Compare databases": this PC and a target side by side, read only on both. Data: the rows of each table recognised
// by their key (never the id), grouped by table. Structure: the Delta Schéma page,
// filled in with both structures, writes the SQL script that brings the target to this PC.
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app_state.dart';
import 'i18n.dart';
import 'models.dart';
import 'pickers.dart';
import 'report_html.dart';
import 'results.dart';
import 'theme.dart';
import 'widgets.dart';

/// Runs the comparison (in the activity panel), then shows it.
Future<void> compareDatabases(BuildContext context, AppState app, Project pr, Target t) async {
  final c = await app.run(t, (o) => o.compareDatabases(pr, t));
  if (c == null || !context.mounted) return;
  app.activityOpen = false;
  app.changed();
  await showDbCompare(context, app, pr, t, c);
}

Future<void> showDbCompare(BuildContext context, AppState app, Project pr, Target t, DbCompare c) =>
    showDialog(context: context, barrierColor: Colors.black.withValues(alpha: .35), builder: (_) => DbCompareDialog(app, pr, t, c));

void _openInBrowser(String path) => Process.start('rundll32', ['url.dll,FileProtocolHandler', path]);

class DbCompareDialog extends StatefulWidget {
  const DbCompareDialog(this.app, this.project, this.target, this.c, {super.key});
  final AppState app;
  final Project project;
  final Target target;
  final DbCompare c;
  @override
  State<DbCompareDialog> createState() => _DbCompareDialogState();
}

class _DbCompareDialogState extends State<DbCompareDialog> {
  bool structureTab = false;
  bool all = false; // also the identical tables and the logs
  final open = <String>{};

  DbCompare get c => widget.c;
  Target get t => widget.target;

  String get _stamp {
    String two(int n) => n.toString().padLeft(2, '0');
    final d = c.time;
    return '${d.year}${two(d.month)}${two(d.day)}-${two(d.hour)}${two(d.minute)}';
  }

  String get _safeName => t.name.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');

  Future<void> _save() async {
    final loc = await pickSaveFile(name: 'databases-$_safeName-$_stamp.html', filter: 'HTML (*.html)|*.html');
    if (loc == null) return;
    await File(loc).writeAsString(dataCompareHtml(c, widget.project, t));
    widget.app.notify(tr('Report saved.'), text: loc);
    _openInBrowser(loc);
  }

  /// The two structure exports as .sql files, to keep or to load in another tool.
  Future<void> _saveSql() async {
    final d = await pickFolder(title: tr('Choose where to save the two structure exports'));
    if (d == null) return;
    final a = File(p.join(d, 'structure-this-pc-$_stamp.sql')), b = File(p.join(d, 'structure-$_safeName-$_stamp.sql'));
    await a.writeAsString(c.pcSql);
    await b.writeAsString(c.targetSql);
    widget.app.notify(tr('Structure exports saved.'), text: '${a.path}\n${b.path}');
  }

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final pa = ty.p;
    final size = MediaQuery.sizeOf(context);
    Widget tab(String label, bool on, VoidCallback f, String key) => InkWell(
      key: ValueKey(key),
      onTap: f,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: on ? pa.accent : Colors.transparent, width: 2)),
        ),
        child: Text(label, style: ty.strong.copyWith(color: on ? pa.ink : pa.muted, fontSize: 13.5)),
      ),
    );
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: SizedBox(
        width: min(1240.0, size.width - 40),
        height: size.height * .86,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 10, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${tr('This PC').toUpperCase()}  ⇄  ${t.name.toUpperCase()}  ·  ${tr('read only').toUpperCase()}', style: ty.caps(), overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.compare_arrows, size: 19, color: pa.muted),
                                const SizedBox(width: 8),
                                Text(tr('Compare databases'), style: ty.title),
                              ],
                            ),
                            Tag('${tr('This PC')}: ${c.pc.database} · ${c.pc.server}', icon: Icons.computer),
                            Tag('${t.name}: ${c.target.database} · ${c.target.server}', icon: Icons.dns_outlined),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close, size: 18), tooltip: tr('Close')),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 6, right: 12),
              // the actions go under the tabs when the window is narrow
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                runSpacing: 4,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      tab(tr('Data'), !structureTab, () => setState(() => structureTab = false), 'db-tab-data'),
                      tab(
                        MediaQuery.sizeOf(context).width < 640 ? tr('Structure') : tr('Structure (SQL script)'),
                        structureTab,
                        () => setState(() => structureTab = true),
                        'db-tab-structure',
                      ),
                    ],
                  ),
                  if (!structureTab)
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SmallButton(all ? tr('Only differences') : tr('All tables'), onPressed: () => setState(() => all = !all)),
                        OutlinedButton(key: const ValueKey('db-save'), onPressed: _save, child: Text(tr('Save the report…'))),
                      ],
                    ),
                ],
              ),
            ),
            Container(height: 1, color: pa.rule),
            Expanded(
              child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 18), child: structureTab ? _structure(ty) : _data(ty)),
            ),
          ],
        ),
      ),
    );
  }

  // ---- DATA --------------------------------------------------------------------------------------------------------

  Widget _data(Ty ty) {
    final pa = ty.p;
    final shown = [
      for (final g in DataRank.values)
        if (all || (g != DataRank.same && g != DataRank.countOnly)) (g, c.tables.where((x) => x.rank == g).toList()),
    ].where((e) => e.$2.isNotEmpty).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Text(dataHeadline(c), style: ty.cardTitle.copyWith(color: c.withMissing > 0 ? pa.removed : pa.added)),
        ),
        Text(tr('Rows are recognised by their key (a reference, a code, a unique index), never by their id, which differs between copies.'), style: ty.small),
        TileRow([
          StatTile(icon: Icons.table_rows_outlined, label: tr('Tables'), value: fmtInt(c.tables.length), caption: tr('compared')),
          StatTile(
            icon: Icons.call_made,
            label: tr('Missing on the target'),
            value: fmtInt(c.withMissing),
            color: c.withMissing > 0 ? pa.removed : pa.added,
            caption: tr('tables with rows of this PC'),
          ),
          StatTile(icon: Icons.call_received, label: tr('Only on the target'), value: fmtInt(c.count(DataRank.extraOnTarget)), caption: tr('tables with more rows there')),
          StatTile(icon: Icons.check, label: tr('Identical'), value: fmtInt(c.count(DataRank.same)), color: pa.added, caption: tr('tables')),
        ]),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Text(tr('No difference.'), style: ty.small),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.only(top: 18, bottom: 2, left: 8, right: 8),
            child: Row(
              children: [
                const SizedBox(width: 23),
                Expanded(flex: 4, child: Text(tr('Table').toUpperCase(), style: ty.caps())),
                SizedBox(
                  width: 84,
                  child: Text(tr('This PC').toUpperCase(), style: ty.caps(), textAlign: TextAlign.right),
                ),
                SizedBox(
                  width: 84,
                  child: Text(tr('Target').toUpperCase(), style: ty.caps(), textAlign: TextAlign.right),
                ),
                const SizedBox(width: 18),
                Expanded(flex: 4, child: Text(tr('Difference').toUpperCase(), style: ty.caps())),
              ],
            ),
          ),
          for (final (g, list) in shown) ...[
            Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 4),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      dataGroupTitle(g),
                      style: ty.strong.copyWith(color: _groupColor(g, pa)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Tag(pl(list.length, '{n} table', '{n} tables', '{n} table', '{n} tables')),
                ],
              ),
            ),
            for (final x in list) _row(x, ty),
          ],
        ],
      ],
    );
  }

  Color _groupColor(DataRank g, Palette pa) => switch (g) {
    DataRank.oneSide || DataRank.missingOnTarget => pa.removed,
    DataRank.fewerOnTarget => pa.changed,
    DataRank.same => pa.added,
    _ => pa.ink,
  };

  Widget _row(DataCompare x, Ty ty) {
    final pa = ty.p;
    final more = x.onlyPc.isNotEmpty || x.onlyTarget.isNotEmpty;
    final isOpen = open.contains(x.table);
    String n(InvTable? v) => v == null ? '—' : fmtInt(v.rows);
    final gap = [
      if (x.onlyPc.isNotEmpty)
        Text(
          pl(
            x.onlyPc.length,
            '{n} row of this PC missing on the target',
            '{n} rows of this PC missing on the target',
            '{n} ligne de ce PC absente de la cible',
            '{n} lignes de ce PC absentes de la cible',
          ),
          style: ty.small.copyWith(color: pa.removed, fontWeight: FontWeight.w600),
        ),
      if (x.onlyTarget.isNotEmpty)
        Text(
          pl(x.onlyTarget.length, '{n} row only on the target', '{n} rows only on the target', '{n} ligne seulement sur la cible', '{n} lignes seulement sur la cible'),
          style: ty.small,
        ),
      if (!more && dataGap(x).isNotEmpty) Text(dataGap(x), style: ty.small),
      if (x.byKey && (x.pc!.noKey > 0 || x.target!.noKey > 0))
        Text(tr('Without a key (counted only): this PC {a}, target {b}', {'a': x.pc!.noKey, 'b': x.target!.noKey}), style: ty.small.copyWith(fontSize: 11.5)),
    ];
    return LedgerRow(
      key: ValueKey('data-${x.table}'),
      vertical: 8,
      onTap: more ? () => setState(() => isOpen ? open.remove(x.table) : open.add(x.table)) : null,
      // a row that opens has its own inner margin: the others get the same, to stay under the column titles
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: more ? 0 : 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 23, child: Icon(more ? (isOpen ? Icons.expand_less : Icons.expand_more) : Icons.table_chart_outlined, size: 15, color: pa.faint)),
                Expanded(
                  flex: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(x.table, style: ty.mono(size: 12.5), overflow: TextOverflow.ellipsis),
                      if (x.byKey) Text(tr('key: {key}', {'key': x.keyText}), style: ty.small.copyWith(fontSize: 11.5), overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                SizedBox(
                  width: 84,
                  child: Text(n(x.pc), style: ty.figure(size: 13), textAlign: TextAlign.right),
                ),
                SizedBox(
                  width: 84,
                  child: Text(n(x.target), style: ty.figure(size: 13), textAlign: TextAlign.right),
                ),
                const SizedBox(width: 18),
                Expanded(
                  flex: 4,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: gap),
                ),
              ],
            ),
            if (isOpen) ...[
              if (x.onlyPc.isNotEmpty) _list(tr('On this PC, not on the target'), x.onlyPc, pa.removed, ty),
              if (x.onlyTarget.isNotEmpty) _list(tr('On the target, not on this PC'), x.onlyTarget, pa.muted, ty),
            ],
          ],
        ),
      ),
    );
  }

  Widget _list(String title, List<String> rows, Color color, Ty ty) {
    const most = 300;
    final shown = rows.take(most).toList();
    return Container(
      margin: const EdgeInsets.only(left: 23, top: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: ty.p.sunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ty.p.rule),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title.toUpperCase(), style: ty.caps(color: color)),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: shown.length + (rows.length > most ? 1 : 0),
              itemBuilder: (_, i) =>
                  i < shown.length ? SelectableText(shown[i], style: ty.mono(size: 12)) : Text(tr('… and {n} more', {'n': fmtInt(rows.length - most)}), style: ty.small),
            ),
          ),
        ],
      ),
    );
  }

  // ---- STRUCTURE ---------------------------------------------------------------------------------------------------

  Widget _structure(Ty ty) {
    int tables(String sql) => RegExp(r'^CREATE TABLE ', multiLine: true).allMatches(sql).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Text(tr('The SQL script that brings the structure of the target to the one of this PC'), style: ty.cardTitle),
        ),
        const SizedBox(height: 4),
        Text(
          tr(
            'Both structures are filled into the Delta Schéma page, already compared: differences, the script (ALTER TABLE, CREATE TABLE…) written for the server of the target, and warnings. It opens in your browser and changes nothing: run the script yourself, or save it as a migration of the project.',
          ),
          style: ty.body,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              key: const ValueKey('db-open-delta'),
              onPressed: () => _openInBrowser(c.deltaPage.path),
              icon: const Icon(Icons.open_in_new, size: 17),
              label: Text(tr('Open the SQL script page')),
            ),
            OutlinedButton(onPressed: _saveSql, child: Text(tr('Save the two exports (.sql)…'))),
          ],
        ),
        const SizedBox(height: 18),
        Fact(tr('Old: the target'), '${c.target.database} · ${c.target.server} · ${pl(tables(c.targetSql), '{n} table', '{n} tables', '{n} table', '{n} tables')}', mono: true),
        Fact(tr('New: this PC'), '${c.pc.database} · ${c.pc.server} · ${pl(tables(c.pcSql), '{n} table', '{n} tables', '{n} table', '{n} tables')}', mono: true),
        Fact(tr('Page'), c.deltaPage.path, mono: true),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(tr('The differences of columns are also in the simulation report ("Structure: this PC and the target").'), style: ty.small),
        ),
      ],
    );
  }
}
