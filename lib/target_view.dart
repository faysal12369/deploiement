// A target: its actions, its state, the simulation report (the manifest of what a deployment sends) or its status,
// the activity log — and its settings page.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'db_compare_view.dart';
import 'dialogs.dart';
import 'git.dart' show kGitHub;
import 'motion.dart';
import 'i18n.dart';
import 'models.dart';
import 'operations.dart';
import 'pickers.dart';
import 'report_view.dart';
import 'sql_view.dart';
import 'result_view.dart';
import 'results.dart' show DeployParts;
import 'theme.dart';
import 'widgets.dart';

class TargetPage extends StatefulWidget {
  const TargetPage(this.app, this.project, this.target, {super.key, this.settings = false});
  final AppState app;
  final Project project;
  final Target target;
  final bool settings;
  @override
  State<TargetPage> createState() => _TargetPageState();
}

class _TargetPageState extends State<TargetPage> {
  AppState get app => widget.app;
  Project get pr => widget.project;
  Target get t => widget.target;

  // ---------------------------------------------------------------------------------------------------------------
  //  Actions
  // ---------------------------------------------------------------------------------------------------------------

  Future<Report?> _simulate() async {
    final r = await app.run(t, (o) => o.simulate(pr, t));
    if (r != null) {
      app.reports[t.id] = r;
      app.health[t.id] = true;
      app.activityOpen = false;
      app.changed();
    }
    return r;
  }

  Future<void> _deploy() async {
    var r = app.reports[t.id];
    // an old simulation, one that found nothing, or one made with another choice of tables: simulated again
    if (r == null || DateTime.now().difference(r.time).inMinutes > 30 || r.upToDate || r.tablesKey != pr.tablesKey) {
      r = await _simulate();
      if (r == null || !mounted) return;
    }
    // data ticked for a table whose rows cannot be recognised on the target: taken out of the list (the package is the
    // same: the agent left those rows out anyway, so no new simulation)
    final dropped = dropNoKeyData(pr, r);
    if (dropped.isNotEmpty) {
      r.tablesKey = pr.tablesKey;
      app.save();
      app.journal.info(tr('Data taken out of the list (no key shared with the target, so it can never be sent): {t}', {'t': dropped.join(', ')}));
    }
    // the choice of tables can change in the dialog: then a new simulation with it, and the dialog again
    late DeployParts parts;
    DeployParts? kept; // the boxes left before "Simulate with this choice": the next dialog shows them as they were
    while (true) {
      if (r!.upToDate && tableCandidates(pr, r).every((c) => !c.differs)) {
        // nothing new (asked 17/11/2026): said plainly, nothing is sent, no backup is made
        app.journal.ok(tr('"{name}" is already up to date: nothing to deploy.', {'name': t.name}));
        await showUpToDate(context, t, r);
        return;
      }
      final c = await confirmDeploy(context, t, r, project: pr, gitBranch: kGitHub && pr.gitReady ? pr.gitBranch.trim() : '', parts: kept);
      if (c == null || !mounted) return;
      if (c.tables == null) {
        parts = c.parts;
        break;
      }
      kept = c.parts;
      applyTableChoice(pr, c.tables!);
      app.save();
      r = await _simulate();
      if (r == null || !mounted) return;
    }
    final pkg = r.package;
    final done = await app.run(t, (o) => o.deploy(pr, t, package: pkg, parts: parts));
    app.reports.remove(t.id);
    app.activityOpen = false;
    app.changed();
    if (done != null) app.notify(tr('"{name}" is up to date.', {'name': t.name}));
  }

  Future<void> _test() async {
    final s = await app.run(t, (o) => o.test(t));
    app.health[t.id] = s != null;
    if (s != null) {
      app.statuses[t.id] = s;
      app.reports.remove(t.id);
      app.activityOpen = false;
    }
    app.changed();
  }

  Future<void> _placeAgent() async {
    final s = await app.run(t, (o) async {
      await o.placeAgent(t);
      return true;
    });
    if (s == true) await _test();
  }

