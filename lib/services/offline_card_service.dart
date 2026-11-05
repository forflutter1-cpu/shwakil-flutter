import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/index.dart';
import '../localization/app_localization.dart';
import 'secure_storage_config.dart';

class OfflineCardService {
  static const _cardsKeyPrefix = 'offline_cards_cache_';
  static const _redeemKeyPrefix = 'offline_redeem_queue_';
  static const _rejectedKeyPrefix = 'offline_redeem_rejected_';
  static const _historyKeyPrefix = 'offline_redeem_history_';
  static const _unknownCardsKeyPrefix = 'offline_unknown_cards_';
  static const _revealedCardsKeyPrefix = 'offline_revealed_cards_';
  static const _settingsKeyPrefix = 'offline_cards_settings_';
  static const _scanAttemptsKeyPrefix = 'offline_scan_attempts_';
  static const _offlineKeyName = 'offline_cards_aes_key_v1';
  static const double _defaultMaxPendingAmount = 500;
  static const int _defaultMaxPendingCount = 50;
  static const int _defaultSyncIntervalMinutes = 60;
  static const int _revealedCardRetryDelayMinutes = 5;
  static const Uuid _uuid = Uuid();
  static final Map<String, Future<void>> _queueTails = {};
  static final AesGcm _cipher = AesGcm.with256bits();
  static const FlutterSecureStorage _secureStorage = appSecureStorage;

