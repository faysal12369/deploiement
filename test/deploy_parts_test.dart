// Deploying only some parts: the files, the structure (migrations), the data (synced tables). Not shipped with the app.
// Target = C:\xampp8\htdocs\PARTS_DEMO served by the local Apache, databases parts_local / parts_target (all removed at
// the end). The target already has a database the app never tracked (a "legacy" table): the hard case, where migration
// files written without their structure must still run later.
// Run: flutter test test/deploy_parts_test.dart   (Apache and MySQL of C:\xampp8 started)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:deploiement/git.dart';
import 'package:deploiement/models.dart';
import 'package:deploiement/operations.dart';
import 'package:deploiement/results.dart';

const mysqlExe = r'C:\xampp8\mysql\bin\mysql.exe';
final src = Directory(p.join(Directory.systemTemp.path, 'php-deploy-parts'));
const targetDir = r'C:\xampp8\htdocs\PARTS_DEMO';
final remote = Directory(p.join(Directory.systemTemp.path, 'deploiement-parts-remote.git')); // plays GitHub

Future<String> sql(String q, {String db = ''}) async {
  final r = await Process.run(mysqlExe, ['-u', 'root', '-N', '-B', if (db.isNotEmpty) db, '-e', q]);
  if (r.exitCode != 0) throw StateError('${r.stderr}');
  return '${r.stdout}'.trim();
}

void write(String rel, String content) => File(p.join(src.path, rel))
  ..parent.createSync(recursive: true)
  ..writeAsStringSync(content);

