// What the pages showed comes back after Déploiement is closed and reopened: the last test, the last simulation and the
// last error of each target, and the activity log (state.json next to the settings, here in a temporary folder).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:deploiement/app_state.dart';
import 'package:deploiement/models.dart';
import 'package:deploiement/operations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('closed and reopened: the last test, simulation, error and log are back', () {
    final dir = Directory.systemTemp.createTempSync('php-deploy-state');
    Store.testFolder = dir.path;
    addTearDown(() {
      Store.testFolder = null;
      dir.deleteSync(recursive: true);
    });
    final t = Target(id: 'h', name: 'hostinger', url: 'https://example.com');
    final gone = Target(id: 'g', name: 'removed later', url: 'https://old.example.com');
    Store.save(AppSettings(), [Project(id: 'p', name: 'erp', folder: r'C:\site', targets: [t, gone])]);

    // ---- first run: a test, a simulation, an error, a few log lines
    final a = AppState();
    final when = DateTime(2026, 11, 15, 16, 42);
    a.statuses['h'] = {'agent': 5, 'php': '8.3.36', 'db': {'ok': true, 'name': 'u1_erp', 'tables': 154}};
    a.health['h'] = true;
    a.errors['h'] = 'FTP login refused';
    a.reports['h'] = Report(
      target: 'hostinger',
      package: 'release-1.zip',
      time: when,
      plan: {
        'new': ['a.php'],
        'changed': ['index.php', 'config/session.php'],
        'removed': [],
        'total': 120,
        'db_ok': true,
        'migrations': {'run': [{'path': 'database/migrations/003_x.sql', 'reason': 'new'}], 'baseline': [], 'tracked': true},
      },
      status: {'agent': 5},
    )
      ..missing = [('products', 'price'), ('colors', null)]
      ..sync = [SyncResult('colors', 2, 1, 5, 0, [('R', 'name "Red"')], [], pending: 0, columns: ['code', 'name'])]
      ..summary = DbSummary(154, 9000, [('users', 12)])
      ..localStructure = {'products': {'price': {'type': 'decimal(10,2)'}}}
      ..targetStructure = {'products': {}};
    a.statuses['g'] = {'agent': 4};
    a.journal
      ..step('Simulation: what "Deploy" would do on "hostinger"')
      ..ok('Simulation done: nothing was changed on the target.');
    SavedState.save(a);
    a.dispose();

    // the target "g" is removed before the next start: what it showed is dropped
    Store.save(AppSettings(), [Project(id: 'p', name: 'erp', folder: r'C:\site', targets: [t])]);

    // ---- reopened
    final b = AppState();
    addTearDown(b.dispose);
    expect(b.statuses['h']?['php'], '8.3.36');
    expect((b.statuses['h']?['db'] as Map)['tables'], 154);
    expect(b.health['h'], true);
    expect(b.errors['h'], 'FTP login refused');
    expect(b.statuses.containsKey('g'), false);
    final r = b.reports['h']!;
    expect(r.time, when);
    expect(r.changedFiles, ['index.php', 'config/session.php']);
    expect(r.migrations.map((m) => m.$1), ['database/migrations/003_x.sql']);
    expect(r.missing, [('products', 'price'), ('colors', null)]);
    expect([r.rowsAdded, r.rowsUpdated], [2, 1]);
    expect(r.sync.single.details.single, ('R', 'name "Red"'));
    expect([r.summary!.tables, r.summary!.rowsOf('users')], [154, 12]);
    expect(r.localStructure!['products']!['price']!['type'], 'decimal(10,2)');
    expect(r.targetStructure, {'products': <String, Map<String, dynamic>>{}});
    final texts = b.journal.lines.map((l) => l.text).toList();
    expect(texts.take(2), ['Simulation: what "Deploy" would do on "hostinger"', 'Simulation done: nothing was changed on the target.']);
    expect(texts.last, 'Déploiement reopened: the lines above are from before.');
    expect(b.journal.lines.first.level, Level.step);
  });
}
