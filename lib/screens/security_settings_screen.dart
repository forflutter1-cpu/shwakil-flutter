import 'package:flutter/material.dart';

import '../services/index.dart';
import '../utils/app_theme.dart';
import '../widgets/app_sidebar.dart';
import '../widgets/app_top_actions.dart';
import '../widgets/responsive_scaffold_container.dart';
import '../widgets/shwakel_button.dart';
import '../widgets/shwakel_card.dart';

class SecuritySettingsScreen extends StatefulWidget {
  const SecuritySettingsScreen({super.key, this.showSetupHint = false});

  final bool showSetupHint;

  @override
  State<SecuritySettingsScreen> createState() => _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState extends State<SecuritySettingsScreen> {
  final AuthService _authService = AuthService();
  final ApiService _apiService = ApiService();

  bool _isLoading = true;
  bool _hasPin = false;
  bool _biometricEnabled = false;
  bool _canUseBiometrics = false;
  bool _isTrustedDevice = false;
  String _trustedUsername = '';
  String _lastAuthMethod = '';
  int _relockTimeout = 30;
  List<Map<String, dynamic>> _devices = const [];
  String? _busyDeviceId;
  bool _isUpdatingBiometric = false;
  bool _isUpdatingPin = false;
  bool _showSetupHint = false;
  bool _routeArgsApplied = false;
  bool _hintDialogShown = false;

  @override
  void initState() {
    super.initState();
    _load();
    LocalSecurityService.securityStateListenable.addListener(_onChanged);
  }

  @override
  void dispose() {
    LocalSecurityService.securityStateListenable.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => _load();

  Future<void> _load() async {
    final hasPin = await LocalSecurityService.hasPin();
    final canUseBiometrics = await LocalSecurityService.canUseBiometrics();
    final biometricEnabled =
        await LocalSecurityService.isBiometricEnabled() && canUseBiometrics;
    final isTrustedDevice = await LocalSecurityService.isTrustedDevice();
    final trustedUsername = await LocalSecurityService.trustedUsername() ?? '';
    final lastAuthMethod =
        await LocalSecurityService.lastLocalAuthMethod() ?? '';
    final relockTimeout = await LocalSecurityService.relockTimeoutInSeconds();

    List<Map<String, dynamic>> devices = const [];
    try {
      final payload = await _apiService.getMyDevices();
      devices = List<Map<String, dynamic>>.from(
        (payload['devices'] as List? ?? const []).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
    } catch (_) {}

    if (!mounted) {
      return;
    }
    setState(() {
      _hasPin = hasPin;
      _biometricEnabled = biometricEnabled;
      _canUseBiometrics = canUseBiometrics;
      _isTrustedDevice = isTrustedDevice;
      _trustedUsername = trustedUsername;
      _lastAuthMethod = lastAuthMethod;
      _relockTimeout = relockTimeout;
      _devices = devices;
      _isLoading = false;
    });
  }

  String _lastAuthMethodLabel(AppLocalizer l) {
    if (_lastAuthMethod == 'biometric') {
      return l.tr('screens_security_settings_screen.010');
    }
    if (_lastAuthMethod == 'pin') {
      return l.tr('screens_security_settings_screen.011');
    }
    return l.tr('screens_security_settings_screen.012');
  }

  String _biometricDescription(AppLocalizer l) {
    if (!_canUseBiometrics) {
      return l.tr('screens_security_settings_screen.024');
    }
    if (_hasPin) {
      return l.tr('screens_security_settings_screen.022');
    }
    return l.tr('screens_security_settings_screen.023');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_routeArgsApplied) {
      return;
    }
    _routeArgsApplied = true;
    _showSetupHint = widget.showSetupHint;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map && args['showSetupHint'] == true) {
      _showSetupHint = true;
    }
    if (_showSetupHint && !_hintDialogShown) {
      _hintDialogShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _showSetupWarningDialog();
      });
    }
  }

  Future<void> _showSetupWarningDialog() async {
    final l = context.loc;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.tr('screens_security_settings_screen.072')),
        content: Text(l.tr('screens_security_settings_screen.073')),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l.tr('screens_login_screen.020')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.loc;
    if (_isLoading) {
      return const ShwakelPageLoadingScaffold();
    }

    return DefaultTabController(
      length: 3,
      initialIndex: 1,
      child: Builder(
        builder: (context) {
          final tabController = DefaultTabController.of(context);
          return AnimatedBuilder(
            animation: tabController,
            builder: (context, _) {
              Widget currentTab;
              switch (tabController.index) {
                case 1:
                  currentTab = _buildPinTab();
                  break;
                case 2:
                  currentTab = _buildDevicesTab();
                  break;
                case 0:
                default:
                  currentTab = Column(
                    children: [
                      _buildStatusOverview(),
                      const SizedBox(height: 16),
                      _buildTimeoutSection(),
                    ],
                  );
              }

              return Scaffold(
                backgroundColor: AppTheme.background,
                appBar: AppBar(
                  title: Text(l.tr('screens_security_settings_screen.001')),
                  actions: const [AppNotificationAction(), QuickLogoutAction()],
                ),
                drawer: AppSidebar.drawerFor(context),
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(AppTheme.spacingLg),
                  child: ResponsiveScaffoldContainer(
                    padding: EdgeInsets.zero,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_showSetupHint) ...[
                          _buildSetupHintCard(),
                          const SizedBox(height: 18),
                        ],
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppTheme.surface,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: AppTheme.borderLight),
                          ),
                          child: TabBar(
                            isScrollable: true,
                            tabAlignment: TabAlignment.start,
                            dividerColor: Colors.transparent,
                            indicatorSize: TabBarIndicatorSize.tab,
                            indicatorPadding: const EdgeInsets.all(6),
                            tabs: [
                              Tab(
                                text: l.tr(
                                  'screens_security_settings_screen.065',
                                ),
                                icon: const Icon(Icons.shield_rounded),
                              ),
                              Tab(
                                text: l.tr(
                                  'screens_security_settings_screen.066',
                                ),
                                icon: const Icon(Icons.pin_rounded),
                              ),
                              Tab(
                                text: l.tr(
                                  'screens_security_settings_screen.067',
                                ),
                                icon: const Icon(Icons.devices_rounded),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),
                        currentTab,
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildSetupHintCard() {
    final l = context.loc;
    return ShwakelCard(
      padding: const EdgeInsets.all(18),
      color: AppTheme.primarySoft.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(22),
      borderColor: AppTheme.primary.withValues(alpha: 0.14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.lock_person_rounded,
              color: AppTheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.tr('screens_security_settings_screen.072'),
                  style: AppTheme.bodyBold.copyWith(color: AppTheme.primary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPinTab() {
    final l = context.loc;
    return Column(
      children: [
        _buildPinSection(),
        if (_isTrustedDevice) ...[
          const SizedBox(height: 16),
          ShwakelButton(
            label: l.tr('screens_security_settings_screen.002'),
            icon: Icons.phonelink_erase_rounded,
            isSecondary: true,
            onPressed: _clearTrusted,
            width: double.infinity,
          ),
        ],
      ],
    );
  }

  Widget _buildDevicesTab() {
    return _buildDevicesSection();
  }

  Widget _buildStatusOverview() {
    final l = context.loc;
    return ShwakelCard(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.tr('screens_security_settings_screen.014'),
            style: AppTheme.h3,
          ),
          const SizedBox(height: 18),
          _statusLine(
            l.tr('screens_security_settings_screen.016'),
            _isTrustedDevice
                ? l.tr('screens_security_settings_screen.017')
                : l.tr('screens_security_settings_screen.018'),
            _isTrustedDevice ? AppTheme.success : AppTheme.error,
          ),
          _statusLine(
            l.tr('screens_security_settings_screen.019'),
            _hasPin
                ? l.tr('screens_security_settings_screen.020')
                : l.tr('screens_security_settings_screen.021'),
            _hasPin ? AppTheme.success : AppTheme.warning,
          ),
          _statusLine(
            l.tr('screens_security_settings_screen.010'),
            _biometricEnabled
                ? l.tr('screens_security_settings_screen.020')
                : l.tr('screens_security_settings_screen.021'),
            _biometricEnabled ? AppTheme.success : AppTheme.textTertiary,
          ),
          _statusLine(
            l.tr('screens_security_settings_screen.025'),
            _lastAuthMethodLabel(l),
            AppTheme.primary,
          ),
          if (_trustedUsername.isNotEmpty)
            _statusLine(
              l.tr('screens_security_settings_screen.026'),
              '@$_trustedUsername',
              AppTheme.primary,
            ),
        ],
      ),
    );
  }

  Widget _buildPinSection() {
    final l = context.loc;
    return ShwakelCard(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.tr('screens_security_settings_screen.027'),
            style: AppTheme.h3,
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: AppTheme.primary.withValues(alpha: 0.10),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l.tr('screens_security_settings_screen.019'),
                            style: AppTheme.bodyBold,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l.tr('screens_security_settings_screen.031'),
                            style: AppTheme.caption,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Switch(
                      value: _hasPin,
                      onChanged: _isUpdatingPin ? null : _togglePin,
                      activeThumbColor: AppTheme.primary,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isCompact = constraints.maxWidth < 420;
                    final primaryAction = ShwakelButton(
                      label: _hasPin
                          ? l.tr('screens_security_settings_screen.029')
                          : l.tr('screens_security_settings_screen.030'),
                      icon: Icons.pin_rounded,
                      onPressed: _createOrChangePin,
                      isSecondary: true,
                      height: 46,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      fontSize: 14,
                      width: isCompact ? double.infinity : null,
                    );
                    final removeAction = ShwakelButton(
                      label: l.tr('screens_security_settings_screen.064'),
                      icon: Icons.delete_outline_rounded,
                      onPressed: (_hasPin && !_isUpdatingPin)
                          ? _removePin
                          : null,
                      isSecondary: true,
                      height: 46,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      fontSize: 14,
                      width: isCompact ? double.infinity : null,
                    );

                    if (!_hasPin) {
                      return primaryAction;
                    }

                    if (isCompact) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          primaryAction,
                          const SizedBox(height: 10),
                          removeAction,
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(child: primaryAction),
                        const SizedBox(width: 10),
                        Expanded(child: removeAction),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.secondary.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: AppTheme.secondary.withValues(alpha: 0.10),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.tr('screens_security_settings_screen.034'),
                        style: AppTheme.bodyBold,
                      ),
                      const SizedBox(height: 4),
                      Text(_biometricDescription(l), style: AppTheme.caption),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Switch(
                  value: _biometricEnabled,
                  onChanged: (_canUseBiometrics && !_isUpdatingBiometric)
                      ? _toggleBiometric
                      : null,
                  activeThumbColor: AppTheme.primary,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeoutSection() {
    final l = context.loc;
    return ShwakelCard(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.tr('screens_security_settings_screen.035'),
            style: AppTheme.h3,
          ),
          const SizedBox(height: 18),
          DropdownButtonFormField<int>(
            initialValue: _relockTimeout,
            items: LocalSecurityService.relockTimeoutOptionsInSeconds
                .map(
                  (seconds) => DropdownMenuItem(
                    value: seconds,
                    child: Text(_timeoutLabel(seconds)),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value != null) {
                _updateTimeout(value);
              }
            },
            decoration: InputDecoration(
              labelText: l.tr('screens_security_settings_screen.037'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDevicesSection() {
    final l = context.loc;
    return ShwakelCard(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.tr('screens_security_settings_screen.038'),
            style: AppTheme.h3,
          ),
          const SizedBox(height: 18),
          if (_devices.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.08),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.devices_other_rounded,
                    color: AppTheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l.tr('screens_security_settings_screen.040'),
                      style: AppTheme.bodyText,
                    ),
                  ),
                ],
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _devices.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) =>
                  _buildDeviceTile(_devices[index]),
            ),
        ],
      ),
    );
  }

  Widget _buildDeviceTile(Map<String, dynamic> device) {
    final l = context.loc;
    final isActive = device['isActiveDevice'] == true;
    final isBusy = _busyDeviceId == device['id']?.toString();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isActive
              ? AppTheme.primary.withValues(alpha: 0.25)
              : Colors.transparent,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            backgroundColor: (isActive ? AppTheme.primary : AppTheme.secondary)
                .withValues(alpha: 0.12),
            child: Icon(
              Icons.smartphone_rounded,
              color: isActive ? AppTheme.primary : AppTheme.secondary,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device['deviceName']?.toString() ??
                      l.tr('screens_security_settings_screen.041'),
                  style: AppTheme.bodyBold,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  l.tr(
                    'screens_security_settings_screen.042',
                    params: {'id': '${device['deviceId'] ?? '-'}'},
                  ),
                  style: AppTheme.caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (isActive) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      l.tr('screens_security_settings_screen.043'),
                      style: AppTheme.caption.copyWith(
                        color: AppTheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: l.tr('screens_security_settings_screen.044'),
            onPressed: isBusy ? null : () => _releaseDevice(device),
            icon: isBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(
                    Icons.delete_outline_rounded,
                    color: AppTheme.error,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _statusLine(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: Text(label, style: AppTheme.bodyAction)),
          const SizedBox(width: 12),
          Text(value, style: AppTheme.bodyBold.copyWith(color: color)),
        ],
      ),
    );
  }

  String _timeoutLabel(int seconds) {
    final l = context.loc;
    if (seconds == 0) {
      return l.tr('screens_security_settings_screen.045');
    }
    if (seconds < 60) {
      return l.tr(
        'screens_security_settings_screen.046',
        params: {'count': '$seconds'},
      );
    }
    return l.tr(
      'screens_security_settings_screen.047',
      params: {'count': '${seconds ~/ 60}'},
    );
  }

  Future<void> _createOrChangePin() async {
    final wasPinEnabled = _hasPin;
    final confirmation = await TransferSecurityService.confirmTransfer(
      context,
      allowOtpFallback: true,
      otpPurpose: 'pin_security',
    );
    if (!mounted || !confirmation.isVerified) {
      return;
    }
    final pin = await showDialog<String>(
      context: context,
      builder: (_) => _StyledPinDialog(isEdit: _hasPin),
    );
    if (pin != null && pin.length == 4) {
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
      } catch (error) {
        if (!mounted) {
          return;
        }
        await AppAlertService.showError(
          context,
          title: context.loc.tr('screens_security_settings_screen.060'),
          message: ErrorMessageService.sanitize(error),
        );
        return;
      }
      await LocalSecurityService.savePin(pin);
      if (!wasPinEnabled) {
        await _returnHomeAfterSecuritySetup();
        return;
      }
      await _load();
    }
  }

  Future<void> _togglePin(bool value) async {
    setState(() => _isUpdatingPin = true);
    try {
      if (value) {
        await _createOrChangePin();
        return;
      }
      await _removePin();
    } finally {
      if (mounted) {
        setState(() => _isUpdatingPin = false);
      }
    }
  }

  Future<void> _removePin() async {
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

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.tr('screens_security_settings_screen.062')),
        content: Text(l.tr('screens_security_settings_screen.063')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.tr('screens_security_settings_screen.050')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.tr('screens_security_settings_screen.064')),
          ),
        ],
      ),
    );

    if (confirm != true) {
      return;
    }

    try {
      final payload = await _apiService.removeSecurityPin(
        currentPin: confirmation.securityPin,
        otpCode: confirmation.otpCode,
      );
      final user = payload['user'];
      if (user is Map) {
        await _authService.cacheCurrentUser(Map<String, dynamic>.from(user));
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      await AppAlertService.showError(
        context,
        title: context.loc.tr('screens_security_settings_screen.060'),
        message: ErrorMessageService.sanitize(error),
      );
      return;
    }
    await LocalSecurityService.removePin();
    await _load();
  }

  Future<void> _toggleBiometric(bool value) async {
    setState(() => _isUpdatingBiometric = true);
    try {
      if (value && !await LocalSecurityService.authenticateWithBiometrics()) {
        return;
      }
      await LocalSecurityService.setBiometricEnabled(value);
      if (value) {
        await LocalSecurityService.markLocalUnlockCompleted();
        await _returnHomeAfterSecuritySetup();
        return;
      }
      await _load();
    } finally {
      if (mounted) {
        setState(() => _isUpdatingBiometric = false);
      }
    }
  }

  Future<void> _updateTimeout(int seconds) async {
    await LocalSecurityService.setRelockTimeoutInSeconds(seconds);
    _load();
  }

  Future<void> _releaseDevice(Map<String, dynamic> device) async {
    final l = context.loc;
    final id = device['id']?.toString();
    if (id == null || id.isEmpty) {
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.tr('screens_security_settings_screen.048')),
        content: Text(l.tr('screens_security_settings_screen.049')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.tr('screens_security_settings_screen.050')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.tr('screens_security_settings_screen.051')),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) {
      return;
    }

    setState(() => _busyDeviceId = id);
    try {
      final response = await _apiService.releaseMyDevice(deviceRecordId: id);
      if (!mounted) {
        return;
      }
      setState(() {
        _devices = List<Map<String, dynamic>>.from(
          (response['devices'] as List? ?? const []).map(
            (item) => Map<String, dynamic>.from(item as Map),
          ),
        );
      });
      AppAlertService.showSuccess(
        context,
        title: l.tr('screens_security_settings_screen.052'),
        message:
            response['message']?.toString() ??
            l.tr('screens_security_settings_screen.053'),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppAlertService.showError(
        context,
        title: l.tr('screens_security_settings_screen.054'),
        message: ErrorMessageService.sanitize(error),
      );
    } finally {
      if (mounted) {
        setState(() => _busyDeviceId = null);
      }
    }
  }

  Future<void> _clearTrusted() async {
    await _authService.logout();
    await LocalSecurityService.clearTrustedState();
    if (!mounted) {
      return;
    }
    Navigator.pushReplacementNamed(context, '/login');
  }

  Future<void> _returnHomeAfterSecuritySetup() async {
    await LocalSecurityService.skipNextUnlock();
    await LocalSecurityService.clearRelockRequirement();
    if (!mounted) {
      return;
    }
    Navigator.pushNamedAndRemoveUntil(context, '/home', (route) => false);
  }
}

