import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Shared options keep Android secure-storage migrations consistent across
/// authentication, device trust, and offline business data.
const FlutterSecureStorage appSecureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(migrateWithBackup: true),
);
