import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../services/index.dart';
import '../utils/app_permissions.dart';
import '../utils/app_theme.dart';
import '../utils/user_display_name.dart';
import 'app_top_actions.dart';
import 'shwakel_logo.dart';

class AppSidebar extends StatefulWidget {
  const AppSidebar({super.key, this.embedded = false, this.currentRouteName});

  final bool embedded;
  final String? currentRouteName;

  /// The desktop web shell already renders an embedded navigation rail.
  /// Returning null here prevents every page Scaffold from registering a
  /// second Drawer (and therefore a second sidebar/hamburger) at wide widths.
  static Widget? drawerFor(BuildContext context, {String? currentRouteName}) {
    final isDesktopWeb =
        kIsWeb && MediaQuery.sizeOf(context).width >= desktopBreakpoint;
    return isDesktopWeb ? null : AppSidebar(currentRouteName: currentRouteName);
  }

  static const double desktopBreakpoint = 1100;

  @override
  State<AppSidebar> createState() => _AppSidebarState();
}

/// Keeps navigation and a clear status visible while a screen waits for its
/// first API response. A bare spinner made slow requests look like a blank
/// page and left mobile users without a way to move elsewhere.
class ShwakelPageLoadingScaffold extends StatelessWidget {
  const ShwakelPageLoadingScaffold({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.loc;
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        centerTitle: true,
        title: Text(l.text('تحميل الصفحة', 'Loading page')),
        actions: const [AppNotificationAction(), QuickLogoutAction()],
      ),
      drawer: AppSidebar.drawerFor(context),
      body: const ShwakelPageLoadingContent(),
    );
  }
}

