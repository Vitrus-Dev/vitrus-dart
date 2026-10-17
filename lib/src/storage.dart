import 'dart:convert';
import 'dart:io';

/// Where the SDK keeps two small things between launches: the daily visitor
/// value and the offline queue. In Flutter, back it with shared_preferences or
/// a file in the app's support directory (see the README).
abstract class VitrusStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// Nothing survives a restart: the daily value is regenerated each launch
/// (a person who opens the app twice in a day counts twice) and unsent events
/// are lost. Fine for tests; use a persistent one in an app.
class MemoryStorage implements VitrusStorage {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
}

/// One JSON file in a directory you choose (Flutter: getApplicationSupportDirectory()).
class FileStorage implements VitrusStorage {
  FileStorage(String directory) : _file = File('$directory${Platform.pathSeparator}vitrus.json');
  final File _file;
  Map<String, dynamic>? _cache;

  Future<Map<String, dynamic>> _load() async {
    if (_cache != null) return _cache!;
    try {
      _cache = (jsonDecode(await _file.readAsString()) as Map).cast<String, dynamic>();
    } catch (_) {
      _cache = {};
    }
    return _cache!;
  }

  @override
  Future<String?> read(String key) async => (await _load())[key] as String?;

  @override
  Future<void> write(String key, String value) async {
    final m = await _load();
    m[key] = value;
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode(m), flush: true);
  }
}
