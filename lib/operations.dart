// What every button does, step by step, told in the log.
//   Test · Place agent · Simulate · Deploy · Install · Replace database · Backup · Restore
// Rules: every write on a target is preceded by a backup of its database (and files); a deployment keeps the target's
// data (files, migrations, synced tables only); installing or replacing a database puts a FULL COPY of the local
// database or of another target's database.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import 'agent_client.dart';
import 'clone.dart';
import 'git.dart';
import 'i18n.dart';
import 'local.dart';
import 'models.dart';
import 'package.dart';
import 'report_html.dart';
import 'sql_view.dart';
import 'results.dart';
import 'transport.dart';

enum Level { step, info, ok, warn, error, detail }

class LogLine {
  LogLine(this.level, this.text, [DateTime? time]) : time = time ?? DateTime.now();
  final Level level;
  final String text;
  final DateTime time;
}

class Journal extends ChangeNotifier {
  final lines = <LogLine>[];
  String? current;

  void _add(Level l, String t) {
    lines.add(LogLine(l, t));
    notifyListeners();
  }

  void step(String t) => _add(Level.step, t);
  void info(String t) => _add(Level.info, t);
  void ok(String t) => _add(Level.ok, t);
  void warn(String t) => _add(Level.warn, t);
  void error(String t) => _add(Level.error, t);
  void detail(String t) => _add(Level.detail, t);

  void progress(String t) {
    current = t;
    notifyListeners();
  }

  void idle() {
    current = null;
    notifyListeners();
  }

  void clear() {
    lines.clear();
    notifyListeners();
  }

  String asText() => lines.map((l) => '${l.time.toIso8601String().substring(11, 19)}  ${l.level.name.padRight(6)} ${l.text}').join('\n');
}

/// Where the database of an installation or a replacement comes from.
class DbSource {
  const DbSource.local() : target = null;
  const DbSource.target(Target this.target);
  final Target? target;
  String get label => target == null ? tr('the local database') : tr('the database of "{name}"', {'name': target!.name});
}

class DbSummary {
  DbSummary(this.tables, this.rows, this.top);
  final int tables;
  final int rows;
  final List<(String, int)> top;

  factory DbSummary.from(Map<String, dynamic> j) => DbSummary(
        (j['tables'] as num?)?.toInt() ?? 0,
        (j['rows_estimate'] as num?)?.toInt() ?? 0,
        [for (final t in (j['top'] as List? ?? [])) ('${(t as Map)['table']}', (t['rows'] as num).toInt())],
      );

  int rowsOf(String table) => top.where((t) => t.$1 == table).map((t) => t.$2).firstOrNull ?? 0;

  Map<String, dynamic> toJson() => {'tables': tables, 'rows_estimate': rows, 'top': [for (final (t, n) in top) {'table': t, 'rows': n}]};
}

/// A row of a synced table for the grid: added (all its values) or updated (its values and the old ones that change).
class SyncRow {
  SyncRow(this.kind, this.key, this.values, this.old);
  final String kind; // add | update
  final String key;
  final List<String?> values;
  final Map<String, String?> old; // column → value on the target before (updates)
  Map<String, dynamic> toJson() => {'k': kind, 'key': key, 'values': values, 'old': old};
  factory SyncRow.from(Map<String, dynamic> j) => SyncRow('${j['k']}', '${j['key']}', [for (final v in (j['values'] as List? ?? [])) v?.toString()],
      {if (j['old'] is Map) for (final e in (j['old'] as Map).entries) '${e.key}': e.value?.toString()}); // PHP: [] when empty
}

class SyncResult {
  SyncResult(this.table, this.added, this.updated, this.same, this.skipped, this.details, this.missingColumns,
      {this.pending = 0, this.columns = const [], this.rows = const [], this.unlinked = 0});
  final String table;
  final int added, updated, same, skipped;
  final List<(String, String)> details;
  final List<String> missingColumns;
  final int pending; // table not on the target yet (created by a pending migration): rows to add at deployment
  final int unlinked; // rows written with a link left empty: the row it points at is not on the target (agent 8)
  final List<String> columns; // synced columns, in the order of [SyncRow.values]
  final List<SyncRow> rows; // up to 200 added / updated rows (agent 4)

  Map<String, dynamic> toJson({int maxRows = 200}) => {
        'table': table, 'added': added, 'updated': updated, 'same': same, 'skipped': skipped, 'pending': pending, 'unlinked': unlinked,
        'details': [for (final (k, t) in details) [k, t]], 'missing_columns': missingColumns, 'columns': columns,
        'rows': [for (final r in rows.take(maxRows)) r.toJson()],
      };

  bool get tableMissing => pending > 0;

  factory SyncResult.from(Map<String, dynamic> j) => SyncResult(
        '${j['table']}',
        (j['added'] as num).toInt(),
        (j['updated'] as num).toInt(),
        (j['same'] as num).toInt(),
        (j['skipped'] as num).toInt(),
        [for (final d in (j['details'] as List? ?? [])) ('${(d as List)[0]}', '${d[1]}')],
        ((j['missing_columns'] as List?) ?? []).map((x) => '$x').toList(),
        pending: (j['pending'] as num?)?.toInt() ?? 0,
        unlinked: (j['unlinked'] as num?)?.toInt() ?? 0,
        columns: ((j['columns'] as List?) ?? []).map((x) => '$x').toList(),
        rows: [for (final r in (j['rows'] as List? ?? [])) SyncRow.from((r as Map).cast<String, dynamic>())],
      );
}

/// The rows results of a sync, but the tables without a key shared with the target: their data never goes, "Deploy"
/// says why under the table — counted as "85 left out" they looked like 85 rows thrown away (18/11/2026, "wtf???").
List<SyncResult> syncResults(Object? tables) => [
      for (final x in (tables as List? ?? []))
        if ((x as Map)['nokey'] != true) SyncResult.from(x.cast<String, dynamic>()),
    ];

/// The result of a simulation, drawn by the Overview tab.
class Report {
  Report({required this.target, required this.package, required this.plan, required this.status, DateTime? time}) : time = time ?? DateTime.now();
  final String target;
  final String package;
  final Map<String, dynamic> plan;
  final Map<String, dynamic> status;
  final DateTime time;
  List<(String, String?)> missing = []; // (table, column) — added by the migrations
  List<SyncResult> sync = [];
  List<TableChange> tables = []; // structure of the chosen tables: what would change
  int get tableChanges => tables.fold(0, (n, t) => n + t.changes.length);
  Map<String, int> localCounts = {}, targetCounts = {}; // exact rows of every table, this PC and the target
  Set<String> localNoKey = {}; // tables of this PC whose rows cannot be recognised on a target (no unique key)
  String tablesKey = ''; // the choice of tables the package was made with (Project.tablesKey)
  DbSummary? summary;
  Structure? localStructure, targetStructure; // columns of every table on this PC and on the target (agent 4)

