// A step of a long action cut on the way (18/11/2026, the stock sent to the server: "Connection closed before full
// header was received" after 48 000 rows, nothing in the server's logs): the same step is asked again, the action
// goes on. A small HTTP server in the test plays the agent and drops the connection of one request.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:deploiement/agent_client.dart';
import 'package:deploiement/i18n.dart';
import 'package:deploiement/models.dart';

void main() {
  language.value = 'en';

  Future<(HttpServer, List<String>)> agent({required Set<int> cutAt, bool refuseAt2 = false}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String>[];
    var n = 0;
    server.listen((req) async {
      n++;
      final body = jsonDecode(await utf8.decodeStream(req)) as Map;
      seen.add('${req.uri.queryParameters['a']} ${jsonEncode(body['state'])} ${req.headers.value('connection')}');
      if (cutAt.contains(n)) {
        final socket = await req.response.detachSocket(writeHeaders: false);
        socket.destroy(); // closed before any header
        return;
      }
      final step = (body['state'] as Map?)?['step'] as int? ?? 0;
      final out = refuseAt2 && step == 1
          ? {'ok': false, 'message': 'Table x: duplicate'}
          : step >= 2
              ? {'ok': true, 'done': true, 'tables': []}
              : {'ok': true, 'done': false, 'state': {'step': step + 1}, 'progress': 'step ${step + 1}'};
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(out));
      await req.response.close();
    });
    return (server, seen);
  }

  Target target(HttpServer s) => Target.create()
    ..name = 'test'
    ..url = 'http://127.0.0.1:${s.port}'
    ..agentName = 'deploy-agent-x.php'
    ..token = 'secret';

  test('a cut step is asked again, then the action goes on', () async {
    final (server, seen) = await agent(cutAt: {2});
    final said = <String>[];
    final a = AgentClient(target(server));
    final j = await a.loop('sync', {'package': 'p.zip'}, said.add);
    a.close();
    await server.close(force: true);
    expect(j['done'], true);
    expect(seen.map((s) => s.split(' ').take(2).join(' ')), ['sync null', 'sync {"step":1}', 'sync {"step":1}', 'sync {"step":2}'],
        reason: 'the cut step is asked again with the same state');
    expect(said, contains('The connection was cut: the step is asked again (1/5)…'));
    expect(seen.every((s) => s.endsWith('close')), true, reason: 'a fresh connection for every request');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('a refusal of the agent is not asked again', () async {
    final (server, seen) = await agent(cutAt: {}, refuseAt2: true);
    final a = AgentClient(target(server));
    final error = await a.loop('sync', {}, (_) {}).then((_) => '', onError: (Object e) => '$e');
    a.close();
    await server.close(force: true);
    expect(error, contains('duplicate'));
    expect(seen, hasLength(2));
  });

  test('always cut: it stops after 5 tries, with the error', () async {
    final (server, seen) = await agent(cutAt: {for (var i = 1; i < 20; i++) i});
    final a = AgentClient(target(server));
    final error = await a.loop('sync', {}, (_) {}).then((_) => '', onError: (Object e) => '$e');
    a.close();
    await server.close(force: true);
    expect(error, isNotEmpty);
    expect(seen, hasLength(6));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
