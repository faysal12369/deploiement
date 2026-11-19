// The screens of "structure / data per table": the block of the project page (two boxes per table, the data options
// only with "Data") and what a simulation shows for the structure of the chosen tables.
// Run: flutter test test/tables_screens_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:deploiement/app_state.dart';
import 'package:deploiement/dialogs.dart';
import 'package:deploiement/operations.dart';
import 'package:deploiement/git.dart';
import 'package:deploiement/i18n.dart';
import 'package:deploiement/main.dart';
import 'package:deploiement/models.dart';
import 'package:deploiement/report_view.dart';
import 'package:deploiement/results.dart';
import 'package:deploiement/theme.dart';
import 'package:deploiement/widgets.dart';

Future<void> fonts() async {
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files.where((f) => File(f).existsSync())) {
      l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
    }
    await l.load();
  }

  await load('Segoe UI', [r'C:\Windows\Fonts\segoeui.ttf', r'C:\Windows\Fonts\seguisb.ttf', r'C:\Windows\Fonts\segoeuib.ttf']);
  await load('Bahnschrift', [r'C:\Windows\Fonts\bahnschrift.ttf']);
  await load('Cascadia Mono', [r'C:\Windows\Fonts\CascadiaMono.ttf', r'C:\Windows\Fonts\consola.ttf']);
  await load('MaterialIcons', [r'D:\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf']);
}