  List<String> _list(String k) => ((plan[k] as List?) ?? []).map((x) => '$x').toList();
  List<String> get newFiles => _list('new');
  List<String> get changedFiles => _list('changed');
  List<String> get removedFiles => _list('removed');
  int get total => (plan['total'] as num?)?.toInt() ?? 0;
  bool get dbOk => plan['db_ok'] == true;
  bool get firstRelease => plan['first_release'] == true;
  Map<String, dynamic> get _mig => ((plan['migrations'] as Map?) ?? {}).cast<String, dynamic>();
  List<(String, String)> get migrations => [for (final m in (_mig['run'] as List? ?? [])) ('${(m as Map)['path']}', '${m['reason']}')];
  List<String> get baseline => ((_mig['baseline'] as List?) ?? []).map((x) => '$x').toList();
  bool get tracked => _mig['tracked'] == true;
  int get rowsAdded => sync.fold(0, (s, r) => s + r.added + r.pending);
  int get rowsUpdated => sync.fold(0, (s, r) => s + r.updated);
  int get rowsSkipped => sync.fold(0, (s, r) => s + r.skipped);
  bool get upToDate =>
      newFiles.isEmpty && changedFiles.isEmpty && removedFiles.isEmpty && migrations.isEmpty && tableChanges == 0 && rowsAdded + rowsUpdated == 0;

  /// Kept in state.json, to show it again after Déploiement is reopened.
  Map<String, dynamic> toJson() => {
        'target': target, 'package': package, 'plan': plan, 'status': status, 'time': time.toIso8601String(),
        'missing': [for (final (t, c) in missing) [t, c]],
        'sync': [for (final s in sync) s.toJson()],
        'tables': [for (final t in tables) t.toJson()],
        'local_counts': localCounts, 'target_counts': targetCounts, 'local_nokey': localNoKey.toList(), 'tables_key': tablesKey,
        if (summary != null) 'summary': summary!.toJson(),
        if (localStructure != null) 'local_structure': localStructure,
        if (targetStructure != null) 'target_structure': targetStructure,
      };

  factory Report.fromJson(Map<String, dynamic> j) => Report(
        target: '${j['target'] ?? ''}',
        package: '${j['package'] ?? ''}',
        plan: ((j['plan'] as Map?) ?? {}).cast<String, dynamic>(),
        status: ((j['status'] as Map?) ?? {}).cast<String, dynamic>(),
        time: DateTime.tryParse('${j['time']}'),
      )
        ..missing = [for (final m in (j['missing'] as List? ?? [])) ('${(m as List)[0]}', m.length > 1 ? m[1] as String? : null)]
        ..sync = [for (final s in (j['sync'] as List? ?? [])) SyncResult.from((s as Map).cast<String, dynamic>())]
        ..tables = [for (final t in (j['tables'] as List? ?? [])) TableChange.from((t as Map).cast<String, dynamic>())]
        ..localCounts = _counts(j['local_counts'])
        ..targetCounts = _counts(j['target_counts'])
        ..localNoKey = {for (final x in (j['local_nokey'] as List? ?? [])) '$x'}
        ..tablesKey = '${j['tables_key'] ?? ''}'
        ..summary = j['summary'] is Map ? DbSummary.from((j['summary'] as Map).cast<String, dynamic>()) : null
        ..localStructure = j['local_structure'] == null ? null : structureFrom(j['local_structure'])
        ..targetStructure = j['target_structure'] == null ? null : structureFrom(j['target_structure']);
}

class Operations {
  Operations(this.settings, this.log);
  final AppSettings settings;
  final Journal log;

