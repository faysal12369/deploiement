// Confirmation and choice dialogs.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app_state.dart';
import 'clone.dart';
import 'git.dart';
import 'i18n.dart';
import 'local.dart';
import 'pickers.dart';
import 'models.dart';
import 'operations.dart';
import 'results.dart';
import 'theme.dart';
import 'widgets.dart';

/// A dialog of the look: title, content, buttons on the right.
Future<T?> showSheet<T>(BuildContext context, {required String title, required Widget Function(BuildContext, StateSetter) body, required List<Widget> Function(BuildContext, StateSetter) actions, double width = 500}) =>
    showDialog<T>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .35),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Dialog(
          insetPadding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(title, style: Ty.of(ctx).title),
                const SizedBox(height: 14),
                Flexible(child: SingleChildScrollView(child: DefaultTextStyle.merge(style: Ty.of(ctx).body, child: body(ctx, set)))),
                const SizedBox(height: 22),
                Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions(ctx, set)),
              ]),
            ),
          ),
        ),
      ),
    );

Widget _danger(BuildContext ctx, String label, VoidCallback? f) {
  final p = Palette.of(ctx);
  return FilledButton(style: FilledButton.styleFrom(backgroundColor: p.removed, foregroundColor: p.onAccent), onPressed: f, child: Text(label));
}

Future<bool> confirm(BuildContext context, String title, String text, {String? button, bool danger = false}) async =>
    await showSheet<bool>(
      context,
      title: title,
      body: (ctx, _) => Text(text),
      actions: (ctx, _) => [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel'))),
        if (danger)
          _danger(ctx, button ?? tr('Confirm'), () => Navigator.pop(ctx, true))
        else
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(button ?? tr('Confirm'))),
      ],
    ) ??
    false;

/// "Delete…" of a project (its page, the side panel): asks, deletes it from this app, offers "Undo".
Future<void> askRemoveProject(BuildContext context, AppState app, Project pr) async {
  if (app.busy) return;
  final names = pr.targets.map((t) => '« ${t.name} »').join(', ');
  if (!await confirm(
      context,
      tr('Delete the project "{name}"?', {'name': pr.name}),
      [
        pr.targets.isEmpty
            ? tr('Its settings are deleted from this app.')
            : tr('Its settings and its targets ({list}) are deleted from this app.', {'list': names}),
        tr('Nothing is touched on this PC nor on the servers: the folder, the databases and the sites stay as they are.'),
      ].join('\n\n'),
      button: tr('Delete'),
      danger: true)) {
    return;
  }
  final undo = app.removeProject(pr);
  app.notify(tr('Project "{name}" deleted', {'name': pr.name}), action: (tr('Undo'), undo));
}

/// "Delete…" of a target (its page, its settings, the side panel): asks, deletes it from this app, offers "Undo".
Future<void> askRemoveTarget(BuildContext context, AppState app, Project pr, Target t) async {
  if (app.busy) return;
  if (!await confirm(
      context,
      tr('Delete the target "{name}"?', {'name': t.name}),
      [
        tr('Its settings, its last checks and its history are deleted from this app.'),
        tr('Nothing is touched on the server: the site and its database stay as they are.'),
        if (t.agentName.isNotEmpty) tr('Delete the agent ({file}) from the server if you no longer use it.', {'file': t.agentName}),
      ].join('\n\n'),
      button: tr('Delete'),
      danger: true)) {
    return;
  }
  final undo = app.removeTarget(pr, t);
  app.notify(tr('Target "{name}" deleted', {'name': t.name}), action: (tr('Undo'), undo));
}

/// "Deploy" when the simulation finds nothing new on this PC: said plainly, nothing is sent.
Future<void> showUpToDate(BuildContext context, Target t, Report r) => showSheet<void>(
      context,
      title: tr('"{name}" is already up to date', {'name': t.name}),
      body: (ctx, _) {
        final ty = Ty.of(ctx);
        Widget line(String text) => Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.check_circle_outline, size: 17, color: ty.p.added),
                const SizedBox(width: 8),
                Expanded(child: Text(text)),
              ]),
            );
        return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(tr('Nothing to deploy: the target already has the last version of this PC.')),
          const SizedBox(height: 8),
          line(tr('Files: the same {n} files.', {'n': r.total})),
          if (r.dbOk) ...[
            line(tr('Structure: no migration to run.')),
            line(r.sync.isEmpty ? tr('Data: no synced tables in this project.') : tr('Data: the synced tables are the same.')),
          ] else
            line(tr('Database: not compared (no database on the target).')),
          const SizedBox(height: 14),
          Text(tr('Nothing was sent and nothing was changed on the target.'), style: ty.small),
        ]);
      },
      actions: (ctx, _) => [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('OK')))],
    );

