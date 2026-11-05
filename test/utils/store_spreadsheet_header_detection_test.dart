import 'package:flutter_test/flutter_test.dart';
import 'package:virtual_currency_cards/utils/store_spreadsheet_header_detection.dart';

void main() {
  test('finds headers after report title and blank rows', () {
    final rows = [
      ['تقرير حركة المبيعات'],
      ['', '', ''],
      ['رقم الفاتورة', 'اسم الصنف', 'الكمية', 'سعر الوحدة'],
      ['101', 'صنف', '2', '4.5'],
    ];

    final index = StoreSpreadsheetHeaderDetection.findBestHeaderRow(
      rows: rows,
      score: (row) => row
          .where(
            (value) => [
              'رقم الفاتورة',
              'اسم الصنف',
              'الكمية',
              'سعر الوحدة',
            ].contains(value),
          )
          .length,
    );

    expect(index, 2);
  });

  test('keeps the earliest row when matching header scores are tied', () {
    final rows = [
      ['name', 'price'],
      ['another', 'row'],
      ['name', 'price'],
    ];

    expect(
      StoreSpreadsheetHeaderDetection.findBestHeaderRow(
        rows: rows,
        score: (row) =>
            row.where((value) => ['name', 'price'].contains(value)).length,
      ),
      0,
    );
  });

  test('uses the widest first row when all header names are unfamiliar', () {
    final rows = [
      ['Sales report'],
      ['', '', ''],
      ['Document code', 'Material', 'Count', 'Unit value'],
      ['101', 'Soap', '2', '4.50'],
    ];

    expect(
      StoreSpreadsheetHeaderDetection.findBestHeaderRow(
        rows: rows,
        score: (_) => 0,
      ),
      2,
    );
  });

  test('limits header detection to the configured leading rows', () {
    final rows = [
      ['title'],
      ['detail'],
      ['name', 'price'],
    ];

    expect(
      StoreSpreadsheetHeaderDetection.findBestHeaderRow(
        rows: rows,
        maxRowsToScan: 2,
        score: (row) =>
            row.where((value) => ['name', 'price'].contains(value)).length,
      ),
      0,
    );
  });
}
