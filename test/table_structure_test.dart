// Tables with their structure only, or their structure and their data (asked 17/11/2026: "some tables I want to
// import the data, and some tables just their structure"). No migration file: the app makes the chosen tables of the
// target like this PC's — created, columns added at their place, columns changed, indexes added — and never removes
// anything there: the rows of the target and its own columns stay. A row pointing at a table that is not sent (a
// market) gets the target's own row with the same key, whatever its id (18/11/2026: rows point at
// rows whose ids differ on the server). Not shipped with the app.
// Target = C:\xampp8\htdocs\TABLES_DEMO served by the local Apache, databases tables_local / tables_target (removed at
// the end).
// Run: flutter test test/table_structure_test.dart   (Apache and MySQL of C:\xampp8 started)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:deploiement/models.dart';
import 'package:deploiement/operations.dart';
import 'package:deploiement/results.dart';

const mysqlExe = r'C:\xampp8\mysql\bin\mysql.exe';
final src = Directory(p.join(Directory.systemTemp.path, 'deploiement-tables'));
const targetDir = r'C:\xampp8\htdocs\TABLES_DEMO';

Future<String> sql(String q, {String db = ''}) async {
  final r = await Process.run(mysqlExe, ['-u', 'root', '-N', '-B', if (db.isNotEmpty) db, '-e', q]);
  if (r.exitCode != 0) throw StateError('${r.stderr}');
  return '${r.stdout}'.trim();
}

