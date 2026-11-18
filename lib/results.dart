// What a simulation compares and what a deployment did: the structure of both databases side by side, and the
// result of each deployment, kept as a history per target (history.json next to the settings).
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'i18n.dart';
import 'models.dart';
import 'operations.dart';

/// table → column → {type, null, key, default, extra}, as the agent's "structure" gives it.
typedef Structure = Map<String, Map<String, Map<String, dynamic>>>;

/// (PHP sends an empty array as [], not {}.)
Structure structureFrom(Object? j) => {
      if (j is Map)
        for (final e in j.entries)
          '${e.key}': {
            if (e.value is Map)
              for (final c in (e.value as Map).entries) '${c.key}': c.value is Map ? (c.value as Map).cast<String, dynamic>() : <String, dynamic>{},
          },
    };

enum Diff { same, missing, extra, differs } // missing: on this PC, not on the target; extra: only on the target

class ColumnCompare {
  ColumnCompare(this.name, this.local, this.target);
  final String name;
  final Map<String, dynamic>? local, target;
  Diff get state => target == null ? Diff.missing : (local == null ? Diff.extra : (describe(local) == describe(target) ? Diff.same : Diff.differs));

  /// "int(10) unsigned NOT NULL PRI auto_increment = 0"
  static String describe(Map<String, dynamic>? c) {
    if (c == null) return '—';
    final def = c['default'];
    return [
      '${c['type']}',
      if (c['null'] != true) 'NOT NULL',
      if ('${c['key'] ?? ''}'.isNotEmpty) '${c['key']}',
      if ('${c['extra'] ?? ''}'.isNotEmpty) '${c['extra']}',
      if (def != null && '$def' != 'NULL') '= $def',
    ].join(' ');
  }
}

class TableCompare {
  TableCompare(this.table, this.columns, {required this.onLocal, required this.onTarget});
  final String table;
  final List<ColumnCompare> columns;
  final bool onLocal, onTarget;
  Diff get state => !onTarget ? Diff.missing : (!onLocal ? Diff.extra : (columns.every((c) => c.state == Diff.same) ? Diff.same : Diff.differs));
  int count(Diff d) => columns.where((c) => c.state == d).length;
}

/// Every table of both sides; the ones that differ first, then by name.
List<TableCompare> compareStructures(Structure local, Structure target) {
  final names = {...local.keys, ...target.keys}.toList()..sort();
  final out = [
    for (final t in names)
      TableCompare(
        t,
        [
          for (final c in {...?local[t]?.keys, ...?target[t]?.keys}) ColumnCompare(c, local[t]?[c], target[t]?[c]),
        ],
        onLocal: local.containsKey(t),
        onTarget: target.containsKey(t),
      ),
  ];
  out.sort((a, b) => (a.state == Diff.same ? 1 : 0).compareTo(b.state == Diff.same ? 1 : 0));
  return out;
}

/// One table whose structure is followed (the "Structure" box of the project's tables, agent 7): what makes it like
/// this PC's — created, columns added, columns changed, indexes added. Nothing is ever removed on the target.
class TableChange {
  TableChange(this.table, {this.create = false, this.changes = const [], this.kept = const [], this.done = 0, this.error});
  final String table;
  final bool create; // the table was not on the target
  final List<({String what, String name, String sql, String before, String after})> changes;
  final List<String> kept; // columns only on the target: they stay
  final int done; // changes made (a deployment)
  final String? error;

  int count(String what) => changes.where((c) => c.what == what).length;

  factory TableChange.from(Map<String, dynamic> j) => TableChange(
        '${j['table'] ?? ''}',
        create: j['create'] == true,
        changes: [
          for (final c in (j['changes'] as List? ?? []))
            if (c is Map)
              (what: '${c['what'] ?? ''}', name: '${c['name'] ?? ''}', sql: '${c['sql'] ?? ''}', before: '${c['before'] ?? ''}', after: '${c['after'] ?? ''}'),
        ],
        kept: [for (final k in (j['kept_columns'] as List? ?? [])) '$k'],
        done: (j['done'] as num?)?.toInt() ?? 0,
        error: j['error'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'table': table, 'create': create, 'kept_columns': kept, 'done': done, if (error != null) 'error': error,
        'changes': [for (final c in changes) {'what': c.what, 'name': c.name, 'sql': c.sql, 'before': c.before, 'after': c.after}],
      };
}

/// What one deployment did. Saved even when it failed (with where it stopped).
/// What a deployment sends: the files, the structure (the migrations), the data (the synced tables). All by default.
class DeployParts {
  const DeployParts({this.files = true, this.structure = true, this.data = true, this.github = false});
  final bool files, structure, data;
  final bool github; // after the deployment, the code is committed and sent to the project's GitHub branch
  bool get all => files && structure && data;

  /// "Files + Structure + Data", only the chosen ones.
  String get label => [if (files) tr('Files'), if (structure) tr('Structure'), if (data) tr('Data'), if (github) 'GitHub'].join(' + ');

