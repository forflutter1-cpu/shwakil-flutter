import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage_config.dart';

class OfflineTransferCodeService {
  static const FlutterSecureStorage _storage = appSecureStorage;
  static const String _keyPrefix = 'offline_temp_transfer_slots_';

  Future<List<Map<String, dynamic>>> getSlots(String userId) async {
    try {
      final raw = await _storage.read(key: '$_keyPrefix$userId');
      if (raw == null || raw.trim().isEmpty) {
        return [];
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return [];
      }
      final now = DateTime.now().toUtc();
      return decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .where((item) {
            final expiresAt = DateTime.tryParse(
              item['expiresAt']?.toString() ?? '',
            );
            if (expiresAt == null) {
              return false;
            }
            return expiresAt.isAfter(now);
          })
          .toList();
    } on PlatformException {
      return [];
    } catch (_) {
      return [];
    }
  }

  Future<void> replaceSlots(
    String userId,
    List<Map<String, dynamic>> slots,
  ) async {
    try {
      if (slots.isEmpty) {
        await _storage.delete(key: '$_keyPrefix$userId');
        return;
      }
      await _storage.write(key: '$_keyPrefix$userId', value: jsonEncode(slots));
    } on PlatformException {
      return;
    }
  }

  Future<List<Map<String, dynamic>>> mergeSlots(
    String userId,
    List<Map<String, dynamic>> incoming,
  ) async {
    final current = await getSlots(userId);
    final byId = <String, Map<String, dynamic>>{
      for (final slot in current)
        if ((slot['id']?.toString() ?? '').isNotEmpty)
          slot['id'].toString(): slot,
    };
    for (final slot in incoming) {
      final id = slot['id']?.toString() ?? '';
      if (id.isEmpty || byId.containsKey(id)) {
        continue;
      }
      byId[id] = Map<String, dynamic>.from(slot);
    }
    final merged = byId.values.toList()
      ..sort(
        (a, b) => (a['expiresAt']?.toString() ?? '').compareTo(
          b['expiresAt']?.toString() ?? '',
        ),
      );
    await replaceSlots(userId, merged);
    return merged;
  }

  Future<int> countAvailableSlots(String userId) async {
    final slots = await getSlots(userId);
    return slots.length;
  }

  Future<Map<String, dynamic>?> takeNextSlot(String userId) async {
    final slots = await getSlots(userId);
    if (slots.isEmpty) {
      return null;
    }
    final next = slots.removeAt(0);
    await replaceSlots(userId, slots);
    return next;
  }
}
