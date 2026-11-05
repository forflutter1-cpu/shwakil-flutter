import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';
import 'app_version_service.dart';
import 'error_message_service.dart';
import 'external_app_notification_service.dart';
import 'local_security_service.dart';
import 'network_client_service.dart';
import 'secure_storage_config.dart';

class OtpRequestResult {
  const OtpRequestResult({
    this.message,
    this.whatsapp,
    this.debugOtpCode,
    this.otpRequired,
    this.pendingRegistrationId,
    this.loginRequired,
    this.loginIdentifier,
  });

  final String? message;
  final String? whatsapp;
  final String? debugOtpCode;
  final bool? otpRequired;
  final String? pendingRegistrationId;
  final bool? loginRequired;
  final String? loginIdentifier;
}

class PendingRegistrationLookupResult {
  const PendingRegistrationLookupResult({
    required this.hasPendingRegistration,
    this.message,
    this.pendingRegistration,
  });

  final bool hasPendingRegistration;
  final String? message;
  final Map<String, dynamic>? pendingRegistration;
}

class AuthRequestException implements Exception {
  const AuthRequestException(
    this.message, {
    this.deviceApprovalRequired = false,
    this.deviceApprovalPending = false,
    this.deviceSessionOtpRequired = false,
  });

  final String message;
  final bool deviceApprovalRequired;
  final bool deviceApprovalPending;
  final bool deviceSessionOtpRequired;

  @override
  String toString() => message;
}

class AuthService {
  AuthService({http.Client? client})
    : _client = client ?? NetworkClientService.client;

  static const _tokenKey = 'auth_token';
  static const _userKey = 'auth_user_json';
  static const _refreshTokenKey = 'device_session_refresh_token';
  static const Duration _requestTimeout = Duration(seconds: 10);
  final http.Client _client;
  static SharedPreferences? _cachedPrefs;
  static String? _cachedToken;
  static Map<String, dynamic>? _cachedUser;
  static String? _cachedRefreshToken;
  static const FlutterSecureStorage _secureStorage = appSecureStorage;
  static Future<void>? _pendingRefreshCurrentUser;
  static Future<bool>? _pendingTrustedSessionRefresh;
  static int _sessionEpoch = 0;
  static Future<void> _sessionMutationTail = Future<void>.value();

  @visibleForTesting
  static void resetMemoryCacheForTesting() {
    _cachedPrefs = null;
    _cachedToken = null;
    _cachedUser = null;
    _cachedRefreshToken = null;
    _pendingRefreshCurrentUser = null;
    _pendingTrustedSessionRefresh = null;
    _sessionEpoch = 0;
    _sessionMutationTail = Future<void>.value();
  }

  static Future<T> _synchronizeSessionMutation<T>(
    Future<T> Function() operation,
  ) {
    final previous = _sessionMutationTail;
    final completed = Completer<void>();
    _sessionMutationTail = completed.future;
    return (() async {
      try {
        await previous;
      } catch (_) {
        // A failed persistence operation must not block future session writes.
      }
      try {
        return await operation();
      } finally {
        completed.complete();
      }
    })();
  }

  static String _normalizeUsername(String? value) {
    return value?.trim().toLowerCase() ?? '';
  }

  static String _normalizeIdentifier(String? value) {
    return value?.trim() ?? '';
  }

  static Map<String, dynamic>? peekCurrentUser() {
    final cached = _cachedUser;
    return cached == null ? null : Map<String, dynamic>.from(cached);
  }

  static String? peekToken() => _cachedToken;

  static bool hasPermissionSnapshot(Map<String, dynamic>? user) {
    if (user == null) {
      return false;
    }
    final permissions = user['permissions'];
    if (permissions is Map && permissions.isNotEmpty) {
      return true;
    }
    return const [
      'canViewBalance',
      'canViewTransactions',
      'canIssueCards',
      'canScanCards',
      'canViewSecuritySettings',
      'canManageUsers',
    ].any(user.containsKey);
  }

  static Future<SharedPreferences> _prefs() async {
    _cachedPrefs ??= await SharedPreferences.getInstance();
    return _cachedPrefs!;
  }

