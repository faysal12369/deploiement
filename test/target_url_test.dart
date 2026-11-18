// The address of a target: a page typed instead of the folder still finds the agent; a page of the site answering
// instead of the agent is explained.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:deploiement/agent_client.dart';
import 'package:deploiement/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('the folder of the project, whatever page was typed', () {
    expect(Target.folderUrl('https://erp.example.com/index.php'), 'https://erp.example.com');
    expect(Target.folderUrl(' https://example.com/app/index.php?page=login#top '), 'https://example.com/app');
    expect(Target.folderUrl('https://example.com/app/'), 'https://example.com/app');
    expect(Target.folderUrl('http://192.168.1.10/shop/home.html'), 'http://192.168.1.10/shop');
    expect(Target.folderUrl('https://example.com'), 'https://example.com');
    expect(Target.folderUrl('https://shop.example.com/v2.1'), 'https://shop.example.com/v2.1');
    final t = Target(id: 'h', name: 'hostinger', url: 'https://erp.example.com/index.php', agentName: 'deploy-agent-abc.php');
    expect('${t.agentUrl}', 'https://erp.example.com/deploy-agent-abc.php');
  });

  test('a page of the site instead of the agent', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) => r.response
      ..headers.contentType = ContentType.html
      ..write('<html><head><title>Connexion | Mon site</title></head><body>Bienvenue</body></html>')
      ..close());
    final t = Target(id: 'x', name: 'x', url: 'http://127.0.0.1:${server.port}/index.php', agentName: 'deploy-agent-abc.php');
    final a = AgentClient(t);
    try {
      await a.call('status');
      fail('should have thrown');
    } on AgentError catch (e) {
      expect(e.message, contains('"Connexion | Mon site"'));
      expect(e.message, contains('without index.php'));
      expect(e.message, contains('http://127.0.0.1:${server.port}/deploy-agent-abc.php'));
    } finally {
      a.close();
      await server.close(force: true);
    }
  });
}
