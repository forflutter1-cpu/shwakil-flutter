import 'dart:async';

import 'package:flutter/material.dart';

import '../localization/index.dart';
import '../utils/app_theme.dart';
import 'api_service.dart';
import 'auth_service.dart';
import 'local_security_service.dart';
import '../widgets/responsive_scaffold_container.dart';
import '../widgets/shwakel_card.dart';

class TransferSecurityResult {
  const TransferSecurityResult({
    required this.isVerified,
    this.method,
    this.otpCode,
    this.securityPin,
  });

  final bool isVerified;
  final String? method;
  final String? otpCode;
  final String? securityPin;
}

class TransferSecurityService {
  TransferSecurityService._();

  static Widget _buildDialogActionBar(List<Widget> children) {
    return SizedBox(
      width: double.infinity,
      child: OverflowBar(
        alignment: MainAxisAlignment.end,
        spacing: 12,
        overflowSpacing: 12,
        children: children,
      ),
    );
  }

  static Future<TransferSecurityResult> confirmTransfer(
    BuildContext context, {
    bool requireOtpAfterLocalAuth = false,
    bool allowOtpFallback = false,
    bool allowNoPhoneAccount = false,
    String otpPurpose = 'transfer_security',
  }) async {
    final hasPin = await LocalSecurityService.hasPin();
    if (allowNoPhoneAccount && !hasPin) {
      final user = await AuthService().currentUser();
      final whatsapp = user?['whatsapp']?.toString().trim() ?? '';
      if (whatsapp.isEmpty) {
        return const TransferSecurityResult(
          isVerified: true,
          method: 'no_phone_account',
        );
      }
    }
    final biometricEnabled = await LocalSecurityService.isBiometricEnabled();
    final canUseBiometrics =
        biometricEnabled && await LocalSecurityService.canUseBiometrics();

    if (!context.mounted) {
      return const TransferSecurityResult(isVerified: false);
    }

    // Prefer the OS biometric prompt whenever it is enabled and available.
    // If the user cancels/fails it, continue with the configured PIN (when
    // present) before considering the SMS/OTP fallback.
    if (canUseBiometrics) {
      final biometricOk =
          await LocalSecurityService.authenticateWithBiometrics();
      if (biometricOk) {
        if (!context.mounted) {
          return const TransferSecurityResult(isVerified: false);
        }
        return const TransferSecurityResult(
          isVerified: true,
          method: 'biometric',
        );
      }
      if (!context.mounted) {
        return const TransferSecurityResult(isVerified: false);
      }
    }

    if (hasPin) {
      final pinResult = await _confirmWithPin(
        context,
        // Biometrics have already been attempted above.  After cancellation,
        // show the PIN path directly instead of prompting for the fingerprint
        // a second time from inside the PIN dialog.
        canUseBiometrics: false,
      );
      if (!context.mounted) {
        return const TransferSecurityResult(isVerified: false);
      }
      // A successful biometric prompt is already a second, OS-backed local
      // factor.  It must not fall through to the OTP/SMS step (the SMS
      // gateway may be unavailable).  Keep the optional extra OTP step only
      // for confirmations that were actually completed with the account PIN.
      if (pinResult.isVerified &&
          requireOtpAfterLocalAuth &&
          pinResult.method != 'biometric') {
        return _confirmWithOtp(
          context,
          introText: context.loc.tr('services_transfer_security_service.002'),
          otpPurpose: otpPurpose,
        );
      }
      // A cancelled or unavailable PIN may use the explicitly enabled OTP
      // fallback, but never combine PIN and OTP for the same operation.
      if (!pinResult.isVerified && allowOtpFallback) {
        return _confirmWithOtp(context, otpPurpose: otpPurpose);
      }
      return pinResult;
    }

    if (!context.mounted) {
      return const TransferSecurityResult(isVerified: false);
    }

    if (!allowOtpFallback) {
      await _showLocalSecurityRequiredDialog(context);
      return const TransferSecurityResult(isVerified: false);
    }

    return _confirmWithOtp(context, otpPurpose: otpPurpose);
  }

