import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:file_saver/file_saver.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../localization/app_localization.dart';
import '../localization/app_strings_ar.dart';
import '../localization/app_strings_en.dart';
import '../models/index.dart';
import 'app_config.dart';
import 'app_version_service.dart';
import 'app_alert_service.dart';
import 'auth_service.dart';
import 'error_message_service.dart';
import 'local_security_service.dart';
import 'network_client_service.dart';
import 'phone_number_service.dart';
import 'session_refreshing_http_client.dart';

class ApiService {
  ApiService({http.Client? client, AuthService? authService})
    : _authService = authService ?? AuthService(),
      _client = SessionRefreshingHttpClient(
        client ?? NetworkClientService.client,
        authService ?? AuthService(),
      );

  final AuthService _authService;
  bool lastCardLookupAutoRedeemed = false;
  final http.Client _client;
  static const Duration _publicRequestTimeout = Duration(seconds: 8);
  static const Duration _authenticatedRequestTimeout = Duration(seconds: 12);
  static const Duration _authSettingsCacheLifetime = Duration(minutes: 5);
  static const Duration _notificationSummaryCacheLifetime = Duration(
    seconds: 20,
  );
  static Map<String, dynamic>? _cachedAuthSettings;
  static DateTime? _cachedAuthSettingsAt;
  static Future<Map<String, dynamic>>? _pendingAuthSettingsRequest;
  static Map<String, dynamic>? _cachedNotificationSummary;
  static DateTime? _cachedNotificationSummaryAt;
  static String? _cachedNotificationSummaryOwnerId;
  static Future<Map<String, dynamic>>? _pendingNotificationSummaryRequest;
  static String? _pendingNotificationSummaryOwnerId;

  Future<Map<String, String>> _headers() async {
    final token = await _authService.token();
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

  Future<Map<String, String>> authenticatedHeaders() => _headers();

  Map<String, dynamic> _transactionConfirmationPayload({
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) {
    final normalizedOtp = otpCode?.trim() ?? '';
    if (normalizedOtp.isNotEmpty) {
      return {'otpCode': normalizedOtp};
    }

    final normalizedPin = securityPin?.trim() ?? '';
    if (normalizedPin.isNotEmpty) {
      return {'securityPin': normalizedPin};
    }

    final normalizedMethod = localAuthMethod?.trim() ?? '';
    return normalizedMethod.isEmpty
        ? const <String, dynamic>{}
        : {'localAuthMethod': normalizedMethod};
  }

  Uri adminVerificationFileUri({
    required String requestId,
    required String fileType,
  }) {
    return AppConfig.apiUri('admin/verifications/$requestId/files/$fileType');
  }

  Future<Map<String, String>> _publicHeaders() {
    return AppVersionService.publicHeaders();
  }

  Future<Map<String, dynamic>> getMyBalance({
    String locationFilter = 'all',
    int page = 1,
    int perPage = 8,
    bool printingDebtOnly = false,
  }) async {
    final response = await _client.get(
      AppConfig.apiUri('balance/me', {
        if (locationFilter != 'all') 'locationFilter': locationFilter,
        'page': page.toString(),
        'perPage': perPage.toString(),
        if (printingDebtOnly) 'printingDebtOnly': 'true',
      }),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    final responseUser = body['user'] is Map<String, dynamic>
        ? Map<String, dynamic>.from(body['user'] as Map<String, dynamic>)
        : body['user'] is Map
        ? Map<String, dynamic>.from(body['user'] as Map)
        : null;
    if (responseUser != null) {
      await _authService.cacheCurrentUser(responseUser);
    } else if (body['balance'] is num) {
      await _authService.patchCurrentUser({
        'balance': (body['balance'] as num).toDouble(),
      });
    }
    final user = responseUser ?? await _authService.currentUser();
    return {
      'user': user ?? <String, dynamic>{},
      'transactions': List<dynamic>.from(
        body['statement'] as List? ?? const [],
      ),
      'balance': body['balance'],
      'pagination': Map<String, dynamic>.from(
        body['pagination'] as Map? ?? const {},
      ),
      'summary': Map<String, dynamic>.from(body['summary'] as Map? ?? const {}),
    };
  }

  Future<Map<String, dynamic>> getContactInfo() async {
    final stopwatch = Stopwatch()..start();
    final response = await _client
        .get(
          AppConfig.apiUri('app/contact-info'),
          headers: await _publicHeaders(),
        )
        .timeout(_publicRequestTimeout);
    final body = _decodeObject(response);
    _debugLogRequest('GET', 'app/contact-info', stopwatch.elapsed);
    return Map<String, dynamic>.from(body['contact'] as Map? ?? const {});
  }

  Future<Map<String, dynamic>> getAuthSettings({bool refresh = false}) async {
    if (!refresh && _hasFreshCachedAuthSettings()) {
      return Map<String, dynamic>.from(_cachedAuthSettings!);
    }
    final pendingRequest = _pendingAuthSettingsRequest;
    if (!refresh && pendingRequest != null) {
      return Map<String, dynamic>.from(await pendingRequest);
    }

    final future = _fetchAuthSettings();
    _pendingAuthSettingsRequest = future;
    try {
      return Map<String, dynamic>.from(await future);
    } finally {
      if (identical(_pendingAuthSettingsRequest, future)) {
        _pendingAuthSettingsRequest = null;
      }
    }
  }

  static bool _hasFreshCachedAuthSettings() {
    final cached = _cachedAuthSettings;
    final cachedAt = _cachedAuthSettingsAt;
    if (cached == null || cachedAt == null) {
      return false;
    }
    return DateTime.now().difference(cachedAt) < _authSettingsCacheLifetime;
  }

  Future<Map<String, dynamic>> _fetchAuthSettings() async {
    final stopwatch = Stopwatch()..start();
    final response = await _client
        .get(
          AppConfig.apiUri('app/auth-settings'),
          headers: await _publicHeaders(),
        )
        .timeout(_publicRequestTimeout);
    final body = _decodeObject(response);
    final auth = Map<String, dynamic>.from(body['auth'] as Map? ?? const {});
    _cachedAuthSettings = Map<String, dynamic>.from(auth);
    _cachedAuthSettingsAt = DateTime.now();
    _debugLogRequest('GET', 'app/auth-settings', stopwatch.elapsed);
    return auth;
  }

  static void _debugLogRequest(String method, String path, Duration elapsed) {
    assert(() {
      // Keep network timing visible in debug runs without impacting release.
      // ignore: avoid_print
      print('[api] $method $path ${elapsed.inMilliseconds}ms');
      return true;
    }());
  }

  static void invalidateNotificationSummaryCache() {
    _cachedNotificationSummary = null;
    _cachedNotificationSummaryAt = null;
    _cachedNotificationSummaryOwnerId = null;
    _pendingNotificationSummaryRequest = null;
    _pendingNotificationSummaryOwnerId = null;
  }

  static void invalidateAuthSettingsCache() {
    _cachedAuthSettings = null;
    _cachedAuthSettingsAt = null;
    _pendingAuthSettingsRequest = null;
  }

  Future<Map<String, dynamic>> getTopupRequestSettings() async {
    final response = await _client.get(
      AppConfig.apiUri('app/topup-request-settings'),
      headers: await _publicHeaders(),
    );
    final body = _decodeObject(response);
    return Map<String, dynamic>.from(body['topupRequest'] as Map? ?? const {});
  }

  Future<Map<String, dynamic>> getAdminAffiliateSettings() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/settings/affiliate'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return Map<String, dynamic>.from(body['affiliate'] as Map? ?? const {});
  }

  Future<Map<String, dynamic>> getTransferSettings() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/settings/transfer'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return Map<String, dynamic>.from(body['transfer'] as Map? ?? const {});
  }

  Future<Map<String, dynamic>> getFeeSettings() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/settings/fees'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return Map<String, dynamic>.from(body['fees'] as Map? ?? const {});
  }