/// A table worth a choice at a deployment, and why: [hint] says what differs ('' when nothing does).
class TableCandidate {
  const TableCandidate(this.table, this.hint, {this.differs = false, this.noKey = false, this.sync, this.more = 0});
  final String table, hint;
  final bool differs;
  final bool noKey; // its rows cannot be recognised on the target: its data cannot be sent (its structure can)
  final SyncResult? sync; // what the simulation found for its rows (its data is in the list)
  final int more; // rows more here than on the target (all of them when the table is not there)
}

/// The rows of a table in "Deploy" (asked 18/11/2026: "how many données manquantes"): what the simulation would do —
/// missing rows to add, rows to update, rows left out (why: in the tooltip), the same — or, when its data is not
/// sent, how many more rows this PC has.
List<(String, Color)> tableRowsLine(TableCandidate c, Palette p, {bool dataTicked = false}) {
  if (c.noKey) return []; // its data never goes: the hint says why (18/11/2026: "85 left out" in red read as rows thrown away)
  final s = c.sync;
  if (s == null) {   // not simulated: its data was not in the list (ticked now: counted by the next simulation)
    if (c.more <= 0) return [];
    return [
      dataTicked
          ? (pl(c.more, '{n} more row here', '{n} more rows here', '{n} ligne de plus ici', '{n} lignes de plus ici'), p.faint)
          : (pl(c.more, '{n} more row here, data not sent', '{n} more rows here, data not sent', '{n} ligne de plus ici, données non envoyées', '{n} lignes de plus ici, données non envoyées'), p.faint),
    ];
  }
  final add = s.added + s.pending;
  return [
    if (add > 0) (pl(add, '{n} missing on the target, to add', '{n} missing on the target, to add', '{n} manquante sur la cible, à ajouter', '{n} manquantes sur la cible, à ajouter'), p.added),
    if (s.updated > 0) (pl(s.updated, '{n} to update', '{n} to update', '{n} à mettre à jour', '{n} à mettre à jour'), p.changed),
    if (s.unlinked > 0) (pl(s.unlinked, '{n} without one of its links', '{n} without one of their links', '{n} sans un de ses liens', '{n} sans un de leurs liens'), p.changed),
    if (s.skipped > 0) (pl(s.skipped, '{n} left out', '{n} left out', '{n} écartée', '{n} écartées'), p.removed),
    if (s.same > 0) (pl(s.same, '{n} already the same', '{n} already the same', '{n} déjà identique', '{n} déjà identiques'), p.faint),
    if (add + s.updated + s.skipped == 0 && s.same == 0) (tr('nothing to send'), p.faint),
  ];
}

/// [tableRowsLine] coloured; hovering it shows why rows are left out or written without a link (the report has them all).
Widget? _rowsText(TableCandidate c, Ty ty, bool dataTicked) {
  final parts = tableRowsLine(c, ty.p, dataTicked: dataTicked);
  if (parts.isEmpty) return null;
  final text = Text.rich(
    key: ValueKey('deploy-rows-${c.table}'),
    TextSpan(children: [
      for (final (i, (txt, color)) in parts.indexed) ...[
        if (i > 0) TextSpan(text: ' · ', style: TextStyle(color: ty.p.faint)),
        TextSpan(text: txt, style: TextStyle(color: color, fontWeight: color == ty.p.faint ? null : FontWeight.w600)),
      ],
    ]),
    style: ty.small,
  );
  final why = [
    for (final (k, txt) in c.sync?.details ?? const <(String, String)>[])
      if (k == 'skip' || k == 'unlink') '${k == 'skip' ? '×' : '○'} $txt',
  ];
  return why.isEmpty ? text : Tooltip(message: why.take(8).join('\n'), child: text);
}

