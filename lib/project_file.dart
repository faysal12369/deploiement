// A project as a file (.deploy.json): to move it to another PC or give it to a colleague. Exported without passwords
// nor agent keys; imported with new ids and new keys, so "Place the agent" is needed once on each target.
import 'dart:convert';
import 'dart:io';

import 'i18n.dart';
import 'models.dart';

class ProjectFile {
  static const marker = 'php_deploy_project';

  /// Writes the project without any secret: passwords emptied, agent keys removed.
  static void write(Project project, String path) {
    final j = project.toJson(secrets: false);
    for (final t in (j['targets'] as List)) {
      (t as Map)['token'] = '';
    }
    File(path).writeAsStringSync(const JsonEncoder.withIndent('  ').convert({marker: 1, ...j}));
  }

  /// Reads an exported project. It gets a new id (and its targets too), a name not already [taken], new agent keys
  /// and a new agent file name, and no last action. The agent this PC places then sits next to the one of the PC the
  /// project came from, each with its own key: both PCs keep working on the same server, neither replaces the other.
  static Project read(String path, {Iterable<String> taken = const []}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(File(path).readAsStringSync());
    } on FormatException {
      throw FormatException(tr('This is not a Déploiement project file.'));
    }
    if (decoded is! Map || decoded[marker] == null) throw FormatException(tr('This is not a Déploiement project file.'));
    final j = decoded.cast<String, dynamic>();
    j['id'] = randomHex(8);
    j['targets'] = [
      for (final t in (j['targets'] as List? ?? []))
        {...(t as Map).cast<String, dynamic>(), 'id': randomHex(8), 'token': '', 'agentName': null, 'pass': '', 'lastAction': ''},
    ];
    final p = Project.fromJson(j);
    p.name = uniqueName(p.name.trim().isEmpty ? tr('Imported project') : p.name.trim(), taken);
    return p;
  }

  /// [base], or "base (2)", "base (3)"… when the name is already used.
  static String uniqueName(String base, Iterable<String> taken) {
    final names = taken.toSet();
    var name = base;
    for (var i = 2; names.contains(name); i++) {
      name = '$base ($i)';
    }
    return name;
  }
}