/// Clear, compact loading feedback for a screen that already owns its app bar
/// and navigation. Keeping it inside the page body preserves the page actions
/// and navigation while its first request is pending.
class ShwakelPageLoadingContent extends StatelessWidget {
  const ShwakelPageLoadingContent({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.loc;
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: AppTheme.border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 34,
                    height: 34,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    l.text('جارٍ تحميل بيانات الشاشة', 'Loading screen data'),
                    textAlign: TextAlign.center,
                    style: AppTheme.bodyAction.copyWith(
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l.text(
                      'سيظهر المحتوى هنا فور اكتمال التحميل.',
                      'The content will appear as soon as loading finishes.',
                    ),
                    textAlign: TextAlign.center,
                    style: AppTheme.caption.copyWith(
                      color: AppTheme.textSecondary,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AppSidebarState extends State<AppSidebar> {
  static DateTime? _lastPermissionRefreshAt;
  final AuthService _authService = AuthService();
  Map<String, dynamic>? _user = AuthService.peekCurrentUser();

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    // Permission changes made by the owner/admin must reach an already-open
    // client too. Refresh at most once per minute to avoid a request for every
    // drawer created while navigating on mobile.
    final now = DateTime.now();
    final lastRefresh = _lastPermissionRefreshAt;
    if (lastRefresh == null || now.difference(lastRefresh).inSeconds >= 60) {
      _lastPermissionRefreshAt = now;
      try {
        await _authService.tryRefreshCurrentUser();
      } catch (_) {
        // Keep the last cached permission snapshot when offline or unavailable.
      }
    }
    final user = await _authService.currentUser();
    if (!mounted) {
      return;
    }
    if (_user?['id']?.toString() == user?['id']?.toString() &&
        _user?['role']?.toString() == user?['role']?.toString() &&
        _user?['isSubUser']?.toString() == user?['isSubUser']?.toString() &&
        _user?['parentUserId']?.toString() ==
            user?['parentUserId']?.toString() &&
        jsonEncode(_user?['permissions']) == jsonEncode(user?['permissions']) &&
        _user?['balance']?.toString() == user?['balance']?.toString() &&
        _user?['transferVerificationStatus']?.toString() ==
            user?['transferVerificationStatus']?.toString()) {
      return;
    }
    setState(() => _user = user);
  }

  Future<void> _showOfflineBlockedMessage() {
    return AppAlertService.showInfo(
      context,
      title: context.loc.tr('widgets_app_sidebar.035'),
      message: context.loc.tr('widgets_app_sidebar.036'),
    );
  }

  Future<void> _openRoute(String routeName, {Object? arguments}) async {
    final normalizedRoute =
        OfflineSessionService.isOfflineMode && routeName == '/scan-card'
        ? '/scan-card-offline'
        : routeName;
    if (!OfflineSessionService.canOpenRoute(normalizedRoute)) {
      await _showOfflineBlockedMessage();
      return;
    }
    if (!mounted) {
      return;
    }
    // The desktop sidebar is injected by MaterialApp.builder and therefore is
    // a sibling of the Navigator, not a descendant of it.  Resolve navigation
    // through the app-level key so desktop menu taps remain functional.
    final navigator = AppAlertService.navigatorKey.currentState;
    if (navigator == null) {
      return;
    }
    final currentRoute =
        widget.currentRouteName ?? ModalRoute.of(context)?.settings.name ?? '';
    if (!widget.embedded) {
      navigator.pop();
    }
    if (currentRoute == normalizedRoute ||
        (currentRoute == '/app-shell' && normalizedRoute == '/home')) {
      return;
    }
    navigator.pushNamed(normalizedRoute, arguments: arguments);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.loc;
    final username =
        _user?['username']?.toString() ?? l.tr('widgets_app_sidebar.001');
    final displayName = UserDisplayName.fromMap(_user, fallback: username);
    final verificationStatus =
        _user?['transferVerificationStatus']?.toString() ?? 'unverified';
    final permissions = AppPermissions.fromUser(_user);
    // الحساب الرئيسي هو مساحة التاجر. أدوات البطاقات والمتاجر العامة لا تظهر
    // في قائمته، بينما تبقى خاضعة للصلاحيات عند الحسابات التابعة.
    final isPrimaryTrader = permissions.isPrimaryTrader;

    final canViewContact = permissions.canViewContact;
    final canViewNotifications =
        permissions.canViewTransactions || permissions.canViewBalance;
    final canViewBalance = permissions.canViewBalance;
    final canViewTransactions = permissions.canViewTransactions;
    final canIssueCards = permissions.canIssueCards;
    final canOpenCardTools = permissions.canOpenCardTools;
    final canTransfer = permissions.canTransfer;
    final canViewInventory = permissions.canViewInventory;
    final canRequestCardPrinting = permissions.canRequestCardPrinting;
    final canOpenPrepaidMultipayCards = permissions.canOpenPrepaidMultipayCards;
    final canOpenExternalCardStore = permissions.canOpenExternalCardStore;
    final canViewPublicStores = permissions.canViewPublicStores;
    final canWithdraw = permissions.canWithdraw;
    final canManageDebtBook = permissions.canManageDebtBook;
    final canAccessStoreManagement = permissions.canAccessStoreManagement;
    final canViewAffiliateCenter = permissions.canViewAffiliateCenter;
    final canViewUsagePolicy = permissions.canViewUsagePolicy;
    final canViewSubUsers = permissions.canViewSubUsers;
    final canViewAccountSettings = permissions.canViewAccountSettings;
    final canRequestVerification = permissions.canRequestVerification;
    final hasAdminWorkspaceAccess = permissions.hasAdminWorkspaceAccess;
    // صلاحيات دفتر الديون أو إدارة المحل لا تجعل التاجر مساحة إدارة كاملة.
    // مساحة الإدارة والتقارير الإدارية تظهر للإدارة/الأدوار الإدارية فقط.
    final showAdminWorkspace = !isPrimaryTrader && hasAdminWorkspaceAccess;
    final isOfflineMode = OfflineSessionService.isOfflineMode;
    const headerGradient = LinearGradient(
      colors: [AppTheme.secondary, AppTheme.primary],
      begin: Alignment.topRight,
      end: Alignment.bottomLeft,
    );
    final sidebarContent = SafeArea(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppTheme.webSafeGradientFallback(
                headerGradient,
                fallback: AppTheme.secondary,
              ),
              gradient: AppTheme.webSafeGradient(headerGradient),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const ShwakelLogo(size: 48, framed: true),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTheme.h2.copyWith(
                              color: Colors.white,
                              fontSize: 20,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '@$username',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTheme.bodyText.copyWith(
                              color: AppTheme.textMutedOnDark,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _verificationBadge(verificationStatus),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              key: const PageStorageKey<String>('app-sidebar-menu'),
              cacheExtent: 1200,
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
              children: [
                _buildMenuSection(
                  label: isOfflineMode
                      ? l.tr('widgets_app_sidebar.037')
                      : l.tr('widgets_app_sidebar.002'),
                  children: [
                    _buildItem(
                      context,
                      icon: Icons.home_rounded,
                      title: l.tr('widgets_app_sidebar.003'),
                      routeName: '/home',
                    ),
                    if (!isOfflineMode && canViewNotifications)
                      _buildItem(
                        context,
                        icon: Icons.notifications_active_rounded,
                        title: l.tr('widgets_app_sidebar.044'),
                        routeName: '/notifications',
                      ),
                    if (!isOfflineMode && permissions.canViewExternalTransfers)
                      _buildItem(
                        context,
                        icon: Icons.account_balance_wallet_rounded,
                        title: l.text(
                          'متابعة التحويلات الخارجية',
                          'External transfer follow-up',
                        ),
                        routeName: '/external-transfers',
                      ),
                    if (!isOfflineMode && permissions.isPrimaryTrader)
                      _buildItem(
                        context,
                        icon: Icons.price_check_rounded,
                        title: 'تصفية الحسابات',
                        routeName: '/external-transfer-accounting',
                      ),
                  ],
                ),
                if (!isOfflineMode) ...[
                  _buildMenuSection(
                    label: l.tr('widgets_app_sidebar.046'),
                    children: [
                      if (canViewBalance)
                        _buildItem(
                          context,
                          icon: Icons.account_balance_wallet_rounded,
                          title: l.tr('widgets_app_sidebar.004'),
                          routeName: '/balance',
                        ),
                      if (canTransfer)
                        _buildItem(
                          context,
                          icon: Icons.send_to_mobile_rounded,
                          title: l.tr('widgets_app_sidebar.011'),
                          routeName: '/quick-transfer',
                        ),
                      if (canTransfer)
                        _buildItem(
                          context,
                          icon: Icons.storefront_rounded,
                          title: l.text('استلام التاجر', 'Merchant receive'),
                          routeName: '/merchant-receive',
                        ),
                      if (canWithdraw)
                        _buildItem(
                          context,
                          icon: Icons.payments_rounded,
                          title: l.tr('widgets_app_sidebar.031'),
                          routeName: '/withdrawal-requests',
                        ),
                      if (canViewTransactions)
                        _buildItem(
                          context,
                          icon: Icons.receipt_long_rounded,
                          title: l.tr('widgets_app_sidebar.005'),
                          routeName: '/transactions',
                        ),
                    ],
                  ),
                  _buildMenuSection(
                    label: l.tr('widgets_app_sidebar.006'),
                    children: [
                      if (canIssueCards)
                        _buildItem(
                          context,
                          icon: Icons.add_card_rounded,
                          title: l.text(
                            'إنشاء بطاقة سريعة',
                            'Quick card issue',
                          ),
                          routeName: '/create-card-quick',
                        ),
                      if (canIssueCards)
                        _buildItem(
                          context,
                          icon: Icons.library_add_rounded,
                          title: l.tr('widgets_app_sidebar.047'),
                          routeName: '/create-card',
                        ),
                      if ((!isOfflineMode && canOpenCardTools) ||
                          (isOfflineMode && permissions.canOfflineCardScan))
                        _buildItem(
                          context,
                          icon: Icons.camera_alt_rounded,
                          title: l.text(
                            'فحص بطاقة بالكاميرا',
                            'Scan card with camera',
                          ),
                          routeName: isOfflineMode
                              ? '/scan-card-offline-camera'
                              : '/scan-card-camera',
                        ),
                      if (permissions.canManageSubscriptions)
                        _buildItem(
                          context,
                          icon: Icons.event_repeat_rounded,
                          title: l.text('إدارة الاشتراكات', 'Subscriptions'),
                          routeName: '/subscriptions',
                        ),
                      if (permissions.canOfflineCardScan)
                        _buildItem(
                          context,
                          icon: Icons.cloud_sync_rounded,
                          title: l.tr('widgets_app_sidebar.053'),
                          routeName: '/offline-sync',
                        ),
                      if (canViewInventory && canIssueCards)
                        _buildItem(
                          context,
                          icon: Icons.layers_rounded,
                          title: l.text('مخزون البطاقات', 'Card inventory'),
                          routeName: '/inventory',
                        ),
                      if (canRequestCardPrinting)
                        _buildItem(
                          context,
                          icon: Icons.print_rounded,
                          title: l.tr('widgets_app_sidebar.007'),
                          routeName: '/card-print-requests',
                        ),
                      if (canIssueCards ||
                          canRequestCardPrinting ||
                          canViewInventory)
                        _buildItem(
                          context,
                          icon: Icons.analytics_rounded,
                          title: l.text(
                            'تقارير استخدام البطاقات',
                            'Card usage reports',
                          ),
                          routeName: '/card-usage-report',
                        ),
                      if (canOpenPrepaidMultipayCards)
                        _buildItem(
                          context,
                          icon: Icons.contactless_rounded,
                          title: l.tr('widgets_app_sidebar.049'),
                          routeName: '/prepaid-multipay-cards',
                        ),
                      if (canOpenExternalCardStore)
                        _buildItem(
                          context,
                          icon: Icons.storefront_rounded,
                          title: l.text('متجر البطاقات', 'Card store'),
                          routeName: '/external-card-store',
                        ),
                      if (canViewPublicStores)
                        _buildItem(
                          context,
                          icon: Icons.store_mall_directory_rounded,
                          title: l.text('المتاجر', 'Stores'),
                          routeName: '/public-stores',
                        ),
                    ],
                  ),
                  _buildMenuSection(
                    label: l.tr('widgets_app_sidebar.009'),
                    children: [
                      if (canViewAccountSettings)
                        _buildItem(
                          context,
                          icon: Icons.person_rounded,
                          title: l.tr('widgets_app_sidebar.010'),
                          routeName: '/account-settings',
                        ),
                      if (verificationStatus != 'approved' &&
                          canRequestVerification)
                        _buildItem(
                          context,
                          icon: Icons.verified_user_rounded,
                          title: l.tr('widgets_app_sidebar.012'),
                          routeName: '/account-verification',
                        ),
                      if (canViewSubUsers)
                        _buildItem(
                          context,
                          icon: Icons.supervised_user_circle_rounded,
                          title: l.tr('widgets_app_sidebar.039'),
                          routeName: '/sub-users',
                        ),
                      if (permissions.canViewSecuritySettings)
                        _buildItem(
                          context,
                          icon: Icons.shield_rounded,
                          title: l.tr('widgets_app_sidebar.013'),
                          routeName: '/security-settings',
                        ),
                      if (isPrimaryTrader || canManageDebtBook)
                        _buildItem(
                          context,
                          icon: Icons.menu_book_rounded,
                          title: l.tr('widgets_app_sidebar.040'),
                          routeName: '/debt-book',
                        ),
                      if (isPrimaryTrader || canAccessStoreManagement)
                        _buildItem(
                          context,
                          icon: Icons.storefront_rounded,
                          title: l.text('إدارة المحل', 'Store management'),
                          routeName: '/store-management',
                        ),
                      if (isPrimaryTrader || canAccessStoreManagement)
                        _buildItem(
                          context,
                          icon: Icons.build_circle_rounded,
                          title: l.text(
                            'إدارة الصيانة',
                            'Maintenance management',
                          ),
                          routeName: '/maintenance-management',
                        ),
                      if (canViewAffiliateCenter)
                        _buildItem(
                          context,
                          icon: Icons.campaign_rounded,
                          title: l.tr('widgets_app_sidebar.041'),
                          routeName: '/affiliate-center',
                        ),
                    ],
                  ),
                  if (showAdminWorkspace) ...[
                    _buildMenuSection(
                      label: l.tr('widgets_app_sidebar.014'),
                      children: [
                        _buildItem(
                          context,
                          icon: Icons.dashboard_customize_rounded,
                          title: l.text(
                            'مركز الإدارة والتقارير',
                            'Admin center & reports',
                          ),
                          routeName: '/admin-dashboard',
                        ),
                        if (permissions.canViewAdminCardScanReports)
                          _buildItem(
                            context,
                            icon: Icons.query_stats_rounded,
                            title: l.text(
                              'تقارير العمليات',
                              'Operations reports',
                            ),
                            routeName: '/admin-card-scan-reports',
                          ),
                        if (permissions.canViewCustomers)
                          _buildItem(
                            context,
                            icon: Icons.groups_rounded,
                            title: l.tr('widgets_app_sidebar.030'),
                            routeName: '/admin-customers',
                          ),
                        if (permissions.canManageUsers ||
                            permissions.canManageMarketingAccounts)
                          _buildItem(
                            context,
                            icon: Icons.how_to_reg_rounded,
                            title: l.tr('widgets_app_sidebar.042'),
                            routeName: '/admin-pending-registrations',
                          ),
                        if (permissions.canManageUsers)
                          _buildItem(
                            context,
                            icon: Icons.verified_user_rounded,
                            title: l.tr('widgets_app_sidebar.050'),
                            routeName: '/admin-verification-requests',
                          ),
                        if (permissions.canReviewTopups ||
                            permissions.canFinanceTopup)
                          _buildItem(
                            context,
                            icon: Icons.account_balance_rounded,
                            title: l.tr('widgets_app_sidebar.017'),
                            routeName: '/topup-requests',
                          ),
                        if (permissions.canReviewWithdrawals)
                          _buildItem(
                            context,
                            icon: Icons.payments_rounded,
                            title: l.tr('widgets_app_sidebar.031'),
                            routeName: '/withdrawal-requests',
                          ),
                        if (permissions.canManageCardPrintRequests)
                          _buildItem(
                            context,
                            icon: Icons.print_rounded,
                            title: l.tr('widgets_app_sidebar.032'),
                            routeName: '/admin-card-print-requests',
                          ),
                        if (permissions.canManagePrepaidMultipayApprovals)
                          _buildItem(
                            context,
                            icon: Icons.credit_score_rounded,
                            title: l.tr('widgets_app_sidebar.045'),
                            routeName: '/admin-prepaid-multipay-approvals',
                          ),
                        if (permissions.canReviewDevices)
                          _buildItem(
                            context,
                            icon: Icons.devices_rounded,
                            title: l.tr('widgets_app_sidebar.016'),
                            routeName: '/admin-device-requests',
                          ),
                        if (permissions.canManageDebtBook)
                          _buildItem(
                            context,
                            icon: Icons.menu_book_rounded,
                            title: l.tr('widgets_app_sidebar.040'),
                            routeName: '/admin-debt-book',
                          ),
                        if (permissions.canAccessStoreManagement)
                          _buildItem(
                            context,
                            icon: Icons.store_rounded,
                            title: l.text('إدارة المحل', 'Store management'),
                            routeName: '/store-management',
                          ),
                        if (permissions.canManageLocations)
                          _buildItem(
                            context,
                            icon: Icons.store_mall_directory_rounded,
                            title: l.tr('widgets_app_sidebar.018'),
                            routeName: '/admin-locations',
                          ),
                        if (permissions.canManageAdminNotifications)
                          _buildItem(
                            context,
                            icon: Icons.notification_add_rounded,
                            title: l.tr('widgets_app_sidebar.043'),
                            routeName: '/admin-notifications',
                          ),
                        if (permissions.isAdminRole ||
                            permissions.isSupportRole ||
                            permissions.canManageUsers)
                          _buildItem(
                            context,
                            icon: Icons.support_agent_rounded,
                            title: l.text('تذاكر التواصل', 'Support tickets'),
                            routeName: '/admin-support-tickets',
                          ),
                        if (permissions.canManagePermissionTemplates)
                          _buildItem(
                            context,
                            icon: Icons.rule_rounded,
                            title: l.tr('widgets_app_sidebar.033'),
                            routeName: '/admin-permissions',
                          ),
                        if (permissions.canManageSystemSettings)
                          _buildItem(
                            context,
                            icon: Icons.tune_rounded,
                            title: l.tr('widgets_app_sidebar.019'),
                            routeName: '/admin-system-settings',
                          ),
                      ],
                    ),
                  ],
                  _buildMenuSection(
                    label: l.tr('widgets_app_sidebar.020'),
                    children: [
                      if (canViewUsagePolicy)
                        _buildItem(
                          context,
                          icon: Icons.policy_rounded,
                          title: l.tr('widgets_app_sidebar.021'),
                          routeName: '/usage-policy',
                        ),
                      if (canViewContact)
                        _buildItem(
                          context,
                          icon: Icons.support_agent_rounded,
                          title: l.tr('widgets_app_sidebar.022'),
                          routeName: '/contact-us',
                        ),
                      _buildItem(
                        context,
                        icon: Icons.forum_rounded,
                        title: l.text('تذاكر التواصل', 'Support tickets'),
                        routeName: '/support-tickets',
                      ),
                    ],
                  ),
                ],
                _buildMenuSection(
                  label: l.tr('widgets_app_sidebar.024'),
                  children: [
                    _buildLanguageItem(context),
                    _buildSecureLogoutItem(context),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );

    if (widget.embedded) {
      return Material(
        color: AppTheme.sidebarSurface,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppTheme.sidebarSurface,
            border: Border(
              left: BorderSide(color: AppTheme.border.withValues(alpha: 0.8)),
            ),
          ),
          child: sidebarContent,
        ),
      );
    }

    return Drawer(
      width: MediaQuery.of(context).size.width >= 480 ? 360 : null,
      backgroundColor: AppTheme.sidebarSurface,
      child: sidebarContent,
    );
  }

  Widget _verificationBadge(String status) {
    final l = context.loc;
    var label = l.tr('widgets_app_sidebar.027');
    var color = Colors.white24;
    if (status == 'approved') {
      label = l.text('الحساب موثق', 'Account verified');
      color = AppTheme.success.withValues(alpha: 0.28);
    } else if (status == 'pending') {
      label = l.text('توثيق الحساب قيد المراجعة', 'Verification under review');
      color = AppTheme.warning.withValues(alpha: 0.28);
    } else {
      label = l.text('الحساب غير موثق', 'Account not verified');
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: AppTheme.caption.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildMenuSection({
    required String label,
    required List<Widget> children,
  }) {
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionLabel(label),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: AppTheme.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.035),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(21),
              child: Column(children: _withItemSeparators(children)),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _withItemSeparators(List<Widget> children) {
    final separated = <Widget>[];
    for (var index = 0; index < children.length; index += 1) {
      if (index > 0) {
        separated.add(const Divider(height: 1, indent: 58, endIndent: 12));
      }
      separated.add(children[index]);
    }
    return separated;
  }

  Widget _buildLanguageItem(BuildContext context) {
    final l = context.loc;
    return ListTile(
      minTileHeight: 50,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      leading: const Icon(
        Icons.language_rounded,
        color: AppTheme.textSecondary,
      ),
      title: Text(
        l.tr('widgets_app_sidebar.025'),
        style: AppTheme.bodyText.copyWith(fontWeight: FontWeight.w600),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(
        Icons.translate_rounded,
        size: 20,
        color: AppTheme.textTertiary,
      ),
      onTap: () async {
        await AppLocaleService.instance.toggleLocale();
        if (context.mounted && !widget.embedded) {
          AppAlertService.navigatorKey.currentState?.pop();
        }
      },
    );
  }

  Widget _buildItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String routeName,
    Object? arguments,
  }) {
    final currentRoute =
        widget.currentRouteName ?? ModalRoute.of(context)?.settings.name;
    final normalizedRoute =
        OfflineSessionService.isOfflineMode && routeName == '/scan-card'
        ? '/scan-card-offline'
        : routeName;
    final isSelected =
        currentRoute == routeName || currentRoute == normalizedRoute;
    final isArabic = context.loc.isArabic;
    final isBlockedOffline = !OfflineSessionService.canOpenRoute(
      normalizedRoute,
    );

    return ListTile(
      minTileHeight: 50,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      leading: Icon(
        icon,
        color: isBlockedOffline
            ? AppTheme.textTertiary
            : (isSelected ? AppTheme.primary : AppTheme.textSecondary),
      ),
      title: Text(
        title,
        style: AppTheme.bodyText.copyWith(
          color: isBlockedOffline
              ? AppTheme.textTertiary
              : (isSelected ? AppTheme.primary : AppTheme.textPrimary),
          fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: isBlockedOffline
              ? AppTheme.surfaceMuted.withValues(alpha: 0.7)
              : (isSelected
                    ? AppTheme.primary.withValues(alpha: 0.14)
                    : AppTheme.surfaceMuted),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          isArabic
              ? Icons.arrow_forward_ios_rounded
              : Icons.arrow_back_ios_new_rounded,
          size: 14,
          color: isBlockedOffline
              ? AppTheme.textTertiary
              : (isSelected ? AppTheme.primary : AppTheme.textTertiary),
        ),
      ),
      selected: isSelected,
      selectedTileColor: AppTheme.tabSurface,
      onTap: () {
        if (isSelected) {
          if (!widget.embedded) {
            AppAlertService.navigatorKey.currentState?.pop();
          }
          return;
        }
        _openRoute(routeName, arguments: arguments);
      },
    );
  }

  Widget _buildSecureLogoutItem(BuildContext context) {
    final l = context.loc;
    return ListTile(
      minTileHeight: 50,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      leading: const Icon(Icons.logout_rounded, color: AppTheme.error),
      title: Text(
        l.tr('widgets_app_sidebar.051'),
        style: AppTheme.bodyText.copyWith(
          color: AppTheme.error,
          fontWeight: FontWeight.w700,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(
        Icons.lock_clock_rounded,
        size: 20,
        color: AppTheme.error,
      ),
      onTap: () async {
        if (!widget.embedded) {
          AppAlertService.navigatorKey.currentState?.pop();
        }
        await QuickLogoutAction.logout(context);
      },
    );
  }

  Widget _buildSectionLabel(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Text(
        label,
        style: AppTheme.caption.copyWith(
          color: AppTheme.textTertiary,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