  Future<void> _saveAgent() async {
    final f = await Operations(app.settings, app.journal).saveAgent(t);
    await Process.start('explorer', ['/select,', f.path]);
  }

  Future<void> _install() async {
    final c = await chooseSource(context, pr, t, install: true);
    if (c == null || !mounted) return;
    if (c.source != null) {
      final pv = await app.run(t, (o) => o.previewDb(pr, t, c.source!));
      if (pv == null || !mounted) return;
      if (!await confirmDb(context, t, c.source!, pv.$1, pv.$2, install: true)) return;
    } else if (!await confirm(context, tr('Install on "{name}"?', {'name': t.name}), tr('All the project files are sent to the target. Kept files (.env, uploads…) are not touched.'))) {
      return;
    }
    await app.run(t, (o) async {
      await o.install(pr, t, c.source);
      return true;
    });
  }

  Future<void> _replaceDb() async {
    final c = await chooseSource(context, pr, t, install: false);
    if (c?.source == null || !mounted) return;
    final pv = await app.run(t, (o) => o.previewDb(pr, t, c!.source!));
    if (pv == null || !mounted) return;
    if (!await confirmDb(context, t, c!.source!, pv.$1, pv.$2, install: false)) return;
    await app.run(t, (o) async {
      await o.replaceDb(pr, t, c.source!);
      return true;
    });
  }

  Future<void> _backup() async {
    await app.run(t, (o) async {
      await o.backup(t);
      return true;
    });
  }

  Future<void> _restore() async {
    final list = await app.run(t, (o) => o.backups(t));
    if (list == null || !mounted) return;
    final c = await chooseBackup(context, t, list);
    if (c == null) return;
    await app.run(t, (o) async {
      await o.restore(t, db: c.$1, files: c.$2);
      return true;
    });
  }

  /// A copy of the target on this PC to work on — production is only read.
  Future<void> _clone() async {
    final c = await chooseClone(context, app, pr, t);
    if (c == null || !mounted) return;
    final clone = await app.run(t, (o) => o.cloneToPc(pr, t, folder: c.folder, url: c.url, db: c.db, withDb: c.withDb, replace: c.replace));
    if (clone == null) return;
    pr.targets.add(clone);
    app.health[clone.id] = true;
    app.route = 't:${clone.id}';
    app.activityOpen = true;
    app.save();
    app.notify(tr('Clone ready: {url}', {'url': clone.baseUrl}), text: tr('Production was not changed. Deploy your work here first, then to "{name}".', {'name': t.name}));
  }

  void _open() => Process.start('rundll32', ['url.dll,FileProtocolHandler', '${t.baseUrl}/']);

