import 'package:flutter/material.dart';

import '../services/index.dart';
import '../utils/app_permissions.dart';
import '../utils/app_theme.dart';
import '../utils/user_display_name.dart';
import '../utils/permission_catalog.dart';
import '../widgets/app_sidebar.dart';
import '../widgets/app_top_actions.dart';
import '../widgets/responsive_scaffold_container.dart';
import '../widgets/shwakel_button.dart';
import '../widgets/shwakel_card.dart';

class SubUsersScreen extends StatefulWidget {
  const SubUsersScreen({super.key});

  @override
  State<SubUsersScreen> createState() => _SubUsersScreenState();
}

class _SubUsersScreenState extends State<SubUsersScreen> {
  final ApiService _api = ApiService();
  final AuthService _auth = AuthService();
  final _fullNameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  List<Map<String, dynamic>> _subUsers = const [];
  Map<String, dynamic>? _editing;
  bool _loading = true;
  bool _saving = false;
  bool _isDisabled = false;
  bool _canViewSubUsers = false;
  bool _canManageSubUsers = false;
  bool _showStats = false;
  late final Map<String, bool> _permissions = _defaultPermissions();

  static Map<String, bool> _defaultPermissions() => {
    'canTransfer': false,
    'canScanCards': true,
    'canOfflineCardScan': true,
    'canRedeemCards': true,
    'canWithdraw': false,
    'canReviewCards': false,
    'canReadOwnPrivateCardsOnly': false,
    'canRequestCardPrinting': true,
    'canUseExternalCardStore': true,
    'canAccessStoreManagement': false,
    'canManageStoreInventory': false,
    'canCreateStoreSales': false,
    'canCreateStorePurchases': false,
    'canManageStoreDebts': false,
    'canEditStorePrices': false,
    'canViewStoreProfits': false,
    'canViewStoreReports': false,
    'canManagePublicStorefront': false,
    'canViewPublicStores': true,
    'canBuyPublicStoreProducts': false,
  };

