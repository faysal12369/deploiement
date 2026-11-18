// A project: its targets, folder, file rules, migrations, local database and synced tables.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'dialogs.dart';
import 'git.dart';
import 'i18n.dart';
import 'local.dart';
import 'main.dart' show TargetRow;
import 'models.dart';
import 'pickers.dart';
import 'project_file.dart';
import 'sql_view.dart';
import 'theme.dart';
import 'widgets.dart';

class ProjectPage extends StatefulWidget {
  const ProjectPage(this.app, this.project, {super.key});
  final AppState app;
  final Project project;
  @override
  State<ProjectPage> createState() => _ProjectPageState();
}

class _ProjectPageState extends State<ProjectPage> {
  late Project p = widget.project.copy();
  late final c = <String, TextEditingController>{
    'name': TextEditingController(text: p.name),
    'folder': TextEditingController(text: p.folder),
    'exclude': TextEditingController(text: p.exclude.join('\n')),
    'keep': TextEditingController(text: p.keep.join('\n')),
    'migFolder': TextEditingController(text: p.migrationsFolder),
    'migSkip': TextEditingController(text: p.migrationsSkip),
    'dbHost': TextEditingController(text: p.localDb.host),
    'dbPort': TextEditingController(text: p.localDb.port),
    'dbName': TextEditingController(text: p.localDb.name),
    'dbUser': TextEditingController(text: p.localDb.user),
    'dbPass': TextEditingController(text: p.localDb.pass),
    'countOnly': TextEditingController(text: p.compareCountOnly.join('\n')),
    'keys': TextEditingController(text: p.compareKeys.join('\n')),
  };
  bool showPass = false;

  AppState get app => widget.app;

  // ---- every change is saved by itself: a moment later, on leaving the page, on closing the app
  Timer? _autoTimer;
  bool _dirty = false;
  final saved = ValueNotifier<bool?>(null); // the mark next to the title: null nothing changed, false saving, true saved
  final _texts = <String, String>{};

  @override
  void initState() {
    super.initState();
    for (final e in c.entries) {
      _texts[e.key] = e.value.text;
      e.value.addListener(() {
        if (_texts[e.key] == e.value.text) return; // only the cursor moved
        _texts[e.key] = e.value.text;
        _later();
      });
    }
    app.flushers.add(_flushQuietly);
  }

  void _later() {
    _dirty = true;
    saved.value = false;
    _autoTimer?.cancel();
    _autoTimer = Timer(const Duration(milliseconds: 700), _flush);
  }

  void _flush() {
    _autoTimer?.cancel();
    if (!_dirty || !mounted) return;
    _dirty = false;
    _apply();
    app.save();
    saved.value = true;
  }

  /// When leaving the page or closing the app: written to disk without redrawing anything.
  void _flushQuietly() {
    _autoTimer?.cancel();
    if (!_dirty) return;
    _dirty = false;
    _apply();
    app.persistQuietly();
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _later();
  }

  @override
  void dispose() {
    _flushQuietly();
    app.flushers.remove(_flushQuietly);
    saved.dispose();
    for (final x in c.values) {
      x.dispose();
    }
    super.dispose();
  }

  List<String> _lines(String k) => c[k]!.text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  DbSettings get _db => DbSettings(host: c['dbHost']!.text.trim(), port: c['dbPort']!.text.trim(), name: c['dbName']!.text.trim(), user: c['dbUser']!.text.trim(), pass: c['dbPass']!.text);

  /// What is on the screen into the project (an empty name keeps the previous one).
  void _apply() {
    final name = c['name']!.text.trim();
    widget.project
      ..name = name.isEmpty ? widget.project.name : name
      ..folder = c['folder']!.text.trim()
      ..exclude = _lines('exclude')
      ..keep = _lines('keep')
      ..migrationsFolder = c['migFolder']!.text.trim()
      ..migrationsSkip = c['migSkip']!.text.trim()
      ..rerunChangedMigrations = p.rerunChangedMigrations
      ..localDb = _db
      ..compareCountOnly = _lines('countOnly')
      ..compareKeys = _lines('keys')
      ..sync = [for (final s in p.sync) if (s.table.trim().isNotEmpty) s];
  }

  /// Before an export: what is on the screen, saved now.
  bool _save() {
    if (c['name']!.text.trim().isEmpty) {
      app.notify(tr('The project needs a name.'), severity: Severity.warning);
      return false;
    }
    _dirty = true;
    _flush();
    return true;
  }