  // ---------------------------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (widget.settings) return TargetSettings(app, pr, t);
    final busy = app.busy;
    final missing = t.missingSettings();
    VoidCallback? on(VoidCallback f) => busy ? null : f;
    VoidCallback? need(VoidCallback f) => busy || missing.isNotEmpty ? null : f; // needs a target that is set up
    final ty = Ty.of(context);
    final report = app.reports[t.id];
    final status = app.statuses[t.id];
    final err = app.errors[t.id];
    final known = report?.status ?? status;
    final agent = (known?['agent'] as num?)?.toInt();
    final php = known?['php'] as String?;
    final result = app.lastResult[t.id];
    final history = app.history[t.id] ?? const [];
    return PageFrame(
      kicker: pr.name,
      title: t.name,
      top: busy ? const LinearProgressIndicator() : null,
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          StatusMark(app.health[t.id], withText: true),
          if (t.cloneOf.isNotEmpty) Tag(tr('Clone of "{name}"', {'name': t.cloneOf}), icon: Icons.content_copy, color: ty.p.changed),
          if (agent != null) Tag(tr('agent {v}', {'v': agent}), icon: Icons.memory, color: agent < 4 ? ty.p.accent : null),
          if (php != null) Tag('PHP $php'),
          Tag(t.transport.label, icon: Icons.swap_horiz),
          if (t.hasUrl)
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: _open,
              child: Tag(t.baseUrl, icon: Icons.open_in_new, color: ty.p.accent),
            )
          else
            Tag(tr('No address yet'), color: ty.p.accent),
        ]),
        if (t.lastAction.isNotEmpty || t.remotePath.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text([if (t.remotePath.isNotEmpty) t.remotePath, if (t.lastAction.isNotEmpty) t.lastAction].join('   ·   '),
                style: ty.small, overflow: TextOverflow.ellipsis),
          ),
      ]),
      actions: [
        TextButton(key: const ValueKey('target-settings'), onPressed: on(() => app.go('t:${t.id}:settings')), child: Text(tr('Settings'))),
        OutlinedButton(key: const ValueKey('target-simulate'), onPressed: need(_simulate), child: Text(tr('Simulate'))),
        FilledButton(key: const ValueKey('target-deploy'), onPressed: need(_deploy), child: Text(tr('Deploy'))),
        MoreMenu(buttonKey: const ValueKey('target-more'), [
          (tr('Back up now'), need(_backup)),
          (tr('Restore a backup…'), need(_restore)),
          ('-', null),
          (tr('Test connection'), need(_test)),
          if (t.transport != Transport.agentOnly) (tr('Place the agent'), need(_placeAgent)),
          (tr('Save the agent to a file'), on(_saveAgent)),
          ('-', null),
          (tr('Compare databases…'), need(() => compareDatabases(context, app, pr, t))),
          (tr('SQL…'), need(() => showSqlDialog(context, app, pr, target: t))),
          (tr('Clone to this PC…'), need(_clone)),
          (tr('Install…'), need(_install)),
          (tr('Replace the database…'), need(_replaceDb)),
          ('-', null),
          (tr('Open the site'), t.hasUrl ? _open : null),
          ('-', null),
          (tr('Delete this target…'), on(() => askRemoveTarget(context, app, pr, t))),
        ]),
      ],
      children: [
        if (!busy && missing.isNotEmpty)
          Notice(
            color: ty.p.accent,
            icon: Icons.build_outlined,
            title: tr('Set up this target first'),
            text: tr('Missing: {list}.', {'list': missing.join(', ')}),
            action: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(onPressed: () => app.go('t:${t.id}:settings'), child: Text(tr('Open the settings'))),
            ),
          ),
        if (app.watchProblems[t.id] case final problems? when !busy)
          Notice(
            color: ty.p.removed,
            icon: Icons.notifications_active_outlined,
            title: tr('Problem found by the email alerts'),
            text: problems.map((x) => x.text).join('\n'),
            action: OutlinedButton(onPressed: () => app.go('settings'), child: Text(tr('Email alerts…'))),
          ),
        if (busy && app.busyTarget == t.id)
          WorkingPanel(app)
        else if (busy)
          Notice(color: ty.p.accent, icon: Icons.hourglass_top, title: tr('Working…'), text: tr('Another target is being worked on: wait for it to finish.'))
        else if (err != null)
          Notice(
            color: ty.p.removed,
            icon: Icons.error_outline,
            title: tr('Last action failed'),
            text: err,
            onClose: () {
              app.errors.remove(t.id);
              app.changed();
            },
          ),
        if (report != null)
          ReportView(report, app: app, project: pr, target: t, key: ValueKey(report.time))
        else if (result != null)
          ResultView(result, onClose: () {
            app.lastResult.remove(t.id);
            app.changed();
          })
        else if (status != null)
          StatusView(status)
        else
          _firstSteps(context, need),
        if (history.isNotEmpty) HistoryView(history, onOpen: (r) => showResult(context, r)),
        ActivityView(app),
      ],
    );
  }

  Widget _firstSteps(BuildContext context, VoidCallback? Function(VoidCallback) on) {
    Widget step(int n, String title, String text, Widget? button) => StepRow(n, title, text, button: button);
    return Section(
      tr('Getting started'),
      icon: Icons.flag_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        step(
          1,
          tr('Place the agent'),
          t.transport == Transport.agentOnly
              ? tr('Save it to a file and copy it into the project folder of the target.')
              : tr('The app sends one PHP file to {path} by {transport}.', {'path': t.remotePath.isEmpty ? tr('the project folder') : t.remotePath, 'transport': t.transport.label}),
          t.transport == Transport.agentOnly
              ? OutlinedButton(key: const ValueKey('step-save-agent'), onPressed: on(_saveAgent), child: Text(tr('Save the agent to a file')))
              : OutlinedButton(key: const ValueKey('step-place-agent'), onPressed: on(_placeAgent), child: Text(tr('Place the agent'))),
        ),
        step(2, tr('Test'), tr('Checks PHP, its extensions, the database and the last release.'),
            OutlinedButton(key: const ValueKey('step-test'), onPressed: on(_test), child: Text(tr('Test')))),
        step(3, tr('Simulate'), tr('Shows what a deployment would change — files, migrations, synced rows — without changing anything.'),
            OutlinedButton(onPressed: on(_simulate), child: Text(tr('Simulate')))),
        step(4, tr('Deploy'), tr('Backs up the target, then sends only what is missing or changed. Empty target: More › Install…'), null),
      ]),
    );
  }
}