  Future<Map<String, dynamic>> getOfflineCardSettings() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/settings/offline-cards'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return Map<String, dynamic>.from(body['offlineCards'] as Map? ?? const {});
  }

  Future<Map<String, dynamic>> getPermissionTemplates() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/settings/permissions'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getUsagePolicy() async {
    final response = await _client.get(
      AppConfig.apiUri('app/usage-policy'),
      headers: await _publicHeaders(),
    );
    final body = _decodeObject(response);
    return Map<String, dynamic>.from(body['policy'] as Map? ?? const {});
  }

  Future<List<Map<String, dynamic>>> getSupportedLocations() async {
    final response = await _client.get(
      AppConfig.apiUri('app/supported-locations'),
      headers: await _publicHeaders(),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['locations'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<Map<String, dynamic>> getSupportedLocationsDashboard() async {
    final response = await _client.get(
      AppConfig.apiUri('supported-locations/dashboard'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return {
      'locations': List<Map<String, dynamic>>.from(
        (body['locations'] as List? ?? const []).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      ),
      'myLocations': List<Map<String, dynamic>>.from(
        (body['myLocations'] as List? ?? const []).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      ),
      'canSubmit': body['canSubmit'] == true,
    };
  }

  Future<List<Map<String, dynamic>>> getAdminSupportedLocations() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/supported-locations'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['locations'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> submitSupportedLocation({
    required String title,
    String displayName = '',
    required String address,
    required String phone,
    String displayPhone = '',
    String displayWhatsapp = '',
    required String type,
    required double latitude,
    required double longitude,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('supported-locations/submissions'),
      headers: await _headers(),
      body: jsonEncode({
        'title': title.trim(),
        'displayName': displayName.trim(),
        'address': address.trim(),
        'phone': phone.trim(),
        'displayPhone': displayPhone.trim(),
        'displayWhatsapp': displayWhatsapp.trim(),
        'type': type.trim(),
        'latitude': latitude,
        'longitude': longitude,
      }),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['myLocations'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> saveMySupportedLocation({
    required String locationId,
    required String title,
    String displayName = '',
    required String address,
    required String phone,
    String displayPhone = '',
    String displayWhatsapp = '',
    required String type,
    required double latitude,
    required double longitude,
    required bool isActive,
  }) async {
    final response = await _client.put(
      AppConfig.apiUri('supported-locations/my/$locationId'),
      headers: await _headers(),
      body: jsonEncode({
        'title': title.trim(),
        'displayName': displayName.trim(),
        'address': address.trim(),
        'phone': phone.trim(),
        'displayPhone': displayPhone.trim(),
        'displayWhatsapp': displayWhatsapp.trim(),
        'type': type.trim(),
        'latitude': latitude,
        'longitude': longitude,
        'isActive': isActive,
      }),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['myLocations'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> saveAdminSupportedLocation({
    String? locationId,
    required String title,
    required String address,
    required String phone,
    required String type,
    required double latitude,
    required double longitude,
    required bool isActive,
    required int sortOrder,
  }) async {
    final payload = {
      'title': title,
      'address': address,
      'phone': phone,
      'type': type,
      'latitude': latitude,
      'longitude': longitude,
      'isActive': isActive,
      'sortOrder': sortOrder,
    };
    final response = locationId == null
        ? await _client.post(
            AppConfig.apiUri('admin/supported-locations'),
            headers: await _headers(),
            body: jsonEncode(payload),
          )
        : await _client.put(
            AppConfig.apiUri('admin/supported-locations/$locationId'),
            headers: await _headers(),
            body: jsonEncode(payload),
          );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['locations'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> approveAdminSupportedLocation(
    String locationId,
  ) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/supported-locations/$locationId/approve'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['locations'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> rejectAdminSupportedLocation(
    String locationId, {
    String reason = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/supported-locations/$locationId/reject'),
      headers: await _headers(),
      body: jsonEncode({'reason': reason.trim()}),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['locations'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> deleteAdminSupportedLocation(
    String locationId,
  ) async {
    final response = await _client.delete(
      AppConfig.apiUri('admin/supported-locations/$locationId'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['locations'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<Map<String, dynamic>> getAdminCustomers({
    String query = '',
    int page = 1,
    int perPage = 25,
    String sort = 'newest',
    bool includeFinancialSummary = false,
  }) async {
    final params = <String, String>{
      'page': page.toString(),
      'perPage': perPage.toString(),
      'sort': sort,
      if (includeFinancialSummary) 'includeFinancialSummary': 'true',
    };
    if (query.trim().isNotEmpty) {
      params['q'] = query.trim();
    }
    final response = await _client.get(
      AppConfig.apiUri('admin/customers', params),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getAdminCustomerTransactions(
    String userId, {
    String locationFilter = 'all',
  }) async {
    final response = await _client.get(
      AppConfig.apiUri(
        'admin/customers/$userId/transactions',
        locationFilter == 'all' ? null : {'locationFilter': locationFilter},
      ),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<List<Map<String, dynamic>>> getSubUsers() async {
    final response = await _client.get(
      AppConfig.apiUri('sub-users'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['subUsers'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> createSubUser({
    required String fullName,
    required String username,
    required String password,
    required Map<String, bool> permissions,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('sub-users'),
      headers: await _headers(),
      body: jsonEncode({
        'fullName': fullName.trim(),
        'username': username.trim().toLowerCase(),
        'password': password,
        'permissions': permissions,
      }),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['subUsers'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> updateSubUser({
    required String subUserId,
    required String fullName,
    String? password,
    required Map<String, bool> permissions,
    bool isDisabled = false,
  }) async {
    final response = await _client.put(
      AppConfig.apiUri('sub-users/$subUserId'),
      headers: await _headers(),
      body: jsonEncode({
        'fullName': fullName.trim(),
        if (password != null && password.trim().isNotEmpty)
          'password': password.trim(),
        'permissions': permissions,
        'isDisabled': isDisabled,
      }),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['subUsers'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> transferSubUserBalance({
    required String subUserId,
    required String direction,
    required double amount,
    String notes = '',
    String? otpCode,
    String? securityPin,
  }) async {
    final payload = <String, dynamic>{
      'direction': direction,
      'amount': amount,
      'notes': notes.trim(),
    };
    payload.addAll(
      _transactionConfirmationPayload(
        otpCode: otpCode,
        securityPin: securityPin,
      ),
    );
    final response = await _client.post(
      AppConfig.apiUri('sub-users/$subUserId/balance-transfer'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    final body = _decodeObject(response);
    if (body['currentUser'] is Map) {
      await _authService.cacheCurrentUser(
        Map<String, dynamic>.from(body['currentUser'] as Map),
      );
    }
    return List<Map<String, dynamic>>.from(
      (body['subUsers'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<Map<String, dynamic>> getAdminUserDevices(String userId) async {
    final response = await _client.get(
      AppConfig.apiUri('admin/users/$userId/devices'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getAdminUserVerification(String userId) async {
    final response = await _client.get(
      AppConfig.apiUri('admin/users/$userId/verification'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<List<Map<String, dynamic>>> getPendingDeviceAccessRequests() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/devices/pending'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['requests'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> getPendingRegistrationRequests() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/registrations/pending'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['requests'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> getPendingWithdrawalRequests() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/withdrawals/pending'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['requests'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> getPendingTopupRequests() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/topup-requests/pending'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['requests'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> getPendingVerificationRequests() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/verifications/pending'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['requests'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<Map<String, dynamic>> getWithdrawalRequests({
    String? status,
    String query = '',
    int page = 1,
    int perPage = 8,
  }) async {
    final params = <String, String>{
      'page': page.toString(),
      'perPage': perPage.toString(),
    };
    if (status != null && status.trim().isNotEmpty && status.trim() != 'all') {
      params['status'] = status.trim();
    }
    if (query.trim().isNotEmpty) {
      params['q'] = query.trim();
    }
    final response = await _client.get(
      AppConfig.apiUri('admin/withdrawals', params),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getTopupRequests({
    String? status,
    String query = '',
    int page = 1,
    int perPage = 8,
  }) async {
    final params = <String, String>{
      'page': page.toString(),
      'perPage': perPage.toString(),
    };
    if (status != null && status.trim().isNotEmpty && status.trim() != 'all') {
      params['status'] = status.trim();
    }
    if (query.trim().isNotEmpty) {
      params['q'] = query.trim();
    }
    final response = await _client.get(
      AppConfig.apiUri('admin/topup-requests', params),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> approvePendingDeviceAccessRequest(
    String requestId, {
    String notes = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/devices/$requestId/approve'),
      headers: await _headers(),
      body: jsonEncode({if (notes.trim().isNotEmpty) 'notes': notes.trim()}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> rejectPendingDeviceAccessRequest(
    String requestId, {
    String notes = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/devices/$requestId/reject'),
      headers: await _headers(),
      body: jsonEncode({if (notes.trim().isNotEmpty) 'notes': notes.trim()}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> approvePendingVerificationRequest(
    String requestId, {
    String notes = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/verifications/$requestId/approve'),
      headers: await _headers(),
      body: jsonEncode({if (notes.trim().isNotEmpty) 'notes': notes.trim()}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> rejectPendingVerificationRequest(
    String requestId, {
    String notes = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/verifications/$requestId/reject'),
      headers: await _headers(),
      body: jsonEncode({if (notes.trim().isNotEmpty) 'notes': notes.trim()}),
    );
    return _decodeObject(response);
  }

  Future<void> downloadAdminVerificationFile({
    required String requestId,
    required String fileType,
    required String fileName,
  }) async {
    final response = await _client.get(
      adminVerificationFileUri(requestId: requestId, fileType: fileType),
      headers: await _headers(),
    );
    unawaited(_cacheRefreshedSession(response));

    if (response.statusCode >= 400) {
      _decodeObject(response);
    }

    final contentType = response.headers['content-type'] ?? '';
    final extension = contentType.contains('png')
        ? 'png'
        : contentType.contains('webp')
        ? 'webp'
        : 'jpg';
    final mimeType = extension == 'png'
        ? MimeType.png
        : extension == 'webp'
        ? MimeType.other
        : MimeType.jpeg;

    await FileSaver.instance.saveFile(
      name: fileName,
      bytes: response.bodyBytes,
      fileExtension: extension,
      mimeType: mimeType,
    );
  }

  Future<Map<String, dynamic>> approvePendingWithdrawalRequest(
    String requestId, {
    required String approvalImageBase64,
    String notes = '',
    String? otpCode,
    String? securityPin,
  }) async {
    final payload = <String, dynamic>{
      'approvalImageBase64': approvalImageBase64,
      if (notes.trim().isNotEmpty) 'notes': notes.trim(),
    };
    payload.addAll(
      _transactionConfirmationPayload(
        otpCode: otpCode,
        securityPin: securityPin,
      ),
    );
    final response = await _client.post(
      AppConfig.apiUri('admin/withdrawals/$requestId/approve'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> approvePendingTopupRequest(
    String requestId, {
    required String approvalImageBase64,
    String? otpCode,
    String? securityPin,
  }) async {
    final payload = <String, dynamic>{
      'approvalImageBase64': approvalImageBase64,
    };
    payload.addAll(
      _transactionConfirmationPayload(
        otpCode: otpCode,
        securityPin: securityPin,
      ),
    );
    final response = await _client.post(
      AppConfig.apiUri('admin/topup-requests/$requestId/approve'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> rejectPendingWithdrawalRequest(
    String requestId, {
    String notes = '',
    String approvalImageBase64 = '',
    String? otpCode,
    String? securityPin,
  }) async {
    final payload = <String, dynamic>{
      if (notes.trim().isNotEmpty) 'notes': notes.trim(),
      if (approvalImageBase64.trim().isNotEmpty)
        'approvalImageBase64': approvalImageBase64.trim(),
    };
    payload.addAll(
      _transactionConfirmationPayload(
        otpCode: otpCode,
        securityPin: securityPin,
      ),
    );
    final response = await _client.post(
      AppConfig.apiUri('admin/withdrawals/$requestId/reject'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> rejectPendingTopupRequest(
    String requestId, {
    String notes = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/topup-requests/$requestId/reject'),
      headers: await _headers(),
      body: jsonEncode({if (notes.trim().isNotEmpty) 'notes': notes.trim()}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> updateAdminUserDevicePolicy({
    required String userId,
    required bool allowMultiDevice,
    required int maxDevices,
  }) async {
    final response = await _client.put(
      AppConfig.apiUri('admin/users/$userId/device-policy'),
      headers: await _headers(),
      body: jsonEncode({
        'allowMultiDevice': allowMultiDevice,
        'maxDevices': maxDevices,
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> updateAdminUserCardPermissions({
    required String userId,
    required bool canIssueCards,
    required bool canIssueSubShekelCards,
    required bool canIssueHighValueCards,
    required bool canIssuePrivateCards,
    required bool canIssueSingleUseTickets,
    required bool canIssueAppointmentTickets,
    required bool canIssueQueueTickets,
    required bool canReadOwnPrivateCardsOnly,
    required bool canResellCards,
    required bool canRequestCardPrinting,
    required bool canManageCardPrintRequests,
    required bool canOfflineCardScan,
    required bool canManageDebtBook,
    required bool canManageUsers,
    required bool canFinanceTopup,
    required bool canUsePrepaidMultipayCards,
    required bool canAcceptPrepaidMultipayPayments,
    bool canUsePrepaidMultipayNfc = false,
    Map<String, bool> permissionOverrides = const {},
    bool restoreDefaults = false,
  }) async {
    final payload = <String, dynamic>{
      'canIssueCards': canIssueCards,
      'canIssueSubShekelCards': canIssueSubShekelCards,
      'canIssueHighValueCards': canIssueHighValueCards,
      'canIssuePrivateCards': canIssuePrivateCards,
      'canIssueSingleUseTickets': canIssueSingleUseTickets,
      'canIssueAppointmentTickets': canIssueAppointmentTickets,
      'canIssueQueueTickets': canIssueQueueTickets,
      'canReadOwnPrivateCardsOnly': canReadOwnPrivateCardsOnly,
      'canResellCards': canResellCards,
      'canRequestCardPrinting': canRequestCardPrinting,
      'canManageCardPrintRequests': canManageCardPrintRequests,
      'canOfflineCardScan': canOfflineCardScan,
      'canManageDebtBook': canManageDebtBook,
      'canManageUsers': canManageUsers,
      'canFinanceTopup': canFinanceTopup,
      'canUsePrepaidMultipayCards': canUsePrepaidMultipayCards,
      'canAcceptPrepaidMultipayPayments': canAcceptPrepaidMultipayPayments,
      'canUsePrepaidMultipayNfc': canUsePrepaidMultipayNfc,
      ...permissionOverrides,
      if (restoreDefaults) 'restoreDefaults': true,
    };
    final response = await _client.put(
      AppConfig.apiUri('admin/users/$userId/card-permissions'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getDebtBookSnapshot() async {
    final response = await _client.get(
      AppConfig.apiUri('debt-book/snapshot'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> syncDebtBook(
    List<Map<String, dynamic>> operations,
  ) async {
    final response = await _client.post(
      AppConfig.apiUri('debt-book/sync'),
      headers: await _headers(),
      body: jsonEncode({'operations': operations}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> updateAdminUserAccountControls({
    required String userId,
    String? businessName,
    String? fullName,
    String? username,
    String? whatsapp,
    String? email,
    String? address,
    String? nationalId,
    String? birthDate,
    String? referralPhone,
    String? printLogoBase64,
    bool removePrintLogo = false,
    required bool isDisabled,
    required String transferVerificationStatus,
    required String role,
    required double printingDebtLimit,
    double? customTopupFeePercent,
    double? customWithdrawFeePercent,
    double? customTransferFeePercent,
    double? customCardRedeemFeePercent,
    double? customCardResellFeePercent,
    double? customCardPrintRequestFeePercent,
    int? customCardScanLimit,
    bool cardScanLimitExempt = false,
    bool resetCardScanCounter = false,
    bool cardAutoRedeemOnScanForced = false,
  }) async {
    final payload = <String, dynamic>{
      'removePrintLogo': removePrintLogo,
      'isDisabled': isDisabled,
      'transferVerificationStatus': transferVerificationStatus,
      'role': role,
      'printingDebtLimit': printingDebtLimit,
      'customTopupFeePercent': customTopupFeePercent,
      'customWithdrawFeePercent': customWithdrawFeePercent,
      'customTransferFeePercent': customTransferFeePercent,
      'customCardRedeemFeePercent': customCardRedeemFeePercent,
      'customCardResellFeePercent': customCardResellFeePercent,
      'customCardPrintRequestFeePercent': customCardPrintRequestFeePercent,
      'customCardScanLimit': customCardScanLimit,
      'cardScanLimitExempt': cardScanLimitExempt,
      'resetCardScanCounter': resetCardScanCounter,
      'cardAutoRedeemOnScanForced': cardAutoRedeemOnScanForced,
    };
    if (businessName != null) payload['businessName'] = businessName;
    if (fullName != null) payload['fullName'] = fullName;
    if (username != null) payload['username'] = username;
    if (whatsapp != null) payload['whatsapp'] = whatsapp;
    if (email != null) payload['email'] = email;
    if (address != null) payload['address'] = address;
    if (nationalId != null) payload['nationalId'] = nationalId;
    if (birthDate != null) payload['birthDate'] = birthDate;
    if (referralPhone != null) payload['referralPhone'] = referralPhone;
    if (printLogoBase64 != null) payload['printLogoBase64'] = printLogoBase64;

    final response = await _client.put(
      AppConfig.apiUri('admin/users/$userId/account-controls'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getCardScanLimitSettings() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/settings/card-scan-limits'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return Map<String, dynamic>.from(
      body['cardScanLimits'] as Map? ?? const {},
    );
  }

  Future<Map<String, dynamic>> updateCardScanLimitSettings({
    required int defaultLimit,
    required int restrictedLimit,
    required int basicLimit,
    required int verifiedLimit,
    required int driverLimit,
    required int marketerLimit,
    required int supportLimit,
    required int financeLimit,
    required int adminLimit,
    required bool autoRedeemGlobalForced,
    required int withoutRedeemChargeEvery,
    required double withoutRedeemChargeAmount,
  }) async {
    final response = await _client.put(
      AppConfig.apiUri('admin/settings/card-scan-limits'),
      headers: await _headers(),
      body: jsonEncode({
        'defaultLimit': defaultLimit,
        'restrictedLimit': restrictedLimit,
        'basicLimit': basicLimit,
        'verifiedLimit': verifiedLimit,
        'driverLimit': driverLimit,
        'marketerLimit': marketerLimit,
        'supportLimit': supportLimit,
        'financeLimit': financeLimit,
        'adminLimit': adminLimit,
        'autoRedeemGlobalForced': autoRedeemGlobalForced,
        'withoutRedeemChargeEvery': withoutRedeemChargeEvery,
        'withoutRedeemChargeAmount': withoutRedeemChargeAmount,
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> updateFeeSettings({
    required double walletTopupPercent,
    required double walletTransferPercent,
    required double cardRedeemPercent,
    required double cardResellPercent,
    required double cardPrintRequestPercent,
    required int cardPrintCardsPerA4Page,
    required int cardPrintPageGroupSize,
    required double cardPrintPageGroupFee,
    required double withdrawPercent,
    required double standardCardIssueCost,
    required double deliveryCardIssueCost,
    required double privateCardIssueCost,
    required double singleUseTicketIssueCost,
    required double appointmentTicketIssueCost,
    required double queueTicketIssueCost,
    required double subscriptionCardIssueCost,
    required double attendanceCardIssueCost,
  }) async {
    final response = await _client.put(
      AppConfig.apiUri('admin/settings/fees'),
      headers: await _headers(),
      body: jsonEncode({
        'walletTopupPercent': walletTopupPercent,
        'walletTransferPercent': walletTransferPercent,
        'cardRedeemPercent': cardRedeemPercent,
        'cardResellPercent': cardResellPercent,
        'cardPrintRequestPercent': cardPrintRequestPercent,
        'cardPrintCardsPerA4Page': cardPrintCardsPerA4Page,
        'cardPrintPageGroupSize': cardPrintPageGroupSize,
        'cardPrintPageGroupFee': cardPrintPageGroupFee,
        'withdrawPercent': withdrawPercent,
        'standardCardIssueCost': standardCardIssueCost,
        'deliveryCardIssueCost': deliveryCardIssueCost,
        'privateCardIssueCost': privateCardIssueCost,
        'singleUseTicketIssueCost': singleUseTicketIssueCost,
        'appointmentTicketIssueCost': appointmentTicketIssueCost,
        'queueTicketIssueCost': queueTicketIssueCost,
        'subscriptionCardIssueCost': subscriptionCardIssueCost,
        'attendanceCardIssueCost': attendanceCardIssueCost,
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> updatePermissionTemplates({
    required Map<String, dynamic> templates,
  }) async {
    final response = await _client.put(
      AppConfig.apiUri('admin/settings/permissions'),
      headers: await _headers(),
      body: jsonEncode({'templates': templates}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getMyCardPrintRequests({
    int page = 1,
    int perPage = 12,
    bool compact = true,
  }) async {
    final response = await _client.get(
      AppConfig.apiUri('cards/print-requests', {
        'page': page.toString(),
        'perPage': perPage.toString(),
        'compact': compact ? 'true' : 'false',
      }),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> requestCardPrint({
    required String idempotencyKey,
    required double value,
    required int quantity,
    required String cardType,
    String notes = '',
    List<String> allowedUserIds = const [],
    List<String> allowedUserPhones = const [],
    String? validFrom,
    String? validUntil,
    Map<String, dynamic> cardDetails = const {},
    String? otpCode,
    String? securityPin,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('cards/print-requests'),
      headers: await _headers(),
      body: jsonEncode({
        'idempotencyKey': idempotencyKey.trim(),
        'value': value,
        'quantity': quantity,
        'cardType': cardType,
        'notes': notes.trim(),
        if (allowedUserIds.isNotEmpty) 'allowedUserIds': allowedUserIds,
        if (allowedUserPhones.isNotEmpty)
          'allowedUserPhones': allowedUserPhones,
        if ((validFrom ?? '').trim().isNotEmpty) 'validFrom': validFrom!.trim(),
        if ((validUntil ?? '').trim().isNotEmpty)
          'validUntil': validUntil!.trim(),
        if (cardDetails.isNotEmpty) 'cardDetails': cardDetails,
        ..._transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
        ),
      }),
    );
    final body = _decodeObject(response);
    if (body['user'] is Map<String, dynamic>) {
      await _authService.cacheCurrentUser(
        Map<String, dynamic>.from(body['user'] as Map<String, dynamic>),
      );
    } else if (body['user'] is Map) {
      await _authService.cacheCurrentUser(
        Map<String, dynamic>.from(body['user'] as Map),
      );
    }
    return body;
  }

  Future<Map<String, dynamic>> requestExistingCardsPrint({
    required String idempotencyKey,
    required List<String> cardIds,
    String notes = '',
    String? otpCode,
    String? securityPin,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('cards/print-requests/existing'),
      headers: await _headers(),
      body: jsonEncode({
        'idempotencyKey': idempotencyKey.trim(),
        'cardIds': cardIds.where((id) => id.trim().isNotEmpty).toList(),
        if (notes.trim().isNotEmpty) 'notes': notes.trim(),
        ..._transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
        ),
      }),
    );
    final body = _decodeObject(response);
    if (body['user'] is Map<String, dynamic>) {
      await _authService.cacheCurrentUser(
        Map<String, dynamic>.from(body['user'] as Map<String, dynamic>),
      );
    } else if (body['user'] is Map) {
      await _authService.cacheCurrentUser(
        Map<String, dynamic>.from(body['user'] as Map),
      );
    }
    return body;
  }

  Future<Map<String, dynamic>> getCardPrintRequests({
    String status = 'all',
    String query = '',
    int page = 1,
    int perPage = 8,
  }) async {
    final params = <String, String>{
      'status': status,
      'page': page.toString(),
      'perPage': perPage.toString(),
      // Printing and PDF export require the server-side card snapshot.  The
      // admin print screen deliberately requests the complete rows so a
      // completed order remains printable after a refresh.
      'compact': 'false',
    };
    if (query.trim().isNotEmpty) {
      params['q'] = query.trim();
    }
    final response = await _client.get(
      AppConfig.apiUri('admin/card-print-requests', params),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> createAdminCardPrintRequest({
    required String idempotencyKey,
    required String userId,
    required double value,
    required int quantity,
    required String cardType,
    String? chargeUserId,
    String notes = '',
    List<String> allowedUserIds = const [],
    List<String> allowedUserPhones = const [],
    String? validFrom,
    String? validUntil,
    Map<String, dynamic> cardDetails = const {},
    String? otpCode,
    String? securityPin,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/card-print-requests'),
      headers: await _headers(),
      body: jsonEncode({
        'idempotencyKey': idempotencyKey.trim(),
        'userId': userId,
        'value': value,
        'quantity': quantity,
        'cardType': cardType,
        if ((chargeUserId ?? '').trim().isNotEmpty)
          'chargeUserId': chargeUserId!.trim(),
        'notes': notes.trim(),
        if (allowedUserIds.isNotEmpty) 'allowedUserIds': allowedUserIds,
        if (allowedUserPhones.isNotEmpty)
          'allowedUserPhones': allowedUserPhones,
        if ((validFrom ?? '').trim().isNotEmpty) 'validFrom': validFrom!.trim(),
        if ((validUntil ?? '').trim().isNotEmpty)
          'validUntil': validUntil!.trim(),
        if (cardDetails.isNotEmpty) 'cardDetails': cardDetails,
        ..._transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
        ),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> approveCardPrintRequest(
    String requestId, {
    String notes = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/card-print-requests/$requestId/approve'),
      headers: await _headers(),
      body: jsonEncode({if (notes.trim().isNotEmpty) 'notes': notes.trim()}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> startCardPrintRequest(
    String requestId, {
    String notes = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/card-print-requests/$requestId/start'),
      headers: await _headers(),
      body: jsonEncode({if (notes.trim().isNotEmpty) 'notes': notes.trim()}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> readyCardPrintRequest(
    String requestId, {
    String notes = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/card-print-requests/$requestId/ready'),
      headers: await _headers(),
      body: jsonEncode({if (notes.trim().isNotEmpty) 'notes': notes.trim()}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> completeCardPrintRequest(
    String requestId, {
    String notes = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/card-print-requests/$requestId/complete'),
      headers: await _headers(),
      body: jsonEncode({if (notes.trim().isNotEmpty) 'notes': notes.trim()}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> markCardPrintRequestPrinted(
    String requestId,
  ) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/card-print-requests/$requestId/printed'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> overrideCardPrintRequestStatus(
    String requestId, {
    required String status,
    String notes = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/card-print-requests/$requestId/override-status'),
      headers: await _headers(),
      body: jsonEncode({
        'status': status.trim(),
        if (notes.trim().isNotEmpty) 'notes': notes.trim(),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> rejectCardPrintRequest(
    String requestId, {
    String notes = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/card-print-requests/$requestId/reject'),
      headers: await _headers(),
      body: jsonEncode({if (notes.trim().isNotEmpty) 'notes': notes.trim()}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> createAdminUser({
    required String username,
    required String whatsapp,
    String fullName = '',
    String password = '',
    String countryCode = '970',
    String deliveryMethod = 'whatsapp',
  }) async {
    final normalizedUsername = username.trim().toLowerCase();
    final normalizedWhatsapp = PhoneNumberService.normalize(
      input: whatsapp.trim(),
      defaultDialCode: countryCode.trim(),
    );

    final response = await _client.post(
      AppConfig.apiUri('admin/users'),
      headers: await _headers(),
      body: jsonEncode({
        'username': normalizedUsername,
        'whatsapp': normalizedWhatsapp,
        'fullName': fullName.trim(),
        'password': password,
        'countryCode': countryCode.trim(),
        'deliveryMethod': deliveryMethod.trim(),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> resendAdminUserAccountDetails({
    required String userId,
    bool regeneratePassword = true,
    String deliveryMethod = 'whatsapp',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/users/$userId/resend-account-details'),
      headers: await _headers(),
      body: jsonEncode({
        'regeneratePassword': regeneratePassword,
        'deliveryMethod': deliveryMethod.trim(),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> sendAdminUserOtp({
    required String userId,
  }) async {
    final headers = await _headers();
    final uri = AppConfig.apiUri('admin/users/$userId/send-otp');

    // Some production nodes still expose this admin action as GET only.
    // Try POST first to match the action semantics, then fall back safely.
    var response = await _client.post(
      uri,
      headers: headers,
      body: jsonEncode(const <String, dynamic>{}),
    );

    if (response.statusCode == 405) {
      response = await _client.get(uri, headers: headers);
    }

    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> settleAdminUserPrintingDebt({
    required String userId,
    String notes = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/users/$userId/settle-printing-debt'),
      headers: await _headers(),
      body: jsonEncode({if (notes.trim().isNotEmpty) 'notes': notes.trim()}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> updateAdminAuthSettings({
    required bool registrationEnabled,
    required bool loginOtpRequired,
    required bool registrationWhatsappVerificationRequired,
    required String whatsappUsageMode,
    required String messageDeliveryPriority,
    required bool adminAlertsWhatsappEnabled,
    required bool adminAlertsSmsEnabled,
    required String minSupportedVersion,
    required String latestVersion,
    required String androidStoreUrl,
    required String iosStoreUrl,
    required String webStoreUrl,
  }) async {
    final response = await _client.put(
      AppConfig.apiUri('admin/settings/auth'),
      headers: await _headers(),
      body: jsonEncode({
        'registrationEnabled': registrationEnabled,
        'loginOtpRequired': loginOtpRequired,
        'registrationWhatsappVerificationRequired':
            registrationWhatsappVerificationRequired,
        'whatsappUsageMode': whatsappUsageMode.trim(),
        'messageDeliveryPriority': messageDeliveryPriority.trim(),
        'adminAlertsWhatsappEnabled': adminAlertsWhatsappEnabled,
        'adminAlertsSmsEnabled': adminAlertsSmsEnabled,
        'minSupportedVersion': minSupportedVersion.trim(),
        'latestVersion': latestVersion.trim(),
        'androidStoreUrl': androidStoreUrl.trim(),
        'iosStoreUrl': iosStoreUrl.trim(),
        'webStoreUrl': webStoreUrl.trim(),
      }),
    );
    final body = _decodeObject(response);
    final auth = body['auth'];
    if (auth is Map) {
      _cachedAuthSettings = Map<String, dynamic>.from(auth);
      _cachedAuthSettingsAt = DateTime.now();
    } else {
      invalidateAuthSettingsCache();
    }
    return body;
  }

  Future<Map<String, dynamic>> updateAdminTransferSettings({
    required double unverifiedTransferLimit,
  }) async {
    final response = await _client.put(
      AppConfig.apiUri('admin/settings/transfer'),
      headers: await _headers(),
      body: jsonEncode({'unverifiedTransferLimit': unverifiedTransferLimit}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> updateAdminOfflineCardSettings({
    required double maxPendingAmount,
    required int maxPendingCount,
    required int maxCachedCards,
    required int syncIntervalMinutes,
  }) async {
    final response = await _client.put(
      AppConfig.apiUri('admin/settings/offline-cards'),
      headers: await _headers(),
      body: jsonEncode({
        'maxPendingAmount': maxPendingAmount,
        'maxPendingCount': maxPendingCount,
        'maxCachedCards': maxCachedCards,
        'syncIntervalMinutes': syncIntervalMinutes,
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getAdminTopupRequestSettings() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/settings/topup-request'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return Map<String, dynamic>.from(body['topupRequest'] as Map? ?? const {});
  }

  Future<Map<String, dynamic>> updateAdminTopupRequestSettings({
    required bool enabled,
    required String instructions,
    double? minAmount,
    double? maxAmount,
  }) async {
    final payload = <String, dynamic>{
      'enabled': enabled,
      'instructions': instructions.trim(),
    };
    if (minAmount != null) {
      payload['minAmount'] = minAmount;
    }
    if (maxAmount != null) {
      payload['maxAmount'] = maxAmount;
    }
    final response = await _client.put(
      AppConfig.apiUri('admin/settings/topup-request'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getAdminWithdrawalRequestSettings() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/settings/withdrawal-request'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return Map<String, dynamic>.from(
      body['withdrawalRequest'] as Map? ?? const {},
    );
  }

  Future<Map<String, dynamic>> updateAdminWithdrawalRequestSettings({
    required bool enabled,
    required String instructions,
    required double minAmount,
    required double maxAmount,
  }) async {
    final response = await _client.put(
      AppConfig.apiUri('admin/settings/withdrawal-request'),
      headers: await _headers(),
      body: jsonEncode({
        'enabled': enabled,
        'instructions': instructions.trim(),
        'minAmount': minAmount,
        'maxAmount': maxAmount,
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getCardQuantityLimitSettings() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/settings/card-quantity-limits'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return Map<String, dynamic>.from(
      body['cardQuantityLimits'] as Map? ?? const {},
    );
  }

  Future<Map<String, dynamic>> updateCardQuantityLimitSettings({
    required int defaultLimit,
    required int restrictedLimit,
    required int basicLimit,
    required int verifiedLimit,
    required int driverLimit,
    required int marketerLimit,
    required int supportLimit,
    required int financeLimit,
    required int adminLimit,
  }) async {
    final response = await _client.put(
      AppConfig.apiUri('admin/settings/card-quantity-limits'),
      headers: await _headers(),
      body: jsonEncode({
        'defaultLimit': defaultLimit,
        'restrictedLimit': restrictedLimit,
        'basicLimit': basicLimit,
        'verifiedLimit': verifiedLimit,
        'driverLimit': driverLimit,
        'marketerLimit': marketerLimit,
        'supportLimit': supportLimit,
        'financeLimit': financeLimit,
        'adminLimit': adminLimit,
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> updateAdminAffiliateSettings({
    required bool enabled,
    required double rewardAmount,
    required double firstTopupMinAmount,
    required double marketerDebtLimit,
  }) async {
    final response = await _client.put(
      AppConfig.apiUri('admin/settings/affiliate'),
      headers: await _headers(),
      body: jsonEncode({
        'enabled': enabled,
        'rewardAmount': rewardAmount,
        'firstTopupMinAmount': firstTopupMinAmount,
        'marketerDebtLimit': marketerDebtLimit,
      }),
    );
    return _decodeObject(response);
  }

  Future<List<Map<String, dynamic>>> getAdminTopupPaymentMethods() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/topup-payment-methods'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['methods'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> saveAdminTopupPaymentMethod({
    String? methodId,
    required String title,
    required String description,
    required String imageUrl,
    required String accountNumber,
    required bool isActive,
    required int sortOrder,
  }) async {
    final payload = {
      'title': title.trim(),
      'description': description.trim(),
      'imageUrl': imageUrl.trim(),
      'accountNumber': accountNumber.trim(),
      'isActive': isActive,
      'sortOrder': sortOrder,
    };
    final response = methodId == null
        ? await _client.post(
            AppConfig.apiUri('admin/topup-payment-methods'),
            headers: await _headers(),
            body: jsonEncode(payload),
          )
        : await _client.put(
            AppConfig.apiUri('admin/topup-payment-methods/$methodId'),
            headers: await _headers(),
            body: jsonEncode(payload),
          );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['methods'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> deleteAdminTopupPaymentMethod(
    String methodId,
  ) async {
    final response = await _client.delete(
      AppConfig.apiUri('admin/topup-payment-methods/$methodId'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['methods'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> getAdminWithdrawalMethods() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/withdrawal-methods'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['methods'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> saveAdminWithdrawalMethod({
    String? methodId,
    required String code,
    required String title,
    required String description,
    required String accountLabel,
    required bool requiresBankName,
    required bool isActive,
    required int sortOrder,
  }) async {
    final payload = {
      'code': code.trim(),
      'title': title.trim(),
      'description': description.trim(),
      'accountLabel': accountLabel.trim(),
      'requiresBankName': requiresBankName,
      'isActive': isActive,
      'sortOrder': sortOrder,
    };
    final response = methodId == null
        ? await _client.post(
            AppConfig.apiUri('admin/withdrawal-methods'),
            headers: await _headers(),
            body: jsonEncode(payload),
          )
        : await _client.put(
            AppConfig.apiUri('admin/withdrawal-methods/$methodId'),
            headers: await _headers(),
            body: jsonEncode(payload),
          );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['methods'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> deleteAdminWithdrawalMethod(
    String methodId,
  ) async {
    final response = await _client.delete(
      AppConfig.apiUri('admin/withdrawal-methods/$methodId'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['methods'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<Map<String, dynamic>> updatePrintLogo({
    String? logoBase64,
    bool remove = false,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('auth/profile/print-logo'),
      headers: await _headers(),
      body: jsonEncode({'logoBase64': logoBase64, 'remove': remove}),
    );
    final body = _decodeObject(response);
    await _syncCurrentUserFromPayload(body);
    return body;
  }

  Future<Map<String, dynamic>> updateAdminContactSettings({
    required String title,
    required String supportWhatsapp,
    required String supportEmail,
    required String address,
  }) async {
    final response = await _client.put(
      AppConfig.apiUri('admin/settings/contact'),
      headers: await _headers(),
      body: jsonEncode({
        'title': title,
        'supportWhatsapp': supportWhatsapp,
        'supportEmail': supportEmail,
        'address': address,
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> updateAdminUsagePolicy({
    required String title,
    required String content,
  }) async {
    final response = await _client.put(
      AppConfig.apiUri('admin/settings/usage-policy'),
      headers: await _headers(),
      body: jsonEncode({'title': title, 'content': content}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> updateContactInfo({
    required String title,
    required String supportWhatsapp,
    required String supportEmail,
    required String address,
  }) {
    return updateAdminContactSettings(
      title: title,
      supportWhatsapp: supportWhatsapp,
      supportEmail: supportEmail,
      address: address,
    );
  }

  Future<Map<String, dynamic>> updateAuthSettings({
    required bool registrationEnabled,
    required bool loginOtpRequired,
    required bool registrationWhatsappVerificationRequired,
    required String whatsappUsageMode,
    required String messageDeliveryPriority,
    required bool adminAlertsWhatsappEnabled,
    required bool adminAlertsSmsEnabled,
    required String minSupportedVersion,
    required String latestVersion,
    required String androidStoreUrl,
    required String iosStoreUrl,
    required String webStoreUrl,
  }) {
    return updateAdminAuthSettings(
      registrationEnabled: registrationEnabled,
      loginOtpRequired: loginOtpRequired,
      registrationWhatsappVerificationRequired:
          registrationWhatsappVerificationRequired,
      whatsappUsageMode: whatsappUsageMode,
      messageDeliveryPriority: messageDeliveryPriority,
      adminAlertsWhatsappEnabled: adminAlertsWhatsappEnabled,
      adminAlertsSmsEnabled: adminAlertsSmsEnabled,
      minSupportedVersion: minSupportedVersion,
      latestVersion: latestVersion,
      androidStoreUrl: androidStoreUrl,
      iosStoreUrl: iosStoreUrl,
      webStoreUrl: webStoreUrl,
    );
  }

  Future<Map<String, dynamic>> getAdminMessageGatewayDashboard() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/message-gateway/dashboard'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getAdminDashboard({
    String period = 'daily',
  }) async {
    final response = await _client.get(
      AppConfig.apiUri('admin/dashboard', {'period': period}),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> toggleWhatsAppGatewayChannel({
    required String channelKey,
    required bool enabled,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/message-gateway/whatsapp/$channelKey/toggle'),
      headers: await _headers(),
      body: jsonEncode({'enabled': enabled}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> testWhatsAppGatewayChannel({
    required String channelKey,
    String phone = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/message-gateway/whatsapp/$channelKey/test'),
      headers: await _headers(),
      body: jsonEncode({if (phone.trim().isNotEmpty) 'phone': phone.trim()}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> testSmsGateway({String phone = ''}) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/message-gateway/sms/test'),
      headers: await _headers(),
      body: jsonEncode({if (phone.trim().isNotEmpty) 'phone': phone.trim()}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> updateTransferSettings({
    required double unverifiedTransferLimit,
  }) {
    return updateAdminTransferSettings(
      unverifiedTransferLimit: unverifiedTransferLimit,
    );
  }

  Future<Map<String, dynamic>> updateUsagePolicy({
    required String title,
    required String content,
  }) {
    return updateAdminUsagePolicy(title: title, content: content);
  }

  Future<Map<String, dynamic>> updateAffiliateSettings({
    required bool enabled,
    required double rewardAmount,
    required double firstTopupMinAmount,
    required double marketerDebtLimit,
  }) {
    return updateAdminAffiliateSettings(
      enabled: enabled,
      rewardAmount: rewardAmount,
      firstTopupMinAmount: firstTopupMinAmount,
      marketerDebtLimit: marketerDebtLimit,
    );
  }

  Future<Map<String, dynamic>> reviewDeviceAccessRequest(
    String requestId, {
    required bool approve,
    String notes = '',
  }) {
    return approve
        ? approvePendingDeviceAccessRequest(requestId, notes: notes)
        : rejectPendingDeviceAccessRequest(requestId, notes: notes);
  }

  Future<Map<String, dynamic>> reviewWithdrawalRequest(
    String requestId, {
    required bool approve,
    String notes = '',
    String approvalImageBase64 = '',
  }) {
    return approve
        ? approvePendingWithdrawalRequest(
            requestId,
            approvalImageBase64: approvalImageBase64,
            notes: notes,
          )
        : rejectPendingWithdrawalRequest(
            requestId,
            notes: notes,
            approvalImageBase64: approvalImageBase64,
          );
  }

  Future<Map<String, dynamic>> reviewTopupRequest(
    String requestId, {
    required bool approve,
    String notes = '',
    String approvalImageBase64 = '',
  }) {
    return approve
        ? approvePendingTopupRequest(
            requestId,
            approvalImageBase64: approvalImageBase64,
          )
        : rejectPendingTopupRequest(requestId, notes: notes);
  }

  Future<Map<String, dynamic>> releaseAdminUserDevice({
    required String userId,
    required String deviceRecordId,
  }) async {
    final response = await _client.delete(
      AppConfig.apiUri('admin/users/$userId/devices/$deviceRecordId'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> releaseAllAdminUserDevices({
    required String userId,
  }) async {
    final response = await _client.delete(
      AppConfig.apiUri('admin/users/$userId/devices'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getMyDevices() async {
    final response = await _client.get(
      AppConfig.apiUri('auth/devices'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> releaseMyDevice({
    required String deviceRecordId,
  }) async {
    final response = await _client.delete(
      AppConfig.apiUri('auth/devices/$deviceRecordId'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<OtpRequestResult> requestTransferSecurityOtp() async {
    final response = await _client.post(
      AppConfig.apiUri('auth/transfer-security/request-otp'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return OtpRequestResult(
      message: body['message']?.toString(),
      whatsapp: body['whatsapp']?.toString(),
      debugOtpCode: body['debugOtpCode']?.toString(),
    );
  }

  Future<void> exportCustomerTransactionsCsv({
    required Map<String, dynamic> customer,
    required List<Map<String, dynamic>> transactions,
  }) async {
    final buffer = StringBuffer();
    buffer.writeln(
      '\uFEFFid,type,amount,fee,description,location_status,nearest_branch,created_at',
    );
    for (final item in transactions) {
      final description = (item['description']?.toString() ?? '').replaceAll(
        '"',
        '""',
      );
      final metadata = Map<String, dynamic>.from(
        item['metadata'] as Map? ?? const {},
      );
      final audit = Map<String, dynamic>.from(
        metadata['locationAudit'] as Map? ?? const {},
      );
      final locationStatus = audit.isEmpty
          ? ''
          : (audit['isNearSupportedBranch'] == true
                ? 'near_branch'
                : 'outside_branches');
      final nearestBranch =
          (audit['nearestBranch'] as Map?)?['title']?.toString().replaceAll(
            '"',
            '""',
          ) ??
          '';
      buffer.writeln(
        '${item['id'] ?? ''},${item['type'] ?? ''},${item['amount'] ?? ''},${item['fee'] ?? ''},"$description",$locationStatus,"$nearestBranch",${item['createdAt'] ?? ''}',
      );
    }
    final bytes = Uint8List.fromList(utf8.encode(buffer.toString()));
    final fileName =
        'customer_${customer['username'] ?? customer['id']}_transactions';
    await FileSaver.instance.saveFile(
      name: fileName,
      bytes: bytes,
      fileExtension: 'csv',
      mimeType: MimeType.csv,
    );
  }

  Future<void> exportMyTransactionsCsv({
    required List<Map<String, dynamic>> transactions,
  }) async {
    final user = await _authService.currentUser();
    await exportCustomerTransactionsCsv(
      customer: user ?? const <String, dynamic>{'username': 'my'},
      transactions: transactions,
    );
  }

  Future<List<Map<String, dynamic>>> searchUsers(String query) async {
    final response = await _client.get(
      AppConfig.apiUri('users', {'q': query}),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return List<dynamic>.from(
      body['users'] as List? ?? const [],
    ).map((item) => Map<String, dynamic>.from(item as Map)).toList();
  }

  Future<Map<String, dynamic>> lookupUserByPhone({
    required String phone,
    required String countryCode,
    bool inviteIfMissing = false,
  }) async {
    final response = await _client.get(
      AppConfig.apiUri('users/lookup-by-phone', {
        'phone': phone,
        'countryCode': countryCode,
        if (inviteIfMissing) 'invite': '1',
      }),
      headers: await _headers(),
    );
    unawaited(_cacheRefreshedSession(response));
    if (response.statusCode == 404) {
      return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    }
    final body = _decodeObject(response);
    return Map<String, dynamic>.from(body);
  }

  Future<Map<String, dynamic>> sendCardRecipientInvite({
    required String phone,
    required String countryCode,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('cards/recipient-invite'),
      headers: await _headers(),
      body: jsonEncode({
        'phone': phone.trim(),
        'countryCode': countryCode.trim(),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> topUpUser({
    required String userId,
    required double amount,
    String notes = '',
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
    Map<String, dynamic>? location,
  }) async {
    final payload = <String, dynamic>{
      'userId': userId,
      'amount': amount,
      'notes': notes,
    };
    if (location != null) {
      payload['location'] = location;
    }
    if (otpCode != null && otpCode.trim().isNotEmpty) {
      payload['otpCode'] = otpCode.trim();
    } else if (securityPin != null && securityPin.trim().isNotEmpty) {
      payload['securityPin'] = securityPin.trim();
    } else if (localAuthMethod != null && localAuthMethod.trim().isNotEmpty) {
      payload['localAuthMethod'] = localAuthMethod.trim();
    }
    final response = await _client.post(
      AppConfig.apiUri('wallet/topup'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> addAdminUserBalance({
    required String userId,
    required double amount,
    String notes = '',
    String? otpCode,
    String? securityPin,
  }) async {
    final payload = <String, dynamic>{'amount': amount, 'notes': notes};
    payload.addAll(
      _transactionConfirmationPayload(
        otpCode: otpCode,
        securityPin: securityPin,
      ),
    );
    final response = await _client.post(
      AppConfig.apiUri('admin/users/$userId/add-balance'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> deductAdminUserBalance({
    required String userId,
    required double amount,
    String notes = '',
    String? otpCode,
    String? securityPin,
  }) async {
    final payload = <String, dynamic>{'amount': amount, 'notes': notes};
    payload.addAll(
      _transactionConfirmationPayload(
        otpCode: otpCode,
        securityPin: securityPin,
      ),
    );
    final response = await _client.post(
      AppConfig.apiUri('admin/users/$userId/deduct-balance'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> transferBalance({
    required String recipientId,
    required double amount,
    String notes = '',
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
    Map<String, dynamic>? location,
  }) async {
    final payload = <String, dynamic>{
      'recipientId': recipientId,
      'amount': amount,
      'notes': notes,
    };
    if (location != null) {
      payload['location'] = location;
    }
    if (otpCode != null && otpCode.trim().isNotEmpty) {
      payload['otpCode'] = otpCode.trim();
    } else if (securityPin != null && securityPin.trim().isNotEmpty) {
      payload['securityPin'] = securityPin.trim();
    } else if (localAuthMethod != null && localAuthMethod.trim().isNotEmpty) {
      payload['localAuthMethod'] = localAuthMethod.trim();
    }
    final response = await _client.post(
      AppConfig.apiUri('wallet/transfer'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    final body = _decodeObject(response);
    await _patchCachedBalanceFromPayload(body);
    return body;
  }

  Future<Map<String, dynamic>> createTemporaryTransferCode({
    required double amount,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final payload = <String, dynamic>{'amount': amount};
    if (otpCode != null && otpCode.trim().isNotEmpty) {
      payload['otpCode'] = otpCode.trim();
    } else if (securityPin != null && securityPin.trim().isNotEmpty) {
      payload['securityPin'] = securityPin.trim();
    } else if (localAuthMethod != null && localAuthMethod.trim().isNotEmpty) {
      payload['localAuthMethod'] = localAuthMethod.trim();
    }
    final response = await _client.post(
      AppConfig.apiUri('wallet/temporary-transfer-code'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> approvePendingRegistrationRequest(
    String requestId, {
    bool allowUnverifiedWhatsapp = false,
    String deliveryMethod = 'whatsapp',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/registrations/$requestId/approve'),
      headers: await _headers(),
      body: jsonEncode({
        'allowUnverifiedWhatsapp': allowUnverifiedWhatsapp,
        'deliveryMethod': deliveryMethod.trim(),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> confirmPendingRegistrationWithoutOtp(
    String requestId,
  ) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/registrations/$requestId/confirm-without-otp'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> updatePendingRegistrationWhatsapp(
    String requestId, {
    required String whatsapp,
    String countryCode = '970',
  }) async {
    final normalizedWhatsapp = PhoneNumberService.normalize(
      input: whatsapp.trim(),
      defaultDialCode: countryCode.trim(),
    );
    final response = await _client.put(
      AppConfig.apiUri('admin/registrations/$requestId/whatsapp'),
      headers: await _headers(),
      body: jsonEncode({'whatsapp': normalizedWhatsapp}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> rejectPendingRegistrationRequest(
    String requestId, {
    String reason = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/registrations/$requestId/reject'),
      headers: await _headers(),
      body: jsonEncode({'rejectionReason': reason.trim()}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> prefetchTemporaryTransferCodes({
    required String deviceId,
    int count = 5,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('wallet/temporary-transfer-code/prefetch'),
      headers: await _headers(),
      body: jsonEncode({'deviceId': deviceId, 'count': count}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> redeemTemporaryTransferCode({
    required String payload,
    Map<String, dynamic>? location,
  }) async {
    final requestPayload = <String, dynamic>{'payload': payload};
    if (location != null) {
      requestPayload['location'] = location;
    }
    final response = await _client.post(
      AppConfig.apiUri('wallet/temporary-transfer-code/redeem'),
      headers: await _headers(),
      body: jsonEncode(requestPayload),
    );
    final body = _decodeObject(response);
    await _patchCachedBalanceFromPayload(body);
    return body;
  }

  Future<Map<String, dynamic>> requestWithdrawal({
    required double amount,
    required String destinationType,
    required String destinationAccount,
    required String accountHolderName,
    String? bankName,
    String notes = '',
    required bool agreementAccepted,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
    Map<String, dynamic>? location,
  }) async {
    final payload = <String, dynamic>{
      'amount': amount,
      'destinationType': destinationType,
      'destinationAccount': destinationAccount,
      'accountHolderName': accountHolderName,
      'notes': notes,
      'agreementAccepted': agreementAccepted,
    };
    if (bankName != null && bankName.trim().isNotEmpty) {
      payload['bankName'] = bankName.trim();
    }
    if (location != null) {
      payload['location'] = location;
    }
    payload.addAll(
      _transactionConfirmationPayload(
        otpCode: otpCode,
        securityPin: securityPin,
        localAuthMethod: localAuthMethod,
      ),
    );
    final response = await _client.post(
      AppConfig.apiUri('wallet/withdrawal'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    final body = _decodeObject(response);
    await _patchCachedBalanceFromPayload(body);
    return body;
  }

  Future<Map<String, dynamic>> getWithdrawalRequestOptions() async {
    final response = await _client.get(
      AppConfig.apiUri('wallet/withdrawal/options'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getTopupRequestOptions() async {
    final response = await _client.get(
      AppConfig.apiUri('wallet/topup-request/options'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getAffiliateDashboard() async {
    final response = await _client.get(
      AppConfig.apiUri('affiliate/dashboard'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> requestTopup({
    required double amount,
    required String paymentMethodId,
    String senderName = '',
    String senderPhone = '',
    String transferReference = '',
    String? transferredAt,
    String notes = '',
  }) async {
    final payload = <String, dynamic>{
      'amount': amount,
      'paymentMethodId': paymentMethodId,
      'senderName': senderName.trim(),
      'senderPhone': senderPhone.trim(),
      'transferReference': transferReference.trim(),
      'notes': notes.trim(),
    };
    if (transferredAt != null && transferredAt.trim().isNotEmpty) {
      payload['transferredAt'] = transferredAt.trim();
    }
    final response = await _client.post(
      AppConfig.apiUri('wallet/topup-request'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getVerificationStatus() async {
    final response = await _client.get(
      AppConfig.apiUri('auth/verification'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> submitVerification({
    required String identityDocumentBase64,
    required String selfieImageBase64,
    required String fullName,
    required String nationalId,
    required String birthDate,
    String requestedRole = 'verified_member',
    String notes = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('auth/verification'),
      headers: await _headers(),
      body: jsonEncode({
        'identityDocumentBase64': identityDocumentBase64,
        'selfieImageBase64': selfieImageBase64,
        'fullName': fullName.trim(),
        'nationalId': nationalId.trim(),
        'birthDate': birthDate.trim(),
        'requestedRole': requestedRole,
        'notes': notes,
      }),
    );
    final body = _decodeObject(response);
    final nextStatus = body['status']?.toString();
    await _authService.patchCurrentUser({
      if (nextStatus != null && nextStatus.isNotEmpty)
        'transferVerificationStatus': nextStatus,
    });
    return body;
  }

  Future<List<VirtualCard>> issueCards({
    required double value,
    required int quantity,
    List<String> allowedUserIds = const [],
    List<String> allowedUserPhones = const [],
    String visibilityScope = 'general',
    String cardType = 'standard',
    Map<String, dynamic>? printDesign,
    String? validFrom,
    String? validUntil,
    Map<String, dynamic>? cardDetails,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
    String? customBarcode,
  }) async {
    final payload = <String, dynamic>{
      'value': value,
      'quantity': quantity,
      'cardType': cardType,
      if (allowedUserIds.isNotEmpty) 'allowedUserIds': allowedUserIds,
      if (allowedUserPhones.isNotEmpty) 'allowedUserPhones': allowedUserPhones,
      if (visibilityScope.trim().isNotEmpty) 'visibilityScope': visibilityScope,
      ...?printDesign == null ? null : {'printDesign': printDesign},
      if (validFrom != null && validFrom.trim().isNotEmpty)
        'validFrom': validFrom,
      if (validUntil != null && validUntil.trim().isNotEmpty)
        'validUntil': validUntil,
      ...?cardDetails == null ? null : {'cardDetails': cardDetails},
      if (customBarcode != null && customBarcode.trim().isNotEmpty)
        'customBarcode': customBarcode.trim(),
      if (otpCode != null && otpCode.trim().isNotEmpty)
        'otpCode': otpCode.trim(),
      if ((otpCode == null || otpCode.trim().isEmpty) &&
          securityPin != null &&
          securityPin.trim().isNotEmpty)
        'securityPin': securityPin.trim(),
      if (otpCode == null || otpCode.trim().isEmpty)
        if ((securityPin == null || securityPin.trim().isEmpty) &&
            localAuthMethod != null &&
            localAuthMethod.trim().isNotEmpty)
          'localAuthMethod': localAuthMethod.trim(),
    };
    final response = await _client.post(
      AppConfig.apiUri('cards/issue'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    final body = _decodeObject(response);
    await _authService.patchCurrentUser({
      if (body['balance'] is num)
        'balance': (body['balance'] as num).toDouble(),
      if (body['availablePrintingBalance'] is num)
        'availablePrintingBalance': (body['availablePrintingBalance'] as num)
            .toDouble(),
    });
    final rawCards = List<dynamic>.from(body['cards'] as List? ?? const []);
    return rawCards
        .map((item) => _cardFromApi(Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<Map<String, dynamic>> renewSubscriptionCard({
    required String cardId,
    int? durationDays,
    String? validFrom,
    String? validUntil,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final payload = <String, dynamic>{};
    if (durationDays != null) payload['durationDays'] = durationDays;
    if (validFrom != null && validFrom.trim().isNotEmpty) {
      payload['validFrom'] = validFrom.trim();
    }
    if (validUntil != null && validUntil.trim().isNotEmpty) {
      payload['validUntil'] = validUntil.trim();
    }
    if (otpCode != null && otpCode.trim().isNotEmpty) {
      payload['otpCode'] = otpCode.trim();
    } else if (securityPin != null && securityPin.trim().isNotEmpty) {
      payload['securityPin'] = securityPin.trim();
    } else if (localAuthMethod != null && localAuthMethod.trim().isNotEmpty) {
      payload['localAuthMethod'] = localAuthMethod.trim();
    }
    final response = await _client.post(
      AppConfig.apiUri('cards/$cardId/subscription/renew'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    final body = _decodeObject(response);
    await _authService.patchCurrentUser({
      if (body['balance'] is num)
        'balance': (body['balance'] as num).toDouble(),
      if (body['availablePrintingBalance'] is num)
        'availablePrintingBalance': (body['availablePrintingBalance'] as num)
            .toDouble(),
    });
    if (body['card'] is Map) {
      body['card'] = _cardFromApi(
        Map<String, dynamic>.from(body['card'] as Map),
      );
    }
    return body;
  }

  Future<List<VirtualCard>> issueTrialCards({
    required List<Map<String, dynamic>> items,
    String cardType = 'standard',
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final normalizedCardType = cardType.trim().isEmpty
        ? 'standard'
        : cardType.trim();
    final payload = <String, dynamic>{
      'items': items,
      'cardType': normalizedCardType,
      if (otpCode != null && otpCode.trim().isNotEmpty)
        'otpCode': otpCode.trim(),
      if ((otpCode == null || otpCode.trim().isEmpty) &&
          securityPin != null &&
          securityPin.trim().isNotEmpty)
        'securityPin': securityPin.trim(),
      if (otpCode == null || otpCode.trim().isEmpty)
        if ((securityPin == null || securityPin.trim().isEmpty) &&
            localAuthMethod != null &&
            localAuthMethod.trim().isNotEmpty)
          'localAuthMethod': localAuthMethod.trim(),
    };
    final response = await _client.post(
      AppConfig.apiUri('cards/trial-issue'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    final body = _decodeObject(response);
    await _authService.patchCurrentUser({
      if (body['balance'] is num)
        'balance': (body['balance'] as num).toDouble(),
      if (body['trialCardsLimit'] is num)
        'trialCardsLimit': (body['trialCardsLimit'] as num).toDouble(),
      if (body['trialCardsOutstandingAmount'] is num)
        'trialCardsOutstandingAmount':
            (body['trialCardsOutstandingAmount'] as num).toDouble(),
      if (body['trialCardsRemainingAmount'] is num)
        'trialCardsAvailableAmount': (body['trialCardsRemainingAmount'] as num)
            .toDouble(),
    });
    final rawCards = List<dynamic>.from(body['cards'] as List? ?? const []);
    return rawCards
        .map((item) => _cardFromApi(Map<String, dynamic>.from(item as Map)))
        .toList();
  }

  Future<Map<String, dynamic>> getMyCards({
    String? status,
    int page = 1,
    int perPage = 12,
  }) async {
    final query = <String, String>{
      'page': page.toString(),
      'perPage': perPage.toString(),
    };
    if (status != null && status.trim().isNotEmpty) {
      query['status'] = status.trim();
    }
    final response = await _client.get(
      AppConfig.apiUri('cards', query.isEmpty ? null : query),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    final rawCards = List<dynamic>.from(body['cards'] as List? ?? const []);
    return {
      'cards': rawCards
          .map((item) => _cardFromApi(Map<String, dynamic>.from(item as Map)))
          .toList(),
      'pagination': Map<String, dynamic>.from(
        body['pagination'] as Map? ?? const {},
      ),
      'summary': Map<String, dynamic>.from(body['summary'] as Map? ?? const {}),
    };
  }

  Future<Map<String, dynamic>> getAdminCards({
    String? status,
    String creator = '',
    double? valueMin,
    double? valueMax,
    String issuedFrom = '',
    String issuedTo = '',
    int page = 1,
    int perPage = 24,
  }) async {
    final query = <String, String>{
      'page': page.toString(),
      'perPage': perPage.toString(),
    };
    if (status != null && status.trim().isNotEmpty && status.trim() != 'all') {
      query['status'] = status.trim();
    }
    if (creator.trim().isNotEmpty) {
      query['creator'] = creator.trim();
    }
    if (valueMin != null) {
      query['valueMin'] = valueMin.toString();
    }
    if (valueMax != null) {
      query['valueMax'] = valueMax.toString();
    }
    if (issuedFrom.trim().isNotEmpty) {
      query['issuedFrom'] = issuedFrom.trim();
    }
    if (issuedTo.trim().isNotEmpty) {
      query['issuedTo'] = issuedTo.trim();
    }
    final response = await _client.get(
      AppConfig.apiUri('admin/cards', query),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    final rawCards = List<dynamic>.from(body['cards'] as List? ?? const []);
    return {
      'cards': rawCards
          .map((item) => _cardFromApi(Map<String, dynamic>.from(item as Map)))
          .toList(),
      'pagination': Map<String, dynamic>.from(
        body['pagination'] as Map? ?? const {},
      ),
      'summary': Map<String, dynamic>.from(body['summary'] as Map? ?? const {}),
      'filters': Map<String, dynamic>.from(body['filters'] as Map? ?? const {}),
    };
  }

  Future<Map<String, dynamic>> createAdminCardForUser({
    required String userId,
    required double value,
    required int quantity,
    String cardType = 'standard',
    String notes = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/users/$userId/cards'),
      headers: await _headers(),
      body: jsonEncode({
        'value': value,
        'quantity': quantity,
        'cardType': cardType,
        if (notes.trim().isNotEmpty) 'notes': notes.trim(),
      }),
    );
    final body = _decodeObject(response);
    final rawCards = List<dynamic>.from(body['cards'] as List? ?? const []);
    return {
      ...body,
      'cards': rawCards
          .map((item) => _cardFromApi(Map<String, dynamic>.from(item as Map)))
          .toList(),
    };
  }

  Future<Map<String, dynamic>> transferAdminCard({
    required String cardId,
    required String targetUserId,
    String notes = '',
    String? otpCode,
    String? securityPin,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/cards/$cardId/transfer'),
      headers: await _headers(),
      body: jsonEncode({
        'targetUserId': targetUserId,
        if (notes.trim().isNotEmpty) 'notes': notes.trim(),
        ..._transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
        ),
      }),
    );
    final body = _decodeObject(response);
    if (body['card'] is Map) {
      body['card'] = _cardFromApi(
        Map<String, dynamic>.from(body['card'] as Map),
      );
    }
    return body;
  }

  Future<void> deleteAdminCard(
    String cardId, {
    String? otpCode,
    String? securityPin,
  }) async {
    final response = await _client.delete(
      AppConfig.apiUri('admin/cards/$cardId'),
      headers: await _headers(),
      body: jsonEncode(
        _transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
        ),
      ),
    );
    _decodeObject(response);
  }

  Future<Map<String, dynamic>> getOfflineCardCache() async {
    final response = await _client.get(
      AppConfig.apiUri('cards/offline-cache'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    final cards = List<dynamic>.from(body['cards'] as List? ?? const []);
    return {
      ...body,
      'cards': cards
          .map((item) => _cardFromApi(Map<String, dynamic>.from(item as Map)))
          .toList(),
      'settings': Map<String, dynamic>.from(
        body['settings'] as Map? ?? const {},
      ),
    };
  }

  Future<void> deleteCard(
    String cardId, {
    String? otpCode,
    String? securityPin,
  }) async {
    final response = await _client.delete(
      AppConfig.apiUri('cards/$cardId'),
      headers: await _headers(),
      body: jsonEncode(
        _transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
        ),
      ),
    );
    final body = _decodeObject(response);
    await _patchCachedBalanceFromPayload(body);
    await _authService.patchCurrentUser({
      if (body['trialCardsLimit'] is num)
        'trialCardsLimit': (body['trialCardsLimit'] as num).toDouble(),
      if (body['trialCardsOutstandingAmount'] is num)
        'trialCardsOutstandingAmount':
            (body['trialCardsOutstandingAmount'] as num).toDouble(),
      if (body['trialCardsRemainingAmount'] is num)
        'trialCardsAvailableAmount': (body['trialCardsRemainingAmount'] as num)
            .toDouble(),
    });
  }

  Future<VirtualCard> updateCardAudience(
    String cardId, {
    List<String> allowedUserIds = const [],
    List<String> allowedUserPhones = const [],
  }) async {
    final response = await _client.put(
      AppConfig.apiUri('cards/$cardId/audience'),
      headers: await _headers(),
      body: jsonEncode({
        'allowedUserIds': allowedUserIds,
        'allowedUserPhones': allowedUserPhones,
      }),
    );
    final body = _decodeObject(response);
    return _cardFromApi(Map<String, dynamic>.from(body['card'] as Map));
  }

  Future<VirtualCard?> getCardByBarcode(
    String barcode, {
    bool autoRedeem = false,
    Map<String, dynamic>? location,
  }) async {
    lastCardLookupAutoRedeemed = false;
    final query = <String, String>{};
    if (autoRedeem) {
      query['autoRedeem'] = '1';
    }
    if (location != null) {
      // Server accepts either `location[lat]=..` style or a json string; we use json for simplicity.
      query['location'] = jsonEncode(location);
    }
    final response = await _client.get(
      AppConfig.apiUri('cards/$barcode', query.isEmpty ? null : query),
      headers: await _headers(),
    );
    if (response.statusCode == 404) {
      return null;
    }
    final body = _decodeObject(response);
    await _patchCachedBalanceFromPayload(body);
    if (body['user'] is Map) {
      await _authService.patchCurrentUser(
        Map<String, dynamic>.from(body['user'] as Map),
      );
    }
    lastCardLookupAutoRedeemed = body['autoRedeemed'] == true;
    final cardMap = Map<String, dynamic>.from(body['card'] as Map);
    if (body['attendanceScan'] is Map) {
      final details = Map<String, dynamic>.from(
        cardMap['details'] as Map? ?? const {},
      );
      details['attendanceScan'] = Map<String, dynamic>.from(
        body['attendanceScan'] as Map,
      );
      cardMap['details'] = details;
    }
    return _cardFromApi(cardMap);
  }

  Future<Map<String, dynamic>> getAdminCardScanReportUsers({
    String scope = 'private',
    String? from,
    String? to,
    int page = 1,
    int perPage = 12,
  }) async {
    final params = <String, String>{
      'scope': scope,
      'page': page.toString(),
      'perPage': perPage.toString(),
    };
    if (from != null && from.trim().isNotEmpty) params['from'] = from.trim();
    if (to != null && to.trim().isNotEmpty) params['to'] = to.trim();

    final response = await _client.get(
      AppConfig.apiUri('admin/reports/card-scans/users', params),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getMyIssuedCardUsageReport({
    String scope = 'all',
    String? from,
    String? to,
    String? query,
    int page = 1,
    int perPage = 20,
  }) async {
    final params = <String, String>{
      'scope': scope,
      'page': page.toString(),
      'perPage': perPage.toString(),
    };
    if (from != null && from.trim().isNotEmpty) params['from'] = from.trim();
    if (to != null && to.trim().isNotEmpty) params['to'] = to.trim();
    if (query != null && query.trim().isNotEmpty) {
      params['query'] = query.trim();
    }

    final response = await _client.get(
      AppConfig.apiUri('cards/usage-report', params),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getAdminCardScanReportUserLocations(
    String userId, {
    String scope = 'private',
    String? from,
    String? to,
  }) async {
    final params = <String, String>{'scope': scope};
    if (from != null && from.trim().isNotEmpty) params['from'] = from.trim();
    if (to != null && to.trim().isNotEmpty) params['to'] = to.trim();

    final response = await _client.get(
      AppConfig.apiUri(
        'admin/reports/card-scans/users/$userId/locations',
        params,
      ),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getAdminCardScanReportLocations({
    String scope = 'private',
    String? from,
    String? to,
  }) async {
    final params = <String, String>{'scope': scope};
    if (from != null && from.trim().isNotEmpty) params['from'] = from.trim();
    if (to != null && to.trim().isNotEmpty) params['to'] = to.trim();

    final response = await _client.get(
      AppConfig.apiUri('admin/reports/card-scans/locations', params),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getAdminAttendanceCardReports({
    String? from,
    String? to,
    String? query,
    int page = 1,
    int perPage = 25,
  }) async {
    final params = <String, String>{
      'page': page.toString(),
      'perPage': perPage.toString(),
    };
    if (from != null && from.trim().isNotEmpty) {
      final value = from.trim();
      params['from'] = value.length == 10 ? '$value 00:00:00' : value;
    }
    if (to != null && to.trim().isNotEmpty) {
      final value = to.trim();
      params['to'] = value.length == 10 ? '$value 23:59:59' : value;
    }
    if (query != null && query.trim().isNotEmpty) params['q'] = query.trim();

    final response = await _client.get(
      AppConfig.apiUri('admin/reports/attendance-cards', params),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<void> exportAttendanceCardReportsCsv({
    required List<Map<String, dynamic>> items,
  }) async {
    final buffer = StringBuffer();
    buffer.writeln(
      '\uFEFFevent_id,barcode,action,employee_name,employee_code,department,attendance_system,integration_reference,scanner,owner,created_at,location,latitude,longitude,accuracy',
    );
    String csv(String value) => '"${value.replaceAll('"', '""')}"';
    for (final item in items) {
      buffer.writeln(
        [
          csv(item['id']?.toString() ?? ''),
          csv(item['barcode']?.toString() ?? ''),
          csv(
            Map<String, dynamic>.from(
                  item['attendanceAction'] as Map? ?? const {},
                )['label']?.toString() ??
                '',
          ),
          csv(item['employeeName']?.toString() ?? ''),
          csv(item['employeeCode']?.toString() ?? ''),
          csv(item['department']?.toString() ?? ''),
          csv(item['attendanceSystem']?.toString() ?? ''),
          csv(item['integrationReference']?.toString() ?? ''),
          csv(item['scannerName']?.toString() ?? ''),
          csv(item['ownerName']?.toString() ?? ''),
          csv(item['createdAt']?.toString() ?? ''),
          csv(item['locationKey']?.toString() ?? ''),
          item['latitude']?.toString() ?? '',
          item['longitude']?.toString() ?? '',
          item['accuracy']?.toString() ?? '',
        ].join(','),
      );
    }

    final bytes = Uint8List.fromList(utf8.encode(buffer.toString()));
    await FileSaver.instance.saveFile(
      name: 'attendance_card_reports',
      bytes: bytes,
      fileExtension: 'csv',
      mimeType: MimeType.csv,
    );
  }

  Future<void> exportAttendanceDailySummaryCsv({
    required List<Map<String, dynamic>> items,
  }) async {
    final buffer = StringBuffer();
    buffer.writeln(
      '\uFEFFdate,barcode,employee_name,employee_code,department,attendance_system,first_check_in,last_check_out,worked_minutes,scan_count,status',
    );
    String csv(String value) => '"${value.replaceAll('"', '""')}"';
    for (final item in items) {
      buffer.writeln(
        [
          csv(item['date']?.toString() ?? ''),
          csv(item['barcode']?.toString() ?? ''),
          csv(item['employeeName']?.toString() ?? ''),
          csv(item['employeeCode']?.toString() ?? ''),
          csv(item['department']?.toString() ?? ''),
          csv(item['attendanceSystem']?.toString() ?? ''),
          csv(item['firstCheckInAt']?.toString() ?? ''),
          csv(item['lastCheckOutAt']?.toString() ?? ''),
          item['workedMinutes']?.toString() ?? '',
          item['scanCount']?.toString() ?? '',
          csv(item['status']?.toString() ?? ''),
        ].join(','),
      );
    }

    final bytes = Uint8List.fromList(utf8.encode(buffer.toString()));
    await FileSaver.instance.saveFile(
      name: 'attendance_daily_summary',
      bytes: bytes,
      fileExtension: 'csv',
      mimeType: MimeType.csv,
    );
  }

  Future<Map<String, dynamic>> updateCardAutoRedeemOnScanPreference({
    required bool enabled,
  }) async {
    final response = await _client.put(
      AppConfig.apiUri('cards/auto-redeem-on-scan'),
      headers: await _headers(),
      body: jsonEncode({'enabled': enabled}),
    );
    final body = _decodeObject(response);
    if (body['user'] is Map) {
      await _authService.patchCurrentUser(
        Map<String, dynamic>.from(body['user'] as Map),
      );
    }
    return body;
  }

  Future<Map<String, dynamic>> redeemCard({
    required String cardId,
    required String customerName,
    Map<String, dynamic>? location,
  }) async {
    final payload = <String, dynamic>{'customerName': customerName};
    if (location != null) {
      payload['location'] = location;
    }
    final response = await _client.post(
      AppConfig.apiUri('cards/$cardId/redeem'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    final body = _decodeObject(response);
    await _patchCachedBalanceFromPayload(body);
    await _authService.patchCurrentUser({
      if (body['trialCardsLimit'] is num)
        'trialCardsLimit': (body['trialCardsLimit'] as num).toDouble(),
      if (body['trialCardsOutstandingAmount'] is num)
        'trialCardsOutstandingAmount':
            (body['trialCardsOutstandingAmount'] as num).toDouble(),
      if (body['trialCardsRemainingAmount'] is num)
        'trialCardsAvailableAmount': (body['trialCardsRemainingAmount'] as num)
            .toDouble(),
    });
    return body;
  }

  Future<Map<String, dynamic>> syncOfflineCardRedeems({
    required List<Map<String, dynamic>> items,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('cards/offline-redeem'),
      headers: await _headers(),
      body: jsonEncode({'items': items}),
    );
    final body = _decodeObject(response);
    await _patchCachedBalanceFromPayload(body);
    return body;
  }

  Future<Map<String, dynamic>> getMyTransactions({
    String locationFilter = 'all',
    String query = '',
    String dateFilter = 'all',
    bool printingDebtOnly = false,
    int page = 1,
    int perPage = 10,
  }) async {
    final response = await _client.get(
      AppConfig.apiUri('transactions/me', {
        if (locationFilter != 'all') 'locationFilter': locationFilter,
        if (query.trim().isNotEmpty) 'q': query.trim(),
        if (dateFilter != 'all') 'dateFilter': dateFilter,
        if (printingDebtOnly) 'printingDebtOnly': 'true',
        'page': page.toString(),
        'perPage': perPage.toString(),
      }),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getAdminPrepaidMultipaySettings() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/settings/prepaid-multipay'),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return Map<String, dynamic>.from(
      body['prepaidMultipay'] as Map? ?? const {},
    );
  }

  Future<Map<String, dynamic>> updateAdminPrepaidMultipaySettings({
    required double maxCardAmount,
    required double maxPaymentAmount,
    required int maxActiveCards,
    required int maxExpiryDays,
    required double dailyPaymentAmountLimit,
    required int dailyPaymentCountLimit,
    bool? nfcEnabled,
    bool? nfcPilotOnly,
    double? nfcMaxPaymentAmount,
    int? nfcAuthorizationTtlSeconds,
    int? nfcMaxDevicesPerCard,
    double? nfcOfflineMerchantAmountLimit,
    int? nfcOfflineMerchantCountLimit,
    bool? nfcRequireBiometrics,
  }) async {
    final payload = <String, dynamic>{
      'maxCardAmount': maxCardAmount,
      'maxPaymentAmount': maxPaymentAmount,
      'maxActiveCards': maxActiveCards,
      'maxExpiryDays': maxExpiryDays,
      'dailyPaymentAmountLimit': dailyPaymentAmountLimit,
      'dailyPaymentCountLimit': dailyPaymentCountLimit,
    };
    if (nfcEnabled != null) payload['nfcEnabled'] = nfcEnabled;
    if (nfcPilotOnly != null) payload['nfcPilotOnly'] = nfcPilotOnly;
    if (nfcMaxPaymentAmount != null) {
      payload['nfcMaxPaymentAmount'] = nfcMaxPaymentAmount;
    }
    if (nfcAuthorizationTtlSeconds != null) {
      payload['nfcAuthorizationTtlSeconds'] = nfcAuthorizationTtlSeconds;
    }
    if (nfcMaxDevicesPerCard != null) {
      payload['nfcMaxDevicesPerCard'] = nfcMaxDevicesPerCard;
    }
    if (nfcOfflineMerchantAmountLimit != null) {
      payload['nfcOfflineMerchantAmountLimit'] = nfcOfflineMerchantAmountLimit;
    }
    if (nfcOfflineMerchantCountLimit != null) {
      payload['nfcOfflineMerchantCountLimit'] = nfcOfflineMerchantCountLimit;
    }
    if (nfcRequireBiometrics != null) {
      payload['nfcRequireBiometrics'] = nfcRequireBiometrics;
    }

    final response = await _client.put(
      AppConfig.apiUri('admin/settings/prepaid-multipay'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getExternalCardStoreCatalog({
    int categoryId = 2,
    int type = 2,
    int perPage = 100,
    String? query,
  }) async {
    final response = await _client.get(
      AppConfig.apiUri('external-card-store/catalog', {
        'category_id': categoryId.toString(),
        'type': type.toString(),
        'per_page': perPage.toString(),
        if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
      }),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<List<Map<String, dynamic>>> getExternalCardStoreCards({
    required int categoryId,
    int type = 2,
    int perPage = 100,
    String? query,
  }) async {
    final response = await _client.get(
      AppConfig.apiUri('external-card-store/cards', {
        'category_id': categoryId.toString(),
        'type': type.toString(),
        'per_page': perPage.toString(),
        if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
      }),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return List<Map<String, dynamic>>.from(
      (body['cards'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<Map<String, dynamic>> purchaseExternalCard({
    required String ean,
    required String title,
    required double price,
    double? providerPriceUsd,
    required int categoryId,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
    int quantity = 1,
  }) async {
    final payload = <String, dynamic>{
      'ean': ean.trim(),
      'title': title.trim(),
      'price': price,
      'categoryId': categoryId,
      'quantity': quantity,
    };
    if (providerPriceUsd != null) {
      payload['providerPriceUsd'] = providerPriceUsd;
    }
    if (otpCode != null && otpCode.trim().isNotEmpty) {
      payload['otpCode'] = otpCode.trim();
    } else if (securityPin != null && securityPin.trim().isNotEmpty) {
      payload['securityPin'] = securityPin.trim();
    } else if (localAuthMethod != null && localAuthMethod.trim().isNotEmpty) {
      payload['localAuthMethod'] = localAuthMethod.trim();
    }

    final response = await _client.post(
      AppConfig.apiUri('external-card-store/purchase'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    final body = _decodeObject(response);
    await _patchCachedBalanceFromPayload(body);
    return body;
  }

  Future<List<Map<String, dynamic>>> getExternalCardStoreOrders({
    int limit = 30,
  }) async {
    final body = await getExternalCardStoreOrdersPayload(perPage: limit);
    return List<Map<String, dynamic>>.from(body['orders'] as List? ?? const []);
  }

  Future<Map<String, dynamic>> getExternalCardStoreOrdersPayload({
    int page = 1,
    int perPage = 12,
  }) async {
    final response = await _client.get(
      AppConfig.apiUri('external-card-store/orders', {
        'page': page.toString(),
        'perPage': perPage.toString(),
      }),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    return {
      ...body,
      'orders': List<Map<String, dynamic>>.from(
        (body['orders'] as List? ?? const []).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      ),
      'pagination': Map<String, dynamic>.from(
        body['pagination'] as Map? ?? const {},
      ),
    };
  }

  Future<Map<String, dynamic>> getAdminExternalCardStoreSettings() async {
    final response = await _client.get(
      AppConfig.apiUri('admin/settings/external-card-store'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> updateAdminExternalCardStoreSettings(
    Map<String, dynamic> settings,
  ) async {
    final response = await _client.put(
      AppConfig.apiUri('admin/settings/external-card-store'),
      headers: await _headers(),
      body: jsonEncode(settings),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getStoreManagementSnapshot() async {
    final response = await _client.get(
      AppConfig.apiUri('store-management/snapshot'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> syncStoreManagement(
    List<Map<String, dynamic>> operations,
  ) async {
    final response = await _client.post(
      AppConfig.apiUri('store-management/sync'),
      headers: await _headers(),
      body: jsonEncode({'operations': operations}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getMaintenanceSnapshot({
    String search = '',
    String status = '',
  }) async {
    final response = await _client.get(
      AppConfig.apiUri('maintenance-management/snapshot', {
        if (search.trim().isNotEmpty) 'search': search.trim(),
        if (status.trim().isNotEmpty) 'status': status.trim(),
      }),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> createMaintenanceOrder(
    Map<String, dynamic> data,
  ) async {
    final response = await _client.post(
      AppConfig.apiUri('maintenance-management/orders'),
      headers: await _headers(),
      body: jsonEncode(data),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> updateMaintenanceOrder(
    String orderId,
    Map<String, dynamic> data,
  ) async {
    final response = await _client.patch(
      AppConfig.apiUri('maintenance-management/orders/$orderId'),
      headers: await _headers(),
      body: jsonEncode(data),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> addMaintenancePart(
    String orderId,
    Map<String, dynamic> data,
  ) async {
    final response = await _client.post(
      AppConfig.apiUri('maintenance-management/orders/$orderId/parts'),
      headers: await _headers(),
      body: jsonEncode(data),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> removeMaintenancePart(
    String orderId,
    String partId,
  ) async {
    final response = await _client.delete(
      AppConfig.apiUri('maintenance-management/orders/$orderId/parts/$partId'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> finalizeMaintenanceOrder(String orderId) async {
    final response = await _client.post(
      AppConfig.apiUri('maintenance-management/orders/$orderId/finalize'),
      headers: await _headers(),
      body: jsonEncode(const {}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> recordMaintenanceContact(
    String orderId, {
    String method = 'call',
    String result = 'attempted',
    String note = '',
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('maintenance-management/orders/$orderId/contacts'),
      headers: await _headers(),
      body: jsonEncode({'method': method, 'result': result, 'note': note}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getPublicStores({String? query}) async {
    final response = await _client.get(
      AppConfig.apiUri('public-stores', {
        if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
      }),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getPublicStore(String workspaceId) async {
    final response = await _client.get(
      AppConfig.apiUri('public-stores/$workspaceId'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> createPublicStoreOrder({
    required String workspaceId,
    required List<Map<String, dynamic>> items,
    String? buyerNote,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('public-stores/orders'),
      headers: await _headers(),
      body: jsonEncode({
        'workspaceId': workspaceId,
        'items': items,
        if (buyerNote != null && buyerNote.trim().isNotEmpty)
          'buyerNote': buyerNote.trim(),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getSellerPublicStoreOrders() async {
    final response = await _client.get(
      AppConfig.apiUri('public-stores/orders/seller'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getBuyerPublicStoreOrders() async {
    final response = await _client.get(
      AppConfig.apiUri('public-stores/orders/buyer'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> updatePublicStoreOrder({
    required String orderId,
    required String action,
  }) async {
    final response = await _client.patch(
      AppConfig.apiUri('public-stores/orders/$orderId'),
      headers: await _headers(),
      body: jsonEncode({'action': action}),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getAdminExternalCardStoreCatalog({
    String? query,
    int limit = 200,
  }) async {
    final response = await _client.get(
      AppConfig.apiUri('admin/external-card-store/catalog', {
        if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
        'limit': limit.toString(),
      }),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> syncAdminExternalCardStoreCatalog({
    int categoryId = 2,
    int type = 2,
    int maxDepth = 3,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/external-card-store/catalog/sync'),
      headers: await _headers(),
      body: jsonEncode({
        'categoryId': categoryId,
        'type': type,
        'maxDepth': maxDepth,
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> updateAdminExternalCardStoreCatalogItem({
    required String kind,
    required String id,
    String? title,
    String? description,
    String? imageUrl,
    bool? hidden,
    bool? forceUnavailable,
    int? sortOrder,
  }) async {
    final payload = <String, dynamic>{};
    if (title != null) {
      payload['title'] = title;
    }
    if (description != null) {
      payload['description'] = description;
    }
    if (imageUrl != null) {
      payload['imageUrl'] = imageUrl;
    }
    if (hidden != null) {
      payload['hidden'] = hidden;
    }
    if (forceUnavailable != null) {
      payload['forceUnavailable'] = forceUnavailable;
    }
    if (sortOrder != null) {
      payload['sortOrder'] = sortOrder;
    }

    final response = await _client.put(
      AppConfig.apiUri('admin/external-card-store/catalog/$kind/$id'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getAdminPrepaidMultipayPayments({
    String? buyerUserId,
    String? merchantUserId,
    String? dateFrom,
    String? dateTo,
    String? query,
    String? cardStatus,
    int perPage = 50,
  }) async {
    final response = await _client.get(
      AppConfig.apiUri('admin/prepaid-multipay/payments', {
        if (buyerUserId != null && buyerUserId.trim().isNotEmpty)
          'buyerUserId': buyerUserId.trim(),
        if (merchantUserId != null && merchantUserId.trim().isNotEmpty)
          'merchantUserId': merchantUserId.trim(),
        if (dateFrom != null && dateFrom.trim().isNotEmpty)
          'dateFrom': dateFrom.trim(),
        if (dateTo != null && dateTo.trim().isNotEmpty) 'dateTo': dateTo.trim(),
        if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
        if (cardStatus != null &&
            cardStatus.trim().isNotEmpty &&
            cardStatus.trim() != 'all')
          'cardStatus': cardStatus.trim(),
        'perPage': perPage.toString(),
      }),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getAdminPendingPrepaidMultipayApprovals({
    String status = 'all',
    String search = '',
    int perPage = 50,
  }) async {
    final response = await _client.get(
      AppConfig.apiUri('admin/prepaid-multipay/approvals', {
        if (status.trim().isNotEmpty) 'status': status.trim(),
        if (search.trim().isNotEmpty) 'q': search.trim(),
        'perPage': perPage.toString(),
      }),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getAdminPrepaidMultipayNfcAttempts({
    String? status,
    int perPage = 50,
  }) async {
    final response = await _client.get(
      AppConfig.apiUri('admin/prepaid-multipay/nfc/attempts', {
        if (status != null && status.trim().isNotEmpty && status != 'all')
          'status': status.trim(),
        'perPage': perPage.toString(),
      }),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> reviewAdminPrepaidMultipayApproval({
    required String cardId,
    required String action,
    String? note,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/prepaid-multipay/approvals/$cardId'),
      headers: await _headers(),
      body: jsonEncode({
        'action': action.trim(),
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        ..._transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
          localAuthMethod: localAuthMethod,
        ),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> updateAdminPrepaidMultipayCardStatus({
    required String cardId,
    required String action,
    String? note,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/prepaid-multipay/cards/$cardId/status'),
      headers: await _headers(),
      body: jsonEncode({
        'action': action.trim(),
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        ..._transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
          localAuthMethod: localAuthMethod,
        ),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> adjustAdminPrepaidMultipayCardBalance({
    required String cardId,
    required double amount,
    String? note,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/prepaid-multipay/cards/$cardId/adjust-balance'),
      headers: await _headers(),
      body: jsonEncode({
        'amount': amount,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        ..._transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
          localAuthMethod: localAuthMethod,
        ),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> cancelAdminPrepaidMultipayCard({
    required String cardId,
    String? note,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/prepaid-multipay/cards/$cardId/cancel'),
      headers: await _headers(),
      body: jsonEncode({
        'confirmed': true,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        ..._transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
          localAuthMethod: localAuthMethod,
        ),
      }),
    );
    return _decodeObject(response);
  }

  Future<void> exportAdminPrepaidMultipayPaymentsCsv({
    required List<Map<String, dynamic>> payments,
  }) async {
    final buffer = StringBuffer();
    buffer.writeln(
      '\uFEFFid,buyer,merchant,card_label,card_number,card_status,amount,status,note,created_at',
    );
    for (final item in payments) {
      String csv(String value) => '"${value.replaceAll('"', '""')}"';
      buffer.writeln(
        [
          csv(item['id']?.toString() ?? ''),
          csv(item['buyerUsername']?.toString() ?? ''),
          csv(item['merchantUsername']?.toString() ?? ''),
          csv(item['cardLabel']?.toString() ?? ''),
          csv(item['cardNumber']?.toString() ?? ''),
          csv(item['cardStatus']?.toString() ?? ''),
          item['amount']?.toString() ?? '',
          csv(item['status']?.toString() ?? ''),
          csv(item['note']?.toString() ?? ''),
          csv(item['createdAt']?.toString() ?? ''),
        ].join(','),
      );
    }

    final bytes = Uint8List.fromList(utf8.encode(buffer.toString()));
    await FileSaver.instance.saveFile(
      name: 'prepaid_multipay_payments',
      bytes: bytes,
      fileExtension: 'csv',
      mimeType: MimeType.csv,
    );
  }

  Future<Map<String, dynamic>> getPrepaidMultipayCards() async {
    final response = await _client.get(
      AppConfig.apiUri('prepaid-multipay-cards'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> createPrepaidMultipayCard({
    required String label,
    required double amount,
    required String pin,
    required int validityYears,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('prepaid-multipay-cards'),
      headers: await _headers(),
      body: jsonEncode({
        'label': label.trim(),
        'amount': amount,
        'pin': pin.trim(),
        'validityYears': validityYears,
        ..._transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
          localAuthMethod: localAuthMethod,
        ),
      }),
    );
    final body = _decodeObject(response);
    if (body['balance'] is num) {
      await _authService.patchCurrentUser({
        'balance': (body['balance'] as num).toDouble(),
      });
    }
    return body;
  }

  Future<Map<String, dynamic>> adminCreatePrepaidMultipayCardForUser({
    required String userId,
    required String label,
    required double amount,
    required String pin,
    required int validityYears,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('admin/users/$userId/prepaid-multipay-cards'),
      headers: await _headers(),
      body: jsonEncode({
        'label': label.trim(),
        'amount': amount,
        'pin': pin.trim(),
        'validityYears': validityYears,
        ..._transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
          localAuthMethod: localAuthMethod,
        ),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> reloadPrepaidMultipayCard({
    required String cardId,
    required double amount,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('prepaid-multipay-cards/$cardId/reload'),
      headers: await _headers(),
      body: jsonEncode({
        'amount': amount,
        ..._transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
          localAuthMethod: localAuthMethod,
        ),
      }),
    );
    final body = _decodeObject(response);
    if (body['balance'] is num) {
      await _authService.patchCurrentUser({
        'balance': (body['balance'] as num).toDouble(),
      });
    }
    return body;
  }

  Future<Map<String, dynamic>> renewPrepaidMultipayCard({
    required String cardId,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('prepaid-multipay-cards/$cardId/renew'),
      headers: await _headers(),
      body: jsonEncode({
        ..._transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
          localAuthMethod: localAuthMethod,
        ),
      }),
    );
    final body = _decodeObject(response);
    if (body['balance'] is num) {
      await _authService.patchCurrentUser({
        'balance': (body['balance'] as num).toDouble(),
      });
    }
    return body;
  }

  Future<Map<String, dynamic>> updatePrepaidMultipayCard({
    required String cardId,
    required String label,
    required int validityYears,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final response = await _client.put(
      AppConfig.apiUri('prepaid-multipay-cards/$cardId'),
      headers: await _headers(),
      body: jsonEncode({
        'label': label.trim(),
        'validityYears': validityYears,
        ..._transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
          localAuthMethod: localAuthMethod,
        ),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> deletePrepaidMultipayCard({
    required String cardId,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final request = http.Request(
      'DELETE',
      AppConfig.apiUri('prepaid-multipay-cards/$cardId'),
    );
    request.headers.addAll(await _headers());
    request.body = jsonEncode({
      ..._transactionConfirmationPayload(
        otpCode: otpCode,
        securityPin: securityPin,
        localAuthMethod: localAuthMethod,
      ),
    });

    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    final body = _decodeObject(response);
    if (body['balance'] is num) {
      await _authService.patchCurrentUser({
        'balance': (body['balance'] as num).toDouble(),
      });
    }
    return body;
  }

  Future<Map<String, dynamic>> updatePrepaidMultipayCardStatus({
    required String cardId,
    required String action,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('prepaid-multipay-cards/$cardId/status'),
      headers: await _headers(),
      body: jsonEncode({
        'action': action,
        ..._transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
          localAuthMethod: localAuthMethod,
        ),
      }),
    );
    final body = _decodeObject(response);
    if (body['balance'] is num) {
      await _authService.patchCurrentUser({
        'balance': (body['balance'] as num).toDouble(),
      });
    }
    return body;
  }

  Future<Map<String, dynamic>> changePrepaidMultipayCardPin({
    required String cardId,
    required String currentPin,
    required String newPin,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('prepaid-multipay-cards/$cardId/pin'),
      headers: await _headers(),
      body: jsonEncode({
        'currentPin': currentPin.trim(),
        'newPin': newPin.trim(),
        ..._transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
          localAuthMethod: localAuthMethod,
        ),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getPrepaidMultipayNfcDevices({
    required String cardId,
  }) async {
    final response = await _client.get(
      AppConfig.apiUri('prepaid-multipay-cards/$cardId/nfc/devices'),
      headers: await _headers(),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> registerPrepaidMultipayNfcDevice({
    required String cardId,
    required String deviceId,
    required String deviceName,
    required String publicKey,
    String keyAlgorithm = 'ed25519',
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('prepaid-multipay-cards/$cardId/nfc/devices'),
      headers: await _headers(),
      body: jsonEncode({
        'deviceId': deviceId.trim(),
        'deviceName': deviceName.trim(),
        'publicKey': publicKey.trim(),
        'keyAlgorithm': keyAlgorithm.trim(),
        ..._transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
          localAuthMethod: localAuthMethod,
        ),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> revokePrepaidMultipayNfcDevice({
    required String cardId,
    required String deviceId,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final request = http.Request(
      'DELETE',
      AppConfig.apiUri('prepaid-multipay-cards/$cardId/nfc/devices/$deviceId'),
    );
    request.headers.addAll(await _headers());
    request.body = jsonEncode({
      ..._transactionConfirmationPayload(
        otpCode: otpCode,
        securityPin: securityPin,
        localAuthMethod: localAuthMethod,
      ),
    });

    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> preparePrepaidMultipayNfcPayment({
    required String cardId,
    required double amount,
    required String pin,
    required String deviceId,
    String? merchantId,
    String? appVersion,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('prepaid-multipay-cards/$cardId/nfc/prepare'),
      headers: await _headers(),
      body: jsonEncode({
        'amount': amount,
        'pin': pin.trim(),
        'deviceId': deviceId.trim(),
        if (merchantId != null && merchantId.trim().isNotEmpty)
          'merchantId': merchantId.trim(),
        if (appVersion != null && appVersion.trim().isNotEmpty)
          'appVersion': appVersion.trim(),
        ..._transactionConfirmationPayload(
          otpCode: otpCode,
          securityPin: securityPin,
          localAuthMethod: localAuthMethod,
        ),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> acceptPrepaidMultipayNfcPayment({
    required String signedPayload,
    required String signature,
    required String idempotencyKey,
    String? merchantDeviceId,
    String? acceptedAt,
    bool offlineAccepted = false,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('prepaid-multipay-cards/nfc/payments'),
      headers: await _headers(),
      body: jsonEncode({
        'signedPayload': signedPayload,
        'signature': signature,
        'idempotencyKey': idempotencyKey,
        if (merchantDeviceId != null && merchantDeviceId.trim().isNotEmpty)
          'merchantDeviceId': merchantDeviceId.trim(),
        if (acceptedAt != null && acceptedAt.trim().isNotEmpty)
          'acceptedAt': acceptedAt.trim(),
        if (offlineAccepted) 'offlineAccepted': true,
      }),
    );
    final body = _decodeObject(response);
    if (body['merchantBalance'] is num) {
      await _authService.patchCurrentUser({
        'balance': (body['merchantBalance'] as num).toDouble(),
      });
    }
    return body;
  }

  Future<Map<String, dynamic>> getPrepaidMultipayNfcPaymentStatus({
    required String idempotencyKey,
  }) async {
    final response = await _client.get(
      AppConfig.apiUri(
        'prepaid-multipay-cards/nfc/payments/status/${Uri.encodeComponent(idempotencyKey.trim())}',
      ),
      headers: await _headers(),
    );
    final body = _decodeObject(response);
    if (body['merchantBalance'] is num) {
      await _authService.patchCurrentUser({
        'balance': (body['merchantBalance'] as num).toDouble(),
      });
    }
    return body;
  }

  Future<Map<String, dynamic>> acceptPrepaidMultipayCardPayment({
    required String cardNumber,
    required double amount,
    required String expiryMonth,
    required String expiryYear,
    required String securityCode,
    required String idempotencyKey,
    String? note,
  }) async {
    final response = await _client.post(
      AppConfig.apiUri('prepaid-multipay-cards/payments'),
      headers: await _headers(),
      body: jsonEncode({
        'cardNumber': cardNumber.trim(),
        'amount': amount,
        'expiryMonth': expiryMonth.trim(),
        'expiryYear': expiryYear.trim(),
        'securityCode': securityCode.trim(),
        'idempotencyKey': idempotencyKey,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      }),
    );
    final body = _decodeObject(response);
    if (body['merchantBalance'] is num) {
      await _authService.patchCurrentUser({
        'balance': (body['merchantBalance'] as num).toDouble(),
      });
    }
    return body;
  }

  Future<Map<String, dynamic>> getNotificationSummary() async {
    final ownerId =
        (await _authService.currentUser())?['id']?.toString().trim() ?? '';
    final cached = _cachedNotificationSummary;
    final cachedAt = _cachedNotificationSummaryAt;
    if (cached != null &&
        cachedAt != null &&
        _cachedNotificationSummaryOwnerId == ownerId &&
        DateTime.now().difference(cachedAt) <
            _notificationSummaryCacheLifetime) {
      return Map<String, dynamic>.from(cached);
    }
    final pending = _pendingNotificationSummaryRequest;
    if (pending != null && _pendingNotificationSummaryOwnerId == ownerId) {
      return Map<String, dynamic>.from(await pending);
    }
    final future = _fetchNotificationSummary(ownerId);
    _pendingNotificationSummaryRequest = future;
    _pendingNotificationSummaryOwnerId = ownerId;
    try {
      return Map<String, dynamic>.from(await future);
    } finally {
      if (identical(_pendingNotificationSummaryRequest, future)) {
        _pendingNotificationSummaryRequest = null;
        _pendingNotificationSummaryOwnerId = null;
      }
    }
  }

  Future<Map<String, dynamic>> _fetchNotificationSummary(String ownerId) async {
    final response = await _getNotificationWithFallback(
      'notifications/summary',
      query: const {'sync': 'false'},
    );
    final payload = _decodeObject(response);
    _cachedNotificationSummary = Map<String, dynamic>.from(payload);
    _cachedNotificationSummaryAt = DateTime.now();
    _cachedNotificationSummaryOwnerId = ownerId;
    return payload;
  }

  Future<Map<String, dynamic>> getAppNotifications({
    String filter = 'all',
    int page = 1,
    int perPage = 20,
  }) async {
    final response = await _getNotificationWithFallback(
      'notifications',
      query: {
        'filter': filter,
        'page': page.toString(),
        'perPage': perPage.toString(),
        'sync': 'false',
      },
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> getAdminNotificationComposer() async {
    final response = await _authenticatedGetWithFallback('admin/notifications');
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> sendAdminNotification({
    required String targetType,
    String targetValue = '',
    required String category,
    required String notificationType,
    required String priority,
    required String title,
    required String body,
    String details = '',
    String actionRoute = '',
    String actionLabel = '',
  }) async {
    final response = await _authenticatedPostWithFallback(
      'admin/notifications',
      body: jsonEncode({
        'targetType': targetType,
        'targetValue': targetValue,
        'category': category,
        'notificationType': notificationType,
        'priority': priority,
        'title': title.trim(),
        'body': body.trim(),
        if (details.trim().isNotEmpty) 'details': details.trim(),
        if (actionRoute.trim().isNotEmpty) 'actionRoute': actionRoute.trim(),
        if (actionLabel.trim().isNotEmpty) 'actionLabel': actionLabel.trim(),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> createSupportTicket({
    String name = '',
    String whatsapp = '',
    String countryCode = '970',
    required String title,
    required String details,
  }) async {
    final response = await _supportPost(
      'support/tickets',
      body: jsonEncode({
        if (name.trim().isNotEmpty) 'name': name.trim(),
        if (whatsapp.trim().isNotEmpty) 'whatsapp': whatsapp.trim(),
        if (countryCode.trim().isNotEmpty) 'countryCode': countryCode.trim(),
        'title': title.trim(),
        'details': details.trim(),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> requestSupportTicketAccess({
    required String ticketId,
    required String whatsapp,
    String countryCode = '970',
  }) async {
    final response = await _supportPost(
      'support/tickets/${ticketId.trim()}/request-access',
      body: jsonEncode({
        'whatsapp': whatsapp.trim(),
        if (countryCode.trim().isNotEmpty) 'countryCode': countryCode.trim(),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> createAdminSupportTicket({
    String userId = '',
    String name = '',
    String whatsapp = '',
    String countryCode = '970',
    required String title,
    required String details,
  }) async {
    final response = await _authenticatedPostWithFallback(
      'admin/support/tickets',
      body: jsonEncode({
        if (userId.trim().isNotEmpty) 'userId': userId.trim(),
        if (name.trim().isNotEmpty) 'name': name.trim(),
        if (whatsapp.trim().isNotEmpty) 'whatsapp': whatsapp.trim(),
        if (countryCode.trim().isNotEmpty) 'countryCode': countryCode.trim(),
        'title': title.trim(),
        'details': details.trim(),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> requestSupportTicketPhoneAccess({
    required String whatsapp,
    String countryCode = '970',
  }) async {
    final response = await _supportPost(
      'support/tickets/request-phone-access',
      body: jsonEncode({
        'whatsapp': whatsapp.trim(),
        if (countryCode.trim().isNotEmpty) 'countryCode': countryCode.trim(),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> verifySupportTicketPhoneAccess({
    required String whatsapp,
    required String otpCode,
    String countryCode = '970',
  }) async {
    final response = await _supportPost(
      'support/tickets/verify-phone-access',
      body: jsonEncode({
        'whatsapp': whatsapp.trim(),
        'otpCode': otpCode.trim(),
        if (countryCode.trim().isNotEmpty) 'countryCode': countryCode.trim(),
      }),
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> verifySupportTicket({
    required String ticketId,
    required String otpCode,
  }) async {
    final response = await _supportPost(
      'support/tickets/${ticketId.trim()}/verify',
      body: jsonEncode({'otpCode': otpCode.trim()}),
    );
    return _decodeObject(response);
  }

  Future<List<Map<String, dynamic>>> getMySupportTickets() async {
    final body = _decodeObject(await _supportGet('support/tickets'));
    return List<Map<String, dynamic>>.from(
      (body['tickets'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<Map<String, dynamic>> getSupportTicket({
    required String ticketId,
    String accessToken = '',
  }) async {
    return _decodeObject(
      await _supportGet(
        'support/tickets/${ticketId.trim()}',
        guestToken: accessToken,
      ),
    );
  }

  Future<Map<String, dynamic>> sendSupportTicketMessage({
    required String ticketId,
    required String body,
    String accessToken = '',
  }) async {
    return _decodeObject(
      await _supportPost(
        'support/tickets/${ticketId.trim()}/messages',
        guestToken: accessToken,
        body: jsonEncode({'body': body.trim()}),
      ),
    );
  }

  Future<Map<String, dynamic>> uploadSupportTicketAttachment({
    required String ticketId,
    required String fileName,
    required Uint8List bytes,
    String accessToken = '',
    bool admin = false,
  }) async {
    return _supportMultipart(
      admin
          ? 'admin/support/tickets/${ticketId.trim()}/attachments'
          : 'support/tickets/${ticketId.trim()}/attachments',
      guestToken: accessToken,
      fileName: fileName,
      bytes: bytes,
    );
  }

  Future<Uint8List> downloadSupportTicketAttachment({
    required String ticketId,
    required String attachmentId,
    String accessToken = '',
  }) async {
    Object? lastError;
    final headers = await _headers();
    if (accessToken.trim().isNotEmpty) {
      headers['X-Support-Ticket-Token'] = accessToken.trim();
    }
    headers.remove('Content-Type');
    headers.remove('content-type');

    for (final uri in AppConfig.apiCandidateUris(
      'support/tickets/${ticketId.trim()}/attachments/${attachmentId.trim()}',
    )) {
      try {
        final response = await _client
            .get(uri, headers: headers)
            .timeout(_authenticatedRequestTimeout);
        unawaited(_cacheRefreshedSession(response));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return Uint8List.fromList(response.bodyBytes);
        }
        _decodeObject(response);
      } on TimeoutException catch (error) {
        lastError = error;
      } on http.ClientException catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? Exception(_tr('services_api_service.001'));
  }

  Future<List<Map<String, dynamic>>> getAdminSupportTickets() async {
    final body = _decodeObject(
      await _authenticatedGetWithFallback('admin/support/tickets'),
    );
    return List<Map<String, dynamic>>.from(
      (body['tickets'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<Map<String, dynamic>> updateSecurityPin({
    required String pin,
    String? currentPin,
    String? otpCode,
  }) async {
    return _decodeObject(
      await _authenticatedPostWithFallback(
        'auth/security-pin',
        body: jsonEncode({
          'pin': pin.trim(),
          if ((currentPin ?? '').trim().isNotEmpty)
            'currentPin': currentPin!.trim(),
          if ((otpCode ?? '').trim().isNotEmpty) 'otpCode': otpCode!.trim(),
        }),
      ),
    );
  }

  Future<Map<String, dynamic>> removeSecurityPin({
    String? currentPin,
    String? otpCode,
  }) async {
    final body = jsonEncode({
      if ((currentPin ?? '').trim().isNotEmpty)
        'currentPin': currentPin!.trim(),
      if ((otpCode ?? '').trim().isNotEmpty) 'otpCode': otpCode!.trim(),
    });
    return _decodeObject(
      await _authenticatedDeleteWithFallback('auth/security-pin', body: body),
    );
  }

  Future<Map<String, dynamic>> getAdminSupportTicket({
    required String ticketId,
  }) async {
    return _decodeObject(
      await _authenticatedGetWithFallback(
        'admin/support/tickets/${ticketId.trim()}',
      ),
    );
  }

  Future<Map<String, dynamic>> claimSupportTicket(String ticketId) async {
    return _decodeObject(
      await _authenticatedPostWithFallback(
        'admin/support/tickets/${ticketId.trim()}/claim',
      ),
    );
  }

  Future<Map<String, dynamic>> sendAdminSupportTicketMessage({
    required String ticketId,
    required String body,
    required String replyAs,
  }) async {
    return _decodeObject(
      await _authenticatedPostWithFallback(
        'admin/support/tickets/${ticketId.trim()}/messages',
        body: jsonEncode({'body': body.trim(), 'replyAs': replyAs}),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> getAdminSupportTicketStatuses() async {
    final body = _decodeObject(
      await _authenticatedGetWithFallback(
        'admin/support/tickets/status-options',
      ),
    );
    return List<Map<String, dynamic>>.from(
      (body['statuses'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<Map<String, dynamic>> changeAdminSupportTicketStatus({
    required String ticketId,
    required String status,
    String customStatusLabel = '',
    String note = '',
    String actorKind = 'support',
  }) async {
    return _decodeObject(
      await _authenticatedPostWithFallback(
        'admin/support/tickets/${ticketId.trim()}/status',
        body: jsonEncode({
          'status': status.trim(),
          if (customStatusLabel.trim().isNotEmpty)
            'customStatusLabel': customStatusLabel.trim(),
          if (note.trim().isNotEmpty) 'note': note.trim(),
          'actorKind': actorKind.trim(),
        }),
      ),
    );
  }

  Future<Map<String, dynamic>> updateAdminSupportTicketTitle({
    required String ticketId,
    required String title,
  }) async {
    return _decodeObject(
      await _authenticatedPostWithFallback(
        'admin/support/tickets/${ticketId.trim()}/title',
        body: jsonEncode({'title': title.trim()}),
      ),
    );
  }

  Future<Map<String, dynamic>> addAdminSupportTicketFollower({
    required String ticketId,
    required String userId,
  }) async {
    return _decodeObject(
      await _authenticatedPostWithFallback(
        'admin/support/tickets/${ticketId.trim()}/follower',
        body: jsonEncode({'userId': userId.trim()}),
      ),
    );
  }

  Future<Map<String, dynamic>> markNotificationAsRead(String id) async {
    final response = await _authenticatedPostWithFallback(
      'notifications/$id/read',
    );
    return _decodeObject(response);
  }

  Future<Map<String, dynamic>> markAllNotificationsAsRead() async {
    final response = await _authenticatedPostWithFallback(
      'notifications/read-all',
    );
    return _decodeObject(response);
  }

  Future<http.Response> _authenticatedGetWithFallback(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    Object? lastError;
    http.Response? lastAuthFailure;
    final headers = await _headers();
    for (final uri in AppConfig.apiCandidateUris(path, query)) {
      try {
        final response = await _client
            .get(uri, headers: headers)
            .timeout(_authenticatedRequestTimeout);
        if ((response.statusCode == 401 || response.statusCode == 403) &&
            AppConfig.apiBaseUrls.length > 1) {
          lastAuthFailure = response;
          continue;
        }
        unawaited(_cacheRefreshedSession(response));
        return response;
      } on TimeoutException catch (error) {
        lastError = error;
      } on http.ClientException catch (error) {
        lastError = error;
      }
    }
    if (lastAuthFailure != null) {
      return lastAuthFailure;
    }
    throw lastError ?? Exception(_tr('services_api_service.001'));
  }

  Future<http.Response> _authenticatedPostWithFallback(
    String path, {
    Object? body,
  }) async {
    Object? lastError;
    http.Response? lastAuthFailure;
    final headers = await _headers();
    for (final uri in AppConfig.apiCandidateUris(path)) {
      try {
        final response = await _client
            .post(uri, headers: headers, body: body)
            .timeout(_authenticatedRequestTimeout);
        if ((response.statusCode == 401 || response.statusCode == 403) &&
            AppConfig.apiBaseUrls.length > 1) {
          lastAuthFailure = response;
          continue;
        }
        unawaited(_cacheRefreshedSession(response));
        return response;
      } on TimeoutException catch (error) {
        lastError = error;
      } on http.ClientException catch (error) {
        lastError = error;
      }
    }
    if (lastAuthFailure != null) {
      return lastAuthFailure;
    }
    throw lastError ?? Exception(_tr('services_api_service.001'));
  }

  Future<http.Response> _authenticatedDeleteWithFallback(
    String path, {
    Object? body,
  }) async {
    Object? lastError;
    http.Response? lastAuthFailure;
    final headers = await _headers();
    for (final uri in AppConfig.apiCandidateUris(path)) {
      try {
        final response = await _client
            .delete(uri, headers: headers, body: body)
            .timeout(_authenticatedRequestTimeout);
        if ((response.statusCode == 401 || response.statusCode == 403) &&
            AppConfig.apiBaseUrls.length > 1) {
          lastAuthFailure = response;
          continue;
        }
        unawaited(_cacheRefreshedSession(response));
        return response;
      } on TimeoutException catch (error) {
        lastError = error;
      } on http.ClientException catch (error) {
        lastError = error;
      }
    }
    if (lastAuthFailure != null) {
      return lastAuthFailure;
    }
    throw lastError ?? Exception(_tr('services_api_service.001'));
  }

  Future<void> _cacheRefreshedSession(http.Response response) async {
    final refreshedToken = response.headers['x-auth-token']?.trim() ?? '';
    if (refreshedToken.isNotEmpty) {
      final expectedToken = _authorizationTokenFromRequest(response.request);
      if (expectedToken != null) {
        await _authService.cacheToken(
          refreshedToken,
          expectedToken: expectedToken,
        );
      }
    }
  }

  String? _authorizationTokenFromRequest(http.BaseRequest? request) {
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

  Future<http.Response> _supportGet(
    String path, {
    String guestToken = '',
  }) async {
    return _supportRequestWithFallback(path, guestToken: guestToken);
  }

  Future<http.Response> _supportPost(
    String path, {
    String guestToken = '',
    Object? body,
  }) async {
    return _supportRequestWithFallback(
      path,
      guestToken: guestToken,
      body: body,
      post: true,
    );
  }

  Future<http.Response> _supportRequestWithFallback(
    String path, {
    String guestToken = '',
    Object? body,
    bool post = false,
  }) async {
    Object? lastError;
    final headers = await _headers();
    if (guestToken.trim().isNotEmpty) {
      headers['X-Support-Ticket-Token'] = guestToken.trim();
    }
    for (final uri in AppConfig.apiCandidateUris(path)) {
      try {
        return await (post
                ? _client.post(uri, headers: headers, body: body)
                : _client.get(uri, headers: headers))
            .timeout(_authenticatedRequestTimeout);
      } on TimeoutException catch (error) {
        lastError = error;
      } on http.ClientException catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? Exception(_tr('services_api_service.001'));
  }

  Future<Map<String, dynamic>> _supportMultipart(
    String path, {
    required String fileName,
    required Uint8List bytes,
    String guestToken = '',
  }) async {
    Object? lastError;
    final headers = await _headers();
    headers.remove('Content-Type');
    headers.remove('content-type');
    if (guestToken.trim().isNotEmpty) {
      headers['X-Support-Ticket-Token'] = guestToken.trim();
    }
    for (final uri in AppConfig.apiCandidateUris(path)) {
      try {
        final request = http.MultipartRequest('POST', uri);
        request.headers.addAll(headers);
        request.files.add(
          http.MultipartFile.fromBytes(
            'file',
            bytes,
            filename: fileName,
            contentType: _contentTypeForFileName(fileName),
          ),
        );
        final streamed = await request.send().timeout(
          _authenticatedRequestTimeout,
        );
        final response = await http.Response.fromStream(streamed);
        return _decodeObject(response);
      } on TimeoutException catch (error) {
        lastError = error;
      } on http.ClientException catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? Exception(_tr('services_api_service.001'));
  }

  MediaType _contentTypeForFileName(String fileName) {
    final normalized = fileName.toLowerCase().trim();
    if (normalized.endsWith('.jpg') || normalized.endsWith('.jpeg')) {
      return MediaType('image', 'jpeg');
    }
    if (normalized.endsWith('.png')) {
      return MediaType('image', 'png');
    }
    if (normalized.endsWith('.webp')) {
      return MediaType('image', 'webp');
    }
    if (normalized.endsWith('.pdf')) {
      return MediaType('application', 'pdf');
    }
    if (normalized.endsWith('.txt')) {
      return MediaType('text', 'plain');
    }

    return MediaType('application', 'octet-stream');
  }

  Future<http.Response> _getNotificationWithFallback(
    String path, {
    Map<String, dynamic>? query,
  }) {
    return _authenticatedGetWithFallback(path, query: query);
  }

  Future<Map<String, dynamic>> resellCard({
    required String cardId,
    String? otpCode,
    String? securityPin,
    String? localAuthMethod,
    Map<String, dynamic>? location,
  }) async {
    final payload = _transactionConfirmationPayload(
      otpCode: otpCode,
      securityPin: securityPin,
      localAuthMethod: localAuthMethod,
    );
    if (location != null) {
      payload['location'] = location;
    }
    final response = await _client.post(
      AppConfig.apiUri('cards/$cardId/resell'),
      headers: await _headers(),
      body: jsonEncode(payload),
    );
    final body = _decodeObject(response);
    await _patchCachedBalanceFromPayload(body);
    return body;
  }

  Future<void> _syncCurrentUserFromPayload(Map<String, dynamic> body) async {
    final user = body['user'];
    if (user is Map<String, dynamic>) {
      await _authService.cacheCurrentUser(user);
      return;
    }
    if (user is Map) {
      await _authService.cacheCurrentUser(Map<String, dynamic>.from(user));
    }
  }

  Future<void> _patchCachedBalanceFromPayload(Map<String, dynamic> body) async {
    final balance = body['balance'];
    if (balance is num) {
      final currentUser = await _authService.currentUser();
      final currentUserId = currentUser?['id']?.toString();
      final balanceOwnerId = body['balanceOwnerId']?.toString();
      if (balanceOwnerId != null &&
          balanceOwnerId.isNotEmpty &&
          currentUserId != balanceOwnerId) {
        return;
      }
      await _authService.patchCurrentUser({'balance': balance.toDouble()});
    }
  }

  VirtualCard _cardFromApi(Map<String, dynamic> map) {
    return VirtualCard.fromMap({
      ...map,
      'status': map['status']?.toString() ?? 'available',
    }).copyWith(
      status: _statusFromApi(map['status']?.toString()),
      soldPrice: _doubleFromApi(map['value']),
    );
  }

  double? _doubleFromApi(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      final normalized = value.trim().replaceAll(',', '');
      if (normalized.isNotEmpty) {
        return double.tryParse(normalized);
      }
    }
    return null;
  }

  CardStatus _statusFromApi(String? status) {
    switch (status) {
      case 'used':
        return CardStatus.used;
      case 'archived':
        return CardStatus.archived;
      default:
        return CardStatus.unused;
    }
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    unawaited(_cacheRefreshedSession(response));
    final contentType = response.headers['content-type'] ?? '';
    final rawBody = response.body;
    final trimmedBody = rawBody.trimLeft();
    final looksLikeHtml =
        trimmedBody.startsWith('<!DOCTYPE html') ||
        trimmedBody.startsWith('<html') ||
        trimmedBody.startsWith('<');
    final fallbackMessage = _tr('services_api_service.001');
    final payloadTooLargeMessage = _tr('services_api_service.002');

    if (response.statusCode == 413) {
      throw Exception(payloadTooLargeMessage);
    }

    if (!contentType.contains('application/json') && looksLikeHtml) {
      _reportApiFailure(
        response,
        response.statusCode == 413 ? payloadTooLargeMessage : fallbackMessage,
        responsePreview: rawBody,
      );
      throw Exception(
        response.statusCode == 413 ? payloadTooLargeMessage : fallbackMessage,
      );
    }

    Map<String, dynamic> body;
    try {
      body = jsonDecode(rawBody) as Map<String, dynamic>;
    } on FormatException {
      _reportApiFailure(response, fallbackMessage, responsePreview: rawBody);
      throw Exception(fallbackMessage);
    }

    if (response.statusCode == 401) {
      final message = ErrorMessageService.sanitize(body['message']);
      throw Exception(message);
    }

    if (response.statusCode == 403) {
      throw Exception(ErrorMessageService.sanitize(body['message']));
    }

    if (response.statusCode >= 400) {
      final message = ErrorMessageService.sanitize(body['message']);
      _reportApiFailure(response, message, responsePreview: rawBody);
      throw Exception(message);
    }

    return body;
  }

  void _reportApiFailure(
    http.Response response,
    String message, {
    String? responsePreview,
  }) {
    if (response.statusCode < 500) {
      return;
    }
    final request = response.request;
    unawaited(
      AppAlertService.reportApiFailure(
        method: request?.method ?? 'HTTP',
        url: request?.url ?? Uri.parse('about:blank'),
        statusCode: response.statusCode,
        message: message,
        responsePreview: responsePreview == null
            ? null
            : ErrorMessageService.sanitize(
                responsePreview.length > 700
                    ? '${responsePreview.substring(0, 700)}...'
                    : responsePreview,
              ),
      ),
    );
  }

  String _tr(String key) {
    if ((AppLocaleService.instance.locale?.languageCode ?? 'ar') == 'en') {
      return appStringsEn[key] ?? key;
    }
    return appStringsAr[key] ?? appStringsEn[key] ?? key;
  }
}
