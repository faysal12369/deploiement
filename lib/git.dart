// GitHub: the project folder as a Git repository, its changes committed and pushed to a branch (asked 17/11/2026:
// "push to a GitHub branch", from the project page and with each deployment). git.exe (Git for Windows) does the work;
// its credential manager signs in to GitHub once, in the browser. The GitHub CLI (gh), when signed in, can also create
// the repository. Nothing is ever forced: a branch that has commits this PC does not have is left as it is.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent_client.dart' show AgentError;
import 'i18n.dart';
import 'operations.dart' show Journal;

/// The GitHub part of the screens (false hides it everywhere).
const kGitHub = true;

/// A changed file, as "git status" gives it: M changed, A added, D deleted, ? new (not followed yet), R renamed.
class GitChange {
  GitChange(this.code, this.path);
  final String code;
  final String path;

  /// Looks like a file with passwords or data: worth a second look before it goes to GitHub.
  bool get sensitive {
    final n = p.posix.basename(path).toLowerCase();
    return n == '.env' || n.startsWith('.env.') || n.endsWith('.local.php') || n == 'wp-config.php' || n == 'db.php' ||
        RegExp(r'\.(sql|sql\.gz|key|pem|pfx|p12)$').hasMatch(n) || n.contains('password') || n.contains('secret');
  }
}

/// What the project folder is for Git right now.
class GitState {
  GitState({this.installed = true, this.repo = false, this.branch = '', this.remote = '', this.changes = const [], this.gh = false});
  final bool installed, repo;
  final String branch; // the branch of this PC
  final String remote; // the address of "origin", '' when none
  final List<GitChange> changes;
  final bool gh; // the GitHub CLI is installed and signed in
}

class Git {
  Git(this.folder);
  final String folder;

  /// Screen tests: git is not run (the project page shows a folder that is not a repository).
  static bool offline = false;

  static Map<String, String> get _env => {'GIT_TERMINAL_PROMPT': '0', 'LC_ALL': 'C', 'LANG': 'C'};

  Future<ProcessResult> _run(List<String> args, {bool check = true, String exe = 'git'}) async {
    final ProcessResult r;
    try {
      r = await Process.run(exe, args, workingDirectory: folder, environment: _env, stdoutEncoding: utf8, stderrEncoding: utf8);
    } on ProcessException {
      throw AgentError(exe == 'git'
          ? tr('Git is not installed on this PC: install Git for Windows (git-scm.com), then try again.')
          : tr('The GitHub CLI (gh) is not installed on this PC.'));
    }
    if (check && r.exitCode != 0) throw AgentError(explain('${r.stderr}'.trim().isEmpty ? '${r.stdout}' : '${r.stderr}'));
    return r;
  }

  Future<String> _out(List<String> args) async => '${(await _run(args)).stdout}'.trim();

  /// The address of a GitHub repository from what was pasted: the address of one of its pages (19/11/2026: the
  /// address bar on ".../shop/branches" gave "GitHub cannot be reached"), without ".git", or without "https://".
  /// Anything else (SSH, another server, a folder) is kept as it is.
  static String repoUrl(String raw) {
    final s = raw.trim();
    final m = RegExp(r'^(?:https?://)?(?:www\.)?github\.com/([A-Za-z0-9-]+)/([A-Za-z0-9._-]+?)(?:\.git)?(?:[/?#].*)?$', caseSensitive: false).firstMatch(s);
    if (m == null) return s;
    return 'https://github.com/${m[1]}/${m[2]}.git';
  }

  /// A message of git turned into what to do.
  static String explain(String raw) {
    final s = raw.trim();
    final l = s.toLowerCase();
    if (l.contains('fetch first') || l.contains('non-fast-forward') || l.contains('[rejected]')) {
      return tr('GitHub already has commits on this branch that are not on this PC: get them first (git pull), then send again. Nothing was overwritten.');
    }
    if (l.contains('authentication failed') || l.contains('could not read username') || l.contains('terminal prompts disabled') || l.contains('permission denied') || l.contains('error: 403')) {
      return tr('GitHub refused the sign-in: sign in once (a browser window opens on the first send), or check that this account can write to the repository.');
    }
    // GitHub answers 410 or 400 to the address of a page that is not the repository itself
    if (RegExp(r'returned error: (400|410)').hasMatch(l)) {
      return tr('This address is a page of the GitHub site, not a repository: use the address of the repository, like https://github.com/account/project.git.');
    }
    if (l.contains('repository not found') || l.contains('not found') || l.contains('returned error: 404')) {
      return tr('Repository not found on GitHub, or this account cannot write to it: check its address.');
    }
    if (l.contains('could not resolve host') || l.contains('failed to connect') || l.contains('timed out') || l.contains("couldn't connect")) {
      return tr('GitHub cannot be reached from this PC: check the internet connection.');
    }
    return s.split('\n').where((x) => x.trim().isNotEmpty).take(3).join('\n');
  }