// =====================================================================================================================
//  Status (after "Test")
// =====================================================================================================================

class StatusView extends StatelessWidget {
  const StatusView(this.s, {super.key});
  final Map<String, dynamic> s;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final db = ((s['db'] as Map?) ?? {}).cast<String, dynamic>();
    final rel = (s['release'] as Map?)?.cast<String, dynamic>();
    final ext = ((s['extensions'] as Map?) ?? {}).cast<String, dynamic>();
    final missing = ['pdo_mysql', 'zip', 'zlib', 'mbstring'].where((x) => ext[x] != true).toList();
    final lim = ((s['limits'] as Map?) ?? {}).cast<String, dynamic>();
    return Section(
      tr('Target status'),
      icon: Icons.monitor_heart_outlined,
      meta: tr('What the agent answered.'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Fact('PHP', '${s['php']}  ·  ${s['os']}  ·  ${s['server']}',
            note: missing.isEmpty ? null : tr('missing: {list}', {'list': missing.join(', ')}), color: missing.isEmpty ? null : p.removed),
        Fact(tr('Folder'), '${s['root']}', mono: true, note: s['writable'] == true ? null : tr('not writable'), color: s['writable'] == true ? null : p.removed),
        Fact(
          tr('Database'),
          db['ok'] == true ? '${db['name']} @ ${db['host']}  ·  ${db['tables']} ${tr('tables')}' : '${db['error'] ?? '—'}',
          color: db['ok'] == true ? null : p.removed,
          note: db['ok'] == true ? '${tr('settings from')} ${db['source']}${db['tracked'] == true ? '' : ' · ${tr('migrations not tracked yet')}'}' : null,
        ),
        Fact(tr('Last release'), rel == null ? tr('none placed by the app yet') : '${rel['label']}  ·  ${rel['date']}  ·  ${tr('from')} ${rel['source']}'),
        Fact(tr('Limits'),
            'memory ${lim['memory_limit']}  ·  time ${lim['max_execution_time']} s  ·  upload ${lim['upload_max_filesize']}  ·  ${tr('disk')} ${fmtInt((s['disk_free_mb'] as num?)?.toInt() ?? 0)} MB'),
      ]),
    );
  }
}

// =====================================================================================================================
//  Activity (log)
// =====================================================================================================================