void main() {
  Git.offline = true;

  testWidgets('the tables block and the structure of a simulation', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 3000);
    addTearDown(tester.view.reset);
    addTearDown(() => language.value = 'en');
    language.value = 'fr';
    await tester.runAsync(fonts);

    final movements = SyncTable(table: 'mouvements_stock', structure: true, data: false);
    final categories = SyncTable(table: 'categories', structure: true, data: true, key: ['code']);
    final p = Project.create()
      ..name = 'erp'
      ..folder = r'C:\sites\erp'
      ..localDb = DbSettings(name: 'erp_local')
      ..sync = [movements, categories, SyncTable(table: 'parametres', key: ['cle'])];
    final app = AppState(settings: AppSettings()..language = 'fr', projects: [p], persist: false)..route = 'p:${p.id}';
    await tester.pumpWidget(DeploiementApp(app, themeMode: ThemeMode.light));
    await tester.pumpAndSettle();

    // the data options only for the tables whose data is sent
    expect(find.text('Tables : structure et données'), findsOneWidget);
    expect(find.text('Clé (auto)'), findsNWidgets(2));
    // the page works on a copy, saved by itself a moment after a change
    SyncTable saved() {
      return app.projects.single.sync.firstWhere((s) => s.table == 'mouvements_stock');
    }

    Future<void> autosaved() async {
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    }

    // one control per table, three positions (19/11/2026: "make it easier")
    Future<void> pick(String label) async {
      final f = find.descendant(of: find.byKey(const ValueKey('table-pick-mouvements_stock')), matching: find.text(label));
      await tester.ensureVisible(f);
      await tester.tap(f);
    }

    await pick('Structure + données');
    await autosaved();
    expect([saved().structure, saved().data], [true, true]);
    expect(find.text('Clé (auto)'), findsNWidgets(3));
    await pick('Rien');
    await autosaved();
    expect([saved().structure, saved().data], [false, false]);
    expect(find.text("Ni structure ni données : cette table n'est pas envoyée."), findsOneWidget);
    await pick('Structure');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Tables : structure et données'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/t1_tables_block.png'));

    // what a simulation shows
    final changes = [
      TableChange('mouvements_stock', changes: [
        (what: 'add_column', name: 'note', sql: 'ALTER TABLE `mouvements_stock` ADD COLUMN `note` varchar(200) DEFAULT NULL AFTER `qty`', before: '', after: ''),
        (what: 'change_column', name: 'qty', sql: '', before: '`qty` int(11) NOT NULL DEFAULT 0', after: '`qty` decimal(12,3) NOT NULL DEFAULT 0.000'),
        (what: 'add_key', name: 'idx_ref', sql: 'ALTER TABLE `mouvements_stock` ADD KEY `idx_ref` (`ref`)', before: '', after: ''),
      ], kept: ['server_flag']),
      TableChange('categories', create: true, changes: [(what: 'create', name: 'categories', sql: 'CREATE TABLE …', before: '', after: '')]),
      TableChange('parametres'),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: Padding(padding: const EdgeInsets.all(24), child: Section('Structure des tables choisies', icon: Icons.table_chart_outlined, child: TableChanges(changes)))),
    ));
    await tester.pumpAndSettle();
    expect(find.text('créée'), findsOneWidget);
    expect(find.text('+1 colonne'), findsOneWidget);
    expect(find.text('1 colonne modifiée'), findsOneWidget);
    expect(find.text('Seulement sur la cible, gardées : server_flag'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/t2_table_changes.png'));
  });

  testWidgets('Deploy: the tables that changed, structure or data each', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);
    addTearDown(() => language.value = 'en');
    language.value = 'fr';
    await tester.runAsync(fonts);
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), debugShowCheckedModeBanner: false, home: Builder(builder: (c) {
      ctx = c;
      return const Scaffold();
    })));
    final pr = Project.create()
      ..name = 'Shop'
      ..compareCountOnly = ['*_log', '*sessions*']
      // order_suppliers: data ticked in the list before the app knew it had no key (as on 18/11/2026)
      ..sync = [SyncTable(table: 'currencies', data: true), SyncTable(table: 'purchase_orders', data: true), SyncTable(table: 'order_suppliers', data: true)];
    Map<String, Map<String, dynamic>> cols(List<String> names) => {for (final n in names) n: {'type': 'int(11)', 'null': false}};
    final r = Report(target: 'serveur', package: 'x.zip', status: {}, plan: {
      'new': ['a.php'], 'changed': [], 'removed': [], 'total': 900, 'db_ok': true, 'migrations': {'run': []},
    })
      ..localStructure = {'stock_items': cols(['id', 'code']), 'stock_counts': cols(['id']), 'currencies': cols(['id']), 'activity_log': cols(['id'])}
      ..targetStructure = {'stock_items': cols(['id', 'code']), 'currencies': cols(['id']), 'activity_log': cols(['id'])}
      ..localCounts = {'stock_items': 19931, 'stock_counts': 12, 'currencies': 4, 'activity_log': 9002}
      ..targetCounts = {'stock_items': 2, 'currencies': 4, 'activity_log': 8771, 'order_suppliers': 79}
      ..localNoKey = {'order_suppliers'};
    r.localCounts['order_suppliers'] = 85;
    final Map<String, Map<String, dynamic>> counter = {'id': {'type': 'int(10) unsigned', 'null': false, 'key': 'PRI', 'extra': 'auto_increment'}, 'fiche_id': {'type': 'int(10) unsigned', 'null': false}};
    r.localStructure!['order_suppliers'] = counter;
    r.targetStructure!['order_suppliers'] = counter;
    // what the simulation found for the tables whose data goes (asked 18/11/2026: "how many données manquantes")
    r.localStructure!['purchase_orders'] = r.targetStructure!['purchase_orders'] = cols(['id', 'numero']);
    r.localCounts['purchase_orders'] = 553;
    r.targetCounts['purchase_orders'] = 4;
    r.sync = [
      SyncResult('currencies', 0, 0, 4, 0, [], []),
      SyncResult('purchase_orders', 547, 2, 2, 2,
          [('add', 'BC-0001'), ('skip', 'BC-0412: fournisseur_id → suppliers F-0099 not on the target'), ('skip', 'BC-0413: empty numero')], []),
    ];

    final names = [for (final c in tableCandidates(pr, r)) c.table];
    expect(names, ['order_suppliers', 'purchase_orders', 'stock_counts', 'stock_items', 'currencies'],
        reason: 'what differs first, the logs left out, the list always');

    final result = confirmDeploy(ctx, Target(id: 't', name: 'Server 192.168.1.10', url: 'http://x'), r, project: pr);
    await tester.pumpAndSettle();
    expect(find.text('19 931 lignes ici, 2 sur la cible'), findsOneWidget);
    expect(find.text('absente de la cible · 12 lignes ici'), findsOneWidget);
    expect(find.text('Déployer'), findsWidgets);
    // no key: "Data" cannot be ticked (18/11/2026 it stopped the simulation)
    expect(find.text('85 lignes ici, 79 sur la cible · clé primaire « id » = simple compteur (autres numéros sur la cible) : données impossibles à envoyer'),
        findsOneWidget, reason: '18/11/2026: "but it has a primary key" — the hint says that key is a counter');
    final noKeyData = tester.widget<TablePick>(find.byKey(const ValueKey('deploy-pick-order_suppliers'), skipOffstage: false));
    expect((noKeyData.position, noKeyData.dataEnabled), (TablePick.none, false), reason: '18/11/2026 "wtf???": ticked next to "data cannot be sent"');
    expect(find.byKey(const ValueKey('deploy-rows-order_suppliers')), findsNothing, reason: 'no "85 écartées" in red: the hint says why');
    // the rows of each table: missing on the target, to update, left out (why: hovering), the same
    expect(find.text('553 lignes ici, 4 sur la cible'), findsOneWidget);
    expect(find.text('547 manquantes sur la cible, à ajouter · 2 à mettre à jour · 2 écartées · 2 déjà identiques', findRichText: true), findsOneWidget);
    final why = tester.widget<Tooltip>(find.ancestor(of: find.byKey(const ValueKey('deploy-rows-purchase_orders')), matching: find.byType(Tooltip)));
    expect(why.message, '× BC-0412: fournisseur_id → suppliers F-0099 not on the target\n× BC-0413: empty numero', reason: 'the rows left out, not the added ones');
    final devises = tableCandidates(pr, r).firstWhere((c) => c.table == 'currencies'); // below the fold of the list
    expect([for (final (t, _) in tableRowsLine(devises, Theme.of(ctx).extension<Palette>()!)) t], ['4 déjà identiques']);
    expect(find.text('19 929 lignes de plus ici, données non envoyées', findRichText: true), findsOneWidget, reason: 'data not sent: only the difference');
    final bothOfArticles = find.descendant(of: find.byKey(const ValueKey('deploy-pick-stock_items'), skipOffstage: false), matching: find.text('Structure + données'));
    await tester.ensureVisible(bothOfArticles);
    await tester.pumpAndSettle();
    await tester.tap(bothOfArticles);
    await tester.pumpAndSettle();
    expect(find.text('Simuler avec ce choix'), findsOneWidget);
    expect(find.text('19 929 lignes de plus ici', findRichText: true), findsOneWidget, reason: 'ticked: no more "data not sent"');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/t3_deploy_tables.png'));
    await tester.tap(find.byKey(const ValueKey('confirm-deploy')));
    await tester.pumpAndSettle();
    final c = (await result)!;
    expect(c.tables!['stock_items'], (structure: true, data: true), reason: 'its data, with its structure');
    final before = pr.tablesKey;
    applyTableChoice(pr, c.tables!);
    expect(pr.tablesKey, isNot(before), reason: 'a simulation made before this choice is made again before deploying');
    expect([for (final s in pr.sync) '${s.table} ${s.structure} ${s.data}'], ['currencies false true', 'purchase_orders false true', 'stock_items true true'],
        reason: 'the no-key table leaves the list with the choice');

    // "Deploy" takes the data of a no-key table out of the list before asking; the agent's "left out" for it is not counted
    final pr2 = Project.create()..sync = [SyncTable(table: 'order_suppliers', data: true, structure: true), SyncTable(table: 'currencies', data: true)];
    expect(dropNoKeyData(pr2, r), ['order_suppliers']);
    expect([for (final s in pr2.sync) '${s.table} ${s.structure} ${s.data}'], ['order_suppliers true false', 'currencies false true']);
    expect(dropNoKeyData(pr2, r), isEmpty);
    expect([for (final s in syncResults([
      {'table': 'order_suppliers', 'added': 0, 'updated': 0, 'same': 0, 'skipped': 85, 'nokey': true},
      {'table': 'currencies', 'added': 0, 'updated': 0, 'same': 4, 'skipped': 0},
    ])) s.table], ['currencies']);
  });
}
