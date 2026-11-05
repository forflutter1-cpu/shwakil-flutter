import 'dart:async';
import 'dart:convert';

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
        paidAmount: 60,
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
      paidAmount: 30,
      paymentMethod: 'cash',
      items: [
        {...item, 'quantity': 3.0, 'unitPrice': 10.0},
      ],
    );
    snapshot = await service.getSnapshot(userId);
    expect((snapshot['products'] as List).first['stockQuantity'], 2.0);
  });

  test(
    'quick sale can add a manual item and record its stock below zero',
    () async {
      final service = StoreManagementService();
      const userId = 'offline-manual-quick-sale-user';
      await service.queueInvoice(
        userId: userId,
        invoiceType: 'sale',
        paidAmount: 12,
        paymentMethod: 'cash',
        quickSale: true,
        partyName: 'زبون عام',
        items: [
          {
            'manualEntry': true,
            'allowNegativeStock': true,
            'productClientRef': 'manual-product-1',
            'unitClientRef': 'manual-unit-1',
            'productName': 'صنف يدوي',
            'unitName': 'piece',
            'quantity': 3.0,
            'unitPrice': 4.0,
            'salePrice': 4.0,
          },
        ],
      );

      final snapshot = await service.getSnapshot(userId);
      final product = (snapshot['products'] as List).single as Map;
      final warehouse = (snapshot['warehouses'] as List).single as Map;
      final warehouseStock =
          ((product['warehouseStocks'] as List).single as Map);
      expect(product['name'], 'صنف يدوي');
      expect(product['stockQuantity'], -3.0);
      expect(warehouse['isDefault'], true);
      expect(warehouseStock['warehouseId'], warehouse['id']);
      expect(warehouseStock['quantity'], -3.0);
    },
  );

  test(
    'manual purchase line creates its item and adds warehouse stock',
    () async {
      final service = StoreManagementService();
      const userId = 'offline-manual-purchase-user';
      await service.queueParty(
        userId: userId,
        type: 'supplier',
        name: 'المورد العام',
      );
      final supplier = (await service.getSnapshot(userId))['parties'] as List;
      final party = supplier.single as Map;
      await service.queueInvoice(
        userId: userId,
        invoiceType: 'purchase',
        partyId: party['id'] as String,
        partyClientRef: party['clientRef'] as String,
        paidAmount: 9,
        paymentMethod: 'cash',
        items: [
          {
            'manualEntry': true,
            'productClientRef': 'purchase-manual-product',
            'unitClientRef': 'purchase-manual-unit',
            'productName': 'صنف شراء جديد',
            'sku': 'PURCHASE-NEW',
            'barcode': '123456789',
            'minimumStock': 5.0,
            'unitName': 'piece',
            'quantity': 3.0,
            'unitPrice': 3.0,
            'salePrice': 5.0,
          },
        ],
      );

      final snapshot = await service.getSnapshot(userId);
      final product = (snapshot['products'] as List).single as Map;
      expect(product['name'], 'صنف شراء جديد');
      expect(product['stockQuantity'], 3.0);
      expect(product['sku'], 'PURCHASE-NEW');
      expect(product['minimumStock'], 5.0);
      expect(
        ((product['units'] as List).single as Map)['barcode'],
        '123456789',
      );
      expect((snapshot['warehouses'] as List), hasLength(1));
    },
  );

  test('offline sales enforce a customer credit limit', () async {
    final service = StoreManagementService();
    const userId = 'offline-credit-limit-user';
    await service.queueParty(userId: userId, type: 'supplier', name: 'مورد');
    await service.queueParty(
      userId: userId,
      type: 'customer',
      name: 'زبون بحد دين',
      creditLimit: 10,
    );
    var snapshot = await service.getSnapshot(userId);
    final supplier = (snapshot['parties'] as List).cast<Map>().firstWhere(
      (party) => party['type'] == 'supplier',
    );
    final customer = (snapshot['parties'] as List).cast<Map>().firstWhere(
      (party) => party['type'] == 'customer',
    );
    await service.queueInvoice(
      userId: userId,
      invoiceType: 'purchase',
      partyId: supplier['id'] as String,
      partyClientRef: supplier['clientRef'] as String,
      paidAmount: 20,
      paymentMethod: 'cash',
      items: [
        {
          'manualEntry': true,
          'productClientRef': 'credit-limit-product',
          'unitClientRef': 'credit-limit-unit',
          'productName': 'صنف',
          'unitName': 'piece',
          'quantity': 20.0,
          'unitPrice': 1.0,
          'salePrice': 2.0,
        },
      ],
    );
    snapshot = await service.getSnapshot(userId);
    final product = (snapshot['products'] as List).single as Map;
    final unit = (product['units'] as List).single as Map;
    await service.queueInvoice(
      userId: userId,
      invoiceType: 'sale',
      partyId: customer['id'] as String,
      partyClientRef: customer['clientRef'] as String,
      paidAmount: 0,
      paymentMethod: 'cash',
      canManageStoreDebts: true,
      items: [
        {
          'productId': product['id'],
          'productClientRef': product['clientRef'],
          'productUnitId': unit['id'],
          'unitClientRef': unit['clientRef'],
          'quantity': 4.0,
          'unitPrice': 2.0,
        },
      ],
    );
    snapshot = await service.getSnapshot(userId);
    expect(
      (snapshot['parties'] as List).cast<Map>().firstWhere(
        (party) => party['id'] == customer['id'],
      )['receivableBalance'],
      8.0,
    );

    await expectLater(
      service.queueInvoice(
        userId: userId,
        invoiceType: 'sale',
        partyId: customer['id'] as String,
        partyClientRef: customer['clientRef'] as String,
        paidAmount: 0,
        paymentMethod: 'cash',
        canManageStoreDebts: true,
        items: [
          {
            'productId': product['id'],
            'productClientRef': product['clientRef'],
            'productUnitId': unit['id'],
            'unitClientRef': unit['clientRef'],
            'quantity': 2.0,
            'unitPrice': 2.0,
          },
        ],
      ),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'cashier can queue a sale while server refresh is still pending',
    () async {
      final service = StoreManagementService();
      const userId = 'offline-refresh-lock-user';
      final preferences = await SharedPreferences.getInstance();
      final serverSnapshot = _cashierSnapshot();
      await preferences.setString(
        'store_management_snapshot_$userId',
        jsonEncode(serverSnapshot),
      );
      final api = _BlockingSnapshotApi(serverSnapshot);
      final refresh = service.syncPending(userId: userId, api: api);
      await api.requestStarted.future;

      final sale = service.queueInvoice(
        userId: userId,
        invoiceType: 'sale',
        warehouseId: 'warehouse-1',
        paidAmount: 10,
        paymentMethod: 'كاش',
        items: const [
          {
            'productId': 'product-1',
            'productClientRef': 'product-ref-1',
            'productUnitId': 'unit-1',
            'unitClientRef': 'unit-ref-1',
            'quantity': 1.0,
            'unitPrice': 10.0,
          },
        ],
      );
      var queuedBeforeRefresh = true;
      try {
        await sale.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        queuedBeforeRefresh = false;
      }
      api.releaseRequest.complete();
      await refresh;
      if (!queuedBeforeRefresh) await sale;

      expect(queuedBeforeRefresh, isTrue);
      final snapshot = await service.getSnapshot(userId);
      expect((snapshot['products'] as List).single['stockQuantity'], 4.0);
      expect((await service.getPendingOperations(userId)), hasLength(1));
    },
  );

  test(
    'offline debt sales honor permissions and quick sales stay paid',
    () async {
      final service = StoreManagementService();
      const userId = 'offline-debt-permission-user';
      await service.queueWarehouse(userId: userId, name: 'الرئيسي');
      await service.queueProduct(
        userId: userId,
        name: 'صنف آجل',
        baseUnit: 'piece',
        minimumStock: 0,
        salePrice: 10,
        units: const [
          {
            'name': 'حبة',
            'code': 'piece',
            'factorToBase': 1,
            'isBase': true,
            'salePrice': 10,
          },
        ],
      );
      var snapshot = await service.getSnapshot(userId);
      final warehouse = (snapshot['warehouses'] as List).first as Map;
      final product = (snapshot['products'] as List).first as Map;
      final unit = (product['units'] as List).first as Map;
      await service.queueStockAdjustment(
        userId: userId,
        productId: product['id'] as String,
        productClientRef: product['clientRef'] as String,
        warehouseId: warehouse['id'] as String,
        warehouseClientRef: warehouse['clientRef'] as String,
        productUnitId: unit['id'] as String,
        unitClientRef: unit['clientRef'] as String,
        targetQuantity: 3,
      );
      final item = {
        'productId': product['id'],
        'productClientRef': product['clientRef'],
        'productUnitId': unit['id'],
        'unitClientRef': unit['clientRef'],
        'quantity': 1.0,
        'unitPrice': 10.0,
      };

      await expectLater(
        service.queueInvoice(
          userId: userId,
          invoiceType: 'sale',
          warehouseId: warehouse['id'] as String,
          paidAmount: 5,
          paymentMethod: 'cash',
          items: [item],
        ),
        throwsA(isA<StateError>()),
      );

      await expectLater(
        service.queueInvoice(
          userId: userId,
          invoiceType: 'sale',
          warehouseId: warehouse['id'] as String,
          paidAmount: 5,
          paymentMethod: 'cash',
          canManageStoreDebts: true,
          items: [item],
        ),
        throwsA(isA<StateError>()),
      );

      await service.queueParty(
        userId: userId,
        type: 'customer',
        name: 'زبون آجل',
      );
      snapshot = await service.getSnapshot(userId);
      final customer = (snapshot['parties'] as List).first as Map;
      await service.queueInvoice(
        userId: userId,
        invoiceType: 'sale',
        partyId: customer['id'] as String,
        partyClientRef: customer['clientRef'] as String,
        warehouseId: warehouse['id'] as String,
        paidAmount: 5,
        paymentMethod: 'cash',
        canManageStoreDebts: true,
        items: [item],
      );

      await expectLater(
        service.queueInvoice(
          userId: userId,
          invoiceType: 'sale',
          warehouseId: warehouse['id'] as String,
          paidAmount: 0,
          paymentMethod: 'cash',
          quickSale: true,
          canManageStoreDebts: true,
          items: [item],
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('cashier can queue sales while an invoice sync is pending', () async {
    final service = StoreManagementService();
    const userId = 'offline-sync-lock-user';
    final preferences = await SharedPreferences.getInstance();
    final snapshot = _cashierSnapshot();
    await preferences.setString(
      'store_management_snapshot_$userId',
      jsonEncode(snapshot),
    );
    Future<void> queueSale() => service.queueInvoice(
      userId: userId,
      invoiceType: 'sale',
      warehouseId: 'warehouse-1',
      paidAmount: 10,
      paymentMethod: 'كاش',
      items: const [
        {
          'productId': 'product-1',
          'productClientRef': 'product-ref-1',
          'productUnitId': 'unit-1',
          'unitClientRef': 'unit-ref-1',
          'quantity': 1.0,
          'unitPrice': 10.0,
        },
      ],
    );

    await queueSale();
    final api = _BlockingInvoiceSyncApi(snapshot);
    final sync = service.syncPending(userId: userId, api: api);
    await api.requestStarted.future;

    var queuedDuringSync = true;
    final secondSale = queueSale();
    try {
      await secondSale.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      queuedDuringSync = false;
    }
    api.releaseRequest.complete();
    await sync;
    if (!queuedDuringSync) await secondSale;

    expect(queuedDuringSync, isTrue);
    expect(await service.getPendingOperations(userId), isEmpty);
    final finalSnapshot = await service.getSnapshot(userId);
    expect((finalSnapshot['products'] as List).single['stockQuantity'], 3.0);
  });

  test(
    'offline cashier without price rights uses fixed prices and cannot discount',
    () async {
      final service = StoreManagementService();
      const userId = 'offline-price-guard-user';
      await service.queueWarehouse(userId: userId, name: 'الرئيسي');
      await service.queueProduct(
        userId: userId,
        name: 'صنف بسعر محدد',
        baseUnit: 'piece',
        minimumStock: 0,
        salePrice: 12,
        units: const [
          {
            'name': 'حبة',
            'code': 'piece',
            'factorToBase': 1,
            'isBase': true,
            'salePrice': 12,
          },
        ],
      );
      var snapshot = await service.getSnapshot(userId);
      final warehouse = (snapshot['warehouses'] as List).first as Map;
      final product = (snapshot['products'] as List).first as Map;
      final unit = (product['units'] as List).first as Map;
      await service.queueStockAdjustment(
        userId: userId,
        productId: product['id'] as String,
        productClientRef: product['clientRef'] as String,
        warehouseId: warehouse['id'] as String,
        warehouseClientRef: warehouse['clientRef'] as String,
        productUnitId: unit['id'] as String,
        unitClientRef: unit['clientRef'] as String,
        targetQuantity: 4,
      );

      await service.queueInvoice(
        userId: userId,
        invoiceType: 'sale',
        warehouseId: warehouse['id'] as String,
        paidAmount: 12,
        paymentMethod: 'cash',
        canEditStorePrices: false,
        items: [
          {
            'productId': product['id'],
            'productClientRef': product['clientRef'],
            'productUnitId': unit['id'],
            'unitClientRef': unit['clientRef'],
            'quantity': 1.0,
            'unitPrice': 1.0,
          },
        ],
      );

      snapshot = await service.getSnapshot(userId);
      final invoice = (snapshot['invoices'] as List).first as Map;
      expect(invoice['total'], 12.0);
      expect((invoice['items'] as List).first['unitPrice'], 12.0);

      await expectLater(
        service.queueInvoice(
          userId: userId,
          invoiceType: 'sale',
          warehouseId: warehouse['id'] as String,
          paidAmount: 10,
          paymentMethod: 'cash',
          discount: 2,
          canEditStorePrices: false,
          items: [
            {
              'productId': product['id'],
              'productClientRef': product['clientRef'],
              'productUnitId': unit['id'],
              'unitClientRef': unit['clientRef'],
              'quantity': 1.0,
              'unitPrice': 12.0,
            },
          ],
        ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('offline opening stock adjustments feed cashier stock checks', () async {
    final service = StoreManagementService();
    const userId = 'offline-opening-stock-user';
    await service.queueWarehouse(userId: userId, name: 'الرئيسي');
    await service.queueProduct(
      userId: userId,
      name: 'صنف مستورد',
      baseUnit: 'piece',
      minimumStock: 0,
      salePrice: 8,
      units: const [
        {'name': 'حبة', 'code': 'piece', 'factorToBase': 1, 'isBase': true},
      ],
    );
    var snapshot = await service.getSnapshot(userId);
    final warehouse = (snapshot['warehouses'] as List).first as Map;
    final product = (snapshot['products'] as List).first as Map;
    final unit = (product['units'] as List).first as Map;

    await service.queueStockAdjustment(
      userId: userId,
      productId: product['id'] as String,
      productClientRef: product['clientRef'] as String,
      warehouseId: warehouse['id'] as String,
      warehouseClientRef: warehouse['clientRef'] as String,
      productUnitId: unit['id'] as String,
      unitClientRef: unit['clientRef'] as String,
      targetQuantity: 4,
      unitCost: 3,
      clientRef: 'opening-stock-ref-1',
    );

    snapshot = await service.getSnapshot(userId);
    expect((snapshot['products'] as List).first['stockQuantity'], 4.0);
    expect((snapshot['products'] as List).first['averagePurchaseCost'], 3.0);
    await service.queueInvoice(
      userId: userId,
      invoiceType: 'sale',
      warehouseId: warehouse['id'] as String,
      paidAmount: 8,
      paymentMethod: 'cash',
      items: [
        {
          'productId': product['id'],
          'productClientRef': product['clientRef'],
          'productUnitId': unit['id'],
          'unitClientRef': unit['clientRef'],
          'quantity': 1.0,
          'unitPrice': 8.0,
        },
      ],
    );
    snapshot = await service.getSnapshot(userId);
    expect((snapshot['products'] as List).first['stockQuantity'], 3.0);
    expect(
      (await service.getPendingOperations(userId))
          .where((operation) => operation['entity'] == 'stock_adjustment')
          .single['clientRef'],
      'opening-stock-ref-1',
    );
    await expectLater(
      service.queueInvoice(
        userId: userId,
        invoiceType: 'sale',
        warehouseId: warehouse['id'] as String,
        paidAmount: 32,
        paymentMethod: 'cash',
        items: [
          {
            'productId': product['id'],
            'productClientRef': product['clientRef'],
            'productUnitId': unit['id'],
            'unitClientRef': unit['clientRef'],
            'quantity': 4.0,
            'unitPrice': 8.0,
          },
        ],
      ),
      throwsA(isA<StateError>()),
    );
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
      canManageStoreDebts: true,
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
      canManageStoreDebts: true,
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
      clientRef: 'offline-import-payment-ref',
      occurredAt: DateTime(2024, 5, 10),
    );
    await service.queuePayment(
      userId: userId,
      invoiceId: sale['id'] as String,
      invoiceClientRef: sale['clientRef'] as String,
      partyId: party['id'] as String,
      partyClientRef: party['clientRef'] as String,
      direction: 'in',
      amount: 100,
      clientRef: 'offline-import-payment-ref',
      occurredAt: DateTime(2024, 5, 10),
    );
    snapshot = await service.getSnapshot(userId);
    expect((snapshot['payments'] as List).first['amount'], 30.0);
    expect(
      (snapshot['payments'] as List).first['clientRef'],
      'offline-import-payment-ref',
    );
    expect(
      (snapshot['payments'] as List).first['occurredAt'],
      DateTime(2024, 5, 10).toIso8601String(),
    );
    expect(
      (await service.getPendingOperations(
        userId,
      )).where((operation) => operation['entity'] == 'payment'),
      hasLength(1),
    );
    expect((snapshot['parties'] as List).first['receivableBalance'], 0.0);
  });

  test(
    'offline supplier payment queues when purchase balance is hidden',
    () async {
      final service = StoreManagementService();
      const userId = 'offline-hidden-purchase-payment-user';
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        'store_management_snapshot_$userId',
        jsonEncode({
          'invoices': [
            {
              'id': 'purchase-1',
              'clientRef': 'purchase-ref',
              'type': 'purchase',
              'partyId': 'supplier-1',
              'total': null,
              'paidAmount': null,
              'dueAmount': null,
              'paymentStatus': 'partial',
            },
          ],
          'payments': <Map<String, dynamic>>[],
          'parties': [
            {'id': 'supplier-1', 'payableBalance': 10.0},
          ],
          'products': <Map<String, dynamic>>[],
          'warehouses': <Map<String, dynamic>>[],
          'paymentMethods': <Map<String, dynamic>>[],
        }),
      );

      await service.queuePayment(
        userId: userId,
        invoiceId: 'purchase-1',
        partyId: 'supplier-1',
        direction: 'out',
        amount: 6,
      );

      final snapshot = await service.getSnapshot(userId);
      expect((snapshot['invoices'] as List).single['dueAmount'], isNull);
      expect((snapshot['payments'] as List).single['amount'], 6.0);
      expect((snapshot['parties'] as List).single['payableBalance'], 10.0);
      expect(await service.getPendingOperations(userId), hasLength(1));
    },
  );

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
      paidAmount: 30,
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
            paidAmount: 30,
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
      canManageStoreDebts: true,
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

  test('required offline master data fields are enforced', () async {
    final service = StoreManagementService();
    const userId = 'invalid-master-data-user';
    expect(
      () => service.queueProduct(
        userId: userId,
        name: ' ',
        baseUnit: 'piece',
        minimumStock: 0,
        salePrice: 0,
        units: const [],
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      () => service.queueWarehouse(userId: userId, name: ''),
      throwsA(isA<StateError>()),
    );
    expect(
      () => service.queueParty(userId: userId, type: 'customer', name: ''),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      service.queueMaintenance(
        userId: userId,
        action: 'create',
        data: const {'customerName': 'عميل'},
      ),
      throwsA(isA<StateError>()),
    );
    expect(await service.getPendingOperations(userId), isEmpty);
  });

  test('offline queue keeps a durable insertion sequence', () async {
    final service = StoreManagementService();
    const userId = 'queue-sequence-user';
    await Future.wait([
      service.queueParty(userId: userId, type: 'customer', name: 'الأول'),
      service.queueParty(userId: userId, type: 'customer', name: 'الثاني'),
    ]);
    final pending = await service.getPendingOperations(userId);
    expect(pending.map((item) => item['queueSequence']), [1, 2]);
    expect(pending.map((item) => item['name']), ['الأول', 'الثاني']);
    expect(
      pending.every(
        (item) =>
            DateTime.tryParse(item['createdAt']?.toString() ?? '') != null,
      ),
      isTrue,
    );
  });

  test('restored final stock waits until imported invoices sync', () async {
    final service = StoreManagementService();
    const userId = 'deferred-restore-stock-user';
    await service.queueWarehouse(userId: userId, name: 'الرئيسي');
    await service.queueProduct(
      userId: userId,
      name: 'صنف مستورد',
      baseUnit: 'piece',
      minimumStock: 0,
      salePrice: 10,
      units: const [
        {'name': 'حبة', 'code': 'piece', 'factorToBase': 1, 'isBase': true},
      ],
    );
    var snapshot = await service.getSnapshot(userId);
    final warehouse = (snapshot['warehouses'] as List).first as Map;
    final product = (snapshot['products'] as List).first as Map;
    final unit = (product['units'] as List).first as Map;
    await service.queueStockAdjustment(
      userId: userId,
      productId: product['id'] as String,
      productClientRef: product['clientRef'] as String,
      warehouseId: warehouse['id'] as String,
      warehouseClientRef: warehouse['clientRef'] as String,
      productUnitId: unit['id'] as String,
      unitClientRef: unit['clientRef'] as String,
      targetQuantity: 5,
      clientRef: 'restore-seed-stock-ref',
    );
    snapshot = await service.getSnapshot(userId);
    await service.queueInvoice(
      userId: userId,
      invoiceType: 'sale',
      warehouseId: warehouse['id'] as String,
      paidAmount: 10,
      paymentMethod: 'cash',
      items: [
        {
          'productId': product['id'],
          'productClientRef': product['clientRef'],
          'productUnitId': unit['id'],
          'unitClientRef': unit['clientRef'],
          'quantity': 1.0,
          'unitPrice': 10.0,
        },
      ],
    );
    await service.queueStockAdjustment(
      userId: userId,
      productId: product['id'] as String,
      productClientRef: product['clientRef'] as String,
      warehouseId: warehouse['id'] as String,
      warehouseClientRef: warehouse['clientRef'] as String,
      productUnitId: unit['id'] as String,
      unitClientRef: unit['clientRef'] as String,
      targetQuantity: 4,
      clientRef: 'restore-final-stock-ref',
      deferUntilNoPendingInvoices: true,
    );

    final api = _DeferredInvoiceSyncApi()..failInvoices = true;
    await expectLater(
      service.syncPending(userId: userId, api: api),
      throwsA(isA<StoreManagementSyncException>()),
    );
    expect(api.syncedEntities, isNot(contains('restore-final-stock-ref')));
    expect(
      (await service.getPendingOperations(userId)).any(
        (operation) => operation['clientRef'] == 'restore-final-stock-ref',
      ),
      isTrue,
    );

    api
      ..failInvoices = false
      ..syncedEntities.clear();
    await service.syncPending(userId: userId, api: api);
    final invoiceIndex = api.syncedEntities.indexOf('invoice');
    final finalStockIndex = api.syncedEntities.indexOf(
      'restore-final-stock-ref',
    );
    expect(invoiceIndex, greaterThanOrEqualTo(0));
    expect(finalStockIndex, greaterThan(invoiceIndex));
    expect(await service.getPendingOperations(userId), isEmpty);
  });
}

Map<String, dynamic> _cashierSnapshot() => {
  'workspace': {'id': 'workspace-1', 'name': 'المحل', 'currency': 'ILS'},
  'products': [
    {
      'id': 'product-1',
      'clientRef': 'product-ref-1',
      'name': 'قطعة',
      'baseUnit': 'piece',
      'defaultSalePrice': 10.0,
      'averagePurchaseCost': 4.0,
      'stockQuantity': 5.0,
      'minimumStock': 0.0,
      'units': [
        {
          'id': 'unit-1',
          'clientRef': 'unit-ref-1',
          'name': 'حبة',
          'factorToBase': 1.0,
          'salePrice': 10.0,
          'isBase': true,
        },
      ],
      'warehouseStocks': [
        {'warehouseId': 'warehouse-1', 'quantity': 5.0},
      ],
    },
  ],
  'warehouses': [
    {
      'id': 'warehouse-1',
      'clientRef': 'warehouse-ref-1',
      'name': 'الرئيسي',
      'isDefault': true,
    },
  ],
  'parties': <Map<String, dynamic>>[],
  'invoices': <Map<String, dynamic>>[],
  'payments': <Map<String, dynamic>>[],
  'paymentMethods': <Map<String, dynamic>>[
    {'id': 'cash-1', 'name': 'كاش', 'isActive': true},
  ],
  'debtBookAccounts': <Map<String, dynamic>>[],
  'summary': <String, dynamic>{},
};

class _PartialSyncApi extends ApiService {
  @override
  Future<Map<String, dynamic>> syncStoreManagement(
    List<Map<String, dynamic>> operations,
  ) async {
    if (operations.single['name'] == 'يبقى محليًا') {
      throw Exception('offline test failure');
    }
    return {
      'applied': [
        {'opId': operations.single['opId']},
      ],
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

class _BlockingSnapshotApi extends ApiService {
  _BlockingSnapshotApi(this.snapshot);

  final Map<String, dynamic> snapshot;
  final requestStarted = Completer<void>();
  final releaseRequest = Completer<void>();

  @override
  Future<Map<String, dynamic>> getStoreManagementSnapshot({
    bool includeFullHistory = false,
  }) async {
    requestStarted.complete();
    await releaseRequest.future;
    return Map<String, dynamic>.from(snapshot);
  }
}

class _BlockingInvoiceSyncApi extends ApiService {
  _BlockingInvoiceSyncApi(this.snapshot);

  final Map<String, dynamic> snapshot;
  final requestStarted = Completer<void>();
  final releaseRequest = Completer<void>();
  var _callCount = 0;

  @override
  Future<Map<String, dynamic>> syncStoreManagement(
    List<Map<String, dynamic>> operations,
  ) async {
    _callCount++;
    if (_callCount == 1) {
      requestStarted.complete();
      await releaseRequest.future;
    }
    final stock = 5.0 - _callCount;
    final product = Map<String, dynamic>.from(
      (snapshot['products'] as List).single as Map,
    );
    product['stockQuantity'] = stock;
    product['warehouseStocks'] = [
      {'warehouseId': 'warehouse-1', 'quantity': stock},
    ];
    return {
      ...snapshot,
      'products': [product],
      'applied': [
        {'opId': operations.single['opId']},
      ],
    };
  }
}

class _DeferredInvoiceSyncApi extends ApiService {
  final syncedEntities = <String>[];
  bool failInvoices = false;

  @override
  Future<Map<String, dynamic>> syncStoreManagement(
    List<Map<String, dynamic>> operations,
  ) async {
    final operation = operations.single;
    syncedEntities.add(
      operation['entity'] == 'stock_adjustment'
          ? operation['clientRef']?.toString() ?? 'stock_adjustment'
          : operation['entity']?.toString() ?? '',
    );
    if (failInvoices && operation['entity'] == 'invoice') {
      throw Exception('invoice sync temporarily failed');
    }
    return {
      'applied': [
        {'opId': operation['opId']},
      ],
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
    'applied': [
      {'opId': operations.single['opId']},
    ],
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
      'applied': [
        {'opId': operations.single['opId']},
      ],
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