  static Future<void> _showLocalSecurityRequiredDialog(
    BuildContext context,
  ) async {
    final l = context.loc;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.tr('services_transfer_security_service.019')),
        content: Text(l.tr('services_transfer_security_service.020')),
        actions: [
          _buildDialogActionBar([
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l.tr('services_transfer_security_service.007')),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                Navigator.of(context).pushNamed('/security-settings');
              },
              child: Text(l.tr('services_transfer_security_service.021')),
            ),
          ]),
        ],
      ),
    );
  }

  static Future<TransferSecurityResult> _confirmWithPin(
    BuildContext context, {
    required bool canUseBiometrics,
  }) async {
    final l = context.loc;
    final pinController = TextEditingController();
    var isChecking = false;
    String? errorText;

    final result = await showDialog<TransferSecurityResult>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) {
          Future<void> submitPin() async {
            final pin = pinController.text.trim();
            if (pin.length != 4) {
              setState(
                () => errorText = l.tr('screens_device_unlock_screen.002'),
              );
              return;
            }
            setState(() {
              isChecking = true;
              errorText = null;
            });
            final isValid = await LocalSecurityService.verifyPin(pin);
            if (!dialogContext.mounted) {
              return;
            }
            if (isValid) {
              await LocalSecurityService.setLastLocalAuthMethod('pin');
            }
            if (!dialogContext.mounted) {
              return;
            }
            if (isValid) {
              Navigator.pop(
                dialogContext,
                TransferSecurityResult(
                  isVerified: true,
                  method: 'pin',
                  securityPin: pin,
                ),
              );
              return;
            }

            final retryAfterSeconds =
                await LocalSecurityService.pinRetryAfterSeconds();
            if (!dialogContext.mounted) {
              return;
            }
            setState(() {
              isChecking = false;
              errorText = retryAfterSeconds > 0
                  ? l.tr(
                      'screens_device_unlock_screen.014',
                      params: {'seconds': '$retryAfterSeconds'},
                    )
                  : l.tr('screens_device_unlock_screen.004');
            });
          }

          Future<void> submitBiometric() async {
            setState(() {
              isChecking = true;
              errorText = null;
            });
            final ok = await LocalSecurityService.authenticateWithBiometrics();
            if (!dialogContext.mounted) {
              return;
            }
            if (ok) {
              Navigator.pop(
                dialogContext,
                const TransferSecurityResult(
                  isVerified: true,
                  method: 'biometric',
                ),
              );
              return;
            }
            setState(() => isChecking = false);
          }

          return AlertDialog(
            title: Text(
              context.loc.tr('services_transfer_security_service.003'),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  canUseBiometrics
                      ? context.loc.tr('services_transfer_security_service.004')
                      : context.loc.tr(
                          'services_transfer_security_service.005',
                        ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: pinController,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: l.tr('services_transfer_security_service.006'),
                    prefixIcon: const Icon(Icons.pin_outlined),
                  ),
                  onChanged: (_) {
                    if (errorText == null) {
                      return;
                    }
                    setState(() => errorText = null);
                  },
                  onSubmitted: (_) => submitPin(),
                ),
                if (errorText != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    errorText!,
                    style: const TextStyle(
                      color: Color(0xFFDC2626),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              _buildDialogActionBar([
                TextButton(
                  onPressed: isChecking
                      ? null
                      : () => Navigator.pop(
                          dialogContext,
                          const TransferSecurityResult(isVerified: false),
                        ),
                  child: Text(
                    context.loc.tr('services_transfer_security_service.007'),
                  ),
                ),
                if (canUseBiometrics)
                  OutlinedButton.icon(
                    onPressed: isChecking ? null : submitBiometric,
                    icon: const Icon(Icons.fingerprint_rounded),
                    label: Text(
                      context.loc.tr('services_transfer_security_service.008'),
                    ),
                  ),
                ElevatedButton(
                  onPressed: isChecking ? null : submitPin,
                  child: Text(
                    context.loc.tr('services_transfer_security_service.009'),
                  ),
                ),
              ]),
            ],
          );
        },
      ),
    );

    pinController.dispose();
    return result ?? const TransferSecurityResult(isVerified: false);
  }

  static Future<TransferSecurityResult> _confirmWithOtp(
    BuildContext context, {
    String? introText,
    String otpPurpose = 'transfer_security',
  }) async {
    final result = await Navigator.of(context).push<TransferSecurityResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _TransferSecurityOtpScreen(
          introText: introText,
          otpPurpose: otpPurpose,
        ),
      ),
    );
    return result ?? const TransferSecurityResult(isVerified: false);
  }
}

