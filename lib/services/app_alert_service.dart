import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../localization/app_localization.dart';
import '../localization/app_strings_ar.dart';
import '../localization/app_strings_en.dart';
import '../utils/app_theme.dart';
import 'app_config.dart';
import 'auth_service.dart';
import 'app_version_service.dart';
import 'connectivity_service.dart';
import 'error_message_service.dart';
import 'local_security_service.dart';
import 'network_client_service.dart';
import 'offline_session_service.dart';
import 'realtime_notification_service.dart';
import 'telemetry_redaction_service.dart';

enum AppAlertType { success, error, info }

class AppAlertService {
  AppAlertService._();

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();
  static final http.Client _client = NetworkClientService.client;
  static bool _isShowingGlobalError = false;
  static String? _lastGlobalErrorFingerprint;
  static DateTime? _lastGlobalErrorAt;
  static String? _lastVisibleErrorFingerprint;
  static DateTime? _lastVisibleErrorAt;
  static String? _lastSnackFingerprint;
  static DateTime? _lastSnackAt;
  static final Map<String, DateTime> _recentCrashFingerprints =
      <String, DateTime>{};
  static const Duration _crashDeduplicationWindow = Duration(minutes: 5);

  static Future<void> showSuccess(
    BuildContext context, {
    String? title,
    required String message,
  }) {
    return _show(
      context,
      type: AppAlertType.success,
      title: title ?? context.loc.tr('services_app_alert_service.001'),
      message: message,
    );
  }

  static Future<void> showError(
    BuildContext context, {
    String? title,
    required String message,
    Map<String, dynamic>? extraContext,
    bool includeSupportGuidance = true,
    bool reportVisibleError = true,
  }) {
    return _show(
      context,
      type: AppAlertType.error,
      title: title ?? context.loc.tr('services_app_alert_service.002'),
      message: message,
      extraContext: extraContext,
      includeSupportGuidance: includeSupportGuidance,
      reportVisibleError: reportVisibleError,
    );
  }

  static Future<void> showInfo(
    BuildContext context, {
    String? title,
    required String message,
  }) {
    return _show(
      context,
      type: AppAlertType.info,
      title: title ?? context.loc.tr('services_app_alert_service.003'),
      message: message,
    );
  }

