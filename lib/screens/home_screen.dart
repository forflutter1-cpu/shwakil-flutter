import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../models/index.dart';
import '../services/index.dart';
import '../utils/app_permissions.dart';
import '../utils/app_theme.dart';
import '../utils/currency_formatter.dart';
import '../utils/user_display_name.dart';
import '../widgets/app_sidebar.dart';
import '../widgets/app_top_actions.dart';
import '../widgets/responsive_scaffold_container.dart';
import '../widgets/shwakel_button.dart';
import '../widgets/shwakel_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.openSyncStatus = false, this.authService});

  final bool openSyncStatus;
  final AuthService? authService;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with RouteAware {
  static const String _balanceVisibleKeyPrefix = 'home_balance_visible';
  static const String _dismissedAnnouncementKey =
      'home.dismissed_announcement_version';
  late final AuthService _authService;
  final ApiService _apiService = ApiService();
  final OfflineCardService _offlineCardService = OfflineCardService();
  final DebtBookService _debtBookService = DebtBookService();
  final StoreManagementService _storeManagementService =
      StoreManagementService();

  Map<String, dynamic>? _user;
  bool _isLoading = true;
  bool _needsSessionRecovery = false;
  Future<void>? _pendingUserLoad;
  bool _hasOfflineWorkspace = false;
  bool _isSyncingOfflineWorkspace = false;
  bool _didPromptLocalSecuritySetup = false;
  bool _isBalanceVisible = true;
  bool _lastKnownDeviceOnline = ConnectivityService.instance.isOnline.value;
  int _pendingOfflineCount = 0;
  int _pendingStoreManagementCount = 0;
  int _availableOfflineCount = 0;
  int _cachedOfflineCount = 0;
  int _rejectedOfflineCount = 0;
  int _offlineSyncIntervalMinutes = 60;
  String? _lastOfflineSyncAt;
  bool _offlineAccessExpired = false;
  String? _shownAnnouncementVersionInSession;
  StreamSubscription<Map<String, dynamic>>? _balanceSubscription;
  bool _routeSubscribed = false;

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? AuthService();
    ConnectivityService.instance.isOnline.addListener(
      _handleConnectivityChanged,
    );
    _loadUser();
    _balanceSubscription = RealtimeNotificationService.balanceUpdatesStream
        .listen((_) {
          if (mounted) _loadUser();
        });
    if (widget.openSyncStatus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_showSyncStatusSheet());
        }
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!_routeSubscribed && route is PageRoute) {
      appRouteObserver.subscribe(this, route);
      _routeSubscribed = true;
    }
  }

  @override
  void dispose() {
    _balanceSubscription?.cancel();
    ConnectivityService.instance.isOnline.removeListener(
      _handleConnectivityChanged,
    );
    if (_routeSubscribed) {
      appRouteObserver.unsubscribe(this);
    }
    super.dispose();
  }

  @override
  void didPopNext() => _loadUser();

  bool get _canTransfer {
    return AppPermissions.fromUser(_user).canTransfer;
  }

  bool get _canOfflineScan {
    return AppPermissions.fromUser(_user).canOfflineCardScan;
  }

  bool get _canSyncWorkspace {
    final permissions = AppPermissions.fromUser(_user);
    return permissions.canOfflineCardScan ||
        permissions.canManageDebtBook ||
        permissions.canAccessStoreManagement;
  }

  bool get _canOpenPrepaidOfflineCards {
    return AppPermissions.fromUser(_user).canOpenPrepaidMultipayCards;
  }

  bool get _canOpenCardTools {
    return AppPermissions.fromUser(_user).canOpenCardTools;
  }

  String _t(String key, {Map<String, String>? params}) =>
      context.loc.tr(key, params: params);

  String get _displayName {
    final username = _user?['username']?.toString().trim() ?? '';
    return UserDisplayName.fromMap(_user, fallback: username);
  }

  String get _roleLabel {
    return _user?['roleLabel']?.toString().trim() ??
        _user?['role']?.toString().trim() ??
        '';
  }

  _RoleExperience get _roleExperience {
    final l = context.loc;
    final permissions = AppPermissions.fromUser(_user);
    final role = permissions.role;
    if (permissions.isDriverRole || permissions.canOfflineCardScan) {
      return _RoleExperience(
        title: l.text('مساحة السائق', 'Driver Workspace'),
        subtitle: l.text(
          'فحص سريع ومزامنة واضحة.',
          'Fast scanning and clear sync.',
        ),
        icon: Icons.local_shipping_rounded,
        gradient: const LinearGradient(
          colors: [AppTheme.secondary, AppTheme.primary],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        accent: AppTheme.accent,
        servicesTitle: l.text('مهام السائق', 'Driver Tasks'),
        scanTitle: l.text('فحص بطاقة', 'Scan Card'),
        scanSubtitle: l.text(
          'افتح الكاميرا وابدأ مباشرة.',
          'Open the camera and start immediately.',
        ),
      );
    }
    if (permissions.canIssueCards ||
        permissions.canRequestCardPrinting ||
        permissions.canAcceptPrepaidMultipayPayments ||
        role == 'merchant') {
      return _RoleExperience(
        title: l.text('مساحة التاجر', 'Merchant Workspace'),
        subtitle: l.text(
          'أدوات البيع والبطاقات في مكان واحد.',
          'Sales and card tools in one place.',
        ),
        icon: Icons.storefront_rounded,
        gradient: const LinearGradient(
          colors: [AppTheme.primary, AppTheme.primaryLight],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        accent: AppTheme.primary,
        servicesTitle: l.text('أدوات التاجر', 'Merchant Tools'),
        scanTitle: l.text('قبول أو فحص بطاقة', 'Accept or Scan Card'),
        scanSubtitle: l.text(
          'نفذ العملية الأساسية بدون خطوات إضافية.',
          'Run the core action without extra steps.',
        ),
      );
    }
    return _RoleExperience(
      title: l.text('مساحة المستخدم', 'User Workspace'),
      subtitle: l.text(
        'رصيدك وتحويلاتك بشكل مختصر.',
        'Your balance and transfers at a glance.',
      ),
      icon: Icons.account_circle_rounded,
      gradient: const LinearGradient(
        colors: [AppTheme.secondary, AppTheme.primary],
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
      ),
      accent: AppTheme.primary,
      servicesTitle: l.text('الخدمات', 'Services'),
      scanTitle: l.text('فحص بطاقة', 'Scan Card'),
      scanSubtitle: l.text(
        'استخدم البطاقة أو تحقق منها بسرعة.',
        'Use or verify a card quickly.',
      ),
    );
  }

  bool get _isVerifiedUser {
    final verificationStatus =
        _user?['transferVerificationStatus']?.toString().trim().toLowerCase() ??
        '';
    return _user?['isVerified'] == true || verificationStatus == 'approved';
  }

  bool get _isVerificationPending {
    final verificationStatus =
        _user?['transferVerificationStatus']?.toString().trim().toLowerCase() ??
        '';
    return verificationStatus == 'pending';
  }

  String get _verificationLabel {
    return _isVerifiedUser
        ? context.loc.tr('screens_balance_screen.036')
        : context.loc.tr('screens_balance_screen.037');
  }

  Future<void> _loadUser() {
    final pending = _pendingUserLoad;
    if (pending != null) {
      return pending;
    }

    final future = _loadUserInternal();
    _pendingUserLoad = future;
    return future.whenComplete(() {
      if (identical(_pendingUserLoad, future)) {
        _pendingUserLoad = null;
      }
    });
  }

  Future<void> _loadUserInternal() async {
    final hadUsableSnapshot = AuthService.hasPermissionSnapshot(_user);
    if (!hadUsableSnapshot && mounted) {
      setState(() {
        _isLoading = true;
        _needsSessionRecovery = false;
      });
    }

    Map<String, dynamic>? user;
    try {
      user = await _authService.currentUser();
      final cachedHasPermissions = AuthService.hasPermissionSnapshot(user);
      if (cachedHasPermissions) {
        await _applyUserSnapshot(user, isLoading: false);
      }

      final token = (await _authService.token())?.trim() ?? '';
      if (token.isNotEmpty) {
        try {
          final refreshed = await _authService.tryRefreshCurrentUser();
          if (refreshed) {
            user = await _authService.currentUser();
          }
        } catch (_) {
          // A rejected or temporarily unavailable refresh must never discard
          // the locally stored session. The cached snapshot remains usable.
          user ??= await _authService.currentUser();
        }
      }

      if (AuthService.hasPermissionSnapshot(user)) {
        await _applyUserSnapshot(user, isLoading: false);
        return;
      }

      if (token.isNotEmpty || user != null) {
        _showSessionRecovery(user);
        return;
      }

      await _redirectToLogin();
    } catch (_) {
      user ??= await _safeCurrentUser();
      if (AuthService.hasPermissionSnapshot(user)) {
        await _applyUserSnapshot(user, isLoading: false);
        return;
      }

      final token = (await _safeToken()).trim();
      if (token.isNotEmpty || user != null) {
        _showSessionRecovery(user);
        return;
      }

      await _redirectToLogin();
    }
  }

  Future<Map<String, dynamic>?> _safeCurrentUser() async {
    try {
      return await _authService.currentUser();
    } catch (_) {
      return null;
    }
  }

  Future<String> _safeToken() async {
    try {
      return (await _authService.token()) ?? '';
    } catch (_) {
      return '';
    }
  }

  void _showSessionRecovery(Map<String, dynamic>? user) {
    if (!mounted) {
      return;
    }
    setState(() {
      _user = user;
      _isLoading = false;
      _needsSessionRecovery = true;
    });
  }

  Future<void> _redirectToLogin() async {
    if (!mounted) {
      return;
    }
    OfflineSessionService.setOfflineMode(false);
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
  }

  Future<void> _applyUserSnapshot(
    Map<String, dynamic>? user, {
    required bool isLoading,
  }) async {
    final hasOfflineWorkspaceFuture = _resolveOfflineWorkspace(user);
    final offlineOverviewFuture = _resolveOfflineOverview(user);
    final isBalanceVisibleFuture = _resolveBalanceVisibility(user);

    final hasOfflineWorkspace = await hasOfflineWorkspaceFuture;
    final offlineOverview = await offlineOverviewFuture;
    final isBalanceVisible = await isBalanceVisibleFuture;

    if (!mounted) {
      return;
    }
    setState(() {
      _user = user;
      _hasOfflineWorkspace = hasOfflineWorkspace;
      _isBalanceVisible = isBalanceVisible;
      _pendingOfflineCount =
          (offlineOverview['pendingCount'] as num?)?.toInt() ?? 0;
      _pendingStoreManagementCount =
          (offlineOverview['storePendingCount'] as num?)?.toInt() ?? 0;
      _availableOfflineCount =
          (offlineOverview['availableCount'] as num?)?.toInt() ?? 0;
      _cachedOfflineCount =
          (offlineOverview['cachedCount'] as num?)?.toInt() ?? 0;
      _rejectedOfflineCount =
          (offlineOverview['rejectedCount'] as num?)?.toInt() ?? 0;
      _offlineSyncIntervalMinutes =
          (offlineOverview['syncIntervalMinutes'] as num?)?.toInt() ?? 60;
      _lastOfflineSyncAt = offlineOverview['lastSyncAt']?.toString();
      _offlineAccessExpired = offlineOverview['expired'] == true;
      _isLoading = isLoading;
      _needsSessionRecovery = false;
    });
    _maybeSyncOfflineWorkspaceInBackground();
    unawaited(_maybePromptLocalSecuritySetup());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_maybeShowAppAnnouncement());
      }
    });
  }

  Future<void> _maybeShowAppAnnouncement() async {
    final announcement = Map<String, dynamic>.from(
      _user?['appAnnouncement'] as Map? ?? const {},
    );
    if (announcement['enabled'] != true) {
      return;
    }
    final version = announcement['version']?.toString().trim() ?? '';
    if (version.isEmpty) {
      return;
    }
    if (_shownAnnouncementVersionInSession == version) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_dismissedAnnouncementKey) == version) {
      return;
    }
    if (!mounted) {
      return;
    }
    _shownAnnouncementVersionInSession = version;

    final l = context.loc;
    final neverAgain = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final title = announcement['title']?.toString().trim() ?? '';
        final description =
            announcement['description']?.toString().trim() ?? '';
        final imageUrl = announcement['imageUrl']?.toString().trim() ?? '';
        final route = announcement['route']?.toString().trim() ?? '';
        final actionLabel =
            announcement['actionLabel']?.toString().trim() ??
            l.text('فتح', 'Open');

        return AlertDialog(
          title: Row(
            children: [
              Expanded(
                child: Text(
                  title.isEmpty ? l.text('إعلان', 'Announcement') : title,
                ),
              ),
              IconButton(
                tooltip: l.text('إغلاق', 'Close'),
                onPressed: () => Navigator.pop(dialogContext, false),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (imageUrl.isNotEmpty) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (description.isNotEmpty)
                  Text(description, style: AppTheme.bodyAction),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l.text('عدم الظهور مرة ثانية', "Don't show again")),
            ),
            if (route.isNotEmpty)
              FilledButton(
                onPressed: () {
                  Navigator.pop(dialogContext, false);
                  Navigator.pushNamed(context, route);
                },
                child: Text(actionLabel),
              ),
          ],
        );
      },
    );

    if (neverAgain == true) {
      await prefs.setString(_dismissedAnnouncementKey, version);
    }
  }

  Future<void> _maybePromptLocalSecuritySetup() async {
    if (!mounted || _didPromptLocalSecuritySetup) {
      return;
    }
    if (await LocalSecurityService.hasConfiguredLocalSecurity()) {
      return;
    }
    final shouldPrompt =
        await LocalSecurityService.shouldPromptLocalSecuritySetupReminder();
    if (!mounted || !shouldPrompt) {
      return;
    }
    _didPromptLocalSecuritySetup = true;
    final l = context.loc;
    final shouldOpenSecuritySetup = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.tr('screens_security_settings_screen.072')),
        content: Text(l.tr('screens_security_settings_screen.073')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l.tr('screens_login_screen.019')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l.tr('screens_login_screen.020')),
          ),
        ],
      ),
    );
    await LocalSecurityService.markLocalSecuritySetupReminderShown();
    if (!mounted || shouldOpenSecuritySetup != true) {
      return;
    }
    Navigator.pushNamed(
      context,
      '/security-settings',
      arguments: const {'showSetupHint': true},
    );
  }

  Future<Map<String, dynamic>> _resolveOfflineOverview(
    Map<String, dynamic>? user,
  ) async {
    final permissions = AppPermissions.fromUser(user);
    if (user == null || user['id'] == null) {
      return const {
        'pendingCount': 0,
        'storePendingCount': 0,
        'availableCount': 0,
        'cachedCount': 0,
        'rejectedCount': 0,
        'syncIntervalMinutes': 60,
        'lastSyncAt': null,
        'expired': false,
      };
    }
    final userId = user['id'].toString();
    final storePendingCount = permissions.canAccessStoreManagement
        ? (await _storeManagementService.getPendingOperations(userId)).length
        : 0;
    if (!permissions.canOfflineCardScan) {
      return {
        'pendingCount': storePendingCount,
        'storePendingCount': storePendingCount,
        'availableCount': 0,
        'cachedCount': 0,
        'rejectedCount': 0,
        'syncIntervalMinutes': 60,
        'lastSyncAt': null,
        'expired': false,
      };
    }
    final overview = await _offlineCardService.offlineOverview(userId);
    final summary = Map<String, dynamic>.from(
      overview['summary'] as Map? ?? const {},
    );
    final settings = Map<String, dynamic>.from(
      overview['settings'] as Map? ?? const {},
    );
    final interval =
        (((settings['syncIntervalMinutes'] as num?)?.toInt() ?? 60).clamp(
          5,
          1440,
        )).toInt();
    final lastSyncAt = settings['lastSyncAt']?.toString();
    final parsedLastSync = DateTime.tryParse(lastSyncAt ?? '');
    final expired =
        parsedLastSync == null ||
        DateTime.now().difference(parsedLastSync.toLocal()).inMinutes >=
            interval;
    return {
      'pendingCount':
          ((summary['count'] as num?)?.toInt() ?? 0) + storePendingCount,
      'storePendingCount': storePendingCount,
      'availableCount': (overview['availableCount'] as num?)?.toInt() ?? 0,
      'cachedCount': (overview['cachedCount'] as num?)?.toInt() ?? 0,
      'rejectedCount': (summary['rejectedCount'] as num?)?.toInt() ?? 0,
      'syncIntervalMinutes': interval,
      'lastSyncAt': lastSyncAt,
      'expired': expired,
    };
  }

  void _handleConnectivityChanged() {
    if (!mounted) {
      return;
    }
    final isOnline = ConnectivityService.instance.isOnline.value;
    final regainedConnection = !_lastKnownDeviceOnline && isOnline;
    _lastKnownDeviceOnline = isOnline;

    if (regainedConnection) {
      if (OfflineSessionService.isOfflineMode) {
        OfflineSessionService.setOfflineMode(false);
      }
      _maybeSyncOfflineWorkspaceInBackground();
    }
    setState(() {});
  }

  void _maybeSyncOfflineWorkspaceInBackground() {
    if (!mounted ||
        !_canSyncWorkspace ||
        !_isDeviceOnline ||
        _isSyncingOfflineWorkspace) {
      return;
    }
    final needsSync =
        _pendingOfflineCount > 0 ||
        _pendingStoreManagementCount > 0 ||
        _offlineAccessExpired;
    if (!needsSync) {
      return;
    }
    unawaited(_syncOfflineWorkspace(triggeredAutomatically: true));
  }

  Future<void> _syncOfflineWorkspace({
    bool triggeredAutomatically = false,
  }) async {
    if (_isSyncingOfflineWorkspace ||
        !ConnectivityService.instance.isOnline.value) {
      return;
    }

    final user = _user ?? await _authService.currentUser();
    if (user == null || user['id'] == null) {
      return;
    }
    final permissions = AppPermissions.fromUser(user);
    final canSyncCards = permissions.canOfflineCardScan;
    final canSyncDebtBook = permissions.canManageDebtBook;
    final canSyncStoreManagement = permissions.canAccessStoreManagement;
    if (!canSyncCards && !canSyncDebtBook && !canSyncStoreManagement) {
      return;
    }

    final userId = user['id'].toString();
    final queuedBeforeSync = canSyncCards
        ? await _offlineCardService.getRedeemQueue(userId)
        : const <Map<String, dynamic>>[];
    final unknownLookups = canSyncCards
        ? await _offlineCardService.getUnknownCardLookups(userId)
        : const <Map<String, dynamic>>[];
    var rejectedSyncCount = 0;
    if (mounted) {
      setState(() => _isSyncingOfflineWorkspace = true);
    }

    try {
      if (canSyncCards) {
        final payload = await _apiService.getOfflineCardCache();
        await _offlineCardService.cacheCards(
          userId: userId,
          cards: List<VirtualCard>.from(payload['cards'] as List? ?? const []),
          settings: Map<String, dynamic>.from(
            payload['settings'] as Map? ?? const {},
          ),
        );

        if (unknownLookups.isNotEmpty) {
          await _resolveUnknownOfflineLookups(userId, unknownLookups);
        }
      }

      if (canSyncDebtBook) {
        await _debtBookService.syncPending(userId: userId, api: _apiService);
      }

      if (canSyncStoreManagement) {
        await _storeManagementService.syncPending(
          userId: userId,
          api: _apiService,
        );
      }

      if (queuedBeforeSync.isNotEmpty) {
        final result = await _apiService.syncOfflineCardRedeems(
          items: queuedBeforeSync,
        );
        final resultItems = List<Map<String, dynamic>>.from(
          (result['results'] as List? ?? const []).map(
            (item) => Map<String, dynamic>.from(item as Map),
          ),
        );
        final rejectedBarcodes = <String>{
          for (final item in resultItems)
            if (item['ok'] != true) (item['barcode'] ?? '').toString(),
        }..remove('');
        final acceptedBarcodes = <String>{
          for (final item in resultItems)
            if (item['ok'] == true) (item['barcode'] ?? '').toString(),
        }..remove('');
        final syncedAt = DateTime.now().toIso8601String();
        final historyEntries = queuedBeforeSync.map((entry) {
          final barcode = entry['barcode']?.toString() ?? '';
          Map<String, dynamic>? matchedResult;
          for (final item in resultItems) {
            if (item['barcode']?.toString() == barcode) {
              matchedResult = item;
              break;
            }
          }
          final ok = matchedResult?['ok'] == true;
          return {
            ...entry,
            'status': ok ? 'confirmed' : 'rejected',
            'message': matchedResult?['message']?.toString(),
            'syncedAt': syncedAt,
            'confirmedOffline': true,
          };
        }).toList();
        final rejectedHistoryEntries = historyEntries
            .where((item) => item['status'] == 'rejected')
            .toList();
        rejectedSyncCount = rejectedHistoryEntries.length;

        await _offlineCardService.replaceRedeemQueue(
          userId,
          queuedBeforeSync
              .where(
                (item) =>
                    rejectedBarcodes.contains(item['barcode']?.toString()),
              )
              .toList(),
        );
        await _offlineCardService.replaceRejectedRedeems(
          userId,
          rejectedHistoryEntries,
        );
        await _offlineCardService.appendSyncHistory(
          userId,
          rejectedHistoryEntries,
        );
        await _offlineCardService.removeCardsByBarcode(
          userId: userId,
          barcodes: acceptedBarcodes,
        );

        final updatedBalance = (result['balance'] as num?)?.toDouble();
        final balanceOwnerId = result['balanceOwnerId']?.toString();
        if (updatedBalance != null &&
            (balanceOwnerId == null ||
                balanceOwnerId.isEmpty ||
                balanceOwnerId == userId)) {
          await _authService.patchCurrentUser({'balance': updatedBalance});
        }
      }

      try {
        await _authService.refreshCurrentUser();
      } catch (_) {
        // Keep the cached user if refreshing the profile is temporarily unavailable.
      }

      if (canSyncCards) {
        await _offlineCardService.recordLastSync(
          userId,
          source: queuedBeforeSync.isNotEmpty ? 'queue' : 'inventory',
        );
      }
      OfflineSessionService.setOfflineMode(false);

      await _loadUser();
      if (!mounted) {
        return;
      }
      if (!triggeredAutomatically) {
        final successMessage = queuedBeforeSync.isNotEmpty
            ? _t(
                'screens_home_screen.052',
                params: {
                  'accepted': '${queuedBeforeSync.length - rejectedSyncCount}',
                  'rejected': '$rejectedSyncCount',
                },
              )
            : _t('screens_home_screen.053');
        AppAlertService.showSnack(
          context,
          message: successMessage,
          type: AppAlertType.success,
        );
      }
    } catch (error) {
      if (!mounted || triggeredAutomatically) {
        return;
      }
      AppAlertService.showSnack(
        context,
        message:
            '${_t('screens_home_screen.054')}: ${ErrorMessageService.sanitize(error)}',
        type: AppAlertType.error,
        duration: const Duration(seconds: 4),
      );
    } finally {
      if (mounted) {
        setState(() => _isSyncingOfflineWorkspace = false);
      }
    }
  }

  Future<void> _resolveUnknownOfflineLookups(
    String userId,
    List<Map<String, dynamic>> lookups,
  ) async {
    final foundCards = <VirtualCard>[];
    final unresolved = <Map<String, dynamic>>[];
    final l = context.loc;

    for (final item in lookups) {
      final barcode = item['barcode']?.toString().trim() ?? '';
      if (barcode.isEmpty) {
        continue;
      }
      try {
        final card = await _apiService.getCardByBarcode(barcode);
        if (card == null) {
          unresolved.add({
            ...item,
            'status': 'pending_lookup',
            'message': l.tr('screens_home_screen.055'),
            'lastCheckedAt': DateTime.now().toIso8601String(),
          });
          continue;
        }
        foundCards.add(card);
      } catch (_) {
        unresolved.add({
          ...item,
          'status': 'pending_lookup',
          'message': l.tr('screens_home_screen.056'),
          'lastCheckedAt': DateTime.now().toIso8601String(),
        });
      }
    }

    if (foundCards.isNotEmpty) {
      await _offlineCardService.cacheCards(userId: userId, cards: foundCards);
    }
    await _offlineCardService.replaceUnknownCardLookups(userId, unresolved);
  }

  Future<bool> _resolveOfflineWorkspace(Map<String, dynamic>? user) async {
    final permissions = AppPermissions.fromUser(user);
    if (user == null || user['id'] == null || !permissions.canOfflineCardScan) {
      return false;
    }
    return _offlineCardService.hasOfflineWorkspace(user['id'].toString());
  }

  bool get _isDeviceOnline => ConnectivityService.instance.isOnline.value;

  String _balanceVisibilityPreferenceKey(Map<String, dynamic>? user) {
    final userId = user?['id']?.toString().trim();
    return '${_balanceVisibleKeyPrefix}_${userId?.isNotEmpty == true ? userId : 'guest'}';
  }

  Future<bool> _resolveBalanceVisibility(Map<String, dynamic>? user) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_balanceVisibilityPreferenceKey(user)) ?? true;
  }

  Future<void> _setBalanceVisibility(bool visible) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_balanceVisibilityPreferenceKey(_user), visible);
    if (!mounted) {
      return;
    }
    setState(() => _isBalanceVisible = visible);
  }

  String get _scanCameraRoute => OfflineSessionService.isOfflineMode
      ? '/scan-card-offline-camera'
      : '/scan-card-camera';

  void _openScanScreen() {
    if (OfflineSessionService.isOfflineMode && _offlineAccessExpired) {
      unawaited(_showExpiredOfflineSyncRequired());
      return;
    }
    unawaited(_openRoute(_scanCameraRoute, allowOffline: true));
  }

  Future<void> _showExpiredOfflineSyncRequired() {
    return AppAlertService.showError(
      context,
      title: _t('screens_scan_card_screen.118'),
      message: _t(
        'screens_scan_card_screen.119',
        params: {'minutes': _offlineSyncIntervalMinutes.toString()},
      ),
    );
  }

  Future<void> _showOfflineBlockedMessage() {
    return AppAlertService.showInfo(
      context,
      title: _t('screens_home_screen.061'),
      message: _t('screens_home_screen.062'),
    );
  }

  Future<void> _openRoute(
    String routeName, {
    Object? arguments,
    bool allowOffline = false,
  }) async {
    if (OfflineSessionService.isOfflineMode && !allowOffline) {
      await _showOfflineBlockedMessage();
      return;
    }
    if (!mounted) {
      return;
    }

    final currentRoute = ModalRoute.of(context)?.settings.name;
    if (currentRoute == routeName ||
        (currentRoute == '/app-shell' && routeName == '/home')) {
      return;
    }

    Navigator.pushNamed(context, routeName, arguments: arguments);
  }

  Future<void> _openOnlineOnlyRoute(String routeName, {Object? arguments}) {
    return _openRoute(routeName, arguments: arguments);
  }

  @override
  Widget build(BuildContext context) {
    final services = _needsSessionRecovery
        ? const <_HomeServiceItem>[]
        : _serviceItems(context);
    _HomeServiceItem? scanShortcut;
    for (final item in services) {
      if (item.kind == _HomeServiceKind.scan) {
        scanShortcut = item;
        break;
      }
    }
    final listServices = services
        .where((item) => item.kind != _HomeServiceKind.scan)
        .toList(growable: false);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: _needsSessionRecovery
            ? Text(context.loc.text('استعادة الجلسة', 'Restore session'))
            : const SizedBox.shrink(),
        actions: [
          if (!_needsSessionRecovery && _canSyncWorkspace)
            _buildSyncStatusAction(),
          if (!_needsSessionRecovery && !OfflineSessionService.isOfflineMode)
            const AppNotificationAction(),
          if (!_needsSessionRecovery) const QuickLogoutAction(),
        ],
      ),
      drawer: _needsSessionRecovery ? null : AppSidebar.drawerFor(context),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _needsSessionRecovery
          ? _buildSessionRecoveryState()
          : RefreshIndicator(
              onRefresh: _loadUser,
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  ResponsiveScaffoldContainer(
                    padding: const EdgeInsets.fromLTRB(0, 20, 0, 28),
                    child: _buildHomeContent(
                      context,
                      scanShortcut: scanShortcut,
                      listServices: listServices,
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildSessionRecoveryState() {
    final l = context.loc;
    return RefreshIndicator(
      onRefresh: _loadUser,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        children: [
          ResponsiveScaffoldContainer(
            maxWidth: 680,
            padding: const EdgeInsets.fromLTRB(0, 24, 0, 32),
            child: ShwakelCard(
              key: const ValueKey('session-recovery'),
              padding: EdgeInsets.all(AppTheme.isPhone(context) ? 20 : 28),
              shadowLevel: ShwakelShadowLevel.medium,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: AppTheme.warningLight,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Icon(
                      Icons.sync_problem_rounded,
                      color: AppTheme.warning,
                      size: 32,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    l.text(
                      'تعذر تحديث صلاحيات الحساب مؤقتًا',
                      'Account permissions could not be refreshed',
                    ),
                    style: AppTheme.h2,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    l.text(
                      'جلستك محفوظة ولم يتم تسجيل خروجك. أعد المحاولة عند استقرار الاتصال لاستعادة مساحة العمل بأمان.',
                      'Your session is saved and you were not signed out. Retry when the connection is stable to restore your workspace safely.',
                    ),
                    style: AppTheme.bodyAction.copyWith(height: 1.6),
                  ),
                  const SizedBox(height: 22),
                  ShwakelButton(
                    label: l.text('إعادة المحاولة', 'Retry'),
                    icon: Icons.refresh_rounded,
                    onPressed: _loadUser,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<_HomeServiceItem> _serviceItems(BuildContext context) {
    final permissions = AppPermissions.fromUser(_user);
    final canIssueCards = permissions.canIssueCards;
    final canScanCards = permissions.canOpenCardTools;
    final canReviewCards = permissions.canReviewCards;
    final canViewBalance = permissions.canViewBalance;
    final canViewTransactions = permissions.canViewTransactions;
    final canViewInventory = permissions.canViewInventory;
    final canManageDebtBook = permissions.canManageDebtBook;
    final canAccessStoreManagement = permissions.canAccessStoreManagement;
    final canViewAffiliateCenter = permissions.canViewAffiliateCenter;
    final canViewSecuritySettings = permissions.canViewSecuritySettings;
    final canRequestCardPrinting = permissions.canRequestCardPrinting;
    final canOpenExternalCardStore = permissions.canOpenExternalCardStore;
    final canViewPublicStores = permissions.canViewPublicStores;
    final canOpenPrepaidMultipayCards = _canOpenPrepaidOfflineCards;
    final canAcceptNfcPayments =
        permissions.canAcceptPrepaidMultipayContactless;
    final l = context.loc;
    final showOfflineSyncAction =
        _canSyncWorkspace &&
        _isDeviceOnline &&
        (_pendingOfflineCount > 0 || _isSyncingOfflineWorkspace);

    if (OfflineSessionService.isOfflineMode) {
      return [
        if (_canOfflineScan && (_isDeviceOnline || _offlineAccessExpired))
          _HomeServiceItem(
            title: _isSyncingOfflineWorkspace
                ? _t('screens_home_screen.064')
                : _t('screens_home_screen.108'),
            subtitle: _offlineAccessExpired
                ? _t('screens_home_screen.109')
                : _t('screens_home_screen.110'),
            icon: Icons.cloud_sync_rounded,
            color: _offlineAccessExpired ? AppTheme.error : AppTheme.primary,
            kind: _HomeServiceKind.sync,
            onTap: () => unawaited(_syncOfflineWorkspace()),
            badgeIcon: _isSyncingOfflineWorkspace
                ? Icons.sync_rounded
                : _offlineAccessExpired
                ? Icons.priority_high_rounded
                : Icons.check_rounded,
            badgeColor: _offlineAccessExpired
                ? AppTheme.error
                : AppTheme.success,
          ),
        if (canScanCards)
          _HomeServiceItem(
            title:
                '${l.tr('screens_home_screen.015')} ($_availableOfflineCount)',
            subtitle: _offlineAccessExpired
                ? _t('screens_home_screen.111')
                : _t('screens_home_screen.112'),
            icon: Icons.qr_code_scanner_rounded,
            color: _offlineAccessExpired ? AppTheme.error : AppTheme.success,
            kind: _HomeServiceKind.scan,
            onTap: _openScanScreen,
            badgeIcon: _offlineAccessExpired
                ? Icons.priority_high_rounded
                : Icons.check_rounded,
            badgeColor: _offlineAccessExpired
                ? AppTheme.error
                : AppTheme.success,
          ),
        if (canManageDebtBook)
          _HomeServiceItem(
            title: _t('screens_home_screen.071'),
            subtitle: _t('screens_home_screen.076'),
            icon: Icons.menu_book_rounded,
            color: AppTheme.primaryDark,
            kind: _HomeServiceKind.debtBook,
            onTap: () =>
                unawaited(_openRoute('/debt-book', allowOffline: true)),
          ),
        if (canAccessStoreManagement)
          _HomeServiceItem(
            title: l.text('إدارة المخزون', 'Inventory management'),
            subtitle: l.text(
              'المخزون والمبيعات والمشتريات والديون والتقارير.',
              'Inventory, sales, purchases, debts and reports.',
            ),
            icon: Icons.storefront_rounded,
            color: AppTheme.secondary,
            kind: _HomeServiceKind.storeManagement,
            onTap: () =>
                unawaited(_openRoute('/store-management', allowOffline: true)),
          ),
        if (canViewInventory && canIssueCards && _hasOfflineWorkspace)
          _HomeServiceItem(
            title: l.tr('screens_home_screen.023'),
            subtitle: _t('screens_home_screen.114'),
            icon: Icons.inventory_2_rounded,
            color: AppTheme.textSecondary,
            kind: _HomeServiceKind.inventory,
            onTap: () =>
                unawaited(_openRoute('/inventory', allowOffline: true)),
          ),
        if (canOpenPrepaidMultipayCards)
          _HomeServiceItem(
            title: l.tr('screens_home_screen.118'),
            subtitle: l.text(
              'بطاقات محفوظة على الجهاز.',
              'Saved cards on device.',
            ),
            icon: Icons.credit_card_rounded,
            color: AppTheme.secondaryLight,
            kind: _HomeServiceKind.prepaidMultipay,
            onTap: () => unawaited(
              _openRoute('/prepaid-multipay-cards', allowOffline: true),
            ),
            badgeIcon: Icons.offline_bolt_rounded,
            badgeColor: AppTheme.warning,
          ),
      ];
    }

    if (canReviewCards && !canIssueCards) {
      return [
        if (showOfflineSyncAction)
          _HomeServiceItem(
            title: _isSyncingOfflineWorkspace
                ? _t('screens_home_screen.064')
                : _t('screens_home_screen.065'),
            subtitle: _pendingOfflineCount > 0
                ? _t('screens_home_screen.109')
                : _t('screens_home_screen.115'),
            icon: Icons.cloud_sync_rounded,
            color: AppTheme.primary,
            kind: _HomeServiceKind.sync,
            onTap: () => unawaited(_syncOfflineWorkspace()),
            badgeIcon: _isSyncingOfflineWorkspace
                ? Icons.sync_rounded
                : _pendingOfflineCount > 0
                ? Icons.priority_high_rounded
                : Icons.check_rounded,
            badgeColor: _pendingOfflineCount > 0
                ? AppTheme.warning
                : AppTheme.success,
          ),
        _HomeServiceItem(
          title: l.tr('screens_home_screen.015'),
          subtitle: l.tr('screens_home_screen.016'),
          icon: Icons.qr_code_scanner_rounded,
          color: AppTheme.success,
          kind: _HomeServiceKind.scan,
          onTap: _openScanScreen,
        ),
        if (canManageDebtBook)
          _HomeServiceItem(
            title: _t('screens_home_screen.071'),
            subtitle: _t('screens_home_screen.076'),
            icon: Icons.menu_book_rounded,
            color: AppTheme.primaryDark,
            kind: _HomeServiceKind.debtBook,
            onTap: () =>
                unawaited(_openRoute('/debt-book', allowOffline: true)),
          ),
        if (canAccessStoreManagement)
          _HomeServiceItem(
            title: l.text('إدارة المخزون', 'Inventory management'),
            subtitle: l.text(
              'مخزون وفواتير وديون المحل.',
              'Inventory, invoices and debts.',
            ),
            icon: Icons.storefront_rounded,
            color: AppTheme.secondary,
            kind: _HomeServiceKind.storeManagement,
            onTap: () =>
                unawaited(_openRoute('/store-management', allowOffline: true)),
          ),
      ];
    }

    return [
      if (showOfflineSyncAction)
        _HomeServiceItem(
          title: _isSyncingOfflineWorkspace
              ? _t('screens_home_screen.064')
              : _t('screens_home_screen.065'),
          subtitle: _pendingOfflineCount > 0
              ? _t('screens_home_screen.109')
              : _t('screens_home_screen.115'),
          icon: Icons.cloud_sync_rounded,
          color: AppTheme.primary,
          kind: _HomeServiceKind.sync,
          onTap: () => unawaited(_syncOfflineWorkspace()),
          badgeIcon: _isSyncingOfflineWorkspace
              ? Icons.sync_rounded
              : _pendingOfflineCount > 0
              ? Icons.priority_high_rounded
              : Icons.check_rounded,
          badgeColor: _pendingOfflineCount > 0
              ? AppTheme.warning
              : AppTheme.success,
        ),
      if (canScanCards)
        _HomeServiceItem(
          title: l.tr('screens_home_screen.015'),
          subtitle: l.tr('screens_home_screen.016'),
          icon: Icons.qr_code_scanner_rounded,
          color: AppTheme.success,
          kind: _HomeServiceKind.scan,
          onTap: _openScanScreen,
        ),
      if (canViewBalance)
        _HomeServiceItem(
          title: l.tr('screens_home_screen.017'),
          subtitle: l.tr('screens_home_screen.018'),
          icon: Icons.account_balance_wallet_rounded,
          color: AppTheme.primary,
          kind: _HomeServiceKind.balance,
          onTap: () => unawaited(_openOnlineOnlyRoute('/balance')),
        ),
      if (canIssueCards)
        _HomeServiceItem(
          title: l.tr('screens_home_screen.019'),
          subtitle: l.tr('screens_home_screen.020'),
          icon: Icons.add_card_rounded,
          color: AppTheme.primaryDark,
          kind: _HomeServiceKind.createCard,
          onTap: () => unawaited(_openOnlineOnlyRoute('/create-card')),
        ),
      if (canOpenExternalCardStore)
        _HomeServiceItem(
          title: l.text('متجر الكروت', 'Card store'),
          subtitle: l.text(
            'شراء البطاقات الرقمية وعرض الطلبات من المتجر الخارجي.',
            'Buy digital cards and view orders from the external store.',
          ),
          icon: Icons.store_mall_directory_rounded,
          color: AppTheme.primary,
          kind: _HomeServiceKind.externalCardStore,
          onTap: () => unawaited(_openOnlineOnlyRoute('/external-card-store')),
        ),
      if (canViewPublicStores)
        _HomeServiceItem(
          title: l.text('المتاجر', 'Stores'),
          subtitle: l.text(
            'تصفح متاجر التجار والشراء حسب الكمية المتاحة.',
            'Browse merchant stores and buy by available quantity.',
          ),
          icon: Icons.store_mall_directory_rounded,
          color: AppTheme.primary,
          kind: _HomeServiceKind.publicStores,
          onTap: () => unawaited(_openOnlineOnlyRoute('/public-stores')),
        ),
      if (canOpenPrepaidMultipayCards)
        _HomeServiceItem(
          title: l.tr('screens_home_screen.118'),
          subtitle: permissions.canUsePrepaidMultipayCards
              ? l.tr('screens_home_screen.119')
              : l.tr('screens_home_screen.120'),
          icon: Icons.credit_card_rounded,
          color: AppTheme.secondaryLight,
          kind: _HomeServiceKind.prepaidMultipay,
          onTap: () =>
              unawaited(_openOnlineOnlyRoute('/prepaid-multipay-cards')),
        ),
      if (canAcceptNfcPayments)
        _HomeServiceItem(
          title: l.tr('screens_home_screen.121'),
          subtitle: l.tr('screens_home_screen.122'),
          icon: Icons.contactless_rounded,
          color: AppTheme.primary,
          kind: _HomeServiceKind.prepaidMultipay,
          onTap: () => unawaited(
            _openOnlineOnlyRoute(
              '/prepaid-multipay-contactless-accept',
              arguments: const {'autoReadNfc': true},
            ),
          ),
          badgeIcon: Icons.contactless_rounded,
          badgeColor: AppTheme.success,
        ),
      if (_canTransfer)
        _HomeServiceItem(
          title: l.tr('screens_home_screen.021'),
          subtitle: l.tr('screens_home_screen.022'),
          icon: Icons.send_to_mobile_rounded,
          color: AppTheme.accent,
          kind: _HomeServiceKind.quickTransfer,
          onTap: () => unawaited(_openOnlineOnlyRoute('/quick-transfer')),
        ),
      if (_canTransfer)
        _HomeServiceItem(
          title: l.text('استلام التاجر', 'Merchant receive'),
          subtitle: l.text(
            'شاشة مستقلة لعرض رمز الاستلام وقبول التحويل بوضوح.',
            'Standalone screen to display receive code and accept transfers clearly.',
          ),
          icon: Icons.storefront_rounded,
          color: AppTheme.secondary,
          kind: _HomeServiceKind.merchantReceive,
          onTap: () => unawaited(_openOnlineOnlyRoute('/merchant-receive')),
        ),
      if (_canTransfer)
        _HomeServiceItem(
          title: l.tr('screens_home_screen.123'),
          subtitle: l.tr('screens_home_screen.124'),
          icon: Icons.qr_code_2_rounded,
          color: AppTheme.primary,
          kind: _HomeServiceKind.temporaryTransfer,
          onTap: () => unawaited(
            _openOnlineOnlyRoute(
              '/scan-card',
              arguments: const {'openTemporaryTransferCreator': true},
            ),
          ),
        ),
      if (canViewInventory && canIssueCards)
        _HomeServiceItem(
          title: l.tr('screens_home_screen.023'),
          subtitle: l.tr('screens_home_screen.024'),
          icon: Icons.inventory_2_rounded,
          color: AppTheme.textSecondary,
          kind: _HomeServiceKind.inventory,
          onTap: () => unawaited(_openOnlineOnlyRoute('/inventory')),
        ),
      if (canRequestCardPrinting)
        _HomeServiceItem(
          title: l.tr('screens_home_screen.025'),
          subtitle: l.tr('screens_home_screen.026'),
          icon: Icons.print_rounded,
          color: AppTheme.secondary,
          kind: _HomeServiceKind.printRequests,
          onTap: () => unawaited(_openOnlineOnlyRoute('/card-print-requests')),
        ),
      if (canViewTransactions)
        _HomeServiceItem(
          title: l.tr('screens_home_screen.027'),
          subtitle: l.tr('screens_home_screen.028'),
          icon: Icons.receipt_long_rounded,
          color: AppTheme.warning,
          kind: _HomeServiceKind.transactions,
          onTap: () => unawaited(_openOnlineOnlyRoute('/transactions')),
        ),
      if (canViewAffiliateCenter)
        _HomeServiceItem(
          title: l.tr('screens_home_screen.082'),
          subtitle: l.tr('screens_home_screen.083'),
          icon: Icons.campaign_rounded,
          color: AppTheme.primary,
          kind: _HomeServiceKind.affiliate,
          onTap: () => unawaited(_openOnlineOnlyRoute('/affiliate-center')),
        ),
      if (canManageDebtBook)
        _HomeServiceItem(
          title: _t('screens_home_screen.071'),
          subtitle: _t('screens_home_screen.079'),
          icon: Icons.menu_book_rounded,
          color: AppTheme.primaryDark,
          kind: _HomeServiceKind.debtBook,
          onTap: () => unawaited(_openOnlineOnlyRoute('/debt-book')),
        ),
      if (canAccessStoreManagement)
        _HomeServiceItem(
          title: l.text('إدارة المخزون', 'Inventory management'),
          subtitle: l.text(
            'المخزون والمبيعات والمشتريات والديون والأرباح.',
            'Inventory, sales, purchases, debts and profits.',
          ),
          icon: Icons.storefront_rounded,
          color: AppTheme.secondary,
          kind: _HomeServiceKind.storeManagement,
          onTap: () => unawaited(_openOnlineOnlyRoute('/store-management')),
        ),
      if (canViewSecuritySettings)
        _HomeServiceItem(
          title: l.tr('screens_home_screen.029'),
          subtitle: l.tr('screens_home_screen.030'),
          icon: Icons.security_rounded,
          color: AppTheme.secondary,
          kind: _HomeServiceKind.security,
          onTap: () => unawaited(_openOnlineOnlyRoute('/security-settings')),
        ),
    ];
  }

  Widget _buildWelcomeCard() {
    final greeting = _t('screens_home_screen.084');
    final displayName = _displayName;
    final roleLabel = _roleLabel.isEmpty
        ? _t('screens_home_screen.085')
        : _roleLabel;
    final experience = _roleExperience;
    final userLogoUrl = _user?['printLogoUrl']?.toString().trim() ?? '';
    final balance = (_user?['balance'] as num?)?.toDouble() ?? 0;
    final balanceTextColor = balance < 0
        ? AppTheme.errorTextOnDark
        : Colors.white;

    return ShwakelCard(
      padding: const EdgeInsets.all(24),
      borderRadius: BorderRadius.circular(26),
      shadowLevel: ShwakelShadowLevel.medium,
      gradient: experience.gradient,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxWidth < 520;
          final logoSize = isCompact ? 64.0 : 72.0;
          final logoImageSize = isCompact ? 38.0 : 44.0;
          Widget infoChip({
            required IconData icon,
            required String label,
            required Color color,
          }) {
            return Container(
              padding: EdgeInsets.symmetric(
                horizontal: isCompact ? 10 : 12,
                vertical: isCompact ? 8 : 10,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white24),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: AppTheme.caption.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            );
          }

          final metaBlock = Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              infoChip(
                icon: experience.icon,
                label: experience.title,
                color: Colors.white,
              ),
              if (roleLabel != experience.title)
                infoChip(
                  icon: Icons.badge_rounded,
                  label: roleLabel,
                  color: Colors.white,
                ),
              infoChip(
                icon: _isVerifiedUser
                    ? Icons.verified_rounded
                    : Icons.pending_outlined,
                label: _verificationLabel,
                color: _isVerifiedUser
                    ? AppTheme.successTextOnDark
                    : AppTheme.warningTextOnDark,
              ),
            ],
          );
          final logo = Container(
            width: logoSize,
            height: logoSize,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white24),
            ),
            alignment: Alignment.center,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: userLogoUrl.isNotEmpty
                  ? Image.network(
                      userLogoUrl,
                      width: logoImageSize,
                      height: logoImageSize,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => Image.asset(
                        'assets/images/shwakel_app_icon.png',
                        width: logoImageSize,
                        height: logoImageSize,
                        fit: BoxFit.contain,
                      ),
                    )
                  : Image.asset(
                      'assets/images/shwakel_app_icon.png',
                      width: logoImageSize,
                      height: logoImageSize,
                      fit: BoxFit.contain,
                    ),
            ),
          );
          final balanceCard = Container(
            width: double.infinity,
            padding: EdgeInsets.all(isCompact ? 14 : 16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: Colors.white24),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _t('screens_home_screen.093'),
                  style: AppTheme.caption.copyWith(
                    color: Colors.white.withValues(alpha: 0.86),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: _isBalanceVisible
                          ? _t('screens_home_screen.096')
                          : _t('screens_home_screen.099'),
                      onPressed: () =>
                          _setBalanceVisibility(!_isBalanceVisible),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      icon: Icon(
                        _isBalanceVisible
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _isBalanceVisible
                            ? CurrencyFormatter.ils(balance)
                            : '******',
                        textAlign: TextAlign.end,
                        style: AppTheme.h1.copyWith(
                          color: balanceTextColor,
                          fontSize: isCompact ? 28 : 32,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: isCompact ? 6 : 8),
                Text(
                  _t('screens_home_screen.094'),
                  textAlign: TextAlign.start,
                  style: AppTheme.bodyAction.copyWith(
                    color: Colors.white.withValues(alpha: 0.86),
                    height: 1.4,
                    fontSize: isCompact ? 14 : 15,
                  ),
                ),
                if (_canOfflineScan) ...[
                  const SizedBox(height: 8),
                  Text(
                    _t(
                      'screens_home_screen.116',
                      params: {
                        'time': _formatSyncTimestamp(_lastOfflineSyncAt),
                        'suffix': OfflineSessionService.isOfflineMode
                            ? _t('screens_home_screen.117')
                            : '',
                      },
                    ),
                    style: AppTheme.caption.copyWith(
                      color: Colors.white.withValues(alpha: 0.82),
                      fontWeight: FontWeight.w700,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          );

          final compactHeader = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      greeting,
                      style: AppTheme.bodyAction.copyWith(
                        color: Colors.white.withValues(alpha: 0.88),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (displayName.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        displayName,
                        style: AppTheme.h2.copyWith(
                          color: Colors.white,
                          fontSize: 20,
                          height: 1.2,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      experience.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.caption.copyWith(
                        color: Colors.white.withValues(alpha: 0.82),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    metaBlock,
                  ],
                ),
              ),
              const SizedBox(width: 14),
              logo,
            ],
          );

          final textBlock = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isCompact)
                compactHeader
              else ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    logo,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            greeting,
                            style: AppTheme.bodyAction.copyWith(
                              color: Colors.white.withValues(alpha: 0.88),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (displayName.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              displayName,
                              style: AppTheme.h2.copyWith(
                                fontSize: 22,
                                color: Colors.white,
                              ),
                            ),
                          ],
                          const SizedBox(height: 6),
                          Text(
                            experience.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTheme.caption.copyWith(
                              color: Colors.white.withValues(alpha: 0.82),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                metaBlock,
              ],
              SizedBox(height: isCompact ? 12 : 16),
              balanceCard,
            ],
          );

          return ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 144),
            child: textBlock,
          );
        },
      ),
    );
  }

  Widget _buildHomeContent(
    BuildContext context, {
    required _HomeServiceItem? scanShortcut,
    required List<_HomeServiceItem> listServices,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mediaQuery = MediaQuery.of(context);
        final isLandscapePhone =
            mediaQuery.orientation == Orientation.landscape &&
            constraints.maxWidth < 1100;
        final useWideLayout = constraints.maxWidth >= 900;

        if (!isLandscapePhone && !useWideLayout) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildWelcomeCard(),
              if (scanShortcut != null) ...[
                const SizedBox(height: 14),
                if (!_isVerifiedUser) ...[
                  _buildAccountVerificationReminder(),
                  const SizedBox(height: 14),
                ],
                _buildScanShortcut(scanShortcut),
              ],
              const SizedBox(height: 18),
              _buildServicesSection(listServices),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 11, child: _buildWelcomeCard()),
                if (scanShortcut != null) ...[
                  const SizedBox(width: 14),
                  Expanded(
                    flex: 9,
                    child: Column(
                      children: [
                        if (!_isVerifiedUser) ...[
                          _buildAccountVerificationReminder(),
                          const SizedBox(height: 14),
                        ],
                        _buildScanShortcut(scanShortcut),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 18),
            _buildServicesSection(listServices),
          ],
        );
      },
    );
  }

  Widget _buildAccountVerificationReminder() {
    final color = _isVerificationPending ? AppTheme.warning : AppTheme.primary;
    final title = _isVerificationPending
        ? 'طلب توثيق الحساب قيد المراجعة'
        : 'حسابك غير موثق بعد';
    final message = _isVerificationPending
        ? 'طلبك قيد المراجعة.'
        : 'وثق حسابك للاستفادة الكاملة من الخدمات.';
    final actionLabel = _isVerificationPending
        ? 'متابعة الطلب'
        : 'توثيق الحساب';

    return ShwakelCard(
      onTap: () => unawaited(_openOnlineOnlyRoute('/account-verification')),
      padding: const EdgeInsets.all(16),
      borderRadius: BorderRadius.circular(22),
      color: color.withValues(alpha: 0.07),
      borderColor: color.withValues(alpha: 0.18),
      shadowLevel: ShwakelShadowLevel.medium,
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(Icons.verified_user_rounded, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTheme.bodyBold.copyWith(color: color)),
                const SizedBox(height: 5),
                Text(
                  message,
                  style: AppTheme.caption.copyWith(
                    color: AppTheme.textSecondary,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: () =>
                unawaited(_openOnlineOnlyRoute('/account-verification')),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }

  Widget _buildServicesGrid(
    List<_HomeServiceItem> services, {
    required int crossAxisCount,
    required double tileExtent,
  }) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: services.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        mainAxisExtent: tileExtent,
      ),
      itemBuilder: (context, index) => crossAxisCount == 1
          ? _buildServiceListItem(services[index])
          : _buildCompactServiceTile(services[index]),
    );
  }

  Widget _buildScanShortcut(_HomeServiceItem item) {
    final experience = _roleExperience;
    return ShwakelCard(
      onTap: item.onTap,
      padding: const EdgeInsets.all(22),
      borderRadius: BorderRadius.circular(24),
      shadowLevel: ShwakelShadowLevel.medium,
      borderColor: item.color.withValues(alpha: 0.16),
      color: item.color.withValues(alpha: 0.04),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxWidth < 560;
          final cta = Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: item.color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: item.color.withValues(alpha: 0.14)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.camera_alt_rounded, size: 18, color: item.color),
                const SizedBox(width: 6),
                Text(
                  experience.scanTitle,
                  style: AppTheme.caption.copyWith(
                    color: item.color,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          );
          final quickCreateCta = AppPermissions.fromUser(_user).canIssueCards
              ? InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () =>
                      unawaited(_openOnlineOnlyRoute('/create-card-quick')),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: AppTheme.primary.withValues(alpha: 0.14),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.add_card_rounded,
                          size: 18,
                          color: AppTheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          context.loc.text(
                            'إنشاء بطاقة سريعة',
                            'Quick Card Creation',
                          ),
                          style: AppTheme.caption.copyWith(
                            color: AppTheme.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : null;
          final iconBox = Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              color: item.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(item.icon, color: item.color, size: 30),
          );

          final textBlock = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                experience.scanTitle,
                style: AppTheme.bodyBold.copyWith(fontSize: 17),
              ),
              const SizedBox(height: 6),
              Text(
                experience.scanSubtitle,
                style: AppTheme.bodyAction.copyWith(height: 1.45),
              ),
            ],
          );

          return ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 148),
            child: isCompact
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          iconBox,
                          const SizedBox(width: 14),
                          Expanded(child: textBlock),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SizedBox(width: double.infinity, child: cta),
                      if (quickCreateCta != null) ...[
                        const SizedBox(height: 10),
                        SizedBox(width: double.infinity, child: quickCreateCta),
                      ],
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      iconBox,
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [textBlock],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Align(
                        alignment: Alignment.center,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(width: 190, child: cta),
                            if (quickCreateCta != null) ...[
                              const SizedBox(height: 10),
                              SizedBox(width: 190, child: quickCreateCta),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
          );
        },
      ),
    );
  }

  Widget _buildSyncStatusAction() {
    final hasPending = _pendingOfflineCount > 0;
    final canOpenStatus = _hasOfflineWorkspace || _canOpenCardTools;
    final backgroundColor = _isSyncingOfflineWorkspace
        ? AppTheme.warning.withValues(alpha: 0.16)
        : hasPending
        ? AppTheme.warning.withValues(alpha: 0.16)
        : AppTheme.success.withValues(alpha: 0.14);
    final iconColor = _isSyncingOfflineWorkspace
        ? AppTheme.warning
        : hasPending
        ? AppTheme.warning
        : AppTheme.success;
    final tooltip = _isSyncingOfflineWorkspace
        ? _t('screens_home_screen.064')
        : hasPending
        ? _t(
            'screens_home_screen.077',
            params: {'count': '$_pendingOfflineCount'},
          )
        : _t('screens_home_screen.053');

    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 2),
      child: IconButton(
        tooltip: tooltip,
        onPressed: !canOpenStatus ? null : _showSyncStatusSheet,
        icon: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(14),
              ),
              child: _isSyncingOfflineWorkspace
                  ? Padding(
                      padding: const EdgeInsets.all(9),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        valueColor: AlwaysStoppedAnimation<Color>(iconColor),
                      ),
                    )
                  : Icon(Icons.check_rounded, color: iconColor, size: 20),
            ),
            if (hasPending && !_isSyncingOfflineWorkspace)
              Positioned(
                top: -5,
                left: -5,
                child: Container(
                  constraints: const BoxConstraints(
                    minWidth: 18,
                    minHeight: 18,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.error,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: Text(
                    _pendingOfflineCount > 9 ? '9+' : '$_pendingOfflineCount',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSyncStatusSheet() async {
    final lastSync = _formatSyncTimestamp(_lastOfflineSyncAt);
    final statusText = _isSyncingOfflineWorkspace
        ? _t('screens_home_screen.064')
        : _pendingOfflineCount > 0
        ? _t(
            'screens_home_screen.077',
            params: {'count': '$_pendingOfflineCount'},
          )
        : _t('screens_home_screen.053');

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => Scaffold(
          backgroundColor: AppTheme.background,
          appBar: AppBar(
            title: Text(_t('screens_home_screen.089')),
            actions: const [AppNotificationAction(), QuickLogoutAction()],
          ),
          body: ResponsiveScaffoldContainer(
            padding: const EdgeInsets.all(AppTheme.spacingLg),
            child: ListView(
              children: [
                ShwakelCard(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_t('screens_home_screen.089'), style: AppTheme.h3),
                      const SizedBox(height: 14),
                      _syncInfoRow(_t('screens_home_screen.090'), statusText),
                      _syncInfoRow(_t('screens_home_screen.091'), lastSync),
                      _syncInfoRow(
                        _t('screens_home_screen.100'),
                        _t(
                          'screens_home_screen.101',
                          params: {
                            'available': '$_availableOfflineCount',
                            'cached': '$_cachedOfflineCount',
                          },
                        ),
                      ),
                      _syncInfoRow(
                        _t('screens_home_screen.102'),
                        '$_pendingOfflineCount',
                      ),
                      if (_pendingStoreManagementCount > 0)
                        _syncInfoRow(
                          context.loc.text(
                            'عمليات إدارة المخزون المعلقة',
                            'Pending store operations',
                          ),
                          '$_pendingStoreManagementCount',
                        ),
                      if (_rejectedOfflineCount > 0)
                        _syncInfoRow(
                          _t('screens_home_screen.103'),
                          '$_rejectedOfflineCount',
                        ),
                      _syncInfoRow(
                        _t('screens_home_screen.104'),
                        _t(
                          'screens_home_screen.105',
                          params: {'minutes': '$_offlineSyncIntervalMinutes'},
                        ),
                      ),
                      if (_offlineAccessExpired)
                        _syncInfoRow(
                          _t('screens_home_screen.090'),
                          _t('screens_home_screen.106'),
                        ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed:
                              _isSyncingOfflineWorkspace || !_isDeviceOnline
                              ? null
                              : () {
                                  unawaited(_syncOfflineWorkspace());
                                },
                          icon: const Icon(Icons.cloud_sync_rounded),
                          label: Text(_t('screens_home_screen.107')),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatSyncTimestamp(String? raw) {
    final date = raw == null ? null : DateTime.tryParse(raw);
    if (date == null) {
      return _t('screens_home_screen.092');
    }
    final local = date.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }

  Widget _syncInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTheme.caption),
          const SizedBox(height: 4),
          Text(value, style: AppTheme.bodyBold),
        ],
      ),
    );
  }

  Widget _buildServicesSection(List<_HomeServiceItem> services) {
    final l = context.loc;
    final experience = _roleExperience;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isPhoneLayout = width < 520;
        final crossAxisCount = isPhoneLayout
            ? 2
            : width >= 1180
            ? 4
            : width >= 820
            ? 3
            : 2;
        final tileExtent = isPhoneLayout ? 132.0 : 142.0;
        final sectionHeader = Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppTheme.primarySoft,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.dashboard_customize_rounded,
                color: AppTheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.tr('screens_home_screen.004'), style: AppTheme.h2),
                  const SizedBox(height: 2),
                  Text(experience.servicesTitle, style: AppTheme.caption),
                ],
              ),
            ),
          ],
        );

        final emptyState = Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppTheme.surfaceVariant,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.border),
          ),
          child: Text(
            l.tr('screens_home_screen.005'),
            style: AppTheme.bodyAction,
          ),
        );

        return ShwakelCard(
          padding: EdgeInsets.all(width < 520 ? 14 : 20),
          borderRadius: BorderRadius.circular(28),
          shadowLevel: ShwakelShadowLevel.medium,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              sectionHeader,
              const SizedBox(height: 16),
              if (services.isEmpty)
                emptyState
              else
                _buildServicesGrid(
                  services,
                  crossAxisCount: crossAxisCount,
                  tileExtent: tileExtent,
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCompactServiceTile(_HomeServiceItem item) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: item.onTap,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 14,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: item.color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(item.icon, color: item.color, size: 24),
                  ),
                  if (item.badgeIcon != null)
                    Positioned(
                      top: -4,
                      left: -4,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: (item.badgeColor ?? item.color).withValues(
                              alpha: 0.24,
                            ),
                          ),
                        ),
                        child: Icon(
                          item.badgeIcon,
                          size: 12,
                          color: item.badgeColor ?? item.color,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 9),
              Flexible(
                child: Text(
                  _compactServiceTitle(item.title),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  softWrap: true,
                  style: AppTheme.caption.copyWith(
                    color: AppTheme.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    height: 1.24,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildServiceListItem(_HomeServiceItem item) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: item.onTap,
        child: Ink(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppTheme.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxWidth < 520;
              return Flex(
                direction: Axis.horizontal,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: item.color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Icon(item.icon, color: item.color, size: 26),
                      ),
                      if (item.badgeIcon != null)
                        Positioned(
                          top: -4,
                          left: -4,
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: (item.badgeColor ?? item.color)
                                    .withValues(alpha: 0.24),
                              ),
                            ),
                            child: Icon(
                              item.badgeIcon,
                              size: 14,
                              color: item.badgeColor ?? item.color,
                            ),
                          ),
                        ),
                    ],
                  ),
                  SizedBox(width: isCompact ? 12 : 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          item.title,
                          style: isCompact
                              ? AppTheme.bodyBold.copyWith(
                                  fontSize: 15.5,
                                  height: 1.2,
                                )
                              : AppTheme.bodyBold,
                          maxLines: isCompact ? 2 : 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.subtitle,
                          style: AppTheme.bodyAction.copyWith(
                            height: isCompact ? 1.25 : 1.35,
                            fontSize: isCompact ? 12.5 : null,
                          ),
                          maxLines: isCompact ? 2 : 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: isCompact ? 8 : 12),
                  Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: isCompact ? 16 : 18,
                    color: AppTheme.textSecondary.withValues(alpha: 0.7),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  String _compactServiceTitle(String title) {
    final trimmed = title.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (trimmed.length <= 18) {
      return trimmed;
    }
    final words = trimmed.split(' ');
    if (words.length <= 2) {
      return trimmed;
    }

    final midpoint = (words.length / 2).ceil();
    return '${words.take(midpoint).join(' ')}\n${words.skip(midpoint).join(' ')}';
  }
}

class _HomeServiceItem {
  const _HomeServiceItem({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.kind,
    required this.onTap,
    this.badgeIcon,
    this.badgeColor,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final _HomeServiceKind kind;
  final VoidCallback onTap;
  final IconData? badgeIcon;
  final Color? badgeColor;
}

enum _HomeServiceKind {
  scan,
  sync,
  balance,
  createCard,
  prepaidMultipay,
  quickTransfer,
  merchantReceive,
  temporaryTransfer,
  inventory,
  printRequests,
  transactions,
  affiliate,
  debtBook,
  externalCardStore,
  publicStores,
  storeManagement,
  security,
}

class _RoleExperience {
  const _RoleExperience({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.gradient,
    required this.accent,
    required this.servicesTitle,
    required this.scanTitle,
    required this.scanSubtitle,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final LinearGradient gradient;
  final Color accent;
  final String servicesTitle;
  final String scanTitle;
  final String scanSubtitle;
}
