// Email alerts (watch.dart): targets checked read only, a problem emailed once when it appears and once when it is
// over, by SMTP from this PC. A small SMTP server in the test receives the emails. Targets: the agent in
// C:\xampp8\htdocs\ALERTS_TEST (local Apache) whose database is made unreachable then reachable again, and an address
// where nothing answers. Run: flutter test test/alerts_test.dart (Apache and MySQL started)
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:deploiement/alerts_view.dart';
import 'package:deploiement/app_state.dart';
import 'package:deploiement/i18n.dart';
import 'package:deploiement/models.dart';
import 'package:deploiement/operations.dart';
import 'package:deploiement/theme.dart';
import 'package:deploiement/watch.dart';

const targetDir = r'C:\xampp8\htdocs\ALERTS_TEST';

/// The emails received: (from, to, raw message).
class FakeSmtp {
  late ServerSocket server;
  final mails = <String>[];
  int get port => server.port;

  Future<void> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) {
      var data = false;
      final buf = StringBuffer();
      s.write('220 fake ESMTP\r\n');
      s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
        if (data) {
          if (l == '.') {
            data = false;
            mails.add(buf.toString());
            buf.clear();
            s.write('250 queued\r\n');
          } else {
            buf.writeln(l);
          }
          return;
        }
        final cmd = l.toUpperCase();
        if (cmd.startsWith('EHLO') || cmd.startsWith('HELO')) {
          s.write('250-fake\r\n250 8BITMIME\r\n');
        } else if (cmd.startsWith('DATA')) {
          data = true;
          s.write('354 go\r\n');
        } else if (cmd.startsWith('QUIT')) {
          s.write('221 bye\r\n');
          s.close();
        } else {
          s.write('250 ok\r\n');
        }
      });
    });
  }

  /// The subject of each email: its header unfolded (a long one goes on several lines), its encoded words decoded
  /// together (an accented letter can be split between two of them).
  List<String> get subjects => [
        for (final m in mails)
          () {
            final lines = m.split('\n');
            final i = lines.indexWhere((l) => l.toLowerCase().startsWith('subject:'));
            if (i < 0) return '';
            var v = lines[i].substring(8);
            for (var j = i + 1; j < lines.length && (lines[j].startsWith(' ') || lines[j].startsWith('\t')); j++) {
              v += lines[j];
            }
            v = v.trim();
            final words = RegExp(r'=\?utf-8\?B\?([^?]*)\?=', caseSensitive: false).allMatches(v).toList();
            return words.isEmpty ? v : utf8.decode([for (final w in words) ...base64.decode(w[1]!)]);
          }(),
      ];
}

