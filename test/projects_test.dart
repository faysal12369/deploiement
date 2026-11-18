// Projects in the app itself, through its screens: create one, change it, add a target, export it, import it back,
// refuse a wrong file, reopen the app, remove a project. The Windows file dialogs are answered by the test
// (pickers.testAnswers) and the settings go to a scratch folder (Store.testFolder), never to the real ones.
// Run: flutter test test/projects_test.dart --update-goldens
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:deploiement/app_state.dart';
import 'package:deploiement/git.dart';
import 'package:deploiement/i18n.dart';
import 'package:deploiement/main.dart';
import 'package:deploiement/models.dart';
import 'package:deploiement/pickers.dart' as pickers;
import 'package:deploiement/widgets.dart';

final scratch = Directory(p.join(Directory.systemTemp.path, 'php-deploy-projects-test'));

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
  Git.offline = true; // the project page does not run git in these screens
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('projects: create, change, add a target, export, import, wrong file, reopen, remove', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 2400); // the whole page fits: nothing to scroll to
    addTearDown(tester.view.reset);
    language.value = 'en';

    // ---- a scratch settings folder and a project folder "on this PC"
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    final settingsDir = Directory(p.join(scratch.path, 'settings'))..createSync(recursive: true);
    final shop = Directory(p.join(scratch.path, 'my-shop'));
    Directory(p.join(shop.path, 'database', 'migrations')).createSync(recursive: true);
    File(p.join(shop.path, 'index.php')).writeAsStringSync('<?php echo "shop";');
    final exported = p.join(scratch.path, 'my-shop.deploy.json');
    Store.testFolder = settingsDir.path;
    pickers.testAnswers = [];
    addTearDown(() {
      Store.testFolder = null;
      pickers.testAnswers = null;
    });
    final config = File(p.join(settingsDir.path, 'config.json'));
    await tester.runAsync(fonts);

    final app = AppState();
    expect(app.projects, isEmpty, reason: 'a fresh settings folder');
    await tester.pumpWidget(DeploiementApp(app, themeMode: ThemeMode.light));
    await tester.pumpAndSettle();

    Finder field(String label) => find.descendant(of: find.widgetWithText(Field, label), matching: find.byType(TextField));
    Finder inPanel(String text) => find.descendant(of: find.byType(SidePanel), matching: find.text(text));
    // the settings save themselves a moment after a change
    Future<void> autosaved() async {
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Saved automatically'), findsOneWidget);
    }

    Future<void> tap(Finder f) async {
      expect(f, findsOneWidget);
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    // ---- 1. new project: its folder is asked first (Cancel: nothing created); it gives the name and the migrations
    await tap(find.widgetWithText(FilledButton, 'New project'));
    expect(app.projects, isEmpty, reason: 'folder dialog cancelled');
    pickers.testAnswers!.add(shop.path);
    await tap(find.widgetWithText(FilledButton, 'New project'));
    expect(app.projects, hasLength(1));
    expect(app.route, 'p:${app.projects.first.id}');
    expect(find.text('Project "my-shop" created.'), findsOneWidget);
    expect(tester.widget<TextField>(field('Name')).controller!.text, 'my-shop');
    expect(tester.widget<TextField>(field('Folder on this PC')).controller!.text, shop.path);
    expect(tester.widget<TextField>(field('Folder (relative to the project)')).controller!.text, 'database/migrations');
    await tester.enterText(field('Kept on the targets'), '.env\nstorage/\nuploads/\nconfig/local.php');
    await autosaved();
    final pr = app.projects.first;
    expect(pr.name, 'my-shop');
    // The folder can be changed later with Browse (here: the same one).
    pickers.testAnswers!.add(shop.path);
    await tap(find.byTooltip('Browse'));
    expect(tester.widget<TextField>(field('Folder on this PC')).controller!.text, shop.path);
    expect(pr.folder, shop.path);
    expect(pr.migrationsFolder, 'database/migrations');
    expect(pr.keep, contains('config/local.php'));
    expect(jsonDecode(config.readAsStringSync())['projects'][0]['name'], 'my-shop', reason: 'saved to disk');

    // ---- 2. change it: the new name shows in the side panel
    await tester.enterText(field('Name'), 'My shop');
    await autosaved();
    expect(pr.name, 'My shop');
    expect(inPanel('My shop'), findsOneWidget);

    // ---- 3. a target, with a password stored encrypted
    await tap(find.widgetWithText(OutlinedButton, 'Add a target'));
    expect(app.route, endsWith(':settings'));
    await tester.enterText(field('Name'), 'production');
    await tester.enterText(field('Address of the project'), 'https://shop.example.com');
    await tester.enterText(field('Host'), 'ftp.example.com');
    await tester.enterText(field('User'), 'u123');
    await tester.enterText(field('Password'), 'secret-ftp');
    await tester.enterText(field('Project folder on the server'), '/public_html');
    await autosaved();
    final t = pr.targets.single;
    expect([t.name, t.url, t.host, t.user, t.pass, t.remotePath], ['production', 'https://shop.example.com', 'ftp.example.com', 'u123', 'secret-ftp', '/public_html']);
    expect(config.readAsStringSync(), isNot(contains('secret-ftp')), reason: 'passwords are encrypted on disk');
    expect(config.readAsStringSync(), contains('dpapi:'));
    expect(inPanel('production'), findsOneWidget);

    // ---- 4. export: no password, no key
    await tap(inPanel('My shop'));
    pickers.testAnswers!.add(exported);
    await tap(find.widgetWithText(TextButton, 'Export…'));
    final ex = jsonDecode(File(exported).readAsStringSync()) as Map<String, dynamic>;
    expect(ex['php_deploy_project'], 1);
    expect(ex['name'], 'My shop');
    expect((ex['keep'] as List), contains('config/local.php'));
    final exT = (ex['targets'] as List).single as Map;
    expect([exT['host'], exT['user'], exT['pass'], exT['token']], ['ftp.example.com', 'u123', '', '']);
    expect(File(exported).readAsStringSync(), isNot(contains('secret')));

    // ---- 5. import it back: a second project, new ids and keys, same settings
    pickers.testAnswers!.add(exported);
    await tap(find.text('Import a project…'));
    expect(app.projects, hasLength(2));
    final im = app.projects.last;
    final imT = im.targets.single;
    expect(im.name, 'My shop (2)', reason: 'the name is already taken');
    expect(im.id, isNot(pr.id));
    expect(imT.id, isNot(t.id));
    expect(imT.token, isNot(t.token));
    expect(imT.token, hasLength(64));
    expect(imT.agentName, allOf(startsWith('deploy-agent-'), isNot(t.agentName)), reason: 'its own agent, next to the one of the other PC: neither replaces the other');
    expect(imT.pass, '');
    expect([imT.url, imT.host, imT.user, imT.remotePath], [t.url, t.host, t.user, t.remotePath]);
    expect([im.folder, im.keep, im.exclude, im.migrationsFolder], [pr.folder, pr.keep, pr.exclude, pr.migrationsFolder]);
    expect(app.route, 'p:${im.id}');
    expect(inPanel('My shop (2)'), findsOneWidget);
    expect(find.text('"My shop (2)" imported.'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/p1_imported.png'));

    // ---- 6. wrong files are refused
    final notOurs = File(p.join(scratch.path, 'package.json'))..writeAsStringSync('{"name": "something-else"}');
    final notJson = File(p.join(scratch.path, 'notes.json'))..writeAsStringSync('hello');
    for (final f in [notOurs, notJson]) {
      pickers.testAnswers!.add(f.path);
      await tap(find.text('Import a project…'));
      expect(app.projects, hasLength(2));
      expect(find.text('Import failed'), findsOneWidget);
      expect(find.text('This is not a Déploiement project file.'), findsOneWidget);
    }
    // Cancel in the file dialog: nothing happens.
    await tap(find.text('Import a project…'));
    expect(app.projects, hasLength(2));

    // ---- 7. change the imported project and leave the page at once (no button, no wait), then reopen the app:
    // everything is still there
    await tester.enterText(field('Never run'), '*_down.sql');
    await tester.pump();
    expect(find.text('Saving…'), findsOneWidget);
    app.go('home');
    await tester.pump();
    await tap(inPanel('My shop (2)'));
    final reopened = AppState();
    expect(reopened.projects.map((x) => x.name), ['My shop', 'My shop (2)']);
    expect(reopened.projects.first.targets.single.pass, 'secret-ftp');
    expect(reopened.projects.last.targets.single.pass, '');
    expect(reopened.projects.last.migrationsSkip, '*_down.sql');
    expect(reopened.projects.first.migrationsSkip, '*_rollback.sql');

    // ---- 8. delete the imported project (after a confirmation)
    await tap(find.widgetWithText(OutlinedButton, 'Delete this project…'));
    await tap(find.widgetWithText(FilledButton, 'Delete'));
    expect(app.projects.map((x) => x.name), ['My shop']);
    expect(app.route, 'home');
    expect((jsonDecode(config.readAsStringSync())['projects'] as List), hasLength(1));
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pump(const Duration(seconds: 10)); // let the last message go
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/p2_overview.png'));
  });
}