class ActivityView extends StatelessWidget {
  const ActivityView(this.app, {super.key});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final log = app.journal;
    final ty = Ty.of(context);
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) => Section(
        tr('Activity'),
        icon: Icons.terminal,
        meta: log.lines.isEmpty ? tr('Nothing yet.') : log.lines.last.text,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (app.activityOpen && log.lines.isNotEmpty) ...[
            SmallButton(tr('Copy'), onPressed: () {
              Clipboard.setData(ClipboardData(text: log.asText()));
              app.notify(tr('Log copied.'));
            }),
            SmallButton(tr('Clear'), onPressed: log.clear),
          ],
          SmallButton(app.activityOpen ? tr('Hide') : tr('Show'), onPressed: () {
            app.activityOpen = !app.activityOpen;
            app.changed();
          }),
        ]),
        child: !app.activityOpen
            ? const SizedBox()
            : Container(
                margin: const EdgeInsets.only(top: 12),
                height: 340,
                padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
                decoration: BoxDecoration(color: ty.p.sunken, borderRadius: BorderRadius.circular(8), border: Border.all(color: ty.p.rule)),
                child: log.lines.isEmpty
                    ? Padding(padding: const EdgeInsets.only(top: 8), child: Text(tr('Nothing yet.'), style: ty.mono(color: ty.p.faint)))
                    : ListView.builder(
                        reverse: true,
                        itemCount: log.lines.length,
                        itemBuilder: (_, i) => _line(context, log.lines[log.lines.length - 1 - i]),
                      ),
              ),
      ),
    );
  }

  Widget _line(BuildContext context, LogLine l) {
    final ty = Ty.of(context);
    final p = ty.p;
    final (String mark, Color color) = switch (l.level) {
      Level.step => ('▸', p.ink),
      Level.ok => ('✓', p.added),
      Level.warn => ('!', p.accent),
      Level.error => ('✗', p.removed),
      Level.info => ('·', p.muted),
      Level.detail => (' ', p.muted),
    };
    final time = '${l.time.hour.toString().padLeft(2, '0')}:${l.time.minute.toString().padLeft(2, '0')}:${l.time.second.toString().padLeft(2, '0')}';
    return Padding(
      padding: EdgeInsets.only(top: l.level == Level.step ? 8 : 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 70, child: Text(time, style: ty.mono(size: 12, color: p.faint))),
        SizedBox(width: 18, child: Text(mark, style: ty.mono(size: 12, color: color, weight: FontWeight.w700))),
        Expanded(
          child: Text(l.level == Level.detail ? '  ${l.text}' : l.text,
              style: ty.mono(
                  size: 12,
                  color: l.level == Level.detail ? p.muted : (l.level == Level.error ? p.removed : p.ink),
                  weight: l.level == Level.step ? FontWeight.w700 : FontWeight.w400)),
        ),
      ]),
    );
  }
}

// =====================================================================================================================
//  Target settings
// =====================================================================================================================

class TargetSettings extends StatefulWidget {
  const TargetSettings(this.app, this.project, this.target, {super.key});
  final AppState app;
  final Project project;
  final Target target;
  @override
  State<TargetSettings> createState() => _TargetSettingsState();
}

