// "Save the agent to a file" for a target "Agent only" of a project imported on another PC (19/11/2026: "it does not
// create the agent.php, so I can put it into the target folder"): the app asks where to save it, writes it there under
// the target's agent name (even if another name was typed) and says where it is; Cancel writes nothing; an error is
// shown, never swallowed.
// Run: flutter test test/save_agent_test.dart
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
import 'package:deploiement/project_file.dart';

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

  testWidgets('the agent is saved where the user chooses', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.reset);
    addTearDown(() => language.value = 'en');
    language.value = 'fr';
    await tester.runAsync(fonts);
    final root = (await tester.runAsync(() async => Directory.systemTemp.createTempSync('deploiement-save-agent')))!;
    addTearDown(() => root.deleteSync(recursive: true));
    addTearDown(() => pickers.testAnswers = null);

    // ---- a project exported on one PC, imported on another: its target gets a new agent name and key
    final server = Target.create()
      ..name = 'serveur'
      ..url = 'http://192.0.2.10/shop'
      ..transport = Transport.agentOnly;
    final original = Project.create()
      ..name = 'shop'
      ..folder = root.path
      ..targets.add(server);
    final exported = p.join(root.path, 'shop.deploy.json');
    ProjectFile.write(original, exported);
    final imported = ProjectFile.read(exported);
    final t = imported.targets.single;
    expect(t.agentName, isNot(server.agentName));

    final app = AppState(settings: AppSettings()..language = 'fr', projects: [imported], persist: false);
    app.route = 't:${t.id}';
    await tester.pumpWidget(DeploiementApp(app, themeMode: ThemeMode.light));
    await tester.pumpAndSettle();

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 40 && !done(); i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> letTheMessageGo() async {
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
    }

    final site = Directory(p.join(root.path, 'site'))..createSync();
    final saved = File(p.join(site.path, t.agentName));

    // ---- 1. Cancel: nothing written, nothing said
    pickers.testAnswers = [];
    await tester.tap(find.byKey(const ValueKey('step-save-agent')));
    await until(() => false);
    expect(site.listSync(), isEmpty);
    expect(find.text("L'agent n'a pas pu être enregistré"), findsNothing);

    // ---- 2. saved into the folder chosen, under the agent's own name although "agent.php" was typed
    pickers.testAnswers = [p.join(site.path, 'agent.php')];
    await tester.tap(find.byKey(const ValueKey('step-save-agent')));
    await until(() => find.text('Agent enregistré').evaluate().isNotEmpty); // said once the file is written
    expect(saved.existsSync(), true, reason: 'the agent.php of this target, ready to copy');
    expect(File(p.join(site.path, 'agent.php')).existsSync(), false);
    final code = saved.readAsStringSync();
    expect(code, contains(t.tokenHash));
    expect(code, contains('const AGENT_VERSION'));
    expect(find.text('Agent enregistré'), findsOneWidget);
    final journal = app.journal.lines.map((l) => l.text).join('\n');
    expect(journal, contains(saved.path));
    expect(journal, contains("L'agent garde son nom ${t.agentName}"));
    await letTheMessageGo();

    // ---- 3. a place that cannot be written: said, not swallowed
    pickers.testAnswers = [p.join(exported, 'no', t.agentName)]; // "under" a file
    await tester.tap(find.byKey(const ValueKey('step-save-agent')));
    await until(() => find.text("L'agent n'a pas pu être enregistré").evaluate().isNotEmpty);
    expect(find.text("L'agent n'a pas pu être enregistré"), findsOneWidget);
    await letTheMessageGo();
  });

  test('the working folder can be written', () {
    final w = Store.work;
    final f = File(p.join(w.path, 'probe-${DateTime.now().microsecondsSinceEpoch}.txt'))..writeAsStringSync('ok');
    expect(f.readAsStringSync(), 'ok');
    f.deleteSync();
    expect(Store.work.path, w.path, reason: 'chosen once');
  });
}
