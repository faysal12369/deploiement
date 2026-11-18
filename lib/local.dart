// Tools on this PC: finding php.exe, matching file patterns, and running the agent in CLI mode against the local
// database (schema, sync export, full dump, summary). Only PHP is needed — no mysqldump, no project script.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import 'agent_client.dart';
import 'i18n.dart';
import 'models.dart';

/// gitignore-like pattern → RegExp (same rules as dpGlob() in the agent):
/// "storage/" a folder at any depth, "*.log" by name, "config/app.local.php" from the root, "/build/" root only.
RegExp globToRegExp(String pattern) {
  var g = pattern.trim().replaceAll('\\', '/');
  final anchored = g.startsWith('/');
  g = g.replaceFirst(RegExp(r'^/+'), '');
  final dir = g.endsWith('/');
  g = g.replaceFirst(RegExp(r'/+$'), '');
  final b = StringBuffer();
  for (var i = 0; i < g.length; i++) {
    final c = g[i];
    if (c == '*' && i + 1 < g.length && g[i + 1] == '*') {
      b.write('.*');
      i++;
      if (i + 1 < g.length && g[i + 1] == '/') i++;
    } else if (c == '*') {
      b.write('[^/]*');
    } else if (c == '?') {
      b.write('[^/]');
    } else {
      b.write(RegExp.escape(c));
    }
  }
  final start = (anchored || g.contains('/')) ? '^' : '(^|/)';
  return RegExp('$start$b${dir ? '/' : r'(/|$)'}', caseSensitive: false);
}

class Patterns {
  Patterns(Iterable<String> patterns) : _res = patterns.where((x) => x.trim().isNotEmpty).map(globToRegExp).toList();
  final List<RegExp> _res;
  bool matches(String rel) => _res.any((r) => r.hasMatch(rel));
}

class Local {
  Local(this.settings);
  final AppSettings settings;

  /// php.exe: the one in the settings, else PATH, XAMPP, Laragon, WampServer.
  Future<String> php() async {
    if (settings.phpPath.isNotEmpty && await File(settings.phpPath).exists()) return settings.phpPath;
    final w = await Process.run('where', ['php']);
    if (w.exitCode == 0) {
      final first = '${w.stdout}'.split(RegExp(r'\r?\n')).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
      if (first.isNotEmpty) return first.trim();
    }
    final candidates = <String>[];
    for (final drive in ['C:', 'D:']) {
      for (final x in ['xampp8', 'xampp']) {
        candidates.add('$drive\\$x\\php\\php.exe');
      }
      for (final base in ['$drive\\laragon\\bin\\php', '$drive\\wamp64\\bin\\php', '$drive\\wamp\\bin\\php']) {
        final d = Directory(base);
        if (await d.exists()) {
          final subs = await d.list().where((e) => e is Directory).map((e) => e.path).toList()..sort();
          candidates.addAll(subs.reversed.map((s) => p.join(s, 'php.exe')));
        }
      }
    }
    for (final c in candidates) {
      if (await File(c).exists()) return c;
    }
    throw AgentError(tr('PHP was not found on this PC: set the path of php.exe in Settings.'));
  }

  /// The agent for the CLI, named after its content: written once, complete (two runs at the same time never read a
  /// file the other is still writing).
  Future<File> _agentFile() async {
    final code = await rootBundle.loadString('assets/agent/deploy-agent.php');
    final f = File(p.join(Store.work.path, 'deploy-agent-cli-${sha1.convert(utf8.encode(code)).toString().substring(0, 10)}.php'));
    if (!await f.exists()) {
      final tmp = File('${f.path}.${randomHex(4)}.tmp');
      await tmp.writeAsString(code);
      try {
        await tmp.rename(f.path);
      } catch (_) {
        if (await tmp.exists()) await tmp.delete(); // another run wrote it meanwhile
      }
      // the copies of former versions
      for (final old in Store.work.listSync().whereType<File>()) {
        final b = p.basename(old.path);
        if (b.startsWith('deploy-agent-cli') && b.endsWith('.php') && old.path != f.path) {
          try {
            old.deleteSync();
          } catch (_) {}
        }
      }
    }
    return f;
  }