class _TargetSettingsState extends State<TargetSettings> {
  late Target t = widget.target.copy();
  late final c = <String, TextEditingController>{
    'name': TextEditingController(text: t.name),
    'url': TextEditingController(text: t.url),
    'host': TextEditingController(text: t.host),
    'port': TextEditingController(text: '${t.port}'),
    'user': TextEditingController(text: t.user),
    'pass': TextEditingController(text: t.pass),
    'remotePath': TextEditingController(text: t.remotePath),
    'privateDir': TextEditingController(text: t.privateDir),
    'dbHost': TextEditingController(text: t.db.host),
    'dbPort': TextEditingController(text: t.db.port),
    'dbName': TextEditingController(text: t.db.name),
    'dbUser': TextEditingController(text: t.db.user),
    'dbPass': TextEditingController(text: t.db.pass),
  };
  late bool autoDb = !t.db.isSet;
  bool showPass = false;

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
    widget.app.flushers.add(_flushQuietly);
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
    widget.app.save();
    saved.value = true;
  }

  /// When leaving the page or closing the app: written to disk without redrawing anything.
  void _flushQuietly() {
    _autoTimer?.cancel();
    if (!_dirty) return;
    _dirty = false;
    _apply();
    widget.app.persistQuietly();
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _later();
  }

  @override
  void dispose() {
    _flushQuietly();
    widget.app.flushers.remove(_flushQuietly);
    saved.dispose();
    for (final x in c.values) {
      x.dispose();
    }
    super.dispose();
  }

  /// What is on the screen into the target (an empty name keeps the previous one; an address that is not complete
  /// yet is kept as typed: the target page says what is still missing).
  void _apply() {
    final name = c['name']!.text.trim();
    widget.target
      ..name = name.isEmpty ? widget.target.name : name
      ..url = Target.folderUrl(c['url']!.text) // "…/index.php" typed: the folder is kept
      ..transport = t.transport
      ..host = c['host']!.text.trim()
      ..port = int.tryParse(c['port']!.text.trim()) ?? t.transport.defaultPort
      ..user = c['user']!.text.trim()
      ..pass = c['pass']!.text
      ..remotePath = c['remotePath']!.text.trim()
      ..privateDir = c['privateDir']!.text.trim().isEmpty ? '.deploy' : c['privateDir']!.text.trim()
      ..db = autoDb
          ? DbSettings(host: 'localhost', user: '')
          : DbSettings(host: c['dbHost']!.text.trim(), port: c['dbPort']!.text.trim(), name: c['dbName']!.text.trim(), user: c['dbUser']!.text.trim(), pass: c['dbPass']!.text)
      ..files = [for (final f in t.files) if (f.local.trim().isNotEmpty && f.remote.trim().isNotEmpty) f]
      ..agentName = t.agentName
      ..token = t.token;
    widget.app.errors.remove(widget.target.id);
  }

  Future<void> _remove() async {
    _flushQuietly(); // what was just typed goes with it, and comes back with "Undo"
    await askRemoveTarget(context, widget.app, widget.project, widget.target);
  }

  @override
  Widget build(BuildContext context) {
    final remote = t.transport.remote;
    final ty = Ty.of(context);
    void back() => widget.app.go('t:${widget.target.id}');
    return PageFrame(
      kicker: '${widget.project.name}  /  ${widget.target.name}',
      onBack: back,
      title: tr('Settings'),
      actions: [
        AutoSaveMark(saved),
        FilledButton(
          key: const ValueKey('target-settings-done'),
          onPressed: () {
            _flush();
            back();
          },
          child: Text(tr('Done')),
        ),
      ],
      children: [
        const SizedBox(height: 12),
        FormBlock(
          title: tr('Target'),
          description: tr('Its name in this app and the address of the project.'),
          child: FieldRow([
            Field(tr('Name'), c['name']!, placeholder: 'production'),
            Field(tr('Address of the project'), c['url']!,
                monospace: true,
                placeholder: 'https://example.com',
                help: tr('What you type in a browser: https://example.com, https://example.com/app, http://192.168.1.10/shop')),
          ], widths: const [200, -1]),
        ),
        FormBlock(
          title: tr('File transfer'),
          description: tr('How the files reach the target.'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Choice<Transport>(
              tr('Transport'),
              value: t.transport,
              items: [for (final x in Transport.values) (x, x.label, true)],
              onChanged: (v) => setState(() {
                t.transport = v;
                if (v.defaultPort > 0) c['port']!.text = '${v.defaultPort}';
              }),
            ),
            if (remote) ...[
              const SizedBox(height: 14),
              FieldRow([
                Field(tr('Host'), c['host']!, monospace: true, placeholder: 'ftp.example.com'),
                Field(tr('Port'), c['port']!, monospace: true),
              ], widths: const [-1, 90]),
              const SizedBox(height: 14),
              FieldRow([Field(tr('User'), c['user']!), Field(tr('Password'), c['pass']!, obscure: !showPass)]),
            ],
            if (t.transport != Transport.agentOnly) ...[
              const SizedBox(height: 14),
              Field(remote ? tr('Project folder on the server') : tr('Project folder (Windows path)'), c['remotePath']!,
                  monospace: true,
                  placeholder: remote ? '/public_html' : r'\\server\www\app',
                  help: remote ? tr('Where the project is (or will be): /public_html for a domain, /public_html/app for a sub-folder…') : tr('This PC or a network share writable by your Windows account.')),
            ],
            const SizedBox(height: 14),
            Field(tr('Agent private folder'), c['privateDir']!,
                monospace: true, help: tr('Relative to the project folder. "../.deploy-app" keeps backups outside the web root (recommended when possible).')),
          ]),
        ),
        FormBlock(
          title: tr('Database on the target'),
          description: tr('Used by migrations, synced tables, backups and copies.'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            CheckLine(tr('Detect it from the project on the target'),
                value: autoDb,
                onChanged: (v) => setState(() => autoDb = v),
                help: tr('.env (Laravel…), wp-config.php (WordPress), or define(\'DB_NAME\', …) in config/*.php')),
            if (!autoDb) ...[
              const SizedBox(height: 14),
              FieldRow([Field(tr('Host'), c['dbHost']!, monospace: true), Field(tr('Port'), c['dbPort']!, monospace: true)], widths: const [-1, 90]),
              const SizedBox(height: 14),
              FieldRow([
                Field(tr('Database'), c['dbName']!, monospace: true),
                Field(tr('User'), c['dbUser']!, monospace: true),
                Field(tr('Password'), c['dbPass']!, obscure: !showPass),
              ]),
            ],
            const SizedBox(height: 8),
            CheckLine(tr('Show passwords'), value: showPass, onChanged: (v) => setState(() => showPass = v)),
          ]),
        ),
        FormBlock(
          title: tr('Files of this target only'),
          description: tr('A different config for this target: a file of this PC sent under another name, only here, even over a kept file. E.g. config/app.local.hostinger.php → config/app.local.php, or .env.production → .env. The file of this PC is never sent as itself.'),
          trailing: OutlinedButton(onPressed: () => setState(() => t.files.add(TargetFile(local: '', remote: ''))), child: Text(tr('Add'))),
          child: t.files.isEmpty
              ? Text(tr('None.'), style: ty.small)
              : Column(children: [
                  for (final (i, f) in t.files.indexed) _TargetFileRow(f, key: ValueKey(f), onChanged: _later, onRemove: () => setState(() => t.files.removeAt(i))),
                ]),
        ),
        FormBlock(
          title: tr('Agent'),
          description: tr('It obeys only this app (its key is stored encrypted on this PC). After a new key, place the agent again.'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SelectableText(t.agentName, style: ty.mono(size: 13)),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () async {
                // saved at once like every change: the agent there must then be placed again
                if (await confirm(context, tr('Make a new key?'),
                    tr('The agent on the target will no longer obey this app until it is placed again (or copied again by hand with "Agent only").'),
                    button: tr('New key'))) {
                  setState(t.newKey);
                }
              },
              child: Text(tr('New key')),
            ),
          ]),
        ),
        FormBlock(
          title: tr('Delete this target'),
          description: tr('Its settings and its history are deleted from this app. Nothing is touched on the server.'),
          child: Align(alignment: Alignment.centerLeft, child: DangerButton(tr('Delete this target…'), onPressed: widget.app.busy ? null : _remove)),
        ),
      ],
    );
  }
}

