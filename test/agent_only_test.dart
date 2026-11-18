// "Agent only": no FTP, no shared folder — the agent is copied by hand into the project folder of the target, then
// everything goes over the web (packages uploaded to the agent in 2 MB pieces). This is how a Windows server that only
// answers on http (no FTP, no share) is deployed. Target: C:\xampp8\htdocs\AGENT_ONLY served by the local Apache,
// database agent_only_target. Run: flutter test test/agent_only_test.dart   (Apache and MySQL started)
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:deploiement/diff.dart';
import 'package:deploiement/diff_view.dart';
import 'package:deploiement/models.dart';
import 'package:deploiement/operations.dart';
import 'package:deploiement/report_html.dart';

const mysqlExe = r'C:\xampp8\mysql\bin\mysql.exe';
const targetDir = r'C:\xampp8\htdocs\AGENT_ONLY';
const cloneDir = r'C:\xampp8\htdocs\AGENT_ONLY_CLONE';
final src = Directory(p.join(Directory.systemTemp.path, 'php-deploy-agent-only'));

Future<String> sql(String q, {String db = ''}) async {
  final r = await Process.run(mysqlExe, ['-u', 'root', '-N', '-B', if (db.isNotEmpty) db, '-e', q]);
  if (r.exitCode != 0) throw StateError('${r.stderr}');
  return '${r.stdout}'.trim();
}

