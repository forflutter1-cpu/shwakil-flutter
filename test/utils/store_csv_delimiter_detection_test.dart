import 'package:flutter_test/flutter_test.dart';
import 'package:virtual_currency_cards/utils/store_csv_delimiter_detection.dart';

void main() {
  test(
    'uses recognized headers when report text and prices contain commas',
    () {
      const lines = [
        'Store,Sales,Report,2026',
        'Branch,Hebron,Generated,Today',
        'Item;Quantity;Unit Price',
        'Soap;2;4,50',
        'Powder;1;7,25',
      ];

      final delimiter = StoreCsvDelimiterDetection.choose(
        sampleLines: lines,
        fallback: ',',
        parseLine: (line, separator) => line.split(separator),
        scoreHeader: (fields) => fields
            .where(
              (field) => ['Item', 'Quantity', 'Unit Price'].contains(field),
            )
            .length,
      );

      expect(delimiter, ';');
    },
  );

  test(
    'uses the existing fallback when no candidate contains known headers',
    () {
      expect(
        StoreCsvDelimiterDetection.choose(
          sampleLines: const ['plain text', 'more plain text'],
          fallback: '\t',
          parseLine: (line, separator) => line.split(separator),
          scoreHeader: (_) => 0,
        ),
        '\t',
      );
    },
  );

  test('finds a table delimiter when headings are unfamiliar', () {
    const lines = [
      'Store,Sales,Report,2026',
      'Branch,Hebron,Generated,Today',
      'Document code;Material;Count;Unit value',
      '101;Soap;2;4,50',
      '102;Powder;1;7,25',
    ];

    expect(
      StoreCsvDelimiterDetection.choose(
        sampleLines: lines,
        fallback: ',',
        parseLine: (line, separator) => line.split(separator),
        scoreHeader: (_) => 0,
      ),
      ';',
    );
  });
}
