import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'screens/index.dart';
import 'services/index.dart';
import 'utils/app_permissions.dart';
import 'utils/app_theme.dart';
import 'widgets/app_sidebar.dart';
import 'widgets/shwakel_button.dart';
import 'widgets/shwakel_logo.dart';

final AppRouteObserver appRouteObserver = AppRouteObserver();

class AppRouteObserver extends RouteObserver<ModalRoute<void>>
    with ChangeNotifier {
  String? currentRouteName;
  bool _notifyScheduled = false;

  void _setCurrentRoute(Route<dynamic>? route) {
    final nextName = route?.settings.name;
    if (nextName == currentRouteName) {
      return;
    }
    currentRouteName = nextName;
    _notifyAfterBuild();
  }

  void _notifyAfterBuild() {
    if (_notifyScheduled) {
      return;
    }
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      notifyListeners();
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _setCurrentRoute(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _setCurrentRoute(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _setCurrentRoute(newRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _setCurrentRoute(previousRoute);
  }
}

final Map<String, WidgetBuilder> _appRoutes = {
  '/app-shell': (context) => const _AppLifecycleShell(),
  '/home': (context) => const HomeScreen(),
  '/offline-sync': (context) => const HomeScreen(openSyncStatus: true),
  '/login': (context) {
    final args = ModalRoute.of(context)?.settings.arguments;
    final options = args is Map ? args : const <String, dynamic>{};
    return LoginScreen(
      initialIdentifier: options['initialIdentifier']?.toString(),
    );
  },
  '/login-offline': (context) {
    final args = ModalRoute.of(context)?.settings.arguments;
    final options = args is Map ? args : const <String, dynamic>{};
    return LoginScreen(
      redirectRoute: '/home',
      offlineMode: true,
      initialIdentifier: options['initialIdentifier']?.toString(),
    );
  },
  '/register': (context) => const RegisterScreen(),
  '/support-tickets': (context) {
    final args = ModalRoute.of(context)?.settings.arguments;
    final options = args is Map ? args : const <String, dynamic>{};
    return SupportTicketsScreen(openTracking: options['tracking'] == true);
  },
  '/unlock': (context) => const DeviceUnlockScreen(),
  '/balance': (context) => const BalanceScreen(),
  '/create-card': (context) => const CreateCardScreen(),
  '/create-card-quick': (context) => const CreateCardScreen(quickMode: true),
  '/prepaid-multipay-cards': (context) {
    final args = ModalRoute.of(context)?.settings.arguments;
    final options = args is Map ? args : const <String, dynamic>{};
    return PrepaidMultipayCardsScreen(
      openPaymentsTab: options['openPaymentsTab'] == true,
      autoAcceptNfc: options['autoAcceptNfc'] == true,
      offlineOnly: options['offlineOnly'] == true,
    );
  },
  '/external-card-store': (context) => const ExternalCardStoreScreen(),
  '/public-stores': (context) => const PublicStoresScreen(),
  '/prepaid-multipay-contactless-accept': (context) => ScanCardScreen(
    offlineMode: OfflineSessionService.isOfflineMode,
    autoReadNfc: true,
  ),
  '/quick-transfer': (context) => const QuickTransferScreen(),
  '/card-print-requests': (context) => const CardPrintRequestsScreen(),
  '/card-usage-report': (context) => const IssuedCardUsageReportScreen(),
  '/scan-card': (context) {
    final args = ModalRoute.of(context)?.settings.arguments;
    final options = args is Map ? args : const <String, dynamic>{};
    return ScanCardScreen(
      initialBarcode: options['initialBarcode']?.toString(),
      autoOpenScanner: options['autoOpenScanner'] == true,
      autoReadNfc: options['autoReadNfc'] == true,
      openTemporaryTransferCreator:
          options['openTemporaryTransferCreator'] == true,
    );
  },
  '/scan-card-camera': (context) {
    final args = ModalRoute.of(context)?.settings.arguments;
    final options = args is Map ? args : const <String, dynamic>{};
    return ScanCardScreen(
      autoOpenScanner: true,
      initialBarcode: options['initialBarcode']?.toString(),
      autoReadNfc: options['autoReadNfc'] == true,
    );
  },
  '/scan-card-offline': (context) {
    final args = ModalRoute.of(context)?.settings.arguments;
    final options = args is Map ? args : const <String, dynamic>{};
    return ScanCardScreen(
      offlineMode: true,
      initialBarcode: options['initialBarcode']?.toString(),
      autoOpenScanner: options['autoOpenScanner'] == true,
      autoReadNfc: options['autoReadNfc'] == true,
    );
  },
  '/scan-card-offline-camera': (context) {
    final args = ModalRoute.of(context)?.settings.arguments;
    final options = args is Map ? args : const <String, dynamic>{};
    return ScanCardScreen(
      offlineMode: true,
      autoOpenScanner: true,
      initialBarcode: options['initialBarcode']?.toString(),
      autoReadNfc: options['autoReadNfc'] == true,
    );
  },
  '/inventory': (context) => const InventoryScreen(),
  '/transactions': (context) => const TransactionsScreen(),
  '/notifications': (context) => const NotificationsScreen(),
  '/security-settings': (context) => const SecuritySettingsScreen(),
  '/account-settings': (context) => const AccountSettingsScreen(),
  '/affiliate-center': (context) => const AffiliateCenterScreen(),
  '/merchant-receive': (context) =>
      const QuickTransferScreen(initialTab: 1, merchantReceiveOnly: true),
  '/admin-dashboard': (context) => const AdminDashboardScreen(),
  '/admin-debt-book': (context) => const AdminDebtBookScreen(),
  '/admin-card-print-requests': (context) =>
      const AdminCardPrintRequestsScreen(),
  '/admin-card-scan-reports': (context) => const AdminCardScanReportsScreen(),
  '/admin-customers': (context) => const AdminCustomersScreen(),
  '/admin-pending-registrations': (context) =>
      const AdminPendingRegistrationsScreen(),
  '/admin-verification-requests': (context) =>
      const AdminVerificationRequestsScreen(),
  '/admin-device-requests': (context) => const AdminDeviceRequestsScreen(),
  '/admin-locations': (context) => const AdminLocationsScreen(),
  '/admin-notifications': (context) => const AdminNotificationsScreen(),
  '/admin-support-tickets': (context) => const AdminSupportTicketsScreen(),
  '/admin-prepaid-multipay-approvals': (context) =>
      const AdminPrepaidMultipayApprovalsScreen(),
  '/admin-system-settings': (context) => const AdminSystemSettingsScreen(),
  '/admin-permissions': (context) => const AdminPermissionsScreen(),
  '/withdrawal-requests': (context) => const WithdrawalRequestsScreen(),
  '/topup-requests': (context) => const TopupRequestsScreen(),
  '/usage-policy': (context) => const UsagePolicyScreen(),
  '/contact-us': (context) => const ContactUsScreen(),
  '/supported-locations': (context) => const SupportedLocationsScreen(),
  '/approved-merchants': (context) => const SupportedLocationsScreen(),
  '/forgot-password': (context) => const ForgotPasswordScreen(),
  '/account-verification': (context) => const AccountVerificationScreen(),
  '/sub-users': (context) => const SubUsersScreen(),
  '/debt-book': (context) => const DebtBookScreen(),
  '/store-management': (context) => const StoreManagementScreen(),
  '/maintenance-management': (context) => const MaintenanceManagementScreen(),
};

Route<dynamic> _buildNamedRoute(RouteSettings settings) {
  final resolvedName = OfflineSessionService.resolveRoute(settings.name);
  final builder = _appRoutes[resolvedName] ?? _appRoutes['/app-shell']!;

  return MaterialPageRoute<void>(
    settings: RouteSettings(name: resolvedName, arguments: settings.arguments),
    builder: (context) => _OfflineRouteGuard(
      routeName: resolvedName,
      child: _LocalSecurityRouteGuard(
        routeName: resolvedName,
        child: _PermissionRouteGuard(
          routeName: resolvedName,
          child: builder(context),
        ),
      ),
    ),
  );
}

bool _isPublicRoute(String? routeName) {
  return routeName == '/login' ||
      routeName == '/login-offline' ||
      routeName == '/register' ||
      routeName == '/support-tickets' ||
      routeName == '/forgot-password' ||
      routeName == '/unlock';
}

bool _isLocalSecurityExemptRoute(String? routeName) {
  return routeName == '/login' ||
      routeName == '/login-offline' ||
      routeName == '/register' ||
      routeName == '/forgot-password' ||
      routeName == '/unlock';
}

bool _routeAllowedForUser(String routeName, Map<String, dynamic>? user) {
  if (_isPublicRoute(routeName) || routeName == '/app-shell') {
    return true;
  }
  if (user == null) {
    return false;
  }

  final permissions = AppPermissions.fromUser(user);
  return switch (routeName) {
    '/home' || '/offline-sync' => true,
    '/balance' => permissions.canViewBalance,
    '/notifications' =>
      permissions.canViewTransactions || permissions.canViewBalance,
    '/create-card' => permissions.canIssueCards,
    '/create-card-quick' => permissions.canIssueCards,
    '/card-print-requests' => permissions.canRequestCardPrinting,
    '/card-usage-report' =>
      permissions.canIssueCards ||
          permissions.canRequestCardPrinting ||
          permissions.canViewInventory,
    '/inventory' => permissions.canViewInventory && permissions.canIssueCards,
    '/maintenance-management' => permissions.canAccessStoreManagement,
    '/scan-card' || '/scan-card-camera' =>
      permissions.canOpenCardTools || permissions.canReviewCards,
    '/scan-card-offline' ||
    '/scan-card-offline-camera' => permissions.canOfflineCardScan,
    '/prepaid-multipay-cards' => permissions.canOpenPrepaidMultipayCards,
    '/external-card-store' => permissions.canOpenExternalCardStore,
    '/public-stores' => permissions.canViewPublicStores,
    '/prepaid-multipay-contactless-accept' =>
      permissions.canAcceptPrepaidMultipayContactless,
    '/quick-transfer' => permissions.canTransfer,
    '/transactions' => permissions.canViewTransactions,
    '/withdrawal-requests' =>
      permissions.canWithdraw || permissions.canReviewWithdrawals,
    '/topup-requests' =>
      permissions.canReviewTopups || permissions.canFinanceTopup,
    '/security-settings' => permissions.canViewSecuritySettings,
    '/account-settings' => permissions.canViewAccountSettings,
    '/account-verification' => permissions.canRequestVerification,
    '/sub-users' => permissions.canViewSubUsers,
    '/debt-book' => permissions.canManageDebtBook,
    '/store-management' => permissions.canAccessStoreManagement,
    '/affiliate-center' => permissions.canViewAffiliateCenter,
    '/merchant-receive' => permissions.canTransfer,
    '/usage-policy' => permissions.canViewUsagePolicy,
    '/contact-us' => permissions.canViewContact,
    '/support-tickets' => true,
    '/supported-locations' ||
    '/approved-merchants' => permissions.canViewLocations,
    '/admin-dashboard' => permissions.hasAdminWorkspaceAccess,
    '/admin-customers' => permissions.canViewCustomers,
    '/admin-pending-registrations' =>
      permissions.canManageUsers || permissions.canManageMarketingAccounts,
    '/admin-verification-requests' => permissions.canManageUsers,
    '/admin-device-requests' => permissions.canReviewDevices,
    '/admin-locations' => permissions.canManageLocations,
    '/admin-notifications' => permissions.canManageAdminNotifications,
    '/admin-support-tickets' =>
      permissions.isAdminRole ||
          permissions.isSupportRole ||
          permissions.canManageUsers,
    '/admin-prepaid-multipay-approvals' =>
      permissions.canManagePrepaidMultipayApprovals,
    '/admin-system-settings' => permissions.canManageSystemSettings,
    '/admin-permissions' => permissions.canManagePermissionTemplates,
    '/admin-debt-book' => permissions.canManageDebtBook,
    '/admin-card-print-requests' => permissions.canManageCardPrintRequests,
    '/admin-card-scan-reports' => permissions.canViewAdminCardScanReports,
    _ => true,
  };
}

class _PermissionRouteGuard extends StatelessWidget {
  const _PermissionRouteGuard({required this.routeName, required this.child});

  final String routeName;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: AuthService().currentUser(),
      builder: (context, snapshot) {
        if (!snapshot.hasData && !_isPublicRoute(routeName)) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const _SplashScreen();
          }
        }

        final user = snapshot.data;
        if (_routeAllowedForUser(routeName, user)) {
          return child;
        }

        return _PermissionDeniedFallback(isLoggedIn: user != null);
      },
    );
  }
}

