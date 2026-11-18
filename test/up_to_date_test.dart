// "Deploy" when nothing changed on this PC (asked 17/11/2026: "if there is no update, it tells me"): the app says the
// target already has the last version, part by part, and sends nothing.
// Run: flutter test test/up_to_date_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:deploiement/dialogs.dart';
import 'package:deploiement/i18n.dart';
import 'package:deploiement/models.dart';
import 'package:deploiement/operations.dart';
import 'package:deploiement/theme.dart';

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
  await load('MaterialIcons', [r'D:\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf']);
}

void main() {
  testWidgets('nothing to deploy: said plainly', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 640);
    addTearDown(tester.view.reset);
    addTearDown(() => language.value = 'en');
    await tester.runAsync(fonts);
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: Builder(builder: (c) {
      ctx = c;
      return const Scaffold();
    })));
    final t = Target.create()..name = 'hostinger';
    final r = Report(target: 'hostinger', package: 'release.zip', status: {}, plan: {
      'new': [], 'changed': [], 'removed': [], 'total': 921, 'db_ok': true,
      'migrations': {'run': [], 'tracked': true},
    });
    expect(r.upToDate, isTrue);

    language.value = 'en';
    showUpToDate(ctx, t, r);
    await tester.pumpAndSettle();
    expect(find.text('"hostinger" is already up to date'), findsOneWidget);
    expect(find.text('Files: the same 921 files.'), findsOneWidget);
    expect(find.text('Structure: no migration to run.'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);

    // a project without synced tables, in French
    language.value = 'fr';
    showUpToDate(ctx, t, r);
    await tester.pumpAndSettle();
    expect(find.text('« hostinger » est déjà à jour'), findsOneWidget);
    expect(find.text('Données : pas de tables synchronisées dans ce projet.'), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/u1_up_to_date_fr.png'));
  });
}