/// The tables shown by "Deploy" (asked 18/11/2026: "each time I deploy, the structure of a changed table only, or its
/// data too"): those of the project's list, those whose structure differs on the target, those with more rows on this
/// PC — logs and sessions (the "Counted only" patterns of the project) left out unless they are in the list. The ones
/// that differ first.
List<TableCandidate> tableCandidates(Project pr, Report r) {
  if (!r.dbOk) return const [];
  final listed = {for (final s in pr.sync) s.table};
  final skip = Patterns(pr.compareCountOnly);
  final structure = <String, String>{};
  if (r.localStructure != null && r.targetStructure != null) {
    for (final c in compareStructures(r.localStructure!, r.targetStructure!)) {
      if (c.state == Diff.missing) structure[c.table] = tr('not on the target');
      if (c.state == Diff.differs) structure[c.table] = tr('structure differs');
    }
  }
  final more = <String, String>{};
  final moreRows = <String, int>{};
  for (final MapEntry(key: t, value: here) in r.localCounts.entries) {
    final there = r.targetCounts[t];
    if (here > 0 && (there == null || here > there)) {
      moreRows[t] = here - (there ?? 0);
      more[t] = there == null
          ? pl(here, '{n} row here', '{n} rows here', '{n} ligne ici', '{n} lignes ici')
          : tr('{here} rows here, {there} on the target', {'here': fmtInt(here), 'there': fmtInt(there)});
    }
  }
  final names = {...listed, ...structure.keys, ...more.keys}.where((t) => t != '_deploy_migrations' && (listed.contains(t) || !skip.matches(t))).toList();
  bool noKey(String t) => r.localNoKey.contains(t) && (pr.sync.where((s) => s.table == t).firstOrNull?.key.isEmpty ?? true);
  // why (18/11/2026, "but it has a primary key"): that key is a counter, numbered apart on each database
  String noKeyWhy(String t) {
    final cols = r.localStructure?[t];
    if (cols == null) return tr('no key shared with the target: data cannot be sent');
    final pk = [for (final MapEntry(key: n, value: c) in cols.entries) if ('${c['key']}' == 'PRI') n];
    if (pk.isEmpty) return tr('no primary key and no unique index: data cannot be sent');
    final counter = cols.values.any((c) => '${c['key']}' == 'PRI' && '${c['extra'] ?? ''}'.contains('auto_increment'));
    return counter
        ? tr('primary key "{col}" is only a counter (other numbers on the target): data cannot be sent', {'col': pk.join(', ')})
        : tr('no key shared with the target: data cannot be sent');
  }

  final synced = {for (final s in r.sync) s.table: s};
  final out = [
    for (final t in names)
      TableCandidate(t, [?structure[t], ?more[t], if (noKey(t)) noKeyWhy(t)].join(' · '),
          differs: structure.containsKey(t) || more.containsKey(t), noKey: noKey(t), sync: synced[t], more: moreRows[t] ?? 0),
  ];
  out.sort((a, b) => a.differs != b.differs ? (a.differs ? -1 : 1) : a.table.compareTo(b.table));
  return out;
}

/// The tables of the project's list whose data is ticked but can never go (no key shared with the target, none set in
/// the project): their data is taken out of the list — "Data" ticked next to "data cannot be sent" made no sense
/// (18/11/2026, "wtf???"). Their structure stays as it was. Returns their names.
List<String> dropNoKeyData(Project pr, Report r) {
  final out = [for (final s in pr.sync) if (s.data && s.key.isEmpty && r.localNoKey.contains(s.table)) s.table];
  if (out.isNotEmpty) {
    applyTableChoice(pr, {for (final s in pr.sync) if (out.contains(s.table)) s.table: (structure: s.structure, data: false)});
  }
  return out;
}

/// What "Deploy" gives back: the parts, and the whole choice of tables when it changed — then the package is made
/// again (a new simulation) before deploying.
class DeployChoice {
  const DeployChoice(this.parts, {this.tables});
  final DeployParts parts;
  final Map<String, ({bool structure, bool data})>? tables;
}

/// The project's list after the choice of a deployment: a table ticked is added or changed, a table with nothing
/// ticked leaves the list unless it has options of its own (key, filter, columns).
void applyTableChoice(Project pr, Map<String, ({bool structure, bool data})> choice) {
  for (final MapEntry(key: t, value: c) in choice.entries) {
    final i = pr.sync.indexWhere((s) => s.table == t);
    if (i < 0) {
      if (c.structure || c.data) pr.sync.add(SyncTable(table: t, structure: c.structure, data: c.data));
      continue;
    }
    final s = pr.sync[i]
      ..structure = c.structure
      ..data = c.data;
    if (!c.structure && !c.data && s.key.isEmpty && s.where.trim().isEmpty && s.ignore.isEmpty && s.links.isEmpty) pr.sync.removeAt(i);
  }
}

