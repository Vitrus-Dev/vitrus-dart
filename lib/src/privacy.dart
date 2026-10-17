import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Personal data never leaves the device in a property: keys that name it and
/// values shaped like an email or an international phone number are dropped.
/// The same list the server applies again (core/pii.ts).
final RegExp _personalKey = RegExp(
  r'^(e?mail|emailaddress|(user|customer)email|phone(number)?|mobile(phone)?|tel(ephone)?|gsm|(first|last|full|given|family|display|real|sur)name|((street|home|billing|shipping)?address)|street|pass(wd|word)?|pwd|((access|refresh|id|auth|session)?token)|secret|api(key|secret)|((user|client)?ip(address)?)|dob|dateofbirth|birth(date|day)|card(number)?|creditcard|ccnumber|cv[vc]|iban|ssn|tckn|tckimlik(no)?|nationalid|passport(number)?|taxid)$',
  caseSensitive: false,
);
final RegExp _personalValue = RegExp(r'^\s*([^\s@]+@[^\s@]+\.[a-z]{2,}|\+[\d\s().-]{8,22})\s*$', caseSensitive: false);

bool isPersonalKey(String key) => _personalKey.hasMatch(key.replaceAll(RegExp(r'[\s_.-]'), ''));

bool isPersonalValue(Object? value) => value is String && _personalValue.hasMatch(value);

/// Scalars only (the server refuses nested values), personal fields removed.
Map<String, Object?> cleanProps(Map<String, Object?> props) {
  final out = <String, Object?>{};
  props.forEach((k, v) {
    if (isPersonalKey(k) || isPersonalValue(v)) return;
    if (v == null || v is String || v is num || v is bool) out[k] = v;
  });
  return out;
}

/// `sha256(site + "|" + id)`, lower-case hex — what the browser tracker and the
/// Swift SDK send, so one person on web and in the app is one person. The raw
/// id never leaves the device.
String preHash(String site, String id) => sha256.convert(utf8.encode('$site|$id')).toString();
