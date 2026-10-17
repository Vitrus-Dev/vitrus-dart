import 'package:vitrus/vitrus.dart';

/// A plain Dart example. In Flutter, see the README for storage and lifecycle.
Future<void> main() async {
  await Vitrus.instance.configure(site: 'SITE_ID', appVersion: '1.0.0', appName: 'Example');
  Vitrus.instance.screen('Home');
  Vitrus.instance.identify('user-42');
  Vitrus.instance.track('invoice_sent', {'items': 3});
  Vitrus.instance.plan('pro');
  await Vitrus.instance.flush();
  Vitrus.instance.dispose();
}
