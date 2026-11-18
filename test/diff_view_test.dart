// The comparison window at several sizes, light and dark, in French: long indented lines that wrap, a changed line
// with its changed part marked, inserted lines facing a hatched side, unchanged lines opened with a click.
// Images in test/captures/diff_*.png.   Run: flutter test test/diff_view_test.dart --update-goldens
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:deploiement/diff_view.dart';
import 'package:deploiement/i18n.dart';
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
  await load('Cascadia Mono', File(r'C:\Windows\Fonts\CascadiaMono.ttf').existsSync() ? [r'C:\Windows\Fonts\CascadiaMono.ttf'] : [r'C:\Windows\Fonts\consola.ttf']);
  await load('Bahnschrift', [r'C:\Windows\Fonts\bahnschrift.ttf']);
  await load('MaterialIcons', [r'D:\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf']);
}

final redirects = [for (var i = 1; i <= 30; i++) '    RewriteRule ^old-page-$i\$ new-page-$i [R=301,L]'];
final before = [
  '# Example site',
  'Options -Indexes',
  'RewriteEngine On',
  '',
  '<IfModule mod_rewrite.c>',
  ...redirects,
  '    # Base of the site, whatever folder it is in',
  r'    RewriteCond $0#%{REQUEST_URI} ^(.*)#(.*)\1$',
  r'    RewriteRule ^.*$ - [E=SITE_BASE:%2]',
  '',
  '    # Les adresses courtes marchent ici : page() s\'en servira (seulement si pages/ est bien trouvé).',
  '    RewriteCond %{DOCUMENT_ROOT}%{ENV:SITE_BASE}pages/partials/header.php -f',
  '    RewriteRule ^ - [E=SHORT_URLS:1]',
  '</IfModule>',
].join('\n');
final after = before
    .replaceFirst('Options -Indexes', 'Options -Indexes -MultiViews')
    .replaceFirst('    RewriteRule ^.*\$ - [E=SITE_BASE:%2]\n\n', '''    RewriteRule ^.*\$ - [E=SITE_BASE:%2]

    # La connexion s'ouvre par l'adresse du dossier (/site/), jamais par « /site/index.php » (11/11/2026, voulu par
    # l'utilisateur : la barre d'adresse ne montre pas le nom du fichier). Lectures seulement ; THE_REQUEST : ce que le
    # navigateur a demandé, pas le index.php que sert le dossier (pas de boucle).
    RewriteCond %{REQUEST_METHOD} =GET [OR]
    RewriteCond %{REQUEST_METHOD} =HEAD
    RewriteCond %{THE_REQUEST} \\s[^?\\s]*/index\\.php[\\s?] [NC]
    RewriteRule ^index\\.php\$ %{ENV:SITE_BASE} [R=302,L]

''');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('comparison window', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(fonts);
    language.value = 'fr';

    Future<void> shot(String name, Size size, {ThemeMode mode = ThemeMode.light, String kind = 'M', Finder? tap, bool narrowBar = false}) async {
      tester.view.physicalSize = size;
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: mode,
        home: Builder(builder: (c) {
          ctx = c;
          return Scaffold(backgroundColor: Palette.of(c).bg);
        }),
      ));
      final b = Uint8List.fromList(utf8.encode(before)), a = Uint8List.fromList(utf8.encode(after));
      showDialog(
        context: ctx,
        barrierColor: Colors.black.withValues(alpha: .35),
        builder: (_) => DiffDialog(
          target: 'Serveur de test',
          rel: 'public/.htaccess',
          kind: kind,
          versions: Future.value(kind == 'A' ? (null, a) : (b, a)),
        ),
      );
      await tester.pumpAndSettle();
      if (tap != null) {
        await tester.tap(tap);
        await tester.pumpAndSettle();
      }
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('captures/diff_$name.png'));
    }

    await shot('wide', const Size(1520, 900));
    await shot('wide_dark', const Size(1520, 900), mode: ThemeMode.dark);
    await shot('wide_opened', const Size(1520, 900), tap: find.textContaining('Afficher 30 lignes'));
    await shot('medium', const Size(900, 820));
    await shot('medium_split', const Size(900, 820), tap: find.byKey(const ValueKey('diff-split')));
    await shot('phone', const Size(420, 860));
    await shot('new_file', const Size(1200, 700), kind: 'A');
  });
}
