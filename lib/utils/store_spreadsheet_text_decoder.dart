import 'dart:convert';

import 'package:enough_convert/windows.dart';

class StoreSpreadsheetTextDecoder {
  const StoreSpreadsheetTextDecoder._();

  static const _windows1256 = Windows1256Codec(allowInvalid: true);

  static String decode(
    List<int> bytes, {
    int Function(String text)? scoreText,
  }) {
    if (bytes.isEmpty) return '';

    if (_startsWith(bytes, const [0xff, 0xfe])) {
      return _decodeUtf16(bytes, offset: 2, littleEndian: true);
    }
    if (_startsWith(bytes, const [0xfe, 0xff])) {
      return _decodeUtf16(bytes, offset: 2, littleEndian: false);
    }

    final utf16LittleEndian = _detectUtf16Endian(bytes);
    if (utf16LittleEndian != null) {
      return _decodeUtf16(
        bytes,
        littleEndian: utf16LittleEndian,
      ).replaceFirst('\uFEFF', '');
    }

    final utf8Offset = _startsWith(bytes, const [0xef, 0xbb, 0xbf]) ? 3 : 0;
    String? utf8Text;
    try {
      utf8Text = utf8.decode(bytes.skip(utf8Offset).toList());
    } on FormatException {
      // Legacy Arabic CSV exports commonly use Windows-1256 without a BOM.
    }

    if (utf8Text == null) {
      return _windows1256.decode(bytes.skip(utf8Offset).toList());
    }

    final windows1256Text = _windows1256.decode(bytes);
    if (scoreText != null && scoreText(windows1256Text) > scoreText(utf8Text)) {
      return windows1256Text;
    }
    return utf8Text;
  }

  static bool _startsWith(List<int> bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var index = 0; index < prefix.length; index++) {
      if (bytes[index] != prefix[index]) return false;
    }
    return true;
  }

  static bool? _detectUtf16Endian(List<int> bytes) {
    final pairCount = bytes.length ~/ 2;
    if (pairCount < 4) return null;
    final sampleCount = pairCount > 512 ? 512 : pairCount;
    var evenLowByteCount = 0;
    var oddLowByteCount = 0;
    for (var pair = 0; pair < sampleCount; pair++) {
      if (bytes[pair * 2] <= 0x07) evenLowByteCount++;
      if (bytes[pair * 2 + 1] <= 0x07) oddLowByteCount++;
    }
    final enoughEvenLowBytes = evenLowByteCount * 100 >= sampleCount * 35;
    final enoughOddLowBytes = oddLowByteCount * 100 >= sampleCount * 35;
    if (enoughOddLowBytes && oddLowByteCount > evenLowByteCount) return true;
    if (enoughEvenLowBytes && evenLowByteCount > oddLowByteCount) return false;
    return null;
  }

  static String _decodeUtf16(
    List<int> bytes, {
    int offset = 0,
    required bool littleEndian,
  }) {
    final unitCount = (bytes.length - offset) ~/ 2;
    final units = List<int>.generate(unitCount, (index) {
      final first = bytes[offset + index * 2];
      final second = bytes[offset + index * 2 + 1];
      return littleEndian ? first | (second << 8) : (first << 8) | second;
    });
    return String.fromCharCodes(units);
  }
}