  static void showSnack(
    BuildContext context, {
    required String message,
    AppAlertType type = AppAlertType.info,
    Duration duration = const Duration(seconds: 3),
  }) {
    final cleanMessage = ErrorMessageService.sanitize(message);
    final fingerprint = '${type.name}|${cleanMessage.trim()}';
    final lastAt = _lastSnackAt;
    if (_lastSnackFingerprint == fingerprint &&
        lastAt != null &&
        DateTime.now().difference(lastAt) < const Duration(seconds: 4)) {
      return;
    }
    _lastSnackFingerprint = fingerprint;
    _lastSnackAt = DateTime.now();

    final style = _styleFor(type);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      return;
    }

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: duration,
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.transparent,
          elevation: 0,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          content: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: style.color.withValues(alpha: 0.16)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x200F172A),
                  blurRadius: 20,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: style.softColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(style.icon, color: style.color, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    cleanMessage,
                    style: const TextStyle(
                      color: Color(0xFF0F172A),
                      fontWeight: FontWeight.w700,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
  }

  static Future<void> showGlobalError({
    required String title,
    required String message,
    Map<String, dynamic>? extraContext,
  }) {
    final fingerprint = '${title.trim()}|${message.trim()}';
    final lastAt = _lastGlobalErrorAt;
    final isDuplicate =
        _isShowingGlobalError ||
        (_lastGlobalErrorFingerprint == fingerprint &&
            lastAt != null &&
            DateTime.now().difference(lastAt) < const Duration(seconds: 5));
    if (isDuplicate) {
      return Future.value();
    }
    final context = navigatorKey.currentContext;
    if (context == null) {
      debugPrint('Global alert skipped: $title - $message');
      return Future.value();
    }
    _isShowingGlobalError = true;
    _lastGlobalErrorFingerprint = fingerprint;
    _lastGlobalErrorAt = DateTime.now();
    return showError(
      context,
      title: title,
      message: message,
      extraContext: extraContext,
    ).whenComplete(() {
      _isShowingGlobalError = false;
    });
  }

  static Future<void> reportUnhandledCrash({
    required String title,
    required String message,
    String? details,
    String? stackTrace,
    String? route,
    Map<String, dynamic>? extraContext,
  }) async {
    try {
      final cleanTitle = TelemetryRedactionService.scrub(title, maxLength: 120);
      final cleanMessage = TelemetryRedactionService.scrub(
        message,
        maxLength: 4000,
      );
      final cleanStackTrace = stackTrace == null || stackTrace.trim().isEmpty
          ? ''
          : TelemetryRedactionService.scrub(stackTrace, maxLength: 8000);
      if (!_shouldReportCrash(
        message: cleanMessage,
        stackTrace: cleanStackTrace,
        route: route,
      )) {
        return;
      }

      final authService = AuthService();
      final token = await authService.token();
      final currentUser = await authService.currentUser();
      final appHeaders = await AppVersionService.publicHeaders(
        includeJsonContentType: true,
      );
      String? deviceId;
      try {
        deviceId = await LocalSecurityService.getOrCreateDeviceId();
      } catch (_) {}

      final payload = <String, dynamic>{
        'title': cleanTitle,
        'message': cleanMessage,
        'platform': defaultTargetPlatform.name,
        'route': route ?? '',
        'appVersion': appHeaders['X-App-Version'] ?? '',
        'appBuild': appHeaders['X-App-Build'] ?? '',
        'reportedAt': DateTime.now().toIso8601String(),
        'isOnline': ConnectivityService.instance.isOnline.value,
        'isWeb': kIsWeb,
        'runtimeMode': _runtimeMode,
        if (kIsWeb) 'url': Uri.base.toString(),
      };
      if (deviceId != null && deviceId.trim().isNotEmpty) {
        payload['deviceId'] = deviceId.trim();
      }

      if (details != null && details.trim().isNotEmpty) {
        payload['details'] = TelemetryRedactionService.scrub(
          details,
          maxLength: 4000,
        );
      }
      if (cleanStackTrace.isNotEmpty) {
        payload['stackTrace'] = cleanStackTrace;
      }

      if (currentUser != null) {
        payload['accountId'] = currentUser['id']?.toString();
        payload['role'] = (currentUser['roleLabel'] ?? currentUser['role'])
            ?.toString();
      }

      (extraContext ?? const <String, dynamic>{}).forEach((key, value) {
        final sanitized = _safeTelemetryValue(key, value);
        if (sanitized != null) {
          payload[key] = sanitized;
        }
      });

      await _client
          .post(
            AppConfig.apiUri('app/report-crash'),
            headers: {
              ...appHeaders,
              if (token != null && token.isNotEmpty)
                'Authorization': 'Bearer $token',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 4));
    } catch (_) {}
  }

  static bool _shouldReportCrash({
    required String message,
    required String stackTrace,
    required String? route,
  }) {
    // A single web exception can be surfaced by FlutterError,
    // PlatformDispatcher and the guarded zone with different titles/kinds.
    // The stack (or message when unavailable) plus the route identifies the
    // actual failure without treating those delivery paths as distinct crashes.
    final fingerprint = [
      stackTrace.isNotEmpty ? stackTrace : message,
      route?.trim() ?? '',
    ].join('\u001f');
    final now = DateTime.now();
    _recentCrashFingerprints.removeWhere(
      (_, reportedAt) =>
          now.difference(reportedAt) >= _crashDeduplicationWindow,
    );
    if (_recentCrashFingerprints.containsKey(fingerprint)) {
      return false;
    }
    _recentCrashFingerprints[fingerprint] = now;
    return true;
  }

  static String get _runtimeMode {
    if (kReleaseMode) {
      return 'release';
    }
    if (kProfileMode) {
      return 'profile';
    }
    return 'debug';
  }

  static Future<void> reportApiFailure({
    required String method,
    required Uri url,
    required int statusCode,
    required String message,
    String? responsePreview,
  }) {
    final context = navigatorKey.currentContext;
    final route = context != null ? _currentRouteName(context) : null;
    return _reportVisibleError(
      title: 'API failure $statusCode',
      message: message,
      route: route,
      extraContext: {
        'errorKind': 'client_api_failure',
        'method': method,
        'url': url.toString(),
        'statusCode': statusCode,
        if (responsePreview != null && responsePreview.trim().isNotEmpty)
          'responsePreview': responsePreview.trim(),
      },
    );
  }

  static Future<void> _show(
    BuildContext context, {
    required AppAlertType type,
    required String title,
    required String message,
    Map<String, dynamic>? extraContext,
    bool includeSupportGuidance = true,
    bool reportVisibleError = true,
  }) async {
    final style = _styleFor(type);
    final networkIssue =
        type == AppAlertType.error &&
        ErrorMessageService.isNetworkIssue(message);
    final cleanTitle = networkIssue
        ? (navigatorKey.currentContext?.loc.tr(
                'services_app_alert_service.007',
              ) ??
              ErrorMessageService.forUser(title))
        : ErrorMessageService.forUser(title);
    final cleanMessage = ErrorMessageService.forUser(
      message,
      includeSupportGuidance:
          type == AppAlertType.error && includeSupportGuidance && !networkIssue,
    );
    if (type == AppAlertType.error && reportVisibleError && !networkIssue) {
      unawaited(
        _reportVisibleError(
          title: cleanTitle,
          message: cleanMessage,
          route: _currentRouteName(context),
          extraContext: extraContext,
        ),
      );
    }
    final supportNumber = _extractWhatsAppNumber(cleanMessage);
    final returnToHomeOnAcknowledge =
        type == AppAlertType.error &&
        _shouldReturnHomeOnAcknowledge(cleanMessage);
    final restartLoginOnAcknowledge =
        type == AppAlertType.error &&
        ErrorMessageService.requiresFreshLogin(cleanMessage);
    final canRelogin =
        type == AppAlertType.error && _shouldOfferRelogin(cleanMessage);

    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            boxShadow: const [
              BoxShadow(
                color: Color(0x260F172A),
                blurRadius: 28,
                offset: Offset(0, 18),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  color: style.softColor,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: style.color.withValues(alpha: 0.18),
                    width: 2,
                  ),
                ),
                child: Icon(style.icon, color: style.color, size: 58),
              ),
              const SizedBox(height: 22),
              Text(
                cleanTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 27,
                  fontWeight: FontWeight.w900,
                  color: style.color,
                ),
              ),
              const SizedBox(height: 12),
              Directionality(
                textDirection: context.loc.isArabic
                    ? TextDirection.rtl
                    : TextDirection.ltr,
                child: Text(
                  cleanMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.7,
                    color: Color(0xFF334155),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 22),
              if (supportNumber != null) ...[
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: OutlinedButton.icon(
                    onPressed: () => _openWhatsApp(supportNumber),
                    icon: const Icon(Icons.chat_rounded),
                    label: Text(
                      context.loc.tr('services_app_alert_service.005'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.success,
                      side: const BorderSide(color: AppTheme.success),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (canRelogin) ...[
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      Navigator.pop(dialogContext);
                      await _restartLoginFlow();
                    },
                    icon: const Icon(Icons.login_rounded),
                    label: Text(
                      context.loc.tr('services_app_alert_service.009'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.primary,
                      side: const BorderSide(color: AppTheme.primary),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    if (restartLoginOnAcknowledge) {
                      unawaited(_restartLoginFlow());
                      return;
                    }
                    if (returnToHomeOnAcknowledge) {
                      final navigator = navigatorKey.currentState;
                      if (navigator != null) {
                        navigator.pushNamedAndRemoveUntil(
                          '/home',
                          (route) => false,
                        );
                      }
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: style.color,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    context.loc.tr('services_app_alert_service.006'),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static bool _shouldReturnHomeOnAcknowledge(String message) {
    return _messageContainsAny(message, 'services_app_alert_service.007');
  }

  static Future<void> _reportVisibleError({
    required String title,
    required String message,
    String? route,
    Map<String, dynamic>? extraContext,
  }) async {
    final fingerprint =
        '${title.trim()}|${message.trim()}|${route?.trim() ?? ''}';
    final lastAt = _lastVisibleErrorAt;
    final isDuplicate =
        _lastVisibleErrorFingerprint == fingerprint &&
        lastAt != null &&
        DateTime.now().difference(lastAt) < const Duration(seconds: 8);
    if (isDuplicate) {
      return;
    }

    _lastVisibleErrorFingerprint = fingerprint;
    _lastVisibleErrorAt = DateTime.now();

    try {
      final authService = AuthService();
      final token = await authService.token();
      final currentUser = await authService.currentUser();
      final appHeaders = await AppVersionService.publicHeaders(
        includeJsonContentType: true,
      );
      String? deviceId;
      try {
        deviceId = await LocalSecurityService.getOrCreateDeviceId();
      } catch (_) {}

      final payload = <String, dynamic>{
        'title': TelemetryRedactionService.scrub(title, maxLength: 120),
        'message': TelemetryRedactionService.scrub(message, maxLength: 4000),
        'platform': defaultTargetPlatform.name,
        'route': route ?? '',
        'errorKind': 'client_visible_error',
        'appVersion': appHeaders['X-App-Version'] ?? '',
        'appBuild': appHeaders['X-App-Build'] ?? '',
        'reportedAt': DateTime.now().toIso8601String(),
      };
      if (deviceId != null && deviceId.trim().isNotEmpty) {
        payload['deviceId'] = deviceId.trim();
      }
      final details = _detailsFromExtraContext(extraContext);
      if (details.isNotEmpty) {
        payload['details'] = details;
      }

      if (currentUser != null) {
        payload['accountId'] = currentUser['id']?.toString();
        payload['role'] = (currentUser['roleLabel'] ?? currentUser['role'])
            ?.toString();
      }

      (extraContext ?? const <String, dynamic>{}).forEach((key, value) {
        final sanitized = _safeTelemetryValue(key, value);
        if (sanitized != null) {
          payload[key] = sanitized;
        }
      });

      await _client
          .post(
            AppConfig.apiUri('app/report-crash'),
            headers: {
              ...appHeaders,
              if (token != null && token.isNotEmpty)
                'Authorization': 'Bearer $token',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 4));
    } catch (_) {}
  }

  static bool _shouldOfferRelogin(String message) {
    return ErrorMessageService.requiresFreshLogin(message);
  }

  static String? _currentRouteName(BuildContext context) {
    final route = ModalRoute.of(context);
    final name = route?.settings.name?.trim();
    if (name != null && name.isNotEmpty) {
      return name;
    }

    final navigatorContext = navigatorKey.currentContext;
    final fallbackName = ModalRoute.of(
      navigatorContext ?? context,
    )?.settings.name?.trim();
    return (fallbackName != null && fallbackName.isNotEmpty)
        ? fallbackName
        : null;
  }

  static Future<void> _restartLoginFlow() async {
    final currentContext = navigatorKey.currentContext;
    final returnRoute = currentContext == null
        ? null
        : ModalRoute.of(currentContext)?.settings.name;
    await RealtimeNotificationService.stop();
    OfflineSessionService.setOfflineMode(false);

    final canUseTrustedUnlock =
        await LocalSecurityService.canUseTrustedUnlock();
    final navigator = navigatorKey.currentState;
    if (navigator != null) {
      navigator.pushNamedAndRemoveUntil(
        canUseTrustedUnlock ? '/unlock' : '/login',
        (route) => false,
        arguments: canUseTrustedUnlock && returnRoute != null
            ? {'returnRoute': returnRoute}
            : null,
      );
    }
  }

  static Future<void> _openWhatsApp(String phone) async {
    final normalized = phone.replaceAll(RegExp(r'\D'), '');
    final uri = Uri.parse('https://wa.me/$normalized');
    var opened = false;
    try {
      opened = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      ).timeout(const Duration(seconds: 8));
    } catch (_) {
      opened = false;
    }
    final context = navigatorKey.currentContext;
    if (!opened && context != null && context.mounted) {
      showSnack(
        context,
        message:
            'تعذر فتح الشات الآن. تحقق من اتصال الإنترنت أو انسخ الرقم وتواصل يدويًا.',
        type: AppAlertType.error,
      );
    }
  }

  static String? _extractWhatsAppNumber(String message) {
    if (!_messageContainsAny(message, 'services_app_alert_service.008')) {
      return null;
    }
    final match = RegExp(r'(\+?\d[\d\s-]{7,}\d)').firstMatch(message);
    if (match == null) {
      return null;
    }
    final digits = match.group(0)?.replaceAll(RegExp(r'\D'), '') ?? '';
    return digits.length >= 8 ? digits : null;
  }

  static bool _messageContainsAny(String message, String key) {
    final current = navigatorKey.currentContext?.loc.tr(key);
    final arabic = appStringsAr[key];
    final english = appStringsEn[key];
    return [current, arabic, english].any(
      (candidate) =>
          candidate != null &&
          candidate.isNotEmpty &&
          message.contains(candidate),
    );
  }

  static String _detailsFromExtraContext(Map<String, dynamic>? extraContext) {
    final entries = <String>[];
    (extraContext ?? const <String, dynamic>{}).forEach((key, value) {
      final sanitized = _safeTelemetryValue(key, value);
      if (sanitized == null) {
        return;
      }
      entries.add('$key: $sanitized');
    });

    return entries.join('\n');
  }

  static String? _safeTelemetryValue(String key, Object? value) {
    if (value == null) {
      return null;
    }
    final normalizedKey = key.toLowerCase();
    if (normalizedKey.contains('password') ||
        normalizedKey.contains('otp') ||
        normalizedKey.contains('pin') ||
        normalizedKey.contains('token') ||
        normalizedKey.contains('secret') ||
        normalizedKey.contains('whatsapp') ||
        normalizedKey.contains('phone') ||
        normalizedKey.contains('mobile') ||
        normalizedKey.contains('email') ||
        normalizedKey.contains('address') ||
        normalizedKey.contains('national') ||
        normalizedKey.contains('identity') ||
        normalizedKey.contains('barcode') ||
        normalizedKey.contains('cardnumber') ||
        normalizedKey.contains('card_number')) {
      return 'محجوب';
    }
    final text = TelemetryRedactionService.scrub(value);
    if (text.isEmpty) {
      return null;
    }
    return text;
  }

  static _AlertStyle _styleFor(AppAlertType type) {
    switch (type) {
      case AppAlertType.success:
        return const _AlertStyle(
          color: AppTheme.success,
          softColor: AppTheme.successLight,
          icon: Icons.check_circle_rounded,
        );
      case AppAlertType.error:
        return const _AlertStyle(
          color: AppTheme.error,
          softColor: AppTheme.errorLight,
          icon: Icons.cancel_rounded,
        );
      case AppAlertType.info:
        return const _AlertStyle(
          color: AppTheme.info,
          softColor: AppTheme.infoLight,
          icon: Icons.info_rounded,
        );
    }
  }
}

class _AlertStyle {
  const _AlertStyle({
    required this.color,
    required this.softColor,
    required this.icon,
  });

  final Color color;
  final Color softColor;
  final IconData icon;
}