class _LocalSecurityRouteGuard extends StatelessWidget {
  const _LocalSecurityRouteGuard({
    required this.routeName,
    required this.child,
  });

  final String routeName;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (_isLocalSecurityExemptRoute(routeName)) {
      return child;
    }

    return ValueListenableBuilder<int>(
      valueListenable: LocalSecurityService.securityStateListenable,
      builder: (context, _, _) {
        if (LocalSecurityService.relockRequired) {
          return DeviceUnlockScreen(returnRoute: routeName);
        }
        return child;
      },
    );
  }
}

class _PermissionDeniedFallback extends StatefulWidget {
  const _PermissionDeniedFallback({required this.isLoggedIn});

  final bool isLoggedIn;

  @override
  State<_PermissionDeniedFallback> createState() =>
      _PermissionDeniedFallbackState();
}

class _PermissionDeniedFallbackState extends State<_PermissionDeniedFallback> {
  bool _scheduled = false;

  @override
  Widget build(BuildContext context) {
    if (!_scheduled) {
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        Navigator.of(context).pushNamedAndRemoveUntil(
          widget.isLoggedIn ? '/home' : '/login',
          (route) => false,
        );
      });
    }
    return const _SplashScreen();
  }
}

bool _isOfflineOnlyRoute(String? routeName) {
  return routeName == '/login-offline' ||
      routeName == '/offline-sync' ||
      routeName == '/scan-card-offline' ||
      routeName == '/scan-card-offline-camera';
}