Future<String> columns(String table) => sql(
    "SELECT GROUP_CONCAT(CONCAT(COLUMN_NAME, ' ', COLUMN_TYPE) ORDER BY ORDINAL_POSITION SEPARATOR ', ') FROM information_schema.COLUMNS "
    "WHERE TABLE_SCHEMA = 'tables_target' AND TABLE_NAME = '$table'");

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('structure only, structure and data, nothing removed', () async {
    final ops = Operations(AppSettings(), Journal());
    final project = Project(
      id: 'tables',
      name: 'tables-demo',
      folder: src.path,
      keep: ['.env'],
      localDb: DbSettings(name: 'tables_local'),
      sync: [
        SyncTable(table: 'movements', structure: true, data: false), // the target keeps its rows
        SyncTable(table: 'categories', structure: true, data: true), // not on the target yet: created, then filled
        SyncTable(table: 'logs', structure: true, data: false), // not on the target: created empty
        SyncTable(table: 'notes', data: true), // no key besides its id: left out with its reason, the others still go
      ],
    );
    final target = Target(id: 'tables', name: 'tables', url: 'http://localhost/TABLES_DEMO', transport: Transport.folder, remotePath: targetDir);
    project.targets.add(target);

    if (src.existsSync()) src.deleteSync(recursive: true);
    File(p.join(src.path, 'index.php'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('<?php echo "tables";');
    await sql('DROP DATABASE IF EXISTS tables_local; CREATE DATABASE tables_local; DROP DATABASE IF EXISTS tables_target; CREATE DATABASE tables_target;');
    // this PC: the new structure
    await sql('''
      CREATE TABLE markets (id INT AUTO_INCREMENT PRIMARY KEY, numero VARCHAR(20) NOT NULL, UNIQUE KEY uq_numero (numero));
      INSERT INTO markets (id, numero) VALUES (1, 'M-A'), (2, 'M-PC-ONLY');
      CREATE TABLE categories (id INT AUTO_INCREMENT PRIMARY KEY, code VARCHAR(10) NOT NULL, name VARCHAR(60) NOT NULL, market_id INT DEFAULT NULL,
        updated_by_id INT DEFAULT NULL, UNIQUE KEY uq_code (code), CONSTRAINT fk_cat_market FOREIGN KEY (market_id) REFERENCES markets (id));
      INSERT INTO categories (code, name, market_id, updated_by_id) VALUES ('A', 'Achats', 1, 7), ('V', 'Ventes', 2, NULL);
      CREATE TABLE movements (
        id INT AUTO_INCREMENT PRIMARY KEY,
        ref VARCHAR(20) NOT NULL,
        category VARCHAR(10) DEFAULT NULL,
        qty DECIMAL(12,3) NOT NULL DEFAULT 0,
        note VARCHAR(200) DEFAULT NULL,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        KEY idx_ref (ref)
      );
      INSERT INTO movements (ref, qty) VALUES ('PC-ONLY', 1);
      CREATE TABLE logs (id BIGINT AUTO_INCREMENT PRIMARY KEY, message TEXT NOT NULL);
      INSERT INTO logs (message) VALUES ('a log of this PC');
      CREATE TABLE notes (id INT AUTO_INCREMENT PRIMARY KEY, txt VARCHAR(50));
      INSERT INTO notes (txt) VALUES ('a'), ('b');
    ''', db: 'tables_local');
    // the target: an older movements, with its own rows and a column of its own
    await sql('''
      CREATE TABLE movements (id INT AUTO_INCREMENT PRIMARY KEY, ref VARCHAR(20) NOT NULL, qty INT NOT NULL DEFAULT 0, server_flag TINYINT NOT NULL DEFAULT 1);
      INSERT INTO movements (ref, qty) VALUES ('SRV-1', 5), ('SRV-2', 7);
      CREATE TABLE markets (id INT AUTO_INCREMENT PRIMARY KEY, numero VARCHAR(20) NOT NULL, UNIQUE KEY uq_numero (numero));
      INSERT INTO markets (id, numero) VALUES (50, 'M-A');
    ''', db: 'tables_target');

    final td = Directory(targetDir);
    if (td.existsSync()) td.deleteSync(recursive: true);
    td.createSync();
    File(p.join(targetDir, '.env')).writeAsStringSync('DB_HOST=127.0.0.1\nDB_DATABASE=tables_target\nDB_USERNAME=root\nDB_PASSWORD=\n');

    try {
      await ops.placeAgent(target);

      // ---- 1. the simulation says what would change, and changes nothing
      final s = await ops.simulate(project, target);
      final byName = {for (final t in s.tables) t.table: t};
      expect(byName.keys.toSet(), {'movements', 'categories', 'logs'});
      expect(byName['categories']!.create, true);
      expect(byName['logs']!.create, true);
      final m = byName['movements']!;
      expect(m.create, false);
      expect([for (final c in m.changes.where((c) => c.what == 'add_column')) c.name], ['category', 'note', 'created_at']);
      expect([for (final c in m.changes.where((c) => c.what == 'change_column')) c.name], ['qty']);
      expect([for (final c in m.changes.where((c) => c.what == 'add_key')) c.name], ['idx_ref']);
      expect(m.kept, ['server_flag'], reason: 'a column only on the target is kept');
      expect(s.upToDate, false);
      expect(s.tablesKey, project.tablesKey, reason: 'the simulation knows the choice of tables it was made with');
      expect(await sql("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'tables_target'"), '2', reason: 'a simulation changes nothing');
      // a table without a key does not stop the simulation (18/11/2026), its rows are left out — and not counted as
      // "left out" (they looked like rows thrown away): "Deploy" says why under the table
      expect(s.sync.map((x) => x.table), ['categories'], reason: 'only the tables with "Data" send rows, never one without a key');
      expect(s.rowsSkipped, 0);
      expect(s.localNoKey, contains('notes'));
      expect(s.localNoKey, isNot(contains('categories')));

      // ---- 2. without "Structure": the tables stay as they are
      final r0 = await ops.deploy(project, target, parts: const DeployParts(structure: false, data: false));
      expect(r0.ok, true);
      expect(r0.tables, isEmpty);
      expect(await columns('movements'), 'id int(11), ref varchar(20), qty int(11), server_flag tinyint(4)');

      // ---- 3. deploy: structure of the three tables, rows of categories only
      final r = await ops.deploy(project, target);
      expect(r.ok, true);
      expect(r.tables.fold(0, (n, t) => n + t.done), s.tableChanges);
      expect(await columns('movements'),
          'id int(11), ref varchar(20), category varchar(10), qty decimal(12,3), note varchar(200), created_at datetime, server_flag tinyint(4)',
          reason: 'new columns at their place, qty changed, the column of the target kept at the end');
      expect(await sql('SELECT GROUP_CONCAT(CONCAT(ref, "=", qty) ORDER BY id) FROM movements', db: 'tables_target'), 'SRV-1=5.000,SRV-2=7.000',
          reason: 'the rows of the target stay, none of this PC arrives');
      expect(await sql("SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = 'tables_target' AND TABLE_NAME = 'movements' AND INDEX_NAME = 'idx_ref'"), '1');
      expect(await sql('SELECT GROUP_CONCAT(name ORDER BY code) FROM categories', db: 'tables_target'), 'Achats,Ventes', reason: 'created, then its rows');
      expect(await sql("SELECT GROUP_CONCAT(CONCAT(code, ':', IFNULL(market_id, '-')) ORDER BY code) FROM categories", db: 'tables_target'), 'A:50,V:-',
          reason: 'the market found by its numero (id 1 here, 50 there); the one missing there left empty, the row still comes');
      final cat = r.sync.firstWhere((x) => x.table == 'categories');
      expect([cat.added, cat.unlinked], [2, 1]);
      expect(cat.details.where((d) => d.$1 == 'unlink').single.$2, contains('M-PC-ONLY'));
      expect(await sql('SELECT COUNT(*) FROM logs', db: 'tables_target'), '0', reason: 'structure only: created empty');
      expect(await columns('logs'), 'id bigint(20), message text');

      // ---- 4. nothing left to do; who changed a row on the target is its own business
      await sql('UPDATE categories SET updated_by_id = 9', db: 'tables_target');
      final again = await ops.simulate(project, target);
      expect(again.rowsUpdated, 0, reason: 'updated_by_id is never sent over an existing row');
      expect(again.tableChanges, 0, reason: 'the same structure on both sides now');
      expect(again.upToDate, true);
      final back = DeployResult.fromJson(r.toJson());
      expect(back.tables.firstWhere((t) => t.table == 'movements').count('add_column'), 3);

      // ---- 5. a project saved before the choice existed: its tables send their data only, as then
      final old = SyncTable.fromJson({'table': 'colors', 'key': ['code']});
      expect([old.data, old.structure], [true, false]);
    } finally {
      await sql('DROP DATABASE IF EXISTS tables_local; DROP DATABASE IF EXISTS tables_target;');
      if (td.existsSync()) td.deleteSync(recursive: true);
      if (src.existsSync()) src.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