void env(String db, {String port = '3306'}) =>
    File(p.join(targetDir, '.env')).writeAsStringSync('DB_HOST=127.0.0.1\nDB_PORT=$port\nDB_DATABASE=$db\nDB_USERNAME=root\nDB_PASSWORD=\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  final smtp = FakeSmtp();
  final server = Target(id: 'srv', name: 'office server', url: 'http://localhost/ALERTS_TEST', transport: Transport.agentOnly);
  final gone = Target(id: 'gone', name: 'old host', url: 'http://127.0.0.1:9', transport: Transport.agentOnly);
  final clone = Target(id: 'cl', name: 'clone', url: 'http://127.0.0.1:9', transport: Transport.agentOnly, cloneOf: 'office server');
  final project = Project(id: 'shop', name: 'corner-shop', folder: Directory.systemTemp.path, targets: [server, gone, clone]);
  final app = AppState(settings: AppSettings(), projects: [project], persist: false);
  final a = app.settings.alerts
    ..enabled = true
    ..minutes = 5
    ..host = '127.0.0.1'
    ..security = 'none'
    ..from = 'deploy@example.com'
    ..to = 'it@example.com, boss@example.com';

  setUpAll(() async {
    await smtp.start();
    a.port = smtp.port;
    final td = Directory(targetDir);
    if (td.existsSync()) td.deleteSync(recursive: true);
    td.createSync();
    File(p.join(targetDir, server.agentName)).writeAsStringSync((await Operations(AppSettings(), Journal()).saveAgent(server)).readAsStringSync());
  });
  tearDownAll(() async {
    await smtp.server.close();
    if (Directory(targetDir).existsSync()) Directory(targetDir).deleteSync(recursive: true);
  });

  test('a problem is emailed once when it appears, once when it is over; a failed email is tried again', () async {
    final w = Watcher(app, confirmAfter: Duration.zero);

    // MySQL "down" for the office server (nothing listens on 3999), nothing at all at the old host
    env('mysql', port: '3999');
    expect(await w.check(), hasLength(2));
    expect(smtp.subjects, containsAll(['[Déploiement] Problem on "office server": the database does not answer', '[Déploiement] Problem on "old host": the site does not answer']));
    final mysqlMail = smtp.mails[smtp.subjects.indexWhere((s) => s.contains('office server'))];
    expect(mysqlMail, allOf(contains('it@example.com'), contains('boss@example.com'), contains('deploy@example.com')));
    final text = utf8.decode(base64.decode(mysqlMail.replaceAll('\r', '').split('\n\n').skip(1).join().replaceAll('\n', '')));
    expect(text, allOf(contains('MySQL stopped?'), contains('SQLSTATE'), contains('corner-shop')), reason: 'the body says what is wrong');
    expect(a.sent, {'srv': ['database'], 'gone': ['site']});
    expect(app.watchProblems.keys, unorderedEquals(['srv', 'gone']), reason: 'shown on the target pages');
    expect(app.health['srv'], false);
    expect(app.watchProblems.containsKey('cl'), false, reason: 'clones are not watched');

    // still down: no second email
    expect(await w.check(), isEmpty);
    expect(smtp.mails, hasLength(2));

    // MySQL back: one "back to normal" email
    env('mysql');
    expect(await w.check(), ['[Déploiement] Back to normal on "office server"']);
    expect(a.sent, {'gone': ['site']});
    expect(app.watchProblems.containsKey('srv'), false);
    expect(app.health['srv'], true);

    // the SMTP server refuses: nothing is lost, the email goes at the next check
    env('mysql', port: '3999');
    a.port = 1; // nothing there
    expect(await w.check(), isEmpty);
    expect(app.journal.lines.map((l) => l.text), anyElement(startsWith('Alert email not sent:')));
    expect(a.sent['srv'], isNull, reason: 'not marked as sent');
    a.port = smtp.port;
    expect(await w.check(), ['[Déploiement] Problem on "office server": the database does not answer']);

    // alerts off: the targets are still checked for the app, no email
    a.enabled = false;
    env('mysql');
    expect(await w.check(), isEmpty);
    expect(app.watchProblems.containsKey('srv'), false);
    a.enabled = true;

    // a deployment running on a target: it is left alone
    app.busyTarget = 'gone';
    final before = smtp.mails.length;
    await w.check();
    app.busyTarget = null;
    expect(smtp.mails.length, before + 1, reason: 'only "back to normal" for the office server');
  });

  test('the settings say what is missing to send an email', () {
    final s = AlertSettings();
    expect(s.missing, 'the SMTP server');
    s.host = 'smtp.example.com';
    expect(s.missing, 'the address to send to');
    s.to = 'me@example.com';
    expect(s.missing, 'the sender address');
    s.user = 'me@example.com';
    expect(s.missing, '');
    final back = AlertSettings()..read(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expect([back.host, back.to, back.user, back.port, back.security], [s.host, s.to, s.user, s.port, s.security]);
  });

  test('the email says what is wrong, where, and that the next one comes when it is over', () {
    final (subject, body) = problemMail(project, server, [const Problem('database', 'The database does not answer (MySQL stopped?): SQLSTATE[HY000] [2002]')], 15);
    expect(subject, '[Déploiement] Problem on "office server": the database does not answer');
    expect(body, allOf(contains('corner-shop'), contains('SQLSTATE[HY000] [2002]'), contains('http://localhost/ALERTS_TEST'), contains('every 15 minutes')));
    final (s2, b2) = overMail(project, server, ['database']);
    expect(s2, '[Déploiement] Back to normal on "office server"');
    expect(b2, contains('the database does not answer'));
  });

  test('"Start with Windows" puts a shortcut in the Startup folder, and removes it', () async {
    final d = Directory.systemTemp.createTempSync('startup-');
    Startup.folderOverride = d.path;
    try {
      await Startup.set(true, exe: r'C:\Program Files\Deploiement\Deploiement.exe');
      expect(Startup.link.existsSync(), true);
      await Startup.set(false);
      expect(Startup.link.existsSync(), false);
    } finally {
      Startup.folderOverride = null;
      d.deleteSync(recursive: true);
    }
  });

  testWidgets('the alerts settings, wide and narrow, English and French', (tester) async {
    for (final (lang, size) in [('en', const Size(1200, 1600)), ('fr', const Size(480, 2200))]) {
      language.value = lang;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: AlertsBlock(app, key: UniqueKey()))),
      ));
      await tester.pumpAndSettle();
      expect(find.text(lang == 'en' ? 'Email alerts' : 'Alertes par e-mail'), findsOneWidget);
      expect(find.byKey(const ValueKey('alerts-test')), findsOneWidget);
    }
    language.value = 'en';
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