  static Future<bool> get installed async {
    try {
      return (await Process.run('git', ['--version'])).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> get ghReady async {
    try {
      return (await Process.run('gh', ['auth', 'status'], environment: _env)).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<GitState> state() async {
    if (offline) return GitState();
    if (!await installed) return GitState(installed: false);
    if (folder.trim().isEmpty || !Directory(folder).existsSync()) return GitState();
    final top = await _run(['rev-parse', '--show-toplevel'], check: false);
    if (top.exitCode != 0) return GitState(gh: await ghReady);
    final branch = await _out(['branch', '--show-current']);
    final o = await _run(['remote', 'get-url', 'origin'], check: false);
    return GitState(repo: true, branch: branch, remote: o.exitCode == 0 ? '${o.stdout}'.trim() : '', changes: await changes(), gh: await ghReady);
  }

  /// The files that differ from the last commit (new ones too, ignored ones not).
  Future<List<GitChange>> changes() async {
    final raw = '${(await _run(['status', '--porcelain=v1', '-z', '--untracked-files=all'])).stdout}';
    final parts = raw.split('\x00');
    final out = <GitChange>[];
    for (var i = 0; i < parts.length; i++) {
      final e = parts[i];
      if (e.length < 4) continue;
      final xy = e.substring(0, 2);
      final code = xy == '??' ? '?' : (xy.trim().isEmpty ? 'M' : xy.trim()[0]);
      out.add(GitChange(code, e.substring(3)));
      if (code == 'R' || code == 'C') i++; // followed by the old name
    }
    return out;
  }

  /// A new repository in the project folder, with a .gitignore made of what is never sent and what each target keeps
  /// (.env, config files with passwords, uploads…), so that they never go to GitHub. An existing .gitignore is kept.
  Future<void> create({required String branch, required List<String> ignore}) async {
    await _run(['init', '-b', branch.isEmpty ? 'main' : branch]);
    final gi = File(p.join(folder, '.gitignore'));
    if (!gi.existsSync()) {
      final lines = <String>{for (final x in ignore) if (x.trim().isNotEmpty && x.trim() != '.git/') x.trim()};
      gi.writeAsStringSync('# Written by Déploiement: never sent to the servers, or kept on them (passwords, uploads…)\n${lines.join('\n')}\n');
    }
  }

  /// "origin" is set to [url] (added, or changed), the address of a GitHub page turned into the repository's.
  /// Returns the address set.
  Future<String> link(String url) async {
    final u = repoUrl(url);
    final has = (await _run(['remote', 'get-url', 'origin'], check: false)).exitCode == 0;
    await _run(['remote', has ? 'set-url' : 'add', 'origin', u]);
    return u;
  }

  /// A project linked before 19/11/2026 with the address of a GitHub page: "origin" is set to the repository's.
  /// Returns the address set, or null when there was nothing to change.
  Future<String?> repairOrigin() async {
    final o = await _run(['remote', 'get-url', 'origin'], check: false);
    if (o.exitCode != 0) return null;
    final now = '${o.stdout}'.trim();
    final good = repoUrl(now);
    if (good == now) return null;
    await _run(['remote', 'set-url', 'origin', good]);
    return good;
  }

  /// A private repository on GitHub with the name of [name], linked as "origin" (the GitHub CLI, signed in).
  Future<String> createOnGitHub(String name) async {
    final slug = name.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    await _run(['repo', 'create', slug.isEmpty ? 'project' : slug, '--private', '--source', '.', '--remote', 'origin'], exe: 'gh');
    return await _out(['remote', 'get-url', 'origin']);
  }

  /// Everything that changed is committed with [message] (nothing new: the last commit is sent as it is), then pushed
  /// to [branch] on GitHub, whatever the branch of this PC. Returns the short id of the commit sent.
  Future<String> send({required String branch, required String message, Journal? log}) async {
    if (!RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(branch) || branch.startsWith('/') || branch.endsWith('/') || branch.contains('..')) {
      throw AgentError(tr('"{branch}" is not a valid branch name.', {'branch': branch}));
    }
    await _run(['add', '-A']);
    final staged = await _run(['diff', '--cached', '--quiet'], check: false);
    if (staged.exitCode == 1) {
      final n = (await _out(['diff', '--cached', '--name-only'])).split('\n').where((x) => x.isNotEmpty).length;
      // a commit needs a name and an email: this PC's Git settings, else the Windows account
      final named = (await _run(['config', 'user.email'], check: false)).exitCode == 0;
      final who = Platform.environment['USERNAME'] ?? 'deploiement';
      await _run([if (!named) ...['-c', 'user.name=$who', '-c', 'user.email=$who@${Platform.localHostname}.local'], 'commit', '-q', '-m', message]);
      log?.info(tr('Commit: {n} file(s) — "{message}".', {'n': n, 'message': message}));
    } else {
      final head = await _run(['rev-parse', '--verify', 'HEAD'], check: false);
      if (head.exitCode != 0) throw AgentError(tr('Nothing to send: the folder has no file for Git yet.'));
      log?.info(tr('Nothing new to commit: the last commit is sent.'));
    }
    final id = await _out(['rev-parse', '--short', 'HEAD']);
    final fixed = await repairOrigin();
    if (fixed != null) log?.info(tr('GitHub address corrected: {url}', {'url': fixed}));
    log?.info(tr('Sending to GitHub, branch "{branch}"…', {'branch': branch}));
    await _run(['push', 'origin', 'HEAD:refs/heads/$branch']);
    return id;
  }
}
