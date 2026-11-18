// FTP sending (17/11/2026, Hostinger): "release-….zip arrived damaged (checksum differs)", and before that
// "semaphore timeout… port = 56230". A small FTP server in this test behaves like a Linux server: in text mode
// (TYPE A, where every FTP server starts) it changes the line ends of what it receives, as Hostinger did to the zip.
// The app must switch to binary (TYPE I) after each connection, and send again on a new connection when the
// transfer port does not answer.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:deploiement/i18n.dart';
import 'package:deploiement/models.dart';
import 'package:deploiement/transport.dart';

/// A tiny passive-mode FTP server: what it received ([files]) and the commands, in order ([commands]).
class FakeFtp {
  late final ServerSocket _control;
  final files = <String, Uint8List>{};
  final commands = <String>[];
  int deadPorts = 0; // the next PASV replies give a port where nobody answers
  int get port => _control.port;

  Future<void> start() async {
    _control = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _control.listen(_session);
  }

  Future<void> stop() => _control.close();

  void _session(Socket c) {
    var type = 'A', cwd = '/';
    ServerSocket? data;
    void say(String s) => c.write('$s\r\n');
    say('220 fake FTP');
    c.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) async {
      final cmd = line.split(' ').first.toUpperCase(), arg = line.length > cmd.length ? line.substring(cmd.length + 1) : '';
      commands.add(cmd == 'PASS' ? 'PASS' : line);
      switch (cmd) {
        case 'USER':
          say('331 password');
        case 'PASS':
          say('230 logged in');
        case 'TYPE':
          type = arg.trim().toUpperCase();
          say('200 type $type');
        case 'PWD':
          say('257 "$cwd"');
        case 'CWD':
          cwd = arg.startsWith('/') ? arg : p.posix.join(cwd, arg);
          say('250 ok');
        case 'MKD':
          say('257 created');
        case 'PASV':
          if (deadPorts > 0) {
            deadPorts--;
            final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
            final dead = s.port;
            await s.close(); // nobody listens there any more: the connection is refused
            say('227 Entering Passive Mode (127,0,0,1,${dead >> 8},${dead & 255})');
            return;
          }
          data = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
          say('227 Entering Passive Mode (127,0,0,1,${data!.port >> 8},${data!.port & 255})');
        case 'STOR':
          final name = p.posix.join(cwd, arg);
          final ds = data!;
          data = null;
          say('150 sending');
          final conn = await ds.first;
          final bytes = BytesBuilder();
          await conn.forEach(bytes.add);
          await ds.close();
          var got = bytes.takeBytes();
          // text mode on a Linux server: CR LF becomes LF, as the zip of 17/11/2026 was changed
          if (type == 'A') got = Uint8List.fromList(latin1.encode(latin1.decode(got).replaceAll('\r\n', '\n')));
          files[name] = got;
          say('226 done');
        case 'QUIT':
          say('221 bye');
          await c.close();
        default:
          say('502 not here');
      }
    }, onError: (_) {});
  }
}

void main() {
  language.value = 'en';
  late FakeFtp ftp;
  late Directory dir;
  setUp(() async {
    ftp = FakeFtp();
    await ftp.start();
    dir = Directory.systemTemp.createTempSync('ftp-binary-test');
  });
  tearDown(() async {
    await ftp.stop();
    dir.deleteSync(recursive: true);
  });

  Target target() => Target.create()
    ..name = 'ftp'
    ..transport = Transport.ftp
    ..host = '127.0.0.1'
    ..port = ftp.port
    ..user = 'u'
    ..pass = 'secret'
    ..remotePath = '/www';

  // bytes of a zip: every value, with CR LF pairs that a text-mode server would change
  final zip = Uint8List.fromList([for (var i = 0; i < 4000; i++) i % 7 == 0 ? 13 : (i % 7 == 1 ? 10 : i % 256)]);

  test('a package goes in binary, byte for byte', () async {
    final f = File(p.join(dir.path, 'release.zip'))..writeAsBytesSync(zip);
    final s = Sender.forTarget(target());
    await s.open();
    await s.send(f, '.deploy/packages/release.zip.part', (_) {});
    await s.close();
    expect(ftp.files['/www/.deploy/packages/release.zip.part'], zip, reason: 'the same bytes as on this PC');
    final typeI = ftp.commands.indexOf('TYPE I'), stor = ftp.commands.indexWhere((c) => c.startsWith('STOR'));
    expect(typeI, isNonNegative, reason: 'binary asked');
    expect(typeI, lessThan(stor), reason: 'before the file is sent');
  });

  test('the transfer port does not answer: sent again on a new connection', () async {
    final f = File(p.join(dir.path, 'release.zip'))..writeAsBytesSync(zip);
    ftp.deadPorts = 1;
    final said = <String>[];
    final s = Sender.forTarget(target());
    await s.open();
    await s.send(f, 'release.zip.part', said.add);
    await s.close();
    expect(said.where((x) => x.contains('new try (2/3)')), hasLength(1), reason: 'the second try is told');
    expect(ftp.files['/www/release.zip.part'], zip, reason: 'binary again on the new connection');
    expect(ftp.commands.where((c) => c == 'TYPE I'), hasLength(2), reason: 'once per connection');
  });

  test('it never gets through: a clear message after 3 tries', () async {
    final f = File(p.join(dir.path, 'release.zip'))..writeAsBytesSync(zip);
    ftp.deadPorts = 3;
    final s = Sender.forTarget(target());
    await s.open();
    String? error;
    try {
      await s.send(f, 'release.zip.part', (_) {});
    } catch (e) {
      error = '$e';
    }
    await s.close();
    expect(error, contains('did not get through (3 tries)'));
    expect(error, contains('a firewall, an antivirus or the network'));
    expect(ftp.files, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
