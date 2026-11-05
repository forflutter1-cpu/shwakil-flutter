import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import 'api_service.dart';
import 'secure_storage_config.dart';

class ExternalTransferOfflineService {
  static const FlutterSecureStorage _storage = appSecureStorage;
  static const Uuid _uuid = Uuid();
  static const String _queuePrefix = 'external_transfer_queue_v1_';
  static const String _snapshotPrefix = 'external_transfer_snapshot_v1_';
  static final Map<String, Future<void>> _tails = {};

  String _queueKey(String userId) => '$_queuePrefix$userId';
  String _snapshotKey(String userId, [String scope = '']) =>
      '$_snapshotPrefix$userId${scope.isEmpty ? '' : '_${base64Url.encode(utf8.encode(scope))}'}';

  Future<List<Map<String, dynamic>>> getPending(String userId) async {
    final raw = await _storage.read(key: _queueKey(userId));
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
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

  Future<Map<String, dynamic>?> getSnapshot(
    String userId, {
    String scope = '',
  }) async {
    final raw = await _storage.read(key: _snapshotKey(userId, scope));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSnapshot(
    String userId,
    Map<String, dynamic> snapshot, {
    String scope = '',
  }) async {
    await _storage.write(
      key: _snapshotKey(userId, scope),
      value: jsonEncode(snapshot),
    );
  }

  Future<Map<String, dynamic>> enqueue({
    required String userId,
    required Map<String, dynamic> payload,
    String? clientRef,
  }) async {
    final resolvedClientRef = clientRef?.trim().isNotEmpty == true
        ? clientRef!.trim()
        : _uuid.v4();
    final operation = <String, dynamic>{
      'clientRef': resolvedClientRef,
      'localId': 'local:$resolvedClientRef',
      'payload': <String, dynamic>{...payload, 'clientRef': resolvedClientRef},
      'queuedAt': DateTime.now().toIso8601String(),
      'syncStatus': 'pending',
    };
    await _withLock(userId, () async {
      final queue = await getPending(userId);
      if (queue.any((item) => item['clientRef'] == resolvedClientRef)) return;
      queue.add(operation);
      await _writeQueue(userId, queue);
    });
    return operation;
  }

  Future<int> syncPending({required String userId, required ApiService api}) =>
      _withLock(userId, () => _syncPendingUnlocked(userId: userId, api: api));

  Future<int> _syncPendingUnlocked({
    required String userId,
    required ApiService api,
  }) async {
    final initial = await getPending(userId);
    var synced = 0;
    for (final operation in initial) {
      final clientRef = operation['clientRef']?.toString() ?? '';
      try {
        await api.createExternalTransfer(
          Map<String, dynamic>.from(operation['payload'] as Map),
        );
        final current = await getPending(userId);
        await _writeQueue(
          userId,
          current
              .where((item) => item['clientRef']?.toString() != clientRef)
              .toList(),
        );
        synced++;
      } catch (error) {
        final current = await getPending(userId);
        final index = current.indexWhere(
          (item) => item['clientRef']?.toString() == clientRef,
        );
        if (index >= 0) {
          current[index] = {
            ...current[index],
            'syncStatus': 'failed',
            'lastSyncError': error.toString(),
            'lastSyncAttemptAt': DateTime.now().toIso8601String(),
          };
          await _writeQueue(userId, current);
        }
      }
    }
    return synced;
  }

  Future<void> updatePending({
    required String userId,
    required String clientRef,
    required Map<String, dynamic> payload,
  }) => _withLock(userId, () async {
    final queue = await getPending(userId);
    final index = queue.indexWhere(
      (item) => item['clientRef']?.toString() == clientRef,
    );
    if (index < 0) throw StateError('العملية المحلية غير موجودة.');
    queue[index] = {
      ...queue[index],
      'payload': {...payload, 'clientRef': clientRef},
      'syncStatus': 'pending',
      'lastSyncError': null,
    };
    await _writeQueue(userId, queue);
  });

  Future<void> deletePending({
    required String userId,
    required String clientRef,
  }) => _withLock(userId, () async {
    final queue = await getPending(userId);
    await _writeQueue(
      userId,
      queue
          .where((item) => item['clientRef']?.toString() != clientRef)
          .toList(),
    );
  });

  Future<void> _writeQueue(
    String userId,
    List<Map<String, dynamic>> queue,
  ) async {
    if (queue.isEmpty) {
      await _storage.delete(key: _queueKey(userId));
    } else {
      await _storage.write(key: _queueKey(userId), value: jsonEncode(queue));
    }
  }

  Future<T> _withLock<T>(String userId, Future<T> Function() action) async {
    final previous = _tails[userId] ?? Future<void>.value();
    final gate = Completer<void>();
    _tails[userId] = gate.future;
    await previous;
    try {
      return await action();
    } finally {
      gate.complete();
      if (identical(_tails[userId], gate.future)) _tails.remove(userId);
    }
  }
}