/// The summary of a deployment, with what to send: the files, the structure (migrations and chosen tables), the data
/// (chosen tables), and for each table worth it, its structure and/or its data. Null: cancelled.
/// [gitBranch]: the GitHub branch of the project ('' when it is not linked).
Future<DeployChoice?> confirmDeploy(BuildContext context, Target t, Report r, {String gitBranch = '', Project? project}) {
  final canStructure = r.dbOk, canData = r.dbOk && r.sync.isNotEmpty, canGit = gitBranch.isNotEmpty;
  var files = true, structure = true, data = true, github = canGit;
  final candidates = project == null ? const <TableCandidate>[] : tableCandidates(project, r);
  final noKeys = {for (final c in candidates) if (c.noKey) c.table};
  ({bool structure, bool data}) current(String table) {
    final s = project!.sync.where((x) => x.table == table).firstOrNull;
    return (structure: s?.structure ?? false, data: !noKeys.contains(table) && (s?.data ?? false)); // no key: its data never goes
  }

  final initial = {for (final c in candidates) c.table: current(c.table)};
  final choice = {...initial};
  bool tablesChanged() => choice.entries.any((e) => initial[e.key] != e.value);
  bool chosen() => files || (canStructure && structure) || (canData && data);
  return showSheet<DeployChoice>(
    context,
    width: candidates.isEmpty ? 500 : 680,
    title: tr('Deploy to "{name}"?', {'name': t.name}),
    body: (ctx, set) {
      final ty = Ty.of(ctx);
      final waiting = r.sync.where((s) => s.tableMissing).length;
      Widget warn(String text) => Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.warning_amber_rounded, size: 17, color: ty.p.changed),
              const SizedBox(width: 8),
              Expanded(child: Text(text, style: ty.small.copyWith(color: ty.p.ink))),
            ]),
          );
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('What to deploy:'), style: ty.label),
        const SizedBox(height: 6),
        CheckLine(
          tr('Files'),
          key: const ValueKey('part-files'),
          value: files,
          onChanged: (v) => set(() => files = v),
          help: tr('{new} new, {changed} changed, {removed} removed.', {'new': r.newFiles.length, 'changed': r.changedFiles.length, 'removed': r.removedFiles.length}),
        ),
        CheckLine(
          tr('Structure (migrations)'),
          key: const ValueKey('part-structure'),
          value: canStructure && structure,
          enabled: canStructure,
          onChanged: (v) => set(() => structure = v),
          help: !canStructure
              ? tr('No database on the target.')
              : (r.migrations.isEmpty && r.tableChanges == 0
                  ? tr('Database structure: unchanged.')
                  : [
                      if (r.migrations.isNotEmpty) tr('Migrations: {n} to run.', {'n': r.migrations.length}),
                      if (r.tableChanges > 0)
                        tr('Tables: {n} change(s) in {t} table(s), nothing removed.', {'n': r.tableChanges, 't': r.tables.where((x) => x.changes.isNotEmpty).length}),
                    ].join(' ')),
        ),
        CheckLine(
          tr('Data (synced tables)'),
          key: const ValueKey('part-data'),
          value: canData && data,
          enabled: canData,
          onChanged: (v) => set(() => data = v),
          help: !r.dbOk
              ? tr('No database on the target.')
              : (r.sync.isEmpty
                  ? tr('No synced tables in this project.')
                  : tr('Synced tables: +{add} added, {upd} updated, nothing deleted.', {'add': r.rowsAdded, 'upd': r.rowsUpdated})),
        ),
        if (canGit)
        CheckLine(
          'GitHub',
          key: const ValueKey('part-github'),
          value: canGit && github,
          enabled: canGit,
          onChanged: (v) => set(() => github = v),
          help: canGit
              ? tr('After the deployment, commit the code and send it to the branch "{branch}".', {'branch': gitBranch})
              : tr('Link the project to GitHub in its settings to send the code with each deployment.'),
        ),
        if (files && canStructure && !structure && r.migrations.isNotEmpty)
          warn(tr('The new files may need the {n} migration(s): deploy the structure with them, or before them.', {'n': r.migrations.length})),
        if (canData && data && canStructure && !structure && r.tableChanges > 0)
          warn(tr('The data of the chosen tables may need their new structure: deploy the structure with them.')),
        if (canData && data && canStructure && !structure && waiting > 0)
          warn(tr('{n} synced table(s) only exist after the migrations: their rows wait until the structure is deployed.', {'n': waiting})),
        if (candidates.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(tr('Tables'), style: ty.label),
          Text(tr('For each table: its structure only (columns, indexes), or its data too (rows added or updated, never deleted). Kept for the next deployments.'),
              style: ty.small),
          const SizedBox(height: 6),
          Container(
            constraints: const BoxConstraints(maxHeight: 260),
            decoration: BoxDecoration(border: Border.all(color: ty.p.rule), borderRadius: BorderRadius.circular(8)),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), children: [
              for (final c in candidates)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(c.table, style: ty.mono(size: 13, weight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                        if (c.hint.isNotEmpty) Text(c.hint, style: ty.small.copyWith(color: c.differs ? ty.p.changed : null)),
                        ?_rowsText(c, ty, choice[c.table]!.data),
                      ]),
                    ),
                    SizedBox(
                      width: 118,
                      child: CheckLine(tr('Structure'), key: ValueKey('deploy-structure-${c.table}'), value: choice[c.table]!.structure, onChanged: (v) {
                        set(() => choice[c.table] = (structure: v, data: choice[c.table]!.data));
                      }),
                    ),
                    SizedBox(
                      width: 118,
                      // a table without a key: its data never goes, "Data" stays unticked
                      child: CheckLine(tr('Data'), key: ValueKey('deploy-data-${c.table}'), value: !c.noKey && choice[c.table]!.data,
                          enabled: !c.noKey, onChanged: (v) {
                        set(() => choice[c.table] = (structure: choice[c.table]!.structure, data: v));
                      }),
                    ),
                  ]),
                ),
            ]),
          ),
          if (tablesChanged())
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(tr('The choice of tables changed: the app simulates again with it, then asks again.'), style: ty.small.copyWith(color: ty.p.accent)),
            )
          else if (r.upToDate)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(tr('Nothing new with this choice: tick tables, or cancel.'), style: ty.small.copyWith(color: ty.p.changed)),
            ),
        ],
        const SizedBox(height: 14),
        Text(files ? tr('First: backup of the target database and files.') : tr('First: backup of the target database.'), style: ty.small),
        Text(tr('Everything else on the target (its data, uploads, kept files) stays as it is.'), style: ty.small),
      ]);
    },
    actions: (ctx, set) => [
      TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancel'))),
      FilledButton(
        key: const ValueKey('confirm-deploy'),
        // a part that cannot be deployed (no database, no synced table) stays "chosen": there is nothing to do for it
        onPressed: tablesChanged()
            ? () => Navigator.pop(ctx, DeployChoice(const DeployParts(), tables: {...choice}))
            : (chosen() && !r.upToDate
                ? () => Navigator.pop(
                    ctx, DeployChoice(DeployParts(files: files, structure: !canStructure || structure, data: !canData || data, github: canGit && github)))
                : null),
        child: Text(tablesChanged() ? tr('Simulate with this choice') : tr('Deploy')),
      ),
    ],
  );
}

