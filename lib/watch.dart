// Watching the targets while Déploiement runs (asked 15/11/2026: "if there is a problem in the server, send me an
// automatic message — MySQL down…"). Every few minutes each target is checked, read only: its site answers, its agent
// answers, its database connects, its disk has room. A problem is emailed once when it appears and once when it is
// over, from this PC by SMTP (package mailer, pure Dart) — not by PHP: a server whose PHP or MySQL is down could not
// send it. "Start with Windows" opens Déploiement minimized at each login, so the checks keep running.
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';
import 'package:path/path.dart' as p;

import 'agent_client.dart';
import 'app_state.dart';
import 'i18n.dart';
import 'models.dart';

class Problem {
  const Problem(this.code, this.text);
  final String code; // site | agent | database | disk
  final String text;

  /// "the database does not answer" — for the subject of an email.
  static String label(String code) => switch (code) {
        'site' => tr('the site does not answer'),
        'agent' => tr('the agent does not answer'),
        'database' => tr('the database does not answer'),
        'disk' => tr('the disk is almost full'),
        _ => code,
      };
}

String _short(Object e) {
  // "ClientException with SocketException: The remote computer refused… (OS Error: …), address = …" → the sentence
  final s = '$e'
      .replaceFirst(RegExp(r'^[A-Za-z]*(Exception|Error)[^:]*: '), '')
      .split('\n')
      .first
      .replaceFirst(RegExp(r'\s*\(OS Error:.*$'), '')
      .replaceFirst(RegExp(r',\s*(address|uri)\s*=.*$'), '')
      .trim();
  return s.length > 300 ? '${s.substring(0, 300)}…' : s;
}

/// Watched: a target that is set up, except the clones on this PC.
bool watched(Target t) => t.cloneOf.isEmpty && t.missingSettings().isEmpty;

/// What is wrong with [t] right now (empty: all good). Read only: the home page of the site, the agent's status.
Future<List<Problem>> checkTarget(Target t, {Duration timeout = const Duration(seconds: 30)}) async {
  final client = http.Client();
  try {
    final r = await client.get(Uri.parse('${t.baseUrl}/')).timeout(timeout);
    if (r.statusCode >= 500) return [Problem('site', tr('The site answers with an error (HTTP {code}).', {'code': r.statusCode}))];
  } catch (e) {
    return [Problem('site', tr('The site does not answer: {error}', {'error': _short(e)}))]; // nothing else can answer
  } finally {
    client.close();
  }
  final out = <Problem>[];
  final a = AgentClient(t);
  try {
    final s = await a.require('status').timeout(timeout * 2);
    final db = ((s['db'] as Map?) ?? {}).cast<String, dynamic>();
    final err = '${db['error'] ?? ''}';
    if (db['ok'] != true && !err.startsWith('No database settings')) {
      out.add(Problem('database', tr('The database does not answer (MySQL stopped?): {error}', {'error': err})));
    }
    final free = (s['disk_free_mb'] as num?)?.toInt();
    if (free != null && free < 1024) out.add(Problem('disk', tr('Only {mb} MB left on the disk of the target.', {'mb': free})));
  } catch (e) {
    out.add(Problem('agent', tr('The agent does not answer: {error}', {'error': _short(e)})));
  } finally {
    a.close();
  }
  return out;
}

/// Sends one email with the SMTP settings of [s]. Throws with the server's answer when it fails.
Future<void> sendAlert(AlertSettings s, String subject, String body) async {
  final m = s.missing;
  if (m.isNotEmpty) throw StateError(tr('Email not set up: {what} is missing.', {'what': m}));
  final server = SmtpServer(s.host.trim(),
      port: s.port,
      ssl: s.security == 'ssl',
      allowInsecure: s.security == 'none',
      username: s.user.trim().isEmpty ? null : s.user.trim(),
      password: s.user.trim().isEmpty ? null : s.pass);
  final msg = Message()
    ..from = Address(s.sender, 'Déploiement')
    ..recipients.addAll(s.recipients)
    ..subject = subject
    ..text = body;
  try {
    await send(msg, server, timeout: const Duration(seconds: 45));
  } on MailerException catch (e) {
    throw StateError([e.message, for (final x in e.problems) '${x.code}: ${x.msg}'].join(' — '));
  }
}