  Future<void> _browse() async {
    final d = await pickFolder(initial: c['folder']!.text.trim());
    if (d == null) return;
    setState(() {
      c['folder']!.text = d;
      if (c['name']!.text.trim().isEmpty || c['name']!.text == tr('New project')) c['name']!.text = d.split(RegExp(r'[\\/]')).last;
      for (final m in ['database/migrations', 'migrations', 'sql/migrations', 'db/migrations']) {
        if (c['migFolder']!.text.isEmpty && Directory('$d/$m').existsSync()) c['migFolder']!.text = m;
      }
    });
  }

  Future<void> _testDb() async {
    try {
      final s = await Local(app.settings).summary(_db);
      app.notify(tr('Local database OK: {n} tables.', {'n': s['tables']}));
    } catch (e) {
      app.notify(tr('Error'), text: '$e', severity: Severity.error);
    }
  }

  Future<void> _addTables() async {
    try {
      final all = await Local(app.settings).tables(_db);
      if (!mounted) return;
      final chosen = await pickTables(context, all, p.sync.map((s) => s.table).toSet());
      // a new table: its structure only; "Data" is ticked by hand, for the tables whose rows go too
      if (chosen != null) setState(() => p.sync.addAll(chosen.map((t) => SyncTable(table: t, structure: true, data: false))));
    } catch (e) {
      app.notify(tr('Error'), text: '$e', severity: Severity.error);
    }
  }

  /// Saves what is on the screen, then writes the project to a file, without passwords nor keys.
  Future<void> _export() async {
    if (!_save()) return;
    final name = widget.project.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final loc = await pickSaveFile(name: '$name.deploy.json');
    if (loc == null) return;
    try {
      ProjectFile.write(widget.project, loc);
      app.notify(tr('Exported without passwords nor keys: {path}', {'path': loc}));
    } catch (e) {
      app.notify(tr('Error'), text: '$e', severity: Severity.error);
    }
  }

  Future<void> _remove() async {
    _flushQuietly(); // what was just typed goes with it, and comes back with "Undo"
    await askRemoveProject(context, app, widget.project);
  }

