import 'package:flutter/foundation.dart';

class OfflineSessionService {
  OfflineSessionService._();

  static final ValueNotifier<bool> _isOfflineMode = ValueNotifier<bool>(false);

  static ValueListenable<bool> get listenable => _isOfflineMode;

  static bool get isOfflineMode => _isOfflineMode.value;

  static void setOfflineMode(bool value) {
    if (_isOfflineMode.value == value) {
      return;
    }
    _isOfflineMode.value = value;
  }

  static const Set<String> _offlineAllowedRoutes = {
    '/home',
    '/prepaid-multipay-cards',
    '/prepaid-multipay-contactless-accept',
    '/scan-card-offline',
    '/scan-card-offline-camera',
    '/debt-book',
    '/store-management',
    '/inventory',
    '/maintenance-management',
    '/affiliate-center',
    '/login-offline',
    '/unlock',
  };

  static String resolveRoute(String? routeName) {
    final normalized = (routeName ?? '').trim();
    final requestedRoute = normalized.isEmpty ? '/app-shell' : normalized;

    if (!isOfflineMode) {
      return requestedRoute;
    }

    if (_offlineAllowedRoutes.contains(requestedRoute)) {
      return requestedRoute;
    }

    switch (requestedRoute) {
      case '/scan-card':
        return '/scan-card-offline';
      case '/scan-card-camera':
        return '/scan-card-offline-camera';
      case '/login':
      case '/register':
      case '/forgot-password':
        return '/login-offline';
      default:
        return '/home';
    }
  }

  static bool canOpenRoute(String routeName) {
    if (!isOfflineMode) {
      return true;
    }
    return resolveRoute(routeName) == routeName;
  }
}