String _when(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// The email for problems that just appeared on [t]: (subject, text).
(String, String) problemMail(Project pr, Target t, List<Problem> fresh, int minutes, {DateTime? at}) => (
      tr('[Déploiement] Problem on "{name}": {what}', {'name': t.name, 'what': fresh.map((x) => Problem.label(x.code)).join(', ')}),
      [
        tr('Déploiement found a problem on "{name}" (project {project}) at {time}:', {'name': t.name, 'project': pr.name, 'time': _when(at ?? DateTime.now())}),
        '',
        for (final x in fresh) '  • ${x.text}',
        '',
        '${tr('Address')}: ${t.baseUrl}',
        '${tr('Checked from')}: ${Platform.localHostname}',
        '',
        tr('You get one email when a problem appears and one when it is over. The checks run every {n} minutes while Déploiement is open.', {'n': minutes}),
      ].join('\n'),
    );

/// The email for problems of [t] that are over.
(String, String) overMail(Project pr, Target t, List<String> over, {DateTime? at}) => (
      tr('[Déploiement] Back to normal on "{name}"', {'name': t.name}),
      [
        tr('The problem found on "{name}" (project {project}) is over at {time}: {list}.',
            {'name': t.name, 'project': pr.name, 'time': _when(at ?? DateTime.now()), 'list': over.map(Problem.label).join(', ')}),
        '',
        '${tr('Address')}: ${t.baseUrl}',
      ].join('\n'),
    );

typedef MailSender = Future<void> Function(AlertSettings s, String subject, String body);

/// The checks of every watched target, every few minutes while the app runs.
class Watcher {
  Watcher(this.app, {this.confirmAfter = const Duration(seconds: 45), MailSender? mailer}) : _send = mailer ?? sendAlert;
  final AppState app;
  final Duration confirmAfter; // a problem is checked a second time before an email: no email for a short hiccup
  final MailSender _send;
  Timer? _timer, _first;
  bool checking = false;

  AlertSettings get s => app.settings.alerts;

  /// (Re)starts the checks with the current settings; the first one [first] after.
  void restart({Duration first = const Duration(minutes: 1)}) {
    stop();
    if (!s.enabled) return;
    _first = Timer(first, check);
    _timer = Timer.periodic(Duration(minutes: s.minutes.clamp(1, 1440)), (_) => check());
  }

  void stop() {
    _timer?.cancel();
    _first?.cancel();
    _timer = _first = null;
  }

  /// One round over every watched target. Emails only when alerts are on. Returns the subjects sent.
  Future<List<String>> check() async {
    if (checking) return const [];
    checking = true;
    app.changed();
    final mailed = <String>[];
    try {
      for (final pr in app.projects) {
        for (final t in pr.targets) {
          if (!watched(t) || app.busyTarget == t.id) continue; // a deployment running there: not now
          var now = await checkTarget(t);
          final before = s.sent[t.id] ?? const <String>[];
          if (s.enabled && now.any((x) => !before.contains(x.code)) && confirmAfter > Duration.zero) {
            await Future<void>.delayed(confirmAfter);
            now = await checkTarget(t);
          }
          app.health[t.id] = now.isEmpty;
          if (now.isEmpty) {
            app.watchProblems.remove(t.id);
          } else {
            app.watchProblems[t.id] = now;
          }
          if (!s.enabled) continue;
          final fresh = [for (final x in now) if (!before.contains(x.code)) x];
          final over = [for (final c in before) if (!now.any((x) => x.code == c)) c];
          if (fresh.isNotEmpty) app.journal.warn('${t.name}: ${fresh.map((x) => x.text).join(' · ')}');
          try {
            if (fresh.isNotEmpty) {
              final (subject, body) = problemMail(pr, t, fresh, s.minutes);
              await _send(s, subject, body);
              mailed.add(subject);
              s.sent[t.id] = [...before, for (final x in fresh) x.code];
            }
            if (over.isNotEmpty) {
              final (subject, body) = overMail(pr, t, over);
              await _send(s, subject, body);
              mailed.add(subject);
              app.journal.ok(tr('"{name}" is back to normal.', {'name': t.name}));
              s.sent[t.id] = [for (final c in s.sent[t.id] ?? before) if (!over.contains(c)) c];
              if (s.sent[t.id]!.isEmpty) s.sent.remove(t.id);
            }
          } catch (e) {
            // not marked as sent: it is tried again at the next check
            app.journal.error(tr('Alert email not sent: {error}', {'error': _short(e)}));
            app.notify(tr('Alert email not sent'), text: _short(e), severity: Severity.error);
          }
        }
      }
      s.lastCheck = DateTime.now();
      app.save();
    } finally {
      checking = false;
      app.changed();
    }
    return mailed;
  }
}

/// "Start with Windows": a shortcut in the Startup folder of this Windows account opens Déploiement minimized
/// (--background) at each login. Only the installed program can be started that way.
class Startup {
  static String? folderOverride; // tests
  static String get folder => folderOverride ?? p.join(Platform.environment['APPDATA'] ?? '', r'Microsoft\Windows\Start Menu\Programs\Startup');
  static File get link => File(p.join(folder, 'Deploiement.lnk'));

  static bool get canInstall {
    final exe = File(Platform.resolvedExecutable);
    return p.basename(exe.path).toLowerCase() == 'deploiement.exe' && !exe.path.contains(r'\build\');
  }

  /// The shortcut of the former name (PHP Deploy) is replaced by the one of Déploiement, when the alerts start with Windows.
  static Future<void> migrate(bool wanted) async {
    final old = File(p.join(folder, 'PHP Deploy.lnk'));
    if (!await old.exists()) return;
    await old.delete();
    if (wanted && canInstall) await set(true);
  }

  static Future<void> set(bool on, {String? exe}) async {
    if (!on) {
      if (await link.exists()) await link.delete();
      return;
    }
    final target = exe ?? Platform.resolvedExecutable;
    String q(String s) => "'${s.replaceAll("'", "''")}'";
    final ps = '\$s = (New-Object -ComObject WScript.Shell).CreateShortcut(${q(link.path)}); \$s.TargetPath = ${q(target)}; '
        "\$s.Arguments = '--background'; \$s.WorkingDirectory = ${q(p.dirname(target))}; \$s.WindowStyle = 7; "
        "\$s.Description = 'Déploiement: email alerts'; \$s.Save()";
    Directory(folder).createSync(recursive: true);
    final r = await Process.run('powershell', ['-NoProfile', '-Command', ps]);
    if (r.exitCode != 0 || !await link.exists()) throw StateError('${r.stderr}'.trim().isEmpty ? 'shortcut not created' : '${r.stderr}'.trim());
  }
}
