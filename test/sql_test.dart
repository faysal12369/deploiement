// SQL typed in the app. On a real target (the local Apache + an agent, database sql_target) and on the local database
// (sql_local): statements run in turn, a reading one gives its rows, a change is preceded by a backup, the first
// error stops the rest. The checks before running, the migration files it writes, and the window in French
// (test/captures/sql_*.png). Run: flutter test test/sql_test.dart --update-goldens   (Apache and MySQL started)
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:deploiement/app_state.dart';
import 'package:deploiement/i18n.dart';
import 'package:deploiement/models.dart';
import 'package:deploiement/operations.dart';
import 'package:deploiement/sql_view.dart';
import 'package:deploiement/theme.dart';

const mysqlExe = r'C:\xampp8\mysql\bin\mysql.exe';
const targetDir = r'C:\xampp8\htdocs\SQL_DEMO';

Future<String> sql(String q, {String db = ''}) async {
  final r = await Process.run(mysqlExe, ['-u', 'root', '-N', '-B', if (db.isNotEmpty) db, '-e', q]);
  if (r.exitCode != 0) throw StateError('${r.stderr}');
  return '${r.stdout}'.trim();
}

Future<void> fonts() async {
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files.where((f) => File(f).existsSync())) {
      l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
    }
    await l.load();
  }

  await load('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\seguisb.ttf', r'C:\Windows\Fonts\segoeuib.ttf']);
  await load('Cascadia Mono', File(r'C:\Windows\Fonts\CascadiaMono.ttf').existsSync() ? [r'C:\Windows\Fonts\CascadiaMono.ttf'] : [r'C:\Windows\Fonts\consola.ttf']);
  await load('Bahnschrift', [r'C:\Windows\Fonts\bahnschrift.ttf']);
  await load('MaterialIcons', [r'D:\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf']);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('what is checked before running, and the migration files', () {
    expect(sqlChanges('SELECT 1;\n-- a comment\nSHOW TABLES; DESCRIBE x'), false);
    expect(sqlChanges('SELECT 1; ALTER TABLE x ADD y INT'), true);
    expect(sqlDangers('DELETE FROM a; DELETE FROM a WHERE id = 1; DROP TABLE b; ALTER TABLE c DROP COLUMN d; UPDATE e SET f = 1; UPDATE e SET f = 1 WHERE g = 2'),
        ['DELETE FROM a', 'DROP TABLE b', 'ALTER TABLE c DROP COLUMN d', 'UPDATE e SET f = 1']);
    expect(sqlDangers('ALTER TABLE c ADD COLUMN d INT; CREATE TABLE z (a INT)'), isEmpty);

    final dir = Directory.systemTemp.createTempSync('deploiement-mig');
    addTearDown(() => dir.deleteSync(recursive: true));
    final mig = Directory(p.join(dir.path, 'database', 'migrations'))..createSync(recursive: true);
    for (final f in ['001_a.sql', '172_b.sql', '172_b_rollback.sql', 'notes.txt']) {
      File(p.join(mig.path, f)).writeAsStringSync('-- x');
    }
    final pr = Project(id: 'p', folder: dir.path, migrationsFolder: 'database/migrations');
    expect(p.basename(nextMigration(pr, 'Add the phone to the clients!').path), '173_add_the_phone_to_the_clients.sql');
    final f = saveMigration(pr, 'Add phone', 'ALTER TABLE clients ADD COLUMN phone VARCHAR(30) NULL');
    expect(p.basename(f.path), '173_add_phone.sql');
    expect(f.readAsStringSync(), allOf(startsWith('-- Add phone\n'), endsWith('ALTER TABLE clients ADD COLUMN phone VARCHAR(30) NULL;\n')));
    expect(p.basename(nextMigration(pr, '').path), '174_change.sql');
    // a project without a migrations folder yet: database/migrations, and the project now points to it
    final bare = Project(id: 'q', folder: Directory.systemTemp.createTempSync('deploiement-mig2').path);
    addTearDown(() => Directory(bare.folder).deleteSync(recursive: true));
    expect(p.basename(saveMigration(bare, 'first', 'CREATE TABLE t (a INT);').path), '001_first.sql');
    expect(bare.migrationsFolder, 'database/migrations');
  });

  test('on a target and on the local database', () async {
    final ops = Operations(AppSettings(), Journal());
    final t = Target(id: 'sql', name: 'sql', url: 'http://localhost/SQL_DEMO', transport: Transport.folder, remotePath: targetDir);
    final pr = Project(id: 'p', name: 'sql-demo', localDb: DbSettings(name: 'sql_local'), targets: [t]);
    await sql('DROP DATABASE IF EXISTS sql_target; CREATE DATABASE sql_target; DROP DATABASE IF EXISTS sql_local; CREATE DATABASE sql_local;');
    final td = Directory(targetDir);
    if (td.existsSync()) td.deleteSync(recursive: true);
    td.createSync();
    File(p.join(targetDir, '.env')).writeAsStringSync('DB_HOST=127.0.0.1\nDB_DATABASE=sql_target\nDB_USERNAME=root\nDB_PASSWORD=\n');
    try {
      await ops.placeAgent(t);
      Future<int> dbBackups() async => (await ops.backups(t)).where((b) => '${b['name']}'.startsWith('db-')).length;

      // ---- changes then reads: a backup first, then each statement in turn
      final r1 = await ops.runSql(t, '''
CREATE TABLE colors (id INT PRIMARY KEY, name VARCHAR(20));
INSERT INTO colors VALUES (1, 'Red'), (2, 'Green');
-- a comment between two statements
SELECT * FROM colors ORDER BY id;
SHOW TABLES;''');
      expect(r1.map((o) => o.error), [null, null, null, null]);
      expect([r1[0].affected, r1[1].affected], [0, 2]);
      expect(r1[2].columns, ['id', 'name']);
      expect(r1[2].rows, [['1', 'Red'], ['2', 'Green']]);
      expect(r1[3].rows.expand((r) => r), contains('colors'));
      expect(await dbBackups(), 1);

      // ---- only reading: no backup
      final r2 = await ops.runSql(t, 'SELECT COUNT(*) AS n FROM colors');
      expect([r2.single.columns, r2.single.rows], [['n'], [['2']]]);
      expect(await dbBackups(), 1);

      // ---- the first error stops the rest: the DELETE after it does not run
      final r3 = await ops.runSql(t, "UPDATE colors SET name = 'Rouge' WHERE id = 1; SELECT nope FROM colors; DELETE FROM colors");
      expect(r3, hasLength(2));
      expect(r3[0].affected, 1);
      expect(r3[1].error, contains('nope'));
      expect(await sql('SELECT GROUP_CONCAT(name ORDER BY id) FROM colors', db: 'sql_target'), 'Rouge,Green');

      // ---- the local database of the project
      final r4 = await ops.runSqlLocal(pr, 'CREATE TABLE t (a INT); INSERT INTO t VALUES (5); SELECT a * 2 AS twice FROM t');
      expect([r4[1].affected, r4[2].rows], [1, [['10']]]);
      expect(await sql('SELECT COUNT(*) FROM t', db: 'sql_local'), '1');
    } finally {
      await sql('DROP DATABASE IF EXISTS sql_target; DROP DATABASE IF EXISTS sql_local;');
      if (td.existsSync()) td.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('the window, in French', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.reset);
    await tester.runAsync(fonts);
    language.value = 'fr';
    final t = Target(id: 't', name: 'hostinger', url: 'https://example.com');
    final pr = Project(id: 'p', name: 'erp', targets: [t]);
    final app = AppState(settings: AppSettings()..language = 'fr', projects: [pr], persist: false);
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: Builder(builder: (c) {
      ctx = c;
      return Scaffold(backgroundColor: Palette.of(c).bg);
    })));
    showSqlDialog(ctx, app, pr, target: t, results: [
      SqlOutcome(sql: 'ALTER TABLE customers ADD COLUMN phone VARCHAR(30) NULL', affected: 0, ms: 41),
      SqlOutcome(sql: 'SELECT id, code, nom, telephone FROM customers ORDER BY id LIMIT 3', columns: ['id', 'code', 'nom', 'telephone'], rows: [
        ['1', 'CL-001', 'Alpha Industrie', null],
        ['2', 'CL-002', 'Bureau Nord', null],
        ['3', 'CL-003', 'Cabinet Sud', null],
      ], count: 3, ms: 3),
      SqlOutcome(sql: 'SELECT nope FROM customers', error: "Unknown column 'nope' in 'field list'", ms: 1),
    ]);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('sql-editor')), 'ALTER TABLE customers ADD COLUMN phone VARCHAR(30) NULL;\nSELECT id, code, nom, telephone FROM customers ORDER BY id LIMIT 3;');
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/sql_1_target.png'));
    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();
    showSqlDialog(ctx, app, pr, migration: true);
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/sql_2_migration.png'));
  });
}