  Future<void> cacheCards({
    required String userId,
    required List<VirtualCard> cards,
    Map<String, dynamic> settings = const {},
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_cardsKeyPrefix$userId';
    final existingCards = await _loadCards(userId);
    final existingByBarcode = <String, VirtualCard>{
      for (final card in existingCards) card.barcode: card,
    };
    final pendingQueue = await getRedeemQueue(userId);
    final pendingBarcodes = {
      for (final item in pendingQueue) (item['barcode']?.toString() ?? ''),
    }..remove('');
    final byBarcode = <String, Map<String, dynamic>>{};
    final offlineScope = settings['offlineScope']?.toString() ?? '';
    final canCacheAllCards = offlineScope == 'all';

    for (final card in cards) {
      final isOwner = (card.ownerId ?? '') == userId;
      final isAllowed = card.allowedUserIds.contains(userId);
      if (!canCacheAllCards && !isOwner && !isAllowed) {
        continue;
      }
      if (!canCacheAllCards &&
          offlineScope == 'private_only' &&
          !card.isPrivate) {
        continue;
      }
      if (!canCacheAllCards &&
          offlineScope == 'driver_private_delivery' &&
          !card.isPrivate &&
          !card.isDelivery) {
        continue;
      }
      final localCard = existingByBarcode[card.barcode];
      final shouldPreserveLocalUsedState =
          localCard != null &&
          (localCard.status == CardStatus.used ||
              pendingBarcodes.contains(card.barcode));
      byBarcode[card.barcode] = shouldPreserveLocalUsedState
          ? localCard
                .copyWith(
                  ownerId: card.ownerId,
                  ownerUsername: card.ownerUsername,
                  issuedById: card.issuedById,
                  issuedByUsername: card.issuedByUsername,
                  allowedUserIds: card.allowedUserIds,
                  allowedUsernames: card.allowedUsernames,
                  value: card.value,
                  issueCost: card.issueCost,
                  visibilityScope: card.visibilityScope,
                  cardType: card.cardType,
                )
                .toMap()
          : card.toMap();
    }

    for (final localCard in existingCards) {
      if (!byBarcode.containsKey(localCard.barcode) &&
          (localCard.status == CardStatus.used ||
              pendingBarcodes.contains(localCard.barcode))) {
        byBarcode[localCard.barcode] = localCard.toMap();
      }
    }

    await prefs.setString(
      key,
      await _encodeStoredList(byBarcode.values.toList()),
    );
    if (settings.isNotEmpty) {
      await prefs.setString(
        '$_settingsKeyPrefix$userId',
        await _encodeStoredObject(settings),
      );
    }
  }

  Future<void> mergeCardsIntoCache({
    required String userId,
    required List<VirtualCard> cards,
  }) async {
    if (cards.isEmpty) {
      return;
    }

    final existingCards = await _loadCards(userId);
    final byBarcode = <String, VirtualCard>{
      for (final card in existingCards) card.barcode: card,
    };

    for (final card in cards) {
      if (card.barcode.trim().isEmpty) {
        continue;
      }
      byBarcode[card.barcode] = card;
    }

    await _storeCards(userId, byBarcode.values.toList());
  }

  Future<VirtualCard?> findCachedCard(String userId, String barcode) async {
    final cards = await _loadCards(userId);
    final match = cards.firstWhere(
      (card) => card.barcode == barcode,
      orElse: () =>
          VirtualCard(id: '', barcode: '', value: 0, createdAt: DateTime.now()),
    );
    return match.barcode.isEmpty ? null : match;
  }

  Future<void> markCardUsed({
    required String userId,
    required String barcode,
    String? customerName,
    String? usedBy,
    DateTime? usedAt,
  }) async {
    final cards = await _loadCards(userId);
    final updated = cards.map((card) {
      if (card.barcode != barcode) {
        return card;
      }
      return card.copyWith(
        status: CardStatus.used,
        customerName: customerName ?? card.customerName,
        usedBy: usedBy ?? card.usedBy,
        usedAt: usedAt ?? DateTime.now(),
      );
    }).toList();
    await _storeCards(userId, updated);
  }

  Future<void> removeCardsByBarcode({
    required String userId,
    required Set<String> barcodes,
  }) async {
    if (barcodes.isEmpty) {
      return;
    }
    final cards = await _loadCards(userId);
    await _storeCards(
      userId,
      cards.where((card) => !barcodes.contains(card.barcode)).toList(),
    );
  }

  Future<void> clearCachedCards(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_cardsKeyPrefix$userId');
  }

  Future<List<Map<String, dynamic>>> getRedeemQueue(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeStoredList(prefs.getString('$_redeemKeyPrefix$userId'));
  }

  Future<List<Map<String, dynamic>>> getRejectedRedeems(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeStoredList(prefs.getString('$_rejectedKeyPrefix$userId'));
  }

  Future<List<Map<String, dynamic>>> getSyncHistory(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeStoredList(prefs.getString('$_historyKeyPrefix$userId'));
  }

  Future<List<Map<String, dynamic>>> getUnknownCardLookups(
    String userId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeStoredList(prefs.getString('$_unknownCardsKeyPrefix$userId'));
  }

  Future<void> replaceUnknownCardLookups(
    String userId,
    List<Map<String, dynamic>> entries,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_unknownCardsKeyPrefix$userId';
    if (entries.isEmpty) {
      await prefs.remove(key);
      return;
    }
    await prefs.setString(key, await _encodeStoredList(entries));
  }

  Future<void> enqueueUnknownCardLookup(
    String userId, {
    required String barcode,
  }) async {
    final existing = await getUnknownCardLookups(userId);
    if (existing.any((item) => item['barcode']?.toString() == barcode)) {
      return;
    }
    existing.add({
      'barcode': barcode,
      'status': 'pending_lookup',
      'queuedAt': DateTime.now().toIso8601String(),
      'message': _tr('services_offline_card_service.pending_lookup'),
    });
    await replaceUnknownCardLookups(userId, existing);
  }

  Future<void> replaceRejectedRedeems(
    String userId,
    List<Map<String, dynamic>> entries,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_rejectedKeyPrefix$userId';
    if (entries.isEmpty) {
      await prefs.remove(key);
      return;
    }
    await prefs.setString(key, await _encodeStoredList(entries));
  }

  Future<void> appendSyncHistory(
    String userId,
    List<Map<String, dynamic>> entries, {
    int maxEntries = 100,
  }) async {
    if (entries.isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final key = '$_historyKeyPrefix$userId';
    final existing = await _decodeStoredList(prefs.getString(key));
    final merged = [...entries, ...existing];
    await prefs.setString(
      key,
      await _encodeStoredList(merged.take(maxEntries).toList()),
    );
  }

  Future<Map<String, dynamic>> pendingRedeemSummary(String userId) async {
    final queue = await getRedeemQueue(userId);
    final rejected = await getRejectedRedeems(userId);
    final amount = queue.fold<double>(
      0,
      (sum, item) => sum + ((item['value'] as num?)?.toDouble() ?? 0),
    );
    return {
      'count': queue.length,
      'amount': amount,
      'rejectedCount': rejected.length,
      'rejected': rejected,
      'items': queue,
    };
  }

  Future<List<VirtualCard>> getCachedCards(String userId) async {
    return _loadCards(userId);
  }

  Future<List<String>> getRevealedCards(String userId) async {
    await _pruneRevealedCards(userId);
    final prefs = await SharedPreferences.getInstance();
    final entries = await _decodeStoredList(
      prefs.getString('$_revealedCardsKeyPrefix$userId'),
    );
    return entries
        .map((item) => item['barcode']?.toString() ?? '')
        .where((value) => value.isNotEmpty)
        .toList();
  }

  Future<bool> isCardRevealed(String userId, String barcode) async {
    final revealed = await getRevealedCards(userId);
    return revealed.contains(barcode);
  }

  Future<void> markCardRevealed(
    String userId,
    String barcode, {
    required bool allowRetryAfterReconnect,
  }) async {
    if (barcode.trim().isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final key = '$_revealedCardsKeyPrefix$userId';
    final entries = await _decodeStoredList(prefs.getString(key));
    final now = DateTime.now();
    final exists = entries.any(
      (item) => item['barcode']?.toString() == barcode,
    );
    if (exists) {
      return;
    }
    entries.add({
      'barcode': barcode.trim(),
      'revealedAt': now.toIso8601String(),
      'retryAllowedAt': allowRetryAfterReconnect
          ? now
                .add(const Duration(minutes: _revealedCardRetryDelayMinutes))
                .toIso8601String()
          : null,
    });
    await prefs.setString(key, await _encodeStoredList(entries));
  }

  Future<void> clearRevealedCards(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_revealedCardsKeyPrefix$userId');
  }

  Future<bool> hasOfflineWorkspace(String userId) async {
    final cards = await getCachedCards(userId);
    if (cards.isNotEmpty) {
      return true;
    }
    final queue = await getRedeemQueue(userId);
    if (queue.isNotEmpty) {
      return true;
    }
    final rejected = await getRejectedRedeems(userId);
    if (rejected.isNotEmpty) {
      return true;
    }
    final unknown = await getUnknownCardLookups(userId);
    return unknown.isNotEmpty;
  }

  Future<void> syncRevealedCards(
    String userId, {
    required Iterable<VirtualCard> currentCards,
    required bool online,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_revealedCardsKeyPrefix$userId';
    final entries = await _decodeStoredList(prefs.getString(key));
    if (entries.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final cardsByBarcode = <String, VirtualCard>{
      for (final card in currentCards) card.barcode: card,
    };
    final updatedEntries = <Map<String, dynamic>>[];

    for (final entry in entries) {
      final barcode = entry['barcode']?.toString().trim() ?? '';
      if (barcode.isEmpty) {
        continue;
      }

      final card = cardsByBarcode[barcode];
      if (card == null || card.status == CardStatus.used) {
        continue;
      }

      final retryAllowedAt = DateTime.tryParse(
        entry['retryAllowedAt']?.toString() ?? '',
      );

      if (online) {
        if (retryAllowedAt != null && !now.isBefore(retryAllowedAt)) {
          continue;
        }

        updatedEntries.add({
          ...entry,
          'retryAllowedAt':
              retryAllowedAt?.toIso8601String() ??
              now
                  .add(const Duration(minutes: _revealedCardRetryDelayMinutes))
                  .toIso8601String(),
        });
        continue;
      }

      updatedEntries.add(entry);
    }

    if (updatedEntries.isEmpty) {
      await prefs.remove(key);
      return;
    }

    await prefs.setString(key, await _encodeStoredList(updatedEntries));
  }

  Future<Map<String, dynamic>> offlineOverview(String userId) async {
    final cards = await getCachedCards(userId);
    final summary = await pendingRedeemSummary(userId);
    final settings = await offlineSettings(userId);
    final history = await getSyncHistory(userId);
    final unknownLookups = await getUnknownCardLookups(userId);
    final availableCards = cards
        .where((card) => card.status != CardStatus.used)
        .length;
    final usedCards = cards.length - availableCards;

    return {
      'cachedCount': cards.length,
      'availableCount': availableCards,
      'usedCount': usedCards,
      'cards': cards,
      'summary': summary,
      'settings': settings,
      'history': history,
      'unknownLookups': unknownLookups,
    };
  }

  Future<Map<String, dynamic>> offlineSettings(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final decoded = await _decodeStoredObject(
      prefs.getString('$_settingsKeyPrefix$userId'),
    );
    return {
      'maxPendingAmount':
          (decoded['maxPendingAmount'] as num?)?.toDouble() ??
          _defaultMaxPendingAmount,
      'maxPendingCount':
          (decoded['maxPendingCount'] as num?)?.toInt() ??
          _defaultMaxPendingCount,
      'syncIntervalMinutes':
          (decoded['syncIntervalMinutes'] as num?)?.toInt() ??
          _defaultSyncIntervalMinutes,
      ...decoded,
    };
  }

  Future<void> updateOfflineSettings(
    String userId,
    Map<String, dynamic> patch,
  ) async {
    if (patch.isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final key = '$_settingsKeyPrefix$userId';
    final current = await offlineSettings(userId);
    current.addAll(patch);
    await prefs.setString(key, await _encodeStoredObject(current));
  }

  Future<void> recordLastSync(
    String userId, {
    DateTime? syncedAt,
    String? source,
  }) async {
    final timestamp = (syncedAt ?? DateTime.now()).toIso8601String();
    await updateOfflineSettings(userId, {
      'lastSyncAt': timestamp,
      if (source != null && source.trim().isNotEmpty)
        'lastSyncSource': source.trim(),
    });
  }

  Future<String?> validateCanQueueRedeem({
    required String userId,
    required double cardValue,
  }) async {
    final settings = await offlineSettings(userId);
    final queue = await getRedeemQueue(userId);
    final pendingAmount = queue.fold<double>(
      0,
      (sum, item) => sum + ((item['value'] as num?)?.toDouble() ?? 0),
    );
    final maxAmount =
        (settings['maxPendingAmount'] as num?)?.toDouble() ??
        _defaultMaxPendingAmount;
    final maxCount =
        (settings['maxPendingCount'] as num?)?.toInt() ??
        _defaultMaxPendingCount;

    if (queue.length >= maxCount) {
      return _tr('services_offline_card_service.max_count_reached');
    }
    if (pendingAmount + cardValue > maxAmount) {
      return _tr('services_offline_card_service.max_amount_reached');
    }

    return null;
  }

  Future<bool> recordUnknownOfflineScan(String userId, String barcode) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_scanAttemptsKeyPrefix$userId';
    final now = DateTime.now();
    final attempts = await _decodeStoredList(prefs.getString(key));
    final recent = attempts.where((item) {
      final at = DateTime.tryParse(item['at']?.toString() ?? '');
      return at != null && now.difference(at).inMinutes < 3;
    }).toList()..add({'barcode': barcode, 'at': now.toIso8601String()});
    await prefs.setString(key, await _encodeStoredList(recent));
    return recent.length >= 8;
  }

  Future<void> clearUnknownOfflineScans(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_scanAttemptsKeyPrefix$userId');
  }

  Future<void> enqueueRedeem(String userId, Map<String, dynamic> entry) async {
    await _withQueueLock(userId, () async {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_redeemKeyPrefix$userId';
      final queue = await _decodeStoredList(prefs.getString(key));
      queue.add({...entry, 'queueId': entry['queueId'] ?? _uuid.v4()});
      await prefs.setString(key, await _encodeStoredList(queue));
    });
  }

  Future<void> acknowledgeRedeems(
    String userId,
    List<Map<String, dynamic>> acknowledged,
  ) async {
    if (acknowledged.isEmpty) return;
    final identities = acknowledged.map(_redeemIdentity).toSet();
    await _withQueueLock(userId, () async {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_redeemKeyPrefix$userId';
      final queue = await _decodeStoredList(prefs.getString(key));
      final remaining = queue
          .where((item) => !identities.contains(_redeemIdentity(item)))
          .toList();
      if (remaining.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, await _encodeStoredList(remaining));
      }
    });
  }

  String _redeemIdentity(Map<String, dynamic> item) {
    final queueId = item['queueId']?.toString();
    if (queueId != null && queueId.isNotEmpty) return queueId;
    return '${item['barcode'] ?? ''}|${item['queuedAt'] ?? ''}';
  }

  Future<T> _withQueueLock<T>(
    String userId,
    Future<T> Function() action,
  ) async {
    final previous = _queueTails[userId] ?? Future<void>.value();
    final gate = Completer<void>();
    _queueTails[userId] = gate.future;
    await previous;
    try {
      return await action();
    } finally {
      gate.complete();
      if (identical(_queueTails[userId], gate.future)) {
        _queueTails.remove(userId);
      }
    }
  }

  Future<void> clearRedeemQueue(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_redeemKeyPrefix$userId');
  }

  Future<void> replaceRedeemQueue(
    String userId,
    List<Map<String, dynamic>> entries,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_redeemKeyPrefix$userId';
    if (entries.isEmpty) {
      await prefs.remove(key);
      return;
    }
    await prefs.setString(key, await _encodeStoredList(entries));
  }

  Future<List<VirtualCard>> _loadCards(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_cardsKeyPrefix$userId';
    final stored = prefs.getString(key);
    final raw = await _decodeStoredList(stored);
    if (stored != null &&
        stored.trim().isNotEmpty &&
        !_isEncryptedPayload(stored)) {
      await prefs.setString(key, await _encodeStoredList(raw));
    }
    return raw.map((item) => VirtualCard.fromMap(item)).toList();
  }

  Future<void> _storeCards(String userId, List<VirtualCard> cards) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_cardsKeyPrefix$userId';
    final payload = cards.map((card) => card.toMap()).toList();
    await prefs.setString(key, await _encodeStoredList(payload));
  }

  Future<void> _pruneRevealedCards(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_revealedCardsKeyPrefix$userId';
    final entries = await _decodeStoredList(prefs.getString(key));
    if (entries.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final filtered = entries.where((entry) {
      final barcode = entry['barcode']?.toString().trim() ?? '';
      if (barcode.isEmpty) {
        return false;
      }

      final retryAllowedAt = DateTime.tryParse(
        entry['retryAllowedAt']?.toString() ?? '',
      );
      if (retryAllowedAt != null && !now.isBefore(retryAllowedAt)) {
        return false;
      }

      return true;
    }).toList();

    if (filtered.length == entries.length) {
      return;
    }

    if (filtered.isEmpty) {
      await prefs.remove(key);
      return;
    }

    await prefs.setString(key, await _encodeStoredList(filtered));
  }

  Future<String> _encodeStoredList(List<Map<String, dynamic>> payload) async {
    return _encodeJsonPayload(payload);
  }

  Future<String> _encodeStoredObject(Map<String, dynamic> payload) async {
    return _encodeJsonPayload(payload);
  }

  Future<String> _encodeJsonPayload(Object payload) async {
    final secretKey = await _getOrCreateSecretKey();
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(payload)),
      secretKey: secretKey,
    );
    return jsonEncode({
      'v': 1,
      'alg': 'AES-256-GCM',
      'nonce': base64Encode(box.nonce),
      'cipherText': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    });
  }

  Future<List<Map<String, dynamic>>> _decodeStoredList(String? raw) async {
    final decoded = await _decodeJsonPayload(raw);
    return _coerceList(decoded);
  }

  Future<Map<String, dynamic>> _decodeStoredObject(String? raw) async {
    final decoded = await _decodeJsonPayload(raw);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
  }

  Future<dynamic> _decodeJsonPayload(String? raw) async {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['v'] == 1) {
        final secretKey = await _getOrCreateSecretKey();
        final clearBytes = await _cipher.decrypt(
          SecretBox(
            base64Decode(decoded['cipherText']?.toString() ?? ''),
            nonce: base64Decode(decoded['nonce']?.toString() ?? ''),
            mac: Mac(base64Decode(decoded['mac']?.toString() ?? '')),
          ),
          secretKey: secretKey,
        );
        return jsonDecode(utf8.decode(clearBytes));
      }
      return decoded;
    } catch (_) {
      return null;
    }
  }