  Map<String, dynamic> toJson() => {'files': files, 'structure': structure, 'data': data, 'github': github};

  /// Deployments kept from before the choice existed sent everything.
  factory DeployParts.fromJson(Object? j) =>
      j is Map ? DeployParts(files: j['files'] != false, structure: j['structure'] != false, data: j['data'] != false, github: j['github'] == true) : const DeployParts();
}

class DeployResult {
  DeployResult({required this.time, required this.project, required this.target});
  final DateTime time;
  final String project, target;
  double seconds = 0;
  bool ok = false;
  String? error;
  String label = '';
  List<String> newFiles = [], changedFiles = [], removedFiles = [];
  int written = 0, removed = 0, same = 0;
  List<(String, int)> migrations = []; // file, statements
  int baseline = 0;
  List<SyncResult> sync = [];
  List<TableChange> tables = []; // structure of the chosen tables
  List<String> backups = [];
  int missingAfter = 0; // tables / columns still missing in the target database after the migrations
  DeployParts parts = const DeployParts();
  String git = ''; // "branch commit" sent to GitHub
  String gitError = ''; // why it was not (the deployment itself went through)

  int get rowsAdded => sync.fold(0, (s, r) => s + r.added + r.pending);
  int get rowsUpdated => sync.fold(0, (s, r) => s + r.updated);

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(), 'project': project, 'target': target, 'seconds': seconds, 'ok': ok, 'error': error, 'label': label,
        'new': newFiles.take(500).toList(), 'changed': changedFiles.take(500).toList(), 'removed_files': removedFiles.take(500).toList(),
        'written': written, 'removed': removed, 'same': same,
        'migrations': [for (final (n, s) in migrations) [n, s]], 'baseline': baseline,
        'sync': [for (final s in sync) s.toJson(maxRows: 50)], 'backups': backups, 'missing_after': missingAfter,
        'tables': [for (final t in tables) t.toJson()],
        'parts': parts.toJson(), 'git': git, 'git_error': gitError,
      };

  factory DeployResult.fromJson(Map<String, dynamic> j) {
    List<String> l(String k) => ((j[k] as List?) ?? []).map((x) => '$x').toList();
    return DeployResult(time: DateTime.tryParse('${j['time']}') ?? DateTime(2000), project: '${j['project'] ?? ''}', target: '${j['target'] ?? ''}')
      ..seconds = (j['seconds'] as num?)?.toDouble() ?? 0
      ..ok = j['ok'] == true
      ..error = j['error'] as String?
      ..label = '${j['label'] ?? ''}'
      ..newFiles = l('new')
      ..changedFiles = l('changed')
      ..removedFiles = l('removed_files')
      ..written = (j['written'] as num?)?.toInt() ?? 0
      ..removed = (j['removed'] as num?)?.toInt() ?? 0
      ..same = (j['same'] as num?)?.toInt() ?? 0
      ..migrations = [for (final m in (j['migrations'] as List? ?? [])) ('${(m as List)[0]}', (m[1] as num).toInt())]
      ..baseline = (j['baseline'] as num?)?.toInt() ?? 0
      ..sync = [for (final s in (j['sync'] as List? ?? [])) SyncResult.from((s as Map).cast<String, dynamic>())]
      ..backups = l('backups')
      ..missingAfter = (j['missing_after'] as num?)?.toInt() ?? 0
      ..tables = [for (final t in (j['tables'] as List? ?? [])) TableChange.from((t as Map).cast<String, dynamic>())]
      ..parts = DeployParts.fromJson(j['parts'])
      ..git = '${j['git'] ?? ''}'
      ..gitError = '${j['git_error'] ?? ''}';
  }
}

/// The last deployments of each target (30 kept per target), newest first.
class History {
  static File get _file => File(p.join(Store.folder, 'history.json'));

  static Map<String, List<DeployResult>> load() {
    try {
      if (!_file.existsSync()) return {};
      final j = (jsonDecode(_file.readAsStringSync()) as Map).cast<String, dynamic>();
      return {
        for (final e in j.entries) e.key: [for (final r in (e.value as List)) DeployResult.fromJson((r as Map).cast<String, dynamic>())],
      };
    } catch (_) {
      return {};
    }
  }