/// "Send to GitHub": what changed, a message, the branch. Null: cancelled; else the message of the commit.
Future<String?> confirmGitSend(BuildContext context, GitState s, String branch) {
  String two(int n) => n.toString().padLeft(2, '0');
  final d = DateTime.now();
  final message = TextEditingController(text: tr('Update of {date}', {'date': '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}'}));
  final risky = s.changes.where((c) => c.sensitive && c.code != 'D').toList();
  return showSheet<String>(
    context,
    title: tr('Send to GitHub?'),
    width: 600,
    body: (ctx, set) {
      final ty = Ty.of(ctx);
      Color colorOf(String code) => switch (code) { 'D' => ty.p.removed, 'M' || 'R' => ty.p.changed, _ => ty.p.added };
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text.rich(TextSpan(children: [
          TextSpan(text: '${tr('Branch')} '),
          TextSpan(text: branch, style: ty.mono(weight: FontWeight.w700)),
          TextSpan(text: '  ·  ${s.remote}', style: ty.small),
        ])),
        const SizedBox(height: 12),
        if (s.changes.isEmpty)
          Text(tr('No change since the last commit: the last commit is sent.'), style: ty.small)
        else ...[
          Text(tr('{n} changed file(s):', {'n': s.changes.length}), style: ty.label),
          const SizedBox(height: 6),
          Container(
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(color: ty.p.sunken, borderRadius: BorderRadius.circular(8), border: Border.all(color: ty.p.rule)),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final c in s.changes.take(300))
                  Row(children: [
                    SizedBox(width: 20, child: Text(c.code == '?' ? 'A' : c.code, style: ty.mono(size: 12, weight: FontWeight.w700, color: colorOf(c.code)))),
                    Expanded(child: Text(c.path, style: ty.mono(size: 12, color: c.sensitive ? ty.p.removed : null), overflow: TextOverflow.ellipsis)),
                  ]),
                if (s.changes.length > 300) Text('… ${s.changes.length - 300}', style: ty.small),
              ]),
            ),
          ),
        ],
        if (risky.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.warning_amber_rounded, size: 17, color: ty.p.removed),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    tr('These files look like passwords or data: {list}. If they must stay on this PC, add them to the .gitignore of the project before sending.',
                        {'list': risky.take(6).map((c) => c.path).join(', ')}),
                    style: ty.small.copyWith(color: ty.p.ink)),
              ),
            ]),
          ),
        const SizedBox(height: 14),
        Field(tr('Message'), message),
      ]);
    },
    actions: (ctx, _) => [
      TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancel'))),
      FilledButton(
        key: const ValueKey('git-send'),
        onPressed: () => Navigator.pop(ctx, message.text.trim().isEmpty ? tr('Update') : message.text.trim()),
        child: Text(tr('Send')),
      ),
    ],
  );
}

class SourceChoice {
  SourceChoice(this.source);
  final DbSource? source; // null: files only
}

