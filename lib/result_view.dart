// What a deployment did — shown right after it, and kept in the history of the target: files written, migrations run
// (with their statements), synced rows, the backup made first, how long it took; or where it stopped.
import 'package:flutter/material.dart';

import 'i18n.dart';
import 'motion.dart';
import 'report_view.dart';
import 'results.dart';
import 'theme.dart';
import 'widgets.dart';

String _when(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

String _duration(double s) => s < 60 ? '${s.toStringAsFixed(s < 10 ? 1 : 0)} s' : '${(s / 60).floor()} min ${(s % 60).round()} s';

class ResultView extends StatelessWidget {
  const ResultView(this.r, {super.key, this.onClose});
  final DeployResult r;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final p = ty.p;
    final color = r.ok ? p.added : p.removed;
    final statements = r.migrations.fold(0, (s, m) => s + m.$2);
    return staggered([
      AppCard(
        padding: const EdgeInsets.fromLTRB(18, 14, 8, 14),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(10)),
            child: PopIn(child: Icon(r.ok ? Icons.check_circle_outline : Icons.error_outline, color: color, size: 21)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.ok ? tr('Deployed: "{name}" is up to date.', {'name': r.target}) : tr('The deployment stopped.'), style: ty.title.copyWith(color: r.ok ? p.ink : p.removed)),
              Text('${_when(r.time)}  ·  ${_duration(r.seconds)}${r.label.isEmpty ? '' : '  ·  ${r.label}'}${r.parts.all ? '' : '  ·  ${r.parts.label}'}', style: ty.small),
              if (r.error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(r.error!, style: ty.body.copyWith(color: p.removed, fontSize: 13.5))),
              if (r.git.isNotEmpty || r.gitError.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(r.gitError.isEmpty ? tr('Sent to GitHub: {what}', {'what': r.git}) : tr('Not sent to GitHub: {error}', {'error': r.gitError}),
                      style: ty.small.copyWith(color: r.gitError.isEmpty ? p.added : p.changed)),
                ),
            ]),
          ),
          if (onClose != null) IconButton(onPressed: onClose, icon: const Icon(Icons.close, size: 18), tooltip: tr('Close')),
        ]),
      ),
      TileRow([
        StatTile(
          icon: Icons.description_outlined,
          label: tr('Files written'),
          value: r.parts.files ? fmtInt(r.written) : '—',
          color: r.written > 0 ? p.changed : null,
          caption: !r.parts.files
              ? tr('Not deployed this time.')
              : [
                  pl(r.removed, '{n} removed', '{n} removed', '{n} retiré', '{n} retirés'),
                  tr('{n} already up to date', {'n': fmtInt(r.same)}),
                ].join(' · '),
        ),
        StatTile(
          icon: Icons.schema_outlined,
          label: tr('Migrations run'),
          value: r.parts.structure ? fmtInt(r.migrations.length) : '—',
          color: r.migrations.isEmpty ? null : p.accent,
          caption: !r.parts.structure
              ? tr('Not deployed this time.')
              : r.migrations.isEmpty
              ? (r.baseline > 0 ? tr('{n} recorded as applied', {'n': fmtInt(r.baseline)}) : tr('No structure change.'))
              : pl(statements, '{n} statement', '{n} statements', '{n} instruction', '{n} instructions'),
        ),
        StatTile(
          icon: Icons.sync,
          label: tr('Synced rows'),
          value: r.parts.data ? fmtInt(r.rowsAdded + r.rowsUpdated) : '—',
          color: r.rowsAdded + r.rowsUpdated > 0 ? p.changed : null,
          caption: !r.parts.data
              ? tr('Not deployed this time.')
              : [
                  pl(r.rowsAdded, '+{n} added', '+{n} added', '+{n} ajoutée', '+{n} ajoutées'),
                  pl(r.rowsUpdated, '{n} updated', '{n} updated', '{n} mise à jour', '{n} mises à jour'),
                ].join(' · '),
        ),
        StatTile(
          icon: Icons.inventory_2_outlined,
          label: tr('Backup first'),
          value: r.backups.isEmpty ? '—' : fmtInt(r.backups.length),
          color: r.backups.isEmpty ? null : p.added,
          caption: r.backups.isEmpty ? tr('none') : tr('Restore a backup… puts it back'),
        ),
      ]),
      if (r.newFiles.isNotEmpty || r.changedFiles.isNotEmpty || r.removedFiles.isNotEmpty)
        Section(
          tr('Files'),
          icon: Icons.folder_open_outlined,
          meta: [
            pl(r.newFiles.length, '{n} new', '{n} new', '{n} nouveau', '{n} nouveaux'),
            pl(r.changedFiles.length, '{n} changed', '{n} changed', '{n} modifié', '{n} modifiés'),
            pl(r.removedFiles.length, '{n} removed', '{n} removed', '{n} retiré', '{n} retirés'),
          ].join('  ·  '),
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final (k, list, c) in [('A', r.newFiles, p.added), ('M', r.changedFiles, p.changed), ('D', r.removedFiles, p.removed)])
                for (final f in list.take(60))
                  Row(children: [
                    SizedBox(width: 22, child: Text(k, style: ty.mono(color: c, weight: FontWeight.w700))),
                    Expanded(child: Text(f, style: ty.mono(), overflow: TextOverflow.ellipsis)),
                  ]),
            ]),
          ),
        ),
      if (r.migrations.isNotEmpty)
        Section(
          tr('Migrations run'),
          icon: Icons.schema_outlined,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (name, n) in r.migrations)
              LedgerRow(
                vertical: 8,
                child: Row(children: [
                  Icon(Icons.check, size: 16, color: p.added),
                  const SizedBox(width: 8),
                  Expanded(child: Text(name, style: ty.mono())),
                  Text(pl(n, '{n} statement', '{n} statements', '{n} instruction', '{n} instructions'), style: ty.small),
                ]),
              ),
          ]),
        ),
      if (r.tables.any((t) => t.changes.isNotEmpty || t.error != null))
        Section(tr('Structure of the chosen tables'), icon: Icons.table_chart_outlined, meta: tr('nothing removed'), child: TableChanges(r.tables)),
      if (r.sync.isNotEmpty) Section(tr('Synced data'), icon: Icons.sync, meta: tr('nothing deleted'), child: SyncTables(r.sync)),
      if (r.backups.isNotEmpty || r.missingAfter > 0)
        Section(
          tr('Checks'),
          icon: Icons.fact_check_outlined,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (r.backups.isNotEmpty) Fact(tr('Backup'), r.backups.join('  ·  '), mono: true),
            Fact(
              tr('Database structure'),
              r.missingAfter == 0 ? tr('complete') : tr('{n} table(s) or column(s) still missing', {'n': r.missingAfter}),
              color: r.missingAfter == 0 ? p.added : p.removed,
            ),
          ]),
        ),
    ]);
  }
}

