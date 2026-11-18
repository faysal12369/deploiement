// The GitHub parts of the screens, in French: the block of the project page (a folder that is not a repository yet,
// then a repository linked to a remote), the "Send to GitHub" dialog (with a file that looks like a password), and
// the "GitHub" box of Deploy. Images in test/captures/github_*.png.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:deploiement/app_state.dart';
import 'package:deploiement/dialogs.dart';
import 'package:deploiement/git.dart';
import 'package:deploiement/i18n.dart';
import 'package:deploiement/main.dart';
import 'package:deploiement/models.dart';
import 'package:deploiement/operations.dart';

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

  testWidgets('GitHub on the screens', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 1700);
    addTearDown(tester.view.reset);
    final root = Directory.systemTemp.createTempSync('deploiement-gh');
    addTearDown(() => root.deleteSync(recursive: true));
    final src = Directory(p.join(root.path, 'shop'))..createSync();
    File(p.join(src.path, 'index.php')).writeAsStringSync('<?php echo 1;');
    File(p.join(src.path, '.env')).writeAsStringSync('DB_PASSWORD=x');
    await tester.runAsync(fonts);
    language.value = 'fr';
    final project = Project(id: 'shop', name: 'shop', folder: src.path, gitBranch: 'main');
    final app = AppState(settings: AppSettings()..language = 'fr', projects: [project], persist: false)..route = 'p:shop';

    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 250))); // git runs for real
        await tester.pumpAndSettle();
      }
    }

    Future<void> shotProject(String name) async {
      await tester.pumpWidget(DeploiementApp(app, key: UniqueKey(), themeMode: ThemeMode.light));
      await settle();
      await tester.scrollUntilVisible(find.text('GitHub').first, 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/github_$name.png'));
    }

    // ---- not a repository yet
    await shotProject('1_not_a_repository');
    expect(find.text('Créer le dépôt Git ici'), findsOneWidget);

    // ---- a repository linked to a remote, with changes
    await tester.runAsync(() async {
      await Git(src.path).create(branch: 'main', ignore: ['.env']);
      await Process.run('git', ['init', '--bare', '-q', p.join(root.path, 'remote.git')]);
      await Git(src.path).link(p.join(root.path, 'remote.git'));
    });
    project.gitRemote = p.join(root.path, 'remote.git');
    File(p.join(src.path, 'config.local.php')).writeAsStringSync('<?php');
    await shotProject('2_linked');
    // the block reads the folder when the page opens; git ran meanwhile in the test: Refresh, like a user would
    await tester.tap(find.byTooltip('Actualiser'));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 250)));
      await tester.pumpAndSettle();
    }
    expect(find.text('Envoyer sur GitHub…'), findsOneWidget);

    // ---- the "Send to GitHub" dialog
    final st = (await tester.runAsync(() => Git(src.path).state()))!;
    showDialog(context: app.navigatorKey.currentContext!, builder: (_) => const SizedBox()); // a route above, closed at once
    Navigator.of(app.navigatorKey.currentContext!).pop();
    final ctx = app.navigatorKey.currentContext!;
    confirmGitSend(ctx, st, 'main');
    await tester.pumpAndSettle();
    expect(find.textContaining('ressemblent à des mots de passe'), findsOneWidget, reason: 'config.local.php is flagged');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/github_3_send_dialog.png'));
    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();

    // ---- the "GitHub" box of Deploy, ticked when the project is linked
    tester.view.physicalSize = const Size(1440, 900);
    final r = Report(target: 'staging', package: 'x.zip', plan: {'new': ['a.php'], 'changed': [], 'removed': [], 'db_ok': true, 'migrations': {'run': []}}, status: {});
    confirmDeploy(ctx, Target(id: 't', name: 'staging', url: 'https://example.com'), r, gitBranch: 'main'); // no project: no table to choose
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('part-github')), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/github_4_deploy_box.png'));
  });
}
