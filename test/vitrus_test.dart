import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:vitrus/vitrus.dart';

class World {
  final List<Map<String, dynamic>> sent = [];
  final List<String> agents = [];
  int status = 200;
  bool fail = false;
  int wall = 1792231200000; // 2026-10-17 12:00 UTC
  int mono = 1000;
  final storage = MemoryStorage();

  Vitrus client() => Vitrus(
        send: (url, body, ua) async {
          if (fail) throw const SocketException('offline');
          sent.addAll((jsonDecode(body)['events'] as List).cast<Map<String, dynamic>>());
          agents.add(ua);
          return status;
        },
        wallMs: () => wall,
        monoMs: () => mono,
        random: Random(7),
      );
}

Future<Vitrus> start(World w, {bool appOpen = false}) async {
  final v = w.client();
  await v.configure(site: 'site_1', storage: w.storage, appVersion: '2.3.0', appName: 'Tallyhook', trackAppOpen: appOpen, flushInterval: const Duration(hours: 1));
  return v;
}

void main() {
  test('screens and events carry the app version and an app user-agent', () async {
    final w = World();
    final v = await start(w);
    v.screen('Invoices');
    v.track('invoice_sent', {'items': 3, 'paid': true});
    await v.flush();
    expect(w.sent, hasLength(2));
    expect(w.sent[0]['type'], 'pageview');
    expect(w.sent[0]['url'], '/screen/Invoices');
    expect(w.sent[0]['tag'], '2.3.0');
    expect(w.sent[1]['props'], {'items': 3, 'paid': true});
    expect(w.agents.single, startsWith('Vitrus-Dart/$sdkVersion ('));
    expect(w.agents.single, endsWith('Tallyhook/2.3.0'));
    expect(v.pending, 0);
    v.dispose();
  });

  test('identify is hashed on the device, matching the browser and Swift', () async {
    final w = World();
    final v = await start(w);
    v.identify('ayse@example.com', {'plan': 'pro', 'email': 'ayse@example.com'});
    v.screen('Home');
    await v.flush();
    final expected = sha256.convert(utf8.encode('site_1|ayse@example.com')).toString();
    expect(preHash('site_1', 'ayse@example.com'), expected);
    for (final e in w.sent) {
      expect(e['identity'], expected);
    }
    expect(jsonEncode(w.sent), isNot(contains('ayse')));
    expect(w.sent[0]['props'], {'plan': 'pro'});
    v.dispose();
  });

  test('personal properties are dropped, nested values refused', () {
    expect(cleanProps({'Email': 'a@b.co', 'phone_number': 'x', 'contact': '+90 532 111 22 33', 'note': 'a@b.co', 'plan': 'pro', 'seats': 3, 'nested': {'a': 1}}),
        {'plan': 'pro', 'seats': 3});
  });

  test('ago uses the monotonic clock within a launch, not the wall clock', () async {
    final w = World();
    final v = await start(w);
    v.track('offline_thing');
    w.mono += 90000;
    w.wall += 5000000;
    await v.flush();
    expect(w.sent.single['ago'], 90000);
    v.dispose();
  });

  test('an event queued in an earlier launch is sent with a wall-clock age', () async {
    final w = World();
    w.fail = true;
    final first = await start(w);
    first.track('before_restart');
    await first.flush(); // offline: persisted
    first.dispose();
    w.fail = false;
    w.wall += 60000;
    final second = await start(w);
    await second.flush();
    expect(w.sent.single['name'], 'before_restart');
    expect(w.sent.single['ago'], 60000);
    second.dispose();
  });

  test('the daily value is random, kept for the day, and rotates at UTC midnight', () async {
    final w = World();
    final v = await start(w);
    final a = v.nonce();
    expect(v.nonce(), a);
    expect(RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(a), isTrue);
    w.wall += 86400000;
    expect(v.nonce(), isNot(a));
    v.dispose();
  });

  test('batches of fifty; offline and 5xx kept; 4xx dropped', () async {
    final w = World();
    final v = await start(w);
    for (var i = 0; i < 120; i++) {
      v.track('e$i');
    }
    await v.flush();
    expect(w.sent, hasLength(120));
    expect(w.agents, hasLength(3));
    w.sent.clear();
    w.fail = true;
    v.track('kept');
    await v.flush();
    expect(v.pending, 1);
    w.fail = false;
    w.status = 503;
    await v.flush();
    expect(v.pending, 1);
    w.status = 400;
    await v.flush();
    expect(v.pending, 0);
    v.dispose();
  });

  test('events older than a day are dropped, not sent; bad names ignored', () async {
    final w = World();
    final v = await start(w);
    v.track('ancient');
    v.track('has spaces');
    w.mono += 86400001;
    await v.flush();
    expect(w.sent, isEmpty);
    expect(v.pending, 0);
    v.dispose();
  });

  test('FileStorage keeps the queue across instances', () async {
    final dir = await Directory.systemTemp.createTemp('vitrus');
    final s = FileStorage(dir.path);
    await s.write('k', 'v');
    expect(await FileStorage(dir.path).read('k'), 'v');
    await dir.delete(recursive: true);
  });

  test('live server (VITRUS_E2E_HOST + VITRUS_E2E_SITE)', () async {
    final host = Platform.environment['VITRUS_E2E_HOST'];
    final site = Platform.environment['VITRUS_E2E_SITE'];
    if (host == null || site == null) {
      markTestSkipped('set VITRUS_E2E_HOST and VITRUS_E2E_SITE');
      return;
    }
    final v = Vitrus();
    await v.configure(site: site, host: Uri.parse(host), appVersion: '0.1.0-dart-e2e', appName: 'DartE2E', isTablet: true);
    v.identify('dart-e2e-1', {'plan': 'free'});
    v.screen('E2E');
    v.track('e2e_action');
    await v.flush();
    expect(v.pending, 0);
    v.dispose();
  });
}