/// The last deployments of a target; a click shows one.
class HistoryView extends StatelessWidget {
  const HistoryView(this.items, {super.key, required this.onOpen});
  final List<DeployResult> items;
  final void Function(DeployResult) onOpen;

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final p = ty.p;
    return Section(
      tr('History'),
      icon: Icons.history,
      meta: pl(items.length, '{n} deployment', '{n} deployments', '{n} déploiement', '{n} déploiements'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final r in items.take(15))
          LedgerRow(
            vertical: 9,
            onTap: () => onOpen(r),
            child: LayoutBuilder(
              builder: (context, c) => Row(children: [
                Icon(r.ok ? Icons.check_circle : Icons.error, size: 17, color: r.ok ? p.added : p.removed),
                const SizedBox(width: 10),
                SizedBox(width: 128, child: Text(_when(r.time), style: ty.figure(size: 13.5))),
                Expanded(
                  child: Text(
                    r.ok
                        ? [
                            if (r.parts.files) pl(r.written, '{n} file', '{n} files', '{n} fichier', '{n} fichiers'),
                            if (r.parts.structure) pl(r.migrations.length, '{n} migration', '{n} migrations', '{n} migration', '{n} migrations'),
                            if (r.parts.data) pl(r.rowsAdded + r.rowsUpdated, '{n} row', '{n} rows', '{n} ligne', '{n} lignes'),
                          ].join('  ·  ')
                        : (r.error ?? tr('The deployment stopped.')),
                    style: ty.small.copyWith(color: r.ok ? p.muted : p.removed),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!isNarrow(c)) Text(_duration(r.seconds), style: ty.small.copyWith(color: p.faint)),
                Icon(Icons.chevron_right, size: 18, color: p.faint),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// A past deployment, in a dialog.
Future<void> showResult(BuildContext context, DeployResult r) => showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .35),
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        return Dialog(
          insetPadding: const EdgeInsets.all(20),
          backgroundColor: Palette.of(ctx).bg,
          child: SizedBox(
            width: size.width < 1240 ? size.width - 40 : 1200,
            height: size.height * .86,
            child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 20), child: ResultView(r, onClose: () => Navigator.pop(ctx))),
          ),
        );
      },
    );
