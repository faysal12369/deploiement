// "Send to GitHub" without GitHub: a bare repository in a temporary folder plays the remote. A new repository gets a
// .gitignore that keeps passwords and uploads on this PC; changes are committed and pushed to a branch; nothing new is
// fine; a branch that moved on elsewhere is never overwritten; a bad branch name is refused.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:deploiement/agent_client.dart';
import 'package:deploiement/git.dart';
import 'package:deploiement/models.dart';
import 'package:deploiement/results.dart';

Future<String> git(List<String> args, {String? dir}) async {
  final r = await Process.run('git', args, workingDirectory: dir);
  if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
  return '${r.stdout}'.trim();
}

void main() {
  test('send a project to a branch', () async {
    final root = Directory.systemTemp.createTempSync('deploiement-git');
    addTearDown(() => root.deleteSync(recursive: true));
    final src = Directory(p.join(root.path, 'shop'))..createSync();
    void write(String rel, String text) => File(p.join(src.path, rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
    write('index.php', '<?php echo "v1";');
    write('.env', 'DB_PASSWORD=secret');
    write('config/db.php', '<?php \$password = "secret";');
    write('uploads/photo.jpg', 'jpeg');
    write('debug.log', 'log');
    final project = Project(id: 'p', name: 'shop', folder: src.path, keep: ['.env', 'config/db.php', 'uploads/']);
    final g = Git(src.path);

    // ---- a folder that is not a repository yet
    var s = await g.state();
    expect([s.installed, s.repo], [true, false]);

    // ---- created: the .gitignore keeps what is never sent and what the targets keep
    await g.create(branch: 'main', ignore: [...project.exclude, ...project.keep]);
    final ignore = File(p.join(src.path, '.gitignore')).readAsStringSync();
    expect(ignore, allOf(contains('.env'), contains('config/db.php'), contains('uploads/'), contains('*.log')));
    expect(ignore, isNot(contains('.git/')));
    s = await g.state();
    expect([s.repo, s.branch, s.remote], [true, 'main', '']);
    expect(s.changes.map((c) => c.path).toSet(), {'.gitignore', 'index.php'}, reason: 'passwords, uploads and logs are ignored');

    // ---- linked to a remote (here a bare repository), then sent to a branch that is not the local one
    final remote = p.join(root.path, 'remote.git');
    await git(['init', '--bare', '-q', remote]);
    await g.link(remote);
    expect((await g.state()).remote, remote);
    final id1 = await g.send(branch: 'deploy/test', message: 'first');
    expect(await git(['--git-dir', remote, 'log', '--format=%s', 'deploy/test']), 'first');
    expect(await git(['--git-dir', remote, 'ls-tree', '-r', '--name-only', 'deploy/test']), '.gitignore\nindex.php');
    expect(await git(['rev-parse', '--short', 'HEAD'], dir: src.path), id1);

    // ---- a change: committed and sent; the list shows it before
    write('index.php', '<?php echo "v2";');
    s = await g.state();
    expect(s.changes.single.code, 'M');
    expect(s.changes.single.path, 'index.php');
    await g.send(branch: 'deploy/test', message: 'second');
    expect(await git(['--git-dir', remote, 'log', '--format=%s', 'deploy/test']), 'second\nfirst');

    // ---- nothing new: the last commit is sent again, no empty commit
    final id3 = await g.send(branch: 'deploy/test', message: 'nothing');
    expect(await git(['--git-dir', remote, 'log', '--format=%s', 'deploy/test']), 'second\nfirst');
    expect(id3, await git(['rev-parse', '--short', 'HEAD'], dir: src.path));

    // ---- the branch moved on elsewhere: refused, explained, nothing overwritten
    final other = p.join(root.path, 'other');
    await git(['clone', '-q', '-b', 'deploy/test', remote, other]);
    File(p.join(other, 'readme.txt')).writeAsStringSync('from another PC');
    await git(['add', '-A'], dir: other);
    await git(['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'elsewhere'], dir: other);
    await git(['push', '-q', 'origin', 'deploy/test'], dir: other);
    write('index.php', '<?php echo "v3";');
    await expectLater(g.send(branch: 'deploy/test', message: 'third'), throwsA(isA<AgentError>().having((e) => e.message, 'message', contains('already has commits'))));
    expect(await git(['--git-dir', remote, 'log', '-1', '--format=%s', 'deploy/test']), 'elsewhere');

    // ---- a bad branch name
    await expectLater(g.send(branch: 'bad..name', message: 'x'), throwsA(isA<AgentError>()));
  });

  test('what looks like a password, and the GitHub part of a deployment', () {
    expect([for (final f in ['.env', '.env.production', 'config/db.php', 'config/app.local.php', 'dump.sql', 'index.php', 'pages/home.php']) GitChange('M', f).sensitive],
        [true, true, true, true, true, false, false]);
    final r = DeployResult.fromJson((DeployResult(time: DateTime(2026, 11, 17), project: 'p', target: 't')
          ..parts = const DeployParts(github: true)
          ..git = 'main abc123')
        .toJson());
    expect([r.parts.github, r.git, r.parts.label], [true, 'main abc123', 'Files + Structure + Data + GitHub']);
    expect(DeployResult.fromJson({'time': '2026-11-01T10:00:00', 'parts': {'files': true}}).parts.github, false);
    final pr = Project.fromJson(Project(id: 'x', gitRemote: 'https://github.com/a/b.git', gitBranch: 'main').toJson());
    expect([pr.gitRemote, pr.gitBranch, pr.gitReady], ['https://github.com/a/b.git', 'main', true]);
  });
}
