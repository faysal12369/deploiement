// The simulation as a dashboard: four figures, then the files (filtered, by folder; a click compares), the database
// (migrations, structure of this PC next to the target's), the synced rows as grids (new rows, changed cells old →
// new) and the tables of the target (a click shows their columns and rows).
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'db_compare_view.dart';
import 'diff.dart';
import 'diff_view.dart';
import 'motion.dart';
import 'i18n.dart';
import 'models.dart';
import 'operations.dart';
import 'pickers.dart';
import 'report_files.dart';
import 'report_html.dart';
import 'results.dart';
import 'table_view.dart';
import 'theme.dart';
import 'widgets.dart';

class ReportView extends StatefulWidget {
  const ReportView(this.r, {super.key, required this.app, required this.project, required this.target});
  final Report r;
  final AppState app;
  final Project project;
  final Target target;
  @override
  State<ReportView> createState() => _ReportViewState();
}

class _ReportViewState extends State<ReportView> {
  bool allStructure = false;

  /// The simulation as a web page: lines that change in each changed file (fetched from the target), database,
  /// synced rows. Opened in the browser once written.
  Future<void> _saveReport() async {
    final r = widget.r, app = widget.app, pr = widget.project, t = widget.target;
    String two(int n) => n.toString().padLeft(2, '0');
    final d = r.time;
    final name = 'simulation-${t.name}-${d.year}${two(d.month)}${two(d.day)}-${two(d.hour)}${two(d.minute)}.html'.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    final loc = await pickSaveFile(name: name, filter: 'HTML (*.html)|*.html');
    if (loc == null) return;
    app.notify(tr('Preparing the report…'),
        text: tr('{n} changed file(s) read on "{name}" to show their lines; it opens in your browser when it is ready.', {'n': r.changedFiles.length, 'name': t.name}),
        severity: Severity.info);
    final ok = await app.run(t, (o) async {
      o.log.step(tr('Report of the simulation: {path}', {'path': loc}));
      final diffs = <String, FileDiff>{};
      String? note;
      if (Operations.features(r.status).contains('file')) {
        const most = 80;
        final todo = r.changedFiles.take(most).toList();
        // 6 files read at once on the target (17/11/2026, a shared host: 34 files one by one took 18 s, and the app was
        // closed before the report was written)
        var next = 0, done = 0;
        Future<void> worker() async {
          while (next < todo.length) {
            final f = todo[next++];
            try {
              final v = await fileVersions(app.settings, pr, t, f, 'M');
              diffs[f] = FileDiff.of(v.$1, v.$2);
            } catch (e) {
              o.log.warn('$f: ${'$e'.replaceFirst('AgentError: ', '')}');
            }
            done++;
            o.log.progress(tr('Comparing {i} / {n}: {path}', {'i': done, 'n': todo.length, 'path': f}));
          }
        }

        await Future.wait([for (var i = 0; i < 6; i++) worker()]);
        if (r.changedFiles.length > most) note = tr('Only the first {n} changed files are compared in this report.', {'n': most});
      } else {
        note = tr('The agent on the target is too old to show its files: the lines that change are not in this report.');
      }
      await File(loc).writeAsString(reportHtml(r, pr, t, diffs, note: note));
      o.log.ok(tr('Report saved: {path}', {'path': loc}));
      return true;
    });
    if (ok == true) {
      app.activityOpen = false;
      app.changed();
      app.notify(tr('Report saved.'), text: loc);
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', loc]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.r;
    final ty = Ty.of(context);
    final p = ty.p;
    String two(int n) => n.toString().padLeft(2, '0');
    final today = DateUtils.isSameDay(r.time, DateTime.now()); // a simulation kept from another day shows its date
    final hh = '${today ? '' : '${two(r.time.day)}/${two(r.time.month)} '}${two(r.time.hour)}:${two(r.time.minute)}';
    final files = r.newFiles.length + r.changedFiles.length + r.removedFiles.length;
    final rows = r.rowsAdded + r.rowsUpdated;
    final tables = r.missing.where((m) => m.$2 == null).length;
    final cols = r.missing.length - tables;
    Widget none(String s) => Padding(padding: const EdgeInsets.only(top: 12), child: Text(s, style: ty.small));
    final structure = r.localStructure != null && r.targetStructure != null ? compareStructures(r.localStructure!, r.targetStructure!) : null;
    final differs = structure?.where((x) => x.state != Diff.same).toList() ?? const [];

    return staggered([
      // HEADLINE
      AppCard(
        padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: (r.upToDate ? p.added : p.accent).withValues(alpha: .12), borderRadius: BorderRadius.circular(10)),
            child: Icon(r.upToDate ? Icons.check_circle_outline : Icons.upload_outlined, color: r.upToDate ? p.added : p.accent, size: 21),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(reportHeadline(r), style: ty.title.copyWith(color: r.upToDate ? p.added : p.ink)),
              Text(tr('Simulation at {time} — nothing was changed on the target', {'time': hh}), style: ty.small),
            ]),
          ),
          OutlinedButton.icon(
            key: const ValueKey('report-save'),
            onPressed: widget.app.busy ? null : _saveReport,
            icon: const Icon(Icons.download_outlined, size: 17),
            label: Text(tr('Save the report…')),
          ),
        ]),
      ),
      // FIGURES
      TileRow([
        StatTile(
          icon: Icons.description_outlined,
          label: tr('Files'),
          value: fmtInt(files),
          color: files == 0 ? p.added : p.changed,
          caption: [
            pl(r.newFiles.length, '{n} new', '{n} new', '{n} nouveau', '{n} nouveaux'),
            pl(r.changedFiles.length, '{n} changed', '{n} changed', '{n} modifié', '{n} modifiés'),
            pl(r.removedFiles.length, '{n} removed', '{n} removed', '{n} retiré', '{n} retirés'),
          ].join(' · '),
        ),
        StatTile(
          icon: Icons.schema_outlined,
          label: tr('Migrations'),
          value: r.dbOk ? fmtInt(r.migrations.length) : '—',
          color: r.migrations.isEmpty ? null : p.accent,
          caption: !r.dbOk
              ? tr('No database on the target')
              : (r.baseline.isNotEmpty
                  ? tr('{n} already there', {'n': fmtInt(r.baseline.length)})
                  : (r.migrations.isEmpty ? tr('No structure change.') : tr('to run'))),
        ),
        StatTile(
          icon: Icons.sync,
          label: tr('Synced rows'),
          value: r.dbOk ? fmtInt(rows) : '—',
          color: rows == 0 ? null : p.changed,
          caption: [
            pl(r.rowsAdded, '+{n} added', '+{n} added', '+{n} ajoutée', '+{n} ajoutées'),
            pl(r.rowsUpdated, '{n} updated', '{n} updated', '{n} mise à jour', '{n} mises à jour'),
          ].join(' · '),
        ),
        StatTile(
          icon: Icons.dns_outlined,
          label: tr('Target database'),
          value: r.summary == null ? '—' : fmtInt(r.summary!.tables),
          caption: r.summary == null
              ? null
              : '${pl(r.summary!.tables, 'table', 'tables', 'table', 'tables')} · ${pl(r.summary!.rows, 'about {n} row', 'about {n} rows', 'environ {n} ligne', 'environ {n} lignes')}',
        ),
      ]),
      // FILES
      Section(
        tr('Files'),
        icon: Icons.folder_open_outlined,
        meta: tr('{n} in the project', {'n': fmtInt(r.total)}),
        child: files == 0
            ? none(tr('No file to send.'))
            : ReportFiles(r,
                own: {for (final f in widget.target.files) f.remote.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '')},
                onOpen: (path, kind) => showFileDiff(context, widget.app.settings, widget.project, widget.target, path, kind)),
      ),
      // DATABASE
      Section(
        tr('Database'),
        icon: Icons.schema_outlined,
        meta: !r.dbOk || r.migrations.isEmpty && r.missing.isEmpty
            ? null
            : [
                if (r.migrations.isNotEmpty) pl(r.migrations.length, '{n} migration to run', '{n} migrations to run', '{n} migration à passer', '{n} migrations à passer'),
                if (tables > 0) pl(tables, '{n} new table', '{n} new tables', '{n} nouvelle table', '{n} nouvelles tables'),
                if (cols > 0) pl(cols, '{n} new column', '{n} new columns', '{n} nouvelle colonne', '{n} nouvelles colonnes'),
              ].join('  ·  '),
        child: !r.dbOk
            ? none(tr('No database on the target (or no settings): migrations and synced tables are skipped.'))
            : (r.migrations.isEmpty && r.missing.isEmpty && r.baseline.isEmpty
                ? none(tr('No structure change.'))
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final (path, reason) in r.migrations)
                      LedgerRow(
                        vertical: 8,
                        child: Row(children: [
                          Icon(Icons.play_arrow_outlined, size: 16, color: p.accent),
                          const SizedBox(width: 8),
                          Expanded(child: Text(path.split('/').last, style: ty.mono())),
                          Tag(reason == 'changed' ? tr('file changed') : tr('not run yet'), color: reason == 'changed' ? p.changed : p.accent),
                        ]),
                      ),
                    if (r.missing.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(tr('Added by the migrations:'), style: ty.small),
                      const SizedBox(height: 4),
                      Wrap(spacing: 8, runSpacing: 6, children: [
                        for (final (tb, col) in r.missing.take(60)) Tag(col == null ? '+ $tb' : '+ $tb.$col', color: p.added),
                      ]),
                    ],
                    if (r.baseline.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(tr('{n} migration(s) already in the project folder of the target: recorded as applied, not run.', {'n': r.baseline.length}),
                            style: ty.small),
                      ),
                  ])),
      ),
      // STRUCTURE OF THE CHOSEN TABLES
      if (r.dbOk && r.tables.isNotEmpty)
        Section(
          tr('Structure of the chosen tables'),
          icon: Icons.table_chart_outlined,
          meta: r.tableChanges == 0
              ? tr('the same as on this PC')
              : '${pl(r.tableChanges, '{n} change', '{n} changes', '{n} changement', '{n} changements')}  ·  ${tr('nothing removed')}',
          child: TableChanges(r.tables),
        ),
      // STRUCTURE: THIS PC NEXT TO THE TARGET
      if (structure != null)
        Section(
          tr('Structure: this PC and the target'),
          icon: Icons.account_tree_outlined,
          meta: differs.isEmpty
              ? tr('Same tables and columns on both sides.')
              : [
                  for (final (d, one, many, fr1, frN) in [
                    (Diff.differs, '{n} table differs', '{n} tables differ', '{n} table diffère', '{n} tables diffèrent'),
                    (Diff.missing, '{n} only on this PC', '{n} only on this PC', '{n} seulement sur ce PC', '{n} seulement sur ce PC'),
                    (Diff.extra, '{n} only on the target', '{n} only on the target', '{n} seulement sur la cible', '{n} seulement sur la cible'),
                  ])
                    if (differs.any((x) => x.state == d)) pl(differs.where((x) => x.state == d).length, one, many, fr1, frN),
                ].join('  ·  '),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              key: const ValueKey('structure-compare-db'),
              tooltip: tr('Compare databases…'),
              icon: const Icon(Icons.compare_arrows, size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: widget.app.busy ? null : () => compareDatabases(context, widget.app, widget.project, widget.target),
            ),
            SmallButton(allStructure ? tr('Only differences') : tr('All tables'), onPressed: () => setState(() => allStructure = !allStructure)),
          ]),
          child: _StructureList(
            allStructure ? structure : differs,
            created: {for (final m in r.missing) if (m.$2 == null) m.$1},
          ),
        ),
      // SYNCED DATA
      if (r.dbOk && r.sync.isNotEmpty)
        Section(
          tr('Synced data'),
          icon: Icons.sync,
          meta: [
            pl(r.rowsAdded, '+{n} added', '+{n} added', '+{n} ajoutée', '+{n} ajoutées'),
            pl(r.rowsUpdated, '{n} updated', '{n} updated', '{n} mise à jour', '{n} mises à jour'),
            pl(r.rowsSkipped, '{n} skipped', '{n} skipped', '{n} écartée', '{n} écartées'),
            tr('nothing deleted'),
          ].join('  ·  '),
          child: SyncTables(r.sync),
        ),
      // TARGET DATA
      if (r.summary != null)
        Section(
          tr('Target data'),
          icon: Icons.dns_outlined,
          meta: tr('kept as they are — click a table to see its rows'),
          child: _TargetTables(r, widget.app.settings, widget.target),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 14, left: 4),
        child: Text(tr('Before deploying, the target database and files are backed up on the target. "Restore a backup…" puts them back.'), style: ty.small),
      ),
    ]);
  }
}

