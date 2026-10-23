import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:http/http.dart' as http;

import 'privacy.dart';
import 'storage.dart';

const String sdkVersion = '0.1.1';
const int batchMax = 50;
const int queueMax = 1000;

/// The server refuses events older than a day (validate.ts AGO_MAX).
const int maxAgeMs = 86400000;

/// POSTs a JSON body, returns the HTTP status; throws on a network failure.
typedef VitrusSend = Future<int> Function(Uri url, String body, String userAgent);

Future<int> _httpSend(Uri url, String body, String userAgent) async {
  final res = await http
      .post(url, headers: {'content-type': 'application/json', 'user-agent': userAgent}, body: body)
      .timeout(const Duration(seconds: 20));
  return res.statusCode;
}

class _Queued {
  _Queued(this.payload, this.launch, this.monoMs, this.wallMs);
  final Map<String, Object?> payload;
  final String launch;
  final int monoMs;
  final int wallMs;

  Map<String, Object?> toJson() => {'p': payload, 'l': launch, 'm': monoMs, 'w': wallMs};
  static _Queued fromJson(Map<String, dynamic> j) =>
      _Queued((j['p'] as Map).cast<String, Object?>(), j['l'] as String, j['m'] as int, j['w'] as int);
}

/// Cookie-free, privacy-first analytics for Flutter and Dart apps.
///
/// ```dart
/// await Vitrus.instance.configure(site: 'SITE_ID', storage: FileStorage(dir.path));
/// Vitrus.instance.screen('Invoices');
/// Vitrus.instance.track('invoice_sent', {'items': 3});
/// Vitrus.instance.identify(user.id);   // hashed on device, never sent raw
/// Vitrus.instance.plan('pro');
/// ```
class Vitrus {
  Vitrus({VitrusSend? send, int Function()? wallMs, int Function()? monoMs, Random? random})
      : _send = send ?? _httpSend,
        _wallMs = wallMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        _random = random ?? Random.secure() {
    _monoMs = monoMs ?? (() => _mono.elapsedMilliseconds);
  }

  /// The app-wide instance.
  static final Vitrus instance = Vitrus();

  final VitrusSend _send;
  final int Function() _wallMs;
  final Random _random;
  /// Monotonic: measures how long ago an event happened within this launch.
  final Stopwatch _mono = Stopwatch()..start();
  late final int Function() _monoMs;
  final String _launch = DateTime.now().microsecondsSinceEpoch.toRadixString(36) + Random().nextInt(1 << 30).toRadixString(36);

  String? _site;
  Uri _host = Uri.parse('https://app.vitrus.dev');
  VitrusStorage _storage = MemoryStorage();
  String? _appVersion;
  String? _appName;
  bool _tablet = false;
  String? _identity;
  String? _nonce;
  String? _nonceDay;
  final List<_Queued> _queue = [];
  Future<void>? _inFlight;
  Timer? _timer;

  /// Start Vitrus. Call once at launch; await it so the stored queue is loaded first.
  ///
  /// - [site]: the site id from the dashboard's Install page.
  /// - [host]: your Vitrus server; the cloud by default, your own when self-hosted.
  /// - [storage]: where the daily value and offline queue live between launches.
  /// - [appVersion] / [appName]: shown as the release tag and in the user-agent.
  /// - [isTablet]: Dart cannot tell a phone from a tablet on its own; Flutter can
  ///   (`MediaQuery.sizeOf(context).shortestSide >= 600`).
  Future<void> configure({
    required String site,
    Uri? host,
    VitrusStorage? storage,
    String? appVersion,
    String? appName,
    bool isTablet = false,
    bool trackAppOpen = true,
    Duration flushInterval = const Duration(seconds: 15),
  }) async {
    _site = site;
    if (host != null) _host = host;
    if (storage != null) _storage = storage;
    _appVersion = appVersion;
    _appName = appName;
    _tablet = isTablet;
    final saved = await _storage.read('vitrus.queue.$site');
    if (saved != null) {
      try {
        _queue.insertAll(0, (jsonDecode(saved) as List).map((e) => _Queued.fromJson((e as Map).cast<String, dynamic>())));
      } catch (_) {/* a damaged queue is dropped, never fatal */}
    }
    _nonce = await _storage.read('vitrus.nonce');
    _nonceDay = await _storage.read('vitrus.nonce.day');
    if (trackAppOpen) appOpen();
    _timer?.cancel();
    _timer = Timer.periodic(flushInterval, (_) => flush());
  }

  /// A screen view — the app's page view, reported as `/screen/<name>`.
  void screen(String name, [Map<String, Object?> props = const {}]) {
    final n = name.trim();
    if (n.isEmpty) return;
    _enqueue(_event('pageview', null, '/screen/${Uri.encodeComponent(n)}', props, title: n));
  }

  /// A custom event: what people do in your app (`invoice_sent`, `lesson_created`).
  void track(String name, [Map<String, Object?> props = const {}]) {
    if (!RegExp(r'^[A-Za-z0-9_.:-]{1,80}$').hasMatch(name)) return;
    _enqueue(_event('event', name, '/screen/app', props));
  }

  /// The signed-in user. Hashed on device (`sha256(site + "|" + id)`); pass null on sign-out.
  void identify(String? userId, [Map<String, Object?> traits = const {}]) {
    final raw = (userId ?? '').trim();
    _identity = raw.isEmpty || _site == null ? null : preHash(_site!, raw);
    if (_identity != null && traits.isNotEmpty) _enqueue(_event('event', 'identify', '/screen/app', traits));
  }