  static const List<String> _permissionKeysOrder = [
    'canTransfer',
    'canWithdraw',
    'canScanCards',
    'canRedeemCards',
    'canOfflineCardScan',
    'canRequestCardPrinting',
    'canReviewCards',
    'canReadOwnPrivateCardsOnly',
    'canUseExternalCardStore',
    'canAccessStoreManagement',
    'canManageStoreInventory',
    'canCreateStoreSales',
    'canCreateStorePurchases',
    'canManageStoreDebts',
    'canEditStorePrices',
    'canViewStoreProfits',
    'canViewStoreReports',
    'canManagePublicStorefront',
    'canViewPublicStores',
    'canBuyPublicStoreProducts',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _fullNameController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final currentUser = await _auth.currentUser();
      final appPermissions = AppPermissions.fromUser(currentUser);
      if (!appPermissions.canViewSubUsers) {
        if (!mounted) return;
        setState(() {
          _canViewSubUsers = false;
          _canManageSubUsers = false;
          _subUsers = const [];
          _loading = false;
        });
        return;
      }
      final users = await _api.getSubUsers();
      if (!mounted) return;
      setState(() {
        _canViewSubUsers = true;
        _canManageSubUsers = appPermissions.canManageSubUsers;
        _subUsers = users;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppAlertService.showError(
        context,
        title: context.loc.tr('screens_sub_users_screen.080'),
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  void _edit(Map<String, dynamic> user) {
    final permissions = Map<String, dynamic>.from(
      user['permissions'] as Map? ?? const {},
    );
    setState(() {
      _editing = user;
      _fullNameController.text = user['fullName']?.toString() ?? '';
      _usernameController.text = user['username']?.toString() ?? '';
      _passwordController.clear();
      _isDisabled = user['isDisabled'] == true;
      for (final key in _permissions.keys) {
        _permissions[key] = permissions[key] == true;
      }
    });
  }

  void _resetForm() {
    setState(() {
      _editing = null;
      _fullNameController.clear();
      _usernameController.clear();
      _passwordController.clear();
      _isDisabled = false;
      final defaults = _defaultPermissions();
      for (final key in _permissions.keys) {
        _permissions[key] = defaults[key] ?? false;
      }
    });
  }

  void _applyStoreRole(String role) {
    const storeKeys = {
      'canAccessStoreManagement',
      'canManageStoreInventory',
      'canCreateStoreSales',
      'canCreateStorePurchases',
      'canManageStoreDebts',
      'canEditStorePrices',
      'canViewStoreProfits',
      'canViewStoreReports',
      'canManagePublicStorefront',
    };
    setState(() {
      for (final key in storeKeys) {
        _permissions[key] = false;
      }
      _permissions['canAccessStoreManagement'] = true;
      _permissions['canCreateStoreSales'] = true;
      if (role == 'technician') {
        _permissions['canManageStoreInventory'] = true;
      }
      if (role == 'supervisor') {
        _permissions['canManageStoreInventory'] = true;
        _permissions['canCreateStorePurchases'] = true;
        _permissions['canManageStoreDebts'] = true;
        _permissions['canViewStoreReports'] = true;
      }
      if (role == 'manager') {
        for (final key in storeKeys) {
          _permissions[key] = true;
        }
      }
    });
  }

  Future<void> _save() async {
    if (!_canManageSubUsers) {
      return;
    }
    if (_usernameController.text.trim().isEmpty ||
        (_editing == null && _passwordController.text.trim().isEmpty)) {
      AppAlertService.showError(
        context,
        title: context.loc.tr('screens_admin_customers_screen.002'),
        message: context.loc.tr('screens_sub_users_screen.081'),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final users = _editing == null
          ? await _api.createSubUser(
              fullName: _fullNameController.text,
              username: _usernameController.text,
              password: _passwordController.text,
              permissions: Map<String, bool>.from(_permissions),
            )
          : await _api.updateSubUser(
              subUserId: _editing!['id'].toString(),
              fullName: _fullNameController.text,
              password: _passwordController.text,
              permissions: Map<String, bool>.from(_permissions),
              isDisabled: _isDisabled,
            );
      if (!mounted) return;
      setState(() {
        _subUsers = users;
        _saving = false;
      });
      _resetForm();
      AppAlertService.showSuccess(
        context,
        title: context.loc.tr('screens_admin_permissions_screen.001'),
        message: context.loc.tr('screens_sub_users_screen.082'),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppAlertService.showError(
        context,
        title: context.loc.tr('screens_admin_permissions_screen.002'),
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  Future<void> _transferBalance(
    Map<String, dynamic> user,
    String direction,
  ) async {
    if (!_canManageSubUsers) {
      return;
    }
    final amountController = TextEditingController();
    final notesController = TextEditingController();
    final title = direction == 'to_sub'
        ? context.loc.tr('screens_sub_users_screen.083')
        : context.loc.tr('screens_sub_users_screen.084');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: amountController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: context.loc.tr('screens_sub_users_screen.085'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: notesController,
              decoration: InputDecoration(
                labelText: context.loc.tr('screens_sub_users_screen.086'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.loc.tr('screens_security_settings_screen.050')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.loc.tr('screens_sub_users_screen.087')),
          ),
        ],
      ),
    );

    final amount = double.tryParse(amountController.text.trim()) ?? 0;
    final notes = notesController.text;
    amountController.dispose();
    notesController.dispose();

    if (confirmed != true) return;
    if (!mounted) return;

    if (amount <= 0) {
      if (!mounted) return;
      AppAlertService.showError(
        context,
        title: context.loc.tr('screens_sub_users_screen.088'),
        message: context.loc.tr('screens_sub_users_screen.089'),
      );
      return;
    }

    final security = await TransferSecurityService.confirmTransfer(
      context,
      allowOtpFallback: true,
    );
    if (!mounted || !security.isVerified) {
      return;
    }

    setState(() => _saving = true);
    try {
      final users = await _api.transferSubUserBalance(
        subUserId: user['id'].toString(),
        direction: direction,
        amount: amount,
        notes: notes,
        otpCode: security.otpCode,
        securityPin: security.securityPin,
      );
      if (!mounted) return;
      setState(() {
        _subUsers = users;
        _saving = false;
      });
      AppAlertService.showSuccess(
        context,
        title: context.loc.tr('screens_sub_users_screen.090'),
        message: context.loc.tr('screens_sub_users_screen.091'),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppAlertService.showError(
        context,
        title: context.loc.tr('screens_sub_users_screen.092'),
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  int get _enabledPermissionsCount =>
      _permissions.entries.where((entry) => entry.value).length;

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        drawer: AppSidebar.drawerFor(context),
        appBar: AppBar(
          title: Text(context.loc.tr('screens_sub_users_screen.093')),
          actions: const [AppNotificationAction(), QuickLogoutAction()],
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (!_canViewSubUsers) {
      return Scaffold(
        drawer: AppSidebar.drawerFor(context),
        appBar: AppBar(
          title: Text(context.loc.tr('screens_sub_users_screen.093')),
          actions: const [AppNotificationAction(), QuickLogoutAction()],
        ),
        body: ResponsiveScaffoldContainer(
          child: Center(
            child: ShwakelCard(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.lock_outline_rounded,
                    size: 44,
                    color: AppTheme.textTertiary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    context.loc.tr('screens_sub_users_screen.094'),
                    style: AppTheme.h3,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final tabCount = _canManageSubUsers ? 2 : 1;

    return DefaultTabController(
      length: tabCount,
      initialIndex: 0,
      child: Scaffold(
        drawer: AppSidebar.drawerFor(context),
        appBar: AppBar(
          title: Text(context.loc.tr('screens_sub_users_screen.093')),
          actions: const [AppNotificationAction(), QuickLogoutAction()],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(76),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  dividerColor: Colors.transparent,
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicatorPadding: const EdgeInsets.all(6),
                  labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                  tabs: [
                    Tab(
                      text: context.loc.tr('screens_sub_users_screen.096'),
                      icon: const Icon(Icons.groups_rounded),
                    ),
                    if (_canManageSubUsers)
                      Tab(
                        text: context.loc.tr('screens_sub_users_screen.095'),
                        icon: const Icon(Icons.person_add_alt_1_rounded),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        body: ResponsiveScaffoldContainer(
          child: Padding(
            padding: AppTheme.pagePadding(context, top: 18),
            child: TabBarView(
              children: [
                _buildUsersTab(),
                if (_canManageSubUsers) _buildManageTab(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUsersTab() {
    return ListView(
      children: [
        if (_canManageSubUsers) ...[
          _buildInlineGuideCard(),
          const SizedBox(height: 18),
        ],
        if (_showStats) ...[_buildStatsRow(), const SizedBox(height: 18)],
        if (!_canManageSubUsers) ...[
          ShwakelCard(
            padding: const EdgeInsets.all(18),
            child: Text(
              context.loc.tr('screens_sub_users_screen.126'),
              style: AppTheme.bodyAction,
            ),
          ),
          const SizedBox(height: 18),
        ],
        _buildUsersSection(),
      ],
    );
  }

  Widget _buildManageTab() {
    return ListView(
      children: [
        _buildManageWorkspace(),
        const SizedBox(height: 18),
        _buildForm(),
      ],
    );
  }

  Widget _buildInlineGuideCard() {
    return ShwakelCard(
      padding: const EdgeInsets.all(18),
      color: AppTheme.surface,
      withBorder: true,
      borderColor: AppTheme.borderLight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppTheme.primarySoft,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.view_compact_alt_rounded,
              color: AppTheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.loc.tr('screens_sub_users_screen.097'),
                  style: AppTheme.h3,
                ),
                const SizedBox(height: 6),
                Text(
                  context.loc.tr('screens_sub_users_screen.098'),
                  style: AppTheme.bodyAction,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ShwakelButton(
            label: _showStats
                ? context.loc.tr('screens_sub_users_screen.130')
                : context.loc.tr('screens_sub_users_screen.129'),
            icon: _showStats
                ? Icons.visibility_off_rounded
                : Icons.query_stats_rounded,
            isSecondary: true,
            onPressed: () => setState(() => _showStats = !_showStats),
          ),
        ],
      ),
    );
  }

  Widget _buildManageWorkspace() {
    final isEditing = _editing != null;
    return ShwakelCard(
      padding: const EdgeInsets.all(18),
      color: AppTheme.surface,
      withBorder: true,
      borderColor: AppTheme.borderLight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: isEditing
                      ? LinearGradient(
                          colors: [
                            AppTheme.accent.withValues(alpha: 0.92),
                            AppTheme.highlight,
                          ],
                        )
                      : AppTheme.primaryGradient,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  isEditing
                      ? Icons.edit_rounded
                      : Icons.person_add_alt_1_rounded,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isEditing
                          ? context.loc.tr('screens_sub_users_screen.099')
                          : context.loc.tr('screens_sub_users_screen.100'),
                      style: AppTheme.h3,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      isEditing
                          ? context.loc.tr('screens_sub_users_screen.101')
                          : context.loc.tr('screens_sub_users_screen.102'),
                      style: AppTheme.bodyAction,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (isEditing) ...[
            const SizedBox(height: 16),
            ShwakelButton(
              label: context.loc.tr('screens_sub_users_screen.052'),
              icon: Icons.refresh_rounded,
              isSecondary: true,
              onPressed: _resetForm,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildUsersSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeading(
          title: context.loc.tr('screens_sub_users_screen.096'),
          subtitle: _subUsers.isEmpty
              ? context.loc.tr('screens_sub_users_screen.103')
              : context.loc.tr('screens_sub_users_screen.104'),
          icon: Icons.manage_accounts_rounded,
        ),
        const SizedBox(height: 14),
        if (_subUsers.isEmpty)
          _buildEmptyState()
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _subUsers.length,
            separatorBuilder: (context, index) => const SizedBox(height: 12),
            itemBuilder: (context, index) =>
                _buildSubUserCard(_subUsers[index]),
          ),
      ],
    );
  }

  Widget _buildForm() {
    return ShwakelCard(
      shadowLevel: ShwakelShadowLevel.medium,
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeading(
            title: _editing == null
                ? context.loc.tr('screens_sub_users_screen.105')
                : context.loc.tr('screens_sub_users_screen.106'),
            subtitle: _editing == null
                ? context.loc.tr('screens_sub_users_screen.107')
                : context.loc.tr('screens_sub_users_screen.108'),
            icon: _editing == null
                ? Icons.person_add_alt_1_rounded
                : Icons.edit_rounded,
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 5, child: _buildIdentityPanel()),
                    const SizedBox(width: 16),
                    Expanded(flex: 6, child: _buildPermissionsPanel()),
                  ],
                );
              }

              return Column(
                children: [
                  _buildIdentityPanel(),
                  const SizedBox(height: 16),
                  _buildPermissionsPanel(),
                ],
              );
            },
          ),
          const SizedBox(height: 18),
          _buildActionsRow(),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    final activeUsers = _subUsers
        .where((user) => user['isDisabled'] != true)
        .length;
    final disabledUsers = _subUsers.length - activeUsers;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        final children = [
          _buildStatCard(
            title: context.loc.tr('screens_sub_users_screen.109'),
            value: _subUsers.length.toString(),
            hint: context.loc.tr('screens_sub_users_screen.110'),
            icon: Icons.groups_rounded,
            accent: AppTheme.primary,
            background: AppTheme.surface,
          ),
          _buildStatCard(
            title: context.loc.tr('screens_sub_users_screen.111'),
            value: activeUsers.toString(),
            hint: context.loc.tr('screens_sub_users_screen.112'),
            icon: Icons.verified_user_rounded,
            accent: AppTheme.success,
            background: AppTheme.successLight,
          ),
          _buildStatCard(
            title: context.loc.tr('screens_sub_users_screen.113'),
            value: disabledUsers.toString(),
            hint: context.loc.tr('screens_sub_users_screen.114'),
            icon: Icons.pause_circle_outline_rounded,
            accent: AppTheme.warning,
            background: AppTheme.warningLight,
          ),
        ];

        if (compact) {
          return Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i != children.length - 1) const SizedBox(height: 12),
              ],
            ],
          );
        }

        return Row(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              Expanded(child: children[i]),
              if (i != children.length - 1) const SizedBox(width: 12),
            ],
          ],
        );
      },
    );
  }

  Widget _buildStatCard({
    required String title,
    required String value,
    required String hint,
    required IconData icon,
    required Color accent,
    required Color background,
  }) {
    return ShwakelCard(
      color: background,
      withBorder: true,
      borderColor: accent.withValues(alpha: 0.14),
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(icon, color: accent, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTheme.caption.copyWith(color: accent)),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: AppTheme.h2.copyWith(
                    fontSize: 24,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(hint, style: AppTheme.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIdentityPanel() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: AppTheme.cardHighlightGradient,
        borderRadius: AppTheme.radiusMd,
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.loc.tr('screens_sub_users_screen.115'),
            style: AppTheme.h3,
          ),
          const SizedBox(height: 8),
          Text(
            context.loc.tr('screens_sub_users_screen.116'),
            style: AppTheme.caption,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _fullNameController,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: context.loc.tr('screens_admin_customers_screen.007'),
              prefixIcon: const Icon(Icons.badge_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _usernameController,
            enabled: _editing == null,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: context.loc.tr('screens_admin_customers_screen.006'),
              prefixIcon: const Icon(Icons.alternate_email_rounded),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: _editing == null
                  ? context.loc.tr('screens_login_screen.006')
                  : context.loc.tr('screens_sub_users_screen.117'),
              prefixIcon: const Icon(Icons.lock_outline_rounded),
            ),
          ),
          if (_editing != null) ...[
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: _isDisabled ? AppTheme.warningLight : AppTheme.surface,
                borderRadius: AppTheme.radiusMd,
                border: Border.all(
                  color: (_isDisabled ? AppTheme.warning : AppTheme.border)
                      .withValues(alpha: 0.25),
                ),
              ),
              child: SwitchListTile(
                value: _isDisabled,
                onChanged: (value) => setState(() => _isDisabled = value),
                title: Text(context.loc.tr('screens_sub_users_screen.118')),
                subtitle: Text(
                  _isDisabled
                      ? context.loc.tr('screens_sub_users_screen.119')
                      : context.loc.tr('screens_sub_users_screen.120'),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPermissionsPanel() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surfaceVariant,
        borderRadius: AppTheme.radiusMd,
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.loc.tr('screens_sub_users_screen.121'),
                      style: AppTheme.h3,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      context.loc.tr('screens_sub_users_screen.122'),
                      style: AppTheme.caption,
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.primarySoft,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  context.loc.tr(
                    'screens_sub_users_screen.123',
                    params: {'count': '$_enabledPermissionsCount'},
                  ),
                  style: AppTheme.caption.copyWith(
                    color: AppTheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.primarySoft.withValues(alpha: 0.6),
              borderRadius: AppTheme.radiusMd,
              border: Border.all(
                color: AppTheme.primary.withValues(alpha: 0.12),
              ),
            ),
            child: Text(
              context.loc.tr('screens_sub_users_screen.124'),
              style: AppTheme.caption.copyWith(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            context.loc.text('قوالب موظفي المحل', 'Store employee presets'),
            style: AppTheme.bodyBold,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.point_of_sale_rounded, size: 18),
                label: Text(
                  context.loc.text('كاشير - بيع فقط', 'Cashier - sales only'),
                ),
                onPressed: () => _applyStoreRole('cashier'),
              ),
              ActionChip(
                avatar: const Icon(Icons.build_rounded, size: 18),
                label: Text(
                  context.loc.text('فني صيانة', 'Maintenance technician'),
                ),
                onPressed: () => _applyStoreRole('technician'),
              ),
              ActionChip(
                avatar: const Icon(Icons.supervisor_account_rounded, size: 18),
                label: Text(
                  context.loc.text('مشرف مبيعات', 'Sales supervisor'),
                ),
                onPressed: () => _applyStoreRole('supervisor'),
              ),
              ActionChip(
                avatar: const Icon(
                  Icons.admin_panel_settings_rounded,
                  size: 18,
                ),
                label: Text(context.loc.text('مدير محل', 'Store manager')),
                onPressed: () => _applyStoreRole('manager'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ..._permissionKeysOrder.map(
            (key) =>
                _permissionTile(PermissionCatalog.label(context, key), key),
          ),
        ],
      ),
    );
  }

  Widget _buildActionsRow() {
    final isPhone = MediaQuery.sizeOf(context).width < 700;

    if (isPhone) {
      return Column(
        children: [
          ShwakelButton(
            label: _saving
                ? context.loc.tr('screens_sub_users_screen.053')
                : context.loc.tr('screens_sub_users_screen.054'),
            icon: Icons.save_outlined,
            gradient: AppTheme.primaryGradient,
            isLoading: _saving,
            onPressed: _saving ? null : _save,
          ),
          if (_editing != null) ...[
            const SizedBox(height: 10),
            ShwakelButton(
              label: context.loc.tr('screens_sub_users_screen.055'),
              icon: Icons.close_rounded,
              isSecondary: true,
              onPressed: _resetForm,
            ),
          ],
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: ShwakelButton(
            label: _saving
                ? context.loc.tr('screens_sub_users_screen.053')
                : context.loc.tr('screens_sub_users_screen.054'),
            icon: Icons.save_outlined,
            gradient: AppTheme.primaryGradient,
            isLoading: _saving,
            onPressed: _saving ? null : _save,
          ),
        ),
        if (_editing != null) ...[
          const SizedBox(width: 12),
          Expanded(
            child: ShwakelButton(
              label: context.loc.tr('screens_sub_users_screen.055'),
              icon: Icons.close_rounded,
              isSecondary: true,
              onPressed: _resetForm,
            ),
          ),
        ],
      ],
    );
  }

  Widget _permissionTile(String title, String key) {
    final enabled = _permissions[key] ?? false;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: enabled
            ? AppTheme.primarySoft.withValues(alpha: 0.5)
            : Colors.white,
        borderRadius: AppTheme.radiusMd,
        border: Border.all(
          color: enabled
              ? AppTheme.primary.withValues(alpha: 0.18)
              : AppTheme.borderLight,
        ),
      ),
      child: SwitchListTile(
        value: enabled,
        onChanged: (value) {
          setState(() {
            _permissions[key] = value;
            if (key == 'canRedeemCards') {
              _permissions['canScanCards'] =
                  value || (_permissions['canScanCards'] ?? false);
            }
            if (key == 'canRequestCardPrinting' && value) {
              _permissions['canScanCards'] =
                  _permissions['canScanCards'] ?? true;
            }
          });
        },
        title: Text(title, style: AppTheme.bodyBold.copyWith(fontSize: 15)),
        subtitle: Text(_permissionHint(key), style: AppTheme.caption),
      ),
    );
  }

  String _permissionHint(String key) {
    final fromCatalog = PermissionCatalog.description(context, key).trim();
    if (fromCatalog.isNotEmpty) {
      return fromCatalog;
    }
    switch (key) {
      case 'canTransfer':
        return context.loc.tr('screens_sub_users_screen.056');
      case 'canWithdraw':
        return context.loc.tr('screens_sub_users_screen.057');
      case 'canScanCards':
        return context.loc.tr('screens_sub_users_screen.058');
      case 'canRedeemCards':
        return context.loc.tr('screens_sub_users_screen.059');
      case 'canOfflineCardScan':
        return context.loc.tr('screens_sub_users_screen.060');
      case 'canReviewCards':
        return context.loc.tr('screens_sub_users_screen.061');
      case 'canRequestCardPrinting':
        return context.loc.tr('screens_sub_users_screen.062');
      default:
        return context.loc.tr('screens_sub_users_screen.063');
    }
  }

  Widget _buildEmptyState() {
    return ShwakelCard(
      color: AppTheme.surface,
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Container(
            width: 74,
            height: 74,
            decoration: BoxDecoration(
              color: AppTheme.primarySoft,
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Icon(
              Icons.group_add_rounded,
              color: AppTheme.primary,
              size: 34,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            context.loc.tr('screens_sub_users_screen.064'),
            style: AppTheme.h3,
          ),
          const SizedBox(height: 8),
          Text(
            context.loc.tr('screens_sub_users_screen.065'),
            textAlign: TextAlign.center,
            style: AppTheme.caption.copyWith(fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildSubUserCard(Map<String, dynamic> user) {
    final permissions = Map<String, dynamic>.from(
      user['permissions'] as Map? ?? const {},
    );
    final enabledLabels = <String>[
      if (permissions['canTransfer'] == true)
        context.loc.tr('screens_quick_transfer_screen.036'),
      if (permissions['canWithdraw'] == true)
        context.loc.tr('screens_sub_users_screen.066'),
      if (permissions['canScanCards'] == true)
        context.loc.tr('screens_sub_users_screen.067'),
      if (permissions['canRedeemCards'] == true)
        context.loc.tr('screens_sub_users_screen.068'),
      if (permissions['canOfflineCardScan'] == true)
        context.loc.tr('screens_sub_users_screen.069'),
      if (permissions['canRequestCardPrinting'] == true)
        context.loc.tr('screens_sub_users_screen.070'),
      if (permissions['canReviewCards'] == true)
        context.loc.tr('screens_sub_users_screen.071'),
      if (permissions['canReadOwnPrivateCardsOnly'] == true)
        context.loc.tr('screens_sub_users_screen.132'),
    ];
    final displayName = UserDisplayName.fromMap(
      user,
      fallback: user['username'].toString(),
    );
    final isDisabled = user['isDisabled'] == true;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: ShwakelCard(
        shadowLevel: ShwakelShadowLevel.medium,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final stacked = constraints.maxWidth < 720;
                final statusChip = _buildStatusChip(isDisabled);
                final identity = Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          gradient: isDisabled
                              ? LinearGradient(
                                  colors: [
                                    AppTheme.warning.withValues(alpha: 0.9),
                                    AppTheme.highlight,
                                  ],
                                )
                              : AppTheme.primaryGradient,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Icon(
                          Icons.person_outline_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              displayName,
                              style: AppTheme.h3.copyWith(fontSize: 17),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '@${user['username']}',
                              style: AppTheme.caption.copyWith(
                                color: AppTheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: enabledLabels.isEmpty
                                  ? [
                                      _buildPermissionChip(
                                        label: context.loc.tr(
                                          'screens_sub_users_screen.072',
                                        ),
                                        background: AppTheme.surfaceVariant,
                                        foreground: AppTheme.textSecondary,
                                      ),
                                    ]
                                  : enabledLabels
                                        .map(
                                          (label) => _buildPermissionChip(
                                            label: label,
                                            background: AppTheme.primarySoft,
                                            foreground: AppTheme.primary,
                                          ),
                                        )
                                        .toList(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );

                if (stacked) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          identity,
                          const SizedBox(width: 12),
                          statusChip,
                        ],
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: _buildSubUserActionsMenu(user),
                      ),
                    ],
                  );
                }

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    identity,
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        statusChip,
                        const SizedBox(height: 10),
                        _buildSubUserActionsMenu(user),
                      ],
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubUserActionsMenu(Map<String, dynamic> user) {
    return PopupMenuButton<String>(
      tooltip: context.loc.tr('screens_sub_users_screen.125'),
      icon: const Icon(Icons.more_horiz_rounded),
      enabled: _canManageSubUsers && !_saving,
      onSelected: (value) {
        switch (value) {
          case 'edit':
            _edit(user);
            DefaultTabController.of(context).animateTo(1);
            break;
          case 'to_sub':
            _transferBalance(user, 'to_sub');
            break;
          case 'from_sub':
            _transferBalance(user, 'from_sub');
            break;
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          value: 'edit',
          child: Text(context.loc.tr('screens_sub_users_screen.125')),
        ),
        PopupMenuItem<String>(
          value: 'to_sub',
          child: Text(context.loc.tr('screens_quick_transfer_screen.036')),
        ),
        PopupMenuItem<String>(
          value: 'from_sub',
          child: Text(context.loc.tr('screens_sub_users_screen.066')),
        ),
      ],
    );
  }

  Widget _buildStatusChip(bool isDisabled) {
    final color = isDisabled ? AppTheme.warning : AppTheme.success;
    final background = isDisabled
        ? AppTheme.warningLight
        : AppTheme.successLight;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isDisabled
                ? Icons.pause_circle_outline_rounded
                : Icons.check_circle_rounded,
            color: color,
            size: 16,
          ),
          const SizedBox(width: 6),
          Text(
            isDisabled
                ? context.loc.tr('screens_sub_users_screen.127')
                : context.loc.tr('screens_sub_users_screen.128'),
            style: AppTheme.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionChip({
    required String label,
    required Color background,
    required Color foreground,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: AppTheme.caption.copyWith(
          color: foreground,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildSectionHeading({
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: AppTheme.primarySoft,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Icon(icon, color: AppTheme.primary),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTheme.h2.copyWith(fontSize: 20)),
              const SizedBox(height: 4),
              Text(subtitle, style: AppTheme.caption.copyWith(fontSize: 14)),
            ],
          ),
        ),
      ],
    );
  }
}