Future<SourceChoice?> chooseSource(BuildContext context, Project pr, Target t, {required bool install}) {
  final others = pr.targets.where((x) => x.id != t.id).toList();
  var choice = pr.localDb.isSet ? 'local' : (install ? 'none' : (others.isEmpty ? 'local' : 'target'));
  Target? other = others.firstOrNull;
  return showSheet<SourceChoice>(
    context,
    title: install ? tr('Install on "{name}"', {'name': t.name}) : tr('Replace the database of "{name}"', {'name': t.name}),
    body: (ctx, set) {
      final ty = Ty.of(ctx);
      final help = switch (choice) {
        'none' => tr('Files only (the target already has its database, or none is needed).'),
        'local' => pr.localDb.isSet ? '"${pr.localDb.name}" — ${tr('as it is now on this PC.')}' : tr('Set the local database in the project settings first.'),
        _ => others.isEmpty ? tr('No other target in this project.') : tr('Its agent backs it up, the app downloads it and sends it.'),
      };
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(install ? tr('All the project files are sent. Database:') : tr('The target database becomes a FULL COPY of:')),
        const SizedBox(height: 12),
        Choice<String>(
          null,
          value: choice,
          items: [
            if (install) ('none', tr('No database'), true),
            ('local', tr('Copy of the local database'), pr.localDb.isSet),
            ('target', tr('Copy of another target\'s database'), others.isNotEmpty),
          ],
          onChanged: (v) => set(() => choice = v),
        ),
        if (choice == 'target' && others.isNotEmpty) ...[
          const SizedBox(height: 8),
          Choice<Target>(null, value: other ?? others.first, items: [for (final o in others) (o, '${o.name} — ${o.baseUrl}', true)], onChanged: (v) => set(() => other = v)),
        ],
        const SizedBox(height: 8),
        Text(help, style: ty.small),
      ]);
    },
    actions: (ctx, _) => [
      TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancel'))),
      FilledButton(
        onPressed: () => Navigator.pop(
            ctx,
            SourceChoice(switch (choice) {
              'local' => const DbSource.local(),
              'target' when other != null => DbSource.target(other!),
              _ => null,
            })),
        child: Text(choice == 'none' ? tr('Install') : tr('Preview')),
      ),
    ],
  );
}

/// Before / after for the target database; when it already has tables, typing the target name is required.
Future<bool> confirmDb(BuildContext context, Target t, DbSource src, DbSummary? before, DbSummary after, {required bool install}) async {
  final overwrite = before != null && before.tables > 0;
  final typed = TextEditingController();
  final names = <String>{...after.top.map((x) => x.$1), ...?before?.top.map((x) => x.$1)}.take(12).toList();
  final ok = await showSheet<bool>(
    context,
    width: 580,
    title: install ? tr('Install on "{name}"?', {'name': t.name}) : tr('Replace the database of "{name}"?', {'name': t.name}),
    body: (ctx, set) {
      final ty = Ty.of(ctx);
      final p = ty.p;
      Widget cell(String s, {bool head = false, Color? color, TextAlign align = TextAlign.right, bool monospace = false, bool bold = false}) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Text(head ? s.toUpperCase() : s,
                textAlign: align,
                overflow: TextOverflow.ellipsis,
                style: head ? ty.caps() : (monospace ? ty.mono(color: color) : ty.figure(color: color, weight: bold ? FontWeight.w600 : FontWeight.w400))),
          );
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('The target database becomes a full copy of {source}:', {'source': src.label})),
        const SizedBox(height: 12),
        Table(
          columnWidths: const {0: FlexColumnWidth(1.6), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1)},
          border: TableBorder(horizontalInside: BorderSide(color: p.rule), top: BorderSide(color: p.strong), bottom: BorderSide(color: p.rule)),
          children: [
            TableRow(children: [cell(tr('Table'), head: true, align: TextAlign.left), cell(tr('Target today'), head: true), cell(tr('After'), head: true)]),
            TableRow(children: [cell(tr('Tables'), align: TextAlign.left), cell(before == null ? '—' : fmtInt(before.tables)), cell(fmtInt(after.tables), bold: true)]),
            for (final n in names)
              TableRow(children: [
                cell(n, align: TextAlign.left, monospace: true),
                cell(before == null ? '—' : fmtInt(before.rowsOf(n)), color: p.muted),
                cell(fmtInt(after.rowsOf(n)),
                    bold: true, color: before == null || after.rowsOf(n) == before.rowsOf(n) ? null : (after.rowsOf(n) < before.rowsOf(n) ? p.removed : p.added)),
              ]),
          ],
        ),
        const SizedBox(height: 14),
        if (overwrite) ...[
          Container(
            decoration: BoxDecoration(color: p.removed.withValues(alpha: .07), border: Border(left: BorderSide(color: p.removed, width: 3))),
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
            child: Text(tr('Everything in the database of "{name}" today is replaced (red rows go down). It is backed up first on the target: Restore puts it back.', {'name': t.name})),
          ),
          const SizedBox(height: 14),
          Text(tr('To confirm, type the target name: {name}', {'name': t.name}), style: ty.label),
          const SizedBox(height: 6),
          TextField(controller: typed, autofocus: true, onChanged: (_) => set(() {}), style: ty.mono(size: 13)),
        ] else
          Text(tr('The target database is empty: nothing is overwritten.'), style: ty.small),
      ]);
    },
    actions: (ctx, _) {
      final ready = !overwrite || typed.text.trim() == t.name;
      final label = install ? tr('Install') : tr('Replace the database');
      return [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel'))),
        if (overwrite) _danger(ctx, label, ready ? () => Navigator.pop(ctx, true) : null) else FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(label)),
      ];
    },
  );
  typed.dispose();
  return ok ?? false;
}

