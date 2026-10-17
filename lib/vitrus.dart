/// Cookie-free, privacy-first analytics for Flutter and Dart apps — the native
/// SDK for Vitrus (https://vitrus.dev). User ids are hashed on the device; no
/// persistent device identifier; no tracking.
library;

export 'src/client.dart' show Vitrus, VitrusSend, sdkVersion, batchMax;
export 'src/privacy.dart' show cleanProps, preHash, isPersonalKey, isPersonalValue;
export 'src/storage.dart' show VitrusStorage, MemoryStorage, FileStorage;