String onTarget(String rel) => File(p.join(targetDir, rel)).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('deploy only the files, only the structure, only the data', () async {
    final ops = Operations(AppSettings(), Journal());
    final project = Project(
      id: 'parts',
      name: 'parts-demo',
      folder: src.path,
      keep: ['.env'],
      migrationsFolder: 'database/migrations',
      localDb: DbSettings(name: 'parts_local'),
      sync: [SyncTable(table: 'colors')],
    );
    final target = Target(id: 'parts', name: 'parts', url: 'http://localhost/PARTS_DEMO', transport: Transport.folder, remotePath: targetDir);
    project.targets.add(target);

    // this PC: one migration, two rows to sync
    if (src.existsSync()) src.deleteSync(recursive: true);
    write('index.php', '<?php echo "v1";');
    write('.env', 'DB_HOST=127.0.0.1\nDB_DATABASE=parts_local\nDB_USERNAME=root\nDB_PASSWORD=\n');
    write('database/migrations/001_colors.sql', 'CREATE TABLE colors (id INT AUTO_INCREMENT PRIMARY KEY, code VARCHAR(10) NOT NULL UNIQUE, name VARCHAR(40) NOT NULL);\n');
    await sql('DROP DATABASE IF EXISTS parts_local; CREATE DATABASE parts_local; DROP DATABASE IF EXISTS parts_target; CREATE DATABASE parts_target;');
    await sql(File(p.join(src.path, 'database', 'migrations', '001_colors.sql')).readAsStringSync(), db: 'parts_local');
    await sql("INSERT INTO colors (code, name) VALUES ('R', 'Red'), ('G', 'Green');", db: 'parts_local');

    // the target: a server with its own .env and a database the app never deployed (not empty, not tracked)
    final td = Directory(targetDir);
    if (td.existsSync()) td.deleteSync(recursive: true);
    td.createSync();
    File(p.join(targetDir, '.env')).writeAsStringSync('DB_HOST=127.0.0.1\nDB_DATABASE=parts_target\nDB_USERNAME=root\nDB_PASSWORD=\n');
    await sql('CREATE TABLE legacy (id INT PRIMARY KEY);', db: 'parts_target');
    final tables = 'SELECT GROUP_CONCAT(TABLE_NAME ORDER BY TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_SCHEMA = "parts_target"';

    try {
      await ops.placeAgent(target);

      // ---- 1. files only: written, but no table created and no row synced
      final r1 = await ops.deploy(project, target, parts: const DeployParts(structure: false, data: false));
      expect(r1.ok, true);
      expect(onTarget('index.php'), contains('v1'));
      expect(File(p.join(targetDir, 'database', 'migrations', '001_colors.sql')).existsSync(), true);
      expect((await sql(tables)).split(',')..sort(), ['_deploy_migrations', 'legacy'], reason: 'no colors table: the structure was not chosen');
      expect(r1.migrations, isEmpty);
      expect(r1.sync, isEmpty);
      expect(r1.backups.where((b) => b.startsWith('db-')), isNotEmpty, reason: 'the database is backed up anyway');

      // ---- 2. the migration written with the files is still to run (not taken for an applied one)
      final s2 = await ops.simulate(project, target);
      expect(s2.migrations.map((m) => p.basename(m.$1)), ['001_colors.sql']);
      expect(s2.baseline, isEmpty);

      // ---- 3. structure only: the table, no rows, the new local file not sent
      write('index.php', '<?php echo "v2";');
      final r3 = await ops.deploy(project, target, parts: const DeployParts(files: false, data: false));
      expect(r3.migrations.map((m) => m.$1), ['001_colors.sql']);
      expect(r3.written, 0);
      expect(r3.backups.where((b) => b.startsWith('files-')), isEmpty, reason: 'files not sent: not backed up');
      expect(await sql('SELECT COUNT(*) FROM colors', db: 'parts_target'), '0');
      expect(onTarget('index.php'), contains('v1'));

      // ---- 4. data only: the rows, still the old file
      final r4 = await ops.deploy(project, target, parts: const DeployParts(files: false, structure: false));
      expect(r4.rowsAdded, 2);
      expect(await sql("SELECT GROUP_CONCAT(name ORDER BY code) FROM colors", db: 'parts_target'), 'Green,Red');
      expect(onTarget('index.php'), contains('v1'));

      // ---- 5. everything: the new file; nothing else left to do
      final r5 = await ops.deploy(project, target);
      expect(r5.written, 1);
      expect(onTarget('index.php'), contains('v2'));
      expect((await ops.simulate(project, target)).upToDate, true);

      // ---- the history keeps what each deployment sent; older entries count as "everything"
      final back = DeployResult.fromJson(r3.toJson());
      expect([back.parts.files, back.parts.structure, back.parts.data], [false, true, false]);
      expect(back.parts.label, 'Structure');
      expect(DeployResult.fromJson({'time': '2026-11-01T10:00:00'}).parts.all, true);

      // ---- 6. with the GitHub box: after the deployment, the code goes to the project's branch (a bare repository
      // in a temporary folder plays GitHub)
      final g = Git(src.path);
      await g.create(branch: 'main', ignore: [...project.exclude, ...project.keep]);
      await Process.run('git', ['init', '--bare', '-q', remote.path]);
      await g.link(remote.path);
      project
        ..gitRemote = remote.path
        ..gitBranch = 'deploy/parts';
      write('index.php', '<?php echo "v3";');
      final r6 = await ops.deploy(project, target, parts: const DeployParts(github: true));
      expect(r6.ok, true);
      expect(onTarget('index.php'), contains('v3'));
      expect(r6.git, startsWith('deploy/parts '));
      expect(r6.gitError, isEmpty);
      final log = await Process.run('git', ['--git-dir', remote.path, 'log', '-1', '--format=%s', 'deploy/parts']);
      expect('${log.stdout}'.trim(), startsWith('Deployed to "parts"'));
      final files = await Process.run('git', ['--git-dir', remote.path, 'ls-tree', '-r', '--name-only', 'deploy/parts']);
      expect('${files.stdout}', isNot(contains('.env')), reason: 'kept files never go to GitHub');

      // ---- 7. GitHub refuses (no such repository): the deployment still goes through, the result says why
      project.gitRemote = p.join(Directory.systemTemp.path, 'no-such-repository.git');
      await g.link(project.gitRemote);
      write('index.php', '<?php echo "v4";');
      final r7 = await ops.deploy(project, target, parts: const DeployParts(github: true));
      expect(r7.ok, true);
      expect(onTarget('index.php'), contains('v4'));
      expect(r7.git, isEmpty);
      expect(r7.gitError, isNotEmpty);
    } finally {
      await sql('DROP DATABASE IF EXISTS parts_local; DROP DATABASE IF EXISTS parts_target;');
      if (td.existsSync()) td.deleteSync(recursive: true);
      if (src.existsSync()) src.deleteSync(recursive: true);
      if (remote.existsSync()) remote.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
