# Vitrus for Flutter & Dart

[![pub package](https://img.shields.io/pub/v/vitrus.svg)](https://pub.dev/packages/vitrus)
[![publisher](https://img.shields.io/pub/publisher/vitrus.svg)](https://pub.dev/packages/vitrus/publisher)

Cookie-free, privacy-first analytics for Flutter and Dart apps — the native SDK for [Vitrus](https://vitrus.dev),
the open-source analytics where every number opens the query that counted it.

- **Your users' ids never leave the device**: `identify` sends a SHA-256, hashed again on the server.
- **No advertising id, no persistent device id, no tracking.**
- **Offline queue** with batching, and honest timestamps for events sent later.
- Your app shows up next to your website in the same workspace: **Portfolio, Users, Lifecycle**.
- Two dependencies, both from the Dart team: `crypto` and `http`.

## Install

```bash
flutter pub add vitrus      # or: dart pub add vitrus
```

or in `pubspec.yaml`:

```yaml
dependencies:
  vitrus: ^0.1.1
```

## Flutter setup

Keep the daily value and the offline queue between launches, and flush when the app goes to the background:

```dart
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vitrus/vitrus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  await Vitrus.instance.configure(
    site: 'SITE_ID',                 // dashboard → Install
    storage: FileStorage(dir.path),
    appVersion: '2.3.0',             // or from package_info_plus
    appName: 'Tallyhook',
  );
  WidgetsBinding.instance.addObserver(_VitrusLifecycle());
  runApp(const MyApp());
}

class _VitrusLifecycle with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) Vitrus.instance.flush();
    if (state == AppLifecycleState.resumed) Vitrus.instance.appOpen();
  }
}
```

Tablets: pass `isTablet: MediaQuery.sizeOf(context).shortestSide >= 600` to `configure` if you want them counted apart
from phones — Dart alone cannot tell them apart. Self-hosted: `host: Uri.parse('https://analytics.example.com')`.

## Use

```dart
final v = Vitrus.instance;

v.screen('Invoices');                       // a screen view: /screen/Invoices
v.track('invoice_sent', {'items': 3});      // what people do
v.identify(user.id);                        // on every launch while signed in
v.identify(null);                           // on sign-out
v.plan('pro');                              // free · pro · cancelled — your labels
v.revenue(4.99, 'USD');                     // dollars, not cents
```

For screen views from navigation, call `screen` in a `NavigatorObserver.didPush`.

## What is sent

| Sent | Not sent |
|---|---|
| Screen and event names, their properties (personal fields removed) | Your user's raw id, email, name or phone |
| `sha256(site + "\|" + userId)` when you call `identify` | Advertising id, Android id, any persistent device id |
| App version, OS, phone / tablet | Location, contacts, anything from other apps |
| A random value regenerated every UTC day (counts visitors without following anyone) | Timestamps from the device clock within a launch |

Properties whose key names personal data (`email`, `phone`, `first_name`, `address`, `password`, `token`, `ip`, …) and values
shaped like an email address or an international phone number are dropped on the device — and again on the server.

**How times work.** The server's clock is the clock. An event sent later carries how long ago it happened, from a monotonic
stopwatch; only events queued in an earlier launch fall back to the wall clock. Events older than a day are dropped.

**Sending.** Batches of up to 50 to `/api/batch`: when 50 are waiting, every 15 seconds, and on `flush()`. Offline, 429 or
5xx: kept and retried. Any other 4xx: dropped — retrying would not change it.

## Store forms

**Google Play — Data safety:** *App activity → App interactions* (collected, not shared, not processed ephemerally,
purpose: Analytics). If you call `identify`: *Personal info → User IDs* (collected, not shared, purpose: Analytics). Data is
encrypted in transit; Vitrus does not share it with third parties.

**App Store — privacy:** *Product Interaction* (not linked) and, if you call `identify`, *User ID* (linked) — both for
*Analytics*, *not used for tracking*. No App Tracking Transparency prompt is needed: nothing here is tracking in Apple's sense.

## License

Apache-2.0. The server and dashboard: [Vitrus-Dev/vitrus](https://github.com/Vitrus-Dev/vitrus).
