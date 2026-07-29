import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'api_service.dart';

class StoreManagementService {
  static const _snapshotKeyPrefix = 'store_management_snapshot_';
  static const _confirmedSnapshotKeyPrefix =
      'store_management_confirmed_snapshot_';
  static const _queueKeyPrefix = 'store_management_queue_';
  static const _offlineKeyName = 'store_management_aes_key_v1';
  static final AesGcm _cipher = AesGcm.with256bits();
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static const Uuid _uuid = Uuid();
  static final Map<String, Future<void>> _userLocks = {};

  Future<Map<String, dynamic>> getSnapshot(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final decoded = await _decodeObject(
      prefs.getString('$_snapshotKeyPrefix$userId'),
    );
    return decoded;
  }

  Future<List<Map<String, dynamic>>> getPendingOperations(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeList(prefs.getString('$_queueKeyPrefix$userId'));
  }

  Future<void> removePendingOperation({
    required String userId,
    required String opId,
  }) => _serialized(userId, () async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_queueKeyPrefix$userId';
    final queue = await _decodeList(prefs.getString(key));
    final next = queue
        .where((item) => item['opId']?.toString() != opId)
        .toList();
    if (next.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, await _encode(next));
    }
    await _restoreConfirmedWithPending(userId, next);
  });

  Future<void> clearPendingOperations(String userId) =>
      _serialized(userId, () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('$_queueKeyPrefix$userId');
        await _restoreConfirmedWithPending(userId, const []);
      });

  Future<Map<String, dynamic>> refresh({
    required String userId,
    required ApiService api,
  }) => _serialized(userId, () => _refreshUnlocked(userId: userId, api: api));

  Future<Map<String, dynamic>> _refreshUnlocked({
    required String userId,
    required ApiService api,
  }) async {
    final snapshot = await api.getStoreManagementSnapshot();
    final confirmed = await _preserveConfirmedMaintenance(userId, snapshot);
    await _storeConfirmedSnapshot(userId, confirmed);
    final pending = await getPendingOperations(userId);
    final composed = _replayPendingOperations(confirmed, pending);
    await _storeSnapshot(userId, composed);
    return composed;
  }

  Future<Map<String, dynamic>> getMaintenanceSnapshot(String userId) async =>
      Map<String, dynamic>.from(
        (await getSnapshot(userId))['maintenance'] as Map? ?? const {},
      );

  Future<void> cacheMaintenanceSnapshot(
    String userId,
    Map<String, dynamic> data,
  ) => _serialized(userId, () async {
    final snapshot = await getSnapshot(userId);
    await _storeSnapshot(userId, {...snapshot, 'maintenance': data});
    final confirmed = await _getConfirmedSnapshot(userId);
    await _storeConfirmedSnapshot(userId, {...confirmed, 'maintenance': data});
  });

  Future<void> queueMaintenance({
    required String userId,
    required String action,
    String? orderId,
    String? orderClientRef,
    String? partId,
    String? partClientRef,
    Map<String, dynamic> data = const {},
  }) async {
    final clientRef = data['clientRef']?.toString().trim().isNotEmpty == true
        ? data['clientRef'].toString()
        : _uuid.v4();
    if (action == 'add_part') {
      await _validateMaintenanceStock(userId, data);
    }
    await _validateMaintenanceOperation(
      userId: userId,
      action: action,
      orderId: orderId,
      orderClientRef: orderClientRef,
      data: data,
    );
    await _enqueueAndApply(userId, {
      'opId': _uuid.v4(),
      'entity': 'maintenance',
      'action': action,
      'clientRef': clientRef,
      'orderId': ?orderId,
      'orderClientRef': ?orderClientRef,
      'partId': ?partId,
      'partClientRef': ?partClientRef,
      'createdAt': DateTime.now().toIso8601String(),
      ...data,
    });
  }

  Future<void> _validateMaintenanceOperation({
    required String userId,
    required String action,
    String? orderId,
    String? orderClientRef,
    required Map<String, dynamic> data,
  }) async {
    if (action == 'create' || action == 'contact') return;
    final maintenance = await getMaintenanceSnapshot(userId);
    final order = _list(maintenance['orders']).firstWhere(
      (item) =>
          item['id']?.toString() == orderId ||
          (orderClientRef != null &&
              item['clientRef']?.toString() == orderClientRef),
      orElse: () => const {},
    );
    if (order.isEmpty) {
      throw StateError('طلب الصيانة غير موجود في البيانات المحلية.');
    }
    if (['add_part', 'remove_part'].contains(action) &&
        order['invoiceId'] != null) {
      throw StateError('لا يمكن تعديل قطع الصيانة بعد إصدار الفاتورة.');
    }
    if (action == 'finalize') {
      if (!['completed', 'delivered'].contains(order['status'])) {
        throw StateError('يجب إكمال الصيانة قبل إنشاء الفاتورة.');
      }
      if (((order['total'] as num?)?.toDouble() ?? 0) <= 0) {
        throw StateError('يجب أن يكون إجمالي الصيانة أكبر من صفر.');
      }
      if (order['invoiceId'] != null) {
        throw StateError('فاتورة الصيانة منشأة مسبقًا.');
      }
      if (((order['paidAmount'] as num?)?.toDouble() ?? 0) >
          ((order['total'] as num?)?.toDouble() ?? 0)) {
        throw StateError('المبلغ المدفوع لا يمكن أن يتجاوز إجمالي الصيانة.');
      }
    }
    if (action == 'update') {
      final from = order['status']?.toString() ?? 'received';
      final to = data['status']?.toString() ?? from;
      final transitions = Map<String, dynamic>.from(
        maintenance['statusTransitions'] as Map? ?? const {},
      );
      final allowed = transitions[from] is List
          ? List<String>.from(transitions[from] as List)
          : const <String>[];
      if (to != from && transitions.isNotEmpty && !allowed.contains(to)) {
        throw StateError('انتقال حالة الصيانة المطلوب غير مسموح.');
      }
      if (to == 'delivered' && order['invoiceId'] == null) {
        throw StateError('يجب إنشاء فاتورة الصيانة قبل تسليم الجهاز.');
      }
      final assignedTo = data.containsKey('assignedToUserId')
          ? data['assignedToUserId']?.toString()
          : Map<String, dynamic>.from(
              order['assignedTo'] as Map? ?? const {},
            )['id']?.toString();
      final diagnosis = data.containsKey('diagnosis')
          ? data['diagnosis']?.toString().trim() ?? ''
          : order['diagnosis']?.toString().trim() ?? '';
      if (['completed', 'delivered'].contains(to)) {
        if (assignedTo == null || assignedTo.isEmpty) {
          throw StateError('يجب تحديد الفني المسؤول قبل إكمال الصيانة.');
        }
        if (diagnosis.isEmpty) {
          throw StateError('يجب تسجيل التشخيص قبل إكمال الصيانة.');
        }
      }
      final partsPrice = (order['partsPrice'] as num?)?.toDouble() ?? 0;
      final labor = data.containsKey('laborPrice')
          ? (data['laborPrice'] as num?)?.toDouble() ?? 0
          : (order['laborPrice'] as num?)?.toDouble() ?? 0;
      final discount = data.containsKey('discount')
          ? (data['discount'] as num?)?.toDouble() ?? 0
          : (order['discount'] as num?)?.toDouble() ?? 0;
      final paid = data.containsKey('paidAmount')
          ? (data['paidAmount'] as num?)?.toDouble() ?? 0
          : (order['paidAmount'] as num?)?.toDouble() ?? 0;
      final gross = partsPrice + labor;
      if (discount < 0 || discount > gross) {
        throw StateError('الخصم لا يمكن أن يتجاوز قيمة القطع وأجرة العمل.');
      }
      if (paid < 0 || paid > gross - discount) {
        throw StateError('المبلغ المدفوع لا يمكن أن يتجاوز إجمالي الصيانة.');
      }
    }
  }

  Future<void> _validateMaintenanceStock(
    String userId,
    Map<String, dynamic> data,
  ) async {
    final maintenance = await getMaintenanceSnapshot(userId);
    final productId = data['productId']?.toString();
    final productClientRef = data['productClientRef']?.toString();
    final warehouseId = data['warehouseId']?.toString();
    final product = _list(maintenance['products']).firstWhere(
      (item) =>
          item['id']?.toString() == productId ||
          (productClientRef != null &&
              item['clientRef']?.toString() == productClientRef),
      orElse: () => const {},
    );
    if (product.isEmpty) {
      throw StateError('تعذر العثور على قطعة الصيانة محليًا.');
    }
    final unitId = data['productUnitId']?.toString();
    final units = _list(product['units']);
    final unit = units.firstWhere(
      (item) => item['id']?.toString() == unitId,
      orElse: () => units.isNotEmpty ? units.first : const {},
    );
    final factor =
        (unit['factor'] as num?)?.toDouble() ??
        (unit['factorToBase'] as num?)?.toDouble() ??
        1;
    final requested = ((data['quantity'] as num?)?.toDouble() ?? 0) * factor;
    final stock = _list(product['stocks'])
        .where((item) => item['warehouseId']?.toString() == warehouseId)
        .firstOrNull;
    final available = (stock?['quantity'] as num?)?.toDouble() ?? 0;
    if (requested <= 0) {
      throw StateError('يجب أن تكون كمية قطعة الصيانة أكبر من صفر.');
    }
    if (requested > available + 0.000001) {
      throw StateError(
        'الكمية المطلوبة من ${product['name'] ?? 'القطعة'} غير متوفرة في المخزن المحدد.',
      );
    }
  }

  Future<Map<String, dynamic>> syncPending({
    required String userId,
    required ApiService api,
  }) =>
      _serialized(userId, () => _syncPendingUnlocked(userId: userId, api: api));

  Future<Map<String, dynamic>> _syncPendingUnlocked({
    required String userId,
    required ApiService api,
  }) async {
    final operations = await getPendingOperations(userId);
    if (operations.isEmpty) {
      return _refreshUnlocked(userId: userId, api: api);
    }

    final remaining = operations
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    Map<String, dynamic>? latestSnapshot;
    Object? firstError;

    final syncOperations =
        operations.map((item) => Map<String, dynamic>.from(item)).toList()
          ..sort(_syncPriorityCompare);

    for (final operation in syncOperations) {
      try {
        final snapshot = await api.syncStoreManagement([
          _operationPayload(operation),
        ]);
        latestSnapshot = snapshot;
        final index = remaining.indexWhere(
          (item) => _samePendingOperation(item, operation),
        );
        if (index >= 0) {
          remaining.removeAt(index);
        }
        await _storePendingOperations(userId, remaining);
        Map<String, dynamic> rebaseSource = snapshot;
        if (operation['entity'] == 'maintenance' ||
            remaining.any((item) => item['entity'] == 'maintenance')) {
          final maintenance = await api.getMaintenanceSnapshot();
          rebaseSource = {...snapshot, 'maintenance': maintenance};
        }
        rebaseSource = await _preserveConfirmedMaintenance(
          userId,
          rebaseSource,
        );
        await _storeConfirmedSnapshot(userId, rebaseSource);
        await _storeSnapshot(
          userId,
          _replayPendingOperations(rebaseSource, remaining),
        );
      } catch (error) {
        firstError ??= error;
        final index = remaining.indexWhere(
          (item) => _samePendingOperation(item, operation),
        );
        if (index >= 0) {
          remaining[index] = {
            ...remaining[index],
            'syncStatus': 'failed',
            'lastSyncError': error.toString(),
            'lastSyncAttemptAt': DateTime.now().toIso8601String(),
          };
          await _storePendingOperations(userId, remaining);
        }
      }
    }

    if (remaining.isNotEmpty && firstError != null) {
      throw StoreManagementSyncException(
        'تعذر مزامنة ${remaining.length} عملية. راجع تفاصيل العمليات المعلقة واحذف العملية القديمة أو صحح بياناتها.',
        firstError,
      );
    }

    return latestSnapshot ?? refresh(userId: userId, api: api);
  }

  Map<String, dynamic> _replayPendingOperations(
    Map<String, dynamic> serverSnapshot,
    List<Map<String, dynamic>> pending,
  ) {
    var rebased = Map<String, dynamic>.from(serverSnapshot);
    final ordered =
        pending
            .map((operation) => Map<String, dynamic>.from(operation))
            .toList()
          ..sort(_syncPriorityCompare);
    for (final operation in ordered) {
      rebased = _applyLocalOperation(rebased, operation);
    }
    return rebased;
  }

  Future<Map<String, dynamic>> _getConfirmedSnapshot(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeObject(
      prefs.getString('$_confirmedSnapshotKeyPrefix$userId'),
    );
  }

  Future<void> _storeConfirmedSnapshot(
    String userId,
    Map<String, dynamic> snapshot,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_confirmedSnapshotKeyPrefix$userId',
      await _encode(snapshot),
    );
  }

  Future<Map<String, dynamic>> _preserveConfirmedMaintenance(
    String userId,
    Map<String, dynamic> serverSnapshot,
  ) async {
    final confirmed = await _getConfirmedSnapshot(userId);
    return confirmed['maintenance'] is Map &&
            serverSnapshot['maintenance'] == null
        ? {...serverSnapshot, 'maintenance': confirmed['maintenance']}
        : serverSnapshot;
  }

  Future<void> _restoreConfirmedWithPending(
    String userId,
    List<Map<String, dynamic>> pending,
  ) async {
    final confirmed = await _getConfirmedSnapshot(userId);
    if (confirmed.isEmpty) return;
    await _storeSnapshot(userId, _replayPendingOperations(confirmed, pending));
  }

  Future<void> queueProduct({
    required String userId,
    String? serverId,
    String? clientRef,
    required String name,
    required String baseUnit,
    required double minimumStock,
    required double salePrice,
    required List<Map<String, dynamic>> units,
    bool publicVisible = false,
    bool publicAllowOnlineSale = false,
    double? publicMaxQuantity,
  }) {
    final client = clientRef ?? _uuid.v4();
    final preparedUnits = units.map((unit) {
      return {
        ...unit,
        'clientRef': unit['clientRef']?.toString().trim().isNotEmpty == true
            ? unit['clientRef']
            : _uuid.v4(),
      };
    }).toList();
    return _enqueueAndApply(userId, {
      'opId': _uuid.v4(),
      'entity': 'product',
      'type': 'upsert',
      'serverId': ?serverId,
      'clientRef': client,
      'name': name.trim(),
      'baseUnit': baseUnit,
      'minimumStock': minimumStock,
      'defaultSalePrice': salePrice,
      'publicVisible': publicVisible,
      'publicAllowOnlineSale': publicAllowOnlineSale,
      'publicMaxQuantity': ?publicMaxQuantity,
      'units': preparedUnits,
    });
  }

  Future<void> queueWorkspace({
    required String userId,
    required String name,
    String businessType = 'shop',
    String currency = 'ILS',
    bool publicEnabled = false,
    String publicName = '',
    String publicDescription = '',
    String publicOrderMode = 'manual',
    double publicMinOrderTotal = 0,
  }) {
    return _enqueueAndApply(userId, {
      'opId': _uuid.v4(),
      'entity': 'workspace',
      'type': 'upsert',
      'name': name.trim(),
      'businessType': businessType,
      'currency': currency,
      'publicEnabled': publicEnabled,
      'publicName': publicName.trim(),
      'publicDescription': publicDescription.trim(),
      'publicOrderMode': publicOrderMode,
      'publicMinOrderTotal': publicMinOrderTotal,
    });
  }

  Future<void> queueParty({
    required String userId,
    required String type,
    required String name,
    String phone = '',
    String notes = '',
    String? debtBookCustomerId,
  }) {
    return _enqueueAndApply(userId, {
      'opId': _uuid.v4(),
      'entity': 'party',
      'type': 'upsert',
      'clientRef': _uuid.v4(),
      'debtBookCustomerId': ?debtBookCustomerId,
      'partyType': type,
      'name': name.trim(),
      'phone': phone.trim(),
      'notes': notes.trim(),
    });
  }

  Future<void> queueInvoice({
    required String userId,
    required String invoiceType,
    String? partyId,
    String? partyClientRef,
    String? partyName,
    String? warehouseId,
    String? warehouseClientRef,
    required double paidAmount,
    required String paymentMethod,
    required List<Map<String, dynamic>> items,
    double discount = 0,
    String notes = '',
    bool quickSale = false,
    String? actorUserId,
    String? actorName,
  }) async {
    if (invoiceType == 'sale') {
      await _validateStoreStock(
        userId: userId,
        warehouseId: warehouseId,
        warehouseClientRef: warehouseClientRef,
        items: items,
      );
    }
    await _enqueueAndApply(userId, {
      'opId': _uuid.v4(),
      'entity': 'invoice',
      'type': 'create',
      'clientRef': _uuid.v4(),
      'invoiceType': invoiceType,
      'partyId': ?partyId,
      'partyClientRef': ?partyClientRef,
      'partyName': ?partyName,
      'warehouseId': ?warehouseId,
      'warehouseClientRef': ?warehouseClientRef,
      'paidAmount': paidAmount,
      'paymentMethod': paymentMethod,
      'discount': discount,
      'notes': notes.trim(),
      'quickSale': quickSale,
      'actorUserId': ?actorUserId,
      'actorName': ?actorName,
      'occurredAt': DateTime.now().toIso8601String(),
      'items': items,
    });
  }

  Future<void> queueWarehouse({
    required String userId,
    required String name,
    String code = '',
    String notes = '',
  }) => _enqueueAndApply(userId, {
    'opId': _uuid.v4(),
    'entity': 'warehouse',
    'type': 'upsert',
    'clientRef': _uuid.v4(),
    'name': name.trim(),
    'code': code.trim(),
    'notes': notes.trim(),
  });

  Future<void> queueStockTransfer({
    required String userId,
    required String fromWarehouseId,
    required String toWarehouseId,
    required List<Map<String, dynamic>> items,
    String notes = '',
  }) async {
    final snapshot = await getSnapshot(userId);
    final warehouses = _list(snapshot['warehouses']);
    final fromWarehouse = warehouses
        .where((item) => item['id']?.toString() == fromWarehouseId)
        .firstOrNull;
    final toWarehouse = warehouses
        .where((item) => item['id']?.toString() == toWarehouseId)
        .firstOrNull;
    final products = _list(snapshot['products']);
    final preparedItems = items.map((raw) {
      final item = Map<String, dynamic>.from(raw);
      final product = products
          .where(
            (value) => value['id']?.toString() == item['productId']?.toString(),
          )
          .firstOrNull;
      final unit = _list(product?['units'])
          .where(
            (value) =>
                value['id']?.toString() == item['productUnitId']?.toString(),
          )
          .firstOrNull;
      return {
        ...item,
        'productClientRef': item['productClientRef'] ?? product?['clientRef'],
        'unitClientRef': item['unitClientRef'] ?? unit?['clientRef'],
      };
    }).toList();
    await _validateStoreStock(
      userId: userId,
      warehouseId: fromWarehouseId,
      warehouseClientRef: fromWarehouse?['clientRef']?.toString(),
      items: preparedItems,
    );
    await _enqueueAndApply(userId, {
      'opId': _uuid.v4(),
      'entity': 'transfer',
      'type': 'create',
      'clientRef': _uuid.v4(),
      'fromWarehouseId': fromWarehouseId,
      'fromWarehouseClientRef': fromWarehouse?['clientRef'],
      'toWarehouseId': toWarehouseId,
      'toWarehouseClientRef': toWarehouse?['clientRef'],
      'items': preparedItems,
      'notes': notes.trim(),
      'occurredAt': DateTime.now().toIso8601String(),
    });
  }

  Future<void> queuePayment({
    required String userId,
    String? invoiceId,
    String? invoiceClientRef,
    String? partyId,
    String? partyClientRef,
    required String direction,
    required double amount,
    String method = 'cash',
    String notes = '',
    String? actorUserId,
    String? actorName,
  }) {
    return _enqueueAndApply(userId, {
      'opId': _uuid.v4(),
      'entity': 'payment',
      'type': 'create',
      'clientRef': _uuid.v4(),
      'invoiceId': ?invoiceId,
      'invoiceClientRef': ?invoiceClientRef,
      'partyId': ?partyId,
      'partyClientRef': ?partyClientRef,
      'direction': direction,
      'amount': amount,
      'method': method,
      'notes': notes.trim(),
      'actorUserId': ?actorUserId,
      'actorName': ?actorName,
      'occurredAt': DateTime.now().toIso8601String(),
    });
  }

  Future<void> _storeSnapshot(
    String userId,
    Map<String, dynamic> snapshot,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await _decodeObject(
      prefs.getString('$_snapshotKeyPrefix$userId'),
    );
    final preservedMaintenance = current['maintenance'];
    final stored =
        preservedMaintenance != null && snapshot['maintenance'] == null
        ? {...snapshot, 'maintenance': preservedMaintenance}
        : snapshot;
    await prefs.setString('$_snapshotKeyPrefix$userId', await _encode(stored));
  }

  Future<void> _enqueue(String userId, Map<String, dynamic> operation) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_queueKeyPrefix$userId';
    final queue = await _decodeList(prefs.getString(key));
    queue.add(operation);
    await _storePendingOperations(userId, queue);
  }

  Future<void> _storePendingOperations(
    String userId,
    List<Map<String, dynamic>> operations,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_queueKeyPrefix$userId';
    if (operations.isEmpty) {
      await prefs.remove(key);
      return;
    }
    await prefs.setString(key, await _encode(operations));
  }

  bool _samePendingOperation(
    Map<String, dynamic> queued,
    Map<String, dynamic> candidate,
  ) {
    final queuedOpId = queued['opId']?.toString().trim() ?? '';
    final candidateOpId = candidate['opId']?.toString().trim() ?? '';
    if (queuedOpId.isNotEmpty && candidateOpId.isNotEmpty) {
      return queuedOpId == candidateOpId;
    }
    final queuedClientRef = queued['clientRef']?.toString().trim() ?? '';
    final candidateClientRef = candidate['clientRef']?.toString().trim() ?? '';
    if (queued['entity']?.toString() == candidate['entity']?.toString() &&
        queued['type']?.toString() == candidate['type']?.toString() &&
        queuedClientRef.isNotEmpty &&
        queuedClientRef == candidateClientRef) {
      return true;
    }
    return jsonEncode(_operationPayload(queued)) ==
        jsonEncode(_operationPayload(candidate));
  }

  int _syncPriorityCompare(
    Map<String, dynamic> left,
    Map<String, dynamic> right,
  ) {
    final priority = _syncPriority(left).compareTo(_syncPriority(right));
    if (priority != 0) return priority;
    return _operationCreatedAt(left).compareTo(_operationCreatedAt(right));
  }

  int _syncPriority(Map<String, dynamic> operation) {
    final entity = operation['entity']?.toString() ?? '';
    if (entity == 'workspace') return 0;
    if (entity == 'product') return 1;
    if (entity == 'warehouse') return 2;
    if (entity == 'party') return 3;
    if (entity == 'maintenance' && operation['action'] == 'create') return 4;
    if (entity == 'invoice') {
      return operation['invoiceType']?.toString() == 'purchase' ? 5 : 6;
    }
    if (entity == 'transfer') return 7;
    if (entity == 'maintenance') {
      if (operation['action'] == 'update' &&
          operation['status'] == 'delivered') {
        return 11;
      }
      return operation['action'] == 'finalize' ? 10 : 8;
    }
    if (entity == 'payment') return 9;
    return 9;
  }

  DateTime _operationCreatedAt(Map<String, dynamic> operation) {
    final raw =
        operation['createdAt']?.toString() ??
        operation['occurredAt']?.toString() ??
        '';
    return DateTime.tryParse(raw) ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  Map<String, dynamic> _operationPayload(Map<String, dynamic> operation) {
    return Map<String, dynamic>.from(operation)
      ..remove('syncStatus')
      ..remove('lastSyncError')
      ..remove('lastSyncAttemptAt');
  }

  Future<void> _enqueueAndApply(
    String userId,
    Map<String, dynamic> operation,
  ) => _serialized(userId, () async {
    final snapshot = await getSnapshot(userId);
    final next = _applyLocalOperation(snapshot, operation);
    await _enqueue(userId, operation);
    await _storeSnapshot(userId, next);
  });

  Future<T> _serialized<T>(String userId, Future<T> Function() action) async {
    final previous = _userLocks[userId] ?? Future<void>.value();
    final completer = Completer<void>();
    _userLocks[userId] = completer.future;
    try {
      await previous.catchError((_) {});
      return await action();
    } finally {
      completer.complete();
      if (identical(_userLocks[userId], completer.future)) {
        _userLocks.remove(userId);
      }
    }
  }

  Future<void> _validateStoreStock({
    required String userId,
    required List<Map<String, dynamic>> items,
    String? warehouseId,
    String? warehouseClientRef,
  }) async {
    final snapshot = await getSnapshot(userId);
    final warehouses = _list(snapshot['warehouses']);
    final resolvedWarehouse = warehouses.firstWhere(
      (warehouse) =>
          warehouse['id']?.toString() == warehouseId ||
          (warehouseClientRef != null &&
              warehouse['clientRef']?.toString() == warehouseClientRef),
      orElse: () => warehouses.firstWhere(
        (warehouse) => warehouse['isDefault'] == true,
        orElse: () => warehouses.isNotEmpty ? warehouses.first : const {},
      ),
    );
    final resolvedWarehouseId =
        resolvedWarehouse['id']?.toString() ?? warehouseId;
    final requested = <String, double>{};
    final available = <String, double>{};
    final names = <String, String>{};
    for (final raw in items) {
      final productId = raw['productId']?.toString();
      final productClientRef = raw['productClientRef']?.toString();
      final product = _list(snapshot['products']).firstWhere(
        (item) =>
            item['id']?.toString() == productId ||
            (productClientRef != null &&
                item['clientRef']?.toString() == productClientRef),
        orElse: () => const {},
      );
      if (product.isEmpty) {
        throw StateError('تعذر العثور على الصنف في البيانات المحلية.');
      }
      final unitId =
          raw['productUnitId']?.toString() ?? raw['unitId']?.toString();
      final unitClientRef = raw['unitClientRef']?.toString();
      final units = _list(product['units']);
      final unit = units.firstWhere(
        (item) =>
            item['id']?.toString() == unitId ||
            (unitClientRef != null &&
                item['clientRef']?.toString() == unitClientRef),
        orElse: () => units.isNotEmpty ? units.first : const {},
      );
      final factor = (unit['factorToBase'] as num?)?.toDouble() ?? 1;
      final baseQuantity =
          ((raw['quantity'] as num?)?.toDouble() ?? 0) * factor;
      final key = product['id']?.toString() ?? productClientRef ?? '';
      requested[key] = (requested[key] ?? 0) + baseQuantity;
      names[key] = product['name']?.toString() ?? 'الصنف';
      final stocks = _list(product['warehouseStocks']);
      available[key] =
          (stocks
                      .where(
                        (stock) =>
                            stock['warehouseId']?.toString() ==
                            resolvedWarehouseId,
                      )
                      .firstOrNull?['quantity']
                  as num?)
              ?.toDouble() ??
          0;
    }
    for (final entry in requested.entries) {
      if (entry.value > (available[entry.key] ?? 0) + 0.000001) {
        throw StateError(
          'الكمية المطلوبة من ${names[entry.key]} غير متوفرة في المخزن المحدد.',
        );
      }
    }
  }

  Map<String, dynamic> _applyLocalOperation(
    Map<String, dynamic> snapshot,
    Map<String, dynamic> operation,
  ) {
    final next = Map<String, dynamic>.from(snapshot);
    next['workspace'] ??= {
      'id': 'local:workspace',
      'name': 'المحل',
      'businessType': 'shop',
      'currency': 'ILS',
    };
    next['products'] = _list(next['products']);
    next['warehouses'] = _list(next['warehouses']);
    next['parties'] = _list(next['parties']);
    next['invoices'] = _list(next['invoices']);
    next['payments'] = _list(next['payments']);
    next['debtBookAccounts'] = _list(next['debtBookAccounts']);

    switch (operation['entity']?.toString()) {
      case 'product':
        _applyLocalProduct(next, operation);
        break;
      case 'workspace':
        _applyLocalWorkspace(next, operation);
        break;
      case 'party':
        _applyLocalParty(next, operation);
        break;
      case 'warehouse':
        _applyLocalWarehouse(next, operation);
        break;
      case 'invoice':
        _applyLocalInvoice(next, operation);
        break;
      case 'transfer':
        _applyLocalTransfer(next, operation);
        break;
      case 'payment':
        _applyLocalPayment(next, operation);
        break;
      case 'maintenance':
        _applyLocalMaintenance(next, operation);
        break;
    }

    next['summary'] = _summaryFor(next);
    next['syncedAt'] = snapshot['syncedAt'];
    return next;
  }

  void _applyLocalMaintenance(
    Map<String, dynamic> snapshot,
    Map<String, dynamic> op,
  ) {
    final maintenance = Map<String, dynamic>.from(
      snapshot['maintenance'] as Map? ?? const {},
    );
    final orders = _list(maintenance['orders']);
    final action = op['action']?.toString();
    final actor = {
      'id': op['actorUserId']?.toString() ?? '',
      'name': op['actorName']?.toString() ?? '',
    };
    if (action == 'create') {
      final ref = op['clientRef'].toString();
      orders.insert(0, {
        ...op,
        'id': 'local:$ref',
        'clientRef': ref,
        'orderNumber': 'محلي-${ref.substring(0, 6)}',
        'status': 'received',
        'priority': op['priority'] ?? 'normal',
        'parts': [],
        'logs': [
          {
            'id': 'local:log:$ref',
            'action': 'created',
            'fromStatus': null,
            'toStatus': 'received',
            'note': '',
            'actor': actor,
            'createdAt': op['createdAt'],
          },
        ],
        'contacts': [],
        'receivedBy': actor,
        'partsPrice': 0.0,
        'partsCost': 0.0,
        'laborPrice': 0.0,
        'otherCost': 0.0,
        'discount': 0.0,
        'total': 0.0,
        'paidAmount': 0.0,
        'profit': 0.0,
        'createdAt': op['createdAt'],
        'pendingSync': true,
      });
    } else {
      final index = orders.indexWhere(
        (o) => _matchesRef(
          o,
          id: op['orderId']?.toString(),
          clientRef: op['orderClientRef']?.toString(),
        ),
      );
      if (index >= 0) {
        final order = Map<String, dynamic>.from(orders[index]);
        if (action == 'update') {
          final oldStatus = order['status']?.toString();
          order.addAll(op);
          final employeeId = op['assignedToUserId']?.toString();
          if (employeeId != null && employeeId.isNotEmpty) {
            order['assignedTo'] = _list(maintenance['employees']).firstWhere(
              (employee) => employee['id']?.toString() == employeeId,
              orElse: () => {'id': employeeId, 'name': ''},
            );
          }
          if (op['status'] == 'delivered') order['deliveredBy'] = actor;
          order['logs'] = [
            {
              'id': 'local:log:${op['clientRef']}',
              'action': oldStatus == op['status']
                  ? 'updated'
                  : 'status_changed',
              'fromStatus': oldStatus,
              'toStatus': op['status'],
              'note': op['note'] ?? '',
              'actor': actor,
              'createdAt': op['createdAt'],
            },
            ..._list(order['logs']),
          ];
          _recalculateLocalMaintenanceOrder(order);
          order['pendingSync'] = true;
        } else if (action == 'add_part') {
          final parts = _list(order['parts']);
          final product = _list(maintenance['products'])
              .where((p) => p['id']?.toString() == op['productId']?.toString())
              .firstOrNull;
          final quantity = (op['quantity'] as num?)?.toDouble() ?? 0;
          final price = (op['unitPrice'] as num?)?.toDouble() ?? 0;
          final averageCost =
              (product?['averageCost'] as num?)?.toDouble() ?? 0;
          final available =
              (_list(product?['stocks'])
                          .where(
                            (stock) =>
                                stock['warehouseId']?.toString() ==
                                op['warehouseId']?.toString(),
                          )
                          .firstOrNull?['quantity']
                      as num?)
                  ?.toDouble() ??
              0;
          if (quantity <= 0 || quantity > available + 0.000001) {
            throw StateError('الكمية المطلوبة من قطعة الصيانة غير متوفرة.');
          }
          parts.add({
            'id': 'local:${op['clientRef']}',
            'clientRef': op['clientRef'],
            'productName': product?['name'] ?? '',
            'productId': op['productId'],
            'warehouseId': op['warehouseId'],
            'quantity': quantity,
            'baseQuantity': quantity,
            'unitName': '',
            'unitCost': averageCost,
            'costTotal': _money(quantity * averageCost),
            'priceTotal': quantity * price,
            'pendingSync': true,
          });
          order['parts'] = parts;
          order['partsPrice'] = parts.fold<double>(
            0,
            (s, p) => s + ((p['priceTotal'] as num?)?.toDouble() ?? 0),
          );
          order['total'] =
              ((order['partsPrice'] as num?)?.toDouble() ?? 0) +
              ((order['laborPrice'] as num?)?.toDouble() ?? 0) -
              ((order['discount'] as num?)?.toDouble() ?? 0);
          _recalculateLocalMaintenanceOrder(order);
          _adjustMaintenanceStock(
            maintenance,
            snapshot,
            op['productId']?.toString(),
            op['warehouseId']?.toString(),
            -quantity,
          );
        } else if (action == 'remove_part') {
          final oldParts = _list(order['parts']);
          final removed = oldParts
              .where(
                (p) => _matchesRef(
                  p,
                  id: op['partId']?.toString(),
                  clientRef: op['partClientRef']?.toString(),
                ),
              )
              .firstOrNull;
          order['parts'] = oldParts
              .where(
                (p) => !_matchesRef(
                  p,
                  id: op['partId']?.toString(),
                  clientRef: op['partClientRef']?.toString(),
                ),
              )
              .toList();
          if (removed != null) {
            _adjustMaintenanceStock(
              maintenance,
              snapshot,
              removed['productId']?.toString(),
              removed['warehouseId']?.toString(),
              (removed['baseQuantity'] as num?)?.toDouble() ?? 0,
            );
          }
          _recalculateLocalMaintenanceOrder(order);
        } else if (action == 'contact') {
          order['contacts'] = [
            {
              'id': 'local:${op['clientRef']}',
              'method': op['method'] ?? 'call',
              'result': op['result'] ?? 'attempted',
              'note': op['note'] ?? '',
              'actor': actor,
              'createdAt': op['createdAt'],
              'pendingSync': true,
            },
            ..._list(order['contacts']),
          ];
        } else if (action == 'finalize') {
          order['invoiceId'] = 'local:${op['clientRef']}';
          order['pendingSync'] = true;
        }
        orders[index] = order;
      }
    }
    maintenance['orders'] = orders;
    _refreshLocalMaintenanceReports(maintenance);
    snapshot['maintenance'] = maintenance;
  }

  void _recalculateLocalMaintenanceOrder(Map<String, dynamic> order) {
    final parts = _list(order['parts']);
    final partsPrice = parts.fold<double>(
      0,
      (sum, part) => sum + ((part['priceTotal'] as num?)?.toDouble() ?? 0),
    );
    final partsCost = parts.fold<double>(
      0,
      (sum, part) => sum + ((part['costTotal'] as num?)?.toDouble() ?? 0),
    );
    final labor = (order['laborPrice'] as num?)?.toDouble() ?? 0;
    final otherCost = (order['otherCost'] as num?)?.toDouble() ?? 0;
    final discount = (order['discount'] as num?)?.toDouble() ?? 0;
    final paid = (order['paidAmount'] as num?)?.toDouble() ?? 0;
    final total = max(0, partsPrice + labor - discount);
    order['partsPrice'] = _money(partsPrice);
    if (order['partsCost'] != null) order['partsCost'] = _money(partsCost);
    order['total'] = _money(total);
    order['dueAmount'] = _money(max(0, total - paid));
    if (order['profit'] != null) {
      order['profit'] = _money(total - partsCost - otherCost);
    }
  }

  void _refreshLocalMaintenanceReports(Map<String, dynamic> maintenance) {
    final orders = _list(maintenance['orders']);
    final permissions = Map<String, dynamic>.from(
      maintenance['permissions'] as Map? ?? const {},
    );
    final canViewReports = permissions['canViewStoreReports'] == true;
    final canViewProfits = permissions['canViewStoreProfits'] == true;
    final now = DateTime.now();
    bool isWithin(Map<String, dynamic> order, String period) {
      final date = DateTime.tryParse(
        order['createdAt']?.toString() ?? '',
      )?.toLocal();
      if (date == null) return false;
      if (period == 'today') {
        return date.year == now.year &&
            date.month == now.month &&
            date.day == now.day;
      }
      if (period == 'month') {
        return date.year == now.year && date.month == now.month;
      }
      return date.year == now.year;
    }

    Map<String, dynamic> totals(Iterable<Map<String, dynamic>> values) => {
      'count': values.length,
      'revenue': _money(
        values.fold<double>(
          0,
          (sum, order) => sum + ((order['total'] as num?)?.toDouble() ?? 0),
        ),
      ),
      'cost': canViewProfits
          ? _money(
              values.fold<double>(
                0,
                (sum, order) =>
                    sum +
                    ((order['partsCost'] as num?)?.toDouble() ?? 0) +
                    ((order['otherCost'] as num?)?.toDouble() ?? 0),
              ),
            )
          : null,
      'profit': canViewProfits
          ? _money(
              values.fold<double>(
                0,
                (sum, order) =>
                    sum + ((order['profit'] as num?)?.toDouble() ?? 0),
              ),
            )
          : null,
    };
    final operational = {
      'active': orders
          .where(
            (order) => !['delivered', 'cancelled'].contains(order['status']),
          )
          .length,
      'waitingCustomer': orders
          .where((order) => order['status'] == 'waiting_customer')
          .length,
      'completed': orders
          .where((order) => order['status'] == 'completed')
          .length,
    };
    maintenance['summary'] = canViewReports
        ? {
            ...operational,
            'today': totals(orders.where((order) => isWithin(order, 'today'))),
            'month': totals(orders.where((order) => isWithin(order, 'month'))),
            'year': totals(orders.where((order) => isWithin(order, 'year'))),
          }
        : operational;

    if (canViewReports) {
      final grouped = <String, List<Map<String, dynamic>>>{};
      for (final order in orders) {
        final assigned = Map<String, dynamic>.from(
          order['assignedTo'] as Map? ?? const {},
        );
        final id = assigned['id']?.toString() ?? '';
        if (id.isNotEmpty) (grouped[id] ??= []).add(order);
      }
      maintenance['technicianPerformance'] = grouped.values.map((items) {
        final employee = Map<String, dynamic>.from(
          items.first['assignedTo'] as Map? ?? const {},
        );
        return {
          'employee': employee,
          'ordersCount': items.length,
          'activeCount': items
              .where(
                (order) =>
                    !['delivered', 'cancelled'].contains(order['status']),
              )
              .length,
          'completedCount': items
              .where(
                (order) => ['completed', 'delivered'].contains(order['status']),
              )
              .length,
          'revenue': _money(
            items.fold<double>(
              0,
              (sum, order) => sum + ((order['total'] as num?)?.toDouble() ?? 0),
            ),
          ),
          'profit': canViewProfits
              ? _money(
                  items.fold<double>(
                    0,
                    (sum, order) =>
                        sum + ((order['profit'] as num?)?.toDouble() ?? 0),
                  ),
                )
              : null,
        };
      }).toList();
    }
  }

  void _adjustMaintenanceStock(
    Map<String, dynamic> maintenance,
    Map<String, dynamic> store,
    String? productId,
    String? warehouseId,
    double change,
  ) {
    for (final container in [maintenance, store]) {
      final products = _list(container['products']);
      final index = products.indexWhere(
        (p) => p['id']?.toString() == productId,
      );
      if (index < 0) continue;
      final product = Map<String, dynamic>.from(products[index]);
      final stocks = _list(product['stocks']);
      final stockIndex = stocks.indexWhere(
        (s) => s['warehouseId']?.toString() == warehouseId,
      );
      if (stockIndex >= 0) {
        stocks[stockIndex] = {
          ...stocks[stockIndex],
          'quantity':
              ((stocks[stockIndex]['quantity'] as num?)?.toDouble() ?? 0) +
              change,
        };
        product['stocks'] = stocks;
      }
      if (product['stockQuantity'] != null) {
        product['stockQuantity'] =
            ((product['stockQuantity'] as num?)?.toDouble() ?? 0) + change;
      }
      products[index] = product;
      container['products'] = products;
    }
  }

  void _applyLocalProduct(
    Map<String, dynamic> snapshot,
    Map<String, dynamic> operation,
  ) {
    final products = _list(snapshot['products']);
    final clientRef = operation['clientRef']?.toString() ?? _uuid.v4();
    final id = operation['serverId']?.toString().trim().isNotEmpty == true
        ? operation['serverId'].toString()
        : 'local:$clientRef';
    final index = products.indexWhere(
      (item) => _matchesRef(item, id: id, clientRef: clientRef),
    );
    final existing = index >= 0 ? products[index] : const <String, dynamic>{};
    final baseUnit = operation['baseUnit']?.toString() ?? 'piece';
    final product = {
      ...existing,
      'id': existing['id'] ?? id,
      'clientRef': clientRef,
      'syncStatus': 'pending',
      'name': operation['name']?.toString() ?? '',
      'sku': operation['sku'],
      'baseUnit': baseUnit,
      'stockQuantity': (existing['stockQuantity'] as num?)?.toDouble() ?? 0,
      'minimumStock': (operation['minimumStock'] as num?)?.toDouble() ?? 0,
      'averagePurchaseCost':
          (existing['averagePurchaseCost'] as num?)?.toDouble() ?? 0,
      'defaultSalePrice':
          (operation['defaultSalePrice'] as num?)?.toDouble() ?? 0,
      'publicVisible': operation['publicVisible'] == true,
      'publicAllowOnlineSale': operation['publicAllowOnlineSale'] == true,
      'publicMaxQuantity': operation['publicMaxQuantity'],
      'estimatedStockProfit':
          (existing['estimatedStockProfit'] as num?)?.toDouble() ?? 0,
      'isActive': operation['isActive'] ?? true,
      'units': _localUnits(operation['units'], baseUnit),
    };
    if (index >= 0) {
      products[index] = product;
    } else {
      products.add(product);
    }
    snapshot['products'] = products;
  }

  void _applyLocalWorkspace(
    Map<String, dynamic> snapshot,
    Map<String, dynamic> operation,
  ) {
    final existing = snapshot['workspace'] is Map
        ? Map<String, dynamic>.from(snapshot['workspace'] as Map)
        : <String, dynamic>{};
    snapshot['workspace'] = {
      ...existing,
      'id': existing['id'] ?? 'local:workspace',
      'name': operation['name']?.toString() ?? existing['name'] ?? 'المحل',
      'businessType':
          operation['businessType']?.toString() ??
          existing['businessType'] ??
          'shop',
      'currency':
          operation['currency']?.toString() ?? existing['currency'] ?? 'ILS',
      'publicEnabled': operation['publicEnabled'] == true,
      'publicName': operation['publicName']?.toString() ?? '',
      'publicDescription': operation['publicDescription']?.toString() ?? '',
      'publicOrderMode': operation['publicOrderMode']?.toString() ?? 'manual',
      'publicMinOrderTotal':
          (operation['publicMinOrderTotal'] as num?)?.toDouble() ?? 0,
      'syncStatus': 'pending',
    };
  }

  void _applyLocalParty(
    Map<String, dynamic> snapshot,
    Map<String, dynamic> operation,
  ) {
    final parties = _list(snapshot['parties']);
    final clientRef = operation['clientRef']?.toString() ?? _uuid.v4();
    final id = operation['serverId']?.toString().trim().isNotEmpty == true
        ? operation['serverId'].toString()
        : 'local:$clientRef';
    final debtBookCustomerId = operation['debtBookCustomerId']?.toString();
    final debtAccount = _list(snapshot['debtBookAccounts']).firstWhere(
      (item) => item['id']?.toString() == debtBookCustomerId,
      orElse: () => const {},
    );
    final index = parties.indexWhere(
      (item) => _matchesRef(item, id: id, clientRef: clientRef),
    );
    final existing = index >= 0 ? parties[index] : const <String, dynamic>{};
    final party = {
      ...existing,
      'id': existing['id'] ?? id,
      'clientRef': clientRef,
      'debtBookCustomerId': debtBookCustomerId,
      'syncStatus': 'pending',
      'type': operation['partyType'] ?? operation['type'] ?? 'customer',
      'name': operation['name']?.toString().trim().isNotEmpty == true
          ? operation['name'].toString()
          : debtAccount['fullName']?.toString() ?? '',
      'phone': operation['phone']?.toString().trim().isNotEmpty == true
          ? operation['phone'].toString()
          : debtAccount['phone']?.toString() ?? '',
      'notes': operation['notes']?.toString() ?? '',
      'receivableBalance':
          (existing['receivableBalance'] as num?)?.toDouble() ?? 0,
      'payableBalance': (existing['payableBalance'] as num?)?.toDouble() ?? 0,
    };
    if (index >= 0) {
      parties[index] = party;
    } else {
      parties.add(party);
    }
    snapshot['parties'] = parties;
  }

  void _applyLocalInvoice(
    Map<String, dynamic> snapshot,
    Map<String, dynamic> operation,
  ) {
    final invoices = _list(snapshot['invoices']);
    final products = _list(snapshot['products']);
    final parties = _list(snapshot['parties']);
    final warehouses = _list(snapshot['warehouses']);
    final warehouseId =
        operation['warehouseId']?.toString() ??
        warehouses
            .firstWhere(
              (item) => item['isDefault'] == true,
              orElse: () => warehouses.isNotEmpty ? warehouses.first : const {},
            )['id']
            ?.toString();
    final clientRef = operation['clientRef']?.toString() ?? _uuid.v4();
    final id = 'local:$clientRef';
    if (invoices.any(
      (item) => _matchesRef(item, id: id, clientRef: clientRef),
    )) {
      return;
    }
    final invoiceType = operation['invoiceType']?.toString() ?? 'sale';
    final occurredAt =
        operation['occurredAt']?.toString() ?? DateTime.now().toIso8601String();
    final partyId = operation['partyId']?.toString();
    final partyClientRef = operation['partyClientRef']?.toString();
    final party = parties.firstWhere(
      (item) =>
          item['id']?.toString() == partyId ||
          (partyClientRef != null &&
              item['clientRef']?.toString() == partyClientRef),
      orElse: () => const {},
    );
    final preparedItems = <Map<String, dynamic>>[];
    var subtotal = 0.0;
    var costTotal = 0.0;

    for (final raw in _list(operation['items'])) {
      final productId = raw['productId']?.toString();
      final productClientRef = raw['productClientRef']?.toString();
      final productIndex = products.indexWhere(
        (item) =>
            item['id']?.toString() == productId ||
            (productClientRef != null &&
                item['clientRef']?.toString() == productClientRef),
      );
      if (productIndex < 0) continue;
      final product = products[productIndex];
      final units = _list(product['units']);
      final unitId =
          raw['productUnitId']?.toString() ?? raw['unitId']?.toString();
      final unitClientRef = raw['unitClientRef']?.toString();
      final unit = units.firstWhere(
        (item) =>
            item['id']?.toString() == unitId ||
            (unitClientRef != null &&
                item['clientRef']?.toString() == unitClientRef),
        orElse: () => units.isNotEmpty ? units.first : const {},
      );
      final factor = (unit['factorToBase'] as num?)?.toDouble() ?? 1;
      final quantity = (raw['quantity'] as num?)?.toDouble() ?? 0;
      if (quantity <= 0) continue;
      final unitPrice =
          (raw['unitPrice'] as num?)?.toDouble() ??
          (invoiceType == 'sale'
              ? (unit['salePrice'] as num?)?.toDouble() ?? 0
              : (unit['purchasePrice'] as num?)?.toDouble() ?? 0);
      final baseQuantity = quantity * factor;
      final lineTotal = _money(quantity * unitPrice);
      final averageCost =
          (product['averagePurchaseCost'] as num?)?.toDouble() ?? 0;
      final itemCost = invoiceType == 'sale'
          ? _money(baseQuantity * averageCost)
          : lineTotal;
      subtotal += lineTotal;
      costTotal += itemCost;
      final oldStock = (product['stockQuantity'] as num?)?.toDouble() ?? 0;
      final warehouseStocks = _list(product['warehouseStocks']);
      final stockIndex = warehouseStocks.indexWhere(
        (stock) => stock['warehouseId']?.toString() == warehouseId,
      );
      final warehouseAvailable = stockIndex >= 0
          ? (warehouseStocks[stockIndex]['quantity'] as num?)?.toDouble() ?? 0
          : 0;
      if (invoiceType == 'sale' &&
          baseQuantity > warehouseAvailable + 0.000001) {
        throw StateError(
          'الكمية المطلوبة من ${product['name'] ?? 'الصنف'} غير متوفرة في المخزن المحدد.',
        );
      }
      product['stockQuantity'] = _decimal(
        oldStock + (invoiceType == 'purchase' ? baseQuantity : -baseQuantity),
        4,
      );
      if (stockIndex >= 0) {
        final stock = warehouseStocks[stockIndex];
        stock['quantity'] = _decimal(
          ((stock['quantity'] as num?)?.toDouble() ?? 0) +
              (invoiceType == 'purchase' ? baseQuantity : -baseQuantity),
          4,
        );
        warehouseStocks[stockIndex] = stock;
      } else if (warehouseId != null) {
        warehouseStocks.add({
          'warehouseId': warehouseId,
          'quantity': invoiceType == 'purchase' ? baseQuantity : -baseQuantity,
          'minimumStock': product['minimumStock'] ?? 0,
        });
      }
      product['warehouseStocks'] = warehouseStocks;
      product['syncStatus'] = 'pending';
      products[productIndex] = product;
      preparedItems.add({
        'id': 'local:${_uuid.v4()}',
        'productId': product['id'],
        'productUnitId': unit['id'],
        'productName': product['name'],
        'unitName': unit['name'] ?? product['baseUnit'],
        'unitFactor': factor,
        'quantity': quantity,
        'baseQuantity': baseQuantity,
        'unitPrice': unitPrice,
        'lineTotal': lineTotal,
        'costTotal': itemCost,
        'profitTotal': invoiceType == 'sale' ? _money(lineTotal - itemCost) : 0,
      });
    }

    if (preparedItems.isEmpty) return;
    final discount = _money(operation['discount'] ?? 0);
    final total = _money((subtotal - discount).clamp(0, subtotal));
    final paidAmount = _money(
      ((operation['paidAmount'] as num?)?.toDouble() ?? 0).clamp(0, total),
    );
    final dueAmount = _money(total - paidAmount);
    final invoice = {
      'id': id,
      'clientRef': clientRef,
      'syncStatus': 'pending',
      'invoiceNumber': 'محلي-${clientRef.substring(0, 6)}',
      'type': invoiceType,
      'warehouseId': warehouseId,
      'warehouseName':
          warehouses
              .firstWhere(
                (item) => item['id']?.toString() == warehouseId,
                orElse: () => const {},
              )['name']
              ?.toString() ??
          '',
      'partyId': partyId,
      'partyName':
          party['name']?.toString() ??
          operation['partyName']?.toString() ??
          (invoiceType == 'sale' ? 'زبون نقدي' : ''),
      'status': 'posted',
      'paymentStatus': paidAmount <= 0
          ? 'unpaid'
          : paidAmount >= total
          ? 'paid'
          : 'partial',
      'subtotal': _money(subtotal),
      'discount': discount,
      'total': total,
      'paidAmount': paidAmount,
      'dueAmount': dueAmount,
      'costTotal': _money(costTotal),
      'profitTotal': invoiceType == 'sale' ? _money(total - costTotal) : 0,
      'notes': operation['notes']?.toString() ?? '',
      'publicToken': '',
      'shareUrl': '',
      'createdByUserId': operation['actorUserId']?.toString() ?? '',
      'cashierName': operation['actorName']?.toString() ?? '',
      'occurredAt': occurredAt,
      'items': preparedItems,
    };
    invoices.insert(0, invoice);
    snapshot['products'] = products;
    snapshot['invoices'] = invoices;
    final resolvedPartyId = party['id']?.toString() ?? partyId;
    if (resolvedPartyId != null &&
        resolvedPartyId.isNotEmpty &&
        dueAmount > 0) {
      _bumpPartyBalance(parties, resolvedPartyId, invoiceType, dueAmount);
      snapshot['parties'] = parties;
    }
    if (party.isNotEmpty) {
      _bumpDebtAccount(snapshot, party, invoiceType, total, paidAmount);
    }
  }

  void _applyLocalWarehouse(
    Map<String, dynamic> snapshot,
    Map<String, dynamic> operation,
  ) {
    final warehouses = _list(snapshot['warehouses']);
    final clientRef = operation['clientRef']?.toString() ?? _uuid.v4();
    warehouses.add({
      'id': 'local:$clientRef',
      'clientRef': clientRef,
      'name': operation['name']?.toString() ?? '',
      'code': operation['code']?.toString().isNotEmpty == true
          ? operation['code'].toString()
          : 'WH-${clientRef.substring(0, 6).toUpperCase()}',
      'notes': operation['notes']?.toString() ?? '',
      'isDefault': false,
      'isActive': true,
      'syncStatus': 'pending',
    });
    snapshot['warehouses'] = warehouses;
  }

  void _applyLocalTransfer(
    Map<String, dynamic> snapshot,
    Map<String, dynamic> operation,
  ) {
    final products = _list(snapshot['products']);
    final fromId = operation['fromWarehouseId']?.toString();
    final toId = operation['toWarehouseId']?.toString();
    for (final raw in _list(operation['items'])) {
      final productIndex = products.indexWhere(
        (product) => product['id']?.toString() == raw['productId']?.toString(),
      );
      if (productIndex < 0) continue;
      final product = products[productIndex];
      final unit = _list(product['units']).firstWhere(
        (value) => value['id']?.toString() == raw['productUnitId']?.toString(),
        orElse: () => const {},
      );
      final quantity =
          ((raw['quantity'] as num?)?.toDouble() ?? 0) *
          ((unit['factorToBase'] as num?)?.toDouble() ?? 1);
      final stocks = _list(product['warehouseStocks']);
      final sourceStock = stocks
          .where((stock) => stock['warehouseId']?.toString() == fromId)
          .firstOrNull;
      final sourceAvailable =
          (sourceStock?['quantity'] as num?)?.toDouble() ?? 0;
      if (quantity <= 0 || quantity > sourceAvailable + 0.000001) {
        throw StateError(
          'الكمية المطلوبة من ${product['name'] ?? 'الصنف'} غير متوفرة للتحويل.',
        );
      }
      for (final entry in [
        [fromId, -quantity],
        [toId, quantity],
      ]) {
        final index = stocks.indexWhere(
          (stock) => stock['warehouseId']?.toString() == entry[0],
        );
        if (index >= 0) {
          stocks[index]['quantity'] = _decimal(
            ((stocks[index]['quantity'] as num?)?.toDouble() ?? 0) +
                (entry[1] as double),
            4,
          );
        } else if (entry[0] != null) {
          stocks.add({
            'warehouseId': entry[0],
            'quantity': entry[1],
            'minimumStock': product['minimumStock'] ?? 0,
          });
        }
      }
      product['warehouseStocks'] = stocks;
      product['syncStatus'] = 'pending';
      products[productIndex] = product;
    }
    snapshot['products'] = products;
  }

  void _applyLocalPayment(
    Map<String, dynamic> snapshot,
    Map<String, dynamic> operation,
  ) {
    final payments = _list(snapshot['payments']);
    final invoices = _list(snapshot['invoices']);
    final parties = _list(snapshot['parties']);
    final clientRef = operation['clientRef']?.toString() ?? _uuid.v4();
    final id = 'local:$clientRef';
    if (payments.any(
      (item) => _matchesRef(item, id: id, clientRef: clientRef),
    )) {
      return;
    }
    final invoiceId = operation['invoiceId']?.toString();
    final invoiceClientRef = operation['invoiceClientRef']?.toString();
    final invoiceIndex = invoices.indexWhere(
      (item) =>
          item['id']?.toString() == invoiceId ||
          (invoiceClientRef != null &&
              item['clientRef']?.toString() == invoiceClientRef),
    );
    var amount = _money(operation['amount'] ?? 0);
    String? partyId = operation['partyId']?.toString();
    final partyClientRef = operation['partyClientRef']?.toString();
    String direction = operation['direction']?.toString() ?? 'in';
    if (invoiceIndex >= 0) {
      final invoice = invoices[invoiceIndex];
      partyId ??= invoice['partyId']?.toString();
      direction = invoice['type'] == 'purchase' ? 'out' : 'in';
      final total = (invoice['total'] as num?)?.toDouble() ?? 0;
      final oldPaid = (invoice['paidAmount'] as num?)?.toDouble() ?? 0;
      amount = min(amount, max(0, total - oldPaid));
      final paid = _money((oldPaid + amount).clamp(0, total));
      final due = _money(total - paid);
      invoice['paidAmount'] = paid;
      invoice['dueAmount'] = due;
      invoice['paymentStatus'] = paid <= 0
          ? 'unpaid'
          : paid >= total
          ? 'paid'
          : 'partial';
      invoice['syncStatus'] = 'pending';
      invoices[invoiceIndex] = invoice;
    }
    payments.insert(0, {
      'id': id,
      'clientRef': clientRef,
      'syncStatus': 'pending',
      'invoiceId': invoiceId,
      'partyId': partyId,
      'direction': direction,
      'method': operation['method'] ?? 'cash',
      'amount': amount,
      'reference': operation['reference'] ?? '',
      'notes': operation['notes'] ?? '',
      'createdByUserId': operation['actorUserId']?.toString() ?? '',
      'actorName': operation['actorName']?.toString() ?? '',
      'occurredAt':
          operation['occurredAt']?.toString() ??
          DateTime.now().toIso8601String(),
    });
    final partyIndex = parties.indexWhere(
      (item) =>
          item['id']?.toString() == partyId ||
          (partyClientRef != null &&
              item['clientRef']?.toString() == partyClientRef),
    );
    if (partyIndex >= 0) {
      partyId = parties[partyIndex]['id']?.toString() ?? partyId;
      _bumpPartyPayment(parties, partyId ?? '', direction, amount);
      final party = parties.firstWhere(
        (item) =>
            item['id']?.toString() == partyId ||
            (partyClientRef != null &&
                item['clientRef']?.toString() == partyClientRef),
        orElse: () => const {},
      );
      _bumpDebtAccount(
        snapshot,
        party,
        direction == 'out' ? 'purchase' : 'sale',
        0,
        amount,
      );
    }
    snapshot['payments'] = payments;
    snapshot['invoices'] = invoices;
    snapshot['parties'] = parties;
  }

  void _bumpPartyBalance(
    List<Map<String, dynamic>> parties,
    String partyId,
    String invoiceType,
    double dueAmount,
  ) {
    final index = parties.indexWhere(
      (item) => item['id']?.toString() == partyId,
    );
    if (index < 0) return;
    final party = parties[index];
    if (invoiceType == 'purchase') {
      party['payableBalance'] = _money(
        ((party['payableBalance'] as num?)?.toDouble() ?? 0) + dueAmount,
      );
    } else {
      party['receivableBalance'] = _money(
        ((party['receivableBalance'] as num?)?.toDouble() ?? 0) + dueAmount,
      );
    }
    party['syncStatus'] = 'pending';
    parties[index] = party;
  }

  void _bumpPartyPayment(
    List<Map<String, dynamic>> parties,
    String partyId,
    String direction,
    double amount,
  ) {
    final index = parties.indexWhere(
      (item) => item['id']?.toString() == partyId,
    );
    if (index < 0) return;
    final party = parties[index];
    if (direction == 'out') {
      party['payableBalance'] = _money(
        ((party['payableBalance'] as num?)?.toDouble() ?? 0) - amount,
      );
    } else {
      party['receivableBalance'] = _money(
        ((party['receivableBalance'] as num?)?.toDouble() ?? 0) - amount,
      );
    }
    party['syncStatus'] = 'pending';
    parties[index] = party;
  }

  void _bumpDebtAccount(
    Map<String, dynamic> snapshot,
    Map<String, dynamic> party,
    String invoiceType,
    double debt,
    double paid,
  ) {
    final accountId = party['debtBookCustomerId']?.toString();
    if (accountId == null || accountId.isEmpty) return;
    final accounts = _list(snapshot['debtBookAccounts']);
    final index = accounts.indexWhere(
      (item) => item['id']?.toString() == accountId,
    );
    if (index < 0) return;
    final account = accounts[index];
    account['totalDebt'] = _money(
      ((account['totalDebt'] as num?)?.toDouble() ?? 0) + debt,
    );
    account['totalPaid'] = _money(
      ((account['totalPaid'] as num?)?.toDouble() ?? 0) + paid,
    );
    account['balance'] = _money(
      ((account['totalDebt'] as num?)?.toDouble() ?? 0) -
          ((account['totalPaid'] as num?)?.toDouble() ?? 0),
    );
    account['syncStatus'] = 'pending';
    accounts[index] = account;
    snapshot['debtBookAccounts'] = accounts;
  }

  Map<String, dynamic> _summaryFor(Map<String, dynamic> snapshot) {
    final products = _list(snapshot['products']);
    final parties = _list(snapshot['parties']);
    final invoices = _list(snapshot['invoices']);
    final today = DateTime.now();
    final salesToday = invoices.where((invoice) {
      if (invoice['type'] != 'sale') return false;
      final date = DateTime.tryParse(invoice['occurredAt']?.toString() ?? '');
      return date != null &&
          date.year == today.year &&
          date.month == today.month &&
          date.day == today.day;
    });
    return {
      'productsCount': products
          .where((item) => item['isActive'] != false)
          .length,
      'lowStockCount': products.where((item) {
        final min = (item['minimumStock'] as num?)?.toDouble() ?? 0;
        final stock = (item['stockQuantity'] as num?)?.toDouble() ?? 0;
        return min > 0 && stock <= min;
      }).length,
      'inventoryValue': _money(
        products.fold(0.0, (sum, item) {
          return sum +
              (((item['stockQuantity'] as num?)?.toDouble() ?? 0) *
                  ((item['averagePurchaseCost'] as num?)?.toDouble() ?? 0));
        }),
      ),
      'salesToday': _money(
        salesToday.fold(0.0, (sum, item) {
          return sum + ((item['total'] as num?)?.toDouble() ?? 0);
        }),
      ),
      'profitToday': _money(
        salesToday.fold(0.0, (sum, item) {
          return sum + ((item['profitTotal'] as num?)?.toDouble() ?? 0);
        }),
      ),
      'customerDebts': _money(
        parties.fold(0.0, (sum, item) {
          return sum + ((item['receivableBalance'] as num?)?.toDouble() ?? 0);
        }),
      ),
      'supplierDebts': _money(
        parties.fold(0.0, (sum, item) {
          return sum + ((item['payableBalance'] as num?)?.toDouble() ?? 0);
        }),
      ),
    };
  }

  List<Map<String, dynamic>> _localUnits(dynamic raw, String baseUnit) {
    final units = _list(raw);
    if (units.isEmpty) {
      final clientRef = _uuid.v4();
      return [
        {
          'id': 'local:$clientRef',
          'clientRef': clientRef,
          'name': _unitName(baseUnit),
          'code': baseUnit,
          'factorToBase': 1.0,
          'barcode': null,
          'purchasePrice': 0.0,
          'salePrice': 0.0,
          'isBase': true,
        },
      ];
    }
    return units.map((unit) {
      final code = unit['code']?.toString() ?? baseUnit;
      final clientRef = unit['clientRef'] ?? _uuid.v4();
      final factor = (unit['factorToBase'] as num?)?.toDouble() ?? 1;
      return {
        'id': unit['id'] ?? 'local:$clientRef',
        'clientRef': clientRef,
        'name': unit['name'] ?? _unitName(code),
        'code': code,
        'factorToBase': factor,
        'barcode': unit['barcode'],
        'purchasePrice': (unit['purchasePrice'] as num?)?.toDouble() ?? 0,
        'salePrice': (unit['salePrice'] as num?)?.toDouble() ?? 0,
        'isBase': unit['isBase'] == true || factor == 1,
      };
    }).toList();
  }

  bool _matchesRef(Map<String, dynamic> item, {String? id, String? clientRef}) {
    return (id != null && item['id']?.toString() == id) ||
        (clientRef != null && item['clientRef']?.toString() == clientRef);
  }

  List<Map<String, dynamic>> _list(dynamic value) {
    if (value is! List) return [];
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  double _decimal(dynamic value, int precision) {
    final number = value is num
        ? value.toDouble()
        : double.tryParse('$value') ?? 0;
    var factor = 1.0;
    for (var i = 0; i < precision; i += 1) {
      factor *= 10;
    }
    return (number * factor).round() / factor;
  }

  double _money(dynamic value) => _decimal(value, 2);

  String _unitName(String code) => switch (code) {
    'piece' => 'حبة',
    'carton' => 'كرتونة',
    'bag' => 'كيس',
    'pallet' => 'مشطاح',
    'kg' => 'كيلو',
    'liter' => 'لتر',
    'box' => 'صندوق',
    _ => code,
  };

  Future<String> _encode(Object payload) async {
    final secretKey = await _getOrCreateSecretKey();
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(payload)),
      secretKey: secretKey,
    );
    return jsonEncode({
      'v': 1,
      'nonce': base64Encode(box.nonce),
      'cipherText': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    });
  }

  Future<Map<String, dynamic>> _decodeObject(String? raw) async {
    final decoded = await _decode(raw);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
  }

  Future<List<Map<String, dynamic>>> _decodeList(String? raw) async {
    final decoded = await _decode(raw);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<dynamic> _decode(String? raw) async {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['v'] == 1) {
        final clear = await _cipher.decrypt(
          SecretBox(
            base64Decode(decoded['cipherText']?.toString() ?? ''),
            nonce: base64Decode(decoded['nonce']?.toString() ?? ''),
            mac: Mac(base64Decode(decoded['mac']?.toString() ?? '')),
          ),
          secretKey: await _getOrCreateSecretKey(),
        );
        return jsonDecode(utf8.decode(clear));
      }
      return decoded;
    } catch (_) {
      return null;
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
      final message = error.toString().toLowerCase();
      if (message.contains('badpaddingexception') ||
          message.contains('bad_decrypt') ||
          message.contains('failed to unwrap key') ||
          message.contains('invalidkeyexception')) {
        await _secureStorage.delete(key: key);
        return null;
      }
      rethrow;
    }
  }
}

class StoreManagementSyncException implements Exception {
  const StoreManagementSyncException(this.message, this.cause);

  final String message;
  final Object cause;

  @override
  String toString() => message;
}
