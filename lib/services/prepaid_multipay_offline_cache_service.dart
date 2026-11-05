import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage_config.dart';

class PrepaidMultipayOfflineCacheService {
  const PrepaidMultipayOfflineCacheService();

  static const String cacheKey = 'prepaid_multipay_cards_offline_cache_v1';
  static const FlutterSecureStorage _secureStorage = appSecureStorage;

  Future<void> save({
    required String ownerUserId,
    required List<Map<String, dynamic>> cards,
    required List<Map<String, dynamic>> payments,
    required bool nfcEnabled,
    required bool canUsePrepaidCards,
    required bool canAcceptPrepaidPayments,
    required bool canUsePrepaidNfc,
  }) async {
    final key = _keyForUser(ownerUserId);
    if (key == null || cards.isEmpty || !canUsePrepaidCards) {
      return;
    }

    await _secureStorage.write(
      key: key,
      value: jsonEncode({
        'ownerUserId': ownerUserId.trim(),
        'cachedAt': DateTime.now().toUtc().toIso8601String(),
        'cards': cards,
        'payments': payments.take(20).toList(),
        'nfcEnabled': nfcEnabled,
        'canUsePrepaidCards': canUsePrepaidCards,
        'canAcceptPrepaidPayments': canAcceptPrepaidPayments,
        'canUsePrepaidNfc': canUsePrepaidNfc,
      }),
    );
  }

  Future<Map<String, dynamic>?> load({required String ownerUserId}) async {
    final key = _keyForUser(ownerUserId);
    if (key == null) {
      return null;
    }
    await _discardUnscopedLegacyCache();
    final raw = await _secureStorage.read(key: key);
    if (raw == null || raw.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      if ((decoded['ownerUserId']?.toString().trim() ?? '') !=
          ownerUserId.trim()) {
        return null;
      }
      final cards = List<Map<String, dynamic>>.from(
        (decoded['cards'] as List? ?? const []).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
      if (cards.isEmpty) {
        return null;
      }
      final payments = List<Map<String, dynamic>>.from(
        (decoded['payments'] as List? ?? const []).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );

      return {
        'cards': cards,
        'payments': payments,
        'nfcEnabled': decoded['nfcEnabled'] == true,
        'canUsePrepaidCards': decoded['canUsePrepaidCards'] == true,
        'canAcceptPrepaidPayments': decoded['canAcceptPrepaidPayments'] == true,
        'canUsePrepaidNfc': decoded['canUsePrepaidNfc'] == true,
        'cachedAt': decoded['cachedAt']?.toString(),
      };
    } catch (_) {
      return null;
    }
  }

  Future<bool> hasCards({required String ownerUserId}) async {
    final cached = await load(ownerUserId: ownerUserId);
    final cards = cached?['cards'];
    return cards is List && cards.isNotEmpty;
  }

  String? _keyForUser(String userId) {
    final normalized = userId.trim();
    if (normalized.isEmpty) {
      return null;
    }
    final encoded = base64Url
        .encode(utf8.encode(normalized))
        .replaceAll('=', '');
    return '$cacheKey:$encoded';
  }

  Future<void> _discardUnscopedLegacyCache() async {
    await _secureStorage.delete(key: cacheKey);
  }
}
