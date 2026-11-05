import 'package:flutter/material.dart';

import '../services/index.dart';
import '../utils/app_permissions.dart';
import '../utils/app_theme.dart';
import '../widgets/app_sidebar.dart';
import '../widgets/app_top_actions.dart';
import '../widgets/responsive_scaffold_container.dart';
import '../widgets/shwakel_button.dart';
import '../widgets/shwakel_card.dart';

class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({super.key, this.authService});

  @visibleForTesting
  final AuthService? authService;

  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  late final AuthService _authService;
  final ApiService _apiService = ApiService();

  final TextEditingController _businessNameController = TextEditingController();
  final TextEditingController _fullNameController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _whatsappController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _nationalIdController = TextEditingController();
  final TextEditingController _birthDateController = TextEditingController();
  final TextEditingController _referralPhoneController =
      TextEditingController();
  final TextEditingController _currentPassController = TextEditingController();
  final TextEditingController _newPassController = TextEditingController();
  final TextEditingController _confirmNewPassController =
      TextEditingController();

  bool _isLoading = true;
  bool _isAuthorized = false;
  bool _isSaving = false;
  bool _profileLocked = false;
  bool _hasPin = false;
  bool _biometricEnabled = false;
  bool _canUseBiometrics = false;
  bool _needsSessionRecovery = false;
  String? _loadError;
  Set<String> _editableProfileFields = const <String>{};
  Map<String, dynamic>? _user;

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? AuthService();
    _load();
  }

  @override
  void dispose() {
    _businessNameController.dispose();
    _fullNameController.dispose();
    _usernameController.dispose();
    _whatsappController.dispose();
    _emailController.dispose();
    _addressController.dispose();
    _nationalIdController.dispose();
    _birthDateController.dispose();
    _referralPhoneController.dispose();
    _currentPassController.dispose();
    _newPassController.dispose();
    _confirmNewPassController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _isLoading = _user == null;
        _loadError = null;
      });
    }
    try {
      var user =
          AuthService.peekCurrentUser() ?? await _authService.currentUser();
      final token = (await _authService.token())?.trim() ?? '';
      if (user == null && token.isNotEmpty) {
        try {
          await _authService.tryRefreshCurrentUser();
          user = await _authService.currentUser();
        } catch (_) {
          user = await _authService.currentUser();
        }
      }
      if (!mounted) {
        return;
      }
      if (user == null) {
        setState(() {
          _needsSessionRecovery = token.isNotEmpty;
          _isAuthorized = false;
          _isLoading = false;
        });
        return;
      }
      final resolvedUser = user;

      final hasPin = await LocalSecurityService.hasPin();
      final canUseBiometrics = await LocalSecurityService.canUseBiometrics();
      final biometricEnabled =
          await LocalSecurityService.isBiometricEnabled() && canUseBiometrics;
      if (!mounted) {
        return;
      }

      setState(() {
        _needsSessionRecovery = false;
        _loadError = null;
        _isAuthorized = AppPermissions.fromUser(
          resolvedUser,
        ).canViewAccountSettings;
        _user = resolvedUser;
        _businessNameController.text =
            resolvedUser['businessName']?.toString() ?? '';
        _fullNameController.text = resolvedUser['fullName']?.toString() ?? '';
        _usernameController.text = resolvedUser['username']?.toString() ?? '';
        _whatsappController.text = PhoneNumberService.localDisplay(
          resolvedUser['whatsapp']?.toString(),
        );
        _emailController.text = resolvedUser['email']?.toString() ?? '';
        _addressController.text = resolvedUser['address']?.toString() ?? '';
        _nationalIdController.text =
            resolvedUser['nationalId']?.toString() ?? '';
        _birthDateController.text = resolvedUser['birthDate']?.toString() ?? '';
        _referralPhoneController.text =
            resolvedUser['referralPhone']?.toString() ?? '';
        _hasPin = hasPin;
        _canUseBiometrics = canUseBiometrics;
        _biometricEnabled = biometricEnabled;

        final verification =
            resolvedUser['transferVerificationStatus']?.toString() ??
            'unverified';
        _editableProfileFields = Set<String>.from(
          (resolvedUser['editableProfileFields'] as List? ?? const []).map(
            (item) => item.toString(),
          ),
        );
        _profileLocked =
            resolvedUser['profileEditable'] == false ||
            (verification == 'approved' && _editableProfileFields.isEmpty);
        _isLoading = false;
      });
    } catch (error) {
      String token = '';
      try {
        token = (await _authService.token())?.trim() ?? '';
      } catch (_) {}
      if (!mounted) {
        return;
      }
      setState(() {
        _needsSessionRecovery = token.isNotEmpty;
        _loadError = ErrorMessageService.sanitize(error);
        _isLoading = false;
      });
    }
  }

  Future<void> _save() async {
    final l = context.loc;
    if (_profileLocked) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      final response = await _authService.updateProfile(
        businessName: _businessNameController.text,
        fullName: _fullNameController.text,
        username: _usernameController.text,
        email: _emailController.text,
        address: _addressController.text,
        nationalId: _nationalIdController.text,
        birthDate: _birthDateController.text,
        referralPhone: _referralPhoneController.text,
      );
      final user = Map<String, dynamic>.from(response['user'] as Map);
      if (!mounted) {
        return;
      }
      setState(() {
        _user = user;
        _editableProfileFields = Set<String>.from(
          (user['editableProfileFields'] as List? ?? const []).map(
            (item) => item.toString(),
          ),
        );
        _profileLocked = user['profileEditable'] == false;
      });
      AppAlertService.showSuccess(
        context,
        title: l.tr('screens_account_settings_screen.001'),
        message: l.tr('screens_account_settings_screen.039'),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppAlertService.showError(
        context,
        title: l.tr('screens_account_settings_screen.002'),
        message: ErrorMessageService.sanitize(error),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _changePassword() async {
    final l = context.loc;
    final current = _currentPassController.text.trim();
    final next = _newPassController.text;
    final confirm = _confirmNewPassController.text;

    if (current.isEmpty || next.isEmpty || confirm.isEmpty) {
      AppAlertService.showError(
        context,
        title: l.tr('screens_account_settings_screen.003'),
        message: l.tr('screens_account_settings_screen.040'),
      );
      return;
    }
    if (next != confirm) {
      AppAlertService.showError(
        context,
        title: l.tr('screens_account_settings_screen.004'),
        message: l.tr('screens_account_settings_screen.041'),
      );
      return;
    }
    if (next.length < 8) {
      AppAlertService.showError(
        context,
        title: l.tr('screens_account_settings_screen.005'),
        message: l.tr('screens_account_settings_screen.042'),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      await _authService.changePassword(
        currentPassword: current,
        newPassword: next,
      );
      _currentPassController.clear();
      _newPassController.clear();
      _confirmNewPassController.clear();
      if (!mounted) {
        return;
      }
      AppAlertService.showSuccess(
        context,
        title: l.tr('screens_account_settings_screen.006'),
        message: l.tr('screens_account_settings_screen.043'),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppAlertService.showError(
        context,
        title: l.tr('screens_account_settings_screen.007'),
        message: ErrorMessageService.sanitize(error),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.loc.tr('screens_account_settings_screen.056')),
        content: Text(context.loc.tr('screens_account_settings_screen.057')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(context.loc.tr('screens_account_settings_screen.058')),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              context.loc.tr('screens_account_settings_screen.056'),
              style: const TextStyle(color: AppTheme.error),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      await _authService.deleteAccount();
      await RealtimeNotificationService.stop();
      await LocalSecurityService.clearTrustedState();
      await LocalSecurityService.clearRelockRequirement();
      await LocalSecurityService.skipNextUnlock();
      if (!mounted) {
        return;
      }
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppAlertService.showError(
        context,
        title: context.loc.tr('screens_account_settings_screen.059'),
        message: ErrorMessageService.sanitize(error),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  bool get _hasPendingProfileCompletion {
    final verification =
        _user?['transferVerificationStatus']?.toString() ?? 'unverified';
    return verification == 'approved' && _editableProfileFields.isNotEmpty;
  }

  bool get _hasLocalSecuritySetup => _hasPin || _biometricEnabled;

  @override
  Widget build(BuildContext context) {
    final l = context.loc;
    if (_isLoading) {
      return const ShwakelPageLoadingScaffold();
    }

    if (_needsSessionRecovery) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          title: Text(l.text('استعادة الجلسة', 'Restore session')),
        ),
        body: ResponsiveScaffoldContainer(
          maxWidth: 680,
          child: Center(
            child: ShwakelCard(
              key: const ValueKey('account-session-recovery'),
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.sync_problem_rounded,
                    size: 52,
                    color: AppTheme.warning,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l.text(
                      'تعذر استعادة بيانات الحساب مؤقتًا',
                      'Account data could not be restored temporarily',
                    ),
                    style: AppTheme.h2,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _loadError ??
                        l.text(
                          'جلستك محفوظة ولم يتم تسجيل خروجك. أعد المحاولة عند استقرار الاتصال.',
                          'Your session is saved and you were not signed out. Retry when the connection is stable.',
                        ),
                    style: AppTheme.bodyAction.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  ShwakelButton(
                    label: l.text('إعادة المحاولة', 'Retry'),
                    icon: Icons.refresh_rounded,
                    onPressed: _load,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (_user == null) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          title: Text(l.tr('screens_account_settings_screen.008')),
        ),
        body: Center(
          child: ShwakelButton(
            label: l.tr('screens_account_settings_screen.063'),
            icon: Icons.login_rounded,
            onPressed: () => Navigator.of(
              context,
            ).pushNamedAndRemoveUntil('/login', (route) => false),
          ),
        ),
      );
    }

    if (!_isAuthorized) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          title: Text(l.tr('screens_account_settings_screen.008')),
          actions: const [AppNotificationAction(), QuickLogoutAction()],
        ),
        drawer: AppSidebar.drawerFor(context),
        body: Center(
          child: ShwakelCard(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.lock_outline_rounded,
                  size: 54,
                  color: AppTheme.textTertiary,
                ),
                const SizedBox(height: 14),
                Text(
                  l.tr('screens_account_settings_screen.060'),
                  style: AppTheme.h3,
                ),
              ],
            ),
          ),
        ),
      );
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          title: Text(l.tr('screens_account_settings_screen.008')),
          actions: [const AppNotificationAction(), const QuickLogoutAction()],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(78),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: SizedBox(
                  height: 56,
                  child: TabBar(
                    dividerColor: Colors.transparent,
                    indicatorSize: TabBarIndicatorSize.tab,
                    indicatorPadding: const EdgeInsets.all(6),
                    labelPadding: EdgeInsets.zero,
                    tabs: [
                      Tab(
                        height: 56,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.person_rounded, size: 20),
                              const SizedBox(width: 8),
                              Text(l.tr('screens_account_settings_screen.009')),
                            ],
                          ),
                        ),
                      ),
                      Tab(
                        height: 56,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.lock_rounded, size: 20),
                              const SizedBox(width: 8),
                              Text(l.tr('screens_account_settings_screen.010')),
                            ],
                          ),
                        ),
                      ),
                      Tab(
                        height: 56,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.manage_accounts_rounded,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Text(l.tr('screens_account_settings_screen.068')),
                            ],
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
        drawer: AppSidebar.drawerFor(context),
        body: TabBarView(
          children: [
            _buildProfileTab(),
            _buildPasswordTab(),
            _buildAccountActionsTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileTab() {
    final l = context.loc;
    final isMobile = MediaQuery.of(context).size.width < 760;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppTheme.spacingLg),
      child: ResponsiveScaffoldContainer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_hasPendingProfileCompletion) ...[
              _buildCompletionNotice(),
              const SizedBox(height: 16),
            ],
            if (_profileLocked) ...[
              _buildLockedNotice(),
              const SizedBox(height: 16),
            ],
            if (isMobile) ...[
              _buildBasicInfoCard(),
              const SizedBox(height: 16),
              _buildIdentityCard(),
            ] else ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: _buildBasicInfoCard()),
                  const SizedBox(width: 16),
                  Expanded(flex: 2, child: _buildIdentityCard()),
                ],
              ),
            ],
            const SizedBox(height: 24),
            ShwakelButton(
              label: l.tr('screens_account_settings_screen.011'),
              icon: Icons.save_rounded,
              onPressed: _profileLocked ? null : _save,
              isLoading: _isSaving,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPasswordTab() {
    final l = context.loc;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppTheme.spacingLg),
      child: ResponsiveScaffoldContainer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ShwakelCard(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _field(
                    l.tr('screens_account_settings_screen.013'),
                    _currentPassController,
                    Icons.lock_outline_rounded,
                    obscure: true,
                  ),
                  const SizedBox(height: 16),
                  _field(
                    l.tr('screens_account_settings_screen.014'),
                    _newPassController,
                    Icons.lock_reset_rounded,
                    obscure: true,
                  ),
                  const SizedBox(height: 16),
                  _field(
                    l.tr('screens_account_settings_screen.045'),
                    _confirmNewPassController,
                    Icons.verified_user_rounded,
                    obscure: true,
                  ),
                  const SizedBox(height: 24),
                  ShwakelButton(
                    label: l.tr('screens_account_settings_screen.015'),
                    icon: Icons.security_rounded,
                    onPressed: _changePassword,
                    isLoading: _isSaving,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountActionsTab() {
    final l = context.loc;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppTheme.spacingLg),
      child: ResponsiveScaffoldContainer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildLoginProtectionPanel(),
            const SizedBox(height: 16),
            ShwakelCard(
              padding: const EdgeInsets.all(24),
              borderColor: AppTheme.textPrimary.withValues(alpha: 0.08),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.tr('screens_account_settings_screen.053'),
                    style: AppTheme.h3,
                  ),
                  const SizedBox(height: 16),
                  ShwakelButton(
                    label: l.tr('screens_account_settings_screen.055'),
                    icon: Icons.logout_rounded,
                    isSecondary: true,
                    onPressed: _isSaving
                        ? null
                        : () => QuickLogoutAction.logout(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ShwakelCard(
              padding: const EdgeInsets.all(24),
              borderColor: AppTheme.error.withValues(alpha: 0.24),
              color: AppTheme.error.withValues(alpha: 0.04),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.tr('screens_account_settings_screen.056'),
                    style: AppTheme.h3.copyWith(color: AppTheme.error),
                  ),
                  const SizedBox(height: 16),
                  ShwakelButton(
                    label: l.tr('screens_account_settings_screen.056'),
                    icon: Icons.delete_forever_rounded,
                    isDanger: true,
                    onPressed: _isSaving ? null : _deleteAccount,
                    isLoading: _isSaving,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoginProtectionPanel() {
    final l = context.loc;
    final overallColor = _hasLocalSecuritySetup
        ? AppTheme.success
        : AppTheme.warning;

    return ShwakelCard(
      padding: const EdgeInsets.all(22),
      borderColor: overallColor.withValues(alpha: 0.18),
      color: overallColor.withValues(alpha: 0.045),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: overallColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.lock_person_rounded, color: overallColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.tr('screens_account_settings_screen.074'),
                      style: AppTheme.h3,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _hasLocalSecuritySetup
                          ? l.tr('screens_account_settings_screen.070')
                          : l.tr('screens_account_settings_screen.071'),
                      style: AppTheme.caption.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 680;
              final pinTile = _buildSecurityAccessTile(
                icon: Icons.pin_rounded,
                title: l.tr('screens_account_settings_screen.075'),
                description: l.tr('screens_security_settings_screen.031'),
                enabled: _hasPin,
                color: _hasPin ? AppTheme.success : AppTheme.warning,
                actionLabel: _hasPin
                    ? l.tr('screens_security_settings_screen.029')
                    : l.tr('screens_security_settings_screen.030'),
                secondaryLabel: _hasPin
                    ? l.tr('screens_security_settings_screen.064')
                    : null,
                onPrimary: _createOrChangePinFromAccount,
                onSecondary: _hasPin ? _removePinFromAccount : null,
              );
              final biometricTile = _buildSecurityAccessTile(
                icon: Icons.fingerprint_rounded,
                title: l.tr('screens_account_settings_screen.076'),
                description: _canUseBiometrics
                    ? l.tr('screens_security_settings_screen.022')
                    : l.tr('screens_account_settings_screen.077'),
                enabled: _biometricEnabled,
                color: _biometricEnabled
                    ? AppTheme.success
                    : (_canUseBiometrics
                          ? AppTheme.warning
                          : AppTheme.textTertiary),
                actionLabel: _biometricEnabled
                    ? l.tr('screens_security_settings_screen.064')
                    : l.tr('screens_security_settings_screen.030'),
                onPrimary: _canUseBiometrics
                    ? () => _setBiometricFromAccount(!_biometricEnabled)
                    : null,
              );

              if (!isWide) {
                return Column(
                  children: [
                    pinTile,
                    const SizedBox(height: 12),
                    biometricTile,
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: pinTile),
                  const SizedBox(width: 12),
                  Expanded(child: biometricTile),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSecurityAccessTile({
    required IconData icon,
    required String title,
    required String description,
    required bool enabled,
    required Color color,
    required String actionLabel,
    required VoidCallback? onPrimary,
    String? secondaryLabel,
    VoidCallback? onSecondary,
  }) {
    final statusLabel = enabled
        ? context.loc.tr('screens_security_settings_screen.020')
        : context.loc.tr('screens_security_settings_screen.021');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppTheme.bodyBold),
                    const SizedBox(height: 4),
                    Text(
                      statusLabel,
                      style: AppTheme.caption.copyWith(
                        color: color,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            description,
            style: AppTheme.caption.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ShwakelButton(
                label: actionLabel,
                icon: icon,
                onPressed: onPrimary,
                height: 42,
                isSecondary: !enabled,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                fontSize: 13,
              ),
              if (secondaryLabel != null)
                ShwakelButton(
                  label: secondaryLabel,
                  icon: Icons.delete_outline_rounded,
                  onPressed: onSecondary,
                  height: 42,
                  isSecondary: true,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  fontSize: 13,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _createOrChangePinFromAccount() async {
    final l = context.loc;
    final wasPinEnabled = _hasPin;
    final confirmation = await TransferSecurityService.confirmTransfer(
      context,
      allowOtpFallback: true,
      allowNoPhoneAccount: true,
      otpPurpose: 'pin_security',
    );
    if (!mounted || !confirmation.isVerified) {
      return;
    }

    final pin = await _showAccountPinDialog(isEdit: wasPinEnabled);
    if (pin == null) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      final payload = await _apiService.updateSecurityPin(
        pin: pin,
        currentPin: confirmation.securityPin,
        otpCode: confirmation.otpCode,
      );
      final user = payload['user'];
      if (user is Map) {
        await _authService.cacheCurrentUser(Map<String, dynamic>.from(user));
      }
      await LocalSecurityService.savePin(pin);
      await _load();
      if (!mounted) {
        return;
      }
      await AppAlertService.showSuccess(
        context,
        title: wasPinEnabled ? 'تم تعديل PIN' : 'تم تفعيل PIN',
        message: 'تم تحديث حماية الدخول بنجاح.',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      await AppAlertService.showError(
        context,
        title: l.text('تعذر تحديث PIN', 'Failed to update PIN'),
        message: ErrorMessageService.sanitize(error),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _removePinFromAccount() async {
    final l = context.loc;
    if (!_hasPin) {
      return;
    }
    final confirmation = await TransferSecurityService.confirmTransfer(
      context,
      allowOtpFallback: true,
      otpPurpose: 'pin_security',
    );
    if (!mounted || !confirmation.isVerified) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.text('إلغاء PIN', 'Disable PIN')),
        content: Text(
          l.text(
            'سيتم إلغاء استخدام PIN في حماية الدخول والعمليات.',
            'PIN will be disabled from protecting login and transactions.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.loc.tr('shared.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l.text('إلغاء PIN', 'Disable PIN')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      final payload = await _apiService.removeSecurityPin(
        currentPin: confirmation.securityPin,
        otpCode: confirmation.otpCode,
      );
      final user = payload['user'];
      if (user is Map) {
        await _authService.cacheCurrentUser(Map<String, dynamic>.from(user));
      }
      await LocalSecurityService.removePin();
      await _load();
    } catch (error) {
      if (!mounted) {
        return;
      }
      await AppAlertService.showError(
        context,
        title: l.text('تعذر إلغاء PIN', 'Failed to disable PIN'),
        message: ErrorMessageService.sanitize(error),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _setBiometricFromAccount(bool value) async {
    if (!_canUseBiometrics) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      if (value && !await LocalSecurityService.authenticateWithBiometrics()) {
        return;
      }
      await LocalSecurityService.setBiometricEnabled(value);
      if (value) {
        await LocalSecurityService.markLocalUnlockCompleted();
      }
      await _load();
      if (!mounted) {
        return;
      }
      await AppAlertService.showSuccess(
        context,
        title: value ? 'تم تفعيل البصمة' : 'تم إلغاء البصمة',
        message: 'تم تحديث طريقة حماية الدخول.',
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<String?> _showAccountPinDialog({required bool isEdit}) async {
    final l = context.loc;
    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    var obscurePin = true;
    var obscureConfirm = true;
    String? errorText;

    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: Text(isEdit ? 'تعديل PIN' : 'تفعيل PIN'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: pinController,
                  maxLength: 4,
                  obscureText: obscurePin,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'PIN جديد',
                    prefixIcon: const Icon(Icons.pin_rounded),
                    errorText: errorText,
                    suffixIcon: IconButton(
                      onPressed: () =>
                          setDialogState(() => obscurePin = !obscurePin),
                      icon: Icon(
                        obscurePin
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: confirmController,
                  maxLength: 4,
                  obscureText: obscureConfirm,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l.text('تأكيد PIN', 'Confirm PIN'),
                    prefixIcon: const Icon(Icons.verified_user_rounded),
                    suffixIcon: IconButton(
                      onPressed: () => setDialogState(
                        () => obscureConfirm = !obscureConfirm,
                      ),
                      icon: Icon(
                        obscureConfirm
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(context.loc.tr('shared.cancel')),
              ),
              FilledButton.icon(
                onPressed: () {
                  final pin = pinController.text.trim();
                  final confirm = confirmController.text.trim();
                  if (!RegExp(r'^\d{4}$').hasMatch(pin) || pin != confirm) {
                    setDialogState(() => errorText = 'أدخل 4 أرقام متطابقة.');
                    return;
                  }
                  Navigator.pop(dialogContext, pin);
                },
                icon: const Icon(Icons.check_rounded),
                label: Text(l.text('حفظ', 'Save')),
              ),
            ],
          ),
        ),
      );
    } finally {
      pinController.dispose();
      confirmController.dispose();
    }
  }

  bool _canEditField(String fieldKey) {
    if (_user == null) {
      return false;
    }
    final verification =
        _user?['transferVerificationStatus']?.toString() ?? 'unverified';
    if (verification != 'approved') {
      return true;
    }
    return _editableProfileFields.contains(fieldKey);
  }

  Widget _buildBasicInfoCard() {
    final l = context.loc;
    return ShwakelCard(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.tr('screens_account_settings_screen.019'), style: AppTheme.h3),
          const SizedBox(height: 18),
          _field(
            l.tr('screens_account_settings_screen.080'),
            _businessNameController,
            Icons.storefront_rounded,
            enabled: _canEditField('businessName'),
          ),
          const SizedBox(height: 16),
          _field(
            l.tr('screens_account_settings_screen.020'),
            _fullNameController,
            Icons.badge_rounded,
            enabled: _canEditField('fullName'),
          ),
          const SizedBox(height: 16),
          _field(
            l.tr('screens_account_settings_screen.021'),
            _usernameController,
            Icons.alternate_email_rounded,
            enabled: _canEditField('username'),
          ),
          const SizedBox(height: 16),
          _field(
            l.tr('screens_account_settings_screen.022'),
            _whatsappController,
            Icons.phone_rounded,
            enabled: false,
          ),
          const SizedBox(height: 16),
          _field(
            l.tr('screens_account_settings_screen.023'),
            _emailController,
            Icons.email_rounded,
            enabled: _canEditField('email'),
          ),
          const SizedBox(height: 16),
          _field(
            l.tr('screens_account_settings_screen.024'),
            _addressController,
            Icons.location_on_rounded,
            enabled: _canEditField('address'),
            lines: 2,
          ),
        ],
      ),
    );
  }

  Widget _buildIdentityCard() {
    final l = context.loc;
    final isMobile = MediaQuery.of(context).size.width < 760;

    return ShwakelCard(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.tr('screens_account_settings_screen.025'), style: AppTheme.h3),
          const SizedBox(height: 18),
          _field(
            l.tr('screens_account_settings_screen.026'),
            _nationalIdController,
            Icons.credit_card_rounded,
            enabled: _canEditField('nationalId'),
          ),
          const SizedBox(height: 16),
          _field(
            l.tr('screens_account_settings_screen.027'),
            _birthDateController,
            Icons.cake_rounded,
            enabled: _canEditField('birthDate'),
            readOnly: true,
            onTap: _canEditField('birthDate') ? _pickDate : null,
          ),
          const SizedBox(height: 16),
          _field(
            l.tr('screens_account_settings_screen.028'),
            _referralPhoneController,
            Icons.call_split_rounded,
            enabled: _canEditField('referralPhone'),
          ),
          if (!isMobile) const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildLockedNotice() {
    final l = context.loc;
    return ShwakelCard(
      padding: const EdgeInsets.all(16),
      color: AppTheme.warning.withValues(alpha: 0.06),
      borderColor: AppTheme.warning.withValues(alpha: 0.18),
      child: Row(
        children: [
          const Icon(Icons.lock_person_rounded, color: AppTheme.warning),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l.tr('screens_account_settings_screen.047'),
              style: AppTheme.bodyText.copyWith(
                color: AppTheme.warning,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompletionNotice() {
    final l = context.loc;
    return ShwakelCard(
      padding: const EdgeInsets.all(16),
      color: AppTheme.secondary.withValues(alpha: 0.08),
      borderColor: AppTheme.secondary.withValues(alpha: 0.16),
      child: Row(
        children: [
          const Icon(Icons.edit_note_rounded, color: AppTheme.secondary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l.tr('screens_account_settings_screen.048'),
              style: AppTheme.bodyText.copyWith(
                color: AppTheme.secondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller,
    IconData icon, {
    bool enabled = true,
    bool obscure = false,
    bool readOnly = false,
    VoidCallback? onTap,
    int lines = 1,
  }) {
    return TextField(
      controller: controller,
      enabled: enabled,
      obscureText: obscure,
      readOnly: readOnly,
      onTap: onTap,
      maxLines: lines,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20),
        suffixIcon: enabled
            ? null
            : const Icon(Icons.lock_outline_rounded, size: 18),
        filled: !enabled,
        fillColor: enabled ? null : AppTheme.background,
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(2000),
      firstDate: DateTime(1950),
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      _birthDateController.text = picked.toIso8601String().split('T').first;
    });
  }
}
