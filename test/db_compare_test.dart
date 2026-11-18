// "Compare databases": the database of this PC (db_compare_pc) next to the one of a target reached over http
// (C:\xampp8\htdocs\DB_COMPARE served by the local Apache, database db_compare_target), read only on both sides.
// Data: rows recognised by their key, ids translated (matched by key). Structure: the
// Delta Schéma page filled in with both structures. Run: flutter test test/db_compare_test.dart (Apache and MySQL started)
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:deploiement/app_state.dart';
import 'package:deploiement/db_compare_view.dart';
import 'package:deploiement/i18n.dart';
import 'package:deploiement/models.dart';
import 'package:deploiement/operations.dart';
import 'package:deploiement/report_html.dart';
import 'package:deploiement/results.dart';
import 'package:deploiement/theme.dart';

const mysqlExe = r'C:\xampp8\mysql\bin\mysql.exe';
const targetDir = r'C:\xampp8\htdocs\DB_COMPARE';

Future<String> sql(String q, {String db = ''}) async {
  final r = await Process.run(mysqlExe, ['-u', 'root', '-N', '-B', '--default-character-set=utf8mb4', if (db.isNotEmpty) db, '-e', q]);
  if (r.exitCode != 0) throw StateError('${r.stderr}');
  return '${r.stdout}'.trim();
}

/// The same application on both sides, with different data and a slightly different structure.
const schema = '''
CREATE TABLE roles (id INT AUTO_INCREMENT PRIMARY KEY, code VARCHAR(20) NOT NULL UNIQUE, name VARCHAR(50) NOT NULL) ENGINE=InnoDB;
CREATE TABLE users (id INT AUTO_INCREMENT PRIMARY KEY, email VARCHAR(80) NOT NULL UNIQUE, name VARCHAR(50) NOT NULL,
  role_id INT NULL, CONSTRAINT fk_users_role FOREIGN KEY (role_id) REFERENCES roles (id)) ENGINE=InnoDB;
CREATE TABLE role_permissions (role_id INT NOT NULL, perm VARCHAR(30) NOT NULL, PRIMARY KEY (role_id, perm),
  CONSTRAINT fk_rp_role FOREIGN KEY (role_id) REFERENCES roles (id)) ENGINE=InnoDB;
CREATE TABLE notes (id INT AUTO_INCREMENT PRIMARY KEY, text VARCHAR(100) NOT NULL) ENGINE=InnoDB;
CREATE TABLE activity_log (id INT AUTO_INCREMENT PRIMARY KEY, what VARCHAR(100) NOT NULL) ENGINE=InnoDB;
CREATE TABLE settings (k VARCHAR(40) NOT NULL UNIQUE, v VARCHAR(100) NULL) ENGINE=InnoDB;
CREATE TABLE fiches (id INT AUTO_INCREMENT PRIMARY KEY, numero_id INT NOT NULL, objet VARCHAR(80) NOT NULL) ENGINE=InnoDB;
''';

DbCompare? compared;
final project = Project(id: 'cmp', name: 'compare-demo', folder: Directory.systemTemp.path, localDb: DbSettings(name: 'db_compare_pc'),
    compareKeys: ['fiches: numero_id']);