  /// Runs the agent in CLI mode; [config] carries the local database ("db") and the action's options.
  Future<File> cli(String action, Map<String, dynamic> config, String outName) async {
    final php = await this.php();
    final agent = await _agentFile();
    final cfg = File(p.join(Store.work.path, 'cli-${randomHex(4)}.json'));
    await cfg.writeAsString(jsonEncode(config));
    final out = File(p.join(Store.work.path, outName));
    try {
      final r = await Process.run(php, [agent.path, 'cli', action, cfg.path, out.path]);
      if (r.exitCode != 0) {
        throw AgentError('${tr('Local database')}: ${'${r.stderr}${r.stdout}'.trim()}');
      }
      return out;
    } finally {
      if (await cfg.exists()) await cfg.delete();
    }
  }

  Future<Map<String, dynamic>> summary(DbSettings db) async {
    final f = await cli('summary', {'db': db.toAgent()}, 'summary-${randomHex(4)}.json');
    try {
      return (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>();
    } finally {
      await f.delete();
    }
  }

  /// Exact number of rows of every table of a database of this PC, and the tables whose rows cannot be recognised
  /// from one database to the other (no unique index besides a counter).
  Future<(Map<String, int>, Set<String>)> counts(DbSettings db) async {
    final f = await cli('counts', {'db': db.toAgent()}, 'counts-${randomHex(4)}.json');
    try {
      final j = jsonDecode(await f.readAsString()) as Map;
      final t = j['tables'];
      return (
        {if (t is Map) for (final e in t.entries) '${e.key}': (e.value as num).toInt()},
        {for (final x in (j['nokey'] as List? ?? [])) '$x'},
      );
    } finally {
      await f.delete();
    }
  }

  /// SQL typed in the app, run on a database of this PC: one result per statement (see SqlOutcome).
  Future<List<Map<String, dynamic>>> sql(DbSettings db, String sql) async {
    final f = await cli('sql', {'db': db.toAgent(), 'sql': sql}, 'sql-${randomHex(4)}.json');
    try {
      return [for (final x in ((jsonDecode(await f.readAsString()) as Map)['results'] as List? ?? [])) (x as Map).cast<String, dynamic>()];
    } finally {
      await f.delete();
    }
  }

  /// A full copy of the local database (structure + rows), gzip-compressed.
  Future<File> dump(DbSettings db) => cli('dump', {'db': db.toAgent()}, 'db-local-${DateTime.now().millisecondsSinceEpoch}.sql.gz');

  /// Loads a dump (.sql or .sql.gz) into a database of this PC, created when missing. Refused when it has tables,
  /// unless [replace]. Returns the number of tables.
  Future<int> importDump(DbSettings db, File dump, {bool replace = false}) async {
    final f = await cli('import', {'db': db.toAgent(), 'file': dump.path, 'replace': replace}, 'import-${randomHex(4)}.json');
    try {
      return ((jsonDecode(await f.readAsString()) as Map)['tables'] as num?)?.toInt() ?? 0;
    } finally {
      await f.delete();
    }
  }

  /// Number of tables of a database of this PC; null when it does not exist (or cannot be reached).
  Future<int?> tableCount(DbSettings db) async {
    try {
      return ((await summary(db))['tables'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  /// Columns of every table (type, null, key, default, extra).
  Future<Map<String, dynamic>> structure(DbSettings db) async {
    final f = await cli('structure', {'db': db.toAgent()}, 'structure-${randomHex(4)}.json');
    try {
      return ((jsonDecode(await f.readAsString()) as Map)['tables'] as Map? ?? {}).cast<String, dynamic>();
    } finally {
      await f.delete();
    }
  }

  /// The structure as SQL (CREATE TABLE / VIEW), first line "-- Server version: …".
  Future<String> schemaSql(DbSettings db) async {
    final f = await cli('schema_sql', {'db': db.toAgent()}, 'schema-${randomHex(4)}.sql');
    try {
      return await f.readAsString();
    } finally {
      await f.delete();
    }
  }

  /// Rows of each table recognised by their key ([options]: count_only, keys) — see dpInventory() in the agent.
  Future<Map<String, dynamic>> inventory(DbSettings db, Map<String, dynamic> options) async {
    final f = await cli('inventory', {'db': db.toAgent(), ...options}, 'inventory-${randomHex(4)}.json');
    try {
      return (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>();
    } finally {
      await f.delete();
    }
  }

  Future<List<String>> tables(DbSettings db) async {
    final f = await cli('schema', {'db': db.toAgent()}, 'schema-${randomHex(4)}.json');
    try {
      final j = jsonDecode(await f.readAsString()) as Map;
      return ((j['tables'] as Map?) ?? {}).keys.map((k) => '$k').toList()..sort();
    } finally {
      await f.delete();
    }
  }
}