Future<(String?, String?)?> chooseBackup(BuildContext context, Target t, List<Map<String, dynamic>> files) {
  final dbs = files.where((f) => '${f['name']}'.startsWith('db-')).toList();
  final codes = files.where((f) => '${f['name']}'.startsWith('files-')).toList();
  String label(Map<String, dynamic> f) => '${f['date']}   ${((f['size'] as num) / 1048576).toStringAsFixed(1)} MB';
  String? db = dbs.firstOrNull?['name'] as String?;
  String? code = codes.firstOrNull?['name'] as String?;
  return showSheet<(String?, String?)>(
    context,
    title: tr('Restore "{name}"', {'name': t.name}),
    body: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (dbs.isEmpty && codes.isEmpty) Text(tr('No backup on the target yet.')),
      if (dbs.isNotEmpty)
        Choice<String?>(tr('Database'),
            value: db,
            items: [(null, tr('Leave the database as it is'), true), for (final f in dbs) (f['name'] as String, label(f), true)],
            onChanged: (v) => set(() => db = v)),
      const SizedBox(height: 14),
      if (codes.isNotEmpty)
        Choice<String?>(tr('Files'),
            value: code,
            items: [(null, tr('Leave the files as they are'), true), for (final f in codes) (f['name'] as String, label(f), true)],
            onChanged: (v) => set(() => code = v)),
      const SizedBox(height: 14),
      Text(tr('The chosen database fully replaces the target\'s: what was entered since is lost.'), style: Ty.of(ctx).small.copyWith(color: Palette.of(ctx).removed)),
    ]),
    actions: (ctx, _) => [
      TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancel'))),
      FilledButton(onPressed: db == null && code == null ? null : () => Navigator.pop(ctx, (db, code)), child: Text(tr('Restore'))),
    ],
  );
}

Future<List<String>?> pickTables(BuildContext context, List<String> all, Set<String> already) {
  final chosen = <String>{};
  var filter = '';
  return showSheet<List<String>>(
    context,
    title: tr('Tables to sync'),
    body: (ctx, set) {
      final ty = Ty.of(ctx);
      final shown = all.where((t) => !already.contains(t) && t.toLowerCase().contains(filter.toLowerCase())).toList();
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          autofocus: true,
          decoration: InputDecoration(hintText: tr('Filter'), prefixIcon: const Icon(Icons.search, size: 18)),
          onChanged: (v) => set(() => filter = v),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 380,
          child: ListView(children: [
            for (final t in shown)
              CheckLine(t, value: chosen.contains(t), onChanged: (v) => set(() => v ? chosen.add(t) : chosen.remove(t))),
          ]),
        ),
        Text(tr('{n} selected', {'n': chosen.length}), style: ty.small),
      ]);
    },
    actions: (ctx, _) => [
      TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancel'))),
      FilledButton(onPressed: chosen.isEmpty ? null : () => Navigator.pop(ctx, chosen.toList()..sort()), child: Text(tr('Add {n}', {'n': chosen.length}))),
    ],
  );
}

class CloneChoice {
  CloneChoice(this.folder, this.url, this.db, {this.withDb = true, this.replace = false});
  final String folder, url;
  final DbSettings db;
  final bool withDb, replace;
}

