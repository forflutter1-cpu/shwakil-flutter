import 'package:flutter_test/flutter_test.dart';
import 'package:virtual_currency_cards/utils/store_import_header_normalizer.dart';

void main() {
  test('normalizes Arabic diacritics, hamza, taa marbuta and separators', () {
    expect(
      StoreImportHeaderNormalizer.normalize('\uFEFF  السِّعْر الإفرادي '),
      'السعر_الافرادي',
    );
    expect(
      StoreImportHeaderNormalizer.normalize('الوحدة الأساسيّة'),
      'الوحده_الاساسيه',
    );
  });

  test('matches aliases after the same normalization', () {
    final header = StoreImportHeaderNormalizer.normalize('تاريخ الفاتوره');

    expect(
      StoreImportHeaderNormalizer.matchesAny(header, [
        'تاريخ_الفاتورة',
        'invoice_date',
      ]),
      isTrue,
    );
  });
}
