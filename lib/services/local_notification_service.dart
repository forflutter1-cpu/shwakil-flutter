import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../localization/app_localization.dart';
import '../localization/app_strings_ar.dart';
import '../localization/app_strings_en.dart';
import '../utils/app_theme.dart';
import 'notification_navigation_service.dart';

class LocalNotificationService {
  LocalNotificationService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static bool _permissionsRequested = false;

  static bool get _supportsLocalNotifications =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  static Future<void> initialize() async {
    if (_initialized || kIsWeb || !_supportsLocalNotifications) {
      return;
    }

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
      macOS: DarwinInitializationSettings(),
    );

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {
        unawaited(
          NotificationNavigationService.openFromLocalNotificationPayload(
            response.payload,
          ),
        );
      },
    );

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.createNotificationChannel(
      AndroidNotificationChannel(
        'account_updates',
        _tr('services_local_notification_service.001'),
        description: _tr('services_local_notification_service.002'),
        importance: Importance.max,
      ),
    );
    await androidPlugin?.createNotificationChannel(
      AndroidNotificationChannel(
        'balance_updates',
        _tr('services_local_notification_service.003'),
        description: _tr('services_local_notification_service.004'),
        importance: Importance.max,
      ),
    );
    _initialized = true;
  }

  static Future<void> ensurePermissionsRequested() async {
    if (_permissionsRequested || kIsWeb || !_supportsLocalNotifications) {
      return;
    }
    await initialize();

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.requestNotificationsPermission();

    final iosPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    await iosPlugin?.requestPermissions(alert: true, badge: true, sound: true);

    final macosPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >();
    await macosPlugin?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );

    _permissionsRequested = true;
  }

  static Future<void> showBalanceChange({
    required String title,
    required String body,
    bool isCredit = true,
  }) async {
    if (kIsWeb || !_supportsLocalNotifications) {
      return;
    }

    await initialize();
    await ensurePermissionsRequested();

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'balance_updates',
        _tr('services_local_notification_service.003'),
        channelDescription: _tr('services_local_notification_service.004'),
        importance: Importance.max,
        priority: Priority.high,
        color: isCredit ? AppTheme.success : AppTheme.error,
      ),
      iOS: const DarwinNotificationDetails(),
      macOS: const DarwinNotificationDetails(),
    );

    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
    );
  }

  static Future<void> showPushNotification({
    required String title,
    required String body,
    String channelId = 'account_updates',
    String? channelName,
    Map<String, dynamic>? payload,
  }) async {
    if (kIsWeb || !_supportsLocalNotifications) {
      return;
    }

    await initialize();
    await ensurePermissionsRequested();

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName ?? _tr('services_local_notification_service.001'),
        channelDescription: _tr('services_local_notification_service.002'),
        importance: Importance.max,
        priority: Priority.high,
        color: AppTheme.primary,
      ),
      iOS: const DarwinNotificationDetails(),
      macOS: const DarwinNotificationDetails(),
    );

    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
      payload: payload == null ? null : jsonEncode(payload),
    );
  }

  static String _tr(String key) {
    final current = AppLocaleService.instance.locale;
    if ((current?.languageCode ?? 'ar') == 'en') {
      return appStringsEn[key] ?? key;
    }
    return appStringsAr[key] ?? appStringsEn[key] ?? key;
  }
}
