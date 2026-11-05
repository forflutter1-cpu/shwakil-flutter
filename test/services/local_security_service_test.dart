import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:virtual_currency_cards/services/local_security_service.dart';
import 'package:virtual_currency_cards/services/notification_navigation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage = FlutterSecureStorage();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await LocalSecurityService.clearTrustedState();
  });

  test('a configured local lock cannot be skipped when relock is required', () {
    expect(
      LocalSecurityService.mustUnlockBeforeContinuing(
        hasLocalSecurity: true,
        relockRequired: true,
      ),
      isTrue,
    );
    expect(
      LocalSecurityService.mustUnlockBeforeContinuing(
        hasLocalSecurity: false,
        relockRequired: true,
      ),
      isFalse,
    );
    expect(
      LocalSecurityService.mustUnlockBeforeContinuing(
        hasLocalSecurity: true,
        relockRequired: false,
      ),
      isFalse,
    );
  });

  test(
    'stores a salted PBKDF2 PIN and accepts normalized Arabic digits',
    () async {
      await LocalSecurityService.savePin('١٢٣٤');

      final stored = await secureStorage.read(key: 'device_pin_hash');
      expect(stored, isNotNull);
      expect(stored, startsWith(r'pbkdf2-sha256$210000$'));
      expect(stored!.split(r'$'), hasLength(4));
      expect(stored, isNot(contains('1234')));

      expect(await LocalSecurityService.verifyPin('1234'), isTrue);
      expect(await LocalSecurityService.verifyPin('9999'), isFalse);
    },
  );

  test('migrates a valid legacy SHA-256 PIN hash after verification', () async {
    final legacyHash = await _legacyHash('1234');
    FlutterSecureStorage.setMockInitialValues({'device_pin_hash': legacyHash});

    expect(await LocalSecurityService.verifyPin('1234'), isTrue);

    final migrated = await secureStorage.read(key: 'device_pin_hash');
    expect(migrated, startsWith(r'pbkdf2-sha256$210000$'));
    expect(migrated, isNot(legacyHash));
  });

  test(
    'migrates the legacy plaintext preference without losing the PIN',
    () async {
      SharedPreferences.setMockInitialValues({'device_pin': '1234'});

      expect(await LocalSecurityService.hasPin(), isTrue);
      expect(await LocalSecurityService.verifyPin('1234'), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('device_pin'), isFalse);
      expect(
        await secureStorage.read(key: 'device_pin_hash'),
        startsWith(r'pbkdf2-sha256$210000$'),
      );
    },
  );

  test('locks PIN verification for one minute after five failures', () async {
    FlutterSecureStorage.setMockInitialValues({
      'device_pin_hash': await _legacyHash('1234'),
    });

    for (var attempt = 0; attempt < 5; attempt++) {
      expect(await LocalSecurityService.verifyPin('0000'), isFalse);
    }

    expect(
      await LocalSecurityService.pinRetryAfterSeconds(),
      inInclusiveRange(59, 60),
    );
    expect(await LocalSecurityService.verifyPin('1234'), isFalse);
  });

  test('requires relock on a fresh launch for a trusted PIN device', () async {
    await LocalSecurityService.savePin('1234');
    await LocalSecurityService.markDeviceTrusted('trusted-user');
    await LocalSecurityService.clearRelockRequirement();

    await LocalSecurityService.syncRelockStateForLaunch();

    expect(LocalSecurityService.relockRequired, isTrue);
    expect(LocalSecurityService.securitySetupRequired, isFalse);
  });

  test(
    'requires relock when local PIN exists but trust marker is absent',
    () async {
      await LocalSecurityService.savePin('1234');
      await LocalSecurityService.clearRelockRequirement();

      await LocalSecurityService.syncRelockStateForLaunch();

      expect(LocalSecurityService.relockRequired, isTrue);
    },
  );

  test(
    'does not force security setup on an unsecured trusted device',
    () async {
      await LocalSecurityService.markDeviceTrusted('trusted-user');
      await LocalSecurityService.clearRelockRequirement();

      await LocalSecurityService.syncRelockStateForLaunch();

      expect(LocalSecurityService.relockRequired, isFalse);
      expect(LocalSecurityService.securitySetupRequired, isFalse);
    },
  );

  test(
    'notification navigation selects the correct local security gate',
    () async {
      expect(
        NotificationNavigationService.requiredLocalSecurityRoute(),
        isNull,
      );

      await LocalSecurityService.markDeviceTrusted('trusted-user');
      await LocalSecurityService.syncRelockStateForLaunch();
      expect(
        NotificationNavigationService.requiredLocalSecurityRoute(),
        isNull,
      );

      await LocalSecurityService.clearTrustedState();
      await LocalSecurityService.savePin('1234');
      await LocalSecurityService.markDeviceTrusted('trusted-user');
      await LocalSecurityService.syncRelockStateForLaunch();
      expect(
        NotificationNavigationService.requiredLocalSecurityRoute(),
        '/unlock',
      );
    },
  );

  test('does not relock again immediately after a completed unlock', () async {
    await LocalSecurityService.savePin('1234');
    await LocalSecurityService.markDeviceTrusted('trusted-user');
    await LocalSecurityService.markLocalUnlockCompleted();

    await LocalSecurityService.syncRelockStateForLaunch();

    expect(LocalSecurityService.relockRequired, isFalse);
  });
}

Future<String> _legacyHash(String pin) async {
  final digest = await Sha256().hash(utf8.encode(pin));
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}
