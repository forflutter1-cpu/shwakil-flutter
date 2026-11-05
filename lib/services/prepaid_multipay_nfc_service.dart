import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager_ndef/nfc_manager_ndef.dart';

import 'secure_storage_config.dart';

class PrepaidMultipayNfcPayload {
  const PrepaidMultipayNfcPayload({
    required this.cardNumber,
    required this.expiryMonth,
    required this.expiryYear,
    required this.label,
    required this.issuedAt,
  });

  static const String type = 'prepaid_multipay_card';
  static const String mimeType =
      'application/vnd.shwakil.prepaid-multipay-card+json';

  final String cardNumber;
  final int expiryMonth;
  final int expiryYear;
  final String label;
  final DateTime issuedAt;

  factory PrepaidMultipayNfcPayload.fromCard(Map<String, dynamic> card) {
    return PrepaidMultipayNfcPayload(
      cardNumber: (card['rawCardNumber'] ?? '').toString(),
      expiryMonth: (card['expiryMonth'] as num?)?.toInt() ?? 0,
      expiryYear: (card['expiryYear'] as num?)?.toInt() ?? 0,
      label: (card['label'] ?? '').toString(),
      issuedAt: DateTime.now().toUtc(),
    );
  }

  factory PrepaidMultipayNfcPayload.fromJson(Map<String, dynamic> json) {
    if (json['type'] != type) {
      throw const FormatException('نوع بطاقة NFC غير مدعوم.');
    }

    return PrepaidMultipayNfcPayload(
      cardNumber: (json['cardNumber'] ?? '').toString().replaceAll(
        RegExp(r'\D+'),
        '',
      ),
      expiryMonth: (json['expiryMonth'] as num?)?.toInt() ?? 0,
      expiryYear: (json['expiryYear'] as num?)?.toInt() ?? 0,
      label: (json['label'] ?? '').toString(),
      issuedAt:
          DateTime.tryParse((json['issuedAt'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': 1,
      'type': type,
      'cardNumber': cardNumber.replaceAll(RegExp(r'\D+'), ''),
      'expiryMonth': expiryMonth,
      'expiryYear': expiryYear,
      'label': label,
      'issuedAt': issuedAt.toUtc().toIso8601String(),
    };
  }
}

class PrepaidMultipayNfcPaymentAuthorization {
  const PrepaidMultipayNfcPaymentAuthorization({
    required this.signedPayload,
    required this.signature,
    required this.issuedAt,
    required this.expiresAt,
    required this.amount,
  });

  static const String type = 'prepaid_multipay_nfc_signed_payment';
  static const String mimeType =
      'application/vnd.shwakil.prepaid-multipay-nfc-payment+json';

  final String signedPayload;
  final String signature;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final double amount;

  factory PrepaidMultipayNfcPaymentAuthorization.fromJson(
    Map<String, dynamic> json,
  ) {
    if (json['type'] != type) {
      throw const FormatException('نوع إذن NFC غير مدعوم.');
    }
    final payload = (json['signedPayload'] ?? '').toString();
    final decodedPayload = jsonDecode(payload);
    final payloadMap = decodedPayload is Map
        ? Map<String, dynamic>.from(decodedPayload)
        : <String, dynamic>{};

    return PrepaidMultipayNfcPaymentAuthorization(
      signedPayload: payload,
      signature: (json['signature'] ?? '').toString(),
      issuedAt:
          DateTime.tryParse((payloadMap['issuedAt'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      expiresAt:
          DateTime.tryParse((payloadMap['expiresAt'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      amount: double.tryParse((payloadMap['amount'] ?? '0').toString()) ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': 1,
      'type': type,
      'signedPayload': signedPayload,
      'signature': signature,
    };
  }
}

sealed class PrepaidMultipayNfcReadResult {
  const PrepaidMultipayNfcReadResult();
}

class PrepaidMultipayNfcCardReadResult extends PrepaidMultipayNfcReadResult {
  const PrepaidMultipayNfcCardReadResult(this.payload);

  final PrepaidMultipayNfcPayload payload;
}

class PrepaidMultipayNfcPaymentReadResult extends PrepaidMultipayNfcReadResult {
  const PrepaidMultipayNfcPaymentReadResult(this.authorization);

  final PrepaidMultipayNfcPaymentAuthorization authorization;
}

class PrepaidMultipayNfcService {
  const PrepaidMultipayNfcService();

  static const FlutterSecureStorage _secureStorage = appSecureStorage;
  static const MethodChannel _hceChannel = MethodChannel(
    'com.alkmal.shwakil/hce',
  );
  static final Ed25519 _ed25519 = Ed25519();
  static final Uint8List _hceSelectApdu = Uint8List.fromList([
    0x00,
    0xA4,
    0x04,
    0x00,
    0x0A,
    0xA0,
    0x00,
    0x00,
    0x08,
    0x58,
    0x53,
    0x48,
    0x57,
    0x4B,
    0x01,
    0x00,
  ]);
  static const int _hceReadChunkSize = 220;

  static String _privateKeyKey(String cardId) =>
      'prepaid_multipay_nfc_private_$cardId';
  static String _publicKeyKey(String cardId) =>
      'prepaid_multipay_nfc_public_$cardId';
  static String _bindingKey(String cardId) =>
      'prepaid_multipay_nfc_binding_$cardId';

  Future<bool> isAvailable() async {
    if (kIsWeb) {
      return false;
    }

    try {
      return await NfcManager.instance.checkAvailability() ==
          NfcAvailability.enabled;
    } catch (_) {
      return false;
    }
  }

  Future<void> writeCard(PrepaidMultipayNfcPayload payload) async {
    await _ensureAvailable();

    final completer = Completer<void>();
    await NfcManager.instance.startSession(
      pollingOptions: const {NfcPollingOption.iso14443},
      onDiscovered: (tag) async {
        try {
          final ndef = Ndef.from(tag);
          if (ndef == null) {
            await _formatWritableTag(
              tag,
              message: _messageFromPayload(payload),
            );
            await NfcManager.instance.stopSession();
            if (!completer.isCompleted) {
              completer.complete();
            }
            return;
          }
          if (!ndef.isWritable) {
            throw Exception('وسم NFC غير قابل للكتابة.');
          }

          final message = _messageFromPayload(payload);
          if (ndef.maxSize > 0 && message.byteLength > ndef.maxSize) {
            throw Exception('حجم بيانات البطاقة أكبر من مساحة وسم NFC.');
          }

          await ndef.write(message: message);
          await NfcManager.instance.stopSession();
          if (!completer.isCompleted) {
            completer.complete();
          }
        } catch (error, stackTrace) {
          await NfcManager.instance.stopSession(
            errorMessageIos: error.toString(),
          );
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        }
      },
    );

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () async {
        await NfcManager.instance.stopSession(
          errorMessageIos: 'انتهت مهلة NFC.',
        );
        throw TimeoutException('انتهت مهلة NFC.');
      },
    );
  }

  Future<PrepaidMultipayNfcPayload> readCard() async {
    await _ensureAvailable();

    final completer = Completer<PrepaidMultipayNfcPayload>();
    await NfcManager.instance.startSession(
      pollingOptions: const {NfcPollingOption.iso14443},
      onDiscovered: (tag) async {
        try {
          final ndef = Ndef.from(tag);
          if (ndef == null) {
            throw Exception(_unsupportedNdefMessage);
          }

          final message = await ndef.read() ?? ndef.cachedMessage;
          if (message == null) {
            throw Exception('لا توجد بيانات بطاقة شواكل على هذا الوسم.');
          }

          final payload = _payloadFromMessage(message);
          await NfcManager.instance.stopSession();
          if (!completer.isCompleted) {
            completer.complete(payload);
          }
        } catch (error, stackTrace) {
          await NfcManager.instance.stopSession(
            errorMessageIos: error.toString(),
          );
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        }
      },
    );

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () async {
        await NfcManager.instance.stopSession(
          errorMessageIos: 'انتهت مهلة NFC.',
        );
        throw TimeoutException('انتهت مهلة NFC.');
      },
    );
  }

  Future<Map<String, String>> getOrCreateSigningKeyPair(String cardId) async {
    final privateKey = await _secureStorage.read(key: _privateKeyKey(cardId));
    final publicKey = await _secureStorage.read(key: _publicKeyKey(cardId));
    if (privateKey != null &&
        privateKey.isNotEmpty &&
        publicKey != null &&
        publicKey.isNotEmpty) {
      return {'privateKey': privateKey, 'publicKey': publicKey};
    }

    final keyPair = await _ed25519.newKeyPair();
    final keyData = await keyPair.extract();
    final generatedPrivateKey = base64Encode(keyData.bytes);
    final generatedPublicKey = base64Encode(keyData.publicKey.bytes);

    await _secureStorage.write(
      key: _privateKeyKey(cardId),
      value: generatedPrivateKey,
    );
    await _secureStorage.write(
      key: _publicKeyKey(cardId),
      value: generatedPublicKey,
    );

    return {'privateKey': generatedPrivateKey, 'publicKey': generatedPublicKey};
  }

  Future<void> deleteSigningKeyPair(String cardId) async {
    await _secureStorage.delete(key: _privateKeyKey(cardId));
    await _secureStorage.delete(key: _publicKeyKey(cardId));
    await _secureStorage.delete(key: _bindingKey(cardId));
  }

  Future<void> savePaymentBinding({
    required String cardId,
    required String deviceId,
    required String cardRef,
    int lastSequence = 0,
  }) async {
    final normalizedCardId = cardId.trim();
    final normalizedDeviceId = deviceId.trim();
    final normalizedCardRef = cardRef.trim();
    if (normalizedCardId.isEmpty ||
        normalizedDeviceId.isEmpty ||
        normalizedCardRef.isEmpty) {
      return;
    }
    final existing = await paymentBinding(normalizedCardId);
    await _secureStorage.write(
      key: _bindingKey(normalizedCardId),
      value: jsonEncode({
        'deviceId': normalizedDeviceId,
        'cardRef': normalizedCardRef,
        'lastSequence': max(
          lastSequence,
          (existing?['lastSequence'] as num?)?.toInt() ?? 0,
        ),
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }

  Future<Map<String, dynamic>?> paymentBinding(String cardId) async {
    final raw = await _secureStorage.read(key: _bindingKey(cardId.trim()));
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      final cardRef = decoded['cardRef']?.toString().trim() ?? '';
      final deviceId = decoded['deviceId']?.toString().trim() ?? '';
      if (cardRef.isEmpty || deviceId.isEmpty) {
        return null;
      }
      return {
        'cardRef': cardRef,
        'deviceId': deviceId,
        'lastSequence': (decoded['lastSequence'] as num?)?.toInt() ?? 0,
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> rememberPaymentSequence({
    required String cardId,
    required int sequence,
  }) async {
    final binding = await paymentBinding(cardId);
    if (binding == null) {
      return;
    }
    await savePaymentBinding(
      cardId: cardId,
      deviceId: binding['deviceId']?.toString() ?? '',
      cardRef: binding['cardRef']?.toString() ?? '',
      lastSequence: sequence,
    );
  }

  Future<PrepaidMultipayNfcPaymentAuthorization>
  buildOfflinePaymentAuthorization({
    required String cardId,
    required double amount,
    String merchantId = '',
    String appVersion = '',
  }) async {
    final binding = await paymentBinding(cardId);
    if (binding == null) {
      throw Exception(
        'يجب تجهيز الجهاز للدفع بدون تلامس مرة واحدة أثناء الاتصال بالإنترنت.',
      );
    }

    final sequence = ((binding['lastSequence'] as num?)?.toInt() ?? 0) + 1;
    final issuedAt = DateTime.now().toUtc();
    final expiresAt = issuedAt.add(const Duration(seconds: 60));
    final authorization = await signAuthorization(
      cardId: cardId,
      authorization: {
        'version': 1,
        'type': 'prepaid_multipay_nfc_payment',
        'cardRef': binding['cardRef']?.toString() ?? '',
        'deviceId': binding['deviceId']?.toString() ?? '',
        'merchantId': merchantId.trim(),
        'amount': amount.toStringAsFixed(2),
        'currency': 'ILS',
        'nonce': _randomHex(16),
        'sequence': sequence,
        'issuedAt': issuedAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
        'appVersion': appVersion.trim(),
        'offlinePrepared': true,
      },
    );
    await rememberPaymentSequence(cardId: cardId, sequence: sequence);
    return authorization;
  }

  Future<PrepaidMultipayNfcPaymentAuthorization> signAuthorization({
    required String cardId,
    required Map<String, dynamic> authorization,
  }) async {
    final keyPair = await _keyPairForCard(cardId);
    final signedPayload = jsonEncode(_canonicalize(authorization));
    final signature = await _ed25519.sign(
      utf8.encode(signedPayload),
      keyPair: keyPair,
    );
    final payload = jsonDecode(signedPayload) as Map<String, dynamic>;

    return PrepaidMultipayNfcPaymentAuthorization(
      signedPayload: signedPayload,
      signature: base64Encode(signature.bytes),
      issuedAt:
          DateTime.tryParse((payload['issuedAt'] ?? '').toString()) ??
          DateTime.now().toUtc(),
      expiresAt:
          DateTime.tryParse((payload['expiresAt'] ?? '').toString()) ??
          DateTime.now().toUtc(),
      amount: double.tryParse((payload['amount'] ?? '0').toString()) ?? 0,
    );
  }

  Future<void> writePaymentAuthorization(
    PrepaidMultipayNfcPaymentAuthorization authorization,
  ) async {
    await _ensureAvailable();

    final completer = Completer<void>();
    await NfcManager.instance.startSession(
      pollingOptions: const {NfcPollingOption.iso14443},
      onDiscovered: (tag) async {
        try {
          final ndef = Ndef.from(tag);
          if (ndef == null) {
            await _formatWritableTag(
              tag,
              message: _paymentMessageFromAuthorization(authorization),
            );
            await NfcManager.instance.stopSession();
            if (!completer.isCompleted) {
              completer.complete();
            }
            return;
          }
          if (!ndef.isWritable) {
            throw Exception('وسم NFC غير قابل للكتابة.');
          }

          final message = _paymentMessageFromAuthorization(authorization);
          if (ndef.maxSize > 0 && message.byteLength > ndef.maxSize) {
            throw Exception('حجم إذن الدفع أكبر من مساحة وسم NFC.');
          }

          await ndef.write(message: message);
          await NfcManager.instance.stopSession();
          if (!completer.isCompleted) {
            completer.complete();
          }
        } catch (error, stackTrace) {
          await NfcManager.instance.stopSession(
            errorMessageIos: error.toString(),
          );
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        }
      },
    );

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () async {
        await NfcManager.instance.stopSession(
          errorMessageIos: 'انتهت مهلة NFC.',
        );
        throw TimeoutException('انتهت مهلة NFC.');
      },
    );
  }

  Future<void> publishHcePaymentAuthorization(
    PrepaidMultipayNfcPaymentAuthorization authorization,
  ) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw Exception('دفع NFC بدون وسم مدعوم على Android فقط.');
    }

    final expiresAtMillis = authorization.expiresAt
        .toUtc()
        .millisecondsSinceEpoch;
    if (DateTime.now().toUtc().millisecondsSinceEpoch >= expiresAtMillis) {
      throw Exception('انتهت صلاحية إذن NFC.');
    }

    await _hceChannel.invokeMethod<bool>('setPaymentPayload', {
      'payload': jsonEncode(authorization.toJson()),
      'expiresAtMillis': expiresAtMillis,
    });
  }

  Future<void> clearHcePaymentAuthorization() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    await _hceChannel.invokeMethod<bool>('clearPaymentPayload');
  }

  Future<PrepaidMultipayNfcPaymentAuthorization>
  readPaymentAuthorization() async {
    await _ensureAvailable();

    final completer = Completer<PrepaidMultipayNfcPaymentAuthorization>();
    await NfcManager.instance.startSession(
      pollingOptions: const {NfcPollingOption.iso14443},
      onDiscovered: (tag) async {
        try {
          final ndef = Ndef.from(tag);
          if (ndef == null) {
            throw Exception(_unsupportedNdefMessage);
          }

          final message = await ndef.read() ?? ndef.cachedMessage;
          if (message == null) {
            throw Exception('لا يوجد إذن دفع شواكل على هذا الوسم.');
          }

          final authorization = _paymentAuthorizationFromMessage(message);
          await NfcManager.instance.stopSession();
          if (!completer.isCompleted) {
            completer.complete(authorization);
          }
        } catch (error, stackTrace) {
          await NfcManager.instance.stopSession(
            errorMessageIos: error.toString(),
          );
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        }
      },
    );

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () async {
        await NfcManager.instance.stopSession(
          errorMessageIos: 'انتهت مهلة NFC.',
        );
        throw TimeoutException('انتهت مهلة NFC.');
      },
    );
  }

  Future<PrepaidMultipayNfcReadResult> readAny() async {
    await _ensureAvailable();

    final completer = Completer<PrepaidMultipayNfcReadResult>();
    await NfcManager.instance.startSession(
      pollingOptions: const {NfcPollingOption.iso14443},
      onDiscovered: (tag) async {
        try {
          final ndef = Ndef.from(tag);
          if (ndef == null) {
            final hceAuthorization = await _tryReadHcePaymentAuthorization(tag);
            if (hceAuthorization != null) {
              await NfcManager.instance.stopSession();
              if (!completer.isCompleted) {
                completer.complete(
                  PrepaidMultipayNfcPaymentReadResult(hceAuthorization),
                );
              }
              return;
            }

            throw Exception(_unsupportedNdefMessage);
          }

          final message = await ndef.read() ?? ndef.cachedMessage;
          if (message == null) {
            throw Exception(
              'لا توجد بيانات شواكل قابلة للقراءة على هذا الوسم.',
            );
          }

          final result = _readResultFromMessage(message);
          await NfcManager.instance.stopSession();
          if (!completer.isCompleted) {
            completer.complete(result);
          }
        } catch (error, stackTrace) {
          await NfcManager.instance.stopSession(
            errorMessageIos: error.toString(),
          );
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        }
      },
    );

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () async {
        await NfcManager.instance.stopSession(
          errorMessageIos: 'انتهت مهلة NFC.',
        );
        throw TimeoutException('انتهت مهلة NFC.');
      },
    );
  }

  Future<void> _ensureAvailable() async {
    if (!await isAvailable()) {
      throw Exception('NFC غير متاح أو غير مفعل على هذا الجهاز.');
    }
  }

  Future<PrepaidMultipayNfcPaymentAuthorization?>
  _tryReadHcePaymentAuthorization(NfcTag tag) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }

    final isoDep = IsoDepAndroid.from(tag);
    if (isoDep == null) {
      return null;
    }

    await isoDep.setTimeout(5000);
    final selectResponse = await isoDep.transceive(_hceSelectApdu);
    if (!_isSuccessStatus(selectResponse)) {
      return null;
    }

    final bytes = <int>[];
    var offset = 0;
    while (true) {
      final readApdu = Uint8List.fromList([
        0x80,
        0xCA,
        (offset >> 8) & 0xff,
        offset & 0xff,
        _hceReadChunkSize,
      ]);
      final response = await isoDep.transceive(readApdu);
      if (!_isSuccessStatus(response)) {
        return null;
      }
      final chunk = response.sublist(0, response.length - 2);
      if (chunk.isEmpty) {
        break;
      }
      bytes.addAll(chunk);
      offset += chunk.length;
      if (chunk.length < _hceReadChunkSize) {
        break;
      }
    }

    if (bytes.isEmpty) {
      return null;
    }

    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      return null;
    }
    return PrepaidMultipayNfcPaymentAuthorization.fromJson(
      Map<String, dynamic>.from(decoded),
    );
  }

  bool _isSuccessStatus(Uint8List response) {
    return response.length >= 2 &&
        response[response.length - 2] == 0x90 &&
        response[response.length - 1] == 0x00;
  }

  Future<void> _formatWritableTag(
    NfcTag tag, {
    required NdefMessage message,
  }) async {
    final formatable = NdefFormatableAndroid.from(tag);
    if (formatable == null) {
      throw Exception(
        'هذا الوسم لا يدعم NDEF ولا يمكن تهيئته تلقائيًا. استخدم وسم NTAG213 أو NTAG215 أو NTAG216 قابل للكتابة.',
      );
    }

    await formatable.format(message);
  }

  static const String _unsupportedNdefMessage =
      'لم يتم العثور على بيانات شواكل قابلة للقراءة على هذا الوسم. إذا كان الوسم جديدًا فاكتب بيانات البطاقة عليه من شاشة البطاقة أولًا، واستخدم وسم NTAG213 أو NTAG215 أو NTAG216.';

  NdefMessage _messageFromPayload(PrepaidMultipayNfcPayload payload) {
    final jsonPayload = jsonEncode(payload.toJson());
    return NdefMessage(
      records: [
        NdefRecord(
          typeNameFormat: TypeNameFormat.media,
          type: Uint8List.fromList(
            utf8.encode(PrepaidMultipayNfcPayload.mimeType),
          ),
          identifier: Uint8List(0),
          payload: Uint8List.fromList(utf8.encode(jsonPayload)),
        ),
      ],
    );
  }

  NdefMessage _paymentMessageFromAuthorization(
    PrepaidMultipayNfcPaymentAuthorization authorization,
  ) {
    final jsonPayload = jsonEncode(authorization.toJson());
    return NdefMessage(
      records: [
        NdefRecord(
          typeNameFormat: TypeNameFormat.media,
          type: Uint8List.fromList(
            utf8.encode(PrepaidMultipayNfcPaymentAuthorization.mimeType),
          ),
          identifier: Uint8List(0),
          payload: Uint8List.fromList(utf8.encode(jsonPayload)),
        ),
      ],
    );
  }

  PrepaidMultipayNfcPayload _payloadFromMessage(NdefMessage message) {
    for (final record in message.records) {
      final type = utf8.decode(record.type, allowMalformed: true);
      if (record.typeNameFormat != TypeNameFormat.media ||
          type != PrepaidMultipayNfcPayload.mimeType) {
        continue;
      }

      final decoded = jsonDecode(utf8.decode(record.payload));
      if (decoded is Map) {
        return PrepaidMultipayNfcPayload.fromJson(
          Map<String, dynamic>.from(decoded),
        );
      }
    }

    throw const FormatException('لم يتم العثور على بطاقة شواكل NFC صالحة.');
  }

  PrepaidMultipayNfcPaymentAuthorization _paymentAuthorizationFromMessage(
    NdefMessage message,
  ) {
    for (final record in message.records) {
      final type = utf8.decode(record.type, allowMalformed: true);
      if (record.typeNameFormat != TypeNameFormat.media ||
          type != PrepaidMultipayNfcPaymentAuthorization.mimeType) {
        continue;
      }

      final decoded = jsonDecode(utf8.decode(record.payload));
      if (decoded is Map) {
        return PrepaidMultipayNfcPaymentAuthorization.fromJson(
          Map<String, dynamic>.from(decoded),
        );
      }
    }

    throw const FormatException('لم يتم العثور على إذن دفع NFC صالح.');
  }

  PrepaidMultipayNfcReadResult _readResultFromMessage(NdefMessage message) {
    for (final record in message.records) {
      final type = utf8.decode(record.type, allowMalformed: true);
      if (record.typeNameFormat != TypeNameFormat.media) {
        continue;
      }
      if (type != PrepaidMultipayNfcPayload.mimeType &&
          type != PrepaidMultipayNfcPaymentAuthorization.mimeType) {
        continue;
      }

      final decoded = jsonDecode(utf8.decode(record.payload));
      if (decoded is! Map) {
        continue;
      }
      final map = Map<String, dynamic>.from(decoded);
      if (type == PrepaidMultipayNfcPayload.mimeType) {
        return PrepaidMultipayNfcCardReadResult(
          PrepaidMultipayNfcPayload.fromJson(map),
        );
      }
      if (type == PrepaidMultipayNfcPaymentAuthorization.mimeType) {
        return PrepaidMultipayNfcPaymentReadResult(
          PrepaidMultipayNfcPaymentAuthorization.fromJson(map),
        );
      }
    }

    throw const FormatException(
      'تمت قراءة الوسم، لكن بياناته ليست بطاقة أو إذن دفع صالح داخل شواكل.',
    );
  }

  Future<SimpleKeyPairData> _keyPairForCard(String cardId) async {
    final keys = await getOrCreateSigningKeyPair(cardId);
    final publicBytes = base64Decode(keys['publicKey'] ?? '');
    final privateBytes = base64Decode(keys['privateKey'] ?? '');
    return SimpleKeyPairData(
      privateBytes,
      publicKey: SimplePublicKey(publicBytes, type: KeyPairType.ed25519),
      type: KeyPairType.ed25519,
    );
  }

  Map<String, dynamic> _canonicalize(Map<String, dynamic> value) {
    final sortedKeys = value.keys.map((key) => key.toString()).toList()..sort();
    return {
      for (final key in sortedKeys)
        key: value[key] is Map<String, dynamic>
            ? _canonicalize(Map<String, dynamic>.from(value[key] as Map))
            : value[key],
    };
  }

  String _randomHex(int byteCount) {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < byteCount; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
