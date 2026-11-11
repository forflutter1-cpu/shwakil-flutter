import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

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

class CardPrintRequestsScreen extends StatefulWidget {
  const CardPrintRequestsScreen({super.key});

  @override
  State<CardPrintRequestsScreen> createState() =>
      _CardPrintRequestsScreenState();
}

class _CardPrintRequestsScreenState extends State<CardPrintRequestsScreen> {
  static const Map<String, int> _cardTypeDisplayOrder = {
    'standard': 0,
    'single_use': 1,
    'appointment': 2,
    'queue': 3,
  };

  final ApiService _apiService = ApiService();
  final AuthService _authService = AuthService();

  List<Map<String, dynamic>> _requests = const [];
  Map<String, dynamic> _usageReport = const {};
  Map<String, dynamic>? _user;
  Map<String, dynamic> _feeSettings = const {};
  bool _isLoading = true;
  bool _isLoadingRequests = true;
  bool _isAuthorized = false;
  bool _isSubmitting = false;

  Map<String, dynamic> get _subUserOperationalLimits =>
      Map<String, dynamic>.from(
        _user?['subUserOperationalLimits'] as Map? ?? const {},
      );

  bool get _isSubUser => _user?['isSubUser'] == true;

  double? _limitAsDouble(String key) =>
      (_subUserOperationalLimits[key] as num?)?.toDouble();

  bool get _isVerifiedAccount =>
      (_user?['transferVerificationStatus']?.toString() ?? 'unverified') ==
      'approved';
  int get _minimumCardQuantity {
    final raw = (_user?['cardOperationMinQuantity'] as num?)?.toInt() ?? 1;
    return raw < 1 ? 1 : raw;
  }

  String _subUserPrintLimitMessage(BuildContext context) {
    final l = context.loc;
    final limit = CurrencyFormatter.ils(
      _limitAsDouble('printRequestMaxAmount') ?? 0,
    );
    final rawDebtLimit = _limitAsDouble('printingDebtLimit') ?? 0;
    if (rawDebtLimit > 0) {
      return l.tr(
        'screens_card_print_requests_screen.049',
        params: {
          'limit': limit,
          'debtLimit': CurrencyFormatter.ils(rawDebtLimit),
        },
      );
    }

    return l.tr(
      'screens_card_print_requests_screen.054',
      params: {'limit': limit},
    );
  }

  String _cardTypeLabel(BuildContext context, String cardType) {
    final l = context.loc;
    return switch (cardType) {
      'single_use' => l.tr('screens_card_print_requests_screen.027'),
      'delivery' => l.tr('shared.delivery_card_label'),
      'appointment' => l.tr('screens_card_print_requests_screen.055'),
      'queue' => l.tr('screens_card_print_requests_screen.056'),
      _ => l.tr('screens_card_print_requests_screen.028'),
    };
  }

  String _cardTypeUsageNote(String cardType) {
    return cardType == 'delivery'
        ? context.loc.tr('shared.delivery_card_payments_note')
        : '';
  }

  bool _isBalanceCardType(String cardType) =>
      cardType == 'standard' || cardType == 'delivery';

  bool _canIssueGeneralBalanceCards() {
    final permissions = AppPermissions.fromUser(_user);
    return permissions.isAdminRole ||
        permissions.canManageUsers ||
        permissions.canManageCardPrintRequests;
  }

  bool _mustCreatePrivateBalanceCards(String cardType) {
    if (!_isBalanceCardType(cardType)) {
      return true;
    }
    final permissions = AppPermissions.fromUser(_user);
    return !_canIssueGeneralBalanceCards() ||
        permissions.isDriverRole ||
        !_isVerifiedAccount;
  }

