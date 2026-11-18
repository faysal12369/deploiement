// Talking to the agent (assets/agent/deploy-agent.php) placed in the project folder of a target.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'i18n.dart';
import 'models.dart';

class AgentError implements Exception {
  AgentError(this.message, {this.response});
  final String message;
  final Map<String, dynamic>? response;
  @override
  String toString() => message;
}

typedef Progress = void Function(String text);

class AgentClient {
  AgentClient(this.target);
  final Target target;
  final _http = http.Client();

  void close() => _http.close();

  Uri _uri(String action, [Map<String, String> extra = const {}]) => target.agentUrl.replace(queryParameters: {'a': action, ...extra});

  Map<String, dynamic> _read(http.Response r) {
    Map<String, dynamic>? j;
    try {
      final d = jsonDecode(utf8.decode(r.bodyBytes));
      if (d is Map) j = d.cast<String, dynamic>();
    } catch (_) {}
    if (j == null) {
      final body = utf8.decode(r.bodyBytes, allowMalformed: true).replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (r.statusCode == 404) {
        throw AgentError(tr('No agent at {url} (404): place it first, or check the project address.', {'url': '${target.agentUrl}'}));
      }
      // a page of the site (its login page…) instead of the agent: the address or the folder is not the right one
      if (r.statusCode == 200 && (r.headers['content-type'] ?? '').contains('html')) {
        final title = RegExp(r'<title[^>]*>([^<]*)</title>', caseSensitive: false).firstMatch(utf8.decode(r.bodyBytes, allowMalformed: true))?[1]?.trim() ?? '';
        throw AgentError(tr('{url} answers with a page of the site{title}, not with the agent. Check the address of the project (the folder of the site, without index.php) and the project folder on the server, then place the agent again.',
            {'url': '${target.agentUrl}', 'title': title.isEmpty ? '' : ' "$title"'}));
      }
      throw AgentError(tr('Unexpected answer from the target (HTTP {code}): {body}', {'code': r.statusCode, 'body': body.length > 400 ? '${body.substring(0, 400)}…' : body}));
    }
    if (r.statusCode == 403) {
      throw AgentError(tr('The target refuses the app\'s key: the agent there has another key. Place the agent again.'), response: j);
    }
    return j;
  }

  Future<Map<String, dynamic>> call(String action, [Map<String, dynamic> params = const {}]) async {
    final http.Response r;
    try {
      r = await _http
          .post(_uri(action), headers: {'X-Deploy-Token': target.token, 'Content-Type': 'application/json', 'Connection': 'close'}, body: jsonEncode(params))
          .timeout(const Duration(minutes: 6));
    } on SocketException catch (e) {
      throw AgentError(tr('Cannot reach the target ({url}): {error}', {'url': target.baseUrl, 'error': e.message}));
    } on HandshakeException catch (e) {
      throw AgentError(tr('HTTPS connection refused by {url}: {error}', {'url': target.baseUrl, 'error': e.message}));
    }
    return _read(r);
  }

  /// An action that must succeed.
  Future<Map<String, dynamic>> require(String action, [Map<String, dynamic> params = const {}]) async {
    final j = await call(action, params);
    if (j['ok'] != true) throw AgentError((j['message'] as String?) ?? tr('The action "{action}" failed.', {'action': action}), response: j);
    return j;
  }

  /// A request cut on the way, not refused: the connection closed or timed out. Asked again by [loop].
  static bool cut(Object e) =>
      e is http.ClientException ||
      e is TimeoutException ||
      (e is AgentError && e.response == null && RegExp(r'Cannot reach|injoignable|Connection (closed|reset)', caseSensitive: false).hasMatch(e.message));

  /// A long action, resumed step by step ("state") until "done". A step cut on the way is asked again (5 times at
  /// most): the agent keeps where it is between steps (18/11/2026: "Connection closed before full header was
  /// received" in the middle of 178 000 rows of stock, nothing in the server's logs).
  Future<Map<String, dynamic>> loop(String action, Map<String, dynamic> params, Progress progress) async {
    dynamic state;
    var cuts = 0;
    for (var i = 0; i < 3000; i++) {
      final Map<String, dynamic> j;
      try {
        j = await require(action, {...params, 'state': state});
      } catch (e) {
        if (!cut(e) || ++cuts > 5) rethrow;
        progress(tr('The connection was cut: the step is asked again ({n}/5)…', {'n': cuts}));
        await Future.delayed(Duration(seconds: 5 * cuts));
        continue;
      }
      cuts = 0;
      if (j['done'] == true) return j;
      state = j['state'];
      if (j['progress'] != null) progress('${j['progress']}');
    }
    throw AgentError(tr('The action "{action}" never finishes.', {'action': action}));
  }

  /// Sends a file in 2 MB chunks into the agent's packages folder ("Agent only" targets).
  Future<void> upload(File f, String name, Progress progress) async {
    final total = await f.length();
    final rf = await f.open();
    var off = 0;
    try {
      while (off < total) {
        final chunk = await rf.read(2 * 1024 * 1024);
        final r = await _http
            .post(_uri('upload', {'name': name, 'offset': '$off'}),
                headers: {'X-Deploy-Token': target.token, 'Content-Type': 'application/octet-stream', 'Connection': 'close'}, body: chunk)
            .timeout(const Duration(minutes: 5));
        final j = _read(r);
        if (j['ok'] != true) throw AgentError((j['message'] as String?) ?? tr('Upload refused.'));
        off += chunk.length;
        progress('$name: ${(100 * off / total).round()} %');
      }
    } finally {
      await rf.close();
    }
    await uploadDone(f, name);
  }

  /// End of a transfer by any transport: the agent checks the SHA-256 of "`name`.part" and renames it.
  Future<void> uploadDone(File f, String name) async {
    final h = await sha256.bind(f.openRead()).first;
    await require('upload_done', {'name': name, 'sha256': '$h'});
  }

  /// Brings a backup of the target to this PC (to copy its database to another target).
  Future<void> download(String file, File dest, Progress progress) async {
    final out = dest.openWrite();
    var off = 0;
    int? total;
    try {
      while (total == null || off < total) {
        final r = await _http
            .post(_uri('download'),
                headers: {'X-Deploy-Token': target.token, 'Content-Type': 'application/json'},
                body: jsonEncode({'file': file, 'folder': 'backups', 'offset': off, 'length': 4 * 1024 * 1024}))
            .timeout(const Duration(minutes: 5));
        if (r.statusCode != 200 || r.headers['x-deploy-total'] == null) _read(r);
        total = int.parse(r.headers['x-deploy-total']!);
        if (r.bodyBytes.isEmpty && off < total) throw AgentError(tr('Download interrupted.'));
        out.add(r.bodyBytes);
        off += r.bodyBytes.length;
        progress('$file: ${total == 0 ? 100 : (100 * off / total).round()} %');
      }
    } finally {
      await out.close();
    }
  }
}
