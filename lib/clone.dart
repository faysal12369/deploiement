// A clone of a target on this PC — like a container copied from production: the same files and the same data, in a
// folder and a database of this PC. You work and test on the clone; production is only read (one backup, downloaded).
// The clone then gets its own target, so "Simulate" and "Deploy" can be tried on it before production.
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';

/// "C:\xampp8\htdocs\shop_clone" → "http://localhost/shop_clone" (empty when the folder is not under an htdocs / www).
String localUrlFor(String folder) {
  final parts = p.split(p.normalize(folder));
  final i = parts.lastIndexWhere((x) => const ['htdocs', 'www', 'public_html'].contains(x.toLowerCase()));
  if (i < 0) return '';
  final rest = parts.sublist(i + 1);
  return rest.isEmpty ? 'http://localhost' : 'http://localhost/${rest.join('/')}';
}

/// Points the copy at its own database, in the file(s) that hold the database settings: .env (Laravel…), wp-config.php,
/// a kept PHP file (e.g. config/app.local.php: settings added at its top), else define('DB_…') in config/*.php.
/// Returns the files changed (relative paths).
List<String> pointToDatabase(String folder, List<String> keep, DbSettings db) {
  final changed = <String>[];
  String q(String v) => "'${v.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
  final hostPort = db.port.isEmpty || db.port == '3306' ? db.host : '${db.host}:${db.port}';
  final values = {
    'DB_HOST': db.host,
    'DB_PORT': db.port.isEmpty ? '3306' : db.port,
    'DB_NAME': db.name,
    'DB_USER': db.user,
    'DB_PASS': db.pass,
    'DB_PASSWORD': db.pass,
  };
  final defineRe = RegExp(r'''define\(\s*(['"])(DB_HOST|DB_PORT|DB_NAME|DB_USER|DB_PASS|DB_PASSWORD)\1\s*,\s*(['"])(.*?)\3\s*\)''');

  bool rewritePhp(File f, {bool wordpress = false}) {
    final s = f.readAsStringSync();
    if (!defineRe.hasMatch(s)) return false;
    final out = s.replaceAllMapped(defineRe, (m) {
      final k = m[2]!;
      final v = wordpress && k == 'DB_HOST' ? hostPort : values[k]!;
      return 'define(${m[1]}$k${m[1]}, ${q(v)})';
    });
    if (out != s) f.writeAsStringSync(out);
    return true;
  }

  // .env (Laravel, Symfony…)
  final env = File(p.join(folder, '.env'));
  if (env.existsSync()) {
    final keys = {'DB_HOST': db.host, 'DB_PORT': values['DB_PORT']!, 'DB_DATABASE': db.name, 'DB_USERNAME': db.user, 'DB_PASSWORD': db.pass};
    var s = env.readAsStringSync();
    var any = false;
    for (final e in keys.entries) {
      final re = RegExp('^${e.key}=.*\$', multiLine: true);
      if (re.hasMatch(s)) {
        s = s.replaceAll(re, '${e.key}=${e.value}');
        any = true;
      }
    }
    if (any) {
      env.writeAsStringSync(s);
      changed.add('.env');
    }
  }
  // WordPress
  final wp = File(p.join(folder, 'wp-config.php'));
  if (wp.existsSync() && rewritePhp(wp, wordpress: true)) changed.add('wp-config.php');
  if (changed.isNotEmpty) return changed;

  // a kept PHP file (never overwritten by a deployment): its settings, or settings added at its top
  for (final k in keep) {
    final rel = k.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
    if (!rel.toLowerCase().endsWith('.php') || rel.contains('*')) continue;
    final f = File(p.join(folder, rel));
    if (!f.existsSync()) continue;
    if (rewritePhp(f)) {
      changed.add(rel);
      continue;
    }
    final s = f.readAsStringSync();
    final block = StringBuffer('<?php\n// Database of this clone, written by Déploiement on ${DateTime.now().toIso8601String().substring(0, 16)}.\n');
    for (final e in values.entries) {
      block.writeln("defined('${e.key}') || define('${e.key}', ${q(e.value)});");
    }
    f.writeAsStringSync(s.startsWith('<?php') ? '$block${s.substring(5)}' : '$block?>\n$s');
    changed.add(rel);
  }
  if (changed.isNotEmpty) return changed;

  // last chance: define('DB_…') in config/*.php (deployments may overwrite these: the caller warns)
  final cfg = Directory(p.join(folder, 'config'));
  if (cfg.existsSync()) {
    for (final f in cfg.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.php'))) {
      if (rewritePhp(f)) changed.add('config/${p.basename(f.path)}');
    }
  }
  return changed;
}