final target = Target(id: 'srv', name: 'server', url: 'http://localhost/DB_COMPARE', transport: Transport.agentOnly);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  project.targets.add(target);

  test('compare databases: rows of this PC missing on the target and the reverse, ids translated; structure for Delta Schéma', () async {
    final log = Journal();
    final ops = Operations(AppSettings(), log);
    try {
      await sql('DROP DATABASE IF EXISTS db_compare_pc; CREATE DATABASE db_compare_pc CHARACTER SET utf8mb4;'
          'DROP DATABASE IF EXISTS db_compare_target; CREATE DATABASE db_compare_target CHARACTER SET utf8mb4;');
      // this PC: a newer version (a column, a table and a view more)
      await sql('$schema ALTER TABLE users ADD phone VARCHAR(20) NULL; CREATE TABLE only_pc (id INT AUTO_INCREMENT PRIMARY KEY);'
          'CREATE VIEW v_admins AS SELECT u.email FROM users u JOIN roles r ON r.id = u.role_id WHERE r.code = \'admin\';'
          "INSERT INTO roles (id, code, name) VALUES (1, 'admin', 'Administrator'), (2, 'editor', 'Editor'), (3, 'viewer', 'Viewer');"
          "INSERT INTO users (email, name, role_id) VALUES ('ann@example.com', 'Ann', 1), ('bob@example.com', 'Bob', 3);"
          "INSERT INTO role_permissions VALUES (1, 'all'), (2, 'edit'), (3, 'read');"
          "INSERT INTO notes (text) VALUES ('a'), ('b'), ('c');"
          "INSERT INTO activity_log (what) VALUES ('1'), ('2');"
          "INSERT INTO settings VALUES ('site.name', 'Shop'), ('site.lang', 'en');"
          "INSERT INTO fiches (numero_id, objet) VALUES (10, 'Ten'), (11, 'Eleven');", db: 'db_compare_pc');
      // the target: other ids for the same roles, a row only there, fewer notes, more log lines
      await sql("$schema INSERT INTO roles (id, code, name) VALUES (1, 'editor', 'Editor'), (2, 'admin', 'Administrator');"
          "INSERT INTO users (email, name, role_id) VALUES ('ann@example.com', 'Ann', 2), ('carl@example.com', 'Carl', 1);"
          "INSERT INTO role_permissions VALUES (2, 'all'), (1, 'edit'), (1, 'publish');"
          "INSERT INTO notes (text) VALUES ('a');"
          "INSERT INTO activity_log (what) VALUES ('1'), ('2'), ('3'), ('4'), ('5');"
          "INSERT INTO settings VALUES ('site.name', 'Shop'), ('site.lang', 'en');"
          "INSERT INTO fiches (numero_id, objet) VALUES (10, 'Ten');", db: 'db_compare_target');
      final td = Directory(targetDir);
      if (td.existsSync()) td.deleteSync(recursive: true);
      td.createSync();
      File(p.join(targetDir, '.env')).writeAsStringSync('DB_HOST=127.0.0.1\nDB_DATABASE=db_compare_target\nDB_USERNAME=root\nDB_PASSWORD=\n');
      File(p.join(targetDir, target.agentName)).writeAsStringSync((await ops.saveAgent(target)).readAsStringSync());

      final c = compared = await ops.compareDatabases(project, target);
      DataCompare of(String t) => c.tables.firstWhere((x) => x.table == t);

      // ---- data
      expect(of('only_pc').rank, DataRank.oneSide);
      final rp = of('role_permissions');
      expect(rp.byKey, true);
      expect(rp.pc!.key, ['role_id', 'perm']);
      expect(rp.pc!.keyFrom, {'role_id': 'roles'}, reason: 'the role id is read as the role code: ids differ between the two databases');
      expect(rp.onlyPc, ['viewer / read']);
      expect(rp.onlyTarget, ['editor / publish']);
      expect(rp.rank, DataRank.missingOnTarget);
      expect(of('roles').onlyPc, ['viewer — Viewer']);
      final users = of('users');
      expect(users.pc!.key, ['email']);
      expect(users.onlyPc, ['bob@example.com — Bob']);
      expect(users.onlyTarget, ['carl@example.com — Carl']);
      expect(of('notes').byKey, false, reason: 'no key: counted only');
      expect(of('notes').rank, DataRank.fewerOnTarget);
      expect(of('activity_log').rank, DataRank.countOnly);
      expect(of('settings').rank, DataRank.same);
      expect(of('fiches').pc!.key, ['numero_id'], reason: 'key chosen in the project settings');
      expect(of('fiches').onlyPc, ['11 — Eleven']);
      expect(c.tables.first.table, 'only_pc', reason: 'tables on one side first');
      expect(c.withMissing, 6);
      expect(log.lines.map((l) => l.text), contains('6 tables have rows of this PC missing on the target.'));
      // nothing was changed on either side
      expect(await sql('SELECT COUNT(*) FROM role_permissions', db: 'db_compare_target'), '3');
      expect(await sql('SELECT COUNT(*) FROM users', db: 'db_compare_pc'), '2');

      // ---- structure: the Delta Schéma page with both exports, the target as the old one
      expect(c.targetSql, startsWith('-- Server version: '));
      expect(c.pcSql, allOf(contains('CREATE TABLE `only_pc`'), contains('`phone` varchar(20)'), contains('VIEW `v_admins`')));
      expect(c.targetSql, isNot(contains('only_pc')));
      expect(c.pcSql, isNot(contains('AUTO_INCREMENT=')), reason: 'the counter is not a difference of structure');
      final page = c.deltaPage.readAsStringSync();
      expect(page, contains('id="sql-old"'), reason: 'the tool itself');
      final injected = page.substring(page.lastIndexOf('Déploiement: the structure'));
      expect(injected, allOf(contains("getElementById('btn-run')"), contains('only_pc')));
      expect(RegExp(r'</script>').allMatches(injected).length, 1, reason: '"</" of the exports is escaped');
      expect(injected, contains('server = "${deltaTargetKey(c.target.server)}"'));
      expect([
        for (final v in ['10.4.32-MariaDB', '10.11.6-MariaDB-0+deb12u1', '10.6.18-MariaDB', '11.4.2-MariaDB', '10.1.48-MariaDB', '8.0.36', '5.7.44-log', '5.6.51'])
          deltaTargetKey(v)
      ], ['maria104', 'maria1011', 'maria106', 'maria1011', 'maria101', 'mysql80', 'mysql57', 'mysql56']);
      File(p.join('test', 'captures', 'delta_schema_example.html')).writeAsStringSync(page);

      // ---- the report to keep
      final html = dataCompareHtml(c, project, target);
      expect(html, allOf(contains('viewer / read'), contains('carl@example.com'), contains('only_pc')));
      File(p.join('test', 'captures', 'data_compare_example.html')).writeAsStringSync(html);
    } finally {
      for (final l in log.lines.where((l) => l.level != Level.detail)) {
        // ignore: avoid_print
        print('${l.level.name.padRight(6)} ${l.text}');
      }
      if (Directory(targetDir).existsSync()) Directory(targetDir).deleteSync(recursive: true);
      await sql('DROP DATABASE IF EXISTS db_compare_pc; DROP DATABASE IF EXISTS db_compare_target;');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('the comparison window, wide and narrow, English and French', (tester) async {
    final c = compared;
    if (c == null) return; // the first test failed
    final app = AppState(settings: AppSettings(), projects: [project], persist: false);
    for (final (lang, size) in [('en', const Size(1440, 1000)), ('fr', const Size(480, 1000))]) {
      language.value = lang;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: DbCompareDialog(app, project, target, c, key: UniqueKey())),
      ));
      await tester.pumpAndSettle();
      expect(find.text(lang == 'en' ? 'Compare databases' : 'Comparer les bases'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('data-role_permissions')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('data-role_permissions')));
      await tester.pumpAndSettle();
      expect(find.text('viewer / read'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('db-tab-structure')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('db-open-delta')), findsOneWidget);
    }
    language.value = 'en';
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