  List<String> _issuablePrintCardTypes() {
    final raw = _user?['cardIssuanceOptions'];
    if (raw is List) {
      final values = raw
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty && item != 'delivery')
          .toList();
      if (values.isNotEmpty) {
        return values;
      }
    }
    final permissions = AppPermissions.fromUser(_user);
    if (!permissions.canIssueCards) {
      return const [];
    }
    final values = <String>['standard'];
    if (permissions.canIssueSingleUseTickets) {
      values.add('single_use');
    }
    if (permissions.canIssueAppointmentTickets) {
      values.add('appointment');
    }
    if (permissions.canIssueQueueTickets) {
      values.add('queue');
    }
    return values;
  }

  List<String> _sortedPrintableTypes() {
    final values = [..._issuablePrintCardTypes()];
    values.sort(
      (a, b) => (_cardTypeDisplayOrder[a] ?? 999).compareTo(
        _cardTypeDisplayOrder[b] ?? 999,
      ),
    );
    return values;
  }

  IconData _cardTypeIcon(String cardType) {
    return switch (cardType) {
      'single_use' => Icons.confirmation_number_rounded,
      'delivery' => Icons.local_shipping_rounded,
      'appointment' => Icons.event_available_rounded,
      'queue' => Icons.people_alt_rounded,
      _ => Icons.credit_card_rounded,
    };
  }

  String _cardTypeDescription(String cardType) {
    final l = context.loc;
    return switch (cardType) {
      'single_use' => l.tr('screens_card_print_requests_screen.065'),
      'delivery' => l.tr('screens_card_print_requests_screen.066'),
      'appointment' => l.tr('screens_card_print_requests_screen.067'),
      'queue' => l.tr('screens_card_print_requests_screen.068'),
      _ => l.tr('screens_card_print_requests_screen.069'),
    };
  }

  double _cardRequestFeeAmount(double baseAmount, double feePercent) {
    if (baseAmount <= 0 || feePercent <= 0) {
      return 0;
    }
    final rounded = double.parse(
      (baseAmount * (feePercent / 100)).toStringAsFixed(2),
    );
    return rounded > 0 ? rounded : 0.01;
  }

  double _feeAmount(String key) =>
      (_feeSettings[key] as num?)?.toDouble() ?? 0.0;

  double _issueFeePerCard(String cardType, {required bool isPrivate}) {
    final normalizedType = cardType.trim().toLowerCase();
    var fee = switch (normalizedType) {
      'single_use' => _feeAmount('singleUseTicketIssueCost'),
      'appointment' => _feeAmount('appointmentTicketIssueCost'),
      'queue' => _feeAmount('queueTicketIssueCost'),
      'delivery' => _feeAmount('deliveryCardIssueCost'),
      _ => _feeAmount('standardCardIssueCost'),
    };
    final isTicket =
        normalizedType == 'single_use' ||
        normalizedType == 'appointment' ||
        normalizedType == 'queue';
    if (isPrivate && !isTicket) {
      fee += _feeAmount('privateCardIssueCost');
    }
    return fee > 0 ? fee : 0;
  }

  double _creationIssueFeePerCard(
    String cardType, {
    required bool isPrivate,
    required double cardValue,
  }) {
    final configured = _issueFeePerCard(cardType, isPrivate: isPrivate);
    if (_isBalanceCardType(cardType) && isPrivate) {
      final percentCost = double.parse((cardValue * 0.01).toStringAsFixed(2));
      return [configured, percentCost, 0.02].reduce((a, b) => a > b ? a : b);
    }

    return configured;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _load();
      }
    });
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _isLoadingRequests = true;
    });
    final cachedUser = await _authService.currentUser();
    if (!mounted) {
      return;
    }
    if (cachedUser != null) {
      final cachedPermissions = AppPermissions.fromUser(cachedUser);
      setState(() {
        _user = cachedUser;
        _isAuthorized = cachedPermissions.canRequestCardPrinting;
        _isLoading = false;
      });
    }
    try {
      final results = await Future.wait([
        _apiService.getMyCardPrintRequests(perPage: 12),
        _refreshAndReadCurrentUser(),
        _apiService.getFeeSettings().catchError(
          (_) => const <String, dynamic>{},
        ),
      ]);
      if (!mounted) {
        return;
      }
      final user = results[1];
      final permissions = AppPermissions.fromUser(user);
      setState(() {
        final requestsPayload = Map<String, dynamic>.from(results[0] as Map);
        _requests = List<Map<String, dynamic>>.from(
          requestsPayload['requests'] as List? ?? const [],
        );
        _user = user;
        _feeSettings = Map<String, dynamic>.from(results[2] as Map);
        _usageReport = const <String, dynamic>{};
        _isAuthorized = permissions.canRequestCardPrinting;
        _isLoading = false;
        _isLoadingRequests = false;
      });
      _loadUsageReport(permissions);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _isLoadingRequests = false;
      });
      if (cachedUser == null) {
        await AppAlertService.showError(
          context,
          title: context.loc.tr('screens_card_print_requests_screen.001'),
          message: ErrorMessageService.sanitize(error),
        );
      }
    }
  }

  void _loadUsageReport(AppPermissions permissions) {
    if (!permissions.canRequestCardPrinting &&
        !permissions.canIssueCards &&
        !permissions.canViewInventory) {
      return;
    }

    () async {
      try {
        final usageReport = await _apiService.getMyIssuedCardUsageReport(
          perPage: 8,
        );
        if (!mounted) {
          return;
        }
        setState(() => _usageReport = usageReport);
      } catch (_) {
        if (!mounted) {
          return;
        }
        setState(() => _usageReport = const <String, dynamic>{});
      }
    }();
  }

  Future<Map<String, dynamic>?> _refreshAndReadCurrentUser() async {
    var user = await _authService.currentUser();
    try {
      final refreshed = await _authService.tryRefreshCurrentUser();
      if (refreshed) {
        user = await _authService.currentUser();
      }
    } catch (_) {
      user ??= await _authService.currentUser();
    }
    return user;
  }

  Future<void> _showCreateRequestDialog() async {
    if (!_isAuthorized) {
      return;
    }
    final l = context.loc;
    final valueController = TextEditingController();
    final quantityController = TextEditingController(
      text: '$_minimumCardQuantity',
    );
    final notesController = TextEditingController();
    final detailsTitleController = TextEditingController();
    final detailsDescriptionController = TextEditingController();
    final detailsLocationController = TextEditingController();
    final startsAtController = TextEditingController();
    final endsAtController = TextEditingController();
    final validFromController = TextEditingController();
    final validUntilController = TextEditingController();
    final allowedPhoneController = TextEditingController();
    final selectedUsers = <Map<String, dynamic>>[];
    final selectedPhoneNumbers = <String>[];
    final availableTypes = _sortedPrintableTypes();
    var cardType = availableTypes.contains('standard')
        ? 'standard'
        : (availableTypes.isNotEmpty ? availableTypes.first : 'standard');
    String? pendingSubmissionFingerprint;
    String? pendingIdempotencyKey;
    const uuid = Uuid();

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final isBalanceCard = _isBalanceCardType(cardType);
            final requiresTargetedUsers = !isBalanceCard;
            final selectedUserIds = selectedUsers
                .map((item) => item['id']?.toString() ?? '')
                .where((item) => item.isNotEmpty)
                .toList();
            final selectedPhones = selectedPhoneNumbers
                .map((item) => item.trim())
                .where((item) => item.isNotEmpty)
                .toList();
            final availableBalance =
                (_user?['availablePrintingBalance'] as num?)?.toDouble() ?? 0;
            final feePercent =
                (_user?['customCardPrintRequestFeePercent'] as num?)
                    ?.toDouble() ??
                0;
            final value = double.tryParse(valueController.text.trim()) ?? 0;
            final quantity = int.tryParse(quantityController.text.trim()) ?? 0;
            final forcePrivateRequest = _mustCreatePrivateBalanceCards(
              cardType,
            );
            final isPrivateRequest =
                forcePrivateRequest ||
                requiresTargetedUsers ||
                selectedUserIds.isNotEmpty ||
                selectedPhones.isNotEmpty;
            final faceAmount = isBalanceCard && !isPrivateRequest
                ? value * quantity
                : 0.0;
            final issueCostPerCard = _creationIssueFeePerCard(
              cardType,
              isPrivate: isPrivateRequest,
              cardValue: value,
            );
            final chargedIssueCostAmount = issueCostPerCard * quantity;
            const deferredIssueCostAmount = 0.0;
            final baseAmount = faceAmount + chargedIssueCostAmount;
            final feeAmount = _cardRequestFeeAmount(baseAmount, feePercent);
            final totalAmount = baseAmount + feeAmount;

            void addAllowedPhone() {
              if (!_isVerifiedAccount) {
                AppAlertService.showInfo(
                  dialogContext,
                  title: l.tr('screens_card_print_requests_screen.070'),
                  message: l.tr('screens_card_print_requests_screen.071'),
                );
                return;
              }

              final raw = allowedPhoneController.text.trim();
              final digits = raw.replaceAll(RegExp(r'\D'), '');
              if (digits.length < 6) {
                return;
              }
              final normalized = raw.startsWith('+') ? '+$digits' : digits;
              if (!selectedPhoneNumbers.contains(normalized)) {
                setDialogState(() => selectedPhoneNumbers.add(normalized));
              }
              allowedPhoneController.clear();
            }

            Future<void> submit() async {
              if (quantity <= 0 || (isBalanceCard && value <= 0)) {
                await AppAlertService.showError(
                  dialogContext,
                  title: l.tr('screens_card_print_requests_screen.002'),
                  message: l.tr('screens_card_print_requests_screen.003'),
                );
                return;
              }

              if (quantity < _minimumCardQuantity) {
                await AppAlertService.showError(
                  dialogContext,
                  title: l.tr('screens_card_print_requests_screen.057'),
                  message: l.tr(
                    'screens_card_print_requests_screen.058',
                    params: {'count': '$_minimumCardQuantity'},
                  ),
                );
                return;
              }

              if (cardType == 'appointment' &&
                  (detailsTitleController.text.trim().isEmpty ||
                      startsAtController.text.trim().isEmpty)) {
                await AppAlertService.showError(
                  dialogContext,
                  title: l.tr('screens_card_print_requests_screen.061'),
                  message: l.tr('screens_card_print_requests_screen.062'),
                );
                return;
              }

              if (cardType == 'queue' &&
                  detailsTitleController.text.trim().isEmpty) {
                await AppAlertService.showError(
                  dialogContext,
                  title: l.tr('screens_card_print_requests_screen.063'),
                  message: l.tr('screens_card_print_requests_screen.064'),
                );
                return;
              }

              if (totalAmount > availableBalance) {
                final contact = await ContactInfoService.getContactInfo();
                if (!dialogContext.mounted) {
                  return;
                }
                await _showOverLimitDialog(
                  dialogContext,
                  availableBalance: availableBalance,
                  totalAmount: totalAmount,
                  feePercent: feePercent,
                  supportWhatsapp: ContactInfoService.supportWhatsapp(contact),
                );
                return;
              }

              final details = <String, dynamic>{
                if (detailsTitleController.text.trim().isNotEmpty)
                  'title': detailsTitleController.text.trim(),
                if (detailsDescriptionController.text.trim().isNotEmpty)
                  'description': detailsDescriptionController.text.trim(),
                if (detailsLocationController.text.trim().isNotEmpty)
                  'location': detailsLocationController.text.trim(),
                if (startsAtController.text.trim().isNotEmpty)
                  'startsAt': startsAtController.text.trim(),
                if (endsAtController.text.trim().isNotEmpty)
                  'endsAt': endsAtController.text.trim(),
              };
              final submissionFingerprint = jsonEncode({
                'value': isBalanceCard ? value : 0,
                'quantity': quantity,
                'cardType': cardType,
                'notes': notesController.text.trim(),
                'allowedUserIds': selectedUserIds,
                'allowedUserPhones': selectedPhones,
                'validFrom': validFromController.text.trim(),
                'validUntil': validUntilController.text.trim(),
                'cardDetails': details,
              });
              if (pendingSubmissionFingerprint != submissionFingerprint) {
                pendingSubmissionFingerprint = submissionFingerprint;
                pendingIdempotencyKey = uuid.v4();
              }

              final security = await TransferSecurityService.confirmTransfer(
                dialogContext,
                allowOtpFallback: true,
              );
              if (!dialogContext.mounted || !security.isVerified) {
                return;
              }

              setDialogState(() => _isSubmitting = true);
              try {
                final response = await _apiService.requestCardPrint(
                  idempotencyKey: pendingIdempotencyKey!,
                  value: isBalanceCard ? value : 0,
                  quantity: quantity,
                  cardType: cardType,
                  notes: notesController.text,
                  allowedUserIds: selectedUserIds,
                  allowedUserPhones: selectedPhones,
                  validFrom: validFromController.text,
                  validUntil: validUntilController.text,
                  cardDetails: details,
                  otpCode: security.otpCode,
                  securityPin: security.securityPin,
                  localAuthMethod: security.method,
                );
                if (!dialogContext.mounted) {
                  return;
                }
                Navigator.pop(dialogContext);
                if (!mounted) {
                  return;
                }
                await AppAlertService.showSuccess(
                  context,
                  title: l.tr('screens_card_print_requests_screen.004'),
                  message:
                      response['message']?.toString() ??
                      l.tr('screens_card_print_requests_screen.005'),
                );
                await _load();
              } catch (error) {
                if (!dialogContext.mounted) {
                  return;
                }
                setDialogState(() => _isSubmitting = false);
                await AppAlertService.showError(
                  dialogContext,
                  title: l.tr('screens_card_print_requests_screen.006'),
                  message: ErrorMessageService.sanitize(error),
                );
              }
            }

            return Scaffold(
              appBar: AppBar(
                title: Text(l.tr('screens_card_print_requests_screen.007')),
              ),
              body: SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        if (_isSubUser) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppTheme.primarySoft.withValues(
                                alpha: 0.7,
                              ),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: AppTheme.primary.withValues(alpha: 0.12),
                              ),
                            ),
                            child: Text(
                              _subUserPrintLimitMessage(dialogContext),
                              style: AppTheme.caption.copyWith(
                                color: AppTheme.textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (availableTypes.length > 1) ...[
                          _buildPrintRequestStepHeader(
                            number: '1',
                            title: l.text('نوع البطاقة', 'Card type'),
                            subtitle: l.text(
                              'اختر نوع البطاقات التي تريد طلب طباعتها.',
                              'Choose the type of cards you want to print.',
                            ),
                          ),
                          const SizedBox(height: 12),
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(
                              l.tr('screens_card_print_requests_screen.008'),
                              style: AppTheme.bodyBold,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: availableTypes.map((type) {
                              final selected = cardType == type;
                              return InkWell(
                                borderRadius: BorderRadius.circular(18),
                                onTap: () {
                                  setDialogState(() {
                                    cardType = type;
                                    if (_isBalanceCardType(type)) {
                                      selectedUsers.clear();
                                      detailsTitleController.clear();
                                      detailsDescriptionController.clear();
                                      detailsLocationController.clear();
                                      startsAtController.clear();
                                      endsAtController.clear();
                                      validFromController.clear();
                                      validUntilController.clear();
                                    }
                                  });
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 180),
                                  width:
                                      MediaQuery.sizeOf(dialogContext).width <
                                          560
                                      ? MediaQuery.sizeOf(dialogContext).width -
                                            40
                                      : 198,
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? AppTheme.primary.withValues(
                                            alpha: 0.08,
                                          )
                                        : AppTheme.surfaceVariant,
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: selected
                                          ? AppTheme.primary
                                          : AppTheme.border,
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            _cardTypeIcon(type),
                                            color: selected
                                                ? AppTheme.primary
                                                : AppTheme.textSecondary,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              _cardTypeLabel(
                                                dialogContext,
                                                type,
                                              ),
                                              style: AppTheme.bodyBold,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        _cardTypeDescription(type),
                                        style: AppTheme.caption.copyWith(
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (availableTypes.length == 1) ...[
                          _buildPrintRequestStepHeader(
                            number: '1',
                            title: l.text('نوع البطاقة', 'Card type'),
                            subtitle: l.text(
                              'تم تحديد النوع المتاح لحسابك.',
                              'The available type for your account is selected.',
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppTheme.primarySoft.withValues(
                                alpha: 0.7,
                              ),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: AppTheme.primary.withValues(alpha: 0.12),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _cardTypeIcon(cardType),
                                  color: AppTheme.primary,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _cardTypeLabel(dialogContext, cardType),
                                    style: AppTheme.bodyBold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (forcePrivateRequest && isBalanceCard) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppTheme.warning.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: AppTheme.warning.withValues(alpha: 0.18),
                              ),
                            ),
                            child: Text(
                              'سيتم إنشاء البطاقة كخاصة فقط لهذا الحساب. البطاقات العامة تحتاج صلاحية إدارية أو صلاحية إدارة طلبات الطباعة.',
                              style: AppTheme.caption.copyWith(
                                color: AppTheme.textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (cardType == 'delivery')
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppTheme.primarySoft.withValues(
                                alpha: 0.7,
                              ),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: AppTheme.primary.withValues(alpha: 0.12),
                              ),
                            ),
                            child: Text(
                              l.tr('shared.delivery_card_print_note'),
                              style: AppTheme.caption.copyWith(
                                color: AppTheme.textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        if (cardType == 'delivery') const SizedBox(height: 12),
                        _buildPrintRequestStepHeader(
                          number: '2',
                          title: l.text('بيانات الطلب', 'Request details'),
                          subtitle: l.text(
                            'حدد قيمة البطاقة والكمية قبل الانتقال إلى الخيارات الإضافية.',
                            'Set the card value and quantity before optional details.',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: valueController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          enabled: isBalanceCard,
                          decoration: InputDecoration(
                            labelText: !isBalanceCard
                                ? l.tr('screens_card_print_requests_screen.011')
                                : l.tr(
                                    'screens_card_print_requests_screen.012',
                                  ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: quantityController,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: l.tr(
                              'screens_card_print_requests_screen.013',
                            ),
                            helperText: l.tr(
                              'screens_card_print_requests_screen.095',
                              params: {'count': '$_minimumCardQuantity'},
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        ShwakelCard(
                          padding: const EdgeInsets.all(14),
                          color: AppTheme.secondary.withValues(alpha: 0.05),
                          borderColor: AppTheme.secondary.withValues(
                            alpha: 0.14,
                          ),
                          borderRadius: BorderRadius.circular(18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l.tr('screens_card_print_requests_screen.103'),
                                style: AppTheme.bodyBold,
                              ),
                              const SizedBox(height: 10),
                              _metaItem(
                                l.tr('screens_card_print_requests_screen.072'),
                                CurrencyFormatter.ils(faceAmount),
                              ),
                              const SizedBox(height: 8),
                              _metaItem(
                                l.tr('screens_card_print_requests_screen.073'),
                                CurrencyFormatter.ils(chargedIssueCostAmount),
                              ),
                              if (deferredIssueCostAmount > 0) ...[
                                const SizedBox(height: 8),
                                _metaItem(
                                  l.tr(
                                    'screens_card_print_requests_screen.074',
                                  ),
                                  CurrencyFormatter.ils(
                                    deferredIssueCostAmount,
                                  ),
                                ),
                              ],
                              if (feeAmount > 0 || feePercent <= 0) ...[
                                const SizedBox(height: 8),
                                _metaItem(
                                  l.tr(
                                    'screens_card_print_requests_screen.021',
                                  ),
                                  feeAmount <= 0
                                      ? 'مجانا عرض خاص'
                                      : CurrencyFormatter.ils(feeAmount),
                                ),
                              ],
                              const SizedBox(height: 8),
                              _metaItem(
                                l.tr('screens_card_print_requests_screen.075'),
                                CurrencyFormatter.ils(totalAmount),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                deferredIssueCostAmount > 0
                                    ? l.tr(
                                        'screens_card_print_requests_screen.076',
                                      )
                                    : l.tr(
                                        'screens_card_print_requests_screen.077',
                                      ),
                                style: AppTheme.caption.copyWith(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (requiresTargetedUsers) ...[
                          _buildPrintRequestStepHeader(
                            number: '3',
                            title: l.text(
                              'المستفيدون والتفاصيل',
                              'Recipients and details',
                            ),
                            subtitle: l.text(
                              'أضف المستفيدين والبيانات المطلوبة لهذا النوع فقط.',
                              'Add recipients and only the details required for this type.',
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppTheme.errorLight,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: AppTheme.error.withValues(alpha: 0.30),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l.tr(
                                    'screens_card_print_requests_screen.078',
                                  ),
                                  style: AppTheme.bodyBold.copyWith(
                                    color: AppTheme.error,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  l.tr(
                                    'screens_card_print_requests_screen.079',
                                  ),
                                  style: AppTheme.caption.copyWith(
                                    color: AppTheme.error,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: allowedPhoneController,
                                        keyboardType: TextInputType.phone,
                                        decoration: InputDecoration(
                                          labelText: l.tr(
                                            'screens_card_print_requests_screen.080',
                                          ),
                                          prefixIcon: const Icon(
                                            Icons.phone_rounded,
                                          ),
                                        ),
                                        onSubmitted: (_) => addAllowedPhone(),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    IconButton.filledTonal(
                                      onPressed: addAllowedPhone,
                                      icon: const Icon(Icons.add_rounded),
                                      tooltip: l.tr(
                                        'screens_card_print_requests_screen.081',
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                if (selectedPhoneNumbers.isNotEmpty)
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: selectedPhoneNumbers.map((phone) {
                                      return InputChip(
                                        avatar: const Icon(Icons.phone_rounded),
                                        label: Text(phone),
                                        onDeleted: () => setDialogState(
                                          () => selectedPhoneNumbers.remove(
                                            phone,
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                if (selectedPhoneNumbers.isNotEmpty)
                                  const SizedBox(height: 10),
                                if (selectedUsers.isNotEmpty)
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: selectedUsers.map((user) {
                                      final id = user['id']?.toString() ?? '';
                                      final label = UserDisplayName.fromMap(
                                        user,
                                        fallback: id,
                                      );
                                      return InputChip(
                                        label: Text(label),
                                        onDeleted: () {
                                          setDialogState(
                                            () => selectedUsers.removeWhere(
                                              (item) =>
                                                  item['id']?.toString() == id,
                                            ),
                                          );
                                        },
                                      );
                                    }).toList(),
                                  ),
                                Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: TextButton.icon(
                                    onPressed: () async {
                                      final results =
                                          await _pickPrintTargetUsers(
                                            dialogContext,
                                            selectedUsers,
                                          );
                                      if (results != null) {
                                        setDialogState(() {
                                          selectedUsers
                                            ..clear()
                                            ..addAll(results);
                                        });
                                      }
                                    },
                                    icon: const Icon(Icons.group_add_rounded),
                                    label: Text(
                                      selectedUsers.isEmpty
                                          ? l.tr(
                                              'screens_card_print_requests_screen.082',
                                            )
                                          : l.tr(
                                              'screens_card_print_requests_screen.083',
                                            ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: detailsTitleController,
                            decoration: InputDecoration(
                              labelText: cardType == 'appointment'
                                  ? l.tr(
                                      'screens_card_print_requests_screen.084',
                                    )
                                  : cardType == 'queue'
                                  ? l.tr(
                                      'screens_card_print_requests_screen.085',
                                    )
                                  : l.tr(
                                      'screens_card_print_requests_screen.086',
                                    ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (cardType == 'appointment') ...[
                            TextField(
                              controller: startsAtController,
                              decoration: InputDecoration(
                                labelText: l.tr(
                                  'screens_card_print_requests_screen.087',
                                ),
                                hintText: '2026-05-01 09:00',
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: endsAtController,
                              decoration: InputDecoration(
                                labelText: l.tr(
                                  'screens_card_print_requests_screen.088',
                                ),
                                hintText: '2026-05-01 09:30',
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (cardType == 'appointment' ||
                              cardType == 'queue') ...[
                            TextField(
                              controller: detailsLocationController,
                              decoration: InputDecoration(
                                labelText: l.tr(
                                  'screens_card_print_requests_screen.089',
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          TextField(
                            controller: validFromController,
                            decoration: InputDecoration(
                              labelText: l.tr(
                                'screens_card_print_requests_screen.090',
                              ),
                              hintText: l.tr(
                                'screens_card_print_requests_screen.091',
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: validUntilController,
                            decoration: InputDecoration(
                              labelText: l.tr(
                                'screens_card_print_requests_screen.092',
                              ),
                              hintText: l.tr(
                                'screens_card_print_requests_screen.093',
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: detailsDescriptionController,
                            minLines: 2,
                            maxLines: 3,
                            decoration: InputDecoration(
                              labelText: l.tr(
                                'screens_card_print_requests_screen.094',
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        _buildPrintRequestStepHeader(
                          number: requiresTargetedUsers ? '4' : '3',
                          title: l.text(
                            'الملاحظات والتأكيد',
                            'Notes and confirmation',
                          ),
                          subtitle: l.text(
                            'راجع التكلفة ثم أرسل الطلب بعد التحقق الأمني.',
                            'Review the cost and submit after security confirmation.',
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: notesController,
                          minLines: 2,
                          maxLines: 4,
                          decoration: InputDecoration(
                            labelText: l.tr(
                              'screens_card_print_requests_screen.014',
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _isSubmitting
                                    ? null
                                    : () => Navigator.pop(dialogContext),
                                child: Text(
                                  l.tr(
                                    'screens_card_print_requests_screen.015',
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                onPressed: _isSubmitting ? null : submit,
                                child: Text(
                                  _isSubmitting
                                      ? l.tr(
                                          'screens_card_print_requests_screen.016',
                                        )
                                      : l.tr(
                                          'screens_card_print_requests_screen.017',
                                        ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ),
              resizeToAvoidBottomInset: true,
            );
          },
        ),
      ),
    );

    valueController.dispose();
    quantityController.dispose();
    notesController.dispose();
    detailsTitleController.dispose();
    detailsDescriptionController.dispose();
    detailsLocationController.dispose();
    startsAtController.dispose();
    endsAtController.dispose();
    validFromController.dispose();
    validUntilController.dispose();
    if (mounted) {
      setState(() => _isSubmitting = false);
    }
  }

  Future<List<Map<String, dynamic>>?> _pickPrintTargetUsers(
    BuildContext dialogContext,
    List<Map<String, dynamic>> current,
  ) async {
    if (!_isVerifiedAccount) {
      await AppAlertService.showInfo(
        dialogContext,
        title: context.loc.tr('screens_card_print_requests_screen.096'),
        message: context.loc.tr('screens_card_print_requests_screen.097'),
      );
      return current;
    }

    return Navigator.of(context).push<List<Map<String, dynamic>>>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _PrintTargetUsersScreen(initialSelected: current),
      ),
    );
  }

  Future<void> _showOverLimitDialog(
    BuildContext dialogContext, {
    required double availableBalance,
    required double totalAmount,
    required double feePercent,
    required String supportWhatsapp,
  }) async {
    final l = context.loc;
    await showDialog<void>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: Text(l.tr('screens_card_print_requests_screen.041')),
        content: Text(
          l.tr(
            'screens_card_print_requests_screen.042',
            params: {
              'available': CurrencyFormatter.ils(availableBalance),
              'total': CurrencyFormatter.ils(totalAmount),
              'fee': feePercent.toStringAsFixed(2),
              'phone': supportWhatsapp,
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.tr('screens_card_print_requests_screen.043')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.loc;
    if (_isLoading && _user == null) {
      return const ShwakelPageLoadingScaffold();
    }

    if (!_isAuthorized) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          title: Text(l.tr('screens_card_print_requests_screen.018')),
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
                  l.tr('screens_card_print_requests_screen.037'),
                  style: AppTheme.h3,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final availableBalance =
        (_user?['availablePrintingBalance'] as num?)?.toDouble() ?? 0;
    final printFee = (_user?['customCardPrintRequestFeePercent'] as num?)
        ?.toDouble();

    return DefaultTabController(
      length: 3,
      child: Builder(
        builder: (context) {
          final tabController = DefaultTabController.of(context);
          return AnimatedBuilder(
            animation: tabController,
            builder: (context, _) {
              final currentTab = switch (tabController.index) {
                1 => _buildRequestsTab(),
                2 => _buildUsageTab(),
                _ => _buildCreatePrintRequestTab(
                  availableBalance: availableBalance,
                  printFee: printFee,
                ),
              };

              return Scaffold(
                backgroundColor: AppTheme.background,
                appBar: AppBar(
                  title: Text(l.tr('screens_card_print_requests_screen.018')),
                  actions: const [AppNotificationAction(), QuickLogoutAction()],
                ),
                drawer: AppSidebar.drawerFor(context),
                body: RefreshIndicator(
                  onRefresh: _load,
                  child: SingleChildScrollView(
                    child: ResponsiveScaffoldContainer(
                      useSafeArea: false,
                      padding: const EdgeInsets.fromLTRB(
                        AppTheme.spacingLg,
                        8,
                        AppTheme.spacingLg,
                        AppTheme.spacingLg,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildPrintRequestTabs(),
                          const SizedBox(height: 16),
                          currentTab,
                        ],
                      ),
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

  Widget _buildPrintRequestTabs() {
    final l = context.loc;
    return DecoratedBox(
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
            icon: const Icon(Icons.add_card_rounded),
            text: l.tr('screens_card_print_requests_screen.023'),
          ),
          Tab(
            icon: const Icon(Icons.list_alt_rounded),
            text: l.tr('screens_card_print_requests_screen.018'),
          ),
          Tab(
            icon: const Icon(Icons.analytics_rounded),
            text: l.tr('screens_card_print_requests_screen.050'),
          ),
        ],
      ),
    );
  }

  Widget _buildCreatePrintRequestTab({
    required double availableBalance,
    required double? printFee,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPrintInfoCard(
          availableBalance: availableBalance,
          printFee: printFee,
        ),
        if (_isSubUser) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.surfaceVariant,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.borderLight),
            ),
            child: Text(
              _subUserPrintLimitMessage(context),
              style: AppTheme.caption.copyWith(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRequestsTab() {
    final l = context.loc;
    if (_isLoadingRequests) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_requests.isEmpty) {
      return ShwakelCard(
        padding: const EdgeInsets.all(28),
        child: Center(
          child: Text(
            l.tr('screens_card_print_requests_screen.024'),
            style: AppTheme.bodyAction,
          ),
        ),
      );
    }
    return Column(
      children: [
        _buildRequestsSummaryBar(),
        const SizedBox(height: 12),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _requests.length,
          separatorBuilder: (context, index) => const SizedBox(height: 12),
          itemBuilder: (context, index) => _buildRequestCard(_requests[index]),
        ),
      ],
    );
  }

  Widget _buildUsageTab() {
    return _buildIssuedCardsUsageReport();
  }

  Widget _buildRequestsSummaryBar() {
    final l = context.loc;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Row(
        children: [
          const Icon(Icons.receipt_long_rounded, color: AppTheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l.text('طلبات الطباعة الحالية', 'Current print requests'),
              style: AppTheme.bodyBold,
            ),
          ),
          Text(
            '${_requests.length}',
            style: AppTheme.bodyBold.copyWith(color: AppTheme.primary),
          ),
        ],
      ),
    );
  }

  Widget _buildIssuedCardsUsageReport() {
    final summary = Map<String, dynamic>.from(
      _usageReport['summary'] as Map? ?? const {},
    );
    final items = List<Map<String, dynamic>>.from(
      (_usageReport['items'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildUsageReportHeader(summary),
        const SizedBox(height: 12),
        if (items.isEmpty)
          _buildUsageEmptyState()
        else ...[
          _buildUsageResultsHeader(items.length),
          const SizedBox(height: 10),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) => _buildUsageReportRow(items[index]),
          ),
        ],
      ],
    );
  }

  Widget _buildUsageReportHeader(Map<String, dynamic> summary) {
    return ShwakelCard(
      padding: const EdgeInsets.all(18),
      borderRadius: BorderRadius.circular(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.analytics_rounded,
                  color: AppTheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'تقرير استخدام البطاقات الصادرة',
                  style: AppTheme.h3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 560;
              final tiles = [
                _usageSummaryTile(
                  'إجمالي البطاقات',
                  '${(summary['totalCards'] as num?)?.toInt() ?? 0}',
                  Icons.credit_card_rounded,
                ),
                _usageSummaryTile(
                  'المستخدمة',
                  '${(summary['usedCards'] as num?)?.toInt() ?? 0}',
                  Icons.task_alt_rounded,
                ),
                _usageSummaryTile(
                  'المستخدمة اليوم',
                  '${(summary['usedToday'] as num?)?.toInt() ?? 0}',
                  Icons.today_rounded,
                ),
                _usageSummaryTile(
                  'الخاصة',
                  '${(summary['privateCards'] as num?)?.toInt() ?? 0}',
                  Icons.lock_rounded,
                ),
              ];
              if (compact) {
                return Column(
                  children: tiles
                      .map(
                        (tile) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: tile,
                        ),
                      )
                      .toList(),
                );
              }
              return Wrap(spacing: 10, runSpacing: 10, children: tiles);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildUsageResultsHeader(int count) {
    final l = context.loc;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Row(
        children: [
          const Icon(Icons.history_rounded, color: AppTheme.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l.text('آخر استخدامات البطاقات', 'Recent card usage'),
              style: AppTheme.bodyBold,
            ),
          ),
          Text(
            '$count',
            style: AppTheme.bodyBold.copyWith(color: AppTheme.primary),
          ),
        ],
      ),
    );
  }

  Widget _buildUsageEmptyState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Text(
        'لا توجد استخدامات مسجلة للبطاقات الصادرة من حسابك ضمن النطاق الحالي.',
        style: AppTheme.bodyAction,
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _usageSummaryTile(String label, String value, IconData icon) {
    return Container(
      width: AppTheme.isPhone(context) ? double.infinity : 178,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceVariant,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.primary, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTheme.caption),
                const SizedBox(height: 3),
                Text(value, style: AppTheme.bodyBold),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUsageReportRow(Map<String, dynamic> card) {
    final status = card['status']?.toString() ?? 'available';
    final isUsed = status == 'used';
    final usedBy =
        (card['redeemedByDisplayName'] ??
                card['redeemedByUsername'] ??
                'غير مستخدمة')
            .toString();
    final usedAt = card['redeemedAt']?.toString() ?? '-';
    final scope = card['visibilityScope']?.toString() == 'restricted'
        ? 'خاصة'
        : 'عامة';
    final type = card['cardType']?.toString() ?? 'standard';
    final barcode = card['barcode']?.toString() ?? '';
    final statusColor = isUsed ? AppTheme.success : AppTheme.textTertiary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isUsed
            ? AppTheme.success.withValues(alpha: 0.06)
            : AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isUsed
              ? AppTheme.success.withValues(alpha: 0.16)
              : AppTheme.border,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560;
          final leading = Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              isUsed
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked,
              color: statusColor,
            ),
          );
          final body = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_cardTypeLabel(context, type)} - $scope',
                style: AppTheme.bodyBold,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _usageInfoChip(
                    Icons.qr_code_2_rounded,
                    barcode.isEmpty ? '-' : barcode,
                  ),
                  _usageInfoChip(
                    Icons.person_rounded,
                    isUsed ? usedBy : 'غير مستخدمة',
                  ),
                  _usageInfoChip(
                    Icons.schedule_rounded,
                    isUsed ? usedAt : 'بانتظار الاستخدام',
                  ),
                ],
              ),
            ],
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    leading,
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        isUsed ? 'مستخدمة' : 'غير مستخدمة',
                        style: AppTheme.bodyBold.copyWith(color: statusColor),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                body,
              ],
            );
          }

          return Row(
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(child: body),
              const SizedBox(width: 10),
              Text(
                isUsed ? 'مستخدمة' : 'غير مستخدمة',
                style: AppTheme.caption.copyWith(
                  color: statusColor,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _usageInfoChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppTheme.surfaceMuted,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppTheme.primary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: AppTheme.caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrintRequestStepHeader({
    required String number,
    required String title,
    required String subtitle,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: AppTheme.primary,
            shape: BoxShape.circle,
          ),
          child: Text(
            number,
            style: AppTheme.bodyBold.copyWith(color: Colors.white),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTheme.bodyBold),
              const SizedBox(height: 3),
              Text(subtitle, style: AppTheme.caption),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPrintInfoCard({
    required double availableBalance,
    required double? printFee,
  }) {
    final l = context.loc;
    final feeLabel = printFee == null
        ? l.tr('screens_card_print_requests_screen.022')
        : '${CurrencyFormatter.formatAmount(printFee)}%';
    final debtLimit = (_user?['printingDebtLimit'] as num?)?.toDouble() ?? 0;
    final currentDebt = (_user?['outstandingDebt'] as num?)?.toDouble() ?? 0;
    final showPrintFee = (printFee ?? 0) > 0;
    final showDebtLimit = debtLimit > 0;
    final showCurrentDebt = currentDebt > 0;

    return ShwakelCard(
      padding: const EdgeInsets.all(22),
      borderRadius: BorderRadius.circular(28),
      shadowLevel: ShwakelShadowLevel.premium,
      gradient: const LinearGradient(
        colors: [AppTheme.secondary, AppTheme.primary],
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          final actionButton = SizedBox(
            width: compact ? double.infinity : 190,
            child: ShwakelButton(
              label: l.tr('screens_card_print_requests_screen.023'),
              icon: Icons.print_rounded,
              onPressed: _showCreateRequestDialog,
            ),
          );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flex(
                direction: compact ? Axis.vertical : Axis.horizontal,
                crossAxisAlignment: compact
                    ? CrossAxisAlignment.stretch
                    : CrossAxisAlignment.center,
                children: [
                  if (compact)
                    _buildPrintInfoHeader()
                  else
                    Expanded(child: _buildPrintInfoHeader()),
                  SizedBox(width: compact ? 0 : 18, height: compact ? 18 : 0),
                  actionButton,
                ],
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _buildPrintMetricTile(
                    icon: Icons.account_balance_wallet_rounded,
                    label: l.tr('screens_card_print_requests_screen.020'),
                    value: CurrencyFormatter.ils(availableBalance),
                  ),
                  if (showPrintFee)
                    _buildPrintMetricTile(
                      icon: Icons.percent_rounded,
                      label: l.tr('screens_card_print_requests_screen.021'),
                      value: feeLabel,
                    ),
                  if (showDebtLimit)
                    _buildPrintMetricTile(
                      icon: Icons.credit_score_rounded,
                      label: l.tr('screens_card_print_requests_screen.051'),
                      value: CurrencyFormatter.ils(debtLimit),
                    ),
                  if (showCurrentDebt)
                    _buildPrintMetricTile(
                      icon: Icons.trending_down_rounded,
                      label: l.tr('screens_card_print_requests_screen.052'),
                      value: CurrencyFormatter.ils(currentDebt),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPrintInfoHeader() {
    final l = context.loc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.print_rounded, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l.tr('screens_card_print_requests_screen.050'),
                style: AppTheme.h3.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPrintMetricTile({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      width: AppTheme.isPhone(context) ? double.infinity : 210,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 19),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.caption.copyWith(
                    color: Colors.white.withValues(alpha: 0.70),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.bodyBold.copyWith(color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRequestCard(Map<String, dynamic> request) {
    final l = context.loc;
    final status = request['status']?.toString() ?? 'pending_review';
    final cardTypeLabel = _cardTypeLabel(
      context,
      request['cardType']?.toString() ?? 'standard',
    );
    final quantity = (request['quantity'] as num?)?.toInt() ?? 0;
    final totalAmount = CurrencyFormatter.ils(
      (request['totalAmount'] as num?)?.toDouble() ?? 0,
    );
    final createdAt = _formatDateTime(
      request['createdAt']?.toString(),
      request['created_at']?.toString() ?? '-',
    );
    final title = request['statusLabel']?.toString().trim().isNotEmpty == true
        ? request['statusLabel']!.toString()
        : cardTypeLabel;
    final chargedIssueCostAmount =
        (request['chargedIssueCostAmount'] as num?)?.toDouble() ?? 0;
    final deferredIssueCostAmount =
        (request['deferredIssueCostAmount'] as num?)?.toDouble() ?? 0;
    final waivedIssueCostAmount =
        (request['waivedIssueCostAmount'] as num?)?.toDouble() ?? 0;
    final hasFees =
        chargedIssueCostAmount > 0 ||
        deferredIssueCostAmount > 0 ||
        waivedIssueCostAmount > 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ShwakelCard(
        onTap: () => _showRequestDetails(request),
        padding: const EdgeInsets.all(14),
        borderRadius: BorderRadius.circular(20),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _statusColor(status).withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                Icons.print_rounded,
                color: _statusColor(status),
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTheme.bodyBold.copyWith(fontSize: 15),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _statusChip(status),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    cardTypeLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.caption.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _requestInfoChip(
                        Icons.layers_rounded,
                        l.tr(
                          'screens_card_print_requests_screen.030',
                          params: {'count': '$quantity'},
                        ),
                      ),
                      _requestInfoChip(
                        Icons.account_balance_wallet_rounded,
                        totalAmount,
                      ),
                      if (hasFees)
                        _requestInfoChip(
                          Icons.receipt_long_rounded,
                          l.tr('screens_card_print_requests_screen.104'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    createdAt,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.caption.copyWith(
                      color: AppTheme.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_left_rounded,
              color: AppTheme.textTertiary,
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showRequestDetails(Map<String, dynamic> request) async {
    final l = context.loc;
    final chargedIssueCostAmount =
        (request['chargedIssueCostAmount'] as num?)?.toDouble() ?? 0;
    final deferredIssueCostAmount =
        (request['deferredIssueCostAmount'] as num?)?.toDouble() ?? 0;
    final waivedIssueCostAmount =
        (request['waivedIssueCostAmount'] as num?)?.toDouble() ?? 0;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          backgroundColor: AppTheme.background,
          appBar: AppBar(
            title: Text(l.tr('screens_card_print_requests_screen.100')),
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
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l.tr('screens_card_print_requests_screen.100'),
                              style: AppTheme.h3,
                            ),
                          ),
                          _statusChip(
                            request['status']?.toString() ?? 'pending_review',
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          _metaItem(
                            l.tr('screens_card_print_requests_screen.026'),
                            _cardTypeLabel(
                              context,
                              request['cardType']?.toString() ?? 'standard',
                            ),
                          ),
                          if ((request['cardType']?.toString() ?? '') ==
                              'delivery')
                            _metaItem(
                              l.tr('shared.usage_label'),
                              _cardTypeUsageNote(
                                request['cardType']?.toString() ?? 'standard',
                              ),
                            ),
                          _metaItem(
                            l.tr('screens_card_print_requests_screen.029'),
                            l.tr(
                              'screens_card_print_requests_screen.030',
                              params: {'count': '${request['quantity'] ?? 0}'},
                            ),
                          ),
                          _metaItem(
                            l.tr('screens_card_print_requests_screen.031'),
                            CurrencyFormatter.ils(
                              (request['cardValue'] as num?)?.toDouble() ?? 0,
                            ),
                          ),
                          if (chargedIssueCostAmount > 0)
                            _metaItem(
                              l.tr('screens_card_print_requests_screen.073'),
                              CurrencyFormatter.ils(chargedIssueCostAmount),
                            ),
                          if (deferredIssueCostAmount > 0)
                            _metaItem(
                              l.tr('screens_card_print_requests_screen.074'),
                              CurrencyFormatter.ils(deferredIssueCostAmount),
                            ),
                          if (waivedIssueCostAmount > 0)
                            _metaItem(
                              'رسم إصدار قديم تمت تسويته',
                              CurrencyFormatter.ils(waivedIssueCostAmount),
                            ),
                          if (((request['feeAmount'] as num?)?.toDouble() ??
                                  0) >
                              0)
                            _metaItem(
                              l.tr('screens_card_print_requests_screen.021'),
                              CurrencyFormatter.ils(
                                (request['feeAmount'] as num?)?.toDouble() ?? 0,
                              ),
                            )
                          else
                            _metaItem(
                              l.tr('screens_card_print_requests_screen.021'),
                              'مجانا عرض خاص',
                            ),
                          _metaItem(
                            l.tr('screens_card_print_requests_screen.032'),
                            CurrencyFormatter.ils(
                              (request['totalAmount'] as num?)?.toDouble() ?? 0,
                            ),
                          ),
                          _metaItem(
                            l.tr('screens_card_print_requests_screen.044'),
                            request['sourceType'] == 'local'
                                ? l.tr('screens_card_print_requests_screen.045')
                                : l.tr(
                                    'screens_card_print_requests_screen.046',
                                  ),
                          ),
                          _metaItem(
                            l.tr('screens_card_print_requests_screen.047'),
                            _formatDateTime(
                              request['lastPrintedAt']?.toString(),
                              l.tr('screens_card_print_requests_screen.048'),
                            ),
                          ),
                        ],
                      ),
                      if ((request['customerNotes']
                              ?.toString()
                              .trim()
                              .isNotEmpty ??
                          false))
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppTheme.surfaceVariant,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: AppTheme.borderLight),
                            ),
                            child: Text(
                              l.tr(
                                'screens_card_print_requests_screen.033',
                                params: {
                                  'notes': '${request['customerNotes']}',
                                },
                              ),
                              style: AppTheme.bodyAction,
                            ),
                          ),
                        ),
                      if (chargedIssueCostAmount > 0 ||
                          deferredIssueCostAmount > 0 ||
                          waivedIssueCostAmount > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppTheme.surfaceVariant,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: AppTheme.borderLight),
                            ),
                            child: Text(
                              waivedIssueCostAmount > 0
                                  ? 'تمت تسوية رسم الإصدار القديم بقيمة ${CurrencyFormatter.ils(waivedIssueCostAmount)}، ولا يؤثر على رصيد البطاقة.'
                                  : deferredIssueCostAmount > 0
                                  ? l.tr(
                                      'screens_card_print_requests_screen.101',
                                    )
                                  : l.tr(
                                      'screens_card_print_requests_screen.102',
                                    ),
                              style: AppTheme.bodyAction,
                            ),
                          ),
                        ),
                      if ((request['adminNotes']
                              ?.toString()
                              .trim()
                              .isNotEmpty ??
                          false))
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppTheme.surfaceMuted,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: AppTheme.borderLight),
                            ),
                            child: Text(
                              l.tr(
                                'screens_card_print_requests_screen.034',
                                params: {'notes': '${request['adminNotes']}'},
                              ),
                              style: AppTheme.bodyAction.copyWith(
                                color: AppTheme.textSecondary,
                              ),
                            ),
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

  Widget _metaItem(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.surfaceMuted,
        borderRadius: BorderRadius.circular(14),
      ),
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

  Widget _requestInfoChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppTheme.surfaceMuted,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppTheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: AppTheme.caption.copyWith(
              color: AppTheme.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Color _statusColor(String status) {
    return switch (status) {
      'approved' => AppTheme.primary,
      'printing' => AppTheme.warning,
      'ready' => AppTheme.success,
      'completed' => AppTheme.success,
      'rejected' => AppTheme.error,
      _ => AppTheme.textSecondary,
    };
  }

  Widget _statusChip(String status) {
    final l = context.loc;
    final color = _statusColor(status);
    final label = switch (status) {
      'pending_review' => l.tr('screens_card_print_requests_screen.035'),
      'approved' => l.tr('screens_card_print_requests_screen.036'),
      'printing' => l.tr('screens_card_print_requests_screen.037'),
      'ready' => l.tr('screens_card_print_requests_screen.038'),
      'completed' => l.tr('screens_card_print_requests_screen.039'),
      'rejected' => l.tr('screens_card_print_requests_screen.040'),
      _ => status,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: AppTheme.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  String _formatDateTime(String? value, String fallback) {
    if (value == null || value.trim().isEmpty) {
      return fallback;
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      return value;
    }
    final year = parsed.year.toString().padLeft(4, '0');
    final month = parsed.month.toString().padLeft(2, '0');
    final day = parsed.day.toString().padLeft(2, '0');
    final hour = parsed.hour.toString().padLeft(2, '0');
    final minute = parsed.minute.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute';
  }
}

class _PrintTargetUsersScreen extends StatefulWidget {
  const _PrintTargetUsersScreen({required this.initialSelected});

  final List<Map<String, dynamic>> initialSelected;

  @override
  State<_PrintTargetUsersScreen> createState() =>
      _PrintTargetUsersScreenState();
}

class _PrintTargetUsersScreenState extends State<_PrintTargetUsersScreen> {
  final ApiService _apiService = ApiService();
  final TextEditingController _searchController = TextEditingController();
  late final List<Map<String, dynamic>> _selected;
  List<Map<String, dynamic>> _results = const [];
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _selected = List<Map<String, dynamic>>.from(widget.initialSelected);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _searchUsers(String query) async {
    setState(() => _isSearching = true);
    try {
      final results = query.trim().isEmpty
          ? <Map<String, dynamic>>[]
          : await _apiService.searchUsers(query.trim());
      if (!mounted) {
        return;
      }
      setState(() => _results = results);
    } catch (_) {
      if (mounted) {
        setState(() => _results = const []);
      }
    } finally {
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  bool _isSelected(Map<String, dynamic> user) {
    final id = user['id']?.toString();
    return _selected.any((item) => item['id']?.toString() == id);
  }

  void _toggleUser(Map<String, dynamic> user, bool? value) {
    final id = user['id']?.toString() ?? '';
    setState(() {
      if (value == true && !_isSelected(user)) {
        _selected.add(user);
      } else if (value != true) {
        _selected.removeWhere((item) => item['id']?.toString() == id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.loc;
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(l.tr('screens_card_print_requests_screen.082')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _selected),
            child: Text(l.tr('screens_card_print_requests_screen.099')),
          ),
        ],
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
                  TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      labelText: l.tr('screens_card_print_requests_screen.098'),
                      prefixIcon: const Icon(Icons.search_rounded),
                    ),
                    onChanged: _searchUsers,
                  ),
                  const SizedBox(height: 12),
                  if (_selected.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _selected.map((user) {
                        final id = user['id']?.toString() ?? '';
                        return InputChip(
                          label: Text(
                            UserDisplayName.fromMap(user, fallback: id),
                          ),
                          onDeleted: () => setState(
                            () => _selected.removeWhere(
                              (item) => item['id']?.toString() == id,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (_isSearching)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              ..._results.map((user) {
                final checked = _isSelected(user);
                final id = user['id']?.toString() ?? '';
                final title = UserDisplayName.fromMap(user, fallback: id);
                final phone = PhoneNumberService.localDisplay(
                  user['whatsapp']?.toString(),
                );
                final subtitle = phone.isNotEmpty
                    ? phone
                    : user['username']?.toString() ?? '';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: ShwakelCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: CheckboxListTile(
                      value: checked,
                      title: Text(title),
                      subtitle: subtitle.isNotEmpty ? Text(subtitle) : null,
                      onChanged: (value) => _toggleUser(user, value),
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
