// Deleting a target or a project (asked 17/11/2026: "give me the option to delete a target and also a project"):
// right click on it in the side panel, its "⋯" button, the "More" menu of a target, the bin of a project page.
// Always after a confirmation, "Undo" puts it back; its last checks and history go with it. Nothing on a server.
// Run: flutter test test/delete_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:deploiement/app_state.dart';
import 'package:deploiement/git.dart';
import 'package:deploiement/i18n.dart';
import 'package:deploiement/main.dart';
import 'package:deploiement/models.dart';
import 'package:deploiement/results.dart';

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

Target target(String name) => Target.create()
  ..name = name
  ..url = 'https://$name.example.com'
  ..host = '$name.example.com'
  ..user = 'u'
  ..remotePath = '/www';

void main() {
  Git.offline = true;

  testWidgets('delete a target and a project, then undo', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.reset);
    language.value = 'en';
    await tester.runAsync(fonts);

    final cible = target('cible'), production = target('production'), serveur = target('serveur');
    final blog = Project.create()
      ..name = 'blog'
      ..folder = r'C:\sites\blog'
      ..targets.addAll([cible, production]);
    final shop = Project.create()
      ..name = 'Shop'
      ..folder = r'C:\sites\shop'
      ..targets.add(serveur);
    final app = AppState(settings: AppSettings(), projects: [blog, shop], persist: false);
    app.health[cible.id] = true;
    app.errors[cible.id] = 'old error';
    app.history[cible.id] = [DeployResult(time: DateTime(2026, 11, 17), project: 'blog', target: 'cible')..ok = true];
    app.route = 't:${cible.id}';
    await tester.pumpWidget(DeploiementApp(app, themeMode: ThemeMode.light));
    await tester.pumpAndSettle();

    Finder inPanel(String text) => find.descendant(of: find.byType(SidePanel), matching: find.text(text));
    Future<void> tap(Finder f) async {
      expect(f, findsOneWidget);
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    Future<void> letTheMessageGo() async {
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    }

    // ---- 1. right click on "cible" in the side panel: its menu
    await tester.tap(inPanel('cible'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Settings'), findsWidgets);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/d1_target_menu.png'));

    // Cancel: nothing happens
    await tap(find.text('Delete this target…'));
    expect(find.text('Delete the target "cible"?'), findsOneWidget);
    expect(find.textContaining('Nothing is touched on the server'), findsOneWidget);
    expect(find.textContaining(cible.agentName), findsOneWidget, reason: 'the agent file to delete by hand');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/d2_target_confirm.png'));
    await tap(find.widgetWithText(TextButton, 'Cancel'));
    expect(blog.targets, [cible, production]);

    // Delete
    await tester.tap(inPanel('cible'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tap(find.text('Delete this target…'));
    await tap(find.widgetWithText(FilledButton, 'Delete'));
    expect(blog.targets, [production]);
    expect(inPanel('cible'), findsNothing);
    expect(app.route, 'p:${blog.id}', reason: 'its page was open: back to its project');
    expect([app.health[cible.id], app.errors[cible.id], app.history[cible.id]], [null, null, null]);
    expect(find.text('Target "cible" deleted'), findsOneWidget);

    // ---- 2. Undo: back at its place, with its state
    await tap(find.text('Undo'));
    expect(blog.targets, [cible, production]);
    expect(app.health[cible.id], true);
    expect(app.history[cible.id], hasLength(1));
    expect(inPanel('cible'), findsOneWidget);
    await letTheMessageGo();

    // ---- 3. the "More" menu of the target page
    await tap(inPanel('production'));
    await tap(find.byKey(const ValueKey('target-more')));
    await tap(find.text('Delete this target…'));
    await tap(find.widgetWithText(FilledButton, 'Delete'));
    expect(blog.targets, [cible]);
    await letTheMessageGo();

    // ---- 4. the "⋯" of a project, shown when the mouse is over it
    app.go('home');
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(inPanel('blog')));
    await tester.pumpAndSettle();
    await tap(find.byKey(ValueKey('nav-menu-p:${blog.id}')));
    await tap(find.text('Delete this project…'));
    expect(find.text('Delete the project "blog"?'), findsOneWidget);
    expect(find.textContaining('« cible »'), findsOneWidget, reason: 'its targets are named');
    await tap(find.widgetWithText(FilledButton, 'Delete'));
    expect(app.projects, [shop]);
    expect(app.health[cible.id], isNull);
    await tap(find.text('Undo'));
    expect(app.projects, [blog, shop]);
    expect(app.health[cible.id], true);
    await letTheMessageGo();

    // ---- 5. the bin of the project page
    await tap(inPanel('Shop'));
    await tap(find.byKey(const ValueKey('project-delete')));
    await tap(find.widgetWithText(FilledButton, 'Delete'));
    expect(app.projects, [blog]);
    expect(app.route, 'home');
    await letTheMessageGo();

    // ---- 6. nothing is deleted while an operation runs
    app.busy = true;
    app.changed();
    await tester.pumpAndSettle();
    await tester.tap(inPanel('blog'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(tester.widget<MenuItemButton>(find.widgetWithText(MenuItemButton, 'Delete this project…')).onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    app.busy = false;
  });
}
