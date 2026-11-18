// End-to-end test with a small generic PHP project ("demo shop"), unrelated to any ERP. Not shipped with the app.
// Local project in the scratch folder, local database demo_local; target = C:\xampp8\htdocs\DEMO_SHOP served by the
// local Apache (http://localhost/DEMO_SHOP), target database demo_target. Also renders the screens to test/captures.
// Run: flutter test test/generic_test.dart --update-goldens   (Apache and MySQL started)
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:deploiement/app_state.dart';
import 'package:deploiement/git.dart';
import 'package:deploiement/diff_view.dart';
import 'package:deploiement/i18n.dart';
import 'package:deploiement/main.dart';
import 'package:deploiement/models.dart';
import 'package:deploiement/operations.dart';
import 'package:deploiement/result_view.dart';
import 'package:deploiement/results.dart';
import 'package:deploiement/table_view.dart';
import 'package:deploiement/widgets.dart';

const mysqlExe = r'C:\xampp8\mysql\bin\mysql.exe';
final src = Directory(p.join(Directory.systemTemp.path, 'php-deploy-demo-shop'));
const targetDir = r'C:\xampp8\htdocs\DEMO_SHOP';

Future<String> sql(String q, {String db = ''}) async {
  final r = await Process.run(mysqlExe, ['-u', 'root', '-N', '-B', if (db.isNotEmpty) db, '-e', q]);
  if (r.exitCode != 0) throw StateError('${r.stderr}');
  return '${r.stdout}'.trim();
}

