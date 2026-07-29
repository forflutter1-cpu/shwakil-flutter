import 'dart:async';

import 'package:flutter/material.dart';

import '../services/index.dart';
import '../utils/app_theme.dart';

class AppNotificationAction extends StatefulWidget {
  const AppNotificationAction({super.key});

  @override
  State<AppNotificationAction> createState() => _AppNotificationActionState();
}

class _AppNotificationActionState extends State<AppNotificationAction> {
  final ApiService _apiService = ApiService();
  int _unreadNotifications = 0;
  StreamSubscription<Map<String, dynamic>>? _notificationSubscription;
  bool _isOpening = false;

  @override
  void initState() {
    super.initState();
    _loadNotificationSummary();
    _notificationSubscription = RealtimeNotificationService.notificationsStream
        .listen((_) {
          ApiService.invalidateNotificationSummaryCache();
          _loadNotificationSummary();
        });
  }

  @override
  void dispose() {
    _notificationSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadNotificationSummary() async {
    if (OfflineSessionService.isOfflineMode) {
      if (!mounted) {
        return;
      }
      setState(() => _unreadNotifications = 0);
      return;
    }

    try {
      final payload = await _apiService.getNotificationSummary();
      final summary = Map<String, dynamic>.from(
        payload['summary'] as Map? ?? const {},
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _unreadNotifications = (summary['unreadCount'] as num?)?.toInt() ?? 0;
      });
    } catch (_) {}
  }

  Future<void> _openNotifications() async {
    if (OfflineSessionService.isOfflineMode) {
      await AppAlertService.showInfo(
        context,
        title: context.loc.tr('widgets_app_top_actions.001'),
        message: context.loc.tr('widgets_app_top_actions.002'),
      );
      return;
    }
    if (!mounted || _isOpening) {
      return;
    }
    final currentRoute = ModalRoute.of(context)?.settings.name;
    if (currentRoute == '/notifications') {
      return;
    }
    setState(() => _isOpening = true);
    try {
      final navigator = AppAlertService.navigatorKey.currentState;
      if (navigator == null) {
        throw StateError('Root navigator is not ready.');
      }
      await navigator.pushNamed('/notifications');
      if (!mounted) {
        return;
      }
      ApiService.invalidateNotificationSummaryCache();
      _loadNotificationSummary();
    } catch (error) {
      if (!mounted) {
        return;
      }
      await AppAlertService.showError(
        context,
        title: context.loc.tr('screens_login_screen.002'),
        message: ErrorMessageService.sanitize(error),
      );
    } finally {
      if (mounted) {
        setState(() => _isOpening = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.loc;

    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 2),
      child: IconButton(
        tooltip: _unreadNotifications > 0
            ? l.tr(
                'widgets_app_top_actions.003',
                params: {'count': '$_unreadNotifications'},
              )
            : l.tr('widgets_app_top_actions.004'),
        onPressed: _isOpening ? null : _openNotifications,
        icon: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppTheme.primarySoft,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.notifications_active_rounded,
                color: AppTheme.primary,
                size: 20,
              ),
            ),
            if (_unreadNotifications > 0)
              Positioned(
                top: -6,
                left: -6,
                child: Container(
                  constraints: const BoxConstraints(
                    minWidth: 22,
                    minHeight: 22,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.error,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: Text(
                    _unreadNotifications > 99 ? '99+' : '$_unreadNotifications',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
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
}

class QuickLogoutAction extends StatelessWidget {
  const QuickLogoutAction({super.key});

  static Future<void> logout(BuildContext context) async {
    final authService = AuthService();
    await RealtimeNotificationService.stop();
    if (!context.mounted) {
      return;
    }

    final canUseTrustedUnlock =
        await LocalSecurityService.canUseTrustedUnlock();
    if (!context.mounted) {
      return;
    }

    if (!canUseTrustedUnlock) {
      await authService.logout();
      await LocalSecurityService.clearTrustedState();
      if (!context.mounted) {
        return;
      }
    }

    final navigator =
        AppAlertService.navigatorKey.currentState ?? Navigator.maybeOf(context);
    navigator?.pushNamedAndRemoveUntil(
      canUseTrustedUnlock ? '/unlock' : '/login',
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}
