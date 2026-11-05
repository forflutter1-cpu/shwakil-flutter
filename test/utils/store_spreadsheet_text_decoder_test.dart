import 'dart:convert';

import 'package:enough_convert/windows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:virtual_currency_cards/utils/store_spreadsheet_text_decoder.dart';

void main() {
  test('decodes Windows-1256 when it gives a better Arabic header match', () {
    const csv = 'اسم الصنف;الكمية;السعر الإفرادي\nحليب;2;4,50';
    final bytes = const Windows1256Codec().encode(csv);

    final decoded = StoreSpreadsheetTextDecoder.decode(
      bytes,
      scoreText: (text) => text.contains('اسم الصنف') ? 3 : 0,
    );

    expect(decoded, csv);
  });

  test('decodes UTF-8 with a BOM', () {
    const csv = 'اسم الصنف,الكمية\nحليب,2';
    final bytes = [0xef, 0xbb, 0xbf, ...utf8.encode(csv)];

    expect(StoreSpreadsheetTextDecoder.decode(bytes), csv);
  });

  test('decodes UTF-16 little endian with and without a BOM', () {
    const csv = 'اسم الصنف,الكمية\nحليب,2';
    final units = csv.codeUnits;
    final littleEndian = units.expand((unit) => [unit & 0xff, unit >> 8]);

    expect(
      StoreSpreadsheetTextDecoder.decode([0xff, 0xfe, ...littleEndian]),
      csv,
    );
    expect(StoreSpreadsheetTextDecoder.decode(littleEndian.toList()), csv);
  });

  test('decodes UTF-16 big endian with and without a BOM', () {
    const csv = 'اسم الصنف,الكمية\nحليب,2';
    final units = csv.codeUnits;
    final bigEndian = units.expand((unit) => [unit >> 8, unit & 0xff]);

    expect(StoreSpreadsheetTextDecoder.decode([0xfe, 0xff, ...bigEndian]), csv);
    expect(StoreSpreadsheetTextDecoder.decode(bigEndian.toList()), csv);
  });
}
