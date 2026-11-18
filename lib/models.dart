// Projects and targets, saved in %APPDATA%\Deploiement\config.json. Passwords and agent tokens are encrypted with
// Windows DPAPI (secret.dart): the file is useless on another PC or another Windows account.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'i18n.dart';
import 'secret.dart';

String randomHex(int bytes) {
  final r = Random.secure();
  return List.generate(bytes, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

List<String> _strings(Object? v) => (v as List? ?? const []).map((e) => '$e').toList();

/// How files reach the project folder on a target.
enum Transport {
  ftp('FTP', 21),
  ftpes('FTPES (explicit TLS)', 21),
  ftps('FTPS (implicit TLS)', 990),
  sftp('SFTP (SSH)', 22),
  folder('Folder (local or network share)', 0),
  agentOnly('Agent only (placed by hand)', 0);

  const Transport(this.english, this.defaultPort);
  final String english;
  final int defaultPort;
  String get label => tr(english);
  bool get remote => this == ftp || this == ftpes || this == ftps || this == sftp;
}

/// A MySQL / MariaDB connection. An empty [name] means "none" (local) or "auto-detect" (target).
class DbSettings {
  DbSettings({this.host = '127.0.0.1', this.port = '3306', this.name = '', this.user = 'root', this.pass = ''});
  String host, port, name, user, pass;
  bool get isSet => name.trim().isNotEmpty;

  Map<String, dynamic> toAgent() => {'host': host, 'port': port, 'name': name, 'user': user, 'pass': pass};
  Map<String, dynamic> toJson() => {'host': host, 'port': port, 'name': name, 'user': user, 'pass': Secret.encrypt(pass)};
  factory DbSettings.fromJson(Map<String, dynamic>? j, {String defaultHost = '127.0.0.1', String defaultUser = 'root'}) => DbSettings(
        host: j?['host'] as String? ?? defaultHost,
        port: j?['port'] as String? ?? '3306',
        name: j?['name'] as String? ?? '',
        user: j?['user'] as String? ?? defaultUser,
        pass: Secret.decrypt(j?['pass'] as String? ?? ''),
      );
}

/// A table whose rows are pushed from the local database to the targets (insert or update, never delete).
/// A table of the project's list (asked 17/11/2026: "some tables with their data, some only their structure"):
/// [structure] — the target's table is made like this PC's (created, columns and indexes added, columns changed,
/// nothing removed); [data] — its rows are sent (added or updated, never deleted).
class SyncTable {
  SyncTable({required this.table, this.key = const [], this.where = '', this.ignore = const [], this.links = const {}, this.data = true, this.structure = false});
  String table;
  bool data, structure;
  List<String> key; // empty: a unique index of the table
  String where; // SQL filter on the local rows, e.g. "setting_group <> 'email'"
  List<String> ignore; // columns never sent
  Map<String, String> links; // column => synced table it points at (when no foreign key says so)

  Map<String, dynamic> toJson() => {'table': table, 'key': key, 'where': where, 'ignore': ignore, 'links': links, 'data': data, 'structure': structure};
  // tables saved before the choice existed: their data only, as then
  factory SyncTable.fromJson(Map<String, dynamic> j) => SyncTable(
        table: j['table'] as String? ?? '',
        data: j['data'] != false,
        structure: j['structure'] == true,
        key: _strings(j['key']),
        where: j['where'] as String? ?? '',
        ignore: _strings(j['ignore']),
        links: ((j['links'] as Map?) ?? {}).map((k, v) => MapEntry('$k', '$v')),
      );
}

/// A file sent only to one target, e.g. ".env.production" (local) → ".env" (target).
class TargetFile {
  TargetFile({required this.local, required this.remote});
  String local, remote;
  Map<String, dynamic> toJson() => {'local': local, 'remote': remote};
  factory TargetFile.fromJson(Map<String, dynamic> j) => TargetFile(local: j['local'] as String? ?? '', remote: j['remote'] as String? ?? '');
}

class Target {
  Target({
    required this.id,
    this.name = '',
    this.url = '',
    this.transport = Transport.ftp,
    this.host = '',
    this.port = 21,
    this.user = '',
    this.pass = '',
    this.remotePath = '',
    this.privateDir = '.deploy',
    String? agentName,
    String? token,
    DbSettings? db,
    List<TargetFile>? files,
    this.lastAction = '',
    this.cloneOf = '',
  })  : agentName = agentName ?? 'deploy-agent-${randomHex(6)}.php',
        token = token ?? randomHex(32),
        db = db ?? DbSettings(host: 'localhost', user: ''),
        files = files ?? [];

  factory Target.create() => Target(id: randomHex(8));

  final String id;
  String name;
  String url; // the project's address in a browser: https://example.com, https://example.com/app, http://192.168.1.10/shop
  Transport transport;
  String host;
  int port;
  String user;
  String pass;
  String remotePath; // the project folder as the transport sees it: /public_html, /domains/x/public_html/app, \\server\share\app
  String privateDir; // agent's private folder, relative to the project folder: ".deploy", "../.deploy-shop" (outside the web root)
  String agentName;
  String token;
  DbSettings db; // empty name: the agent detects it (.env, wp-config.php, define('DB_…'))
  List<TargetFile> files;
  String lastAction;
  String cloneOf; // name of the target this one is a copy of (a clone on this PC), '' otherwise

  String get baseUrl => folderUrl(url);

  /// The address of the project folder, also when the address of one of its pages was typed:
  /// "https://example.com/index.php?p=1" → "https://example.com", "https://example.com/app/" → "https://example.com/app".
  static String folderUrl(String typed) {
    var u = typed.trim().replaceAll(RegExp(r'[?#].*$'), '');
    final page = RegExp(r'^(https?://[^/]+(?:/.*)?)/[^/]+\.(?:php|html?)$', caseSensitive: false).firstMatch(u);
    if (page != null) u = page[1]!;
    return u.replaceAll(RegExp(r'/+$'), '');
  }
  bool get hasUrl => RegExp(r'^https?://[^/\s]+').hasMatch(url.trim());

  /// What must still be filled in before the app can reach this target (empty: ready).
  List<String> missingSettings() => [
        if (!hasUrl) tr('the address of the project (http://… or https://…)'),
        if (transport.remote && host.trim().isEmpty) tr('the {transport} host', {'transport': transport.label}),
        if (transport.remote && user.trim().isEmpty) tr('the {transport} user', {'transport': transport.label}),
        if (transport == Transport.folder && remotePath.trim().isEmpty) tr('the project folder'),
      ];
  Uri get agentUrl => Uri.parse('$baseUrl/$agentName');
  String get tokenHash => sha256.convert(utf8.encode(token)).toString();

  void newKey() {
    token = randomHex(32);
    agentName = 'deploy-agent-${randomHex(6)}.php';
  }

  Map<String, dynamic> toJson({bool secrets = true}) => {
        'id': id, 'name': name, 'url': url, 'transport': transport.name, 'host': host, 'port': port, 'user': user,
        'pass': secrets ? Secret.encrypt(pass) : '', 'remotePath': remotePath, 'privateDir': privateDir,
        'agentName': agentName, 'token': secrets ? Secret.encrypt(token) : '',
        'db': secrets ? db.toJson() : (db.toJson()..['pass'] = ''),
        'files': files.map((f) => f.toJson()).toList(), 'lastAction': lastAction, 'cloneOf': cloneOf,
      };

  factory Target.fromJson(Map<String, dynamic> j) {
    final tok = j['token'] as String? ?? '';
    return Target(
      id: j['id'] as String? ?? randomHex(8),
      name: j['name'] as String? ?? '',
      url: j['url'] as String? ?? '',
      transport: Transport.values.firstWhere((t) => t.name == j['transport'], orElse: () => Transport.ftp),
      host: j['host'] as String? ?? '',
      port: (j['port'] as num?)?.toInt() ?? 21,
      user: j['user'] as String? ?? '',
      pass: Secret.decrypt(j['pass'] as String? ?? ''),
      remotePath: j['remotePath'] as String? ?? '',
      privateDir: j['privateDir'] as String? ?? '.deploy',
      agentName: j['agentName'] as String?,
      token: tok.isEmpty ? null : Secret.decrypt(tok),
      db: DbSettings.fromJson((j['db'] as Map?)?.cast<String, dynamic>(), defaultHost: 'localhost', defaultUser: ''),
      files: ((j['files'] as List?) ?? []).map((f) => TargetFile.fromJson((f as Map).cast<String, dynamic>())).toList(),
      lastAction: j['lastAction'] as String? ?? '',
      cloneOf: j['cloneOf'] as String? ?? '',
    );
  }

  Target copy() => Target.fromJson(toJson());
}

class Project {
  Project({
    required this.id,
    this.name = '',
    this.folder = '',
    List<String>? exclude,
    List<String>? keep,
    this.migrationsFolder = '',
    this.migrationsSkip = '*_rollback.sql',
    this.rerunChangedMigrations = false,
    DbSettings? localDb,
    List<SyncTable>? sync,
    List<Target>? targets,
    List<String>? compareCountOnly,
    List<String>? compareKeys,
    this.gitRemote = '',
    this.gitBranch = '',
  })  : exclude = exclude ?? List.of(defaultExclude),
        compareCountOnly = compareCountOnly ?? List.of(defaultCountOnly),
        compareKeys = compareKeys ?? [],
        keep = keep ?? List.of(defaultKeep),
        localDb = localDb ?? DbSettings(),
        sync = sync ?? [],
        targets = targets ?? [];

  static const defaultExclude = ['.git/', '.idea/', '.vscode/', 'node_modules/', '*.log', '.DS_Store', 'Thumbs.db'];
  static const defaultKeep = ['.env', 'storage/', 'uploads/'];
  static const defaultCountOnly = ['*_log', '*_logs', '*sessions*', '*notifications*', '*login_attempts*'];

  factory Project.create() => Project(id: randomHex(8));

  final String id;
  String name;
  String folder;
  List<String> exclude; // never sent
  List<String> keep; // never sent, never overwritten nor deleted on a target
  String migrationsFolder; // relative to the project folder, '' = no migrations
  String migrationsSkip; // pattern of migration files never run
  bool rerunChangedMigrations; // a migration whose file changed after it ran is run again
  DbSettings localDb;
  List<SyncTable> sync; // the tables of the list: their data, their structure, or both
  List<SyncTable> get dataTables => [for (final s in sync) if (s.data && s.table.trim().isNotEmpty) s];
  List<SyncTable> get structureTables => [for (final s in sync) if (s.structure && s.table.trim().isNotEmpty) s];

  /// What a package carries for the tables: a simulation made with another choice is made again before deploying
  /// (18/11/2026: the stock was ticked after the simulation, the deployment reused it and sent no stock).
  String get tablesKey => [
        'D:${(dataTables.map((s) => '${s.table}${s.key}${s.where}${s.ignore}${s.links}').toList()..sort()).join(',')}',
        'S:${(structureTables.map((s) => s.table).toList()..sort()).join(',')}',
      ].join('|');
  List<Target> targets;
  List<String> compareCountOnly; // tables compared by their number of rows only (logs, sessions…)
  List<String> compareKeys; // "table: col1, col2" — the key of a table without a useful unique index
  String gitRemote; // the GitHub repository the code is sent to ('' = not linked)
  String gitBranch; // the branch it is sent to
  bool get gitReady => gitRemote.trim().isNotEmpty && gitBranch.trim().isNotEmpty;

  /// compareKeys as table → columns.
  Map<String, List<String>> get compareKeyMap => {
        for (final l in compareKeys)
          if (l.contains(':') || l.contains('='))
            l.split(RegExp('[:=]')).first.trim(): l.split(RegExp('[:=]')).skip(1).join().split(RegExp(r'[,+\s]+')).map((c) => c.trim()).where((c) => c.isNotEmpty).toList(),
      };

  Map<String, dynamic> toJson({bool secrets = true}) => {
        'id': id, 'name': name, 'folder': folder, 'exclude': exclude, 'keep': keep,
        'migrationsFolder': migrationsFolder, 'migrationsSkip': migrationsSkip, 'rerunChangedMigrations': rerunChangedMigrations,
        'localDb': secrets ? localDb.toJson() : (localDb.toJson()..['pass'] = ''),
        'sync': sync.map((s) => s.toJson()).toList(),
        'targets': targets.map((t) => t.toJson(secrets: secrets)).toList(),
        'compareCountOnly': compareCountOnly,
        'compareKeys': compareKeys,
        'gitRemote': gitRemote,
        'gitBranch': gitBranch,
      };

  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: j['id'] as String? ?? randomHex(8),
        name: j['name'] as String? ?? '',
        folder: j['folder'] as String? ?? '',
        exclude: j['exclude'] == null ? null : _strings(j['exclude']),
        keep: j['keep'] == null ? null : _strings(j['keep']),
        migrationsFolder: j['migrationsFolder'] as String? ?? '',
        migrationsSkip: j['migrationsSkip'] as String? ?? '*_rollback.sql',
        rerunChangedMigrations: j['rerunChangedMigrations'] as bool? ?? false,
        localDb: DbSettings.fromJson((j['localDb'] as Map?)?.cast<String, dynamic>()),
        sync: ((j['sync'] as List?) ?? []).map((s) => SyncTable.fromJson((s as Map).cast<String, dynamic>())).toList(),
        targets: ((j['targets'] as List?) ?? []).map((t) => Target.fromJson((t as Map).cast<String, dynamic>())).toList(),
        compareCountOnly: j['compareCountOnly'] == null ? null : _strings(j['compareCountOnly']),
        compareKeys: j['compareKeys'] == null ? null : _strings(j['compareKeys']),
        gitRemote: j['gitRemote'] as String? ?? '',
        gitBranch: j['gitBranch'] as String? ?? '',
      );

  Project copy() => Project.fromJson(toJson());
}

class AppSettings {
  String language = 'en'; // en | fr
  String phpPath = ''; // empty: auto-detected
  final alerts = AlertSettings();

  Map<String, dynamic> toJson() => {'language': language, 'phpPath': phpPath, 'alerts': alerts.toJson()};
  void read(Map<String, dynamic> j) {
    language = j['language'] as String? ?? language;
    phpPath = j['phpPath'] as String? ?? '';
    alerts.read((j['alerts'] as Map?)?.cast<String, dynamic>() ?? {});
  }
}

/// Email alerts (watch.dart): while Déploiement runs, the targets are checked every [minutes]; a problem (site down,
/// agent gone, database not answering, disk full) is sent by email once when it appears, and once when it is over.
/// Sent from this PC by SMTP: a server whose PHP or MySQL is down could not send it.
class AlertSettings {
  bool enabled = false;
  int minutes = 15;
  String host = '';
  int port = 587;
  String security = 'starttls'; // ssl (465) | starttls (587) | none
  String user = '', pass = '', from = '', to = '';
  bool startWithWindows = false;

  /// Problems already sent, per target id (codes: site, agent, database, disk) — not sent again until they are over.
  Map<String, List<String>> sent = {};
  DateTime? lastCheck;

  List<String> get recipients => to.split(RegExp(r'[,;\s]+')).map((x) => x.trim()).where((x) => x.contains('@')).toList();
  String get sender => from.trim().isNotEmpty ? from.trim() : user.trim();

  /// What is missing to send an email ('' when ready).
  String get missing => host.trim().isEmpty
      ? tr('the SMTP server')
      : recipients.isEmpty
          ? tr('the address to send to')
          : !sender.contains('@')
              ? tr('the sender address')
              : '';

  Map<String, dynamic> toJson() => {
        'enabled': enabled, 'minutes': minutes, 'host': host, 'port': port, 'security': security, 'user': user,
        'pass': Secret.encrypt(pass), 'from': from, 'to': to, 'startWithWindows': startWithWindows,
        'sent': sent, 'lastCheck': lastCheck?.toIso8601String(),
      };

  void read(Map<String, dynamic> j) {
    enabled = j['enabled'] as bool? ?? false;
    minutes = (j['minutes'] as num?)?.toInt() ?? 15;
    host = j['host'] as String? ?? '';
    port = (j['port'] as num?)?.toInt() ?? 587;
    security = j['security'] as String? ?? 'starttls';
    user = j['user'] as String? ?? '';
    pass = Secret.decrypt(j['pass'] as String? ?? '');
    from = j['from'] as String? ?? '';
    to = j['to'] as String? ?? '';
    startWithWindows = j['startWithWindows'] as bool? ?? false;
    sent = {
      if (j['sent'] is Map)
        for (final e in (j['sent'] as Map).entries) '${e.key}': [for (final c in (e.value as List? ?? [])) '$c'],
    };
    lastCheck = DateTime.tryParse(j['lastCheck'] as String? ?? '');
  }
}

class Store {
  /// Tests keep their settings in a folder of their own, never in the real one.
  static String? testFolder;
  static String get folder => testFolder ?? _folder;

  /// Where the projects, targets, keys and history are kept: the "settings" folder next to the installed program
  /// (D:\Deploiement\settings), so that every way of starting it sees the same projects — %APPDATA% can be redirected
  /// (a program started from another packaged app, like Claude, writes into that app's own copy of %APPDATA%).
  /// %APPDATA%\Deploiement when the program folder cannot be written (Program Files), or in development.
  /// The first time, the most recent settings found on this PC are taken over (former folders, former name
  /// "PHP Deploy", redirected copies): keys stay readable, Windows ties them to this account, not to a folder.
  static final String _folder = _settingsFolder();
  static String _settingsFolder() {
    final appData = Platform.environment['APPDATA'] ?? Directory.current.path;
    final local = Platform.environment['LOCALAPPDATA'] ?? '';
    final exe = File(Platform.resolvedExecutable);
    final installed = p.basename(exe.path).toLowerCase() == 'deploiement.exe' && !exe.path.contains(r'\build\');
    Directory? next;
    if (installed) {
      try {
        final d = Directory(p.join(exe.parent.path, 'settings'))..createSync(recursive: true);
        File(p.join(d.path, '.write-test'))
          ..writeAsStringSync('ok')
          ..deleteSync();
        next = d;
      } catch (_) {}
    }
    final now = next ?? Directory(p.join(appData, 'Deploiement'));
    if (!File(p.join(now.path, 'config.json')).existsSync()) {
      try {
        final places = [
          p.join(appData, 'Deploiement'),
          p.join(appData, 'PHP Deploy'),
          if (local.isNotEmpty && Directory(p.join(local, 'Packages')).existsSync())
            for (final pkg in Directory(p.join(local, 'Packages')).listSync().whereType<Directory>())
              for (final n in ['Deploiement', 'PHP Deploy']) p.join(pkg.path, 'LocalCache', 'Roaming', n),
        ];
        File? best;
        for (final d in places) {
          final c = File(p.join(d, 'config.json'));
          if (d != now.path && c.existsSync() && (best == null || c.lastModifiedSync().isAfter(best.lastModifiedSync()))) best = c;
        }
        if (best != null) {
          now.createSync(recursive: true);
          for (final f in best.parent.listSync().whereType<File>()) {
            f.copySync(p.join(now.path, p.basename(f.path)));
          }
        }
      } catch (_) {}
    }
    return now.path;
  }
  static File get _file => File(p.join(folder, 'config.json'));

  /// Working folder (built packages, database copies): next to the installed program, or the source folder in dev.
  static Directory get work {
    final exe = File(Platform.resolvedExecutable);
    final installed = p.basename(exe.path).toLowerCase() == 'deploiement.exe' && !exe.path.contains(r'\build\');
    final d = Directory(p.join(installed ? exe.parent.path : Directory.current.path, 'work'));
    d.createSync(recursive: true);
    return d;
  }

  static (AppSettings, List<Project>) load() {
    final s = AppSettings();
    final projects = <Project>[];
    try {
      if (_file.existsSync()) {
        final j = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
        s.read((j['settings'] as Map?)?.cast<String, dynamic>() ?? {});
        for (final x in (j['projects'] as List? ?? [])) {
          projects.add(Project.fromJson((x as Map).cast<String, dynamic>()));
        }
      }
    } catch (_) {
      if (_file.existsSync()) _file.copySync('${_file.path}.bak');
    }
    return (s, projects);
  }

  static void save(AppSettings s, List<Project> projects) {
    Directory(folder).createSync(recursive: true);
    final tmp = File('${_file.path}.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'settings': s.toJson(),
      'projects': projects.map((x) => x.toJson()).toList(),
    }));
    tmp.renameSync(_file.path);
  }
}