  bool _isEncryptedPayload(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map &&
          decoded['v'] == 1 &&
          decoded['alg'] == 'AES-256-GCM';
    } catch (_) {
      return false;
    }
  }

  Future<SecretKey> _getOrCreateSecretKey() async {
    final existing = await _readSecureValue(_offlineKeyName);
    if (existing != null && existing.isNotEmpty) {
      return SecretKey(base64Decode(existing));
    }
    final key = await _cipher.newSecretKey();
    await _secureStorage.write(
      key: _offlineKeyName,
      value: base64Encode(await key.extractBytes()),
    );
    return key;
  }

  Future<String?> _readSecureValue(String key) async {
    try {
      return await _secureStorage.read(key: key);
    } on PlatformException catch (error) {
      if (_isSecureStorageDecryptError(error)) {
        await _secureStorage.delete(key: key);
        return null;
      }
      rethrow;
    }
  }

  bool _isSecureStorageDecryptError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('badpaddingexception') ||
        message.contains('bad_decrypt') ||
        message.contains('failed to unwrap key') ||
        message.contains('invalidkeyexception');
  }

  String _tr(String key) {
    return AppLocalizer(
      AppLocaleService.instance.locale ?? const Locale('ar'),
    ).tr(key);
  }

  List<Map<String, dynamic>> _coerceList(dynamic decoded) {
    if (decoded is! List) {
      return [];
    }
    return decoded
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }
}
