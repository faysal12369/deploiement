// A target or a project that is not set up gets a clear message instead of a connection error: the case of a
// "New target" left with "https://", FTP and no host. Also: an FTP server that refuses the connection is explained.
// Run: flutter test test/setup_checks_test.dart --update-goldens   (Apache started, for the project without folder)
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:deploiement/agent_client.dart';
import 'package:deploiement/app_state.dart';
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
  await load('Bahnschrift', [r'C:\Windows\Fonts\bahnschrift.ttf']);
  await load('Cascadia Mono', [r'C:\Windows\Fonts\CascadiaMono.ttf', r'C:\Windows\Fonts\consola.ttf']);
  await load('MaterialIcons', [r'D:\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf']);
}

Target newTarget() => Target.create()
  ..name = 'New target'
  ..url = 'https://';

void main() {
  Git.offline = true; // the project page does not run git in these screens
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final ops = Operations(AppSettings(), Journal());

  test('a target left empty: nothing is tried, the message says what is missing', () async {
    final t = newTarget();
    expect(t.missingSettings(), hasLength(3), reason: 'address, FTP host, FTP user');
    for (final run in [() => ops.test(t), () => ops.placeAgent(t), () => ops.backup(t)]) {
      await expectLater(
          run(),
          throwsA(isA<AgentError>().having((e) => '$e', 'message',
              allOf(contains('"New target" is not set up yet'), contains('the address of the project'), contains('the FTP host'), contains('Open its Settings')))));
    }
    t
      ..url = 'http://192.168.1.10/shop'
      ..transport = Transport.agentOnly;
    expect(t.missingSettings(), isEmpty, reason: '"Agent only" needs only the address');
  });

  test('an FTP server that refuses the connection is explained', () async {
    final t = newTarget()
      ..url = 'http://localhost/nothing'
      ..host = '127.0.0.1'
      ..port = 2 // nothing listens there
      ..user = 'someone';
    await expectLater(
        ops.placeAgent(t),
        throwsA(isA<AgentError>().having((e) => '$e'.split('\n').first, 'first line',
            allOf(startsWith('127.0.0.1 refused the FTP connection on port 2'), contains('choose "Agent only"')))));
  });

  test('a project without its folder: a clear message before anything is sent', () async {
    const dir = r'C:\xampp8\htdocs\SETUP_CHECK';
    final t = newTarget()
      ..url = 'http://localhost/SETUP_CHECK'
      ..transport = Transport.agentOnly;
    final pr = Project(id: 'x', name: 'New project', targets: [t]);
    try {
      Directory(dir).createSync(recursive: true);
      (await ops.saveAgent(t)).copySync(p.join(dir, t.agentName));
      await expectLater(ops.simulate(pr, t), throwsA(isA<AgentError>().having((e) => '$e', 'message', contains('has no folder on this PC yet'))));
    } finally {
      Directory(dir).deleteSync(recursive: true);
    }
  });

  testWidgets('the page of a target left empty: what is missing, actions off, a way to the settings', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 1000);
    addTearDown(tester.view.reset);
    language.value = 'en';
    await tester.runAsync(fonts);
    final t = newTarget();
    final app = AppState(settings: AppSettings(), projects: [Project(id: 'p', name: 'New project', targets: [t])], persist: false)..route = 't:${t.id}';
    await tester.pumpWidget(DeploiementApp(app, themeMode: ThemeMode.light));
    await tester.pumpAndSettle();
    expect(find.text('Set up this target first'), findsOneWidget);
    expect(find.textContaining('Missing: the address of the project'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Deploy')).onPressed, isNull);
    for (final b in ['Simulate', 'Test', 'Place the agent']) {
      expect(tester.widgetList<OutlinedButton>(find.widgetWithText(OutlinedButton, b)).every((w) => w.onPressed == null), true, reason: '$b is off');
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/s1_target_not_set_up.png'));
    await tester.tap(find.widgetWithText(FilledButton, 'Open the settings'));
    await tester.pumpAndSettle();
    expect(app.route, 't:${t.id}:settings');
  });
}