/// The structure of the chosen tables, one line per table: created, columns added or changed (before → after),
/// indexes added, columns only on the target (kept). Used by the simulation and by the result of a deployment.
class TableChanges extends StatelessWidget {
  const TableChanges(this.tables, {super.key});
  final List<TableChange> tables;

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final p = ty.p;
    String bare(String def) => def.replaceFirst(RegExp(r'^`[^`]+`\s*'), '');
    final list = [...tables]..sort((a, b) => b.changes.length.compareTo(a.changes.length));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final t in list)
        LedgerRow(
          vertical: 8,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(t.table, style: ty.mono(weight: FontWeight.w700)),
              if (t.create) Tag(tr('created'), color: p.added),
              if (!t.create && t.count('add_column') > 0)
                Tag(pl(t.count('add_column'), '+{n} column', '+{n} columns', '+{n} colonne', '+{n} colonnes'), color: p.added),
              if (t.count('change_column') > 0)
                Tag(pl(t.count('change_column'), '{n} column changed', '{n} columns changed', '{n} colonne modifiée', '{n} colonnes modifiées'), color: p.changed),
              if (!t.create && t.count('add_key') > 0)
                Tag(pl(t.count('add_key'), '+{n} index', '+{n} indexes', '+{n} index', '+{n} index'), color: p.added),
              if (t.changes.isEmpty) Text(tr('the same as on this PC'), style: ty.small),
              if (t.error != null) Tag(tr('failed'), color: p.removed),
            ]),
            if (!t.create)
              for (final c in t.changes)
                Padding(
                  padding: const EdgeInsets.only(top: 3, left: 2),
                  child: Text(
                    switch (c.what) {
                      'add_column' => '+ ${c.name}  ${bare(c.sql.replaceFirst(RegExp(r'^.* ADD COLUMN '), '').replaceFirst(RegExp(r' (AFTER `[^`]+`|FIRST)$'), ''))}',
                      'change_column' => '~ ${c.name}  ${bare(c.before)}  →  ${bare(c.after)}',
                      'add_key' => '+ ${tr('index')} ${c.name}',
                      _ => c.sql,
                    },
                    style: ty.mono(size: 12, color: c.what == 'change_column' ? p.changed : p.added),
                  ),
                ),
            if (t.kept.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(tr('Only on the target, kept: {list}', {'list': t.kept.join(', ')}), style: ty.small),
              ),
            if (t.error != null) Padding(padding: const EdgeInsets.only(top: 3), child: Text(t.error!, style: ty.small.copyWith(color: p.removed))),
          ]),
        ),
    ]);
  }
}

/// The tables of the target: rows of each, a click opens the table (columns and rows).
class _TargetTables extends StatelessWidget {
  const _TargetTables(this.r, this.settings, this.t);
  final Report r;
  final AppSettings settings;
  final Target t;

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final names = r.targetStructure?.keys.toList() ?? [for (final x in r.summary!.top) x.$1];
    final rows = {for (final x in r.summary!.top) x.$1: x.$2};
    names.sort((a, b) => (rows[b] ?? -1).compareTo(rows[a] ?? -1));
    if (names.isEmpty) return Padding(padding: const EdgeInsets.only(top: 12), child: Text(tr('Empty database.'), style: ty.small));
    final canBrowse = Operations.features(r.status).contains('table');
    return LayoutBuilder(builder: (context, c) {
      final per = (c.maxWidth / 260).floor().clamp(1, 4);
      final w = (c.maxWidth - (per - 1) * 16) / per;
      return Wrap(spacing: 16, children: [
        for (final n in names)
          SizedBox(
            width: w,
            child: LedgerRow(
              key: ValueKey('table-$n'),
              vertical: 7,
              onTap: canBrowse ? () => showTableBrowser(context, settings, t, n) : null,
              child: Row(children: [
                Icon(Icons.table_chart_outlined, size: 14, color: ty.p.faint),
                const SizedBox(width: 8),
                Expanded(child: Text(n, style: ty.mono(size: 12.5), overflow: TextOverflow.ellipsis)),
                Text(rows[n] == null ? '' : fmtInt(rows[n]!), style: ty.figure(size: 13, color: ty.p.muted)),
              ]),
            ),
          ),
      ]);
    });
  }
}

/// Tables of both structures; a click shows their columns side by side.
class _StructureList extends StatefulWidget {
  const _StructureList(this.tables, {required this.created});
  final List<TableCompare> tables;
  final Set<String> created; // tables the pending migrations create
  @override
  State<_StructureList> createState() => _StructureListState();
}

class _StructureListState extends State<_StructureList> {
  final open = <String>{};

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final p = ty.p;
    if (widget.tables.isEmpty) return Padding(padding: const EdgeInsets.only(top: 12), child: Text(tr('Same tables and columns on both sides.'), style: ty.small));
    Widget state(TableCompare t) => switch (t.state) {
          Diff.missing => Tag(widget.created.contains(t.table) ? tr('created by a migration') : tr('only on this PC'), color: widget.created.contains(t.table) ? p.added : p.accent),
          Diff.extra => Tag(tr('only on the target'), color: p.changed),
          Diff.differs => Tag(
              [
                if (t.count(Diff.missing) > 0) pl(t.count(Diff.missing), '{n} column missing on the target', '{n} columns missing on the target', '{n} colonne absente de la cible', '{n} colonnes absentes de la cible'),
                if (t.count(Diff.differs) > 0) pl(t.count(Diff.differs), '{n} column differs', '{n} columns differ', '{n} colonne diffère', '{n} colonnes diffèrent'),
                if (t.count(Diff.extra) > 0) pl(t.count(Diff.extra), '{n} only on the target', '{n} only on the target', '{n} seulement sur la cible', '{n} seulement sur la cible'),
              ].join(' · '),
              color: p.accent),
          Diff.same => Tag(tr('same')),
        };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final t in widget.tables.take(200)) ...[
        LedgerRow(
          key: ValueKey('structure-${t.table}'),
          vertical: 8,
          onTap: () => setState(() => open.contains(t.table) ? open.remove(t.table) : open.add(t.table)),
          child: Row(children: [
            Icon(open.contains(t.table) ? Icons.expand_more : Icons.chevron_right, size: 18, color: p.faint),
            const SizedBox(width: 6),
            Expanded(child: Text(t.table, style: ty.mono(size: 13), overflow: TextOverflow.ellipsis)),
            Flexible(child: Align(alignment: Alignment.centerRight, child: state(t))),
          ]),
        ),
        if (open.contains(t.table))
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 0, 12),
            child: DataGrid(
              columns: [tr('Column'), tr('This PC'), tr('Target')],
              widths: const [200, 330, 330],
              rows: [for (final c in t.columns) [c.name, ColumnCompare.describe(c.local), ColumnCompare.describe(c.target)]],
              rowColor: (i) => switch (t.columns[i].state) {
                Diff.missing => p.added.withValues(alpha: .08),
                Diff.extra => p.changed.withValues(alpha: .08),
                Diff.differs => p.accent.withValues(alpha: .08),
                Diff.same => null,
              },
            ),
          ),
      ],
    ]);
  }
}

/// The synced tables: a line per table with its figures; a click shows its rows as a grid — new rows in green,
/// changed cells "old → new".
class SyncTables extends StatefulWidget {
  const SyncTables(this.sync, {super.key});
  final List<SyncResult> sync;
  @override
  State<SyncTables> createState() => _SyncTablesState();
}

class _SyncTablesState extends State<SyncTables> {
  late final open = <String>{for (final s in widget.sync.where((s) => s.rows.isNotEmpty).take(1)) s.table};

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final p = ty.p;
    final list = [...widget.sync]..sort((a, b) => (b.added + b.pending + b.updated + b.skipped).compareTo(a.added + a.pending + a.updated + a.skipped));
    Widget n(int v, Color c, String sign, String label) => v == 0 ? const SizedBox() : Padding(padding: const EdgeInsets.only(left: 6), child: Tag('$sign${fmtInt(v)} $label', color: c));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final s in list) ...[
        LedgerRow(
          key: ValueKey('sync-${s.table}'),
          vertical: 8,
          onTap: s.rows.isEmpty && s.details.isEmpty ? null : () => setState(() => open.contains(s.table) ? open.remove(s.table) : open.add(s.table)),
          child: Row(children: [
            Icon(s.rows.isEmpty && s.details.isEmpty ? Icons.remove : (open.contains(s.table) ? Icons.expand_more : Icons.chevron_right), size: 18, color: p.faint),
            const SizedBox(width: 6),
            Expanded(
              child: Text.rich(TextSpan(children: [
                TextSpan(text: s.table, style: ty.mono(size: 13)),
                if (s.tableMissing) TextSpan(text: '   ${tr('created by the migrations')}', style: ty.small.copyWith(color: p.faint)),
              ])),
            ),
            n(s.added + s.pending, p.added, '+', tr('added')),
            n(s.updated, p.changed, '', tr('updated')),
            n(s.skipped, p.removed, '', tr('skipped')),
            Padding(padding: const EdgeInsets.only(left: 10), child: Text('${fmtInt(s.same)} ${tr('same')}', style: ty.small.copyWith(color: p.faint))),
          ]),
        ),
        if (open.contains(s.table))
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 0, 12),
            child: s.rows.isEmpty
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final (k, txt) in s.details)
                      Text('${switch (k) { 'add' => '+', 'update' => '~', 'unlink' => '○', _ => '×' }} $txt',
                          style: ty.mono(size: 12, color: switch (k) { 'add' => p.added, 'update' => p.changed, 'unlink' => p.changed, _ => p.removed })),
                  ])
                : _RowsGrid(s),
          ),
      ],
    ]);
  }
}

class _RowsGrid extends StatelessWidget {
  const _RowsGrid(this.s);
  final SyncResult s;
  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final p = ty.p;
    final cols = s.columns;
    // only the columns that change, plus the first ones, when a table is wide and only updates
    final rows = s.rows;
    // a changed cell shows "old → new": its column is as wide as both
    double width(String head, Iterable<String?> values) {
      var n = head.length;
      for (final v in values.take(80)) {
        n = (v?.length ?? 4) > n ? (v?.length ?? 4) : n;
      }
      return (n * 7.4 + 26).clamp(64, 380).toDouble();
    }

    final widths = <double>[
      34,
      width(tr('Key'), rows.map((r) => r.key)),
      for (var i = 0; i < cols.length; i++)
        width(cols[i], rows.map((r) => r.old.containsKey(cols[i]) ? '${r.old[cols[i]] ?? 'NULL'}  →  ${r.values[i] ?? 'NULL'}' : r.values[i])),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      DataGrid(
        widths: widths,
        columns: ['', tr('Key'), ...cols],
        maxHeight: 420,
        rows: [
          for (final r in rows) [r.kind == 'add' ? '+' : '~', r.key, ...r.values],
        ],
        rowColor: (i) => rows[i].kind == 'add' ? p.added.withValues(alpha: .07) : null,
        cell: (ri, ci, v) {
          final r = rows[ri];
          if (ci == 0) return Text(v ?? '', style: ty.mono(size: 12, weight: FontWeight.w700, color: r.kind == 'add' ? p.added : p.changed));
          if (ci < 2) return null;
          final col = cols[ci - 2];
          if (r.kind != 'update' || !r.old.containsKey(col)) return null;
          return Container(
            color: p.changed.withValues(alpha: .10),
            child: Text.rich(TextSpan(children: [
              TextSpan(text: r.old[col] ?? 'NULL', style: ty.mono(size: 12, color: p.removed).copyWith(decoration: TextDecoration.lineThrough)),
              TextSpan(text: '  →  ', style: ty.mono(size: 12, color: p.faint)),
              TextSpan(text: v ?? 'NULL', style: ty.mono(size: 12, color: p.added, weight: FontWeight.w700)),
            ])),
          );
        },
      ),
      if (s.added + s.updated > rows.length)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(tr('The first {n} rows are shown.', {'n': rows.length}), style: ty.small),
        ),
    ]);
  }
}

/// Children that slide in one after the other.
Widget staggered(List<Widget> children) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, c) in children.indexed) Appear(index: i, child: c),
    ]);
