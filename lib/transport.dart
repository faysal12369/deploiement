// Putting files into the project folder of a target: FTP, FTPES, FTPS, SFTP, a Windows folder, or through the agent.
import 'dart:io';

import 'package:ftpconnect/ftpconnect.dart';
import 'package:path/path.dart' as p;

import 'agent_client.dart';
import 'i18n.dart';
import 'models.dart';

abstract class Sender {
  Future<void> open();
  Future<void> close();

  /// [rel]: path relative to the project folder on the target ("deploy-agent-x.php", ".deploy/packages/p.zip.part").
  Future<void> send(File local, String rel, Progress progress);

  /// A package or a database copy for the agent: sent as "`name`.part" into its private folder, checked, renamed.
  Future<void> deliver(AgentClient agent, File local, String name, Progress progress) async {
    await send(local, '${agent.target.privateDir.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '')}/packages/$name.part', progress);
    await agent.uploadDone(local, name);
  }

  bool get canPlaceFiles => true;

  static Sender forTarget(Target t) => switch (t.transport) {
        Transport.folder => FolderSender(t),
        Transport.agentOnly => AgentSender(t),
        _ => FileTransferSender(t),
      };
}

/// FTP, FTPES, FTPS and SFTP (ftpconnect package).
class FileTransferSender extends Sender {
  FileTransferSender(this.t);
  final Target t;
  late FileTransferClient _client;
  String? _home; // the login folder: where a relative project folder starts

  @override
  Future<void> open() async {
    _client = t.transport == Transport.sftp
        ? SFTPConnect(t.host, port: t.port, user: t.user, pass: t.pass, timeout: 60)
        : FTPConnect(t.host,
            port: t.port,
            user: t.user,
            pass: t.pass,
            timeout: 60,
            securityType: switch (t.transport) {
              Transport.ftpes => SecurityType.ftpes,
              Transport.ftps => SecurityType.ftps,
              _ => SecurityType.ftp,
            });
    try {
      if (!await _client.connect()) throw AgentError(tr('{transport} login refused by {host}.', {'transport': t.transport.label, 'host': t.host}));
      // Binary ("TYPE I"): an FTP server starts in text mode (ASCII) and ftpconnect never leaves it by itself, so a
      // Linux shared host changed the line ends inside every zip: "arrived damaged (checksum differs)",
      // 17/11/2026. Sent again after each new connection (connect() forgets the type).
      final c = _client;
      if (c is FTPConnect) await c.setTransferType(TransferType.binary);
    } catch (e) {
      if (e is AgentError) rethrow;
      final raw = '$e';
      final hint = t.transport == Transport.sftp && t.port == 21
          ? tr('Port 21 is the FTP port, not the SFTP one: put the SSH port (22, or the one your host shows, e.g. 65002 on Hostinger), or choose FTP.')
          : RegExp(r'\b530\b|wrong username|login incorrect|authentication failed|auth.*(fail|denied)', caseSensitive: false).hasMatch(raw)
              ? tr('{host} refuses the user or the password ({transport}). Copy them again from your host\'s panel: the FTP password is not the password of the panel. Several failed tries can block this PC for a while.',
                  {'host': t.host, 'transport': t.transport.label})
          : RegExp(r'refused|1225|10061', caseSensitive: false).hasMatch(raw)
          ? tr('{host} refused the {transport} connection on port {port}: no {transport} server there, or a firewall blocks it. If the server is reached only by its web address, choose "Agent only" in the target settings.',
              {'host': t.host, 'transport': t.transport.label, 'port': t.port})
          : RegExp(r'timed? ?out|semaphore|121\b|10060', caseSensitive: false).hasMatch(raw)
              ? tr('{host} does not answer on port {port} ({transport}): check the host, the port, and that this PC can reach it.', {'host': t.host, 'port': t.port, 'transport': t.transport.label})
              : RegExp(r'host lookup|11001|no such host', caseSensitive: false).hasMatch(raw)
                  ? tr('Unknown host: {host}. Check the name in the target settings.', {'host': t.host})
                  : tr('Cannot connect by {transport} to {host}:{port}.', {'transport': t.transport.label, 'host': t.host, 'port': t.port});
      throw AgentError('$hint\n$raw');
    }
  }

  @override
  Future<void> close() async {
    try {
      await _client.disconnect();
    } catch (_) {}
  }