  Future<Map<String, String>> _jsonHeaders({String? token}) async {
    final headers = await AppVersionService.publicHeaders(
      includeJsonContentType: true,
    );
    final deviceId = await LocalSecurityService.getOrCreateDeviceId();
    if (deviceId.trim().isNotEmpty) {
      headers['X-Device-Id'] = deviceId.trim();
    }
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Future<Map<String, String>> _requestHeaders({String? token}) async {
    final headers = await AppVersionService.publicHeaders();
    final deviceId = await LocalSecurityService.getOrCreateDeviceId();
    if (deviceId.trim().isNotEmpty) {
      headers['X-Device-Id'] = deviceId.trim();
    }
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Future<OtpRequestResult> requestOtp({
    required String purpose,
    String? username,
    String? password,
    String? fullName,
    String? whatsapp,
    String? countryCode,
    String? nationalId,
    String? birthDate,
    String? referralPhone,
    String? pendingRegistrationId,
    bool termsAccepted = false,
  }) async {
    final deviceId = await LocalSecurityService.getOrCreateDeviceId();
    final deviceRefreshToken = purpose.trim() == 'login'
        ? await _deviceRefreshToken()
        : null;
    final response = await _postWithFallback(
      'auth/request-otp',
      body: {
        'purpose': purpose,
        'username': _normalizeIdentifier(username),
        'identifier': _normalizeIdentifier(username),
        'password': password,
        'fullName': fullName?.trim(),
        'whatsapp': whatsapp?.trim(),
        'countryCode': countryCode?.trim(),
        'nationalId': nationalId?.trim(),
        'birthDate': birthDate?.trim(),
        'referralPhone': referralPhone?.trim(),
        'pendingRegistrationId': pendingRegistrationId?.trim(),
        'deviceId': deviceId,
        if (deviceRefreshToken != null && deviceRefreshToken.isNotEmpty)
          'deviceRefreshToken': deviceRefreshToken,
        'termsAccepted': termsAccepted,
      },
    );
    if (response.statusCode >= 400) {
      throw _exceptionFromResponse(response.body, registrationMessage: true);
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return OtpRequestResult(
      message: body['message']?.toString(),
      whatsapp: body['whatsapp']?.toString(),
      debugOtpCode: body['debugOtpCode']?.toString(),
      otpRequired: body['otpRequired'] is bool
          ? body['otpRequired'] as bool
          : null,
      pendingRegistrationId: body['pendingRegistrationId']?.toString(),
      loginRequired: body['loginRequired'] is bool
          ? body['loginRequired'] as bool
          : null,
      loginIdentifier: body['loginIdentifier']?.toString(),
    );
  }

  Future<void> validateRegistration({
    required String fullName,
    String? username,
    required String whatsapp,
    required String countryCode,
    String? nationalId,
    String? birthDate,
    required bool termsAccepted,
    String? referralPhone,
  }) async {
    final response = await _postWithFallback(
      'auth/register/validate',
      body: {
        'fullName': fullName.trim(),
        'username': username == null || username.trim().isEmpty
            ? null
            : _normalizeUsername(username),
        'whatsapp': whatsapp.trim(),
        'countryCode': countryCode.trim(),
        'nationalId': nationalId?.trim(),
        'birthDate': birthDate?.trim(),
        'referralPhone': referralPhone?.trim().isEmpty ?? true
            ? null
            : referralPhone?.trim(),
        'termsAccepted': termsAccepted,
      },
    );
    if (response.statusCode >= 400) {
      throw Exception(_extractRegistrationMessage(response.body));
    }
  }

  Future<OtpRequestResult> startRegistration({
    required String fullName,
    String? username,
    required String whatsapp,
    required String countryCode,
    String? nationalId,
    String? birthDate,
    required bool termsAccepted,
    String? referralPhone,
  }) async {
    final deviceId = await LocalSecurityService.getOrCreateDeviceId();
    final deviceRefreshToken = await _deviceRefreshToken();
    final response = await _postWithFallback(
      'auth/register',
      body: {
        'fullName': fullName.trim(),
        'username': username == null || username.trim().isEmpty
            ? null
            : _normalizeUsername(username),
        'whatsapp': whatsapp.trim(),
        'countryCode': countryCode.trim(),
        'nationalId': nationalId?.trim(),
        'birthDate': birthDate?.trim(),
        'referralPhone': referralPhone?.trim().isEmpty ?? true
            ? null
            : referralPhone?.trim(),
        'termsAccepted': termsAccepted,
        'deviceId': deviceId,
        if (deviceRefreshToken != null && deviceRefreshToken.isNotEmpty)
          'deviceRefreshToken': deviceRefreshToken,
      },
    );
    if (response.statusCode >= 400) {
      throw Exception(_extractRegistrationMessage(response.body));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return OtpRequestResult(
      message: body['message']?.toString(),
      whatsapp: body['whatsapp']?.toString(),
      debugOtpCode: body['debugOtpCode']?.toString(),
      otpRequired: body['otpRequired'] is bool
          ? body['otpRequired'] as bool
          : null,
      pendingRegistrationId: body['pendingRegistrationId']?.toString(),
      loginRequired: body['loginRequired'] is bool
          ? body['loginRequired'] as bool
          : null,
      loginIdentifier: body['loginIdentifier']?.toString(),
    );
  }

  Future<PendingRegistrationLookupResult>
  getPendingRegistrationForCurrentDevice() async {
    final deviceId = await LocalSecurityService.getOrCreateDeviceId();
    final response = await _postWithFallback(
      'auth/register/pending',
      body: {'deviceId': deviceId},
    );
    if (response.statusCode >= 400) {
      throw Exception(_extractRegistrationMessage(response.body));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final pendingRegistrationValue = body['pendingRegistration'];

    return PendingRegistrationLookupResult(
      hasPendingRegistration: body['hasPendingRegistration'] == true,
      message: body['message']?.toString(),
      pendingRegistration: pendingRegistrationValue is Map
          ? Map<String, dynamic>.from(pendingRegistrationValue)
          : null,
    );
  }

  Future<Map<String, dynamic>> register({
    String? fullName,
    String? username,
    String? whatsapp,
    String? countryCode,
    String? nationalId,
    String? birthDate,
    bool? termsAccepted,
    String? referralPhone,
    String? pendingRegistrationId,
    String? otpCode,
    String otpPurpose = 'register',
  }) async {
    final deviceId = await LocalSecurityService.getOrCreateDeviceId();
    final response = await _postWithFallback(
      'auth/register',
      body: {
        'fullName': fullName?.trim(),
        'username': username == null ? null : _normalizeUsername(username),
        'whatsapp': whatsapp?.trim(),
        'countryCode': countryCode?.trim(),
        'nationalId': nationalId?.trim(),
        'birthDate': birthDate?.trim(),
        'referralPhone': referralPhone?.trim().isEmpty ?? true
            ? null
            : referralPhone?.trim(),
        'termsAccepted': termsAccepted,
        'pendingRegistrationId': pendingRegistrationId?.trim(),
        'otpCode': otpCode?.trim(),
        'otpPurpose': otpPurpose,
        'deviceId': deviceId,
      },
    );
    if (response.statusCode >= 400) {
      throw Exception(_extractRegistrationMessage(response.body));
    }
    return Map<String, dynamic>.from(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<void> login({
    required String username,
    required String password,
    String? otpCode,
  }) async {
    final expectedEpoch = _sessionEpoch;
    final deviceId = await LocalSecurityService.getOrCreateDeviceId();
    final deviceRefreshToken = await _deviceRefreshToken();
    final response = await _postWithFallback(
      'auth/login',
      body: {
        'username': _normalizeIdentifier(username),
        'identifier': _normalizeIdentifier(username),
        'password': password,
        'otpCode': (otpCode ?? '').trim(),
        'otpPurpose': 'login',
        'deviceId': deviceId,
        if (deviceRefreshToken != null && deviceRefreshToken.isNotEmpty)
          'deviceRefreshToken': deviceRefreshToken,
      },
    );
    if (response.statusCode >= 400) {
      throw _exceptionFromResponse(response.body);
    }
    final saved = await _saveAuthPayload(
      jsonDecode(response.body) as Map<String, dynamic>,
      expectedEpoch: expectedEpoch,
    );
    if (!saved) {
      throw const AuthRequestException(
        'تعذر حفظ جلسة الدخول في التخزين الآمن. تحقق من الاتصال الآمن ثم أعد المحاولة.',
      );
    }
  }

  Future<OtpRequestResult> requestDeviceSessionOtp() async {
    final expectedEpoch = _sessionEpoch;
    final authToken = await token();
    final deviceId = await LocalSecurityService.getOrCreateDeviceId();
    final response = await _postWithFallback(
      'auth/device-session/request-otp',
      token: authToken,
      body: {'deviceId': deviceId},
    );
    if (response.statusCode >= 400) {
      throw _exceptionFromResponse(response.body);
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if ((body['token']?.toString() ?? '').isNotEmpty) {
      if (!await _saveAuthPayload(body, expectedEpoch: expectedEpoch)) {
        throw const AuthRequestException(
          'تعذر حفظ جلسة الجهاز في التخزين الآمن. أعد المحاولة.',
        );
      }
    }
    return OtpRequestResult(
      message: body['message']?.toString(),
      whatsapp: body['whatsapp']?.toString(),
      debugOtpCode: body['debugOtpCode']?.toString(),
      otpRequired: body['otpRequired'] is bool
          ? body['otpRequired'] as bool
          : null,
    );
  }

  Future<void> confirmDeviceSessionOtp({required String otpCode}) async {
    final expectedEpoch = _sessionEpoch;
    final authToken = await token();
    final deviceId = await LocalSecurityService.getOrCreateDeviceId();
    final response = await _postWithFallback(
      'auth/device-session/confirm',
      token: authToken,
      body: {'deviceId': deviceId, 'otpCode': otpCode.trim()},
    );
    if (response.statusCode >= 400) {
      throw _exceptionFromResponse(response.body);
    }
    final saved = await _saveAuthPayload(
      jsonDecode(response.body) as Map<String, dynamic>,
      expectedEpoch: expectedEpoch,
    );
    if (!saved) {
      throw const AuthRequestException(
        'تعذر حفظ جلسة الجهاز في التخزين الآمن. أعد المحاولة.',
      );
    }
  }

  Future<bool> refreshTrustedDeviceSession() async {
    final pending = _pendingTrustedSessionRefresh;
    if (pending != null) {
      return pending;
    }
    final future = _refreshTrustedDeviceSessionInternal();
    _pendingTrustedSessionRefresh = future;
    try {
      return await future;
    } finally {
      if (identical(_pendingTrustedSessionRefresh, future)) {
        _pendingTrustedSessionRefresh = null;
      }
    }
  }

  Future<bool> _refreshTrustedDeviceSessionInternal() async {
    final expectedEpoch = _sessionEpoch;
    final refreshToken = await _deviceRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      return false;
    }
    final deviceId = await LocalSecurityService.getOrCreateDeviceId();
    final response = await _postWithFallback(
      'auth/device-session/refresh',
      body: {'deviceId': deviceId, 'refreshToken': refreshToken},
    );
    if (response.statusCode >= 400) {
      return false;
    }
    return _saveAuthPayload(
      jsonDecode(response.body) as Map<String, dynamic>,
      expectedEpoch: expectedEpoch,
    );
  }

  Future<void> logout() async {
    String? authToken;
    String? deviceId;
    try {
      authToken = await token();
      deviceId = await LocalSecurityService.getOrCreateDeviceId();
    } catch (_) {
      // Local cleanup below must always remain available.
    }

    _sessionEpoch++;
    _pendingRefreshCurrentUser = null;
    _pendingTrustedSessionRefresh = null;

    try {
      if (authToken != null &&
          authToken.isNotEmpty &&
          deviceId != null &&
          deviceId.trim().isNotEmpty) {
        await _client
            .post(
              AppConfig.apiUri('auth/logout'),
              headers: await _jsonHeaders(token: authToken),
              body: jsonEncode({'deviceId': deviceId.trim()}),
            )
            .timeout(const Duration(seconds: 4));
      }
    } catch (_) {
      // Server logout is best-effort. A network/auth failure must never keep
      // local credentials after the user explicitly requested logout.
    } finally {
      try {
        await ExternalAppNotificationService().setActiveWorkspaceId(null);
      } catch (_) {
        // Android may not have initialized the optional notification channel.
      }
      _cachedToken = null;
      _cachedUser = null;
      _cachedRefreshToken = null;
      await _synchronizeSessionMutation(() async {
        final prefs = await _prefs();
        await prefs.remove(_tokenKey);
        await prefs.remove(_userKey);
        await _deleteSecure(_tokenKey);
        await _deleteSecure(_userKey);
        await _deleteSecure(_refreshTokenKey);
      });
    }
  }

  Future<bool> isLoggedIn() async {
    return ((await token()) ?? '').isNotEmpty;
  }

  Future<String?> currentUsername() async {
    final user = await currentUser();
    return user?['username']?.toString();
  }

  Future<Map<String, dynamic>?> currentUser() async {
    final cached = _cachedUser;
    if (cached != null) {
      return Map<String, dynamic>.from(cached);
    }
    return _synchronizeSessionMutation(() async {
      final inMemory = _cachedUser;
      if (inMemory != null) {
        return Map<String, dynamic>.from(inMemory);
      }

      final prefs = await _prefs();
      final securedRaw = (await _readSecure(_userKey))?.trim() ?? '';
      final legacyRaw = prefs.getString(_userKey)?.trim() ?? '';
      for (final candidate in [
        (raw: securedRaw, legacy: false),
        (raw: legacyRaw, legacy: true),
      ]) {
        if (candidate.raw.isEmpty) {
          continue;
        }
        Map<String, dynamic> decodedUser;
        try {
          decodedUser = Map<String, dynamic>.from(
            jsonDecode(candidate.raw) as Map,
          );
        } catch (_) {
          if (candidate.legacy) {
            await prefs.remove(_userKey);
          } else {
            await _deleteSecure(_userKey);
          }
          continue;
        }
        if (candidate.legacy) {
          if (!await _writeSecure(_userKey, candidate.raw)) {
            await prefs.remove(_userKey);
            await _deleteSecure(_userKey);
            continue;
          }
          await prefs.remove(_userKey);
        }
        _cachedUser = decodedUser;
        return Map<String, dynamic>.from(_cachedUser!);
      }
      return null;
    });
  }

  Future<String?> token() async {
    final cached = _cachedToken;
    if (cached != null) {
      return cached;
    }
    return _synchronizeSessionMutation(() async {
      final inMemory = _cachedToken;
      if (inMemory != null) {
        return inMemory;
      }

      final secured = (await _readSecure(_tokenKey))?.trim() ?? '';
      if (secured.isNotEmpty) {
        _cachedToken = secured;
        return secured;
      }

      final prefs = await _prefs();
      final legacy = prefs.getString(_tokenKey)?.trim() ?? '';
      if (legacy.isEmpty) {
        return null;
      }

      if (!await _writeSecure(_tokenKey, legacy)) {
        await prefs.remove(_tokenKey);
        await _deleteSecure(_tokenKey);
        return null;
      }
      await prefs.remove(_tokenKey);
      _cachedToken = legacy;
      return legacy;
    });
  }

  Future<void> cacheCurrentUser(
    Map<String, dynamic> user, {
    int? expectedSessionEpoch,
  }) async {
    final operationEpoch = expectedSessionEpoch ?? _sessionEpoch;
    if (operationEpoch != _sessionEpoch) {
      return;
    }
    final current = await currentUser();
    final currentId = current?['id']?.toString().trim() ?? '';
    final incomingId = user['id']?.toString().trim() ?? '';
    if (currentId.isNotEmpty &&
        incomingId.isNotEmpty &&
        currentId != incomingId) {
      return;
    }
    await _synchronizeSessionMutation(() async {
      if (operationEpoch != _sessionEpoch) {
        return;
      }
      final activeId = _cachedUser?['id']?.toString().trim() ?? '';
      if (activeId.isNotEmpty &&
          incomingId.isNotEmpty &&
          activeId != incomingId) {
        return;
      }
      _cachedUser = Map<String, dynamic>.from(user);
      final encoded = jsonEncode(user);
      final prefs = await _prefs();
      await prefs.remove(_userKey);
      if (!await _writeSecure(_userKey, encoded)) {
        // A failed overwrite can leave an older user's profile behind.
        await _deleteSecure(_userKey);
      }
    });
  }

  Future<void> cacheToken(String token, {String? expectedToken}) async {
    final normalized = token.trim();
    if (normalized.isEmpty) {
      return;
    }
    final operationEpoch = _sessionEpoch;
    String? current;
    if (expectedToken != null) {
      current = _cachedToken ?? await this.token();
      if (current == null || !identicalSessionToken(current, expectedToken)) {
        return;
      }
    }
    if (operationEpoch != _sessionEpoch) {
      return;
    }
    // Make a response token immediately available to the request that received
    // it. Persistence remains serialized and epoch-guarded below.
    _cachedToken = normalized;
    await _synchronizeSessionMutation(() async {
      if (operationEpoch != _sessionEpoch) {
        return;
      }
      if (expectedToken != null) {
        final active = _cachedToken ?? current;
        if (active == null ||
            (!identicalSessionToken(active, expectedToken) &&
                !identicalSessionToken(active, normalized))) {
          return;
        }
      }
      final prefs = await _prefs();
      if (await _writeSecure(_tokenKey, normalized)) {
        if (_cachedToken == normalized && operationEpoch == _sessionEpoch) {
          await prefs.remove(_tokenKey);
        }
      } else {
        await prefs.remove(_tokenKey);
        // Do not let a stale token be restored on the next app launch.
        await _deleteSecure(_tokenKey);
      }
    });
  }

  Future<void> patchCurrentUser(Map<String, dynamic> patch) async {
    if (patch.isEmpty) {
      return;
    }
    final expectedEpoch = _sessionEpoch;
    final current = await currentUser();
    if (current == null) {
      return;
    }
    current.addAll(patch);
    await cacheCurrentUser(current, expectedSessionEpoch: expectedEpoch);
  }

  Future<void> refreshCurrentUser() async {
    final pending = _pendingRefreshCurrentUser;
    if (pending != null) {
      await pending;
      return;
    }
    final future = _refreshCurrentUserInternal();
    _pendingRefreshCurrentUser = future;
    try {
      await future;
    } finally {
      if (identical(_pendingRefreshCurrentUser, future)) {
        _pendingRefreshCurrentUser = null;
      }
    }
  }

  Future<bool> tryRefreshCurrentUser() async {
    try {
      await refreshCurrentUser();
      return true;
    } catch (error) {
      if (ErrorMessageService.isNetworkIssue(error)) {
        return false;
      }
      rethrow;
    }
  }

  Future<void> _refreshCurrentUserInternal() async {
    final expectedEpoch = _sessionEpoch;
    final stopwatch = Stopwatch()..start();
    for (var attempt = 0; attempt < 2; attempt++) {
      final authToken = await token();
      if (authToken == null || authToken.isEmpty) {
        return;
      }
      final response = await _client
          .get(
            AppConfig.apiUri('auth/me'),
            headers: await _requestHeaders(token: authToken),
          )
          .timeout(_requestTimeout);
      _captureRefreshedToken(response, expectedToken: authToken);
      if (response.statusCode == 401 &&
          attempt == 0 &&
          await refreshTrustedDeviceSession()) {
        continue;
      }
      if (response.statusCode >= 400) {
        throw _exceptionFromResponse(response.body);
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['authenticated'] == false) {
        if (attempt == 0 && await refreshTrustedDeviceSession()) {
          continue;
        }
        throw const AuthRequestException(
          'يتطلب تأكيد الجهاز من جديد.',
          deviceSessionOtpRequired: true,
        );
      }
      if ((body['token']?.toString() ?? '').isNotEmpty) {
        await _saveAuthPayload(body, expectedEpoch: expectedEpoch);
      } else {
        await cacheCurrentUser(
          Map<String, dynamic>.from(body['user'] as Map),
          expectedSessionEpoch: expectedEpoch,
        );
      }
      break;
    }
    assert(() {
      // ignore: avoid_print
      print('[auth] GET auth/me ${stopwatch.elapsed.inMilliseconds}ms');
      return true;
    }());
  }

  Future<Map<String, dynamic>> updateProfile({
    required String businessName,
    required String fullName,
    required String username,
    required String email,
    required String address,
    required String nationalId,
    required String birthDate,
    required String referralPhone,
  }) async {
    final expectedEpoch = _sessionEpoch;
    final authToken = await token();
    final response = await _client.put(
      AppConfig.apiUri('auth/profile'),
      headers: await _jsonHeaders(token: authToken),
      body: jsonEncode({
        'businessName': businessName.trim(),
        'fullName': fullName.trim(),
        'username': _normalizeUsername(username),
        'email': email.trim(),
        'address': address.trim(),
        'nationalId': nationalId.trim(),
        'birthDate': birthDate.trim(),
        'referralPhone': referralPhone.trim(),
      }),
    );
    _captureRefreshedToken(response, expectedToken: authToken);
    if (response.statusCode >= 400) {
      throw Exception(_extractMessage(response.body));
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    await cacheCurrentUser(
      Map<String, dynamic>.from(body['user'] as Map),
      expectedSessionEpoch: expectedEpoch,
    );
    return body;
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final authToken = await token();
    final response = await _client.post(
      AppConfig.apiUri('auth/change-password'),
      headers: await _jsonHeaders(token: authToken),
      body: jsonEncode({
        'currentPassword': currentPassword,
        'newPassword': newPassword,
      }),
    );
    _captureRefreshedToken(response, expectedToken: authToken);
    if (response.statusCode >= 400) {
      throw Exception(_extractMessage(response.body));
    }
  }

  Future<void> deleteAccount() async {
    final authToken = await token();
    final response = await _client.delete(
      AppConfig.apiUri('auth/account'),
      headers: await _jsonHeaders(token: authToken),
    );
    if (response.statusCode >= 400) {
      throw Exception(_extractMessage(response.body));
    }
    await logout();
  }

  Future<OtpRequestResult> requestPasswordResetOtp({
    required String username,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('auth/password-reset/request-otp'),
      headers: await _jsonHeaders(),
      body: jsonEncode({
        'username': _normalizeIdentifier(username),
        'identifier': _normalizeIdentifier(username),
      }),
    );
    if (response.statusCode >= 400) {
      throw Exception(_extractMessage(response.body));
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return OtpRequestResult(
      message: body['message']?.toString(),
      debugOtpCode: body['debugOtpCode']?.toString(),
    );
  }

  Future<void> resetPassword({
    required String username,
    required String otpCode,
    required String newPassword,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('auth/password-reset/reset'),
      headers: await _jsonHeaders(),
      body: jsonEncode({
        'username': _normalizeIdentifier(username),
        'identifier': _normalizeIdentifier(username),
        'otpCode': otpCode.trim(),
        'newPassword': newPassword,
      }),
    );
    if (response.statusCode >= 400) {
      throw Exception(_extractMessage(response.body));
    }
  }

  Future<Map<String, dynamic>> lookupAccountByIdentity({
    required String nationalId,
    required String birthDate,
    required String whatsapp,
    required String countryCode,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('auth/account-recovery/lookup'),
      headers: await _jsonHeaders(),
      body: jsonEncode({
        'nationalId': nationalId.trim(),
        'birthDate': birthDate.trim(),
        'whatsapp': whatsapp.trim(),
        'countryCode': countryCode.trim(),
      }),
    );
    if (response.statusCode >= 400) {
      throw Exception(_extractMessage(response.body));
    }
    return Map<String, dynamic>.from(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<bool> _saveAuthPayload(
    Map<String, dynamic> payload, {
    int? expectedEpoch,
  }) async {
    final operationEpoch = expectedEpoch ?? _sessionEpoch;
    return _synchronizeSessionMutation(() async {
      if (operationEpoch != _sessionEpoch) {
        return false;
      }
      final nextToken = payload['token']?.toString().trim() ?? '';
      if (nextToken.isEmpty) {
        return false;
      }

      final nextUser = payload['user'] is Map
          ? Map<String, dynamic>.from(payload['user'] as Map)
          : _cachedUser;
      final refreshToken = payload['refreshToken']?.toString().trim() ?? '';
      final prefs = await _prefs();
      final tokenStored = await _writeSecure(_tokenKey, nextToken);
      final userStored = nextUser == null
          ? await _deleteSecure(_userKey)
          : await _writeSecure(_userKey, jsonEncode(nextUser));
      final refreshTokenStored = refreshToken.isEmpty
          ? await _deleteSecure(_refreshTokenKey)
          : await _writeSecure(_refreshTokenKey, refreshToken);

      if (!tokenStored || !userStored || !refreshTokenStored) {
        await prefs.remove(_tokenKey);
        await prefs.remove(_userKey);
        await _deleteSecure(_tokenKey);
        await _deleteSecure(_userKey);
        await _deleteSecure(_refreshTokenKey);
        _sessionEpoch++;
        _cachedToken = null;
        _cachedUser = null;
        _cachedRefreshToken = null;
        return false;
      }

      await prefs.remove(_tokenKey);
      await prefs.remove(_userKey);
      _sessionEpoch++;
      _cachedToken = nextToken;
      _cachedUser = nextUser == null
          ? null
          : Map<String, dynamic>.from(nextUser);
      _cachedRefreshToken = refreshToken.isNotEmpty ? refreshToken : null;
      return true;
    });
  }

  Future<String?> _deviceRefreshToken() async {
    final cached = _cachedRefreshToken;
    if (cached != null) {
      return cached;
    }
    _cachedRefreshToken = await _readSecure(_refreshTokenKey);
    return _cachedRefreshToken;
  }

  static Future<String?> _readSecure(String key) async {
    try {
      return await _secureStorage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _writeSecure(String key, String value) async {
    try {
      await _secureStorage.write(key: key, value: value);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _deleteSecure(String key) async {
    try {
      await _secureStorage.delete(key: key);
      return true;
    } catch (_) {
      // Callers that require secure revocation inspect the false result.
      return false;
    }
  }

  Future<String?> deviceRefreshToken() => _deviceRefreshToken();

  String _extractMessage(String body) {
    return ErrorMessageService.fromResponseBody(body);
  }

  String _extractRegistrationMessage(String body) {
    return ErrorMessageService.fromRegistrationResponseBody(body);
  }

  AuthRequestException _exceptionFromResponse(
    String body, {
    bool registrationMessage = false,
  }) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final rawMessage = decoded['message']?.toString() ?? '';
        final message = registrationMessage
            ? ErrorMessageService.sanitizeRegistration(rawMessage)
            : ErrorMessageService.sanitize(rawMessage);
        return AuthRequestException(
          message,
          deviceApprovalRequired: decoded['deviceApprovalRequired'] == true,
          deviceApprovalPending: decoded['deviceApprovalPending'] == true,
          deviceSessionOtpRequired: decoded['deviceSessionOtpRequired'] == true,
        );
      }
    } catch (_) {}

    return AuthRequestException(
      registrationMessage
          ? _extractRegistrationMessage(body)
          : _extractMessage(body),
    );
  }

  Future<http.Response> _postWithFallback(
    String path, {
    required Map<String, dynamic> body,
    String? token,
  }) async {
    Object? lastError;
    for (final uri in AppConfig.apiCandidateUris(path)) {
      try {
        final response = await _client
            .post(
              uri,
              headers: await _jsonHeaders(token: token),
              body: jsonEncode(body),
            )
            .timeout(_requestTimeout);
        _captureRefreshedToken(response);
        return response;
      } on TimeoutException catch (error) {
        lastError = error;
      } on http.ClientException catch (error) {
        lastError = error;
      }
    }

    throw lastError ?? Exception('Request failed');
  }

  void _captureRefreshedToken(
    http.BaseResponse response, {
    String? expectedToken,
  }) {
    final refreshedToken = response.headers['x-auth-token']?.trim() ?? '';
    if (refreshedToken.isNotEmpty) {
      final requestToken =
          expectedToken ?? _authorizationTokenFromRequest(response.request);
      if (requestToken != null) {
        unawaited(cacheToken(refreshedToken, expectedToken: requestToken));
      }
    }
  }

  static String? _authorizationTokenFromRequest(http.BaseRequest? request) {
    if (request == null) {
      return null;
    }
    String authorization = '';
    for (final entry in request.headers.entries) {
      if (entry.key.toLowerCase() == 'authorization') {
        authorization = entry.value.trim();
        break;
      }
    }
    const prefix = 'Bearer ';
    return authorization.startsWith(prefix)
        ? authorization.substring(prefix.length).trim()
        : null;
  }

  static bool identicalSessionToken(String current, String expected) {
    return current.trim() == expected.trim();
  }
}
