import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:virtual_currency_cards/services/prepaid_multipay_nfc_queue_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const service = PrepaidMultipayNfcQueueService();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'new signed payment queue is stored outside SharedPreferences',
    () async {
      final operation = _operation('payment-1');
      await service.enqueue('merchant-1', operation);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('prepaid_multipay_nfc_merchant_queue_v1_merchant-1'),
        isNull,
      );
      expect(await service.getPending('merchant-1'), equals([operation]));
    },
  );

  test(
    'migrates a scoped legacy queue before removing its plaintext copy',
    () async {
      SharedPreferences.setMockInitialValues({
        'prepaid_multipay_nfc_merchant_queue_v1_merchant-1': jsonEncode([
          _operation('legacy-payment'),
        ]),
      });

      expect(
        await service.getPending('merchant-1'),
        equals([_operation('legacy-payment')]),
      );

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('prepaid_multipay_nfc_merchant_queue_v1_merchant-1'),
        isNull,
      );
      expect(await service.getPending('merchant-1'), hasLength(1));
    },
  );

  test('keeps queues isolated between merchant accounts', () async {
    await service.enqueue('merchant-1', _operation('payment-1'));

    expect(await service.getPending('merchant-2'), isEmpty);
    expect(await service.getPending('merchant-1'), hasLength(1));
  });

  test('serializes simultaneous offline payment writes', () async {
    await Future.wait<void>([
      service.enqueue('merchant-1', _operation('payment-1')),
      service.enqueue('merchant-1', _operation('payment-2')),
    ]);

    final queue = await service.getPending('merchant-1');
    expect(queue.map((item) => item['idempotencyKey']).toSet(), {
      'payment-1',
      'payment-2',
    });
  });

  test('removes synced payments while retaining failed ones', () async {
    await service.enqueue('merchant-1', _operation('payment-1'));
    await service.enqueue('merchant-1', _operation('payment-2'));

    await service.removeSynced('merchant-1', {'payment-1'});

    final queue = await service.getPending('merchant-1');
    expect(queue, hasLength(1));
    expect(queue.single['idempotencyKey'], 'payment-2');
  });
}

Map<String, dynamic> _operation(String idempotencyKey) => {
  'signedPayload': '{"type":"prepaid_multipay_nfc_payment"}',
  'signature': 'test-signature',
  'idempotencyKey': idempotencyKey,
  'merchantDeviceId': 'device-test',
  'acceptedAt': '2026-11-05T12:00:00Z',
};