void write(String rel, String content) {
  final f = File(p.join(src.path, rel))..parent.createSync(recursive: true);
  f.writeAsStringSync(content);
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
  Git.offline = true; // the project page does not run git in these screens
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  testWidgets('generic project: install, migrations, sync, kept files, backup, screens', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final settings = AppSettings();
    final log = Journal();
    final ops = Operations(settings, log);
    final project = Project(
      id: 'demo',
      name: 'demo-shop',
      folder: src.path,
      keep: ['.env', 'uploads/'],
      migrationsFolder: 'database/migrations',
      localDb: DbSettings(name: 'demo_local'),
      sync: [SyncTable(table: 'categories'), SyncTable(table: 'products')],
    );
    final target = Target(
      id: 'local',
      name: 'staging',
      url: 'http://localhost/DEMO_SHOP',
      transport: Transport.folder,
      remotePath: targetDir,
      files: [TargetFile(local: '.env.production', remote: '.env')],
    );
    project.targets.add(target);
    late Report report1, report2;
    late Map<String, dynamic> status;
    late DeployResult deployed;
    late Map<String, dynamic> products;

    await tester.runAsync(() async {
      await fonts();
      // ---- the demo project on "this PC"
      if (src.existsSync()) src.deleteSync(recursive: true);
      write('index.php', r'''<?php
$env = [];
foreach (file(__DIR__ . '/.env', FILE_IGNORE_NEW_LINES) as $l) { if (strpos($l, '=')) { [$k, $v] = explode('=', $l, 2); $env[$k] = $v; } }
$pdo = new PDO("mysql:host={$env['DB_HOST']};dbname={$env['DB_DATABASE']};charset=utf8mb4", $env['DB_USERNAME'], $env['DB_PASSWORD']);
foreach ($pdo->query('SELECT p.sku, p.name, c.name AS cat FROM products p JOIN categories c ON c.id = p.category_id ORDER BY p.sku') as $r) {
    echo "{$r['sku']} {$r['name']} ({$r['cat']})\n";
}
''');
      write('old.php', '<?php echo "old";');
      write('.env', 'DB_HOST=127.0.0.1\nDB_DATABASE=demo_local\nDB_USERNAME=root\nDB_PASSWORD=\n');
      write('.env.production', 'DB_HOST=127.0.0.1\nDB_DATABASE=demo_target\nDB_USERNAME=root\nDB_PASSWORD=\n');
      write('uploads/local-photo.txt', 'local upload, never sent');
      write('node_modules/lib/x.js', 'excluded');
      write('database/migrations/001_categories.sql',
          'CREATE TABLE categories (id INT AUTO_INCREMENT PRIMARY KEY, code VARCHAR(20) NOT NULL UNIQUE, name VARCHAR(60) NOT NULL);\n');
      write('database/migrations/002_products.sql',
          'CREATE TABLE products (id INT AUTO_INCREMENT PRIMARY KEY, sku VARCHAR(20) NOT NULL UNIQUE, name VARCHAR(80) NOT NULL,\n'
          '  category_id INT NOT NULL, CONSTRAINT fk_cat FOREIGN KEY (category_id) REFERENCES categories (id));\n');
      write('database/migrations/002_products_rollback.sql', 'DROP TABLE products;\n');
      await sql('DROP DATABASE IF EXISTS demo_local; CREATE DATABASE demo_local; DROP DATABASE IF EXISTS demo_target; CREATE DATABASE demo_target;');
      for (final m in ['001_categories.sql', '002_products.sql']) {
        await sql(File(p.join(src.path, 'database', 'migrations', m)).readAsStringSync(), db: 'demo_local');
      }
      // Local ids deliberately different from what the target will give (ids are never trusted across databases).
      await sql("INSERT INTO categories (id, code, name) VALUES (7, 'TOOLS', 'Tools'), (9, 'GARDEN', 'Garden');"
          "INSERT INTO products (sku, name, category_id) VALUES ('P-1', 'Hammer', 7), ('P-2', 'Shovel', 9), ('P-3', 'Rake', 9);", db: 'demo_local');
      final td = Directory(targetDir);
      if (td.existsSync()) td.deleteSync(recursive: true);
      td.createSync();
      File(p.join(targetDir, 'uploads', 'customer-photo.txt'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('uploaded on the server, must survive');

      // ---- 1. agent + files-only install (the .env of the target comes from .env.production)
      await ops.placeAgent(target);
      await ops.install(project, target, null);
      expect(File(p.join(targetDir, '.env')).readAsStringSync(), contains('demo_target'));
      expect(File(p.join(targetDir, '.env.production')).existsSync(), false, reason: 'the config of one target is never sent as itself');
      expect(Directory(p.join(targetDir, 'node_modules')).existsSync(), false);
      expect(File(p.join(targetDir, 'uploads', 'local-photo.txt')).existsSync(), false);

      // ---- 2. simulation then deployment: both migrations on the empty database, then the synced rows
      report1 = await ops.simulate(project, target);
      expect(report1.migrations.map((m) => p.basename(m.$1)), ['001_categories.sql', '002_products.sql']);
      expect(report1.baseline, isEmpty);
      expect(report1.sync.firstWhere((s) => s.table == 'products').pending, 3, reason: 'rows of a table the migrations create come at deployment');
      expect(report1.rowsSkipped, 0);
      await ops.deploy(project, target, package: report1.package);
      expect(await sql('SELECT COUNT(*) FROM products', db: 'demo_target'), '3');
      expect(await sql("SELECT c.code FROM products p JOIN categories c ON c.id = p.category_id WHERE p.sku = 'P-1'", db: 'demo_target'), 'TOOLS');
      final page = await (await HttpClient().getUrl(Uri.parse('http://localhost/DEMO_SHOP/'))).close();
      expect(await page.transform(const SystemEncoding().decoder).join(), contains('P-2 Shovel (Garden)'));

      // ---- 3. new local work: a migration, changed data, a changed file, a removed file
      write('database/migrations/003_price.sql', 'ALTER TABLE products ADD COLUMN price DECIMAL(10,2) NULL;\n');
      await sql(File(p.join(src.path, 'database', 'migrations', '003_price.sql')).readAsStringSync(), db: 'demo_local');
      await sql("UPDATE products SET price = 9.90; UPDATE products SET name = 'Claw hammer' WHERE sku = 'P-1';"
          "INSERT INTO products (sku, name, category_id, price) VALUES ('P-4', 'Gloves', 9, 4.50);", db: 'demo_local');
      write('index.php', '${File(p.join(src.path, 'index.php')).readAsStringSync()}// v2\n');
      File(p.join(src.path, 'old.php')).deleteSync();
      report2 = await ops.simulate(project, target);
      expect(report2.changedFiles, ['index.php']);
      expect(report2.removedFiles, ['old.php']);
      expect(report2.migrations.map((m) => p.basename(m.$1)), ['003_price.sql']);
      expect(report2.missing, [('products', 'price')]);
      expect(report2.sync.firstWhere((s) => s.table == 'products').details.map((d) => d.$2), contains('P-1: name "Hammer" → "Claw hammer"'),
          reason: 'old and new values of the synced rows');
      status = await ops.test(target);
      deployed = await ops.deploy(project, target, package: report2.package);
      expect(deployed.ok, true);
      expect([deployed.written, deployed.removed, deployed.migrations.map((m) => m.$1).toList()], [2, 1, ['003_price.sql']]);
      expect(deployed.rowsAdded + deployed.rowsUpdated, 4, reason: 'P-4 added, P-1 renamed, and the 3 prices the migration made room for');
      expect(deployed.backups, hasLength(2));
      products = await ops.tableData(target, 'products');
      expect(products['count'], 4);
      expect([for (final c in products['columns'] as List) (c as Map)['name']], ['id', 'sku', 'name', 'category_id', 'price']);
      expect(await sql("SELECT CONCAT(name, ' ', price) FROM products WHERE sku = 'P-1'", db: 'demo_target'), 'Claw hammer 9.90');
      expect(await sql('SELECT COUNT(*) FROM products', db: 'demo_target'), '4');
      expect(await sql('SELECT COUNT(*) FROM _deploy_migrations', db: 'demo_target'), '3');
      expect(File(p.join(targetDir, 'old.php')).existsSync(), false);
      expect(File(p.join(targetDir, 'uploads', 'customer-photo.txt')).existsSync(), true);
      expect(File(p.join(targetDir, '.env')).readAsStringSync(), contains('demo_target'));
      final again = await ops.simulate(project, target);
      expect(again.upToDate, true);

      // ---- 4. backup, damage, restore
      await ops.backup(target);
      final db = (await ops.backups(target)).firstWhere((f) => '${f['name']}'.startsWith('db-'))['name'] as String;
      await sql('DELETE FROM products', db: 'demo_target');
      await ops.restore(target, db: db);
      expect(await sql('SELECT COUNT(*) FROM products', db: 'demo_target'), '4');
    });

    // ---- 5. screens: light and dark, English and French, wide / medium / narrow windows
    Future<void> shot(String name, AppState app, {Size size = const Size(1440, 900), ThemeMode mode = ThemeMode.light, Finder? tap}) async {
      tester.view.physicalSize = size;
      await tester.pumpWidget(DeploiementApp(app, key: UniqueKey(), themeMode: mode));
      await tester.pumpAndSettle();
      if (tap != null) {
        await tester.tap(tap);
        await tester.pumpAndSettle();
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/$name.png'));
    }

    AppState state(String route) {
      // a second, made-up project, only to fill the side panel
      final other = Project(id: 'blog', name: 'recipe-blog', folder: r'D:\Projects\recipe-blog', targets: [
        Target(id: 'h', name: 'production', url: 'https://recipes.example.com'),
        Target(id: 's', name: 'staging', url: 'http://staging.example.lan/recipes', transport: Transport.folder),
      ]);
      // the guide is shared: no name of this PC, and the last action in the language of the screen
      final shown = {...status, if (status['release'] is Map) 'release': {...(status['release'] as Map), 'source': 'DEV-PC'}};
      final when = RegExp(r'\d\d/\d\d/\d{4} \d\d:\d\d').firstMatch(target.lastAction)?.group(0);
      if (when != null) target.lastAction = tr('Restored {date}', {'date': when});
      final a = AppState(settings: settings, projects: [project, other], persist: false)
        ..reports['local'] = report2
        ..statuses['local'] = shown
        ..health.addAll({'local': true, 's': false})
        ..route = route;
      return a;
    }

    language.value = 'en';
    await shot('1_simulation', state('t:local'), size: const Size(1440, 1000));
    await shot('2_simulation_dark', state('t:local'), size: const Size(1440, 1000), mode: ThemeMode.dark);
    await shot('3_status', state('t:local')..reports.clear());
    final withLog = state('t:local')..activityOpen = true;
    withLog.journal.lines.addAll(log.lines.take(40));
    await shot('4_activity', withLog, size: const Size(1440, 1300));
    await shot('5_target_settings', state('t:local:settings'), size: const Size(1440, 1300));
    await shot('6_project', state('p:demo'), size: const Size(1440, 1700));
    await shot('7_home', state('home'));
    await shot('8_medium_760', state('t:local'), size: const Size(760, 1000));
    await shot('9_narrow_480', state('t:local'), size: const Size(480, 1000), mode: ThemeMode.dark);
    await shot('11_menu_narrow', state('t:local'), size: const Size(480, 1000), tap: find.byTooltip('Menu'));
    await shot('12_confirm_deploy', state('t:local'), size: const Size(1440, 1000), tap: find.widgetWithText(FilledButton, 'Deploy'));
    await shot('13_first_run', AppState(settings: settings, projects: [], persist: false), mode: ThemeMode.dark);
    // after a deployment: what it did, and the history of the target
    final older = DeployResult.fromJson({...deployed.toJson(), 'time': '2026-11-10T16:20:00', 'ok': false, 'error': 'Import stopped: table exists'});
    await shot('17_deploy_result', state('t:local')
      ..reports.clear()
      ..lastResult['local'] = deployed
      ..history['local'] = [deployed, older], size: const Size(1440, 1300));
    // a table of the target, read only
    final tb = state('t:local');
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpWidget(DeploiementApp(tb, key: UniqueKey(), themeMode: ThemeMode.light));
    await tester.pumpAndSettle();
    showTableBrowser(tb.navigatorKey.currentContext!, settings, target, 'products', load: (_) async => products);
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/18_table_browser.png'));
    // the structure of a table on both sides
    final st = state('t:local');
    await tester.pumpWidget(DeploiementApp(st, key: UniqueKey(), themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('products').first);
    await tester.tap(find.descendant(of: find.byType(LedgerRow), matching: find.text('products')).first);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(SingleChildScrollView).first, const Offset(0, -700));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/19_structure_dark.png'));
    // clone to this PC
    await shot('20_clone_dialog', state('t:local'), size: const Size(1440, 900));
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clone to this PC…'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/20_clone_dialog.png'));
    expect(find.text('Production is only read'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(ResultView), findsNothing);
    // the comparison screen: index.php on the target (before) and on this PC (after a few changes)
    final before = File(p.join(src.path, 'index.php')).readAsStringSync().replaceAll('// v2\n', '');
    final changed = before.replaceFirst('ORDER BY p.sku', 'ORDER BY c.name, p.sku').replaceFirst(r'echo "{$r[', r'printf("%s ", $r[');
    final after = '$changed// v2\n';
    Future<void> diffShot(String name, Size size) async {
      final a = state('t:local');
      tester.view.physicalSize = size;
      await tester.pumpWidget(DeploiementApp(a, key: UniqueKey(), themeMode: ThemeMode.light));
      await tester.pumpAndSettle();
      showFileDiff(a.navigatorKey.currentContext!, settings, project, target, 'index.php', 'M',
          versions: Future.value((Uint8List.fromList(before.codeUnits), Uint8List.fromList(after.codeUnits))));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/$name.png'));
    }

    await diffShot('14_compare_side_by_side', const Size(1440, 900));
    await diffShot('15_compare_one_column', const Size(760, 900));
    final filtered = state('t:local');
    tester.view.physicalSize = const Size(1440, 1000);
    await tester.pumpWidget(DeploiementApp(filtered, key: UniqueKey(), themeMode: ThemeMode.light));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(RegExp(r'^CHANGED\s+\d'), findRichText: true));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/16_files_changed_only.png'));
    language.value = 'fr';
    settings.language = 'fr';
    await shot('10_simulation_fr', state('t:local'), size: const Size(1440, 1000));
    language.value = 'en';
    settings.language = 'en';

    // ---- frames of the video guide (test/video/<lang>/*.png), in English and in French: the whole flow, the loader frame by frame
    for (final lang in ['en', 'fr']) {
      language.value = lang;
      settings.language = lang;
      Future<void> frame(String name) => expectLater(find.byType(MaterialApp), matchesGoldenFile('video/$lang/$name.png'));
      Future<AppState> open(AppState a, {Size size = const Size(1440, 900), ThemeMode mode = ThemeMode.light}) async {
        tester.view.physicalSize = size;
        await tester.pumpWidget(DeploiementApp(a, key: UniqueKey(), themeMode: mode));
        await tester.pumpAndSettle();
        return a;
      }

      Future<void> scrollBy(double dy) async {
        await tester.drag(find.byType(SingleChildScrollView).first, Offset(0, -dy));
        await tester.pumpAndSettle();
      }

      /// An operation running: [steps] = (text of the current step, a line done after it) per group of frames.
      Future<void> working(String name, String title, List<(String, String?)> steps, {int perStep = 3}) async {
        final a = state('t:local')..reports.clear();
        a
          ..busy = true
          ..busyTarget = 'local'
          ..busySince = DateTime.now().subtract(const Duration(seconds: 2))
          ..activityOpen = false;
        a.journal.step(title);
        tester.view.physicalSize = const Size(1440, 900);
        await tester.pumpWidget(DeploiementApp(a, key: UniqueKey(), themeMode: ThemeMode.light));
        await tester.pump(const Duration(milliseconds: 600));
        var n = 0;
        for (final (now, done) in steps) {
          a.journal.progress(now);
          for (var i = 0; i < perStep; i++) {
            await tester.pump(const Duration(milliseconds: 120));
            await frame('${name}_${(++n).toString().padLeft(2, '0')}');
          }
          if (done != null) a.journal.ok(done);
        }
        await tester.pumpWidget(const SizedBox());
      }

      final via = target.transport.label;
      await open(AppState(settings: settings, projects: [], persist: false));
      await frame('01_first_run');
      await open(state('home')
        ..reports.clear()
        ..statuses.clear());
      await frame('02_overview');
      await open(state('p:demo'));
      await frame('03_project');
      await open(state('t:local:settings'));
      await frame('04_target_settings');
      await open(state('t:local')
        ..reports.clear()
        ..statuses.clear()
        ..health.clear());
      await frame('05_getting_started');
      await working('06_placing', tr('Placing the agent on "{name}" ({transport})', {'name': 'staging', 'transport': via}), [
        ('deploy-agent.php: 100 %', tr('Agent placed: {url}', {'url': 'http://localhost/DEMO_SHOP/deploy-agent.php'})),
        (tr('Test of "{name}" ({url})', {'name': 'staging', 'url': target.baseUrl}),
            tr('Agent reachable: PHP {php} on {os}{server}.', {'php': '8.2.12', 'os': 'Windows', 'server': ' (Apache/2.4.58)'})),
      ]);
      await open(state('t:local')..reports.clear());
      await frame('07_status');
      await working('08_simulating', tr('Simulation: what "Deploy" would do on "{name}"', {'name': 'staging'}), [
        (tr('Reading the project files…'), tr('{n} of {total} file(s) differ on the target: only they are sent.', {'n': 1, 'total': 7})),
        (tr('Sending the package ({mb}) by {transport}…', {'mb': '0.0 MB', 'transport': via}), tr('Package received and checked by the target.')),
        (tr('Local database structure…'),
            tr('Synced tables{sim}: +{add} added, {upd} updated, {skp} skipped.', {'sim': ' (${tr('simulation')})', 'add': 1, 'upd': 1, 'skp': 0})),
        (tr('Rows of the synced tables…'), null),
      ]);
      await open(state('t:local'));
      await frame('09_report');
      await scrollBy(560);
      await frame('10_report_database');
      await scrollBy(520);
      await frame('11_report_rows');
      final cmp = await open(state('t:local'));
      showFileDiff(cmp.navigatorKey.currentContext!, settings, project, target, 'index.php', 'M',
          versions: Future.value((Uint8List.fromList(before.codeUnits), Uint8List.fromList(after.codeUnits))));
      await tester.pumpAndSettle();
      await frame('12_compare');
      final tbl = await open(state('t:local'));
      showTableBrowser(tbl.navigatorKey.currentContext!, settings, target, 'products', load: (_) async => products);
      await tester.pumpAndSettle();
      await frame('13_table');
      await open(state('t:local'));
      await tester.tap(find.byKey(const ValueKey('target-deploy')));
      await tester.pumpAndSettle();
      await frame('14_confirm');
      await working(
          '15_deploying',
          tr('Deploying "{project}" to "{target}": files, migrations, synced tables — the target keeps its data', {'project': 'demo-shop', 'target': 'staging'}), [
        (tr('Backup of the target database and files…'), tr('Backup done on the target: {files}.', {'files': 'db-20261115.sql.gz, files-20261115.zip'})),
        (tr('Migrations to run: {n}.', {'n': 1}), tr('{n} migration(s) run.', {'n': 1})),
        (tr('Writing the files…'), tr('{written} file(s) written, {removed} removed, {same} already up to date.', {'written': 2, 'removed': 1, 'same': 2})),
        (tr('Rows of the synced tables…'), null),
      ]);
      final earlier = DeployResult.fromJson({...deployed.toJson(), 'time': '2026-11-10T16:20:00'});
      await open(state('t:local')
        ..reports.clear()
        ..lastResult['local'] = deployed
        ..history['local'] = [deployed, earlier]);
      await frame('16_result');
      await scrollBy(900);
      await frame('17_history');
      await open(state('t:local')..reports.clear());
      await tester.tap(find.byKey(const ValueKey('target-more')));
      await tester.pumpAndSettle();
      await frame('18_more');
      await tester.tap(find.text(tr('Clone to this PC…')));
      await tester.pumpAndSettle();
      await frame('19_clone');
      await open(state('t:local'), mode: ThemeMode.dark);
      await frame('20_dark');
      await open(state('t:local'), size: const Size(520, 900));
      await frame('21_narrow');
    }
    language.value = 'en';
    settings.language = 'en';
  }, timeout: const Timeout(Duration(minutes: 10)));
}