  /// The user's plan changed (`free`, `pro`, `cancelled` — your own labels).
  void plan(String plan) => track('plan', {'plan': plan});

  /// A payment: amount in the currency's main unit (dollars, not cents), ISO 4217 code.
  void revenue(num amount, String currency, {String event = 'purchase', Map<String, Object?> props = const {}}) =>
      track(event, {...props, 'revenue': amount, 'currency': currency.toUpperCase()});

  /// The app came to the foreground. Called by [configure]; call it from
  /// `didChangeAppLifecycleState(AppLifecycleState.resumed)`.
  void appOpen() => _enqueue(_event('event', 'app_open', '/screen/app', const {}));

  /// The daily visitor value: random, regenerated when the UTC day changes.
  String nonce() {
    final day = DateTime.fromMillisecondsSinceEpoch(_wallMs(), isUtc: true).toIso8601String().substring(0, 10);
    if (_nonce != null && _nonce!.isNotEmpty && _nonceDay == day) return _nonce!;
    final bytes = List<int>.generate(18, (_) => _random.nextInt(256));
    _nonce = base64Url.encode(bytes).replaceAll('=', '');
    _nonceDay = day;
    unawaited(_storage.write('vitrus.nonce', _nonce!));
    unawaited(_storage.write('vitrus.nonce.day', day));
    return _nonce!;
  }

  Map<String, Object?> _event(String type, String? name, String url, Map<String, Object?> props, {String? title}) {
    final e = <String, Object?>{'site': _site, 'type': type, 'url': url, 'nonce': nonce()};
    if (name != null) e['name'] = name;
    if (title != null) e['title'] = title;
    if (_identity != null) e['identity'] = _identity;
    if (_appVersion != null) e['tag'] = _appVersion!.length > 40 ? _appVersion!.substring(0, 40) : _appVersion;
    final clean = cleanProps(props);
    if (clean.isNotEmpty) e['props'] = clean;
    return e;
  }

  void _enqueue(Map<String, Object?> e) {
    if (_site == null) return;
    _queue.add(_Queued(e, _launch, _monoMs(), _wallMs()));
    if (_queue.length > queueMax) _queue.removeRange(0, _queue.length - queueMax);
    // A full batch goes out at once; anything smaller waits for the timer or flush().
    if (_queue.length >= batchMax && _inFlight == null) unawaited(flush(fullBatchesOnly: true));
  }

  /// How long ago, in ms: the monotonic clock within this launch; the wall clock across launches.
  int ago(Object queued) {
    final q = queued as _Queued;
    final ms = q.launch == _launch ? _monoMs() - q.monoMs : _wallMs() - q.wallMs;
    return ms < 0 ? 0 : ms;
  }

  /// Number of events waiting to be sent.
  int get pending => _queue.length;

  /// Send what is queued now. Call it when the app goes to the background
  /// (`AppLifecycleState.paused`). A call made during a send waits for it.
  Future<void> flush({bool fullBatchesOnly = false}) async {
    if (_inFlight != null) await _inFlight;
    if (_inFlight != null) return _inFlight;
    if (_queue.isEmpty || _site == null) return;
    final f = _drain(fullBatchesOnly).whenComplete(() => _inFlight = null);
    _inFlight = f;
    return f;
  }

  Future<void> _drain(bool fullBatchesOnly) async {
    try {
      _queue.removeWhere((q) => ago(q) > maxAgeMs);
      while (_queue.isNotEmpty && (!fullBatchesOnly || _queue.length >= batchMax)) {
        final chunk = _queue.take(batchMax).toList();
        final events = chunk.map((q) {
          final a = ago(q);
          return a > 0 ? {...q.payload, 'ago': a} : q.payload;
        }).toList();
        int status;
        try {
          status = await _send(_host.resolve('/api/batch'), jsonEncode({'events': events}), userAgent());
        } catch (_) {
          return; // offline: kept for the next flush
        }
        if (status == 200 || (status >= 400 && status < 500 && status != 429)) {
          // 200: sent. A 4xx other than 429 will not get better by retrying — drop it.
          _queue.removeRange(0, min(chunk.length, _queue.length));
        } else {
          return; // 429 / 5xx: kept
        }
      }
    } finally {
      await _persist();
    }
  }

  Future<void> _persist() async {
    if (_site == null) return;
    await _storage.write('vitrus.queue.$_site', jsonEncode(_queue.map((q) => q.toJson()).toList()));
  }

  /// `Vitrus-Dart/0.1.0 (Phone; Android 14) MyApp/2.3` — the server buckets it as an app.
  String userAgent() {
    String os;
    String ver = '';
    try {
      os = Platform.isIOS ? 'iOS' : Platform.isAndroid ? 'Android' : Platform.isMacOS ? 'macOS' : Platform.isWindows ? 'Windows' : Platform.isLinux ? 'Linux' : 'Dart';
      final m = RegExp(r'(\d+(\.\d+)?)').firstMatch(Platform.operatingSystemVersion);
      if (m != null && (Platform.isIOS || Platform.isAndroid || Platform.isMacOS)) ver = ' ${m.group(1)}';
    } catch (_) {
      os = 'Dart';
    }
    final model = _tablet ? 'Tablet' : os == 'iOS' || os == 'Android' ? 'Phone' : 'Desktop';
    final app = (_appName ?? 'App').replaceAll(' ', '');
    return 'Vitrus-Dart/$sdkVersion ($model; $os$ver) $app/${_appVersion ?? '0'}';
  }

  /// Stop the timer (tests, or an app that wants to shut Vitrus down).
  void dispose() => _timer?.cancel();
}
