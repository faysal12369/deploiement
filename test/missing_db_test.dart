// A target whose database was deleted (19/11/2026: "I deleted the database of that PC and want to recreate it from 0, the app
// does not help me"): the test says the database is missing, Deploy refuses (it would send the files without it),
// Install creates the database and copies this PC's into it. Target = C:\xampp8\htdocs\MISSING_DB served by the local
// Apache, databases missing_local / missing_target (removed at the end). Not shipped with the app.
// Run: flutter test test/missing_db_test.dart   (Apache and MySQL of C:\xampp8 started)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:deploiement/models.dart';
import 'package:deploiement/operations.dart';

const mysqlExe = r'C:\xampp8\mysql\bin\mysql.exe';
final src = Directory(p.join(Directory.systemTemp.path, 'deploiement-missing-db'));
const targetDir = r'C:\xampp8\htdocs\MISSING_DB';

Future<String> sql(String q, {String db = ''}) async {
  final r = await Process.run(mysqlExe, ['-u', 'root', '-N', '-B', if (db.isNotEmpty) db, '-e', q]);
  if (r.exitCode != 0) throw StateError('${r.stderr}');
  return '${r.stdout}'.trim();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('a deleted database is made again by Install', () async {
    final log = Journal();
    final ops = Operations(AppSettings(), log);
    final project = Project(id: 'missing', name: 'missing-demo', folder: src.path, keep: ['.env'], localDb: DbSettings(name: 'missing_local'),
        migrationsFolder: 'database/migrations');
    final target = Target(id: 'missing', name: 'test pc', url: 'http://localhost/MISSING_DB', transport: Transport.folder, remotePath: targetDir);
    project.targets.add(target);

    if (src.existsSync()) src.deleteSync(recursive: true);
    File(p.join(src.path, 'index.php'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('<?php echo "missing";');
    File(p.join(src.path, 'database', 'migrations', '001_notes.sql'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('CREATE TABLE IF NOT EXISTS notes (id INT AUTO_INCREMENT PRIMARY KEY, txt VARCHAR(50) NOT NULL);\n');
    await sql('DROP DATABASE IF EXISTS missing_local; CREATE DATABASE missing_local; DROP DATABASE IF EXISTS missing_target;');
    await sql("CREATE TABLE notes (id INT AUTO_INCREMENT PRIMARY KEY, txt VARCHAR(50) NOT NULL); INSERT INTO notes (txt) VALUES ('a'), ('b'), ('c');", db: 'missing_local');
    final td = Directory(targetDir);
    if (td.existsSync()) td.deleteSync(recursive: true);
    td.createSync();
    // the site still says where its database is, but the database itself was deleted
    File(p.join(targetDir, '.env')).writeAsStringSync('DB_HOST=127.0.0.1\nDB_DATABASE=missing_target\nDB_USERNAME=root\nDB_PASSWORD=\n');

    try {
      await ops.placeAgent(target);

      // ---- 1. the test says it plainly
      final s = await ops.test(target);
      final db = (s['db'] as Map).cast<String, dynamic>();
      expect(db['ok'], false);
      expect(dbMissing(db), true);
      expect(dbNameOf(db), 'missing_target');
      expect(log.lines.map((l) => l.text).join('\n'), contains('The database "missing_target" does not exist on the target: More › Install… creates it'));

      // ---- 2. Deploy refuses: it would send the files and leave the database out
      final error = await ops.deploy(project, target).then((_) => '', onError: (Object e) => '$e');
      expect(error, contains('does not exist on the target'));
      expect(File(p.join(targetDir, 'index.php')).existsSync(), false, reason: 'nothing written');

      // ---- 3. Install: the database is created, this PC's copied into it, the migrations recorded as applied
      await ops.install(project, target, const DbSource.local());
      expect(await sql('SELECT GROUP_CONCAT(txt ORDER BY id) FROM notes', db: 'missing_target'), 'a,b,c');
      expect(File(p.join(targetDir, 'index.php')).readAsStringSync(), contains('missing'));
      expect(log.lines.map((l) => l.text), contains('Database "missing_target" created.'));
      final after = await ops.simulate(project, target);
      expect(after.migrations, isEmpty, reason: 'the copy is as recent as the project: its migrations are recorded as applied');
      expect(after.upToDate, true);
    } finally {
      await sql('DROP DATABASE IF EXISTS missing_local; DROP DATABASE IF EXISTS missing_target;');
      if (td.existsSync()) td.deleteSync(recursive: true);
      if (src.existsSync()) src.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