class _TransferSecurityOtpScreen extends StatefulWidget {
  const _TransferSecurityOtpScreen({
    this.introText,
    this.otpPurpose = 'transfer_security',
  });

  final String? introText;
  final String otpPurpose;

  @override
  State<_TransferSecurityOtpScreen> createState() =>
      _TransferSecurityOtpScreenState();
}

class _TransferSecurityOtpScreenState
    extends State<_TransferSecurityOtpScreen> {
  final _codeController = TextEditingController();
  final _api = ApiService();
  Timer? _timer;
  String? _infoText;
  String? _errorText;
  String? _debugCode;
  int _cooldown = 0;
  bool _sending = false;
  bool _sent = false;

  @override
  void initState() {
    super.initState();
    _infoText = widget.introText;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sendOtp();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _cooldown = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _cooldown <= 1) {
        timer.cancel();
        if (mounted) setState(() => _cooldown = 0);
        return;
      }
      setState(() => _cooldown--);
    });
  }

  Future<void> _sendOtp() async {
    if (_sending || (_sent && _cooldown > 0)) return;
    setState(() {
      _sending = true;
      _errorText = null;
    });
    try {
      final result = await _api.requestTransferSecurityOtp(
        purpose: widget.otpPurpose,
      );
      if (!mounted) return;
      if (result.otpRequired == false) {
        Navigator.of(context).pop(
          const TransferSecurityResult(
            isVerified: true,
            method: 'no_phone_account',
          ),
        );
        return;
      }
      setState(() {
        _sent = true;
        _sending = false;
        _debugCode = result.debugOtpCode;
        _infoText = result.debugOtpCode == null
            ? context.loc.tr('services_transfer_security_service.011')
            : context.loc.tr(
                'services_transfer_security_service.012',
                params: {'code': result.debugOtpCode ?? ''},
              );
      });
      _startCooldown();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _errorText = error.toString();
      });
    }
  }

  void _verify() {
    final code = _codeController.text.trim();
    if (code.length < 4) {
      setState(
        () => _errorText = context.loc.tr(
          'services_transfer_security_service.014',
        ),
      );
      return;
    }
    Navigator.of(context).pop(
      TransferSecurityResult(isVerified: true, method: 'otp', otpCode: code),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.loc;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.tr('services_transfer_security_service.013')),
        leading: IconButton(
          tooltip: l.tr('services_transfer_security_service.007'),
          onPressed: _sending
              ? null
              : () => Navigator.of(
                  context,
                ).pop(const TransferSecurityResult(isVerified: false)),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: ResponsiveScaffoldContainer(
        maxWidth: 560,
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
        child: ShwakelCard(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.sms_rounded, size: 54, color: AppTheme.primary),
              const SizedBox(height: 18),
              Text(
                _infoText ?? l.tr('services_transfer_security_service.010'),
                textAlign: TextAlign.center,
                style: AppTheme.bodyAction,
              ),
              if (_debugCode != null) ...[
                const SizedBox(height: 12),
                Text(
                  l.tr(
                    'services_transfer_security_service.012',
                    params: {'code': _debugCode!},
                  ),
                  textAlign: TextAlign.center,
                  style: AppTheme.caption.copyWith(color: AppTheme.warning),
                ),
              ],
              const SizedBox(height: 24),
              TextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                style: AppTheme.h1.copyWith(color: AppTheme.primary),
                decoration: InputDecoration(
                  labelText: l.tr('services_transfer_security_service.014'),
                  prefixIcon: const Icon(Icons.password_rounded),
                  counterText: '',
                ),
                onSubmitted: (_) => _verify(),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 10),
                Text(
                  _errorText!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red),
                ),
              ],
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: _sending ? null : _verify,
                icon: const Icon(Icons.verified_rounded),
                label: Text(l.tr('services_transfer_security_service.009')),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: _sending || _cooldown > 0 ? null : _sendOtp,
                child: Text(
                  _sending
                      ? l.tr('services_transfer_security_service.015')
                      : _cooldown > 0
                      ? l.tr(
                          'services_transfer_security_service.018',
                          params: {'seconds': '$_cooldown'},
                        )
                      : l.tr('services_transfer_security_service.016'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
