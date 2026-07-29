import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:virtual_currency_cards/services/api_service.dart';
import 'package:virtual_currency_cards/services/store_management_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('offline sales never make warehouse stock negative', () async {
    final service = StoreManagementService();
    const userId = 'offline-stock-user';
    await service.queueWarehouse(userId: userId, name: 'الرئيسي');
    await service.queueProduct(
      userId: userId,
      name: 'قطعة',
      baseUnit: 'piece',
      minimumStock: 0,
      salePrice: 10,
      units: [
        {'name': 'حبة', 'code': 'piece', 'factorToBase': 1, 'isBase': true},
      ],
    );
    await service.queueParty(userId: userId, type: 'supplier', name: 'مورد');
    var snapshot = await service.getSnapshot(userId);
    final warehouse = (snapshot['warehouses'] as List).first as Map;
    final product = (snapshot['products'] as List).first as Map;
    final unit = (product['units'] as List).first as Map;
    final supplier = (snapshot['parties'] as List).first as Map;
    final item = {
      'productId': product['id'],
      'productClientRef': product['clientRef'],
      'productUnitId': unit['id'],
      'unitClientRef': unit['clientRef'],
      'quantity': 5.0,
      'unitPrice': 4.0,
    };
    await service.queueInvoice(
      userId: userId,
      invoiceType: 'purchase',
      partyId: supplier['id'] as String,
      partyClientRef: supplier['clientRef'] as String,
      warehouseId: warehouse['id'] as String,
      paidAmount: 20,
      paymentMethod: 'cash',
      items: [item],
    );
    final pendingBefore = await service.getPendingOperations(userId);

    await expectLater(
      service.queueInvoice(
        userId: userId,
        invoiceType: 'sale',
        warehouseId: warehouse['id'] as String,
        paidAmount: 0,
        paymentMethod: 'cash',
        items: [
          {...item, 'quantity': 6.0, 'unitPrice': 10.0},
        ],
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      await service.getPendingOperations(userId),
      hasLength(pendingBefore.length),
    );

    await service.queueInvoice(
      userId: userId,
      invoiceType: 'sale',
      warehouseId: warehouse['id'] as String,
      paidAmount: 0,
      paymentMethod: 'cash',
      items: [
        {...item, 'quantity': 3.0, 'unitPrice': 10.0},
      ],
    );
    snapshot = await service.getSnapshot(userId);
    expect((snapshot['products'] as List).first['stockQuantity'], 2.0);
  });

  test('offline invoice payment is capped at the remaining balance', () async {
    final service = StoreManagementService();
    const userId = 'offline-payment-user';
    await service.queueWarehouse(userId: userId, name: 'الرئيسي');
    await service.queueProduct(
      userId: userId,
      name: 'خدمة',
      baseUnit: 'piece',
      minimumStock: 0,
      salePrice: 30,
      units: [
        {'name': 'حبة', 'code': 'piece', 'factorToBase': 1, 'isBase': true},
      ],
    );
    await service.queueParty(userId: userId, type: 'customer', name: 'عميل');
    await service.queueParty(userId: userId, type: 'supplier', name: 'مورد');
    var snapshot = await service.getSnapshot(userId);
    final warehouse = (snapshot['warehouses'] as List).first as Map;
    final product = (snapshot['products'] as List).first as Map;
    final unit = (product['units'] as List).first as Map;
    final parties = (snapshot['parties'] as List).cast<Map>();
    final party = parties.firstWhere((item) => item['type'] == 'customer');
    final supplier = parties.firstWhere((item) => item['type'] == 'supplier');
    await service.queueInvoice(
      userId: userId,
      invoiceType: 'purchase',
      partyId: supplier['id'] as String,
      partyClientRef: supplier['clientRef'] as String,
      warehouseId: warehouse['id'] as String,
      paidAmount: 0,
      paymentMethod: 'cash',
      items: [
        {
          'productId': product['id'],
          'productClientRef': product['clientRef'],
          'productUnitId': unit['id'],
          'unitClientRef': unit['clientRef'],
          'quantity': 1.0,
          'unitPrice': 5.0,
        },
      ],
    );
    await service.queueInvoice(
      userId: userId,
      invoiceType: 'sale',
      partyId: party['id'] as String,
      partyClientRef: party['clientRef'] as String,
      actorUserId: 'cashier-1',
      actorName: 'الكاشير المحلي',
      warehouseId: warehouse['id'] as String,
      paidAmount: 0,
      paymentMethod: 'cash',
      items: [
        {
          'productId': product['id'],
          'productClientRef': product['clientRef'],
          'productUnitId': unit['id'],
          'unitClientRef': unit['clientRef'],
          'quantity': 1.0,
          'unitPrice': 30.0,
        },
      ],
    );
    snapshot = await service.getSnapshot(userId);
    final sale = (snapshot['invoices'] as List).first as Map;
    expect(sale['cashierName'], 'الكاشير المحلي');
    await service.queuePayment(
      userId: userId,
      invoiceId: sale['id'] as String,
      invoiceClientRef: sale['clientRef'] as String,
      partyId: party['id'] as String,
      partyClientRef: party['clientRef'] as String,
      direction: 'in',
      amount: 100,
    );
    snapshot = await service.getSnapshot(userId);
    expect((snapshot['payments'] as List).first['amount'], 30.0);
    expect((snapshot['parties'] as List).first['receivableBalance'], 0.0);
  });

  test(
    'offline maintenance parts cannot exceed cached warehouse stock',
    () async {
      final service = StoreManagementService();
      const userId = 'offline-maintenance-stock-user';
      await service.cacheMaintenanceSnapshot(userId, {
        'orders': <Map<String, dynamic>>[],
        'permissions': {
          'canViewStoreReports': true,
          'canViewStoreProfits': true,
        },
        'employees': [
          {'id': 'employee-1', 'name': 'موظف الصيانة'},
        ],
        'products': [
          {
            'id': 'part-1',
            'name': 'شاشة',
            'averageCost': 8.0,
            'units': [
              {'id': 'unit-1', 'factor': 1},
            ],
            'stocks': [
              {'warehouseId': 'warehouse-1', 'quantity': 3.0},
            ],
          },
        ],
        'warehouses': [
          {'id': 'warehouse-1', 'name': 'الرئيسي'},
        ],
      });
      await service.queueMaintenance(
        userId: userId,
        action: 'create',
        data: const {
          'customerName': 'عميل',
          'customerPhone': '0599000000',
          'deviceType': 'هاتف',
          'reportedIssue': 'شاشة مكسورة',
          'deviceCondition': 'مستعمل',
          'location': 'رف 1',
          'actorUserId': 'employee-1',
          'actorName': 'موظف الصيانة',
        },
      );
      final maintenance = await service.getMaintenanceSnapshot(userId);
      final order = (maintenance['orders'] as List).first as Map;
      expect((order['receivedBy'] as Map)['name'], 'موظف الصيانة');
      expect(
        ((order['logs'] as List).first['actor'] as Map)['name'],
        'موظف الصيانة',
      );
      await service.queueMaintenance(
        userId: userId,
        action: 'add_part',
        orderId: order['id'] as String,
        orderClientRef: order['clientRef'] as String,
        data: const {
          'productId': 'part-1',
          'productUnitId': 'unit-1',
          'warehouseId': 'warehouse-1',
          'quantity': 2.0,
          'unitPrice': 20.0,
        },
      );
      await service.queueMaintenance(
        userId: userId,
        action: 'update',
        orderId: order['id'] as String,
        orderClientRef: order['clientRef'] as String,
        data: const {
          'status': 'received',
          'assignedToUserId': 'employee-1',
          'laborPrice': 10.0,
          'actorUserId': 'employee-1',
          'actorName': 'موظف الصيانة',
        },
      );
      final updated = await service.getMaintenanceSnapshot(userId);
      final updatedOrder = (updated['orders'] as List).first as Map;
      expect(updatedOrder['total'], 50.0);
      expect(updatedOrder['profit'], 34.0);
      expect(((updated['summary'] as Map)['today'] as Map)['revenue'], 50.0);
      expect(
        ((updated['technicianPerformance'] as List).first
            as Map)['ordersCount'],
        1,
      );
      final pendingBefore = await service.getPendingOperations(userId);
      await expectLater(
        service.queueMaintenance(
          userId: userId,
          action: 'add_part',
          orderId: order['id'] as String,
          orderClientRef: order['clientRef'] as String,
          data: const {
            'productId': 'part-1',
            'productUnitId': 'unit-1',
            'warehouseId': 'warehouse-1',
            'quantity': 2.0,
            'unitPrice': 20.0,
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        await service.getPendingOperations(userId),
        hasLength(pendingBefore.length),
      );
    },
  );

  test(
    'a failed operation stays visible after an earlier operation syncs',
    () async {
      final service = StoreManagementService();
      const userId = 'partial-sync-user';
      for (final name in ['ينجح', 'يبقى محليًا']) {
        await service.queueProduct(
          userId: userId,
          name: name,
          baseUnit: 'piece',
          minimumStock: 0,
          salePrice: 1,
          units: const [],
        );
      }
      await expectLater(
        service.syncPending(userId: userId, api: _PartialSyncApi()),
        throwsA(isA<StoreManagementSyncException>()),
      );
      final snapshot = await service.getSnapshot(userId);
      final products = (snapshot['products'] as List).cast<Map>();
      expect(products.map((item) => item['name']), contains('يبقى محليًا'));
      expect(await service.getPendingOperations(userId), hasLength(1));
    },
  );

  test('deleting a pending sale restores confirmed balances', () async {
    final service = StoreManagementService();
    const userId = 'delete-pending-user';
    await service.queueProduct(
      userId: userId,
      name: 'تهيئة',
      baseUnit: 'piece',
      minimumStock: 0,
      salePrice: 1,
      units: const [],
    );
    await service.syncPending(userId: userId, api: _StockSnapshotApi());
    await service.queueInvoice(
      userId: userId,
      invoiceType: 'sale',
      warehouseId: 'warehouse-1',
      paidAmount: 0,
      paymentMethod: 'cash',
      items: const [
        {
          'productId': 'product-1',
          'productUnitId': 'unit-1',
          'quantity': 3.0,
          'unitPrice': 10.0,
        },
      ],
    );
    var snapshot = await service.getSnapshot(userId);
    expect((snapshot['products'] as List).first['stockQuantity'], 2.0);
    expect(snapshot['invoices'], hasLength(1));
    final operation = (await service.getPendingOperations(userId)).single;
    await service.removePendingOperation(
      userId: userId,
      opId: operation['opId'] as String,
    );
    snapshot = await service.getSnapshot(userId);
    expect((snapshot['products'] as List).first['stockQuantity'], 5.0);
    expect(snapshot['invoices'], isEmpty);
  });

  test(
    'simultaneous offline sales are serialized without overselling',
    () async {
      final service = StoreManagementService();
      const userId = 'concurrent-sales-user';
      await service.queueProduct(
        userId: userId,
        name: 'تهيئة',
        baseUnit: 'piece',
        minimumStock: 0,
        salePrice: 1,
        units: const [],
      );
      await service.syncPending(userId: userId, api: _StockSnapshotApi());
      Future<bool> sell() async {
        try {
          await service.queueInvoice(
            userId: userId,
            invoiceType: 'sale',
            warehouseId: 'warehouse-1',
            paidAmount: 0,
            paymentMethod: 'cash',
            items: const [
              {
                'productId': 'product-1',
                'productUnitId': 'unit-1',
                'quantity': 3.0,
                'unitPrice': 10.0,
              },
            ],
          );
          return true;
        } catch (_) {
          return false;
        }
      }

      final results = await Future.wait([sell(), sell()]);
      expect(results.where((result) => result), hasLength(1));
      final snapshot = await service.getSnapshot(userId);
      expect((snapshot['products'] as List).first['stockQuantity'], 2.0);
      expect(await service.getPendingOperations(userId), hasLength(1));
    },
  );

  test('offline transfer keeps all local references', () async {
    final service = StoreManagementService();
    const userId = 'local-transfer-refs-user';
    await service.queueWarehouse(userId: userId, name: 'الأول');
    await service.queueWarehouse(userId: userId, name: 'الثاني');
    await service.queueProduct(
      userId: userId,
      name: 'صنف محلي',
      baseUnit: 'piece',
      minimumStock: 0,
      salePrice: 10,
      units: const [
        {'name': 'حبة', 'factorToBase': 1, 'isBase': true},
      ],
    );
    await service.queueParty(userId: userId, type: 'supplier', name: 'مورد');
    final snapshot = await service.getSnapshot(userId);
    final warehouses = (snapshot['warehouses'] as List).cast<Map>();
    final product = (snapshot['products'] as List).first as Map;
    final unit = (product['units'] as List).first as Map;
    final supplier = (snapshot['parties'] as List).first as Map;
    await service.queueInvoice(
      userId: userId,
      invoiceType: 'purchase',
      partyId: supplier['id'] as String,
      partyClientRef: supplier['clientRef'] as String,
      warehouseId: warehouses.first['id'] as String,
      warehouseClientRef: warehouses.first['clientRef'] as String,
      paidAmount: 0,
      paymentMethod: 'cash',
      items: [
        {
          'productId': product['id'],
          'productClientRef': product['clientRef'],
          'productUnitId': unit['id'],
          'unitClientRef': unit['clientRef'],
          'quantity': 5.0,
          'unitPrice': 2.0,
        },
      ],
    );
    await service.queueStockTransfer(
      userId: userId,
      fromWarehouseId: warehouses.first['id'] as String,
      toWarehouseId: warehouses.last['id'] as String,
      items: [
        {
          'productId': product['id'],
          'productUnitId': unit['id'],
          'quantity': 2.0,
        },
      ],
    );
    final transfer = (await service.getPendingOperations(userId)).last;
    expect(transfer['fromWarehouseClientRef'], warehouses.first['clientRef']);
    expect(transfer['toWarehouseClientRef'], warehouses.last['clientRef']);
    expect(
      (transfer['items'] as List).first['productClientRef'],
      product['clientRef'],
    );
    expect(
      (transfer['items'] as List).first['unitClientRef'],
      unit['clientRef'],
    );
  });

  test('maintenance invoice syncs before delivered status', () async {
    final service = StoreManagementService();
    final api = _MaintenanceOrderApi();
    const userId = 'maintenance-delivery-order-user';
    await service.cacheMaintenanceSnapshot(userId, {
      'orders': [
        {
          'id': 'maintenance-order-1',
          'clientRef': 'maintenance-order-ref-1',
          'status': 'completed',
          'assignedTo': {'id': 'technician-1', 'name': 'فني'},
          'diagnosis': 'تم الإصلاح',
          'parts': <Map<String, dynamic>>[],
          'logs': <Map<String, dynamic>>[],
          'contacts': <Map<String, dynamic>>[],
          'laborPrice': 20.0,
          'partsPrice': 0.0,
          'partsCost': 0.0,
          'otherCost': 0.0,
          'discount': 0.0,
          'paidAmount': 20.0,
          'total': 20.0,
          'profit': 20.0,
          'createdAt': DateTime.now().toIso8601String(),
        },
      ],
      'products': <Map<String, dynamic>>[],
      'warehouses': <Map<String, dynamic>>[],
      'employees': <Map<String, dynamic>>[],
      'permissions': <String, dynamic>{},
    });
    await service.queueMaintenance(
      userId: userId,
      action: 'finalize',
      orderId: 'maintenance-order-1',
      orderClientRef: 'maintenance-order-ref-1',
    );
    await service.queueMaintenance(
      userId: userId,
      action: 'update',
      orderId: 'maintenance-order-1',
      orderClientRef: 'maintenance-order-ref-1',
      data: const {'status': 'delivered'},
    );
    await service.syncPending(userId: userId, api: api);
    expect(api.actions, ['finalize', 'update']);
  });

  test(
    'invalid maintenance finalization never enters the offline queue',
    () async {
      final service = StoreManagementService();
      const userId = 'invalid-maintenance-finalize-user';
      await service.cacheMaintenanceSnapshot(userId, {
        'orders': [
          {
            'id': 'order-zero',
            'clientRef': 'order-zero-ref',
            'status': 'completed',
            'total': 0.0,
            'invoiceId': null,
            'parts': <Map<String, dynamic>>[],
            'logs': <Map<String, dynamic>>[],
            'contacts': <Map<String, dynamic>>[],
          },
        ],
        'statusTransitions': {
          'completed': ['in_progress', 'delivered'],
        },
      });
      await expectLater(
        service.queueMaintenance(
          userId: userId,
          action: 'finalize',
          orderId: 'order-zero',
          orderClientRef: 'order-zero-ref',
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        service.queueMaintenance(
          userId: userId,
          action: 'update',
          orderId: 'order-zero',
          orderClientRef: 'order-zero-ref',
          data: const {'status': 'delivered'},
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        service.queueMaintenance(
          userId: userId,
          action: 'update',
          orderId: 'order-zero',
          orderClientRef: 'order-zero-ref',
          data: const {
            'status': 'completed',
            'assignedToUserId': 'technician-1',
            'diagnosis': 'تشخيص',
            'laborPrice': 10.0,
            'discount': 11.0,
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(await service.getPendingOperations(userId), isEmpty);
    },
  );

  test('invalid accounting operations never enter the offline queue', () async {
    final service = StoreManagementService();
    const userId = 'invalid-accounting-user';
    await expectLater(
      service.queueInvoice(
        userId: userId,
        invoiceType: 'purchase',
        paidAmount: 0,
        paymentMethod: 'cash',
        items: const [
          {'productId': 'p', 'quantity': 1.0, 'unitPrice': 5.0},
        ],
      ),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      service.queueInvoice(
        userId: userId,
        invoiceType: 'sale',
        paidAmount: 0,
        paymentMethod: 'cash',
        items: const [],
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      () => service.queuePayment(userId: userId, direction: 'in', amount: 5),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      service.queueStockTransfer(
        userId: userId,
        fromWarehouseId: 'same',
        toWarehouseId: 'same',
        items: const [
          {'productId': 'p', 'quantity': 1.0},
        ],
      ),
      throwsA(isA<StateError>()),
    );
    expect(await service.getPendingOperations(userId), isEmpty);
  });
}

class _PartialSyncApi extends ApiService {
  @override
  Future<Map<String, dynamic>> syncStoreManagement(
    List<Map<String, dynamic>> operations,
  ) async {
    if (operations.single['name'] == 'يبقى محليًا') {
      throw Exception('offline test failure');
    }
    return {
      'workspace': {
        'id': 'server-workspace',
        'name': 'المحل',
        'currency': 'ILS',
      },
      'products': <Map<String, dynamic>>[],
      'warehouses': <Map<String, dynamic>>[],
      'parties': <Map<String, dynamic>>[],
      'invoices': <Map<String, dynamic>>[],
      'payments': <Map<String, dynamic>>[],
      'debtBookAccounts': <Map<String, dynamic>>[],
      'summary': <String, dynamic>{},
      'syncedAt': DateTime.now().toIso8601String(),
    };
  }
}

class _StockSnapshotApi extends ApiService {
  @override
  Future<Map<String, dynamic>> syncStoreManagement(
    List<Map<String, dynamic>> operations,
  ) async => {
    'workspace': {'id': 'server-workspace', 'name': 'المحل', 'currency': 'ILS'},
    'products': [
      {
        'id': 'product-1',
        'clientRef': 'product-ref-1',
        'name': 'قطعة',
        'baseUnit': 'piece',
        'stockQuantity': 5.0,
        'averagePurchaseCost': 4.0,
        'minimumStock': 0.0,
        'units': [
          {
            'id': 'unit-1',
            'clientRef': 'unit-ref-1',
            'name': 'حبة',
            'factorToBase': 1.0,
            'salePrice': 10.0,
          },
        ],
        'warehouseStocks': [
          {'warehouseId': 'warehouse-1', 'quantity': 5.0},
        ],
      },
    ],
    'warehouses': [
      {'id': 'warehouse-1', 'name': 'الرئيسي', 'isDefault': true},
    ],
    'parties': <Map<String, dynamic>>[],
    'invoices': <Map<String, dynamic>>[],
    'payments': <Map<String, dynamic>>[],
    'debtBookAccounts': <Map<String, dynamic>>[],
    'summary': <String, dynamic>{},
    'syncedAt': DateTime.now().toIso8601String(),
  };
}

class _MaintenanceOrderApi extends ApiService {
  final actions = <String>[];

  @override
  Future<Map<String, dynamic>> syncStoreManagement(
    List<Map<String, dynamic>> operations,
  ) async {
    actions.add(operations.single['action'] as String);
    return {
      'workspace': {
        'id': 'server-workspace',
        'name': 'المحل',
        'currency': 'ILS',
      },
      'products': <Map<String, dynamic>>[],
      'warehouses': <Map<String, dynamic>>[],
      'parties': <Map<String, dynamic>>[],
      'invoices': <Map<String, dynamic>>[],
      'payments': <Map<String, dynamic>>[],
      'debtBookAccounts': <Map<String, dynamic>>[],
      'summary': <String, dynamic>{},
      'syncedAt': DateTime.now().toIso8601String(),
    };
  }

  @override
  Future<Map<String, dynamic>> getMaintenanceSnapshot({
    String search = '',
    String status = '',
  }) async => {
    'orders': [
      {
        'id': 'maintenance-order-1',
        'clientRef': 'maintenance-order-ref-1',
        'status': 'completed',
        'invoiceId': 'invoice-1',
        'parts': <Map<String, dynamic>>[],
        'logs': <Map<String, dynamic>>[],
        'contacts': <Map<String, dynamic>>[],
        'createdAt': DateTime.now().toIso8601String(),
      },
    ],
    'products': <Map<String, dynamic>>[],
    'warehouses': <Map<String, dynamic>>[],
    'employees': <Map<String, dynamic>>[],
    'permissions': <String, dynamic>{},
  };
}