  void _addTarget() {
    final t = Target.create()
      ..name = tr('New target')
      ..url = 'https://';
    widget.project.targets.add(t);
    app.route = 't:${t.id}:settings';
    app.save();
  }

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    return PageFrame(
      kicker: tr('Project'),
      title: widget.project.name,
      subtitle: Text(widget.project.folder.isEmpty ? tr('No folder yet') : widget.project.folder, style: ty.mono(size: 13, color: ty.p.muted)),
      actions: [
        TextButton(onPressed: _export, child: Text(tr('Export…'))),
        OutlinedButton(onPressed: _addTarget, child: Text(tr('Add a target'))),
        IconButton(
          key: const ValueKey('project-delete'),
          tooltip: tr('Delete this project'),
          onPressed: app.busy ? null : _remove,
          icon: Icon(Icons.delete_outline, size: 20, color: ty.p.removed),
        ),
        AutoSaveMark(saved),
      ],
      children: [
        Section(
          tr('Targets'),
          meta: tr('Where this project is deployed: Hostinger, any hosting with PHP, a server by IP…'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.project.targets.isEmpty)
              Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Text(tr('No target yet.'), style: ty.small))
            else
              for (final t in widget.project.targets) TargetRow(app, t, showTransport: true),
          ]),
        ),
        Section(
          tr('Settings'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FormBlock(
              title: tr('Name and folder'),
              description: tr('The folder on this PC is the source of every deployment.'),
              child: FieldRow([
                Field(tr('Name'), c['name']!),
                Field(tr('Folder on this PC'), c['folder']!,
                    monospace: true,
                    placeholder: r'C:\xampp\htdocs\my-app',
                    suffix: fieldButton(Icons.folder_open_outlined, tr('Browse'), _browse)),
              ], widths: const [200, -1]),
            ),
            FormBlock(
              title: tr('Files'),
              description: tr('One pattern per line, like .gitignore: "vendor/" a folder, "*.log" by name, "/config/local.php" from the root.'),
              child: FieldRow([
                Field(tr('Never sent'), c['exclude']!, monospace: true, maxLines: 7, help: tr('Development files: .git/, node_modules/, tests/…')),
                Field(tr('Kept on the targets'), c['keep']!, monospace: true, maxLines: 7, help: tr('Never sent, never overwritten nor deleted on a target: .env, uploads/, storage/…')),
              ]),
            ),
            FormBlock(
              title: tr('Migrations'),
              description: tr('SQL files run in name order, once each, recorded in the `_deploy_migrations` table of the target.'),
              trailing: OutlinedButton(
                key: const ValueKey('new-migration'),
                onPressed: () => showSqlDialog(context, app, widget.project, migration: true),
                child: Text(tr('New SQL migration…')),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                FieldRow([
                  Field(tr('Folder (relative to the project)'), c['migFolder']!, monospace: true, placeholder: 'database/migrations', help: tr('Empty: no migrations.')),
                  Field(tr('Never run'), c['migSkip']!, monospace: true, placeholder: '*_rollback.sql'),
                ], widths: const [-1, 200]),
                const SizedBox(height: 10),
                CheckLine(
                  tr('Run a migration again when its file changes'),
                  value: p.rerunChangedMigrations,
                  onChanged: (v) => setState(() => p.rerunChangedMigrations = v),
                  help: tr('Only if your migrations can be replayed safely (CREATE TABLE IF NOT EXISTS, INSERT IGNORE…).'),
                ),
              ]),
            ),
            FormBlock(
              title: tr('Local database'),
              description: tr('Optional: its structure checks the targets, its synced tables are pushed, and it can be copied to a target.'),
              trailing: OutlinedButton(onPressed: _testDb, child: Text(tr('Test'))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                FieldRow([Field(tr('Host'), c['dbHost']!, monospace: true), Field(tr('Port'), c['dbPort']!, monospace: true)], widths: const [-1, 90]),
                const SizedBox(height: 14),
                FieldRow([
                  Field(tr('Database'), c['dbName']!, monospace: true, help: tr('Empty: no local database.')),
                  Field(tr('User'), c['dbUser']!, monospace: true),
                  Field(tr('Password'), c['dbPass']!, obscure: !showPass),
                ]),
                const SizedBox(height: 8),
                CheckLine(tr('Show passwords'), value: showPass, onChanged: (v) => setState(() => showPass = v)),
              ]),
            ),
            FormBlock(
              title: tr('Tables: structure and data'),
              description: tr('For each table of the local database: "Structure" makes the table of the target like this PC\'s at every deployment (created, columns and indexes added, columns changed — nothing removed, no SQL to write). "Data" also sends its rows: added or updated, never deleted, matched by a key (a unique index), never by their id.'),
              trailing: OutlinedButton(key: const ValueKey('add-tables'), onPressed: _addTables, child: Text(tr('Add tables…'))),
              child: p.sync.isEmpty
                  ? Text(tr('None.'), style: ty.small)
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (final (i, s) in p.sync.indexed) _SyncRow(s, key: ValueKey(s), onChanged: _later, onRemove: () => setState(() => p.sync.removeAt(i))),
                    ]),
            ),
            FormBlock(
              title: tr('Comparing databases'),
              description: tr('"Compare databases" finds the rows of this PC missing on a target, and the reverse. A row is recognised by its key (hf_ref, a unique index, a primary key that is not a counter), never by its id.'),
              child: FieldRow([
                Field(tr('Counted only'), c['countOnly']!, monospace: true, maxLines: 5, help: tr('Tables that always differ (logs, sessions…): one pattern per line, "*_log".')),
                Field(tr('Keys of tables'), c['keys']!, monospace: true, maxLines: 5, placeholder: 'orders: number', help: tr('For a table without a unique index: "table: column, column", one per line.')),
              ]),
            ),
            if (kGitHub) _GitBlock(app, widget.project, key: ValueKey('git-${widget.project.id}-${widget.project.folder}')),
            FormBlock(
              title: tr('Delete this project'),
              description: tr('Its settings and its targets are deleted from this app. Nothing is touched on this PC nor on the servers.'),
              child: Align(alignment: Alignment.centerLeft, child: DangerButton(tr('Delete this project…'), onPressed: app.busy ? null : _remove)),
            ),
          ]),
        ),
      ],
    );
  }
}

/// The GitHub block of the project page: the repository of the folder, the branch the code goes to, "Send to GitHub".
class _GitBlock extends StatefulWidget {
  const _GitBlock(this.app, this.project, {super.key});
  final AppState app;
  final Project project;
  @override
  State<_GitBlock> createState() => _GitBlockState();
}

class _GitBlockState extends State<_GitBlock> {
  GitState? s;
  late final remote = TextEditingController(text: widget.project.gitRemote);
  late final branch = TextEditingController(text: widget.project.gitBranch);
  Timer? _branchTimer;
  bool working = false;