class _TargetFileRow extends StatefulWidget {
  const _TargetFileRow(this.f, {super.key, required this.onRemove, required this.onChanged});
  final TargetFile f;
  final VoidCallback onRemove, onChanged;
  @override
  State<_TargetFileRow> createState() => _TargetFileRowState();
}

class _TargetFileRowState extends State<_TargetFileRow> {
  late final local = TextEditingController(text: widget.f.local);
  late final remote = TextEditingController(text: widget.f.remote);

  @override
  void dispose() {
    local.dispose();
    remote.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ty = Ty.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LayoutBuilder(
        builder: (context, c) => Row(children: [
          Expanded(
            child: TextField(
              controller: local,
              style: ty.mono(size: 13),
              onChanged: (v) {
                widget.f.local = v;
                widget.onChanged();
              },
              decoration: InputDecoration(
                hintText: tr('file on this PC (absolute or relative to the project)'),
                suffixIcon: fieldButton(Icons.folder_open_outlined, tr('Browse'), () async {
                  final x = await pickFile();
                  if (x != null) {
                    local.text = x;
                    widget.f.local = x;
                    widget.onChanged();
                  }
                }),
              ),
            ),
          ),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward, size: 16, color: ty.p.faint)),
          SizedBox(
            width: isNarrow(c) ? 110 : 180,
            child: TextField(
                controller: remote,
                style: ty.mono(size: 13),
                onChanged: (v) {
                  widget.f.remote = v;
                  widget.onChanged();
                },
                decoration: const InputDecoration(hintText: '.env')),
          ),
          IconButton(tooltip: tr('Remove'), icon: const Icon(Icons.close, size: 16), onPressed: widget.onRemove),
        ]),
      ),
    );
  }
}

