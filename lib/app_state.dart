// What the pages share: projects, the selected page, the log, last reports, and the "one operation at a time" runner.
// What the pages show (last test, last simulation, last error of each target, the log) is kept in state.json and
// shown again when Déploiement is reopened.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max, min;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'theme.dart';

import 'i18n.dart';
import 'models.dart';
import 'operations.dart';
import 'results.dart';
import 'watch.dart';

class AppState extends ChangeNotifier {
  AppState({AppSettings? settings, List<Project>? projects, this.persist = true}) {
    if (settings != null && projects != null) {
      this.settings = settings;
      this.projects = projects;
    } else {
      final (s, p) = Store.load();
      this.settings = s;
      this.projects = p;
    }
    language.value = this.settings.language;
    if (persist) {
      SavedState.load(this);
      addListener(_keep);
      journal.addListener(_keep);
      try {
        _exit = AppLifecycleListener(onExitRequested: () async {
          for (final f in [...flushers]) {
            f();
          }
          SavedState.save(this);
          return AppExitResponse.exit;
        });
      } catch (_) {}
    }
    final t = this.projects.firstOrNull?.targets.firstOrNull;
    route = t != null ? 't:${t.id}' : (this.projects.isNotEmpty ? 'p:${this.projects.first.id}' : 'home');
  }

  final bool persist; // false for screenshots and tests

  /// The settings pages open now: they write what is typed and not saved yet (the app is closing).
  final flushers = <VoidCallback>{};
  bool _gone = false;
  Timer? _keepTimer;
  DateTime _kept = DateTime.now();
  AppLifecycleListener? _exit;

  /// Something changed on screen: written to state.json 2 s later, at most 15 s later during a long operation.
  void _keep() {
    _keepTimer?.cancel();
    if (DateTime.now().difference(_kept).inSeconds >= 15) {
      _kept = DateTime.now();
      SavedState.save(this);
      return;
    }
    _keepTimer = Timer(const Duration(seconds: 2), () {
      _kept = DateTime.now();
      SavedState.save(this);
    });
  }

  @override
  void dispose() {
    _gone = true;
    _keepTimer?.cancel();
    _exit?.dispose();
    super.dispose();
  }
  late AppSettings settings;
  late List<Project> projects;
  final journal = Journal();
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  bool busy = false;
  bool activityOpen = false;
  String? busyTarget; // the target an operation is running on
  DateTime? busySince;

  /// The page shown: "home", "settings", "p:`project id`", "t:`target id`", "t:`target id`:settings".
  String route = 'home';
  final reports = <String, Report>{};
  final statuses = <String, Map<String, dynamic>>{};
  final health = <String, bool>{};
  final errors = <String, String>{};

  /// The checks of the targets and their email alerts (watch.dart); what the last check found, per target.
  late final watcher = Watcher(this);
  final watchProblems = <String, List<Problem>>{};

  /// The deployments of each target, newest first (history.json), and the one to show on its page right after it.
  late final Map<String, List<DeployResult>> history = persist ? History.load() : {};
  final lastResult = <String, DeployResult>{};

  void addResult(Target t, DeployResult r) {
    (history[t.id] ??= []).insert(0, r);
    lastResult[t.id] = r;
    if (persist) History.save(history);
  }

  Target? get target {
    if (!route.startsWith('t:')) return null;
    final id = route.split(':')[1];
    for (final p in projects) {
      for (final t in p.targets) {
        if (t.id == id) return t;
      }
    }
    return null;
  }

  Project? get project {
    if (route.startsWith('p:')) return projects.where((p) => p.id == route.substring(2)).firstOrNull;
    final t = target;
    return t == null ? null : projects.where((p) => p.targets.contains(t)).firstOrNull;
  }

  void go(String r) {
    route = r;
    notifyListeners();
  }

  /// Deletes a target from this app: its settings, its last checks and its history. Nothing is touched on the target.
  /// Returns what puts it back ("Undo").
  VoidCallback removeTarget(Project pr, Target t) {
    final i = pr.targets.indexWhere((x) => x.id == t.id);
    if (i < 0) return () {};
    pr.targets.removeAt(i);
    final back = _forget([t.id]);
    if (route == 't:${t.id}' || route == 't:${t.id}:settings') route = 'p:${pr.id}';
    save();
    return () {
      if (!projects.contains(pr) || pr.targets.any((x) => x.id == t.id)) return;
      pr.targets.insert(min(i, pr.targets.length), t);
      back();
      save();
    };
  }

  /// Deletes a project and its targets from this app. Nothing is touched on this PC nor on the targets.
  /// Returns what puts it back ("Undo").
  VoidCallback removeProject(Project pr) {
    final i = projects.indexWhere((x) => x.id == pr.id);
    if (i < 0) return () {};
    projects.removeAt(i);
    final ids = [for (final t in pr.targets) t.id];
    final back = _forget(ids);
    if (route == 'p:${pr.id}' || ids.any((id) => route == 't:$id' || route == 't:$id:settings')) route = 'home';
    save();
    return () {
      if (projects.any((x) => x.id == pr.id)) return;
      projects.insert(min(i, projects.length), pr);
      back();
      save();
    };
  }

  /// Drops what the app keeps about these targets; returns what puts it back.
  VoidCallback _forget(List<String> ids) {
    final kept = {
      for (final id in ids)
        id: (reports.remove(id), statuses.remove(id), health.remove(id), errors.remove(id), watchProblems.remove(id), history.remove(id), lastResult.remove(id)),
    };
    if (persist && kept.values.any((k) => k.$6 != null)) History.save(history);
    return () {
      for (final MapEntry(key: id, value: k) in kept.entries) {
        if (k.$1 != null) reports[id] = k.$1!;
        if (k.$2 != null) statuses[id] = k.$2!;
        if (k.$3 != null) health[id] = k.$3!;
        if (k.$4 != null) errors[id] = k.$4!;
        if (k.$5 != null) watchProblems[id] = k.$5!;
        if (k.$6 != null) history[id] = k.$6!;
        if (k.$7 != null) lastResult[id] = k.$7!;
      }
      if (persist && kept.values.any((k) => k.$6 != null)) History.save(history);
    };
  }