  Project get pr => widget.project;
  Git get git => Git(pr.folder);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    if (_branchTimer?.isActive ?? false) {
      _branchTimer!.cancel();
      widget.app.persistQuietly();
    }
    remote.dispose();
    branch.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final x = await git.state();
    if (!mounted) return;
    setState(() {
      s = x;
      // the repository of the folder is the truth; the branch of this PC is the default branch to send to
      if (x.remote.isNotEmpty && x.remote != pr.gitRemote) {
        pr.gitRemote = x.remote;
        remote.text = x.remote;
        widget.app.persistQuietly();
      }
      if (branch.text.trim().isEmpty && x.branch.isNotEmpty) branch.text = x.branch;
      if (pr.gitBranch.isEmpty && branch.text.trim().isNotEmpty) pr.gitBranch = branch.text.trim();
    });
  }

  Future<void> _do(Future<void> Function() f, String done) async {
    setState(() => working = true);
    try {
      await f();
      widget.app.save();
      widget.app.notify(done);
    } catch (e) {
      widget.app.notify(tr('Error'), text: '$e'.replaceFirst('AgentError: ', ''), severity: Severity.error);
    } finally {
      if (mounted) setState(() => working = false);
      await _load();
    }
  }

  Future<void> _send() async {
    pr.gitBranch = branch.text.trim();
    final st = await git.state();
    if (!mounted) return;
    final message = await confirmGitSend(context, st, pr.gitBranch);
    if (message == null) return;
    final id = await widget.app.run(null, (o) => o.gitSend(pr, message));
    if (id != null) widget.app.notify(tr('Sent to GitHub: commit {id} on "{branch}".', {'id': id, 'branch': pr.gitBranch}));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    final x = s;
    Widget body;
    if (x == null) {
      body = Text(tr('Looking at the folder…'), style: ty.small);
    } else if (!x.installed) {
      body = Text(tr('Git is not installed on this PC: install Git for Windows (git-scm.com), then come back here.'), style: ty.small);
    } else if (pr.folder.trim().isEmpty) {
      body = Text(tr('Choose the folder of the project first.'), style: ty.small);
    } else if (!x.repo) {
      body = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Text(tr('This folder is not a Git repository yet. Creating it also writes a .gitignore with the files never sent and the files kept on the targets (.env, passwords, uploads…), so they never go to GitHub.'),
              style: ty.small),
        ),
        const SizedBox(width: 12),
        OutlinedButton(
          key: const ValueKey('git-create'),
          onPressed: working ? null : () => _do(() => git.create(branch: branch.text.trim().isEmpty ? 'main' : branch.text.trim(), ignore: [...pr.exclude, ...pr.keep]), tr('Git repository created.')),
          child: Text(tr('Create the Git repository here')),
        ),
      ]);
    } else {
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FieldRow([
          Field(tr('Repository on GitHub'), remote, monospace: true, placeholder: 'https://github.com/account/project.git'),
          Field(tr('Branch'), branch, monospace: true, placeholder: 'main', onChanged: (v) {
            pr.gitBranch = v.trim();
            _branchTimer?.cancel();
            _branchTimer = Timer(const Duration(milliseconds: 700), widget.app.save);
          }),
        ], widths: const [-1, 200]),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (remote.text.trim() != x.remote)
            OutlinedButton(
              key: const ValueKey('git-link'),
              onPressed: working || remote.text.trim().isEmpty ? null : () => _do(() async {
                    await git.link(remote.text.trim());
                    pr.gitRemote = remote.text.trim();
                  }, tr('Project linked to GitHub.')),
              child: Text(tr('Link')),
            ),
          if (x.remote.isEmpty && x.gh)
            OutlinedButton(
              onPressed: working ? null : () => _do(() async {
                    pr.gitRemote = await git.createOnGitHub(pr.name);
                    remote.text = pr.gitRemote;
                  }, tr('Private repository created on GitHub.')),
              child: Text(tr('Create it on GitHub (private)')),
            ),
          FilledButton(
            key: const ValueKey('git-send-open'),
            onPressed: working || widget.app.busy || x.remote.isEmpty || branch.text.trim().isEmpty ? null : _send,
            child: Text(tr('Send to GitHub…')),
          ),
          Text(
              [
                if (x.branch.isNotEmpty) tr('Branch of this PC: {branch}', {'branch': x.branch}),
                x.changes.isEmpty ? tr('nothing changed since the last commit') : tr('{n} changed file(s)', {'n': x.changes.length}),
              ].join('  ·  '),
              style: ty.small),
        ]),
      ]);
    }
    return FormBlock(
      title: 'GitHub',
      description: tr('Send the code of this project to a branch of a GitHub repository: from here when you want, and with each deployment (box "GitHub").'),
      trailing: IconButton(tooltip: tr('Refresh'), icon: const Icon(Icons.refresh, size: 18), onPressed: working ? null : _load),
      child: body,
    );
  }
}