  static String _mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} MB';
  static String now() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  /// Nothing is tried on a target that is not set up: a clear message instead of a connection error.
  static void _ready(Target t) {
    final m = t.missingSettings();
    if (m.isNotEmpty) throw AgentError(tr('"{name}" is not set up yet. Missing: {list}. Open its Settings.', {'name': t.name, 'list': m.join(', ')}));
  }

  Future<T> _with<T>(Target t, Future<T> Function(AgentClient a) f) async {
    _ready(t);
    final a = AgentClient(t);
    try {
      return await f(a);
    } finally {
      a.close();
    }
  }

  Future<T> _withSender<T>(Target t, Future<T> Function(Sender s) f) async {
    _ready(t);
    final s = Sender.forTarget(t);
    await s.open();
    try {
      return await f(s);
    } finally {
      await s.close();
    }
  }

  /// The target's database settings, given to its agent (or back to auto-detection when empty).
  Future<void> _configure(AgentClient a, Target t) async {
    final r = await a.require('configure', {'db': t.db.isSet ? t.db.toAgent() : <String, dynamic>{}});
    if (r['auto'] != true) log.detail(tr('Database settings given to the agent: "{name}" on {host}.', {'name': t.db.name, 'host': t.db.host}));
  }

  // -------------------------------------------------------------------------------------------------------------------

  Future<Map<String, dynamic>> test(Target t) => _with(t, (a) async {
        log.step(tr('Test of "{name}" ({url})', {'name': t.name, 'url': t.baseUrl}));
        await _configure(a, t);
        final s = await _status(a, t);
        describeStatus(s);
        return s;
      });

  void describeStatus(Map<String, dynamic> s) {
    log.ok(tr('Agent reachable: PHP {php} on {os}{server}.', {'php': s['php'], 'os': s['os'], 'server': (s['server'] as String? ?? '').isEmpty ? '' : ' (${s['server']})'}));
    final ext = ((s['extensions'] as Map?) ?? {}).cast<String, dynamic>();
    final missing = ['pdo_mysql', 'zip', 'zlib', 'mbstring'].where((x) => ext[x] != true).toList();
    if (missing.isNotEmpty) log.error(tr('Missing PHP extensions on the target: {list}.', {'list': missing.join(', ')}));
    if (s['writable'] != true) log.error(tr('PHP cannot write in the project folder ({path}).', {'path': s['root']}));
    final db = ((s['db'] as Map?) ?? {}).cast<String, dynamic>();
    if (db['ok'] == true) {
      log.ok(tr('Database "{name}": {tables} tables ({version}), settings from {source}.', {'name': db['name'], 'tables': db['tables'], 'version': db['version'], 'source': db['source']}));
    } else {
      log.warn(tr('No database: {error}', {'error': db['error'] ?? '?'}));
    }
    final r = (s['release'] as Map?)?.cast<String, dynamic>();
    log.info(r != null
        ? tr('Last release placed by the app: {label} ({date}, from {source}).', {'label': r['label'], 'date': r['date'], 'source': r['source']})
        : tr('No release placed by the app yet.'));
  }

  Future<String> _agentCode(Target t) async {
    final dir = t.privateDir.trim().replaceAll('\\', '/');
    if (!RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(dir)) throw AgentError(tr('Invalid private folder: {dir}', {'dir': t.privateDir}));
    return (await rootBundle.loadString('assets/agent/deploy-agent.php'))
        .replaceFirst('{{TOKEN_SHA256}}', t.tokenHash)
        .replaceFirst('{{PRIVATE_DIR}}', dir);
  }

  /// The agent in a file, to copy by hand into the project folder (USB key, remote desktop…).
  Future<File> saveAgent(Target t) async {
    final d = Directory(p.join(Store.work.path, 'agents'))..createSync(recursive: true);
    final f = File(p.join(d.path, t.agentName));
    await f.writeAsString(await _agentCode(t));
    return f;
  }

  Future<void> placeAgent(Target t) async {
    log.step(tr('Placing the agent on "{name}" ({transport})', {'name': t.name, 'transport': t.transport.label}));
    final s = Sender.forTarget(t);
    if (!s.canPlaceFiles) {
      final f = await saveAgent(t);
      log.warn(tr('"Agent only": copy {path} by hand into the project folder of the target, then Test.', {'path': f.path}));
      return;
    }
    final tmp = File(p.join(Store.work.path, 'agent-${t.id}.php'));
    await tmp.writeAsString(await _agentCode(t));
    try {
      await _withSender(t, (x) => x.send(tmp, t.agentName, log.progress));
    } finally {
      if (tmp.existsSync()) tmp.deleteSync();
    }
    log.ok(tr('Agent placed: {url}', {'url': '${t.agentUrl}'}));
    await test(t);
  }

  /// The agent's status. An older agent is first replaced by the one of this app: by the agent itself (version 3 and
  /// later), else through the transport when it can place files; an agent placed by hand must be copied again once.
  Future<Map<String, dynamic>> _status(AgentClient a, Target t, {Sender? s}) async {
    final st = await a.require('status');
    final code = await _agentCode(t);
    final want = int.parse(RegExp(r'const AGENT_VERSION = (\d+);').firstMatch(code)![1]!);
    final have = (st['agent'] as num?)?.toInt() ?? 0;
    if (have > want || st['agent_sha1'] == sha1.convert(utf8.encode(code)).toString()) return st;
    final features = ((st['features'] as List?) ?? []).map((x) => '$x').toSet();
    if (features.contains('update_agent')) {
      final r = await a.require('update_agent', {'code': code});
      final next = AgentClient(t.copy()..agentName = '${r['next']}'); // the new agent, written next to the old one
      try {
        await next.require('take_over');
      } finally {
        next.close();
      }
      log.ok(tr('Agent of "{name}" updated to version {v}.', {'name': t.name, 'v': want}));
    } else if (s != null && s.canPlaceFiles) {
      final tmp = File(p.join(Store.work.path, 'agent-${t.id}.php'));
      await tmp.writeAsString(code);
      try {
        await s.send(tmp, t.agentName, log.progress);
      } finally {
        if (tmp.existsSync()) tmp.deleteSync();
      }
      log.ok(tr('Agent of "{name}" replaced by version {v}.', {'name': t.name, 'v': want}));
    } else {
      log.warn(t.transport == Transport.agentOnly
          ? tr('The agent on "{name}" is version {have}, this app brings version {want}: copy it again once (More › Save the agent to a file) to see inside the files and send only what differs. After that it updates itself.',
              {'name': t.name, 'have': have, 'want': want})
          : tr('The agent on "{name}" is version {have}: the next simulation replaces it by version {want}.', {'name': t.name, 'have': have, 'want': want}));
      return st;
    }
    return a.require('status');
  }

  static Set<String> features(Map<String, dynamic>? status) => (((status ?? {})['features'] as List?) ?? []).map((x) => '$x').toSet();

  /// A file of the project as it is on the target: its bytes, or null when the target does not have it.
  Future<Uint8List?> fileOnTarget(Target t, String rel) => _with(t, (a) async {
        final r = await a.call('file', {'path': rel});
        if (r['ok'] != true) {
          if ('${r['message']}'.startsWith('Unknown action')) {
            throw AgentError(tr('The agent on "{name}" is too old to show its files: copy it again once (More › Save the agent to a file).', {'name': t.name}));
          }
          throw AgentError('${r['message']}');
        }
        if (r['exists'] != true) return null;
        if (r['too_big'] == true) throw AgentError(tr('{path} is too big to be shown ({mb} MB).', {'path': rel, 'mb': _mb((r['size'] as num).toInt())}));
        return base64Decode('${r['base64']}');
      });

  /// A copy of the target on this PC (its files, kept ones included, and its database), registered as a new target
  /// so changes can be tried on it before production. The target is only read: one backup is made there, downloaded,
  /// then removed from it. [replace]: the folder and the database of this PC may already have content.
  Future<Target> cloneToPc(Project pr, Target t, {required String folder, required String url, required DbSettings db, bool withDb = true, bool replace = false}) async {
    log.step(tr('Clone of "{name}" to this PC: {folder}', {'name': t.name, 'folder': folder}));
    final dir = Directory(folder);
    if (dir.existsSync() && dir.listSync().isNotEmpty && !replace) {
      throw AgentError(tr('The folder {path} is not empty.', {'path': folder}));
    }
    final got = <File>[];
    await _with(t, (a) async {
      await _configure(a, t);
      final st = await _status(a, t);
      if (!features(st).contains('clone')) {
        throw AgentError(tr('The agent on "{name}" is too old to make a clone: copy it again once (More › Save the agent to a file).', {'name': t.name}));
      }
      final dbOk = (st['db'] as Map?)?['ok'] == true;
      if (withDb && !dbOk) log.warn(tr('The target has no database the agent can read: only the files are copied.'));
      log.info(tr('Copy of the target (all its files{db}), made on the target — nothing there is changed…', {'db': withDb && dbOk ? tr(' and its database') : ''}));
      final b = await a.loop('backup', {'db': withDb && dbOk, 'files': true, 'all': true}, log.progress);
      for (final name in (b['files'] as List).cast<String>()) {
        final f = File(p.join(Store.work.path, name));
        log.info(tr('Downloading {file}…', {'file': name}));
        await a.download(name, f, log.progress);
        got.add(f);
        await a.call('delete', {'file': name, 'folder': 'backups'}); // this copy is not a backup of the target
      }
    });
    try {
      final zip = got.where((f) => p.basename(f.path).startsWith('files-')).firstOrNull;
      if (zip == null) throw AgentError(tr('The target sent no files.'));
      if (replace && dir.existsSync()) {
        log.info(tr('Emptying {path}…', {'path': folder}));
        for (final e in dir.listSync()) {
          e.deleteSync(recursive: true);
        }
      }
      dir.createSync(recursive: true);
      log.info(tr('Unpacking the files into {path}…', {'path': folder}));
      await extractFileToDisk(zip.path, folder);
      final n = dir.listSync(recursive: true).whereType<File>().length;
      log.ok(tr('{n} file(s) copied.', {'n': fmtInt(n)}));

      final dump = got.where((f) => p.basename(f.path).startsWith('db-')).firstOrNull;
      if (dump != null) {
        log.info(tr('Loading the database into "{name}" on this PC…', {'name': db.name}));
        final tables = await Local(settings).importDump(db, dump, replace: replace);
        log.ok(tr('Database "{name}" on this PC: {n} tables.', {'name': db.name, 'n': tables}));
        final files = pointToDatabase(folder, pr.keep, db);
        if (files.isEmpty) {
          log.warn(tr('No database settings found in the copy (.env, wp-config.php, config/*.php): set "{name}" there yourself.', {'name': db.name}));
        } else {
          log.ok(tr('The copy uses its own database: settings written in {files}.', {'files': files.join(', ')}));
          final kept = Patterns(pr.keep);
          for (final f in files.where((f) => !kept.matches(f))) {
            log.warn(tr('{file} is not a kept file: a deployment to the clone would overwrite its database settings. Add it to "Kept on the targets".', {'file': f}));
          }
        }
      }
    } finally {
      for (final f in got) {
        if (f.existsSync()) f.deleteSync();
      }
    }
    final c = Target.create()
      ..name = tr('{name} (clone)', {'name': t.name})
      ..url = url
      ..transport = Transport.folder
      ..remotePath = folder
      ..db = withDb ? db : DbSettings(host: 'localhost', user: '')
      ..lastAction = tr('Cloned from "{name}" {date}', {'name': t.name, 'date': now()})
      ..cloneOf = t.name;
    await placeAgent(c);
    log.ok(tr('Clone ready: {url} — production was not changed.', {'url': c.baseUrl}));
    return c;
  }

  /// The databases of this PC and of the target side by side, read only on both: the rows of each table recognised by
  /// their key (rows of this PC missing on the target, and the reverse ), and the
  /// structure of both as SQL, filled into the Delta Schéma page that writes the script bringing the target's
  /// structure to this PC's.
  Future<DbCompare> compareDatabases(Project pr, Target t) => _with(t, (a) async {
        log.step(tr('Comparing the databases of this PC and of "{name}"', {'name': t.name}));
        if (!pr.localDb.isSet) throw AgentError(tr('No local database in the project settings.'));
        await _configure(a, t);
        final st = await _status(a, t);
        if (!features(st).contains('inventory')) {
          throw AgentError(tr('The agent on "{name}" is too old to compare databases: run a simulation once (it updates the agent), or copy it again (More › Save the agent to a file).',
              {'name': t.name}));
        }
        final options = <String, dynamic>{'count_only': pr.compareCountOnly, 'keys': pr.compareKeyMap};
        final local = Local(settings);
        log.info(tr('Reading the database of this PC ({name})…', {'name': pr.localDb.name}));
        final pcSql = await local.schemaSql(pr.localDb);
        final pc = Inventory.from(await local.inventory(pr.localDb, options));
        log.info(tr('Reading the database of the target…'));
        final targetSql = '${(await a.require('schema_sql'))['sql'] ?? ''}';
        final target = Inventory.from(await a.require('inventory', options));
        final time = DateTime.now();
        String two(int n) => n.toString().padLeft(2, '0');
        final dir = Directory(p.join(Store.work.path, 'reports'))..createSync(recursive: true);
        final page = File(p.join(dir.path,
            '${t.name.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_')}-delta-${time.year}${two(time.month)}${two(time.day)}-${two(time.hour)}${two(time.minute)}${two(time.second)}.html'));
        await page.writeAsString(deltaSchemaPage(await rootBundle.loadString('assets/tools/delta-schema.html'),
            oldSql: targetSql, newSql: pcSql, title: tr('Structure: "{name}" → this PC', {'name': t.name}), server: target.server));
        final c = DbCompare(time: time, pc: pc, target: target, pcSql: pcSql, targetSql: targetSql, deltaPage: page);
        log.detail(tr('This PC: {db} ({server}), {rows} rows', {'db': pc.database, 'server': pc.server, 'rows': fmtInt(pc.rows)}));
        log.detail(tr('target: {db} ({server}), {rows} rows', {'db': target.database, 'server': target.server, 'rows': fmtInt(target.rows)}));
        (c.withMissing == 0 ? log.ok : log.warn)(dataHeadline(c));
        log.ok(tr('Databases compared: nothing was changed on either side.'));
        return c;
      });

  /// One table of the target, read-only: columns, row count, a page of rows (secrets masked by the agent).
  Future<Map<String, dynamic>> tableData(Target t, String table, {int offset = 0, int limit = 50}) => _with(t, (a) async {
        final r = await a.call('table', {'table': table, 'offset': offset, 'limit': limit});
        if (r['ok'] != true && '${r['message']}'.startsWith('Unknown action')) {
          throw AgentError(tr('The agent on "{name}" is too old to show its tables: copy it again once (More › Save the agent to a file).', {'name': t.name}));
        }
        if (r['ok'] != true) throw AgentError('${r['message']}');
        return r;
      });

  Future<String> _deliverPackage(Project pr, Target t, AgentClient a, Sender s, Map<String, dynamic> status) async {
    if (pr.folder.trim().isEmpty || !Directory(pr.folder.trim()).existsSync()) {
      throw AgentError(tr('The project "{name}" has no folder on this PC yet (or it was moved): choose it in the project settings.', {'name': pr.name}));
    }
    final b = PackageBuilder(settings, pr, t);
    final scan = await b.scan(log.progress);
    Set<String>? only;
    if (features(status).contains('compare')) {
      final c = await a.require('compare', {'files': scan.files, 'keep': pr.keep, 'force': scan.force});
      only = ((c['differ'] as List?) ?? []).map((x) => '$x').toSet();
      log.info(tr('{n} of {total} file(s) differ on the target: only they are sent.', {'n': only.length, 'total': scan.files.length}));
    }
    final f = await b.build(log.progress, scan: scan, only: only);
    log.info(tr('Sending the package ({mb}) by {transport}…', {'mb': _mb(f.lengthSync()), 'transport': t.transport.label}));
    await s.deliver(a, f, p.basename(f.path), log.progress);
    log.ok(tr('Package received and checked by the target.'));
    return p.basename(f.path);
  }

  Future<String> _deliverDb(Project pr, Target t, AgentClient a, Sender s, DbSource src) async {
    final File f;
    if (src.target == null) {
      if (!pr.localDb.isSet) throw AgentError(tr('No local database in the project settings.'));
      log.info(tr('Copy of the local database "{name}"…', {'name': pr.localDb.name}));
      f = await Local(settings).dump(pr.localDb);
    } else {
      f = await _copyFrom(src.target!);
    }
    log.info(tr('Sending the copy of {source} ({mb})…', {'source': src.label, 'mb': _mb(f.lengthSync())}));
    final name = 'db-copy-${DateTime.now().millisecondsSinceEpoch}.sql.gz';
    await s.deliver(a, f, name, log.progress);
    log.ok(tr('Database copy received and checked by the target.'));
    try {
      f.deleteSync();
    } catch (_) {}
    return name;
  }

  /// Another target's database: its agent backs it up, the app brings it to this PC.
  Future<File> _copyFrom(Target source) => _with(source, (a) async {
        log.info(tr('Copy of the database of "{name}"…', {'name': source.name}));
        final b = await a.loop('backup', {'db': true, 'files': false}, log.progress);
        final file = (b['files'] as List).first as String;
        final dest = File(p.join(Store.work.path, 'db-target-${DateTime.now().millisecondsSinceEpoch}.sql.gz'));
        await a.download(file, dest, log.progress);
        log.ok(tr('Database of "{name}" downloaded ({mb}).', {'name': source.name, 'mb': _mb(dest.lengthSync())}));
        return dest;
      });

  void _describePlan(Map<String, dynamic> plan) {
    log.info(tr('Release {label} — {total} files.', {'label': plan['label'], 'total': plan['total']}));
    final nw = (plan['new'] as List).length, ch = (plan['changed'] as List).length, rm = (plan['removed'] as List).length;
    log.info(tr('Files: {new} new, {changed} changed, {removed} to remove.', {'new': nw, 'changed': ch, 'removed': rm}));
    for (final (k, sign) in [('new', '+'), ('changed', '~'), ('removed', '-')]) {
      final l = (plan[k] as List).cast<String>();
      for (final f in l.take(30)) {
        log.detail('$sign $f');
      }
      if (l.length > 30) log.detail('  … ${l.length - 30}');
    }
    final mig = ((plan['migrations'] as Map?) ?? {}).cast<String, dynamic>();
    final run = (mig['run'] as List? ?? []);
    if (plan['db_ok'] != true) {
      log.warn(tr('No database on the target: migrations and synced tables are skipped.'));
    } else {
      log.info(run.isEmpty ? tr('Migrations: none to run.') : tr('Migrations to run: {n}.', {'n': run.length}));
      for (final m in run) {
        log.detail('> ${p.posix.basename('${(m as Map)['path']}')}${m['reason'] == 'changed' ? ' (${tr('file changed')})' : ''}');
      }
      final base = (mig['baseline'] as List? ?? []);
      if (base.isNotEmpty) log.detail(tr('{n} migration(s) already in the project folder of the target: recorded as applied.', {'n': base.length}));
    }
  }

  void _describeSync(List<SyncResult> rows, {required bool dryRun}) {
    if (rows.isEmpty) return;
    final unlinked = rows.fold(0, (s, r) => s + r.unlinked);
    if (unlinked > 0) {
      log.warn(tr('{n} row(s) written without one of their links: the row they point at is not on the target (details in the report).', {'n': unlinked}));
    }
    final add = rows.fold(0, (s, r) => s + r.added + r.pending), upd = rows.fold(0, (s, r) => s + r.updated), skp = rows.fold(0, (s, r) => s + r.skipped);
    log.info(tr('Synced tables{sim}: +{add} added, {upd} updated, {skp} skipped.', {'sim': dryRun ? ' (${tr('simulation')})' : '', 'add': add, 'upd': upd, 'skp': skp}));
    for (final r in rows.where((r) => r.tableMissing)) {
      log.detail(tr('{table}: created by the migrations — {n} row(s) to add', {'table': r.table, 'n': r.pending}));
    }
    for (final r in rows.where((r) => r.added + r.updated + r.skipped > 0)) {
      log.detail('${r.table}: +${r.added} ~${r.updated} ×${r.skipped}');
      for (final (k, txt) in r.details.take(6)) {
        log.detail('    $k  $txt');
      }
    }
  }

  /// The structure of the chosen tables, in the Activity: what would change (simulation) or what changed.
  void _describeTables(List<TableChange> tables, {required bool dryRun}) {
    if (tables.isEmpty) return;
    final n = tables.fold(0, (s, t) => s + t.changes.length);
    log.info(n == 0
        ? tr('Structure of the chosen tables: the same as on this PC.')
        : tr('Structure of the chosen tables{sim}: {n} change(s) in {t} table(s).',
            {'sim': dryRun ? ' (${tr('simulation')})' : '', 'n': n, 't': tables.where((t) => t.changes.isNotEmpty).length}));
    String bare(String def) => def.replaceFirst(RegExp(r'^`[^`]+`\s*'), '');
    for (final t in tables.where((t) => t.changes.isNotEmpty || t.error != null)) {
      log.detail(t.create
          ? tr('{table}: created', {'table': t.table})
          : tr('{table}: {add} column(s) added, {chg} changed, {keys} index(es) added',
              {'table': t.table, 'add': t.count('add_column'), 'chg': t.count('change_column'), 'keys': t.count('add_key')}));
      for (final c in t.changes.where((c) => c.what == 'change_column').take(6)) {
        log.detail('    ${c.name}: ${bare(c.before)}  →  ${bare(c.after)}');
      }
      if (t.error != null) log.error('${t.table}: ${t.error}');
    }
  }

  // -------------------------------------------------------------------------------------------------------------------

  /// What "Deploy" would do, without changing anything. The package stays on the target: the deployment reuses it.
  Future<Report> simulate(Project pr, Target t) => _with(t, (a) => _withSender(t, (s) async {
            log.step(tr('Simulation: what "Deploy" would do on "{name}"', {'name': t.name}));
            await _configure(a, t);
            final status = await _status(a, t, s: s);
            final pkg = await _deliverPackage(pr, t, a, s, status);
            final plan = await a.require('plan', {'package': pkg});
            final rep = Report(target: t.name, package: pkg, plan: plan, status: status)..tablesKey = pr.tablesKey;
            _describePlan(plan);
            if (rep.dbOk) {
              final v = await a.require('verify', {'package': pkg});
              rep.missing = [for (final m in (v['missing'] as List? ?? [])) ('${(m as Map)['table']}', m['column'] as String?)];
              if (rep.missing.isNotEmpty) log.info(tr('Structure: {n} table(s) or column(s) to be added by the migrations.', {'n': rep.missing.length}));
              if (pr.structureTables.isNotEmpty) {
                final tb = await a.require('tables', {'package': pkg, 'dry_run': true});
                rep.tables = [for (final x in (tb['tables'] as List? ?? [])) TableChange.from((x as Map).cast<String, dynamic>())];
                _describeTables(rep.tables, dryRun: true);
              }
              if (pr.dataTables.isNotEmpty) log.info(tr('Rows of the tables whose data is sent (simulation)…'));
              final sy = await a.loop('sync', {'package': pkg, 'dry_run': true}, log.progress);
              rep.sync = syncResults(sy['tables']);
              _describeSync(rep.sync, dryRun: true);
              if (features(status).contains('counts') && pr.localDb.isSet) {
                try {
                  rep.targetCounts = _counts((await a.require('counts'))['tables']);
                  final (counts, noKey) = await Local(settings).counts(pr.localDb);
                  rep
                    ..localCounts = counts
                    ..localNoKey = noKey;
                } catch (e) {
                  log.warn(tr('Rows of the tables not counted: {error}', {'error': '$e'.split('\n').first}));
                }
              }
              rep.summary = DbSummary.from(await a.require('summary'));
              if (features(status).contains('structure')) {
                rep.targetStructure = structureFrom((await a.require('structure'))['tables']);
                if (pr.localDb.isSet) {
                  try {
                    rep.localStructure = structureFrom(await Local(settings).structure(pr.localDb));
                  } catch (e) {
                    log.warn(tr('Structure of the local database not read: {error}', {'error': '$e'.split('\n').first}));
                  }
                }
              }
            }
            log.ok(tr('Simulation done: nothing was changed on the target.'));
            return rep;
          }));

  /// [package]: the one a simulation just left on the target (otherwise it is built and sent). [parts]: what is sent —
  /// the files, the structure (migrations), the data (synced tables); a part not chosen stays as it is on the target.
  /// The result says what was done, also when it failed (then [DeployResult.error] says where it stopped and the
  /// error is thrown again).
  Future<DeployResult> deploy(Project pr, Target t, {String? package, DeployParts parts = const DeployParts()}) {
    final res = DeployResult(time: DateTime.now(), project: pr.name, target: t.name)..parts = parts;
    final clock = Stopwatch()..start();
    return _with(t, (a) => _withSender(t, (s) async {
          try {
            log.step(parts.all
                ? tr('Deploying "{project}" to "{target}": files, migrations, synced tables — the target keeps its data', {'project': pr.name, 'target': t.name})
                : tr('Deploying "{project}" to "{target}": {parts} only — the target keeps its data', {'project': pr.name, 'target': t.name, 'parts': parts.label}));
            await _configure(a, t);
            final status = await _status(a, t, s: s);
            var pkg = package;
            Map<String, dynamic>? plan;
            if (pkg != null) {
              final r = await a.call('plan', {'package': pkg});
              if (r['ok'] == true && ((r['stale'] as List?) ?? []).isEmpty) {
                plan = r;
                log.info(tr('Reusing the package of the simulation: {name}.', {'name': pkg}));
              } else if (r['ok'] == true) {
                log.info(tr('The target changed since the simulation: a new package is made.'));
              }
            }
            if (plan == null) {
              pkg = await _deliverPackage(pr, t, a, s, status);
              plan = await a.require('plan', {'package': pkg});
            }
            final name = pkg!;
            _describePlan(plan);
            List<String> list(String k) => ((plan![k] as List?) ?? []).map((x) => '$x').toList();
            res
              ..label = '${plan['label'] ?? ''}'
              ..newFiles = list('new')
              ..changedFiles = list('changed')
              ..removedFiles = list('removed');
            final dbOk = plan['db_ok'] == true;

            // the database is always backed up when there is one; the files only when they are sent
            var saved = <String>[];
            if (dbOk || parts.files) {
              log.info(dbOk && parts.files
                  ? tr('Backup of the target database and files…')
                  : (dbOk ? tr('Backup of the target database…') : tr('Backup of the target files…')));
              final b = await a.loop('backup', {'db': dbOk, 'files': parts.files}, log.progress);
              saved = (b['files'] as List).cast<String>();
              res.backups = saved;
              log.ok(tr('Backup done on the target: {files}.', {'files': saved.join(', ')}));
            }

            final mig = ((plan['migrations'] as Map?) ?? {}).cast<String, dynamic>();
            final run = [for (final m in (mig['run'] as List? ?? [])) '${(m as Map)['path']}'];
            final base = ((mig['baseline'] as List?) ?? []).map((x) => '$x').toList();
            if (dbOk && !parts.structure) {
              if (run.isNotEmpty) log.warn(tr('Structure not chosen: {n} migration(s) not run.', {'n': run.length}));
              // The files about to be written hold the new migrations. On a target the app never tracked, a later
              // deployment would take them for migrations already applied (they are in its folder) and never run them:
              // the tracking starts now, with only the migrations that were there before.
              if (parts.files && mig['tracked'] != true) {
                final m = await a.call('migrate', {'package': name, 'run': const <String>[], 'baseline': base});
                if (m['ok'] != true) throw AgentError('${m['message']}');
                res.baseline = base.length;
              }
            } else if (dbOk && (run.isNotEmpty || base.isNotEmpty || mig['tracked'] != true)) {
              res.baseline = base.length;
              final m = await a.call('migrate', {'package': name, 'run': run, 'baseline': base});
              for (final x in (m['done'] as List? ?? [])) {
                final n = p.posix.basename('${(x as Map)['path']}');
                res.migrations.add((n, (x['statements'] as num?)?.toInt() ?? 0));
                log.detail(tr('ran: {name} ({n} statements)', {'name': n, 'n': x['statements']}));
              }
              if (m['ok'] != true) {
                throw AgentError('${m['message']}\n${tr('The files of the target were not changed. Its database before: {file} (Restore).', {'file': saved.first})}');
              }
              if (run.isNotEmpty) log.ok(tr('{n} migration(s) run.', {'n': run.length}));
            }

            // the structure of the chosen tables: after the migrations (they may create them), before the files
            if (dbOk && pr.structureTables.isNotEmpty && !parts.structure) {
              log.info(tr('Structure not chosen: the chosen tables stay as they are.'));
            } else if (dbOk && pr.structureTables.isNotEmpty) {
              final tb = await a.call('tables', {'package': name, 'dry_run': false});
              res.tables = [for (final x in (tb['tables'] as List? ?? [])) TableChange.from((x as Map).cast<String, dynamic>())];
              _describeTables(res.tables, dryRun: false);
              if (tb['ok'] != true) {
                throw AgentError('${tb['message']}\n${tr('The files of the target were not changed. Its database before: {file} (Restore).', {'file': saved.first})}');
              }
            }

            if (parts.files) {
              log.info(tr('Writing the files…'));
              final w = await a.require('apply_files', {'package': name});
              res
                ..written = (w['written'] as num?)?.toInt() ?? 0
                ..removed = (w['removed'] as num?)?.toInt() ?? 0
                ..same = (w['same'] as num?)?.toInt() ?? 0;
              log.ok(tr('{written} file(s) written, {removed} removed, {same} already up to date.', {'written': w['written'], 'removed': w['removed'], 'same': w['same']}));
            } else {
              log.info(tr('Files not chosen: the files of the target stay as they are.'));
            }

            if (dbOk && pr.dataTables.isNotEmpty && !parts.data) {
              log.info(tr('Data not chosen: the synced tables stay as they are.'));
            } else if (dbOk && pr.dataTables.isNotEmpty) {
              log.info(tr('Rows of the tables whose data is sent…'));
              final sy = await a.loop('sync', {'package': name, 'dry_run': false}, log.progress);
              res.sync = syncResults(sy['tables']);
              _describeSync(res.sync, dryRun: false);
            }
            if (dbOk) res.missingAfter = await _verify(a, name);
            await a.call('delete', {'file': name, 'folder': 'packages'});
            if (parts.github) {
              // after the deployment: GitHub gets what is now online; a refusal there does not undo the deployment
              try {
                final id = await Git(pr.folder).send(branch: pr.gitBranch.trim(), message: tr('Deployed to "{target}" — {date}', {'target': t.name, 'date': now()}), log: log);
                res.git = '${pr.gitBranch.trim()} $id';
                log.ok(tr('Sent to GitHub: commit {id} on "{branch}".', {'id': id, 'branch': pr.gitBranch.trim()}));
              } catch (e) {
                res.gitError = '$e'.split('\n').first;
                log.warn(tr('Not sent to GitHub: {error}', {'error': '$e'}));
              }
            }
            t.lastAction = tr('Deployed {date}', {'date': now()});
            res.ok = true;
            log.ok(tr('"{name}" is up to date. Undo: Restore ({files}).', {'name': t.name, 'files': saved.join(' + ')}));
            return res;
          } catch (e) {
            res.error = '$e'.split('\n').first;
            rethrow;
          } finally {
            res.seconds = clock.elapsedMilliseconds / 1000;
            onResult?.call(res);
          }
        }));
  }

  /// SQL typed in the app, run on the target: the database is backed up first when a statement changes something.
  Future<List<SqlOutcome>> runSql(Target t, String sql) => _with(t, (a) async {
        log.step(tr('SQL on "{name}"', {'name': t.name}));
        await _configure(a, t);
        final status = await _status(a, t); // an older agent updates itself here
        if (!features(status).contains('sql')) {
          throw AgentError(tr('The agent on "{name}" cannot run SQL yet: copy it again once (More › Save the agent to a file).', {'name': t.name}));
        }
        if (sqlChanges(sql)) {
          log.info(tr('Backup of the target database…'));
          final b = await a.loop('backup', {'db': true, 'files': false}, log.progress);
          log.ok(tr('Backup done on the target: {files}.', {'files': (b['files'] as List).join(', ')}));
        }
        final r = await a.require('sql', {'sql': sql});
        final out = [for (final x in (r['results'] as List? ?? [])) SqlOutcome.from((x as Map).cast<String, dynamic>())];
        _describeSql(out);
        return out;
      });

  /// SQL typed in the app, run on the local database of the project (no backup: it is this PC's own database).
  Future<List<SqlOutcome>> runSqlLocal(Project pr, String sql) async {
    if (!pr.localDb.isSet) throw AgentError(tr('No local database in the project settings.'));
    log.step(tr('SQL on the local database "{name}"', {'name': pr.localDb.name}));
    final out = [for (final x in await Local(settings).sql(pr.localDb, sql)) SqlOutcome.from(x)];
    _describeSql(out);
    return out;
  }

  void _describeSql(List<SqlOutcome> out) {
    for (final o in out) {
      if (o.error != null) {
        log.error('${o.sql}\n${o.error}');
      } else {
        log.detail(o.reads ? '${o.sql}  →  ${o.count}' : '${o.sql}  →  ${o.affected}');
      }
    }
    final failed = out.where((o) => o.error != null).length;
    if (failed > 0) {
      log.warn(tr('Stopped at the error: the statements before it ran, the ones after did not.'));
    } else {
      log.ok(tr('{n} statement(s) run.', {'n': out.length}));
    }
  }

  /// "Send to GitHub": the changes of the project folder committed with [message] and sent to its GitHub branch.
  Future<String> gitSend(Project pr, String message) async {
    log.step(tr('GitHub: "{project}" to the branch "{branch}"', {'project': pr.name, 'branch': pr.gitBranch.trim()}));
    final id = await Git(pr.folder).send(branch: pr.gitBranch.trim(), message: message, log: log);
    log.ok(tr('Sent to GitHub: commit {id} on "{branch}".', {'id': id, 'branch': pr.gitBranch.trim()}));
    return id;
  }

  /// Called with the result of each deployment, also a failed one (the screens keep it in the history).
  void Function(DeployResult)? onResult;

  Future<int> _verify(AgentClient a, String pkg) async {
    final v = await a.require('verify', {'package': pkg});
    if (v['none'] == true) return 0;
    final missing = (v['missing'] as List? ?? []);
    if (missing.isEmpty) {
      log.ok(tr('Database structure: complete ({n} tables expected).', {'n': v['tables']}));
    } else {
      log.warn(tr('Still missing in the target database: {n} item(s).', {'n': missing.length}));
      for (final m in missing.take(40)) {
        log.detail('${(m as Map)['table']}${m['column'] != null ? '.${m['column']}' : ''}');
      }
    }
    return missing.length;
  }

  /// Before an installation or a replacement: the target database today (null: none or empty) and the source.
  Future<(DbSummary?, DbSummary)> previewDb(Project pr, Target t, DbSource src) async {
    log.step(tr('Preview: the database of "{name}" before and after, with {source}', {'name': t.name, 'source': src.label}));
    final before = await _with(t, (a) async {
      await _configure(a, t);
      final s = await a.require('status');
      if ((s['db'] as Map?)?['ok'] != true) return null;
      return DbSummary.from(await a.require('summary'));
    });
    final after = src.target == null
        ? (pr.localDb.isSet ? DbSummary.from(await Local(settings).summary(pr.localDb)) : throw AgentError(tr('No local database in the project settings.')))
        : await _with(src.target!, (a) async => DbSummary.from(await a.require('summary')));
    log.ok(tr('Preview ready: nothing was changed.'));
    return (before, after);
  }

  /// First installation: every file, then (optionally) a full copy of a database.
  Future<void> install(Project pr, Target t, DbSource? src) => _with(t, (a) => _withSender(t, (s) async {
            log.step(src == null
                ? tr('Installing "{project}" on "{target}" (files only)', {'project': pr.name, 'target': t.name})
                : tr('Installing "{project}" on "{target}" with {source}', {'project': pr.name, 'target': t.name, 'source': src.label}));
            final status = await _status(a, t, s: s);
            if (status['php'] != null && !RegExp(r'^[89]\.').hasMatch('${status['php']}')) log.warn(tr('PHP {v} on the target: check that your project supports it.', {'v': status['php']}));
            final pkg = await _deliverPackage(pr, t, a, s, status);
            log.info(tr('Writing the files…'));
            final w = await a.require('apply_files', {'package': pkg});
            log.ok(tr('{written} file(s) written, {same} already there.', {'written': w['written'], 'same': w['same']}));
            if (t.db.isSet) await _configure(a, t);
            if (src != null) {
              final st = await a.require('status');
              final db = ((st['db'] as Map?) ?? {}).cast<String, dynamic>();
              if (db['ok'] != true) {
                throw AgentError(tr('The target has no database settings ({error}): fill the target database in its settings, or send a .env with "Target files".', {'error': db['error']}));
              }
              final full = (db['tables'] as num? ?? 0) > 0;
              if (full) {
                log.info(tr('Backup of the current target database…'));
                final b = await a.loop('backup', {'db': true, 'files': false}, log.progress);
                log.ok(tr('Backup: {files}.', {'files': (b['files'] as List).join(', ')}));
              }
              final file = await _deliverDb(pr, t, a, s, src);
              log.info(tr('Loading the database on the target…'));
              final i = await a.loop('import_db', {'file': file, 'replace': full}, log.progress);
              log.ok(tr('Database loaded: {tables} tables, {n} statements.', {'tables': i['tables'], 'n': i['statements']}));
              await a.call('delete', {'file': file, 'folder': 'packages'});
              if (src.target == null) {
                final m = await a.require('mark_migrations', {'package': pkg});
                log.detail(tr('{n} migration(s) recorded as applied (the copy is as recent as the local project).', {'n': m['marked']}));
              } else {
                final plan = await a.require('plan', {'package': pkg});
                final mig = ((plan['migrations'] as Map?) ?? {}).cast<String, dynamic>();
                final run = [for (final m in (mig['run'] as List? ?? [])) '${(m as Map)['path']}'];
                final m = await a.call('migrate', {'package': pkg, 'run': run, 'baseline': mig['baseline'] ?? []});
                if (m['ok'] != true) throw AgentError('${m['message']}');
                if (run.isNotEmpty) log.ok(tr('{n} migration(s) run.', {'n': run.length}));
              }
              await _verify(a, pkg);
            }
            await a.call('delete', {'file': pkg, 'folder': 'packages'});
            t.lastAction = tr('Installed {date}', {'date': now()});
            log.ok(tr('Installation done: open {url}/', {'url': t.baseUrl}));
          }));

  Future<void> replaceDb(Project pr, Target t, DbSource src) => _with(t, (a) => _withSender(t, (s) async {
            log.step(tr('Replacing the database of "{name}" with {source}', {'name': t.name, 'source': src.label}));
            await _configure(a, t);
            log.info(tr('Backup of the current target database…'));
            final b = await a.loop('backup', {'db': true, 'files': false}, log.progress);
            final saved = (b['files'] as List).first as String;
            log.ok(tr('Backup: {file}.', {'file': saved}));
            final file = await _deliverDb(pr, t, a, s, src);
            log.info(tr('Loading the database on the target…'));
            try {
              final i = await a.loop('import_db', {'file': file, 'replace': true}, log.progress);
              log.ok(tr('Database replaced: {tables} tables, {n} statements.', {'tables': i['tables'], 'n': i['statements']}));
              await a.call('delete', {'file': file, 'folder': 'packages'});
            } catch (e) {
              throw AgentError('$e\n${tr('The target database may be incomplete: Restore with {file}.', {'file': saved})}');
            }
            t.lastAction = tr('Database replaced {date}', {'date': now()});
          }));

  Future<void> backup(Target t) => _with(t, (a) async {
        log.step(tr('Backup of "{name}" (database and files), kept on the target', {'name': t.name}));
        await _configure(a, t);
        final st = await a.require('status');
        final b = await a.loop('backup', {'db': (st['db'] as Map?)?['ok'] == true, 'files': true}, log.progress);
        final f = (b['files'] as List).cast<String>();
        final z = (b['sizes'] as List? ?? []).cast<num>();
        for (var i = 0; i < f.length; i++) {
          log.ok('${f[i]}${i < z.length ? ' (${_mb(z[i].toInt())})' : ''}');
        }
        log.info(tr('The 6 latest backups of each kind are kept on the target, in its private folder.'));
      });

  Future<List<Map<String, dynamic>>> backups(Target t) => _with(t, (a) async {
        final l = await a.require('list');
        return (l['files'] as List).cast<Map>().map((m) => m.cast<String, dynamic>()).where((m) => m['folder'] == 'backups').toList();
      });

  Future<void> restore(Target t, {String? db, String? files}) => _with(t, (a) async {
        log.step(tr('Restoring "{name}"', {'name': t.name}));
        if (db != null) {
          log.info(tr('Database: {file}…', {'file': db}));
          final i = await a.loop('import_db', {'file': db, 'folder': 'backups', 'replace': true}, log.progress);
          log.ok(tr('Database restored: {tables} tables.', {'tables': i['tables']}));
        }
        if (files != null) {
          log.info(tr('Files: {file}…', {'file': files}));
          final r = await a.require('restore_files', {'file': files});
          log.ok(tr('Files restored: {n}.', {'n': r['files']}));
        }
        t.lastAction = tr('Restored {date}', {'date': now()});
      });
}

/// "table → rows" as the agent or the local database gives it (PHP sends an empty object as []).
Map<String, int> _counts(Object? j) => {if (j is Map) for (final e in j.entries) '${e.key}': (e.value as num).toInt()};