bool _isOfflinePermittedRoute(String? routeName) {
  return _isOfflineOnlyRoute(routeName) || OfflineSessionService.isOfflineMode;
}

Future<bool> _canUseOfflineWorkspaceForUser(Map<String, dynamic>? user) async {
  if (user == null || user['id'] == null) {
    return false;
  }

  final permissions = AppPermissions.fromUser(user);
  return permissions.canOfflineCardScan &&
      await OfflineCardService().hasOfflineWorkspace(user['id'].toString());
}

Future<bool> _canUseOfflineCardScanForUser(Map<String, dynamic>? user) async {
  if (user == null || user['id'] == null) {
    return false;
  }
  final permissions = AppPermissions.fromUser(user);
  return permissions.canOfflineCardScan &&
      await OfflineCardService().hasOfflineWorkspace(user['id'].toString());
}

class _OfflineRouteGuard extends StatelessWidget {
  const _OfflineRouteGuard({required this.routeName, required this.child});

  final String routeName;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!_isOfflinePermittedRoute(routeName)) {
      return child;
    }

    return FutureBuilder<bool>(
      future: _isOfflineOnlyRoute(routeName)
          ? _canOpenOfflineOnlyRoute(routeName)
          : _canStayInOfflineMode(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const _SplashScreen();
        }
        if (snapshot.data == true) {
          return child;
        }

        OfflineSessionService.setOfflineMode(false);
        return const _OfflineAccessFallback();
      },
    );
  }

  Future<bool> _canStayInOfflineMode() async {
    final user = await AuthService().currentUser();
    return _canUseOfflineWorkspaceForUser(user);
  }

  Future<bool> _canOpenOfflineOnlyRoute(String routeName) async {
    final user = await AuthService().currentUser();
    switch (routeName) {
      case '/scan-card-offline':
      case '/scan-card-offline-camera':
        return _canUseOfflineCardScanForUser(user);
      case '/offline-sync':
        return user != null &&
            user['id'] != null &&
            AppPermissions.fromUser(user).canOfflineCardScan;
      case '/login-offline':
        return _canUseOfflineWorkspaceForUser(user);
      default:
        return _canUseOfflineWorkspaceForUser(user);
    }
  }
}