  void setLanguage(String l) {
    settings.language = l;
    language.value = l;
    save();
  }

  void save() {
    if (persist) Store.save(settings, projects);
    notifyListeners();
  }

  void changed() => notifyListeners();

  /// Writes the settings without redrawing now (a page is being closed): the screens follow at the next frame.
  void persistQuietly() {
    if (persist) Store.save(settings, projects);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_gone) notifyListeners();
    });
  }

  /// A short message at the bottom of the window; errors stay longer.
  void notify(String title, {String? text, Severity severity = Severity.success, (String, VoidCallback)? action}) {
    final m = messengerKey.currentState;
    final ctx = navigatorKey.currentContext; // under the theme (the messenger is above it)
    if (m == null || ctx == null) return;
    // The bubble is ink on paper: its marks use the colours of the other theme so they stay readable.
    final inverse = Theme.of(ctx).brightness == Brightness.light ? Palette.dark : Palette.light;
    final markOnInk = switch (severity) {
      Severity.success => inverse.added,
      Severity.info => inverse.changed,
      Severity.warning => inverse.accent,
      Severity.error => inverse.removed,
    };
    final width = MediaQuery.sizeOf(ctx).width;
    m
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        width: width < 560 ? null : 480,
        duration: Duration(seconds: severity == Severity.error || action != null ? 8 : 4),
        persist: false, // "Undo" goes away by itself too
        action: action == null ? null : SnackBarAction(label: action.$1, textColor: inverse.accent, onPressed: action.$2),
        content: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 3, height: text == null ? 18 : 36, color: markOnInk),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (text != null) Text(text, maxLines: 4, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
      ));
  }

  /// Runs one operation; errors go to the log and a notification.
  Future<T?> run<T>(Target? t, Future<T> Function(Operations o) f) async {
    if (busy) return null;
    busy = true;
    busyTarget = t?.id;
    busySince = DateTime.now();
    activityOpen = true;
    if (t != null) errors.remove(t.id);
    notifyListeners();
    try {
      final ops = Operations(settings, journal);
      if (t != null) ops.onResult = (r) => addResult(t, r);
      final r = await f(ops);
      save();
      return r;
    } catch (e) {
      journal.error('$e');
      if (t != null) errors[t.id] = '$e'.split('\n').first;
      notify(tr('Error'), text: '$e'.split('\n').first, severity: Severity.error);
      return null;
    } finally {
      journal.idle();
      busy = false;
      busyTarget = null;
      notifyListeners();
    }
  }
}

enum Severity { success, info, warning, error }

/// What the pages showed (state.json next to the settings): per target its last test, last simulation and last error;
/// the last 400 lines of the activity log.
class SavedState {
  static File get _file => File(p.join(Store.folder, 'state.json'));

  static void save(AppState a) {
    try {
      final ids = {for (final p in a.projects) for (final t in p.targets) t.id};
      final lines = a.journal.lines;
      final j = {
        'targets': {
          for (final id in ids)
            if (a.statuses.containsKey(id) || a.health.containsKey(id) || a.errors.containsKey(id) || a.reports.containsKey(id))
              id: {
                if (a.statuses[id] != null) 'status': a.statuses[id],
                if (a.health[id] != null) 'health': a.health[id],
                if (a.errors[id] != null) 'error': a.errors[id],
                if (a.reports[id] != null) 'report': a.reports[id]!.toJson(),
              },
        },
        'log': [
          for (final l in lines.skip(max(0, lines.length - 400))) {'t': l.time.toIso8601String(), 'l': l.level.name, 'x': l.text},
        ],
      };
      Directory(Store.folder).createSync(recursive: true);
      final tmp = File('${_file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(j));
      tmp.renameSync(_file.path);
    } catch (_) {} // never in the way: the next change writes it again
  }

  static void load(AppState a) {
    try {
      if (!_file.existsSync()) return;
      final j = (jsonDecode(_file.readAsStringSync()) as Map).cast<String, dynamic>();
      final ids = {for (final p in a.projects) for (final t in p.targets) t.id};
      for (final e in ((j['targets'] as Map?) ?? {}).entries) {
        final id = '${e.key}';
        if (!ids.contains(id) || e.value is! Map) continue;
        final v = (e.value as Map).cast<String, dynamic>();
        if (v['status'] is Map) a.statuses[id] = (v['status'] as Map).cast<String, dynamic>();
        if (v['health'] is bool) a.health[id] = v['health'] as bool;
        if (v['error'] is String) a.errors[id] = v['error'] as String;
        if (v['report'] is Map) {
          try {
            a.reports[id] = Report.fromJson((v['report'] as Map).cast<String, dynamic>());
          } catch (_) {}
        }
      }
      final log = [
        for (final l in (j['log'] as List? ?? []))
          if (l is Map) LogLine(Level.values.firstWhere((x) => x.name == l['l'], orElse: () => Level.info), '${l['x']}', DateTime.tryParse('${l['t']}')),
      ];
      if (log.isNotEmpty) {
        a.journal.lines
          ..addAll(log)
          ..add(LogLine(Level.detail, tr('Déploiement reopened: the lines above are from before.')));
      }
    } catch (_) {}
  }
}