/// "New project": its folder is chosen first; the name and the migrations folder come from it. Cancel: nothing created.
Future<void> newProject(AppState app) async {
  if (app.busy) return;
  final d = await pickFolder(title: tr('Choose the folder of your project on this PC'));
  if (d == null) return;
  final p = Project.create()
    ..folder = d
    ..name = ProjectFile.uniqueName(d.split(RegExp(r'[\\/]')).lastWhere((x) => x.isNotEmpty, orElse: () => d), app.projects.map((x) => x.name));
  for (final m in ['database/migrations', 'migrations', 'sql/migrations', 'db/migrations']) {
    if (p.migrationsFolder.isEmpty && Directory('$d/$m').existsSync()) p.migrationsFolder = m;
  }
  app.projects.add(p);
  app.route = 'p:${p.id}';
  app.save();
  app.notify(tr('Project "{name}" created.', {'name': p.name}), text: tr('Check its settings below and save, then add a target.'));
}

/// "Import a project…": a .deploy.json exported from this app, on this PC or another one.
Future<void> importProject(AppState app) async {
  if (app.busy) return;
  final f = await pickFile(filter: 'Déploiement (*.deploy.json;*.json)|*.deploy.json;*.json');
  if (f == null) return;
  try {
    final p = ProjectFile.read(f, taken: app.projects.map((x) => x.name));
    app.projects.add(p);
    app.route = 'p:${p.id}';
    app.save();
    app.notify(tr('"{name}" imported.', {'name': p.name}),
        text: p.targets.isEmpty ? null : tr('Type the passwords again in the settings of each target, then place its agent again.'));
  } catch (e) {
    app.notify(tr('Import failed'), text: e is FormatException ? e.message : '$e', severity: Severity.error);
  }
}

class _SyncRow extends StatefulWidget {
  const _SyncRow(this.s, {super.key, required this.onRemove, required this.onChanged});
  final SyncTable s;
  final VoidCallback onRemove, onChanged;
  @override
  State<_SyncRow> createState() => _SyncRowState();
}

class _SyncRowState extends State<_SyncRow> {
  late final key = TextEditingController(text: widget.s.key.join(', '));
  late final where = TextEditingController(text: widget.s.where);
  late final ignore = TextEditingController(text: widget.s.ignore.join(', '));

  @override
  void dispose() {
    key.dispose();
    where.dispose();
    ignore.dispose();
    super.dispose();
  }

  List<String> _list(String v) => v.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    return Container(
      padding: const EdgeInsets.only(bottom: 14, top: 4),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ty.p.rule))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Wrap(spacing: 18, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 200),
                child: Text(widget.s.table, style: ty.mono(size: 13.5, weight: FontWeight.w700)),
              ),
              SizedBox(
                width: 130,
                child: CheckLine(tr('Structure'), key: ValueKey('table-structure-${widget.s.table}'), value: widget.s.structure, onChanged: (v) {
                  setState(() => widget.s.structure = v);
                  widget.onChanged();
                }),
              ),
              SizedBox(
                width: 130,
                child: CheckLine(tr('Data'), key: ValueKey('table-data-${widget.s.table}'), value: widget.s.data, onChanged: (v) {
                  setState(() => widget.s.data = v);
                  widget.onChanged();
                }),
              ),
            ]),
          ),
          IconButton(tooltip: tr('Remove'), icon: const Icon(Icons.close, size: 16), onPressed: widget.onRemove),
        ]),
        if (!widget.s.structure && !widget.s.data)
          Text(tr('Neither structure nor data: this table is not sent.'), style: ty.small.copyWith(color: ty.p.changed)),
        if (widget.s.data) ...[
        const SizedBox(height: 4),
        FieldRow([
          Field(tr('Key (auto)'), key, monospace: true, placeholder: 'code', onChanged: (v) {
            widget.s.key = _list(v);
            widget.onChanged();
          }),
          Field(tr('Filter (SQL WHERE)'), where, monospace: true, onChanged: (v) {
            widget.s.where = v;
            widget.onChanged();
          }),
          Field(tr('Columns never sent'), ignore, monospace: true, onChanged: (v) {
            widget.s.ignore = _list(v);
            widget.onChanged();
          }),
        ], widths: const [150, -1, 190]),
        ],
      ]),
    );
  }
}