class _OfflineAccessFallback extends StatefulWidget {
  const _OfflineAccessFallback();

  @override
  State<_OfflineAccessFallback> createState() => _OfflineAccessFallbackState();
}

class _OfflineAccessFallbackState extends State<_OfflineAccessFallback> {
  bool _scheduled = false;

  @override
  Widget build(BuildContext context) {
    if (!_scheduled) {
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) {
          return;
        }
        final navigator = Navigator.of(context);
        final user = await AuthService().currentUser();
        if (!mounted) {
          return;
        }
        navigator.pushNamedAndRemoveUntil(
          user != null ? '/home' : '/login',
          (route) => false,
        );
      });
    }
    return const _SplashScreen();
  }
}

Future<void> main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        final fullDetails = details.toString();
        assert(() {
          debugPrint('FlutterError: ${details.exceptionAsString()}');
          debugPrintStack(stackTrace: details.stack);
          return true;
        }());
        unawaited(
          AppAlertService.reportUnhandledCrash(
            title: 'Flutter framework error',
            message: details.exceptionAsString(),
            details: fullDetails,
            stackTrace: details.stack?.toString(),
            route: appRouteObserver.currentRouteName,
            extraContext: {
              'errorKind': 'flutter_framework_error',
              'exceptionClass': details.exception.runtimeType.toString(),
              if (details.library != null) 'library': details.library,
              if (details.context != null)
                'flutterContext': details.context!.toDescription(),
            },
          ),
        );
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        assert(() {
          debugPrint('PlatformDispatcher error: $error');
          debugPrintStack(stackTrace: stack);
          return true;
        }());
        unawaited(
          AppAlertService.reportUnhandledCrash(
            title: 'Unhandled platform error',
            message: error.toString(),
            stackTrace: stack.toString(),
            route: appRouteObserver.currentRouteName,
            extraContext: {
              'errorKind': 'platform_dispatcher_error',
              'exceptionClass': error.runtimeType.toString(),
            },
          ),
        );
        return true;
      };
      runApp(const MyApp());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_warmUpAppServices());
      });
    },
    (error, stack) {
      unawaited(
        AppAlertService.reportUnhandledCrash(
          title: 'Unhandled zoned error',
          message: error.toString(),
          stackTrace: stack.toString(),
          route: appRouteObserver.currentRouteName,
          extraContext: {
            'errorKind': 'zoned_error',
            'exceptionClass': error.runtimeType.toString(),
          },
        ),
      );
    },
  );
}

Future<void> _warmUpAppServices() async {
  await Future.wait<void>([
    _runStartupTask(AppLocaleService.instance.init, label: 'locale'),
    _runStartupTask(
      ConnectivityService.instance.startMonitoring,
      label: 'connectivity',
    ),
    _runStartupTask(
      LocalNotificationService.initialize,
      label: 'local_notifications',
    ),
    _runStartupTask(
      LocalSecurityService.getOrCreateDeviceId,
      label: 'device_id',
    ),
    _runStartupTask(
      ReferralAttributionService.initialize,
      label: 'referral_attribution',
    ),
  ]);
}

Future<void> _runStartupTask(
  Future<dynamic> Function() task, {
  required String label,
  Duration timeout = const Duration(seconds: 5),
}) async {
  try {
    await task().timeout(timeout);
  } catch (_) {
    // Startup should stay responsive even if an optional task is slow/fails.
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppLocaleService.instance,
      builder: (context, _) {
        final locale = AppLocaleService.instance.locale ?? const Locale('ar');
        final localizer = AppLocalizer(locale);

        return MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: AppAlertService.navigatorKey,
          title: localizer.tr('main.001'),
          locale: locale,
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          navigatorObservers: [appRouteObserver],
          theme: AppTheme.lightTheme,
          builder: (context, child) {
            SystemChrome.setSystemUIOverlayStyle(
              const SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: Brightness.dark,
                statusBarBrightness: Brightness.light,
                systemNavigationBarColor: Colors.white,
                systemNavigationBarIconBrightness: Brightness.dark,
              ),
            );
            return Directionality(
              textDirection: localizer.textDirection,
              child: Stack(
                children: [
                  MediaQuery.withClampedTextScaling(
                    minScaleFactor: 0.8,
                    maxScaleFactor: 1.4,
                    child: _RootBackNavigationGuard(
                      child: _AdaptiveWebSidebarShell(
                        child: child ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
                  const _GlobalConnectivityBanner(),
                ],
              ),
            );
          },
          onGenerateRoute: _buildNamedRoute,
          onGenerateInitialRoutes: (initialRouteName) {
            return [_buildNamedRoute(RouteSettings(name: initialRouteName))];
          },
        );
      },
    );
  }
}