  /// Goes into [dir] (from the current folder). [create]: what is missing is created (the agent's own folders);
  /// otherwise a missing folder is an error (the project folder: created by mistake, the site would not see it).
  Future<void> _cd(String dir, {required bool create}) async {
    for (final d in dir.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty)) {
      if (d == '..') {
        await _client.changeDirectory('..');
        continue;
      }
      if (await _client.changeDirectory(d)) continue;
      if (!create) {
        throw AgentError(tr('The project folder "{path}" does not exist on {host}: check it in the target settings (your host\'s panel shows the folder of each domain and subdomain).',
            {'path': t.remotePath, 'host': t.host}));
      }
      await _client.makeDirectory(d);
      if (!await _client.changeDirectory(d)) throw AgentError(tr('Cannot create or open "{dir}" on {host}.', {'dir': d, 'host': t.host}));
    }
  }

  /// A cut or a timeout of the transfer (17/11/2026, a shared host: "semaphore timeout"): the FTP
  /// login works but the port the server opens for the file does not answer in time. Usually passing: the file is
  /// sent again on a new connection, up to 3 tries.
  static bool _passing(Object e) =>
      e is! AgentError &&
      RegExp(r'SocketException|semaphore|timed? ?out|\b121\b|10060|10053|10054|connection (reset|closed|aborted)|broken pipe', caseSensitive: false)
          .hasMatch('$e');

  @override
  Future<void> send(File local, String rel, Progress progress) async {
    const tries = 3;
    for (var n = 1;; n++) {
      try {
        return await _send(local, rel, progress);
      } catch (e) {
        if (!_passing(e)) rethrow;
        final raw = '$e';
        if (n >= tries) {
          final port = RegExp(r'port = (\d+)').firstMatch(raw)?.group(1);
          throw AgentError(
              '${tr('The {transport} connection to {host} works, but the transfer of {name} did not get through ({n} tries): the port the server opens for the file{port} does not answer. Try again in a moment; if it keeps failing, a firewall, an antivirus or the network of this PC blocks it: try another network (a phone connection) or FTPES.', {
                'transport': t.transport.label,
                'host': t.host,
                'name': p.posix.basename(rel),
                'n': tries,
                'port': port == null ? '' : ' ($port)',
              })}\n$raw');
        }
        progress(tr('{host} did not answer during the transfer: new try ({n}/{max})…', {'host': t.host, 'n': n + 1, 'max': tries}));
        await close();
        await Future.delayed(Duration(seconds: 3 * n));
        await open();
      }
    }
  }

  Future<void> _send(File local, String rel, Progress progress) async {
    final root = t.remotePath.trim();
    final sub = p.posix.dirname(rel.replaceAll('\\', '/'));
    // absolute, or relative to the login folder
    if (root.startsWith('/')) {
      if (!await _client.changeDirectory('/')) throw AgentError(tr('Folder "/" not accessible on {host}.', {'host': t.host}));
    } else {
      final home = _home ??= await _client.currentDirectory();
      await _client.changeDirectory(home);
    }
    await _cd(root, create: false);
    if (sub != '.') await _cd(sub, create: true);
    final name = p.posix.basename(rel);
    var last = -10;
    final ok = await _client.uploadFile(local, sRemoteName: name, onProgress: (pct, _, _) {
      if (pct - last >= 10 || pct >= 100) {
        last = pct.round();
        progress('$name: ${pct.round()} %');
      }
    });
    if (!ok) throw AgentError(tr('Upload of {name} refused by {host}.', {'name': name, 'host': t.host}));
  }
}

/// A Windows folder: this PC or a network share (\\192.168.1.10\www\app).
class FolderSender extends Sender {
  FolderSender(this.t);
  final Target t;

  @override
  Future<void> open() async {
    if (!await Directory(t.remotePath).exists()) throw AgentError(tr('Folder not found or not accessible: {path}', {'path': t.remotePath}));
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> send(File local, String rel, Progress progress) async {
    final dest = File(p.normalize(p.join(t.remotePath, rel.replaceAll('/', p.separator))));
    await dest.parent.create(recursive: true);
    await local.copy(dest.path);
    progress('${p.basename(rel)}: ${tr('copied')}');
  }
}

/// The agent is already there (placed by hand): packages go through it, in HTTP chunks.
class AgentSender extends Sender {
  AgentSender(this.t);
  final Target t;

  @override
  bool get canPlaceFiles => false;

  @override
  Future<void> open() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> send(File local, String rel, Progress progress) async =>
      throw AgentError(tr('With "Agent only", the app cannot place files by itself: save the agent to a file and copy it by hand into the project folder of the target.'));

  @override
  Future<void> deliver(AgentClient agent, File local, String name, Progress progress) => agent.upload(local, name, progress);
}