  static void save(Map<String, List<DeployResult>> all) {
    Directory(Store.folder).createSync(recursive: true);
    final tmp = File('${_file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode({for (final e in all.entries) e.key: [for (final r in e.value.take(30)) r.toJson()]}));
    tmp.renameSync(_file.path);
  }
}

// ---------------------------------------------------------------------------------------------------------------------
//  Comparing the data of two databases (this PC and a target), matched by key
// ---------------------------------------------------------------------------------------------------------------------

/// One table of an inventory: its rows, its key and the key of each row with a label ("ADMIN — Administrator").
class InvTable {
  InvTable.from(Map<String, dynamic> j)
      : rows = (j['rows'] as num?)?.toInt() ?? 0,
        key = [for (final k in (j['key'] as List? ?? [])) '$k'],
        keyFrom = {if (j['keyFrom'] is Map) for (final e in (j['keyFrom'] as Map).entries) '${e.key}': '${e.value}'},
        countOnly = j['countOnly'] == true,
        noKey = (j['noKey'] as num?)?.toInt() ?? 0,
        truncated = j['truncated'] == true,
        values = {
          for (final v in (j['values'] as List? ?? []))
            if (v is List && v.length == 2) '${v[0]}': '${v[1]}',
        };
  final int rows;
  final List<String> key;
  final Map<String, String> keyFrom; // key column → table it is read in (the id is replaced by that row's key)
  final bool countOnly, truncated;
  final int noKey; // rows without a value in a key column: counted only
  final Map<String, String> values; // key (lower case) → label
}

/// What the agent's "inventory" gives (PHP sends an empty object as []).
class Inventory {
  Inventory.from(Map<String, dynamic> j)
      : server = '${j['server'] ?? ''}',
        database = '${j['database'] ?? ''}',
        host = '${j['host'] ?? ''}',
        time = '${j['time'] ?? ''}',
        tables = {
          if (j['tables'] is Map)
            for (final e in (j['tables'] as Map).entries)
              if (e.value is Map) '${e.key}': InvTable.from((e.value as Map).cast<String, dynamic>()),
        };
  final String server, database, host, time;
  final Map<String, InvTable> tables;
  int get rows => tables.values.fold(0, (a, t) => a + t.rows);
}

/// The groups of the comparison, in the order they are shown (most useful first).
enum DataRank { oneSide, missingOnTarget, fewerOnTarget, extraOnTarget, same, countOnly }

class DataCompare {
  DataCompare(this.table, this.pc, this.target);
  final String table;
  final InvTable? pc, target;

  bool get countOnly => (pc?.countOnly ?? false) || (target?.countOnly ?? false);

  /// Row by row only when both sides read the same key the same way (ids translated alike) and read all their rows.
  late final bool byKey = pc != null &&
      target != null &&
      pc!.key.isNotEmpty &&
      pc!.key.join('\u0000') == target!.key.join('\u0000') &&
      !countOnly &&
      _sameMap(pc!.keyFrom, target!.keyFrom) &&
      !pc!.truncated &&
      !target!.truncated;

  /// Rows of this PC the target does not have (labels), and the reverse.
  late final List<String> onlyPc = byKey ? [for (final e in pc!.values.entries) if (!target!.values.containsKey(e.key)) e.value] : const [];
  late final List<String> onlyTarget = byKey ? [for (final e in target!.values.entries) if (!pc!.values.containsKey(e.key)) e.value] : const [];

  DataRank get rank {
    if (pc == null || target == null) return DataRank.oneSide;
    if (countOnly) return DataRank.countOnly;
    if (onlyPc.isNotEmpty) return DataRank.missingOnTarget;
    if (!byKey && pc!.rows > target!.rows) return DataRank.fewerOnTarget;
    if (onlyTarget.isNotEmpty || pc!.rows != target!.rows) return DataRank.extraOnTarget;
    return DataRank.same;
  }

  /// "role_id (read in roles) + permission_id (read in permissions)"
  String get keyText {
    final k = (pc ?? target)!;
    return k.key.map((c) => k.keyFrom[c] == null ? c : '$c (${k.keyFrom[c]})').join(' + ');
  }

  static bool _sameMap(Map<String, String> a, Map<String, String> b) => a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
}

/// Every table of both sides, grouped by [DataRank], the most rows missing on the target first.
List<DataCompare> compareData(Inventory pc, Inventory target) {
  final names = {...pc.tables.keys, ...target.tables.keys};
  final out = [for (final t in names) DataCompare(t, pc.tables[t], target.tables[t])];
  out.sort((a, b) {
    final r = a.rank.index.compareTo(b.rank.index);
    if (r != 0) return r;
    final m = b.onlyPc.length.compareTo(a.onlyPc.length);
    return m != 0 ? m : a.table.compareTo(b.table);
  });
  return out;
}

/// A comparison of the databases of this PC and of a target: data row by row, and the structure as SQL for the
/// Delta Schéma tool (written next to the reports, opened in the browser).
class DbCompare {
  DbCompare({required this.time, required this.pc, required this.target, required this.pcSql, required this.targetSql, required this.deltaPage})
      : tables = compareData(pc, target);
  final DateTime time;
  final Inventory pc, target;
  final String pcSql, targetSql;
  final File deltaPage;
  final List<DataCompare> tables;
  int count(DataRank r) => tables.where((t) => t.rank == r).length;
  /// Tables whose rows of this PC are not all on the target (the first three groups).
  int get withMissing => tables.where((t) => t.rank.index <= DataRank.fewerOnTarget.index).length;
}