class _RootBackNavigationGuard extends StatefulWidget {
  const _RootBackNavigationGuard({required this.child});

  final Widget child;

  @override
  State<_RootBackNavigationGuard> createState() =>
      _RootBackNavigationGuardState();
}

class _RootBackNavigationGuardState extends State<_RootBackNavigationGuard> {
  bool _handlingBack = false;

  Future<bool> _confirmExit() async {
    final l = context.loc;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.tr('main.019')),
        content: Text(l.tr('main.020')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.tr('main.021')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.tr('main.022')),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _handleBack() async {
    if (_handlingBack) {
      return;
    }
    _handlingBack = true;
    try {
      final navigator = AppAlertService.navigatorKey.currentState;
      if (navigator != null && navigator.canPop()) {
        navigator.pop();
        return;
      }

      final shouldExit = await _confirmExit();
      if (shouldExit) {
        await SystemNavigator.pop();
      }
    } finally {
      _handlingBack = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }
        unawaited(_handleBack());
      },
      child: widget.child,
    );
  }
}

class _AdaptiveWebSidebarShell extends StatelessWidget {
  const _AdaptiveWebSidebarShell({required this.child});

  static const double _desktopBreakpoint = AppSidebar.desktopBreakpoint;
  static const double _sidebarWidth = 340;
  static const Set<String> _publicRoutes = {
    '/login',
    '/login-offline',
    '/register',
    '/forgot-password',
    '/unlock',
  };

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) {
      return child;
    }

    final cachedHasSession =
        (AuthService.peekToken()?.isNotEmpty ?? false) ||
        AuthService.peekCurrentUser() != null;
    if (cachedHasSession) {
      return _buildWithRouteState(context, hasSession: true);
    }

    return FutureBuilder<bool>(
      future: AuthService().isLoggedIn(),
      builder: (context, snapshot) {
        return _buildWithRouteState(context, hasSession: snapshot.data == true);
      },
    );
  }

  Widget _buildWithRouteState(
    BuildContext context, {
    required bool hasSession,
  }) {
    return ValueListenableBuilder<int>(
      valueListenable: LocalSecurityService.securityStateListenable,
      builder: (context, _, _) {
        return AnimatedBuilder(
          animation: appRouteObserver,
          builder: (context, _) {
            final routeName = appRouteObserver.currentRouteName;
            final showSidebar =
                hasSession &&
                !LocalSecurityService.relockRequired &&
                !_publicRoutes.contains(routeName) &&
                MediaQuery.sizeOf(context).width >= _desktopBreakpoint;

            if (!showSidebar) {
              return child;
            }

            final activeRouteName = routeName == '/app-shell'
                ? '/home'
                : routeName;
            // Navigator/Overlay can retain a full-viewport hit-test region
            // even when visually constrained inside a Row. Put the desktop
            // sidebar above it in a Stack, and reserve its width for content,
            // so pointer events always reach the navigation items.
            return ColoredBox(
              color: AppTheme.background,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.only(
                        right: _sidebarWidth + 1,
                      ),
                      child: child,
                    ),
                  ),
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    child: SizedBox(
                      width: _sidebarWidth,
                      child: AppSidebar(
                        embedded: true,
                        currentRouteName: activeRouteName,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _AppLifecycleShell extends StatefulWidget {
  const _AppLifecycleShell();
  @override
  State<_AppLifecycleShell> createState() => _AppLifecycleShellState();
}

class _AppLifecycleShellState extends State<_AppLifecycleShell>
    with WidgetsBindingObserver {
  int _appLifecycleVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(LocalSecurityService.markAppBackgrounded());
        break;
      case AppLifecycleState.resumed:
        unawaited(_handleAppResumed());
        break;
    }
  }

  Future<void> _handleAppResumed() async {
    final shouldRebuild = await LocalSecurityService.handleAppResumed();
    unawaited(ConnectivityService.instance.checkNow());
    if (!LocalSecurityService.relockRequired) {
      unawaited(_refreshCurrentUserAfterResume());
    }
    if (!mounted) {
      return;
    }
    if (shouldRebuild) {
      setState(() => _appLifecycleVersion++);
    }
  }

  Future<void> _refreshCurrentUserAfterResume() async {
    try {
      await AuthService().tryRefreshCurrentUser();
    } catch (_) {
      // Route guards and screens handle expired sessions when they next load.
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppEntryPoint(key: ValueKey(_appLifecycleVersion));
  }
}

class _GlobalConnectivityBanner extends StatefulWidget {
  const _GlobalConnectivityBanner();

  @override
  State<_GlobalConnectivityBanner> createState() =>
      _GlobalConnectivityBannerState();
}

class _GlobalConnectivityBannerState extends State<_GlobalConnectivityBanner> {
  bool? _lastOnline;
  bool _visible = false;
  bool _showRecoveredState = false;
  Timer? _hideTimer;
  Timer? _offlineShowTimer;
  bool _offlineBannerWasShown = false;

  @override
  void initState() {
    super.initState();
    _lastOnline = ConnectivityService.instance.isOnline.value;
    _visible = _lastOnline == false;
    ConnectivityService.instance.isOnline.addListener(_handleConnectivity);
  }

  @override
  void dispose() {
    ConnectivityService.instance.isOnline.removeListener(_handleConnectivity);
    _hideTimer?.cancel();
    _offlineShowTimer?.cancel();
    super.dispose();
  }

  void _handleConnectivity() {
    final isOnline = ConnectivityService.instance.isOnline.value;
    final previous = _lastOnline;
    _lastOnline = isOnline;

    if (previous == isOnline) {
      return;
    }

    _hideTimer?.cancel();
    _offlineShowTimer?.cancel();
    if (!mounted) {
      return;
    }

    if (!isOnline) {
      _offlineShowTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted || ConnectivityService.instance.isOnline.value) {
          return;
        }
        setState(() {
          _visible = true;
          _showRecoveredState = false;
          _offlineBannerWasShown = true;
        });
      });
      return;
    }

    if (!_visible && !_offlineBannerWasShown) {
      return;
    }

    setState(() {
      _visible = true;
      _showRecoveredState = true;
    });
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) {
        return;
      }
      setState(() => _visible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.loc;
    final showBanner = _visible;
    final isRecovered = _showRecoveredState && _lastOnline == true;
    final color = isRecovered ? AppTheme.success : AppTheme.error;
    final icon = isRecovered ? Icons.wifi_rounded : Icons.wifi_off_rounded;
    final title = isRecovered ? l.tr('main.004') : l.tr('main.002');
    final message = isRecovered ? l.tr('main.005') : l.tr('main.003');

    return IgnorePointer(
      ignoring: true,
      child: SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 240),
            offset: showBanner ? Offset.zero : const Offset(0, 1.2),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: showBanner ? 1 : 0,
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: color.withValues(alpha: 0.18)),
                  boxShadow: AppTheme.softShadow,
                ),
                child: Row(
                  children: [
                    Icon(icon, color: color, size: 19),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '$title - $message',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.caption.copyWith(
                          color: AppTheme.textPrimary,
                          height: 1.35,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _LaunchState {
  onboarding,
  login,
  unlock,
  home,
  securitySetup,
  homeOffline,
  updateRequired,
}

class _LaunchDecision {
  const _LaunchDecision({required this.state, this.updateRequirement});

  final _LaunchState state;
  final AppUpdateRequirement? updateRequirement;
}

class AppEntryPoint extends StatefulWidget {
  const AppEntryPoint({super.key});
  @override
  State<AppEntryPoint> createState() => _AppEntryPointState();
}

class _AppEntryPointState extends State<AppEntryPoint> {
  static const String _onboardingSeenKey = 'onboarding_seen_v1';
  static const Duration _launchDecisionTimeout = Duration(seconds: 3);
  late Future<_LaunchDecision> _launchStateFuture;
  @override
  void initState() {
    super.initState();
    _launchStateFuture = _safeResolveLaunchState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _refreshLaunchState() {
    if (!mounted) {
      return;
    }
    setState(() {
      _launchStateFuture = _safeResolveLaunchState();
    });
  }

  Future<_LaunchDecision> _safeResolveLaunchState() {
    return _resolveLaunchState().timeout(
      _launchDecisionTimeout,
      onTimeout: () => _resolveCachedLaunchState().timeout(
        const Duration(seconds: 2),
        onTimeout: () => const _LaunchDecision(state: _LaunchState.login),
      ),
    );
  }

  Future<_LaunchDecision> _resolveLaunchState() async {
    final stopwatch = Stopwatch()..start();
    await LocalSecurityService.syncRelockStateForLaunch();
    final updateRequirementFuture = AppVersionService.fetchRequiredUpdate()
        .timeout(const Duration(milliseconds: 1200), onTimeout: () => null);
    final prefsFuture = SharedPreferences.getInstance();
    final authService = AuthService();
    final cachedUserFuture = authService.currentUser();
    final isLoggedInFuture = authService.isLoggedIn();

    final updateRequirement = await updateRequirementFuture;
    if (updateRequirement != null && updateRequirement.isForced) {
      _debugLaunchDecision('updateRequired', stopwatch.elapsed);
      return _LaunchDecision(
        state: _LaunchState.updateRequired,
        updateRequirement: updateRequirement,
      );
    }

    final prefs = await prefsFuture;
    final hasSeenOnboarding = prefs.getBool(_onboardingSeenKey) ?? false;
    if (!hasSeenOnboarding) {
      _debugLaunchDecision('onboarding', stopwatch.elapsed);
      return const _LaunchDecision(state: _LaunchState.onboarding);
    }

    var cachedUser = await cachedUserFuture;
    final isLoggedIn = await isLoggedInFuture;
    final connectivityProbe = await ConnectivityService.instance
        .checkNow()
        .timeout(
          const Duration(milliseconds: 900),
          onTimeout: () => ConnectivityService.instance.isOnline.value,
        );
    final isOnline =
        connectivityProbe || ConnectivityService.instance.isOnline.value;
    if (!isLoggedIn) {
      unawaited(RealtimeNotificationService.stop());
      _debugLaunchDecision('login', stopwatch.elapsed);
      return const _LaunchDecision(state: _LaunchState.login);
    }
    if (cachedUser == null) {
      unawaited(RealtimeNotificationService.stop());
      try {
        await authService.tryRefreshCurrentUser().timeout(
          const Duration(seconds: 2),
          onTimeout: () => false,
        );
        cachedUser = await authService.currentUser().timeout(
          const Duration(seconds: 1),
          onTimeout: () => null,
        );
      } catch (_) {
        cachedUser = await authService.currentUser().timeout(
          const Duration(seconds: 1),
          onTimeout: () => null,
        );
      }
      if (cachedUser == null) {
        _debugLaunchDecision(
          'home(sessionRecoveryNoSnapshot)',
          stopwatch.elapsed,
        );
        return const _LaunchDecision(state: _LaunchState.home);
      }
    }
    final hasLocalSecurity =
        await LocalSecurityService.hasConfiguredLocalSecurity().timeout(
          const Duration(seconds: 1),
          onTimeout: () => false,
        );
    final skipNextUnlock = await LocalSecurityService.consumeSkipNextUnlock();
    if (skipNextUnlock) {
      if (!isOnline && await _canOpenOfflineWorkspace(cachedUser)) {
        unawaited(RealtimeNotificationService.stop());
        _debugLaunchDecision('homeOffline(skipNextUnlock)', stopwatch.elapsed);
        return const _LaunchDecision(state: _LaunchState.homeOffline);
      }
      unawaited(RealtimeNotificationService.start());
      _debugLaunchDecision('home(skipNextUnlock)', stopwatch.elapsed);
      return const _LaunchDecision(state: _LaunchState.home);
    }
    final relockRequired = LocalSecurityService.relockRequired;
    final canUseTrustedUnlock = await LocalSecurityService.canUseTrustedUnlock()
        .timeout(const Duration(seconds: 1), onTimeout: () => false);
    if (relockRequired && hasLocalSecurity) {
      unawaited(RealtimeNotificationService.stop());
      if (canUseTrustedUnlock) {
        _debugLaunchDecision('unlock', stopwatch.elapsed);
        return const _LaunchDecision(state: _LaunchState.unlock);
      }
      _debugLaunchDecision('home(relockUnavailable)', stopwatch.elapsed);
      return const _LaunchDecision(state: _LaunchState.home);
    }
    if (!isOnline) {
      unawaited(RealtimeNotificationService.stop());
      if (await _canOpenOfflineWorkspace(cachedUser)) {
        _debugLaunchDecision('homeOffline(noConnection)', stopwatch.elapsed);
        return const _LaunchDecision(state: _LaunchState.homeOffline);
      }
      _debugLaunchDecision('home(noConnection)', stopwatch.elapsed);
      return const _LaunchDecision(state: _LaunchState.home);
    }
    try {
      final refreshed = await authService.tryRefreshCurrentUser();
      if (!refreshed) {
        final fallbackUser = await authService.currentUser();
        if (fallbackUser != null) {
          unawaited(RealtimeNotificationService.start());
          _debugLaunchDecision(
            'home(refreshNetworkUnavailable)',
            stopwatch.elapsed,
          );
          return const _LaunchDecision(state: _LaunchState.home);
        }
      }
    } catch (error) {
      unawaited(RealtimeNotificationService.stop());
      if ((error is AuthRequestException && error.deviceSessionOtpRequired) ||
          ErrorMessageService.requiresFreshLogin(
            ErrorMessageService.sanitize(error),
          )) {
        final fallbackUser = await authService.currentUser();
        if (fallbackUser != null) {
          if (hasLocalSecurity && canUseTrustedUnlock) {
            _debugLaunchDecision(
              'unlock(refreshAuthRequired)',
              stopwatch.elapsed,
            );
            return const _LaunchDecision(state: _LaunchState.unlock);
          }
          unawaited(RealtimeNotificationService.stop());
          _debugLaunchDecision(
            'login(refreshAuthRequiredNoLocalUnlock)',
            stopwatch.elapsed,
          );
          return const _LaunchDecision(state: _LaunchState.login);
        }
        _debugLaunchDecision(
          'login(noCachedUserExpiredToken)',
          stopwatch.elapsed,
        );
        return const _LaunchDecision(state: _LaunchState.login);
      }
      final fallbackUser = await authService.currentUser();
      if (fallbackUser != null) {
        unawaited(RealtimeNotificationService.start());
        _debugLaunchDecision('home(refreshUnavailable)', stopwatch.elapsed);
        return const _LaunchDecision(state: _LaunchState.home);
      }
      _debugLaunchDecision('login(noCachedUser)', stopwatch.elapsed);
      return const _LaunchDecision(state: _LaunchState.login);
    }
    unawaited(RealtimeNotificationService.start());
    _debugLaunchDecision('home(freshUser)', stopwatch.elapsed);
    return const _LaunchDecision(state: _LaunchState.home);
  }

  Future<_LaunchDecision> _resolveCachedLaunchState() async {
    await LocalSecurityService.syncRelockStateForLaunch();
    final prefs = await SharedPreferences.getInstance();
    final hasSeenOnboarding = prefs.getBool(_onboardingSeenKey) ?? false;
    if (!hasSeenOnboarding) {
      return const _LaunchDecision(state: _LaunchState.onboarding);
    }

    final authService = AuthService();
    final cachedUser = await authService.currentUser();
    final isLoggedIn = await authService.isLoggedIn();

    if (!isLoggedIn) {
      unawaited(RealtimeNotificationService.stop());
      return const _LaunchDecision(state: _LaunchState.login);
    }
    if (cachedUser == null) {
      unawaited(RealtimeNotificationService.stop());
      return const _LaunchDecision(state: _LaunchState.home);
    }
    final hasLocalSecurity =
        await LocalSecurityService.hasConfiguredLocalSecurity().timeout(
          const Duration(seconds: 1),
          onTimeout: () => false,
        );
    final canUseTrustedUnlock = await LocalSecurityService.canUseTrustedUnlock()
        .timeout(const Duration(seconds: 1), onTimeout: () => false);
    if (hasLocalSecurity &&
        LocalSecurityService.relockRequired &&
        canUseTrustedUnlock) {
      return const _LaunchDecision(state: _LaunchState.unlock);
    }
    if (hasLocalSecurity && LocalSecurityService.relockRequired) {
      return const _LaunchDecision(state: _LaunchState.home);
    }

    if (!ConnectivityService.instance.isOnline.value) {
      unawaited(RealtimeNotificationService.stop());
      if (await _canOpenOfflineWorkspace(cachedUser)) {
        return const _LaunchDecision(state: _LaunchState.homeOffline);
      }
      return const _LaunchDecision(state: _LaunchState.home);
    }

    return const _LaunchDecision(state: _LaunchState.home);
  }

  Future<bool> _canOpenOfflineWorkspace(Map<String, dynamic>? user) async {
    return _canUseOfflineWorkspaceForUser(user);
  }

  Future<void> _finishOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingSeenKey, true);
    _refreshLaunchState();
  }

  void _debugLaunchDecision(String state, Duration elapsed) {
    assert(() {
      debugPrint('[startup] launch=$state ${elapsed.inMilliseconds}ms');
      return true;
    }());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_LaunchDecision>(
      future: _launchStateFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const _SplashScreen();
        }
        final decision = snapshot.data!;
        switch (decision.state) {
          case _LaunchState.onboarding:
            OfflineSessionService.setOfflineMode(false);
            return OnboardingScreen(onFinished: _finishOnboarding);
          case _LaunchState.unlock:
            OfflineSessionService.setOfflineMode(false);
            return const DeviceUnlockScreen();
          case _LaunchState.home:
            OfflineSessionService.setOfflineMode(false);
            return const HomeScreen();
          case _LaunchState.securitySetup:
            OfflineSessionService.setOfflineMode(false);
            return const SecuritySettingsScreen(showSetupHint: true);
          case _LaunchState.homeOffline:
            OfflineSessionService.setOfflineMode(true);
            return const HomeScreen();
          case _LaunchState.login:
            OfflineSessionService.setOfflineMode(false);
            return const LoginScreen();
          case _LaunchState.updateRequired:
            OfflineSessionService.setOfflineMode(false);
            return _ForcedUpdateScreen(
              requirement: decision.updateRequirement!,
              onRetry: _refreshLaunchState,
            );
        }
      },
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();
  @override
  Widget build(BuildContext context) {
    final l = context.loc;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.primaryGradient),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 132,
                height: 132,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.24),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.asset(
                    'assets/images/shwakel_app_icon.png',
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                l.tr('main.001'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l.tr('main.006'),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.92),
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 28),
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.6,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ForcedUpdateScreen extends StatelessWidget {
  const _ForcedUpdateScreen({required this.requirement, required this.onRetry});

  final AppUpdateRequirement requirement;
  final VoidCallback onRetry;

  Future<void> _openStore() async {
    if (!requirement.hasStoreUrl) {
      return;
    }

    await launchUrl(
      Uri.parse(requirement.storeUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.loc;

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: AppTheme.pageBackgroundGradient,
          ),
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const ShwakelLogo(size: 78, framed: true),
                        const SizedBox(height: 20),
                        Text(
                          requirement.isForced
                              ? l.tr('main.007')
                              : l.tr('main.008'),
                          style: AppTheme.h1,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          requirement.isForced
                              ? l.tr('main.009')
                              : l.tr('main.010'),
                          style: AppTheme.bodyAction.copyWith(height: 1.6),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        _versionRow(
                          l.tr('main.011'),
                          requirement.currentVersion,
                        ),
                        const SizedBox(height: 10),
                        _versionRow(
                          requirement.isForced
                              ? l.tr('main.012')
                              : l.tr('main.013'),
                          requirement.minSupportedVersion.isEmpty
                              ? '-'
                              : requirement.minSupportedVersion,
                        ),
                        const SizedBox(height: 10),
                        _versionRow(
                          l.tr('main.014'),
                          requirement.latestVersion,
                        ),
                        const SizedBox(height: 24),
                        ShwakelButton(
                          label: requirement.hasStoreUrl
                              ? l.tr('main.015')
                              : l.tr('main.016'),
                          icon: Icons.system_update_rounded,
                          onPressed: requirement.hasStoreUrl
                              ? _openStore
                              : null,
                        ),
                        const SizedBox(height: 12),
                        ShwakelButton(
                          label: requirement.isForced
                              ? l.tr('main.017')
                              : l.tr('main.018'),
                          isSecondary: true,
                          icon: Icons.refresh_rounded,
                          onPressed: onRetry,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _versionRow(String label, String value) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceVariant,
        borderRadius: AppTheme.radiusMd,
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Expanded(child: Text(label, style: AppTheme.bodyAction)),
          const SizedBox(width: 12),
          Text(
            value,
            style: AppTheme.bodyBold.copyWith(color: AppTheme.primary),
          ),
        ],
      ),
    );
  }
}