/// While an operation runs: the loader, what is being done (each step slides in), the steps already done, the time.
class WorkingPanel extends StatefulWidget {
  const WorkingPanel(this.app, {super.key});
  final AppState app;
  @override
  State<WorkingPanel> createState() => _WorkingPanelState();
}

class _WorkingPanelState extends State<WorkingPanel> {
  late final Timer tick = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);

  @override
  void initState() {
    super.initState();
    tick; // starts the clock
  }

  @override
  void dispose() {
    tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final ty = Ty.of(context);
    final p = ty.p;
    final since = app.busySince ?? DateTime.now();
    final s = DateTime.now().difference(since).inSeconds;
    return Appear(
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: ListenableBuilder(
          listenable: app.journal,
          builder: (context, _) {
            final lines = [for (final l in app.journal.lines) if (since.difference(l.time).inMilliseconds <= 500) l];
            final title = lines.where((l) => l.level == Level.step).map((l) => l.text).lastOrNull ?? tr('Working…');
            final now = app.journal.current ?? lines.where((l) => l.level != Level.detail).map((l) => l.text).lastOrNull ?? '';
            final done = lines.where((l) => l.level == Level.ok).toList();
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const DeployLoader(),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(title, style: ty.cardTitle, maxLines: 2, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 10),
                    const Dots(),
                  ]),
                  const SizedBox(height: 6),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    layoutBuilder: (current, previous) => current ?? const SizedBox(), // the new step replaces the old one
                    transitionBuilder: (child, a) => FadeTransition(
                      opacity: a,
                      child: SlideTransition(position: Tween(begin: const Offset(0, .4), end: Offset.zero).animate(a), child: child),
                    ),
                    child: Text(now, key: ValueKey(now), maxLines: 1, overflow: TextOverflow.ellipsis, style: ty.mono(size: 12.5, color: p.muted)),
                  ),
                  if (done.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    for (final l in done.reversed.take(4).toList().reversed)
                      Appear(
                        key: ValueKey(l),
                        dy: 6,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(children: [
                            Icon(Icons.check_circle, size: 14, color: p.added),
                            const SizedBox(width: 8),
                            Expanded(child: Text(l.text, style: ty.small, maxLines: 1, overflow: TextOverflow.ellipsis)),
                          ]),
                        ),
                      ),
                  ],
                ]),
              ),
              const SizedBox(width: 12),
              Text(s < 60 ? '$s s' : '${s ~/ 60} min ${s % 60} s', style: ty.figure(size: 13, color: p.faint)),
            ]);
          },
        ),
      ),
    );
  }
}