/// Where the clone goes on this PC: a folder (served by the local web server), its address, its database. What is
/// already there is replaced only after a confirmation; the project's own folder and database are refused.
Future<CloneChoice?> chooseClone(BuildContext context, AppState app, Project pr, Target t) async {
  final base = (pr.folder.isEmpty ? r'C:\xampp\htdocs\site' : pr.folder).replaceAll(RegExp(r'[\\/]+$'), '');
  var folder = '${base}_clone';
  for (var i = 2; Directory(folder).existsSync() && Directory(folder).listSync().isNotEmpty; i++) {
    folder = '${base}_clone$i';
  }
  final slug = (pr.localDb.name.isNotEmpty ? pr.localDb.name : p.basename(base)).toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]+'), '_');
  final fc = TextEditingController(text: folder);
  final uc = TextEditingController(text: localUrlFor(folder));
  final dc = TextEditingController(text: '${slug}_clone');
  var urlEdited = false, withDb = true;
  String? problem;
  final local = DbSettings(host: pr.localDb.host, port: pr.localDb.port, user: pr.localDb.user, pass: pr.localDb.pass);
  final ok = await showSheet<bool>(
    context,
    width: 600,
    title: tr('Clone "{name}" to this PC', {'name': t.name}),
    body: (ctx, set) {
      final ty = Ty.of(ctx);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('A copy of the site to work on: all its files (uploads and settings too) and its database. You try your changes on the copy; production stays as it is.')),
        Notice(
          color: ty.p.added,
          icon: Icons.shield_outlined,
          title: tr('Production is only read'),
          text: tr('One backup is made on "{name}", downloaded, then removed from it. Nothing else happens there.', {'name': t.name}),
        ),
        const SizedBox(height: 16),
        Field(tr('Folder on this PC'), fc,
            monospace: true,
            onChanged: (v) => set(() {
                  if (!urlEdited) uc.text = localUrlFor(v);
                }),
            suffix: fieldButton(Icons.folder_open_outlined, tr('Browse'), () async {
              final d = await pickFolder(initial: fc.text.trim(), title: tr('Folder of the clone'));
              if (d != null) {
                set(() {
                  fc.text = d;
                  if (!urlEdited) uc.text = localUrlFor(d);
                });
              }
            })),
        const SizedBox(height: 14),
        Field(tr('Its address on this PC'), uc, monospace: true, placeholder: 'http://localhost/site_clone', onChanged: (_) => urlEdited = true,
            help: tr('The folder must be served by the web server of this PC (XAMPP, Laragon…).')),
        const SizedBox(height: 14),
        CheckLine(tr('Copy the database too'), value: withDb, onChanged: (v) => set(() => withDb = v)),
        if (withDb) ...[
          const SizedBox(height: 8),
          Field(tr('Database of the clone on this PC'), dc, monospace: true,
              help: tr('On {host} as {user}, like the local database of the project. Created when missing.', {'host': local.host, 'user': local.user.isEmpty ? 'root' : local.user})),
        ],
        if (problem != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(problem!, style: ty.body.copyWith(color: ty.p.removed))),
      ]);
    },
    actions: (ctx, set) => [
      TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel'))),
      FilledButton(
        onPressed: () {
          final f = fc.text.trim(), u = uc.text.trim(), d = dc.text.trim();
          final inside = pr.folder.isNotEmpty && (p.equals(f, pr.folder) || p.isWithin(pr.folder, f));
          set(() => problem = f.isEmpty || !p.isAbsolute(f)
              ? tr('Choose a folder on this PC.')
              : inside
                  ? tr('Not the folder of the project: choose another one.')
                  : !RegExp(r'^https?://[^/\s]+').hasMatch(u)
                      ? tr('The address must start with http:// or https://.')
                      : withDb && !RegExp(r'^[A-Za-z0-9_$-]{1,64}$').hasMatch(d)
                          ? tr('Database name: letters, digits, _ only.')
                          : withDb && d.toLowerCase() == pr.localDb.name.toLowerCase()
                              ? tr('Not the local database of the project: choose another name.')
                              : null);
          if (problem == null) Navigator.pop(ctx, true);
        },
        child: Text(tr('Clone')),
      ),
    ],
  );
  if (ok != true || !context.mounted) return null;
  final f = fc.text.trim();
  final db = DbSettings(host: local.host, port: local.port, name: dc.text.trim(), user: local.user, pass: local.pass);
  final dir = Directory(f);
  final busyFolder = dir.existsSync() && dir.listSync().isNotEmpty;
  final tables = withDb ? await Local(app.settings).tableCount(db) ?? 0 : 0;
  var replace = false;
  if (busyFolder || tables > 0) {
    if (!context.mounted) return null;
    replace = await confirm(
        context,
        tr('Replace what is on this PC?'),
        [
          if (busyFolder) tr('The folder {path} is not empty: its content is deleted.', {'path': f}),
          if (tables > 0) tr('The database "{name}" of this PC has {n} tables: they are deleted.', {'name': db.name, 'n': tables}),
          tr('Both get the copy of "{name}". Production is not touched.', {'name': t.name}),
        ].join('\n\n'),
        button: tr('Replace'),
        danger: true);
    if (!replace) return null;
  }
  return CloneChoice(f, uc.text.trim(), db, withDb: withDb, replace: replace);
}