class _StyledPinDialog extends StatefulWidget {
  const _StyledPinDialog({required this.isEdit});

  final bool isEdit;

  @override
  State<_StyledPinDialog> createState() => _StyledPinDialogState();
}

class _StyledPinDialogState extends State<_StyledPinDialog> {
  final TextEditingController _pinController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();
  bool _obscurePin = true;
  bool _obscureConfirm = true;

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.loc;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: ShwakelCard(
          padding: const EdgeInsets.all(24),
          borderRadius: BorderRadius.circular(28),
          shadowLevel: ShwakelShadowLevel.premium,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Icon(
                        Icons.pin_rounded,
                        color: AppTheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.isEdit
                            ? l.tr('screens_security_settings_screen.055')
                            : l.tr('screens_security_settings_screen.056'),
                        style: AppTheme.h3,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  l.tr('screens_security_settings_screen.031'),
                  style: AppTheme.bodyAction,
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _pinController,
                  maxLength: 4,
                  obscureText: _obscurePin,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l.tr('screens_security_settings_screen.057'),
                    prefixIcon: const Icon(Icons.password_rounded),
                    suffixIcon: IconButton(
                      onPressed: () {
                        setState(() => _obscurePin = !_obscurePin);
                      },
                      icon: Icon(
                        _obscurePin
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _confirmController,
                  maxLength: 4,
                  obscureText: _obscureConfirm,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: l.tr('screens_security_settings_screen.058'),
                    prefixIcon: const Icon(Icons.verified_user_rounded),
                    suffixIcon: IconButton(
                      onPressed: () {
                        setState(() => _obscureConfirm = !_obscureConfirm);
                      },
                      icon: Icon(
                        _obscureConfirm
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isCompact = constraints.maxWidth < 360;
                    if (isCompact) {
                      return Column(
                        children: [
                          ShwakelButton(
                            label: l.tr('screens_security_settings_screen.059'),
                            onPressed: _submit,
                          ),
                          const SizedBox(height: 10),
                          ShwakelButton(
                            label: l.tr('screens_security_settings_screen.050'),
                            isSecondary: true,
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(
                          child: ShwakelButton(
                            label: l.tr('screens_security_settings_screen.050'),
                            isSecondary: true,
                            onPressed: () => Navigator.pop(context),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ShwakelButton(
                            label: l.tr('screens_security_settings_screen.059'),
                            onPressed: _submit,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _submit() {
    final l = context.loc;
    if (_pinController.text.length != 4 ||
        _pinController.text != _confirmController.text) {
      AppAlertService.showError(
        context,
        title: l.tr('screens_security_settings_screen.060'),
        message: l.tr('screens_security_settings_screen.061'),
      );
      return;
    }
    Navigator.pop(context, _pinController.text);
  }
}