void write(String rel, String content) => File(p.join(src.path, rel))
  ..parent.createSync(recursive: true)
  ..writeAsStringSync(content);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('agent only: agent copied by hand, then install, simulate, deploy, backup, restore over http', () async {
    final log = Journal();
    final ops = Operations(AppSettings(), log);
    final project = Project(id: 'ao', name: 'agent-only-demo', folder: src.path, keep: ['.env', 'uploads/'], migrationsFolder: 'migrations');
    final t = Target(id: 'srv', name: 'server', url: 'http://localhost/AGENT_ONLY', transport: Transport.agentOnly,
        files: [TargetFile(local: '.env.server', remote: '.env')]);
    project.targets.add(t);
    try {
      // ---- the project on this PC, with a 5 MB file (sent in several pieces)
      if (src.existsSync()) src.deleteSync(recursive: true);
      write('index.php', '<?php echo "v1";');
      write('.env', 'DB_HOST=127.0.0.1\nDB_DATABASE=nowhere\nDB_USERNAME=root\nDB_PASSWORD=\n');
      write('.env.server', 'DB_HOST=127.0.0.1\nDB_DATABASE=agent_only_target\nDB_USERNAME=root\nDB_PASSWORD=\n');
      write('migrations/001_notes.sql', 'CREATE TABLE notes (id INT AUTO_INCREMENT PRIMARY KEY, text VARCHAR(100) NOT NULL);\n');
      final rnd = Random(1);
      final big = List<int>.generate(5 * 1024 * 1024, (_) => rnd.nextInt(256)); // does not compress: 3 pieces of 2 MB
      File(p.join(src.path, 'assets', 'video.bin'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(big);
      await sql('DROP DATABASE IF EXISTS agent_only_target; CREATE DATABASE agent_only_target;');
      final td = Directory(targetDir);
      if (td.existsSync()) td.deleteSync(recursive: true);
      td.createSync();
      File(p.join(targetDir, 'uploads', 'kept.txt'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('already on the server');

      // ---- 1. the app cannot place the agent itself: "Save the agent to a file", then copy it by hand
      final agent = await ops.saveAgent(t);
      final code = agent.readAsStringSync();
      // An older copy (here: the same code with one more line) is replaced by the agent itself at the first contact.
      File(p.join(targetDir, t.agentName)).writeAsStringSync(code.replaceFirst('<?php', '<?php\n// older copy'));
      final s = await ops.test(t);
      expect(s['php'], isNotEmpty);
      final version = RegExp(r'const AGENT_VERSION = (\d+);').firstMatch(File('assets/agent/deploy-agent.php').readAsStringSync())![1];
      expect(log.lines.map((l) => l.text), contains('Agent of "server" updated to version $version.'));
      expect(File(p.join(targetDir, t.agentName)).readAsStringSync(), code);
      expect(s['features'], containsAll(['file', 'compare', 'update_agent']));

      // ---- 2. install (files only), over http
      await ops.install(project, t, null);
      expect(File(p.join(targetDir, 'index.php')).readAsStringSync(), contains('v1'));
      expect(File(p.join(targetDir, 'assets', 'video.bin')).readAsBytesSync(), big, reason: '5 MB file arrived whole');
      expect(File(p.join(targetDir, '.env')).readAsStringSync(), contains('agent_only_target'));
      expect(File(p.join(targetDir, 'uploads', 'kept.txt')).existsSync(), true);

      // ---- 3. simulate then deploy: the migration runs on the target database
      final r1 = await ops.simulate(project, t);
      expect(r1.migrations.map((m) => p.basename(m.$1)), ['001_notes.sql']);
      await ops.deploy(project, t, package: r1.package);
      expect(await sql("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'agent_only_target' AND table_name = 'notes'"), '1');

      // ---- 4. a change on this PC: only it is sent
      write('index.php', '<?php echo "v2";');
      final r2 = await ops.simulate(project, t);
      expect(r2.changedFiles, ['index.php']);
      expect(r2.newFiles, isEmpty);
      expect(log.lines.map((l) => l.text), contains('1 of 4 file(s) differ on the target: only they are sent.'));
      expect(log.lines.where((l) => l.text.startsWith('Sending the package')).last.text, contains('(0.0 MB)'), reason: 'not the 5 MB file again');
      // The file as it is on the target, for the comparison screen.
      expect(utf8.decode((await ops.fileOnTarget(t, 'index.php'))!), '<?php echo "v1";');
      expect(await ops.fileOnTarget(t, 'nothing-here.php'), isNull);
      final v = await fileVersions(AppSettings(), project, t, 'index.php', 'M');
      final html = reportHtml(r2, project, t, {'index.php': FileDiff.of(v.$1, v.$2)});
      expect(html, allOf(contains('<details>'), contains('index.php'), contains('class="del"'), contains('v1'), contains('class="add"'), contains('v2')));
      File(p.join('test', 'captures', 'report_example.html')).writeAsStringSync(html);
      await expectLater(ops.fileOnTarget(t, '.deploy/config.php'), throwsA(anything), reason: 'the private folder is never shown');
      // Someone changes the target after the simulation: the deployment makes a new package instead of a wrong one.
      File(p.join(targetDir, '.env')).writeAsStringSync('changed on the server');
      await ops.deploy(project, t, package: r2.package);
      expect(log.lines.map((l) => l.text), contains('The target changed since the simulation: a new package is made.'));
      expect(File(p.join(targetDir, '.env')).readAsStringSync(), contains('agent_only_target'));
      final page = await (await HttpClient().getUrl(Uri.parse('http://localhost/AGENT_ONLY/'))).close();
      expect(await page.transform(const SystemEncoding().decoder).join(), 'v2');
      expect((await ops.simulate(project, t)).upToDate, true);

      // ---- 5. backup and restore over http
      await sql("INSERT INTO notes (text) VALUES ('keep me')", db: 'agent_only_target');
      await ops.backup(t);
      final db = (await ops.backups(t)).firstWhere((f) => '${f['name']}'.startsWith('db-'))['name'] as String;
      await sql('DELETE FROM notes', db: 'agent_only_target');
      await ops.restore(t, db: db);
      expect(await sql('SELECT text FROM notes', db: 'agent_only_target'), 'keep me');

      // ---- 6. a clone on this PC, like a container copied from production: files (kept ones too) and data
      final prodEnv = File(p.join(targetDir, '.env')).readAsStringSync();
      final backupsBefore = (await ops.backups(t)).length;
      final clone = await ops.cloneToPc(project, t,
          folder: cloneDir, url: 'http://localhost/AGENT_ONLY_CLONE', db: DbSettings(name: 'agent_only_clone'));
      expect(File(p.join(cloneDir, 'index.php')).readAsStringSync(), '<?php echo "v2";');
      expect(File(p.join(cloneDir, 'uploads', 'kept.txt')).readAsStringSync(), 'already on the server', reason: 'kept files are in the clone');
      expect(File(p.join(cloneDir, '.env')).readAsStringSync(), contains('DB_DATABASE=agent_only_clone'));
      expect(await sql('SELECT text FROM notes', db: 'agent_only_clone'), 'keep me', reason: 'the data of production');
      expect(Directory(cloneDir).listSync().map((e) => p.basename(e.path)), isNot(contains(t.agentName)), reason: 'not the agent of production');
      expect(clone.transport, Transport.folder);
      expect((await ops.test(clone))['db']['name'], 'agent_only_clone');
      // production untouched: same .env, no backup left there by the clone
      expect(File(p.join(targetDir, '.env')).readAsStringSync(), prodEnv);
      expect((await ops.backups(t)).length, backupsBefore);
      // work on the clone: a change of this PC goes to the clone only
      write('index.php', '<?php echo "v3";');
      project.targets.add(clone);
      final rc = await ops.simulate(project, clone);
      expect(rc.changedFiles, ['index.php']);
      await ops.deploy(project, clone, package: rc.package);
      expect(File(p.join(cloneDir, 'index.php')).readAsStringSync(), contains('v3'));
      expect(File(p.join(targetDir, 'index.php')).readAsStringSync(), contains('v2'), reason: 'production unchanged');
      expect(File(p.join(cloneDir, '.env')).readAsStringSync(), contains('agent_only_clone'), reason: 'the clone keeps its own database');
    } finally {
      for (final l in log.lines.where((l) => l.level != Level.detail)) {
        // ignore: avoid_print
        print('${l.level.name.padRight(6)} ${l.text}');
      }
      if (Directory(targetDir).existsSync()) Directory(targetDir).deleteSync(recursive: true);
      if (src.existsSync()) src.deleteSync(recursive: true);
      await sql('DROP DATABASE IF EXISTS agent_only_target; DROP DATABASE IF EXISTS agent_only_clone;');
      if (Directory(cloneDir).existsSync()) Directory(cloneDir).deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
