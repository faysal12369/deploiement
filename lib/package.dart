// A release package, built on this PC for one target: the project's files (minus "exclude" and "keep" patterns) plus
// the target's own files, and in __deploy/:
//   manifest.json  SHA-1 of every file, keep patterns, migrations, forced files
//   schema.json    tables and columns of the local database (to check the target after the migrations)
//   sync.ndjson    rows of the tables whose data is sent, one line each (see dpSyncExport in the agent)
//   tables.json    CREATE TABLE of the tables whose structure is followed (see dpTablesApply in the agent)
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'agent_client.dart';
import 'i18n.dart';
import 'local.dart';
import 'models.dart';

class PackageBuilder {
  PackageBuilder(this.settings, this.project, this.target);
  final AppSettings settings;
  final Project project;
  final Target target;

  static String stamp() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}-${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  static int naturalOrder(String a, String b) {
    final re = RegExp(r'(\d+)|(\D+)');
    final ma = re.allMatches(a).toList(), mb = re.allMatches(b).toList();
    for (var i = 0; i < ma.length && i < mb.length; i++) {
      final x = ma[i][0]!, y = mb[i][0]!;
      final nx = int.tryParse(x), ny = int.tryParse(y);
      final c = (nx != null && ny != null) ? nx.compareTo(ny) : x.compareTo(y);
      if (c != 0) return c;
    }
    return ma.length.compareTo(mb.length);
  }

  void _cleanup() {
    final old = Store.work.listSync().whereType<File>().where((f) => p.basename(f.path).startsWith('release-')).toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final f in old.skip(4)) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }

  /// Where a file of the package comes from on this PC: a file of this target only, or the project folder.
  static String localPathOf(Project project, Target target, String rel) {
    for (final tf in target.files) {
      if (tf.remote.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '') == rel) {
        return p.isAbsolute(tf.local) ? tf.local : p.join(project.folder, tf.local);
      }
    }
    return p.join(project.folder, rel.replaceAll('/', p.separator));
  }

  /// Every file that a release carries, with its SHA-1 (nothing is zipped yet).
  Future<ProjectScan> scan(Progress progress) async {
    final root = Directory(project.folder);
    if (!await root.exists()) throw AgentError(tr('Project folder not found: {path}', {'path': project.folder}));
    final skip = Patterns([...project.exclude, ...project.keep, '.deploy/', 'deploy-agent*.php']);
    // The sources of the "files of a target only" (config.hostinger.php → config.php…) hold one target's settings:
    // they are sent only as that file, to that target — never as themselves, to any target.
    final ownSources = {
      for (final t in project.targets)
        for (final tf in t.files)
          if (tf.local.trim().isNotEmpty)
            p.relative(p.isAbsolute(tf.local) ? tf.local : p.join(project.folder, tf.local), from: project.folder).replaceAll('\\', '/').toLowerCase(),
    };
    final migFolder = project.migrationsFolder.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '');
    final migSkip = Patterns([project.migrationsSkip]);
    progress(tr('Reading the project files…'));
    final scan = ProjectScan(migFolder);
    var n = 0;
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = p.relative(e.path, from: root.path).replaceAll('\\', '/');
      if (skip.matches(rel) || ownSources.contains(rel.toLowerCase())) continue;
      scan.files[rel] = sha1.convert(await e.readAsBytes()).toString();
      scan.sources[rel] = e.path;
      if (migFolder.isNotEmpty && p.posix.dirname(rel) == migFolder && rel.toLowerCase().endsWith('.sql') && !migSkip.matches(p.posix.basename(rel))) {
        scan.migrations.add(rel);
      }
      if (++n % 250 == 0) progress(tr('Reading the project files… {n}', {'n': n}));
    }
    scan.migrations.sort((a, b) => naturalOrder(p.posix.basename(a), p.posix.basename(b)));
    // The target's own files (".env.production" → ".env"): written even when a keep pattern covers them.
    for (final tf in target.files) {
      final src = File(p.isAbsolute(tf.local) ? tf.local : p.join(project.folder, tf.local));
      if (!await src.exists()) throw AgentError(tr('Target file not found on this PC: {path}', {'path': src.path}));
      final rel = tf.remote.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
      scan.files[rel] = sha1.convert(await src.readAsBytes()).toString();
      scan.sources[rel] = src.path;
      scan.force.add(rel);
    }
    return scan;
  }

  /// The package. [only]: the files that differ on the target (the others are listed in the manifest, not sent);
  /// migrations are always carried, the agent runs them from the package.
  Future<File> build(Progress progress, {ProjectScan? scan, Set<String>? only}) async {
    final sc = scan ?? await this.scan(progress);
    final id = '${stamp()}-${randomHex(3)}'; // unique even for two builds in the same second
    final zipPath = p.join(Store.work.path, 'release-$id.zip');
    final zip = ZipFileEncoder()..create(zipPath);
    var sent = 0;
    for (final MapEntry(key: rel, value: src) in sc.sources.entries) {
      if (only != null && !only.contains(rel) && !sc.migrations.contains(rel)) continue;
      zip.addArchiveFile(ArchiveFile.bytes(rel, await File(src).readAsBytes()));
      sent++;
    }

    var hasSchema = false, hasSync = false;
    if (project.localDb.isSet) {
      final local = Local(settings);
      progress(tr('Local database structure…'));
      final schema = await local.cli('schema', {'db': project.localDb.toAgent()}, 'schema-$id.json');
      await zip.addFile(schema, '__deploy/schema.json');
      hasSchema = true;
      final data = project.dataTables, structure = project.structureTables;
      if (data.isNotEmpty) {
        progress(tr('Rows of the synced tables…'));
        final sync = await local.cli('sync_export', {'db': project.localDb.toAgent(), 'tables': data.map((s) => s.toJson()).toList()}, 'sync-$id.ndjson');
        await zip.addFile(sync, '__deploy/sync.ndjson');
        hasSync = true;
      }
      if (structure.isNotEmpty) {
        progress(tr('Structure of the chosen tables…'));
        final ddl = await local.cli('tables_ddl', {'db': project.localDb.toAgent(), 'tables': [for (final s in structure) s.table]}, 'tables-$id.json');
        await zip.addFile(ddl, '__deploy/tables.json');
      }
    }
    final d = DateTime.now();
    String two(int x) => x.toString().padLeft(2, '0');
    zip.addArchiveFile(ArchiveFile.string(
        '__deploy/manifest.json',
        jsonEncode({
          'format': 2,
          'project': project.name,
          'label': '${project.name} ${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}',
          'date': d.toIso8601String().substring(0, 19).replaceFirst('T', ' '),
          'source': Platform.localHostname,
          'files': sc.files,
          'partial': only != null,
          'keep': project.keep,
          'force': sc.force,
          'migrations': {
            'folder': sc.migFolder,
            'rerun_changed': project.rerunChangedMigrations,
            'files': [for (final m in sc.migrations) {'path': m, 'sha1': sc.files[m]}],
          },
          'schema': hasSchema,
          'sync': hasSync,
        })));
    await zip.close();
    for (final f in Store.work.listSync().whereType<File>()) {
      final b = p.basename(f.path);
      if (b == 'schema-$id.json' || b == 'sync-$id.ndjson' || b == 'tables-$id.json') f.deleteSync();
    }
    _cleanup();
    final f = File(zipPath);
    progress(tr('Package ready: {n} files, {mb} MB.', {'n': sent, 'mb': (await f.length() / 1048576).toStringAsFixed(1)}));
    return f;
  }
}

/// The files of a release on this PC: SHA-1 and path of each, migrations in run order, files of the target only.
class ProjectScan {
  ProjectScan(this.migFolder);
  final String migFolder;
  final files = <String, String>{}; // relative path → SHA-1
  final sources = <String, String>{}; // relative path → file on this PC
  final migrations = <String>[];
  final force = <String>[];
}
