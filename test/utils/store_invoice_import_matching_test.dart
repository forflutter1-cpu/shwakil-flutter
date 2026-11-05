import 'package:flutter_test/flutter_test.dart';
import 'package:virtual_currency_cards/utils/store_invoice_import_matching.dart';

String normalize(String value) => value.trim().toLowerCase();

void main() {
  test('invoice duplicate identity includes the invoice type', () {
    final existing = [
      {'type': 'sale', 'invoiceNumber': ' 105 '},
    ];

    expect(
      StoreInvoiceImportMatching.hasDuplicateInvoice(
        existingInvoices: existing,
        type: 'purchase',
        invoiceNumber: '105',
        normalize: normalize,
      ),
      isFalse,
    );
    expect(
      StoreInvoiceImportMatching.hasDuplicateInvoice(
        existingInvoices: existing,
        type: 'sale',
        invoiceNumber: '105',
        normalize: normalize,
      ),
      isTrue,
    );
  });

  test('unknown imported unit is rejected instead of using the base unit', () {
    final units = [
      {'clientRef': 'case-ref', 'name': 'كرتونة', 'code': 'case'},
      {
        'clientRef': 'piece-ref',
        'name': 'حبة',
        'code': 'piece',
        'isBase': true,
      },
    ];

    expect(
      StoreInvoiceImportMatching.resolveUnit(
        units: units,
        normalize: normalize,
        name: 'صندوق',
      ),
      isNull,
    );
  });

  test('unit hints resolve by name and missing hints choose the base unit', () {
    final baseUnit = <String, dynamic>{
      'clientRef': 'piece-ref',
      'name': 'حبة',
      'code': 'piece',
      'isBase': true,
    };
    final packageUnit = <String, dynamic>{
      'clientRef': 'case-ref',
      'name': 'كرتونة',
      'code': 'case',
    };
    final units = [packageUnit, baseUnit];

    expect(
      StoreInvoiceImportMatching.resolveUnit(
        units: units,
        normalize: normalize,
        clientRef: 'missing-ref',
        name: 'كرتونة',
      ),
      same(packageUnit),
    );
    expect(
      StoreInvoiceImportMatching.resolveUnit(
        units: units,
        normalize: normalize,
      ),
      same(baseUnit),
    );
  });
}
