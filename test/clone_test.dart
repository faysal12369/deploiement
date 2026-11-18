// A clone points at its own database: .env, wp-config.php, a kept PHP file (settings added at its top when it has
// none, like the ERP's config/app.local.php), else define('DB_…') in config/*.php.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:deploiement/clone.dart';
import 'package:deploiement/models.dart';

void main() {
  final db = DbSettings(host: '127.0.0.1', port: '3306', name: 'shop_clone', user: 'root', pass: "it's");
  late Directory d;
  setUp(() => d = Directory.systemTemp.createTempSync('clone-test-'));
  tearDown(() => d.deleteSync(recursive: true));
  void write(String rel, String s) => File(p.join(d.path, rel))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(s);
  String read(String rel) => File(p.join(d.path, rel)).readAsStringSync();

  test('.env', () {
    write('.env', 'APP_NAME=Shop\nDB_HOST=db.prod\nDB_DATABASE=shop\nDB_USERNAME=prod\nDB_PASSWORD=secret\n');
    expect(pointToDatabase(d.path, ['.env'], db), ['.env']);
    expect(read('.env'), 'APP_NAME=Shop\nDB_HOST=127.0.0.1\nDB_DATABASE=shop_clone\nDB_USERNAME=root\nDB_PASSWORD=it\'s\n');
  });

  test('wp-config.php', () {
    write('wp-config.php', "<?php\ndefine( 'DB_NAME', 'wp' );\ndefine( 'DB_USER', 'prod' );\ndefine( 'DB_PASSWORD', 'x' );\ndefine( 'DB_HOST', 'localhost' );\n");
    expect(pointToDatabase(d.path, [], db), ['wp-config.php']);
    expect(read('wp-config.php'), contains("define('DB_NAME', 'shop_clone')"));
    expect(read('wp-config.php'), contains(r"define('DB_PASSWORD', 'it\'s')"));
  });

  test('a kept PHP file without settings (the ERP): settings added at its top, before the defaults', () {
    write('config/app.local.php', "<?php\nif (getenv('DB_HOST') !== false) {\n    define('DB_HOST', getenv('DB_HOST'));\n}\ndefine('SESSION_NAME', 'MYSHOP');\n");
    write('config/app.php', "<?php\ndefined('DB_NAME') || define('DB_NAME', 'ds');\n");
    expect(pointToDatabase(d.path, ['config/app.local.php', 'storage/'], db), ['config/app.local.php']);
    final s = read('config/app.local.php');
    expect(s, startsWith('<?php\n// Database of this clone'));
    expect(s, contains("defined('DB_NAME') || define('DB_NAME', 'shop_clone');"));
    expect(s, contains("define('SESSION_NAME', 'MYSHOP');"), reason: 'the rest of the file is kept');
    expect(read('config/app.php'), contains("'ds'"), reason: 'project files are not touched when a kept file holds the settings');
  });

  test('a kept PHP file with settings: they are rewritten', () {
    write('config/app.local.php', "<?php\ndefine('DB_NAME', 'ds');\ndefine('DB_PASS', 'prodpass');\n");
    expect(pointToDatabase(d.path, ['config/app.local.php'], db), ['config/app.local.php']);
    expect(read('config/app.local.php'), "<?php\ndefine('DB_NAME', 'shop_clone');\ndefine('DB_PASS', 'it\\'s');\n");
  });

  test('the address of a folder under htdocs', () {
    expect(localUrlFor(r'C:\xampp8\htdocs\shop_clone'), 'http://localhost/shop_clone');
    expect(localUrlFor(r'D:\sites\shop'), '');
  });
}
