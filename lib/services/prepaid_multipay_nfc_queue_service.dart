import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_storage_config.dart';

class PrepaidMultipayNfcQueueService {
  const PrepaidMultipayNfcQueueService();

  static const String _legacyQueueKey =
      'prepaid_multipay_nfc_merchant_queue_v1';
  static const String _secureQueueKeyPrefix =
      'prepaid_multipay_nfc_merchant_queue_v2_';
  static const FlutterSecureStorage _secureStorage = appSecureStorage;
  static final Map<String, Future<void>> _tails = {};

  Future<List<Map<String, dynamic>>> getPending(String userId) =>
      _serialized(userId, () => _readUnlocked(userId));

  Future<void> enqueue(String userId, Map<String, dynamic> operation) =>
      _serialized(userId, () async {
        final queue = await _readUnlocked(userId);
        queue.add(Map<String, dynamic>.from(operation));
        await _write(userId, queue);
      });

  Future<void> removeSynced(String userId, Set<String> idempotencyKeys) =>
      _serialized(userId, () async {
        if (idempotencyKeys.isEmpty) return;
        final queue = await _readUnlocked(userId);
        final remaining = queue
            .where(
              (item) =>
                  !idempotencyKeys.contains(item['idempotencyKey']?.toString()),
            )
            .toList();
        if (remaining.length == queue.length) return;
        await _write(userId, remaining);
      });

  Future<List<Map<String, dynamic>>> _readUnlocked(String userId) async {
    final secureKey = _queueKey(userId);
    final current = await _secureStorage.read(key: secureKey);
    if (current != null) {
      return _decode(current);
    }

    // Move old unscoped or user-scoped SharedPreferences data into encrypted
    // platform storage before returning it to the sync code.
    final prefs = await SharedPreferences.getInstance();
    final scopedLegacyKey = userId.trim().isEmpty
        ? _legacyQueueKey
        : '${_legacyQueueKey}_${userId.trim()}';
    final legacyKey = prefs.containsKey(scopedLegacyKey)
        ? scopedLegacyKey
        : (userId.trim().isNotEmpty && prefs.containsKey(_legacyQueueKey)
              ? _legacyQueueKey
              : null);
    if (legacyKey == null) return <Map<String, dynamic>>[];

    final legacy = prefs.getString(legacyKey);
    if (legacy == null || legacy.trim().isEmpty) {
      await prefs.remove(legacyKey);
      return <Map<String, dynamic>>[];
    }

    final decoded = _decode(legacy);
    await _secureStorage.write(key: secureKey, value: jsonEncode(decoded));
    await prefs.remove(legacyKey);
    return decoded;
  }

  Future<void> _write(String userId, List<Map<String, dynamic>> queue) async {
    final key = _queueKey(userId);
    if (queue.isEmpty) {
      await _secureStorage.delete(key: key);
      return;
    }
    await _secureStorage.write(key: key, value: jsonEncode(queue));
  }

  List<Map<String, dynamic>> _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  String _queueKey(String userId) {
    final normalized = userId.trim();
    final scope = normalized.isEmpty
        ? 'unscoped'
        : base64Url.encode(utf8.encode(normalized)).replaceAll('=', '');
    return '$_secureQueueKeyPrefix$scope';
  }

  Future<T> _serialized<T>(
    String userId,
    Future<T> Function() operation,
  ) async {
    final scope = userId.trim().isEmpty ? 'unscoped' : userId.trim();
    final previous = _tails[scope] ?? Future<void>.value();
    final completer = Completer<void>();
    final tail = completer.future;
    _tails[scope] = tail;
    await previous;
    try {
      return await operation();
    } finally {
      completer.complete();
      if (identical(_tails[scope], tail)) {
        _tails.remove(scope);
      }
    }
  }
}
