import 'dart:async';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/index.dart';
import '../services/index.dart';
import '../utils/app_permissions.dart';
import '../utils/app_theme.dart';
import '../utils/card_number_extractor.dart';
import '../utils/currency_formatter.dart';
import '../utils/user_display_name.dart';
import '../widgets/app_sidebar.dart';
import '../widgets/app_top_actions.dart';
import '../widgets/country_selector_field.dart';
import '../widgets/responsive_scaffold_container.dart';
import '../widgets/shwakel_button.dart';
import '../widgets/shwakel_card.dart';

class CreateCardScreen extends StatefulWidget {
  const CreateCardScreen({super.key, this.quickMode = false});

  final bool quickMode;

  @override
  State<CreateCardScreen> createState() => _CreateCardScreenState();
}

class _CreateCardScreenState extends State<CreateCardScreen> {
  static const int _cardsPerA4Page = 35;
  static const double _trialCardsLimit = 100;
  static const int _printTitleMaxLength = 24;
  static const String _lastPrintTitleKey = 'create_card.last_print_title';
  static const String _lastPrintStampKey = 'create_card.last_print_stamp';
  static const String _lastDetailsTitleKey = 'create_card.last_details_title';
  static const String _lastDetailsDescriptionKey =
      'create_card.last_details_description';
  static const String _lastLocationKey = 'create_card.last_location';
  static const Map<String, int> _cardTypeDisplayOrder = {
    'standard': 0,
    'delivery': 1,
    'single_use': 2,
    'appointment': 3,
    'queue': 4,
    'subscription': 5,
    'attendance': 6,
  };

  final ApiService _apiService = ApiService();
  final AuthService _authService = AuthService();
  final OfflineCardService _offlineCardService = OfflineCardService();
  final OfflineTransferCodeService _offlineTransferCodeService =
      OfflineTransferCodeService();
  final PDFService _pdfService = PDFService();
  final TextEditingController _amountC = TextEditingController();
  final TextEditingController _qtyC = TextEditingController(
    text: '$_cardsPerA4Page',
  );
  final TextEditingController _titleC = TextEditingController();
  final TextEditingController _stampC = TextEditingController();
  final TextEditingController _detailsTitleC = TextEditingController();
  final TextEditingController _detailsDescriptionC = TextEditingController();
  final TextEditingController _appointmentLocationC = TextEditingController();
  final TextEditingController _allowedPhoneC = TextEditingController();
  final TextEditingController _customBarcodeC = TextEditingController();

  bool _isLoading = false;
  bool _isLoadingUser = true;
  bool _isAuthorized = false;
  bool _quickMode = false;
  bool _showLogo = true;
  bool _showStamp = true;
  bool _useCustomBarcode = false;
  bool _useAccountLogo = true;
  String _loadingHeadline = '';
  String _loadingDetails = '';
  String _cardType = '';
  String _visibilityScope = 'general';
  String _recipientCountryCode = PhoneNumberService.countries.first.dialCode;
  DateTime? _validFrom;
  DateTime? _validUntil;
  DateTime? _appointmentStartsAt;
  DateTime? _appointmentEndsAt;
  Map<String, dynamic>? _user;
  Map<String, dynamic> _feeSettings = const {};
  List<VirtualCard> _recent = [];
  List<Map<String, dynamic>> _selectedUsers = [];
  List<String> _selectedPhoneNumbers = [];
  bool _didLoadDependencies = false;
  int _currentStep = 0;
  String _cardPreviewSignature = '';
  Future<Uint8List>? _cardPreviewFuture;
  int _availableOfflineTransferSlots = 0;
  String? _pendingPrintRequestFingerprint;
  String? _pendingPrintRequestIdempotencyKey;
  static const Uuid _uuid = Uuid();

  bool get _isDeviceOffline => !ConnectivityService.instance.isOnline.value;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didLoadDependencies) {
      return;
    }
    _didLoadDependencies = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (widget.quickMode || (args is Map && args['quick'] == true)) {
      _quickMode = true;
      _qtyC.text = '1';
    }
    _load();
  }

  @override
  void dispose() {
    _amountC.dispose();
    _qtyC.dispose();
    _titleC.dispose();
    _stampC.dispose();
    _detailsTitleC.dispose();
    _detailsDescriptionC.dispose();
    _appointmentLocationC.dispose();
    _allowedPhoneC.dispose();
    _customBarcodeC.dispose();
    super.dispose();
  }

  void _openRoute(String routeName) {
    final currentRoute = ModalRoute.of(context)?.settings.name;
    if (currentRoute == routeName) {
      return;
    }
    Navigator.pushNamed(context, routeName);
  }

  Future<void> _load() async {
    final l = context.loc;
    try {
      final user = await _authService.currentUser();
      await _loadSavedPrintPreferences();
      Map<String, dynamic> feeSettings = const {};
      try {
        feeSettings = Map<String, dynamic>.from(
          await _apiService.getFeeSettings(),
        );
      } catch (_) {
        feeSettings = const {};
      }
      if (!mounted) {
        return;
      }
      final permissions = AppPermissions.fromUser(user);
      setState(() {
        _user = user;
        _feeSettings = feeSettings;
        _isAuthorized = permissions.canIssueCards;
        final accountName = UserDisplayName.fromMap(
          user,
          fallback: l.tr('screens_create_card_screen.001'),
        );
        if (_titleC.text.trim().isEmpty ||
            _titleC.text.trim() == l.tr('screens_create_card_screen.001')) {
          _titleC.text = accountName;
        }
        _useAccountLogo =
            user?['printLogoUrl']?.toString().trim().isNotEmpty == true;
        final issuableCardTypes = _issuableCardTypesFromUser(user);
        if (_cardType.isNotEmpty && !issuableCardTypes.contains(_cardType)) {
          _cardType = '';
        }
        if (_cardType.isEmpty && issuableCardTypes.length == 1) {
          _applyCardTypeDefaults(issuableCardTypes.first);
          _currentStep = 1;
        }
        if (_quickMode) {
          final quickType = issuableCardTypes.contains('standard')
              ? 'standard'
              : (issuableCardTypes.isNotEmpty ? issuableCardTypes.first : '');
          if (quickType.isNotEmpty) {
            _applyCardTypeDefaults(quickType);
          }
          _qtyC.text = '1';
          _currentStep = 1;
        }
        if (!_isBalanceCard) {
          _visibilityScope = 'restricted';
        }
        _isLoadingUser = false;
      });
      if (_quickMode) {
        await _ensureOfflineTemporaryTransferSlots();
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingUser = false);
      }
    }
  }

  Future<void> _loadSavedPrintPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _titleC.text = prefs.getString(_lastPrintTitleKey) ?? _titleC.text;
    _stampC.text = prefs.getString(_lastPrintStampKey) ?? _stampC.text;
    _detailsTitleC.text =
        prefs.getString(_lastDetailsTitleKey) ?? _detailsTitleC.text;
    _detailsDescriptionC.text =
        prefs.getString(_lastDetailsDescriptionKey) ??
        _detailsDescriptionC.text;
    _appointmentLocationC.text =
        prefs.getString(_lastLocationKey) ?? _appointmentLocationC.text;
  }

  Future<void> _savePrintPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastPrintTitleKey, _titleC.text.trim());
    await prefs.setString(_lastPrintStampKey, _stampC.text.trim());
    await prefs.setString(_lastDetailsTitleKey, _detailsTitleC.text.trim());
    await prefs.setString(
      _lastDetailsDescriptionKey,
      _detailsDescriptionC.text.trim(),
    );
    await prefs.setString(_lastLocationKey, _appointmentLocationC.text.trim());
  }

  Future<void> _ensureOfflineTemporaryTransferSlots() async {
    final userId = _user?['id']?.toString();
    if (userId == null || userId.isEmpty) {
      return;
    }

    final existingCount = await _offlineTransferCodeService.countAvailableSlots(
      userId,
    );
    if (mounted && _availableOfflineTransferSlots != existingCount) {
      setState(() => _availableOfflineTransferSlots = existingCount);
    }

    if (_isDeviceOffline || !AppPermissions.fromUser(_user).canTransfer) {
      return;
    }

    if (existingCount >= 5) {
      return;
    }

    try {
      final deviceId = await LocalSecurityService.getOrCreateDeviceId();
      final response = await _apiService.prefetchTemporaryTransferCodes(
        deviceId: deviceId,
        count: 5 - existingCount,
      );
      final rawSlots = List<Map<String, dynamic>>.from(
        (response['slots'] as List? ?? const []).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
      final merged = await _offlineTransferCodeService.mergeSlots(
        userId,
        rawSlots,
      );
      if (mounted) {
        setState(() => _availableOfflineTransferSlots = merged.length);
      }
    } catch (_) {
      final fallbackCount = await _offlineTransferCodeService
          .countAvailableSlots(userId);
      if (mounted) {
        setState(() => _availableOfflineTransferSlots = fallbackCount);
      }
    }
  }

  AppPermissions get _appPermissions => AppPermissions.fromUser(_user);

  bool get _canIssuePrivateCards => _appPermissions.canIssuePrivateCards;
  bool get _canIssueGeneralBalanceCards =>
      _appPermissions.isAdminRole ||
      _appPermissions.canManageUsers ||
      _appPermissions.canManageCardPrintRequests;
  bool get _canPickTargetedUsers =>
      _canIssuePrivateCards || _requiresTargetedPrivateCard;

  bool get _canRequestCardPrinting => _appPermissions.canRequestCardPrinting;

  bool get _hasAccountLogo =>
      _user?['printLogoUrl']?.toString().trim().isNotEmpty == true;

  bool get _isAppointmentCard => _cardType == 'appointment';
  bool get _isQueueCard => _cardType == 'queue';
  bool get _isSubscriptionCard => _cardType == 'subscription';
  bool get _isAttendanceCard => _cardType == 'attendance';
  bool get _isVerifiedAccount =>
      (_user?['transferVerificationStatus']?.toString() ?? 'unverified') ==
      'approved';

  bool get _hasSelectedCardType => _cardType.trim().isNotEmpty;
  bool get _isBalanceCard => _cardType == 'standard' || _cardType == 'delivery';
  bool get _requiresTargetedPrivateCard => !_isBalanceCard;
  bool get _mustCreatePrivateBalanceCard =>
      _isBalanceCard &&
      (!_canIssueGeneralBalanceCards ||
          _appPermissions.isDriverRole ||
          !_isVerifiedAccount);
  String get _effectiveVisibilityScope =>
      _isTrialMode ||
          _requiresTargetedPrivateCard ||
          _mustCreatePrivateBalanceCard
      ? 'restricted'
      : _visibilityScope;
  bool get _needsTypeDetails =>
      _isAppointmentCard ||
      _isQueueCard ||
      _isSubscriptionCard ||
      _isAttendanceCard;
  bool get _isTrialMode => false;
  int get _minimumCardQuantity {
    if (_hasSelectedCardType && !_isBalanceCard) {
      return 1;
    }
    final raw = (_user?['cardOperationMinQuantity'] as num?)?.toInt() ?? 1;
    return raw < 1 ? 1 : raw;
  }

  String get _normalizedCustomBarcode => CardNumberExtractor.normalizeDigits(
    _customBarcodeC.text,
  ).replaceAll(RegExp(r'\D'), '');

  void _setLoadingState(
    bool value, {
    String headline = '',
    String details = '',
  }) {
    if (!mounted) {
      return;
    }
    setState(() {
      _isLoading = value;
      _loadingHeadline = value ? headline : '';
      _loadingDetails = value ? details : '';
    });
  }

  double get _trialCardsRemainingAmount =>
      ((_user?['trialCardsAvailableAmount'] as num?)?.toDouble() ??
              _trialCardsLimit)
          .clamp(0, _trialCardsLimit)
          .toDouble();
  double get _trialCardsOutstandingAmount =>
      ((_user?['trialCardsOutstandingAmount'] as num?)?.toDouble() ?? 0)
          .clamp(0, _trialCardsLimit)
          .toDouble();

  List<String> get _issuableCardTypes => _issuableCardTypesFromUser(_user);

  List<String> get _sortedIssuableCardTypes {
    final values = [..._issuableCardTypes];
    values.sort(
      (a, b) => (_cardTypeDisplayOrder[a] ?? 999).compareTo(
        _cardTypeDisplayOrder[b] ?? 999,
      ),
    );
    return values;
  }

  List<String> _issuableCardTypesFromUser(Map<String, dynamic>? user) {
    final raw = user?['cardIssuanceOptions'];
    if (raw is List) {
      final values = raw
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty && item != 'delivery')
          .toList();
      if (values.isNotEmpty) {
        return values;
      }
    }
    final permissions = AppPermissions.fromUser(user);
    final isTrialMode =
        (user?['transferVerificationStatus']?.toString() ?? 'unverified') !=
        'approved';
    if (!permissions.canIssueCards) {
      return isTrialMode ? const ['standard'] : const [];
    }
    if (user?['role']?.toString() == 'driver') {
      return const ['standard'];
    }
    final values = <String>['standard'];
    if (permissions.canIssueSingleUseTickets) {
      values.add('single_use');
    }
    if (permissions.canIssueAppointmentTickets) {
      values.addAll(['appointment', 'subscription', 'attendance']);
    }
    if (permissions.canIssueQueueTickets) {
      values.add('queue');
    }
    return values;
  }

  String _cardTypeLabel(AppLocalizer l, String type) {
    switch (type) {
      case 'single_use':
        return l.tr('screens_create_card_screen.003');
      case 'delivery':
        return l.tr('shared.delivery_card_label');
      case 'appointment':
        return l.tr('screens_create_card_screen.069');
      case 'queue':
        return l.tr('screens_create_card_screen.070');
      case 'subscription':
        return l.tr('screens_create_card_screen.087');
      case 'attendance':
        return l.tr('screens_create_card_screen.088');
      default:
        return l.tr('screens_create_card_screen.002');
    }
  }

  IconData _cardTypeIcon(String type) {
    switch (type) {
      case 'single_use':
        return Icons.confirmation_number_rounded;
      case 'delivery':
        return Icons.local_shipping_rounded;
      case 'appointment':
        return Icons.event_available_rounded;
      case 'queue':
        return Icons.people_alt_rounded;
      case 'subscription':
        return Icons.card_membership_rounded;
      case 'attendance':
        return Icons.badge_rounded;
      default:
        return Icons.credit_card_rounded;
    }
  }

  String _cardTypeDescription(String type) {
    final l = context.loc;
    switch (type) {
      case 'single_use':
        return l.tr('screens_create_card_screen.089');
      case 'delivery':
        return l.tr('screens_create_card_screen.090');
      case 'appointment':
        return l.tr('screens_create_card_screen.091');
      case 'queue':
        return l.tr('screens_create_card_screen.092');
      case 'subscription':
        return l.tr('screens_create_card_screen.093');
      case 'attendance':
        return l.tr('screens_create_card_screen.094');
      default:
        return l.tr('screens_create_card_screen.095');
    }
  }

  String _typeDetailsTitle() {
    final l = context.loc;
    if (_isAppointmentCard) return l.tr('screens_create_card_screen.096');
    if (_isQueueCard) return l.tr('screens_create_card_screen.097');
    if (_isSubscriptionCard) return l.tr('screens_create_card_screen.098');
    if (_isAttendanceCard) return l.tr('screens_create_card_screen.099');
    return l.tr('screens_create_card_screen.100');
  }

  String _typeTitleFieldLabel() {
    final l = context.loc;
    if (_isAppointmentCard) return l.tr('screens_create_card_screen.101');
    if (_isQueueCard) return l.tr('screens_create_card_screen.102');
    if (_isSubscriptionCard) return l.tr('screens_create_card_screen.103');
    if (_isAttendanceCard) return l.tr('screens_create_card_screen.104');
    return l.tr('screens_create_card_screen.105');
  }

  String _typeLocationFieldLabel() {
    final l = context.loc;
    if (_isAppointmentCard) return l.tr('screens_create_card_screen.106');
    if (_isQueueCard) return l.tr('screens_create_card_screen.107');
    if (_isSubscriptionCard) return l.tr('screens_create_card_screen.108');
    if (_isAttendanceCard) return l.tr('screens_create_card_screen.109');
    return l.tr('screens_create_card_screen.106');
  }

  String _typeDescriptionFieldLabel() {
    final l = context.loc;
    if (_isAppointmentCard) return l.tr('screens_create_card_screen.110');
    if (_isSubscriptionCard) return l.tr('screens_create_card_screen.098');
    if (_isAttendanceCard) return l.tr('screens_create_card_screen.111');
    return l.tr('screens_create_card_screen.112');
  }

  double _feeAmount(String key) =>
      (_feeSettings[key] as num?)?.toDouble() ?? 0.0;

  bool get _isPrivateIssuance => _effectiveVisibilityScope == 'restricted';

  double _issueFeePerCardForType(String type, {required bool isPrivate}) {
    if (_isTrialMode) {
      return 0;
    }
    final normalizedType = type.trim().toLowerCase();
    var fee = switch (normalizedType) {
      'single_use' => _feeAmount('singleUseTicketIssueCost'),
      'appointment' => _feeAmount('appointmentTicketIssueCost'),
      'queue' => _feeAmount('queueTicketIssueCost'),
      'subscription' => _feeAmount('subscriptionCardIssueCost'),
      'attendance' => _feeAmount('attendanceCardIssueCost'),
      'delivery' => _feeAmount('deliveryCardIssueCost'),
      _ => _feeAmount('standardCardIssueCost'),
    };
    final isTicket =
        normalizedType == 'single_use' ||
        normalizedType == 'appointment' ||
        normalizedType == 'queue' ||
        normalizedType == 'subscription' ||
        normalizedType == 'attendance';
    if (isPrivate && !isTicket) {
      fee += _feeAmount('privateCardIssueCost');
    }
    return fee > 0 ? fee : 0;
  }

  double _creationIssueFeePerCardForType(
    String type, {
    required bool isPrivate,
    required double cardValue,
  }) {
    final configured = _issueFeePerCardForType(type, isPrivate: isPrivate);
    final normalizedType = type.trim().toLowerCase();
    if (isPrivate &&
        (normalizedType == 'standard' || normalizedType == 'delivery')) {
      final percentCost = double.parse((cardValue * 0.01).toStringAsFixed(2));
      return [configured, percentCost, 0.02].reduce((a, b) => a > b ? a : b);
    }

    return configured;
  }

  double get _currentIssueFeePerCard => _creationIssueFeePerCardForType(
    _cardType,
    isPrivate: _isPrivateIssuance,
    cardValue: _currentCardFaceValue,
  );

  double get _currentChargedIssueFeePerCard {
    if (_isTrialMode) {
      return 0;
    }
    if (!_isPrivateIssuance) {
      return 0;
    }
    final quantity = int.tryParse(_qtyC.text.trim()) ?? 0;
    if (quantity <= 0) {
      return _currentIssueFeePerCard;
    }
    return double.parse(
      (_currentChargedIssueFeeTotal / quantity).toStringAsFixed(2),
    );
  }

  double get _monthlyPrivateCardFreeValueLimit =>
      (_user?['monthlyPrivateCardFreeValueLimit'] as num?)?.toDouble() ??
      (_feeSettings['monthlyPrivateCardFreeValueLimit'] as num?)?.toDouble() ??
      100.0;

  double get _monthlyPrivateCardFreeValueRemaining =>
      (_user?['monthlyPrivateCardFreeValueRemaining'] as num?)?.toDouble() ??
      _monthlyPrivateCardFreeValueLimit;

  double get _currentPrivateCardRequestedValue {
    if (!_isPrivateIssuance || !_isBalanceCard) {
      return 0;
    }
    final quantity = int.tryParse(_qtyC.text.trim()) ?? 0;
    return double.parse((_currentCardFaceValue * quantity).toStringAsFixed(2));
  }

  double get _currentFreePrivateCardValueApplied {
    final requested = _currentPrivateCardRequestedValue;
    if (requested <= 0) {
      return 0;
    }
    return [
      requested,
      _monthlyPrivateCardFreeValueRemaining,
    ].reduce((a, b) => a < b ? a : b);
  }

  double get _currentFreeIssueFeeAmount {
    final quantity = int.tryParse(_qtyC.text.trim()) ?? 0;
    final requested = _currentPrivateCardRequestedValue;
    if (quantity <= 0 || requested <= 0) {
      return 0;
    }
    final totalIssueFee = _currentIssueFeePerCard * quantity;
    final ratio = (_currentFreePrivateCardValueApplied / requested).clamp(
      0.0,
      1.0,
    );
    return double.parse((totalIssueFee * ratio).toStringAsFixed(2));
  }

  double get _currentChargedIssueFeeTotal {
    final quantity = int.tryParse(_qtyC.text.trim()) ?? 0;
    if (quantity <= 0) {
      return 0;
    }
    final total =
        (_currentIssueFeePerCard * quantity) - _currentFreeIssueFeeAmount;
    return double.parse((total < 0 ? 0 : total).toStringAsFixed(2));
  }

  double get _currentCardFaceValue {
    final amount = double.tryParse(_amountC.text.trim()) ?? 0;
    return _isBalanceCard || _isAppointmentCard ? amount : 0;
  }

  double get _currentChargeNowPerCard => _isPrivateIssuance
      ? _currentChargedIssueFeePerCard
      : _currentCardFaceValue + _currentChargedIssueFeePerCard;

  double get _currentTotalChargeNow {
    final quantity = int.tryParse(_qtyC.text.trim()) ?? 0;
    if (_isPrivateIssuance) {
      return _currentChargedIssueFeeTotal;
    }
    return _currentChargeNowPerCard * quantity;
  }

  String? _validateAmountForCardType(double amount) {
    if (_isBalanceCard) {
      return amount > 0
          ? null
          : context.loc.tr('screens_create_card_screen.071');
    }

    if (_isAppointmentCard && amount < 0) {
      return context.loc.tr('screens_create_card_screen.072');
    }

    return null;
  }

  Future<void> _create() async {
    final l = context.loc;
    if (!_isAuthorized) {
      await AppAlertService.showError(
        context,
        title: l.tr('screens_create_card_screen.004'),
        message: l.tr('screens_create_card_screen.050'),
      );
      return;
    }
    if (!_hasSelectedCardType) {
      await AppAlertService.showError(
        context,
        title: l.tr('screens_create_card_screen.113'),
        message: l.tr('screens_create_card_screen.114'),
      );
      return;
    }
    final enteredAmount = double.tryParse(_amountC.text) ?? 0;
    final amount = (_isBalanceCard || _isAppointmentCard) ? enteredAmount : 0.0;
    final quantity = int.tryParse(_qtyC.text) ?? 0;
    if (quantity <= 0) {
      await AppAlertService.showError(
        context,
        title: l.tr('screens_create_card_screen.004'),
        message: l.tr('screens_create_card_screen.073'),
      );
      return;
    }

    if (!_quickMode && !_useCustomBarcode && quantity < _minimumCardQuantity) {
      await AppAlertService.showError(
        context,
        title: l.tr('screens_create_card_screen.004'),
        message: l.tr(
          'screens_create_card_screen.074',
          params: {'count': '$_minimumCardQuantity'},
        ),
      );
      return;
    }

    if (_useCustomBarcode &&
        (quantity != 1 ||
            _normalizedCustomBarcode.length !=
                CardNumberExtractor.cardNumberLength)) {
      await AppAlertService.showError(
        context,
        title: l.text('تحقق من رقم البطاقة', 'Check Card Number'),
        message: quantity != 1
            ? l.text(
                'يمكن تخصيص الرقم عند إصدار بطاقة واحدة فقط.',
                'Custom number is only available when issuing one card.',
              )
            : l.text(
                'رقم البطاقة المخصص يجب أن يتكون من 16 رقمًا.',
                'Custom card number must be 16 digits.',
              ),
      );
      return;
    }

    final amountValidationMessage = _validateAmountForCardType(amount);
    if (amountValidationMessage != null) {
      await AppAlertService.showError(
        context,
        title: l.tr('screens_create_card_screen.004'),
        message: amountValidationMessage,
      );
      return;
    }

    if (_isTrialMode) {
      final totalAmount = amount * quantity;
      if (totalAmount > _trialCardsRemainingAmount) {
        await AppAlertService.showError(
          context,
          title: l.tr('screens_create_card_screen.077'),
          message: l.tr(
            'screens_create_card_screen.078',
            params: {
              'amount': CurrencyFormatter.ils(_trialCardsRemainingAmount),
            },
          ),
        );
        return;
      }
    }

    if (_isAppointmentCard) {
      if (_detailsTitleC.text.trim().isEmpty || _appointmentStartsAt == null) {
        await AppAlertService.showError(
          context,
          title: l.tr('screens_create_card_screen.079'),
          message: l.tr('screens_create_card_screen.080'),
        );
        return;
      }

      if (_appointmentEndsAt != null &&
          !_appointmentEndsAt!.isAfter(_appointmentStartsAt!)) {
        await AppAlertService.showError(
          context,
          title: l.tr('screens_create_card_screen.081'),
          message: l.tr('screens_create_card_screen.082'),
        );
        return;
      }
    }

    if (_isQueueCard && _detailsTitleC.text.trim().isEmpty) {
      await AppAlertService.showError(
        context,
        title: l.tr('screens_create_card_screen.083'),
        message: l.tr('screens_create_card_screen.084'),
      );
      return;
    }

    if (_isSubscriptionCard) {
      if (_detailsTitleC.text.trim().isEmpty) {
        await AppAlertService.showError(
          context,
          title: l.tr('screens_create_card_screen.115'),
          message: l.tr('screens_create_card_screen.116'),
        );
        return;
      }
      if (_validFrom == null || _validUntil == null) {
        await AppAlertService.showError(
          context,
          title: l.tr('screens_create_card_screen.117'),
          message: l.tr('screens_create_card_screen.118'),
        );
        return;
      }
    }

    if (_isAttendanceCard) {
      if (_detailsTitleC.text.trim().isEmpty) {
        await AppAlertService.showError(
          context,
          title: l.tr('screens_create_card_screen.119'),
          message: l.tr('screens_create_card_screen.120'),
        );
        return;
      }
      if (quantity > 1) {
        await AppAlertService.showError(
          context,
          title: l.tr('screens_create_card_screen.121'),
          message: l.tr('screens_create_card_screen.122'),
        );
        return;
      }
    }

    if (_validFrom != null &&
        _validUntil != null &&
        !_validUntil!.isAfter(_validFrom!)) {
      await AppAlertService.showError(
        context,
        title: l.tr('screens_create_card_screen.085'),
        message: l.tr('screens_create_card_screen.086'),
      );
      return;
    }

    await _savePrintPreferences();
    final confirmed = _quickMode
        ? await _showQuickIssueConfirmation(amount: amount)
        : true;
    if (confirmed != true) {
      return;
    }

    if (_quickMode && _isDeviceOffline) {
      await _createQuickOfflineTransferCard(amount);
      return;
    }

    final cards = await (_isTrialMode
        ? _issueTrialCardsAfterSecurity(amount, quantity)
        : _issueCardsAfterSecurity(amount, quantity));
    if (cards == null || !mounted) {
      return;
    }

    setState(() {
      _recent = cards;
    });
    _setLoadingState(
      true,
      headline: l.tr('screens_create_card_screen.123'),
      details: l.tr('screens_create_card_screen.124'),
    );
    await _load();
    _setLoadingState(false);
    if (mounted) {
      _showSuccess(cards);
    }
  }

  Future<List<VirtualCard>?> _issueCardsAfterSecurity(
    double amount,
    int quantity,
  ) async {
    final l = context.loc;
    var securityResult = await TransferSecurityService.confirmTransfer(context);
    if (!mounted || !securityResult.isVerified) {
      return null;
    }

    for (var attempt = 0; attempt < 2; attempt++) {
      _setLoadingState(
        true,
        headline: l.tr('screens_create_card_screen.125'),
        details: l.tr('screens_create_card_screen.126'),
      );
      try {
        final cards = await _apiService.issueCards(
          value: amount,
          quantity: quantity,
          cardType: _cardType,
          visibilityScope: _effectiveVisibilityScope,
          printDesign: _currentPrintDesign(),
          validFrom: _validFrom?.toUtc().toIso8601String(),
          validUntil: _validUntil?.toUtc().toIso8601String(),
          cardDetails: _currentCardDetails(),
          otpCode: securityResult.otpCode,
          securityPin: securityResult.securityPin,
          localAuthMethod: securityResult.method,
          allowedUserIds: _selectedAllowedUserIds(),
          allowedUserPhones: _selectedAllowedUserPhones(),
          customBarcode: _useCustomBarcode ? _normalizedCustomBarcode : null,
        );
        final userId = _user?['id']?.toString();
        if (userId != null && userId.isNotEmpty) {
          await _cacheIssuedCards(userId: userId, cards: cards);
        }
        return cards;
      } catch (error) {
        if (!mounted) {
          return null;
        }
        final message = ErrorMessageService.sanitize(error);
        _setLoadingState(false);

        if (attempt == 0 && _isLocalSecurityRequiredMessage(message)) {
          securityResult = await TransferSecurityService.confirmTransfer(
            context,
          );
          if (!mounted || !securityResult.isVerified) {
            return null;
          }
          continue;
        }

        await AppAlertService.showError(
          context,
          title: l.tr('screens_create_card_screen.018'),
          message: message,
        );
        return null;
      }
    }

    return null;
  }

  Future<List<VirtualCard>?> _issueTrialCardsAfterSecurity(
    double amount,
    int quantity,
  ) async {
    final l = context.loc;
    var securityResult = await TransferSecurityService.confirmTransfer(context);
    if (!mounted || !securityResult.isVerified) {
      return null;
    }

    final baseTitle = _detailsTitleC.text.trim();
    final trialCardType = _cardType.trim().isEmpty
        ? 'standard'
        : _cardType.trim();
    final trialIsBalanceCard =
        trialCardType == 'standard' || trialCardType == 'delivery';
    final trialValue = trialIsBalanceCard ? amount : 0.0;
    final trialDetails = _currentCardDetails();
    final items = List.generate(quantity, (index) {
      return <String, dynamic>{
        'value': trialValue,
        'cardType': trialCardType,
        'cardDetails': trialDetails,
        if (baseTitle.isNotEmpty)
          'title': quantity == 1 ? baseTitle : '$baseTitle ${index + 1}',
        if (_useCustomBarcode && quantity == 1)
          'customBarcode': _normalizedCustomBarcode,
      };
    });

    for (var attempt = 0; attempt < 2; attempt++) {
      _setLoadingState(
        true,
        headline: l.tr('screens_create_card_screen.127'),
        details: l.tr('screens_create_card_screen.128'),
      );
      try {
        final cards = await _apiService.issueTrialCards(
          items: items,
          cardType: trialCardType,
          otpCode: securityResult.otpCode,
          securityPin: securityResult.securityPin,
          localAuthMethod: securityResult.method,
        );
        final userId = _user?['id']?.toString();
        if (userId != null && userId.isNotEmpty) {
          await _cacheIssuedCards(userId: userId, cards: cards);
        }
        return cards;
      } catch (error) {
        if (!mounted) {
          return null;
        }
        final message = ErrorMessageService.sanitize(error);
        _setLoadingState(false);

        if (attempt == 0 && _isLocalSecurityRequiredMessage(message)) {
          securityResult = await TransferSecurityService.confirmTransfer(
            context,
          );
          if (!mounted || !securityResult.isVerified) {
            return null;
          }
          continue;
        }

        await AppAlertService.showError(
          context,
          title: l.tr('screens_create_card_screen.129'),
          message: message,
        );
        return null;
      }
    }

    return null;
  }

  Future<void> _cacheIssuedCards({
    required String userId,
    required List<VirtualCard> cards,
  }) async {
    try {
      await _offlineCardService.mergeCardsIntoCache(
        userId: userId,
        cards: cards,
      );
    } catch (_) {
      // Offline cache should never make a successful card issue look failed.
    }
  }

  Future<bool> _showQuickIssueConfirmation({required double amount}) async {
    final l = context.loc;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.text('تأكيد إنشاء البطاقة', 'Confirm Card Creation')),
        contentPadding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l.text(
                  'سيتم إنشاء بطاقة فعلية واحدة وعرضها مباشرة بعد التأكيد.',
                  'A real card will be created and shown immediately after confirmation.',
                ),
                textDirection: TextDirection.rtl,
                style: AppTheme.bodyAction.copyWith(height: 1.5),
              ),
              const SizedBox(height: 16),
              ShwakelCard(
                padding: const EdgeInsets.all(16),
                color: AppTheme.surfaceVariant,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildPreviewSummaryRow(
                      l.text('قيمة البطاقة', 'Card Value'),
                      CurrencyFormatter.ils(amount),
                    ),
                    const SizedBox(height: 8),
                    _buildPreviewSummaryRow(
                      l.text('الخصم من الرصيد', 'Balance Deduction'),
                      CurrencyFormatter.ils(_currentTotalChargeNow),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(l.text('إلغاء', 'Cancel')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ShwakelButton(
                  label: l.text('تأكيد الإنشاء', 'Confirm Creation'),
                  onPressed: () => Navigator.pop(dialogContext, true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _createQuickOfflineTransferCard(double amount) async {
    final userId = _user?['id']?.toString();
    if (userId == null || userId.isEmpty) {
      return;
    }

    if (!AppPermissions.fromUser(_user).canTransfer) {
      final l = context.loc;
      await AppAlertService.showError(
        context,
        title: l.text(
          'الإنشاء الأوفلاين غير متاح',
          'Offline Creation Unavailable',
        ),
        message: l.text(
          'إنشاء بطاقة أوفلاين يحتاج صلاحية التحويل لأن المستلم سيستلم القيمة مباشرة عند مسح الرمز وهو متصل.',
          'Offline card creation requires transfer permission because the recipient receives the value directly when scanning the code while online.',
        ),
      );
      return;
    }

    final security = await TransferSecurityService.confirmTransfer(
      context,
      requireOtpAfterLocalAuth: false,
      allowOtpFallback: false,
    );
    if (!mounted || !security.isVerified) {
      return;
    }

    final payload = await _buildQuickOfflineTransferPayload(amount);
    if (!mounted || payload == null) {
      return;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _QuickOfflineTransferCardDialog(payload: payload),
    );
  }

  Future<_QuickOfflineTransferPayload?> _buildQuickOfflineTransferPayload(
    double amount,
  ) async {
    final userId = _user?['id']?.toString();
    if (userId == null || userId.isEmpty) {
      return null;
    }

    final slot = await _offlineTransferCodeService.takeNextSlot(userId);
    if (slot == null) {
      await _ensureOfflineTemporaryTransferSlots();
      if (!mounted) {
        return null;
      }
      final l = context.loc;
      await AppAlertService.showInfo(
        context,
        title: l.text('لا توجد بطاقات أوفلاين جاهزة', 'No Offline Cards Ready'),
        message: l.text(
          'افتح هذه الشاشة مرة واحدة أثناء الاتصال ليتم تجهيز بطاقات أوفلاين آمنة مرتبطة بهذا الجهاز.',
          'Open this screen once while connected to prepare secure offline cards linked to this device.',
        ),
      );
      return null;
    }

    final expiresAt = DateTime.tryParse(
      slot['expiresAt']?.toString() ?? '',
    )?.toUtc();
    final slotId = slot['id']?.toString() ?? '';
    final token = slot['publicToken']?.toString() ?? '';
    final signingSecret = slot['signingSecret']?.toString() ?? '';
    if (expiresAt == null ||
        !expiresAt.isAfter(DateTime.now().toUtc()) ||
        slotId.isEmpty ||
        token.isEmpty ||
        signingSecret.isEmpty) {
      await _ensureOfflineTemporaryTransferSlots();
      return null;
    }

    final signedAt = DateTime.now().toUtc().toIso8601String();
    final expiresAtIso = expiresAt.toIso8601String();
    final signature = await _quickOfflineTransferSignature(
      slotId: slotId,
      token: token,
      amount: amount,
      signedAt: signedAt,
      expiresAt: expiresAtIso,
      signingSecret: signingSecret,
    );

    await _ensureOfflineTemporaryTransferSlots();

    final envelope = {
      'type': 'shwakel_temp_transfer_offline',
      'version': 2,
      'slotId': slotId,
      'token': token,
      'amount': amount,
      'signedAt': signedAt,
      'expiresAt': expiresAtIso,
      'signature': signature,
      'senderId': _user?['id']?.toString(),
      'senderUsername': _user?['username']?.toString() ?? '',
      'source': 'quick_card_offline',
    };

    return _QuickOfflineTransferPayload(
      qrPayload: jsonEncode(envelope),
      amount: amount,
      expiresAt: expiresAt.toLocal(),
      senderUsername: _user?['username']?.toString() ?? '',
    );
  }

  Future<String> _quickOfflineTransferSignature({
    required String slotId,
    required String token,
    required double amount,
    required String signedAt,
    required String expiresAt,
    required String signingSecret,
  }) async {
    final message =
        '$slotId|$token|${amount.toStringAsFixed(2)}|$signedAt|$expiresAt';
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode(message),
      secretKey: SecretKey(utf8.encode(signingSecret)),
    );
    return mac.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Map<String, dynamic> _currentPrintDesign() {
    final l = context.loc;
    return {
      'logoText': _titleC.text.trim().isEmpty
          ? l.tr('screens_create_card_screen.001')
          : _titleC.text.trim(),
      'stampText': _stampC.text.trim().isEmpty
          ? l.tr('screens_create_card_screen.019')
          : _stampC.text.trim(),
      'logoUrl': (_showLogo && _useAccountLogo)
          ? (_user?['printLogoUrl'])?.toString()
          : null,
      'showStamp': _showStamp,
    };
  }

  Map<String, dynamic>? _currentCardDetails() {
    final details = <String, dynamic>{};
    if (_quickMode) {
      details['quickIssue'] = true;
    }
    if (_detailsTitleC.text.trim().isNotEmpty) {
      details['title'] = _detailsTitleC.text.trim();
    }
    if (_detailsDescriptionC.text.trim().isNotEmpty) {
      details['description'] = _detailsDescriptionC.text.trim();
    }
    if (_appointmentLocationC.text.trim().isNotEmpty) {
      details['location'] = _appointmentLocationC.text.trim();
    }
    if (_appointmentStartsAt != null) {
      details['startsAt'] = _appointmentStartsAt!.toUtc().toIso8601String();
    }
    if (_appointmentEndsAt != null) {
      details['endsAt'] = _appointmentEndsAt!.toUtc().toIso8601String();
    }
    if (_isAppointmentCard) {
      details['ticketKind'] = 'appointment';
    } else if (_isQueueCard) {
      details['ticketKind'] = 'queue';
    } else if (_isSubscriptionCard) {
      details['ticketKind'] = 'subscription';
      details['subscriptionName'] = _detailsTitleC.text.trim();
      if (_detailsDescriptionC.text.trim().isNotEmpty) {
        details['subscriptionDetails'] = _detailsDescriptionC.text.trim();
      }
    } else if (_isAttendanceCard) {
      details['ticketKind'] = 'attendance';
      details['employeeName'] = _detailsTitleC.text.trim();
      if (_appointmentLocationC.text.trim().isNotEmpty) {
        details['department'] = _appointmentLocationC.text.trim();
        details['attendanceSystem'] = _appointmentLocationC.text.trim();
      }
      if (_detailsDescriptionC.text.trim().isNotEmpty) {
        details['employeeCode'] = _detailsDescriptionC.text.trim();
        details['integrationReference'] = _detailsDescriptionC.text.trim();
      }
    }
    return details.isEmpty ? null : details;
  }

  String _cardValueLabel(AppLocalizer l, double amount) {
    if (_cardType == 'single_use' || _isQueueCard || _isAttendanceCard) {
      return amount <= 0
          ? l.text('تذكرة استخدام تنظيمي', 'Organizational Use Ticket')
          : CurrencyFormatter.ils(amount);
    }
    if ((_isAppointmentCard || _isSubscriptionCard) && amount <= 0) {
      return l.text('بدون قيمة مالية', 'No Monetary Value');
    }
    return CurrencyFormatter.ils(amount);
  }

  String _formatValidityWindow() {
    final l = context.loc;
    if (_validFrom == null && _validUntil == null) {
      return '';
    }
    if (_validFrom != null && _validUntil != null) {
      return '${_formatDateTime(_validFrom)} - ${_formatDateTime(_validUntil)}';
    }
    if (_validFrom != null) {
      return '${l.text('من', 'From')} ${_formatDateTime(_validFrom)}';
    }
    return '${l.text('حتى', 'Until')} ${_formatDateTime(_validUntil)}';
  }

  String _formatDateTime(DateTime? value) {
    if (value == null) {
      return '-';
    }
    final local = value.toLocal();
    final year = local.year.toString().padLeft(4, '0');
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$year/$month/$day $hour:$minute';
  }

  Widget _buildDateTimeField({
    required String label,
    required DateTime? value,
    required IconData icon,
    required Future<void> Function() onPick,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onPick,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          suffixIcon: value == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear_rounded),
                  onPressed: () {
                    setState(() {
                      if (label == 'فعالة من') {
                        _validFrom = null;
                      } else if (label == 'تنتهي في') {
                        _validUntil = null;
                      } else if (label == 'بداية الموعد') {
                        _appointmentStartsAt = null;
                      } else if (label == 'نهاية الموعد') {
                        _appointmentEndsAt = null;
                      }
                    });
                  },
                ),
        ),
        child: Text(
          value == null
              ? context.loc.text('اختر التاريخ والوقت', 'Select date and time')
              : _formatDateTime(value),
          style: value == null
              ? AppTheme.bodyAction.copyWith(color: AppTheme.textSecondary)
              : AppTheme.bodyBold,
        ),
      ),
    );
  }

  Future<void> _pickDateTime({
    required DateTime? initialValue,
    required void Function(DateTime value) onChanged,
  }) async {
    final now = DateTime.now();
    final start = initialValue?.toLocal() ?? now;
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: start,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (pickedDate == null || !mounted) {
      return;
    }

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(start),
    );
    if (pickedTime == null || !mounted) {
      return;
    }

    onChanged(
      DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      ),
    );
  }

  List<String> _selectedAllowedUserIds() {
    return _selectedUsers
        .map((user) => user['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
  }

  List<String> _selectedAllowedUserPhones() {
    return _selectedPhoneNumbers
        .map((phone) => phone.trim())
        .where((phone) => phone.isNotEmpty)
        .toList();
  }

  Future<void> _addAllowedPhoneFromInput() async {
    final l = context.loc;
    final raw = _allowedPhoneC.text.trim();
    final normalized = PhoneNumberService.normalize(
      input: raw,
      defaultDialCode: _recipientCountryCode,
    );
    if (normalized.length < 6) {
      await AppAlertService.showError(
        context,
        title: l.text('رقم غير صالح', 'Invalid Number'),
        message: l.text(
          'أدخل رقم الهاتف مع اختيار الدولة أولًا.',
          'Enter the phone number after selecting the country.',
        ),
      );
      return;
    }

    if (_selectedPhoneNumbers.any((item) => item == normalized) ||
        _selectedUsers.any(
          (user) => user['whatsapp']?.toString() == normalized,
        )) {
      _allowedPhoneC.clear();
      return;
    }

    setState(() => _isLoading = true);
    try {
      final lookup = await _apiService.lookupUserByPhone(
        phone: raw,
        countryCode: _recipientCountryCode,
        inviteIfMissing: true,
      );
      if (!mounted) return;
      if (lookup['exists'] == true && lookup['user'] is Map) {
        final user = Map<String, dynamic>.from(lookup['user'] as Map);
        setState(() {
          _selectedUsers = [
            ..._selectedUsers.where(
              (item) => item['id']?.toString() != user['id']?.toString(),
            ),
            user,
          ];
          _allowedPhoneC.clear();
        });
        await AppAlertService.showSuccess(
          context,
          title: l.text('تم اختيار الحساب', 'Account Selected'),
          message: l.text(
            'تم العثور على الحساب وإضافته للمستفيدين.',
            'The account was found and added as a recipient.',
          ),
        );
        return;
      }

      if (!mounted) return;
      setState(() {
        _selectedPhoneNumbers = [..._selectedPhoneNumbers, normalized];
        _allowedPhoneC.clear();
      });
      await AppAlertService.showInfo(
        context,
        title: l.text('تم إرسال دعوة', 'Invitation Sent'),
        message: l.text(
          'لا يوجد حساب بهذا الرقم حاليًا. تم إرسال دعوة واتساب له، وسيبقى الرقم ضمن المستفيدين عند التسجيل بنفس الرقم.',
          'No account exists for this number yet. A WhatsApp invitation was sent, and the number remains allowed when they register with it.',
        ),
      );
    } catch (error) {
      if (!mounted) return;
      await AppAlertService.showError(
        context,
        title: l.text('تعذر إضافة المستفيد', 'Could Not Add Recipient'),
        message: ErrorMessageService.sanitize(error),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  bool _isLocalSecurityRequiredMessage(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('pin') &&
        (normalized.contains('البصمة') ||
            normalized.contains('biometric') ||
            normalized.contains('otp')) &&
        (normalized.contains('تأكيد') || normalized.contains('confirm'));
  }

  Future<bool> _confirmCardOutputSecurity() async {
    final security = await TransferSecurityService.confirmTransfer(context);
    return mounted && security.isVerified;
  }

  CardDesignSettings _currentPdfDesignSettings() {
    final l = context.loc;
    final settings = CardDesignSettings(
      showLogo: _showLogo,
      showStamp: _showStamp,
      logoText: _titleC.text.trim().isEmpty
          ? l.tr('screens_create_card_screen.001')
          : _titleC.text.trim(),
      stampText: _stampC.text.trim().isEmpty
          ? l.tr('screens_create_card_screen.019')
          : _stampC.text.trim(),
    );
    settings.logoUrl = (_showLogo && _useAccountLogo)
        ? (_user?['printLogoUrl'])?.toString()
        : null;
    return settings;
  }

  void _applyCurrentPdfDesignSettings() {
    _pdfService.setDesignSettings(_currentPdfDesignSettings());
  }

  List<VirtualCard> _cardsWithPrintFallbacks(List<VirtualCard> cards) {
    final currentAmount = double.tryParse(_amountC.text.trim()) ?? 0;
    final currentDetails = _currentCardDetails() ?? const <String, dynamic>{};
    return cards
        .map(
          (card) => card.copyWith(
            value: card.value > 0 ? card.value : currentAmount,
            cardType: card.cardType.trim().isNotEmpty
                ? card.cardType
                : (_hasSelectedCardType ? _cardType : 'standard'),
            visibilityScope: card.visibilityScope.trim().isNotEmpty
                ? card.visibilityScope
                : _effectiveVisibilityScope,
            details: card.details.isNotEmpty ? card.details : currentDetails,
          ),
        )
        .toList();
  }

  Future<void> _printCards(
    List<VirtualCard> cards, {
    bool requireSecurity = true,
  }) async {
    if (requireSecurity && !await _confirmCardOutputSecurity()) {
      return;
    }
    if (!mounted) {
      return;
    }

    final l = context.loc;
    final printedBy = _resolvedIssuerName(l);

    _applyCurrentPdfDesignSettings();
    await _savePrintPreferences();
    try {
      final exportCards = _cardsWithPrintFallbacks(cards);
      // Validate that we can generate the PDF sheet before opening the printer dialog.
      final pdf = await _pdfService.createMultiCardPDF(
        exportCards,
        printedBy: printedBy,
      );
      final bytes = await pdf.save();
      if (bytes.isEmpty) {
        throw Exception('تعذر توليد ملف الطباعة.');
      }
      // Extra guard: attempt rasterizing page 1 to ensure rendering works.
      try {
        final stream = Printing.raster(bytes, pages: const [0], dpi: 110);
        await stream.first;
      } catch (_) {
        throw Exception('تعذر تجهيز معاينة الطباعة. يرجى المحاولة لاحقاً.');
      }
      await _pdfService.printPdfBytes(bytes);
    } catch (error) {
      if (!mounted) {
        return;
      }
      await AppAlertService.showError(
        context,
        title: l.tr(
          'screens_admin_card_print_requests_screen.print_failed_title',
        ),
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  Future<void> _requestCardsPrint(List<VirtualCard> cards) async {
    if (!mounted || _isLoading) {
      return;
    }
    final l = context.loc;

    final cardIds = cards
        .map((card) => card.id.trim())
        .where((id) => id.isNotEmpty)
        .toList();
    if (cardIds.isEmpty) {
      await AppAlertService.showError(
        context,
        title: l.text('تعذر إرسال طلب الطباعة', 'Failed to Send Print Request'),
        message: l.text(
          'لا توجد بطاقات صالحة لإرسالها للإدارة.',
          'No valid cards to send to the admin.',
        ),
      );
      return;
    }

    final estimatedPages = (cardIds.length / _cardsPerA4Page).ceil().clamp(
      1,
      9999,
    );
    final estimatedFee = (estimatedPages / 3).ceil();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final dl = context.loc;
        return AlertDialog(
          title: Text(dl.text('تأكيد طلب الطباعة', 'Confirm Print Request')),
          content: Text(
            dl.text(
              'سيتم إرسال ${cardIds.length} بطاقة للإدارة وخصم رسوم الطباعة حسب إعدادات النظام.\nالتقدير الحالي: $estimatedPages صفحة A4، ورسوم تقريبية $estimatedFee شيكل.',
              '${cardIds.length} cards will be sent to admin and printing fees deducted per system settings.\nCurrent estimate: $estimatedPages A4 page(s), approx. $estimatedFee shekel.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(dl.text('إلغاء', 'Cancel')),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.print_rounded),
              label: Text(dl.text('إرسال الطلب', 'Send Request')),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    if (!mounted) {
      return;
    }

    final security = await TransferSecurityService.confirmTransfer(
      context,
      allowOtpFallback: true,
    );
    if (!mounted || !security.isVerified) {
      return;
    }

    const notes = 'طلب طباعة من شاشة إنشاء البطاقة';
    final fingerprint = jsonEncode({'cardIds': cardIds, 'notes': notes});
    if (_pendingPrintRequestFingerprint != fingerprint) {
      _pendingPrintRequestFingerprint = fingerprint;
      _pendingPrintRequestIdempotencyKey = _uuid.v4();
    }

    _setLoadingState(
      true,
      headline: l.text('جارٍ إرسال طلب الطباعة...', 'Sending print request...'),
      details: l.text(
        'سيتم إشعار الإدارة بالبطاقات المطلوبة للطباعة.',
        'Admin will be notified about the requested cards for printing.',
      ),
    );
    try {
      final response = await _apiService.requestExistingCardsPrint(
        idempotencyKey: _pendingPrintRequestIdempotencyKey!,
        cardIds: cardIds,
        notes: notes,
        otpCode: security.otpCode,
        securityPin: security.securityPin,
      );
      if (!mounted) {
        return;
      }
      _setLoadingState(false);
      _pendingPrintRequestFingerprint = null;
      _pendingPrintRequestIdempotencyKey = null;
      await AppAlertService.showSuccess(
        context,
        title: l.text('تم إرسال طلب الطباعة', 'Print Request Sent'),
        message:
            response['message']?.toString() ??
            l.text(
              'تم إرسال الطلب إلى الإدارة وبانتظار المراجعة.',
              'Request sent to admin and awaiting review.',
            ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      _setLoadingState(false);
      await AppAlertService.showError(
        context,
        title: l.text('تعذر إرسال طلب الطباعة', 'Failed to Send Print Request'),
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  Future<void> _saveCardsPdf(List<VirtualCard> cards) async {
    if (!mounted) {
      return;
    }
    final l = context.loc;
    final printedBy = _resolvedIssuerName(l);
    _applyCurrentPdfDesignSettings();
    await _savePrintPreferences();
    try {
      final exportCards = _cardsWithPrintFallbacks(cards);
      final pdf = await _pdfService.createMultiCardPDF(
        exportCards,
        printedBy: printedBy,
      );
      final timestamp = DateTime.now().toIso8601String().replaceAll(
        RegExp(r'[:.]'),
        '-',
      );
      final file = await _pdfService.savePDF(pdf, 'shwakil_cards_$timestamp');
      if (!mounted) {
        return;
      }
      await AppAlertService.showInfo(
        context,
        title: l.text('تم حفظ نسخة PDF', 'PDF Copy Saved'),
        message: l.text(
          'تم تنزيل الملف في:\n${file.path}',
          'File downloaded to:\n${file.path}',
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      await AppAlertService.showError(
        context,
        title: l.tr(
          'screens_admin_card_print_requests_screen.print_failed_title',
        ),
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  String _resolvedIssuerName(AppLocalizer l) {
    final printTitle = _titleC.text.trim();
    if (printTitle.isNotEmpty) {
      return printTitle;
    }
    return UserDisplayName.fromMap(
      _user,
      fallback: l.tr('screens_create_card_screen.001'),
    );
  }

  void _showSuccess(List<VirtualCard> cards) {
    final l = context.loc;
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.tr('screens_create_card_screen.020')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l.tr(
                    'screens_create_card_screen.021',
                    params: {'count': '${cards.length}'},
                  ),
                ),
                const SizedBox(height: 14),
                if (_quickMode && cards.length == 1) ...[
                  _buildQuickIssuedCard(cards.first),
                  const SizedBox(height: 14),
                ],
                if (cards.isNotEmpty) _buildIssuedCardsDetails(cards),
              ],
            ),
          ),
        ),
        actions: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ShwakelButton(
                label: 'تنزيل نسخة PDF',
                icon: Icons.picture_as_pdf_rounded,
                onPressed: () async {
                  Navigator.pop(dialogContext);
                  await _saveCardsPdf(cards);
                },
              ),
              if (_quickMode &&
                  cards.length == 1 &&
                  cards.first.status == CardStatus.unused) ...[
                const SizedBox(height: 8),
                ShwakelButton(
                  label: 'إلغاء البطاقة واسترجاع الرصيد',
                  icon: Icons.undo_rounded,
                  isSecondary: true,
                  onPressed: () async {
                    Navigator.pop(dialogContext);
                    await _cancelIssuedCard(cards.first);
                  },
                ),
              ],
              if (_canRequestCardPrinting) ...[
                const SizedBox(height: 8),
                ShwakelButton(
                  label: 'طلب طباعة',
                  icon: Icons.print_rounded,
                  isSecondary: true,
                  onPressed: () async {
                    Navigator.pop(dialogContext);
                    await _requestCardsPrint(cards);
                  },
                ),
              ],
              const SizedBox(height: 8),
              ShwakelButton(
                label: 'فتح مخزون البطاقات',
                icon: Icons.inventory_2_rounded,
                isSecondary: true,
                onPressed: () {
                  Navigator.pop(dialogContext);
                  _openRoute('/inventory');
                },
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(l.tr('screens_create_card_screen.022')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuickIssuedCard(VirtualCard card) {
    final l = context.loc;
    return ShwakelCard(
      padding: const EdgeInsets.all(14),
      color: AppTheme.surface,
      borderColor: AppTheme.primary.withValues(alpha: 0.16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.offline_bolt_rounded, color: AppTheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.text(
                    'البطاقة جاهزة للاستخدام المباشر',
                    'Card Ready for Direct Use',
                  ),
                  style: AppTheme.bodyBold.copyWith(color: AppTheme.primary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildCardPreviewWidget(card, serialNumber: 1),
          const SizedBox(height: 10),
          _buildPreviewSummaryRow(
            l.text('رقم البطاقة', 'Card Number'),
            card.barcode,
          ),
          const SizedBox(height: 8),
          _buildPreviewSummaryRow(
            l.text('القيمة', 'Value'),
            CurrencyFormatter.ils(card.value),
          ),
        ],
      ),
    );
  }

  Future<void> _cancelIssuedCard(VirtualCard card) async {
    final l = context.loc;
    if (_isLoading) {
      return;
    }
    if (card.status != CardStatus.unused) {
      await AppAlertService.showError(
        context,
        title: l.text('لا يمكن إلغاء البطاقة', 'Cannot Cancel Card'),
        message: l.text(
          'يمكن إلغاء البطاقة فقط قبل استخدامها.',
          'The card can only be cancelled before use.',
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.text('تأكيد إلغاء البطاقة', 'Confirm Card Cancellation')),
        content: Text(
          l.text(
            'سيتم إلغاء البطاقة غير المستخدمة واسترجاع الرصيد حسب النظام. هل تريد المتابعة؟',
            'The unused card will be cancelled and the balance refunded according to policy. Continue?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.text('تراجع', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l.text('متابعة', 'Continue')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final security = await TransferSecurityService.confirmTransfer(
      context,
      allowOtpFallback: true,
    );
    if (!mounted || !security.isVerified) {
      return;
    }
    try {
      setState(() => _isLoading = true);
      await _apiService.deleteCard(
        card.id,
        otpCode: security.otpCode,
        securityPin: security.securityPin,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _recent = _recent.where((item) => item.id != card.id).toList();
      });
      await _load();
      if (!mounted) {
        return;
      }
      await AppAlertService.showSuccess(
        context,
        title: l.text('تم إلغاء البطاقة', 'Card Cancelled'),
        message: l.text(
          'تم إلغاء البطاقة غير المستخدمة واسترجاع الرصيد حسب النظام.',
          'The unused card has been cancelled and balance refunded per system policy.',
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      await AppAlertService.showError(
        context,
        title: l.text('تعذر إلغاء البطاقة', 'Failed to Cancel Card'),
        message: ErrorMessageService.sanitize(error),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Widget _buildIssuedCardsDetails(List<VirtualCard> cards) {
    final l = context.loc;
    final first = cards.first;
    final totalFaceValue = cards.fold<double>(
      0,
      (sum, card) => sum + card.value,
    );
    final totalIssueCost = cards.fold<double>(
      0,
      (sum, card) => sum + card.issueCost,
    );
    final isPrivateBatch = first.visibilityScope == 'restricted';
    final totalCharge = isPrivateBatch ? totalIssueCost : totalFaceValue;
    return ShwakelCard(
      padding: const EdgeInsets.all(16),
      color: AppTheme.surfaceVariant,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.text('تفاصيل الدفعة المنشأة', 'Created Batch Details'),
            style: AppTheme.bodyBold,
          ),
          const SizedBox(height: 10),
          _buildPreviewSummaryRow(
            l.text('النوع', 'Type'),
            _cardTypeLabel(l, first.cardType),
          ),
          const SizedBox(height: 8),
          _buildPreviewSummaryRow(
            l.text('عدد البطاقات', 'Card Count'),
            '${cards.length}',
          ),
          if (!isPrivateBatch) ...[
            const SizedBox(height: 8),
            _buildPreviewSummaryRow(
              l.text('إجمالي القيم', 'Total Values'),
              CurrencyFormatter.ils(totalFaceValue),
            ),
          ],
          if (isPrivateBatch) ...[
            const SizedBox(height: 8),
            _buildPreviewSummaryRow(
              l.text('إجمالي الرسوم', 'Total Fees'),
              CurrencyFormatter.ils(totalIssueCost),
            ),
          ],
          const SizedBox(height: 8),
          _buildPreviewSummaryRow(
            isPrivateBatch
                ? l.text('المخصوم من الرصيد', 'Deducted from Balance')
                : l.text('إجمالي الخصم', 'Total Deduction'),
            CurrencyFormatter.ils(totalCharge),
          ),
          if (first.title?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 8),
            _buildPreviewSummaryRow(
              l.text('العنوان', 'Title'),
              first.title!.trim(),
            ),
          ],
          if (first.validUntil != null) ...[
            const SizedBox(height: 8),
            _buildPreviewSummaryRow(
              l.text('تنتهي', 'Expires'),
              _formatDateTime(first.validUntil),
            ),
          ],
        ],
      ),
    );
  }

  String _userOptionLabel(Map<String, dynamic> user) {
    final displayName = user['displayName']?.toString().trim() ?? '';
    if (displayName.isNotEmpty) {
      return displayName;
    }

    return UserDisplayName.fromMap(
      user,
      fallback: user['username']?.toString().trim().isNotEmpty == true
          ? user['username'].toString()
          : '${user['id'] ?? ''}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.loc;
    if (_isLoadingUser) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_isAuthorized) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          title: Text(l.tr('screens_create_card_screen.029')),
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
                  l.tr('screens_create_card_screen.050'),
                  style: AppTheme.h3,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(
          _quickMode
              ? l.text('إنشاء بطاقة سريعة', 'Quick Card Creation')
              : l.tr('screens_create_card_screen.029'),
        ),
        actions: const [AppNotificationAction(), QuickLogoutAction()],
      ),
      drawer: AppSidebar.drawerFor(context),
      body: Stack(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 520;
              return SingleChildScrollView(
                child: ResponsiveScaffoldContainer(
                  maxWidth: compact ? double.infinity : 1200,
                  padding: EdgeInsets.all(compact ? 2 : AppTheme.spacingLg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_quickMode)
                        _buildQuickCreationFlow()
                      else
                        _buildCreationStepper(),
                      if (!_quickMode && _recent.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        _buildRecent(),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
          if (_isLoading) _buildLoadingOverlay(),
        ],
      ),
    );
  }

  Widget _buildQuickCreationFlow() {
    final l = context.loc;
    final balance = (_user?['balance'] as num?)?.toDouble() ?? 0;
    final issuedCard = _recent.isNotEmpty ? _recent.first : null;
    final canIssue = (double.tryParse(_amountC.text.trim()) ?? 0) > 0;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ShwakelCard(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: AppTheme.primarySoft,
                        borderRadius: AppTheme.radiusMd,
                      ),
                      child: const Icon(
                        Icons.offline_bolt_rounded,
                        color: AppTheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l.text(
                              'بطاقة جاهزة للاستخدام',
                              'Card Ready for Use',
                            ),
                            style: AppTheme.h3,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l.text(
                              'أدخل القيمة فقط، ثم استخدم البطاقة مباشرة من الشاشة.',
                              'Enter the value only, then use the card directly from the screen.',
                            ),
                            style: AppTheme.bodyText.copyWith(
                              color: AppTheme.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                TextField(
                  controller: _amountC,
                  enabled: issuedCard == null,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: l.text('قيمة البطاقة', 'Card Value'),
                    prefixIcon: const Icon(Icons.payments_rounded),
                  ),
                ),
                const SizedBox(height: 16),
                _buildPreviewSummaryRow(
                  l.text('الرصيد الحالي', 'Current Balance'),
                  CurrencyFormatter.ils(balance),
                ),
                const SizedBox(height: 8),
                _buildPreviewSummaryRow(
                  l.text('الخصم عند الإنشاء', 'Deduction on Creation'),
                  CurrencyFormatter.ils(_currentTotalChargeNow),
                ),
                if (_quickMode) ...[
                  const SizedBox(height: 8),
                  _buildPreviewSummaryRow(
                    l.text('بطاقات أوفلاين جاهزة', 'Offline Cards Ready'),
                    '$_availableOfflineTransferSlots',
                  ),
                ],
                const SizedBox(height: 18),
                if (issuedCard == null)
                  ShwakelButton(
                    label: _isDeviceOffline
                        ? l.text('إنشاء بطاقة أوفلاين', 'Create Offline Card')
                        : l.text('إنشاء البطاقة الآن', 'Create Card Now'),
                    icon: _isDeviceOffline
                        ? Icons.qr_code_2_rounded
                        : Icons.add_card_rounded,
                    onPressed: canIssue ? _create : null,
                    isLoading: _isLoading,
                  )
                else ...[
                  ShwakelButton(
                    label: l.text('إنشاء بطاقة أخرى', 'Create Another Card'),
                    icon: Icons.add_rounded,
                    isSecondary: true,
                    onPressed: () {
                      setState(() {
                        _recent = [];
                        _amountC.clear();
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () => _openRoute('/create-card'),
                    icon: const Icon(Icons.tune_rounded),
                    label: Text(
                      l.text(
                        'فتح خيارات إنشاء البطاقات الكاملة',
                        'Open Full Card Creation Options',
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (issuedCard != null) ...[
            const SizedBox(height: 20),
            _buildQuickIssuedCard(issuedCard),
            if (issuedCard.status == CardStatus.unused) ...[
              const SizedBox(height: 12),
              ShwakelButton(
                label: l.text(
                  'إلغاء البطاقة واسترجاع الرصيد',
                  'Cancel Card and Refund Balance',
                ),
                icon: Icons.undo_rounded,
                isDanger: true,
                onPressed: () => _cancelIssuedCard(issuedCard),
                isLoading: _isLoading,
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildCreationStepper() {
    final l = context.loc;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return _buildCompactCreationFlow();
        }
        return SizedBox(
          width: double.infinity,
          child: Stepper(
            currentStep: _currentStep,
            type: StepperType.vertical,
            physics: const NeverScrollableScrollPhysics(),
            margin: EdgeInsets.zero,
            controlsBuilder: (context, details) => _buildStepControls(),
            onStepTapped: (step) {
              if (step <= _highestReachableStep) {
                setState(() => _currentStep = step);
              }
            },
            steps: [
              Step(
                title: Text(l.text('اختيار نوع البطاقة', 'Select Card Type')),
                subtitle: Text(
                  l.text(
                    'تظهر الأنواع المتاحة حسب صلاحيات الحساب.',
                    'Available types appear based on account permissions.',
                  ),
                ),
                isActive: _currentStep >= 0,
                state: _hasSelectedCardType
                    ? StepState.complete
                    : StepState.indexed,
                content: _buildCardTypeStep(),
              ),
              Step(
                title: Text(
                  l.text('البيانات والمستفيدون', 'Data and Recipients'),
                ),
                subtitle: Text(
                  l.text(
                    'القيمة والكمية ونطاق الصلاحية والخصوصية.',
                    'Value, quantity, validity range, and privacy.',
                  ),
                ),
                isActive: _currentStep >= 1,
                state: _currentStep > 1
                    ? StepState.complete
                    : StepState.indexed,
                content: _hasSelectedCardType
                    ? _buildForm()
                    : _buildCardTypeEmptyState(),
              ),
              Step(
                title: Text(
                  l.text('تصميم الطباعة والمعاينة', 'Print Design and Preview'),
                ),
                subtitle: Text(
                  l.text(
                    'تحديث مباشر للشعار والعنوان والختم.',
                    'Live update for logo, title, and stamp.',
                  ),
                ),
                isActive: _currentStep >= 2,
                state: _currentStep > 2
                    ? StepState.complete
                    : StepState.indexed,
                content: _hasSelectedCardType
                    ? _buildDesignStep()
                    : _buildCardTypeEmptyState(),
              ),
              Step(
                title: Text(
                  l.text(
                    'ملخص الحساب والتأكيد',
                    'Account Summary and Confirmation',
                  ),
                ),
                subtitle: Text(
                  l.text(
                    'مراجعة الرسوم والتكلفة قبل الإصدار.',
                    'Review fees and cost before issuing.',
                  ),
                ),
                isActive: _currentStep >= 3,
                state: StepState.indexed,
                content: _hasSelectedCardType
                    ? _buildConfirmationStep()
                    : _buildCardTypeEmptyState(),
              ),
            ],
          ),
        );
      },
    );
  }

  int get _highestReachableStep {
    if (!_hasSelectedCardType) {
      return 0;
    }
    if (_propertiesStepValidationMessage() != null) {
      return 1;
    }
    return 3;
  }

  bool _canContinueCurrentStep() {
    if (_currentStep == 0) {
      return _hasSelectedCardType;
    }
    return _hasSelectedCardType;
  }

  Future<void> _handleStepContinue({required bool isLast}) async {
    final l = context.loc;
    if (_currentStep == 1) {
      final message = _propertiesStepValidationMessage();
      if (message != null) {
        await AppAlertService.showError(
          context,
          title: l.text('تحقق من البيانات', 'Check Data'),
          message: message,
        );
        return;
      }
    }

    if (isLast) {
      await _create();
      return;
    }

    setState(() => _currentStep += 1);
  }

  String? _propertiesStepValidationMessage() {
    final l = context.loc;
    if (!_hasSelectedCardType) {
      return l.text('اختر نوع البطاقة أولًا.', 'Select a card type first.');
    }

    final amount = double.tryParse(_amountC.text.trim()) ?? 0;
    final quantity = int.tryParse(_qtyC.text.trim()) ?? 0;

    if (quantity <= 0) {
      return l.text(
        'أدخل كمية صحيحة للبطاقات.',
        'Enter a valid card quantity.',
      );
    }

    if (!_useCustomBarcode && quantity < _minimumCardQuantity) {
      return l.text(
        'الكمية أقل من الحد الأدنى $_minimumCardQuantity.',
        'Quantity is below the minimum of $_minimumCardQuantity.',
      );
    }

    if (_useCustomBarcode) {
      if (quantity != 1) {
        return l.text(
          'يمكن تخصيص رقم البطاقة عند إصدار بطاقة واحدة فقط.',
          'Custom card number is only available when issuing one card.',
        );
      }
      if (_normalizedCustomBarcode.length !=
          CardNumberExtractor.cardNumberLength) {
        return l.text(
          'رقم البطاقة المخصص يجب أن يتكون من 16 رقمًا.',
          'Custom card number must be 16 digits.',
        );
      }
    }

    final amountValidation = _validateAmountForCardType(amount);
    if (amountValidation != null) {
      return amountValidation;
    }

    if (_isAppointmentCard &&
        (_detailsTitleC.text.trim().isEmpty || _appointmentStartsAt == null)) {
      return l.text(
        'أدخل عنوان الموعد ووقت بدايته قبل المتابعة.',
        'Enter the appointment title and start time before continuing.',
      );
    }

    if (_isAppointmentCard &&
        _appointmentEndsAt != null &&
        !_appointmentEndsAt!.isAfter(_appointmentStartsAt!)) {
      return l.text(
        'نهاية الموعد يجب أن تكون بعد بدايته.',
        'Appointment end time must be after the start time.',
      );
    }

    if (_isQueueCard && _detailsTitleC.text.trim().isEmpty) {
      return l.text(
        'أدخل عنوان التذكرة التنظيمية قبل المتابعة.',
        'Enter the organizational ticket title before continuing.',
      );
    }

    if (_isSubscriptionCard) {
      if (_detailsTitleC.text.trim().isEmpty) {
        return l.text(
          'أدخل اسم الاشتراك قبل المتابعة.',
          'Enter the subscription name before continuing.',
        );
      }
      if (_validFrom == null || _validUntil == null) {
        return l.text(
          'حدد بداية ونهاية الاشتراك قبل المتابعة.',
          'Set the subscription start and end before continuing.',
        );
      }
    }

    if (_isAttendanceCard) {
      if (_detailsTitleC.text.trim().isEmpty) {
        return l.text(
          'أدخل اسم الموظف أو عنوان بطاقة الحضور قبل المتابعة.',
          'Enter the employee name or attendance card title before continuing.',
        );
      }
      if (quantity > 1) {
        return l.text(
          'بطاقات الحضور تصدر بطاقة واحدة لكل موظف.',
          'Attendance cards issue one card per employee.',
        );
      }
    }

    if (_validFrom != null &&
        _validUntil != null &&
        !_validUntil!.isAfter(_validFrom!)) {
      return l.text(
        'تاريخ انتهاء الصلاحية يجب أن يكون بعد تاريخ البداية.',
        'Expiry date must be after the start date.',
      );
    }

    return null;
  }

  Widget _buildCardTypeStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_isTrialMode) ...[
          _buildTrialInfoCard(),
          const SizedBox(height: 16),
        ],
        _buildCardTypeSelector(),
      ],
    );
  }

  Widget _buildDesignStep() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 820;
        final preview = _buildPrintPreviewPanel(isCompact: isCompact);
        final settings = _buildPreviewSettingsPanel();
        if (isCompact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [preview, const SizedBox(height: 16), settings],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 6, child: preview),
            const SizedBox(width: 18),
            Expanded(flex: 5, child: settings),
          ],
        );
      },
    );
  }

  Widget _buildConfirmationStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildPreviewActionPanel(showIssueButton: false),
        const SizedBox(height: 16),
        _buildIssueCostSummary(),
      ],
    );
  }

  Widget _buildLoadingOverlay() {
    final l = context.loc;
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.16),
        alignment: Alignment.center,
        child: ShwakelCard(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
          borderRadius: BorderRadius.circular(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                const SizedBox(height: 16),
                Text(
                  _loadingHeadline.trim().isEmpty
                      ? l.text('جارٍ تنفيذ العملية', 'Processing...')
                      : _loadingHeadline,
                  style: AppTheme.h3.copyWith(fontSize: 18),
                  textAlign: TextAlign.center,
                ),
                if (_loadingDetails.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    _loadingDetails,
                    style: AppTheme.bodyAction.copyWith(
                      color: AppTheme.textSecondary,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPrivacyAndRecipientsSection() {
    final l = context.loc;
    final canChooseVisibility =
        !_isTrialMode &&
        _canIssuePrivateCards &&
        _isBalanceCard &&
        _cardType != 'delivery';
    final showTargetedRecipients =
        !_isTrialMode &&
        _canPickTargetedUsers &&
        _effectiveVisibilityScope == 'restricted';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (canChooseVisibility) ...[
          Text(
            l.tr('screens_create_card_screen.038'),
            style: AppTheme.bodyBold,
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxWidth < 520;
              if (isCompact) {
                return Column(
                  children: [
                    _buildVisibilityChoiceCard(
                      value: 'general',
                      icon: Icons.public_rounded,
                      label: l.tr('screens_create_card_screen.011'),
                    ),
                    const SizedBox(height: 10),
                    _buildVisibilityChoiceCard(
                      value: 'restricted',
                      icon: Icons.lock_rounded,
                      label: l.tr('screens_create_card_screen.010'),
                    ),
                  ],
                );
              }
              return SegmentedButton<String>(
                segments: [
                  ButtonSegment<String>(
                    value: 'general',
                    icon: const Icon(Icons.public_rounded),
                    label: Text(l.tr('screens_create_card_screen.011')),
                  ),
                  ButtonSegment<String>(
                    value: 'restricted',
                    icon: const Icon(Icons.lock_rounded),
                    label: Text(l.tr('screens_create_card_screen.010')),
                  ),
                ],
                selected: {_visibilityScope},
                onSelectionChanged: (selection) {
                  setState(() {
                    _visibilityScope = selection.first;
                    if (_visibilityScope != 'restricted') {
                      _selectedUsers = [];
                      _selectedPhoneNumbers = [];
                    }
                  });
                },
              );
            },
          ),
        ] else if (_isTrialMode || _requiresTargetedPrivateCard) ...[
          Text(
            l.text('ظهور البطاقة', 'Card Visibility'),
            style: AppTheme.bodyBold,
          ),
          const SizedBox(height: 12),
          _buildVisibilityChoiceCard(
            value: 'restricted',
            icon: Icons.lock_rounded,
            label: l.tr('screens_create_card_screen.010'),
          ),
          const SizedBox(height: 10),
          Text(
            _isTrialMode
                ? l.text(
                    'البطاقات المجانية خاصة بحسابك فقط.',
                    'Free cards are private to your account only.',
                  )
                : l.text(
                    'هذا النوع خاص. اختر المستفيدين قبل الإصدار.',
                    'This type is private. Select recipients before issuing.',
                  ),
            style: AppTheme.caption.copyWith(fontSize: 13, height: 1.4),
          ),
        ] else ...[
          Text(
            l.text(
              'البطاقات العامة يمكن استخدامها ونقل رصيدها لدى كل المحلات والأماكن المشاركة حسب صلاحيات الحساب.',
              'General cards can be used and their balance transferred across all participating stores and places, according to the account permissions.',
            ),
            style: AppTheme.bodyAction.copyWith(fontSize: 13),
          ),
        ],
        if (showTargetedRecipients) ...[
          const SizedBox(height: 18),
          Text(
            l.text('المستفيدون من البطاقات الخاصة', 'Private Card Recipients'),
            style: AppTheme.bodyBold,
          ),
          const SizedBox(height: 8),
          Text(
            l.text(
              'البطاقات الخاصة مخصصة للأرقام المحددة فقط. اختر الدولة ثم أدخل رقم الهاتف للتحقق من وجود الحساب. إذا لم يكن موجودًا نرسل له دعوة واتساب لاستخدام النظام.',
              'Private cards are limited to the selected phone numbers only. Select the country, enter the phone number, and the system will verify the account. If it does not exist, a WhatsApp invitation is sent.',
            ),
            style: AppTheme.caption.copyWith(fontSize: 13),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked = constraints.maxWidth < 560;
              final countryField = CountrySelectorField(
                value: _recipientCountryCode,
                labelText: l.text('الدولة', 'Country'),
                onChanged: (value) =>
                    setState(() => _recipientCountryCode = value),
              );
              final phoneField = TextField(
                controller: _allowedPhoneC,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: l.text(
                    'رقم هاتف المستفيد',
                    'Recipient Phone Number',
                  ),
                  prefixIcon: const Icon(Icons.phone_rounded),
                ),
                onSubmitted: (_) => unawaited(_addAllowedPhoneFromInput()),
              );
              final addButton = SizedBox(
                height: 48,
                child: FilledButton.icon(
                  onPressed: _isLoading
                      ? null
                      : () => unawaited(_addAllowedPhoneFromInput()),
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  label: Text(l.text('تحقق وأضف', 'Verify and Add')),
                ),
              );

              if (stacked) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    countryField,
                    const SizedBox(height: 10),
                    phoneField,
                    const SizedBox(height: 10),
                    addButton,
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 220, child: countryField),
                  const SizedBox(width: 10),
                  Expanded(child: phoneField),
                  const SizedBox(width: 10),
                  addButton,
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          if (_selectedPhoneNumbers.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _selectedPhoneNumbers.map((phone) {
                return Chip(
                  avatar: const Icon(Icons.mark_email_read_rounded),
                  label: Text(l.text('دعوة: $phone', 'Invited: $phone')),
                  onDeleted: () {
                    setState(() {
                      _selectedPhoneNumbers.remove(phone);
                    });
                  },
                );
              }).toList(),
            ),
          if (_selectedPhoneNumbers.isNotEmpty) const SizedBox(height: 12),
          if (_selectedUsers.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _selectedUsers.map((user) {
                return Chip(
                  avatar: const Icon(Icons.verified_user_rounded),
                  label: Text(_userOptionLabel(user)),
                  onDeleted: () {
                    setState(() {
                      _selectedUsers.removeWhere(
                        (item) =>
                            item['id']?.toString() == user['id']?.toString(),
                      );
                    });
                  },
                );
              }).toList(),
            ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _buildForm() {
    final l = context.loc;
    return ShwakelCard(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.text(
              'البيانات المالية والمستفيدون',
              'Financial Data and Recipients',
            ),
            style: AppTheme.h3,
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppTheme.primary.withValues(alpha: 0.12),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [_buildPrivacyAndRecipientsSection()],
            ),
          ),
          const SizedBox(height: 20),
          if (!_hasSelectedCardType) ...[
            _buildCardTypeEmptyState(),
          ] else ...[
            if (_isBalanceCard || _isAppointmentCard) ...[
              TextField(
                controller: _amountC,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: _isAppointmentCard
                      ? l.text(
                          'القيمة المالية إن وجدت',
                          'Monetary value if any',
                        )
                      : l.tr('screens_create_card_screen.035'),
                  prefixIcon: const Icon(Icons.money_rounded),
                ),
              ),
              const SizedBox(height: 16),
            ],
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 190),
                child: TextField(
                  controller: _qtyC,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: l.tr('screens_create_card_screen.037'),
                    prefixIcon: const Icon(Icons.pin_rounded),
                    helperText: _isTrialMode
                        ? l.text(
                            'المتاح: ${CurrencyFormatter.formatAmount(_trialCardsRemainingAmount)}.',
                            'Available: ${CurrencyFormatter.formatAmount(_trialCardsRemainingAmount)}.',
                          )
                        : _isAttendanceCard
                        ? l.text(
                            'بطاقة واحدة لكل موظف.',
                            'One card per employee.',
                          )
                        : l.text(
                            'كل صفحة A4 تحتوي $_cardsPerA4Page بطاقة. الحد الأدنى $_minimumCardQuantity.',
                            'Each A4 page contains $_cardsPerA4Page cards. Minimum: $_minimumCardQuantity.',
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _useCustomBarcode,
              onChanged: (int.tryParse(_qtyC.text.trim()) ?? 0) == 1
                  ? (value) => setState(() => _useCustomBarcode = value)
                  : null,
              secondary: const Icon(Icons.pin_outlined),
              title: Text(l.text('تخصيص رقم البطاقة', 'Customize Card Number')),
              subtitle: Text(
                (int.tryParse(_qtyC.text.trim()) ?? 0) == 1
                    ? l.text(
                        'أدخل رقمًا مخصصًا من 16 خانة بدل الرقم التلقائي.',
                        'Enter a custom 16-digit number instead of the automatic one.',
                      )
                    : l.text(
                        'متاح عند إصدار بطاقة واحدة فقط.',
                        'Available when issuing one card only.',
                      ),
              ),
            ),
            if (_useCustomBarcode) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _customBarcodeC,
                keyboardType: TextInputType.number,
                textDirection: TextDirection.ltr,
                maxLength: CardNumberExtractor.cardNumberLength,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: l.text('رقم البطاقة المخصص', 'Custom Card Number'),
                  hintText: '1234567890123456',
                  prefixIcon: const Icon(Icons.credit_card_rounded),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (_cardType == 'single_use') ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.secondary.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.secondary.withValues(alpha: 0.15),
                  ),
                ),
                child: Text(
                  l.tr('screens_create_card_screen.036'),
                  style: AppTheme.bodyText.copyWith(fontSize: 14),
                ),
              ),
            ],
            if (_cardType == 'delivery') ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.warning.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.warning.withValues(alpha: 0.15),
                  ),
                ),
                child: Text(
                  l.tr('shared.delivery_card_create_note'),
                  style: AppTheme.bodyText.copyWith(fontSize: 14),
                ),
              ),
            ],
            if (_needsTypeDetails) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color:
                      ((_isAppointmentCard || _isSubscriptionCard)
                              ? AppTheme.primary
                              : AppTheme.secondary)
                          .withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color:
                        ((_isAppointmentCard || _isSubscriptionCard)
                                ? AppTheme.primary
                                : AppTheme.secondary)
                            .withValues(alpha: 0.15),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_typeDetailsTitle(), style: AppTheme.bodyBold),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _detailsTitleC,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: _typeTitleFieldLabel(),
                        prefixIcon: Icon(_cardTypeIcon(_cardType)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _appointmentLocationC,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: _typeLocationFieldLabel(),
                        prefixIcon: const Icon(Icons.place_rounded),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _detailsDescriptionC,
                      minLines: 2,
                      maxLines: 4,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: _typeDescriptionFieldLabel(),
                        prefixIcon: const Icon(Icons.notes_rounded),
                      ),
                    ),
                    if (_isAppointmentCard) ...[
                      const SizedBox(height: 12),
                      _buildDateTimeField(
                        label: 'بداية الموعد',
                        value: _appointmentStartsAt,
                        icon: Icons.schedule_rounded,
                        onPick: () => _pickDateTime(
                          initialValue: _appointmentStartsAt,
                          onChanged: (value) {
                            setState(() {
                              _appointmentStartsAt = value;
                              _validFrom ??= value;
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildDateTimeField(
                        label: 'نهاية الموعد',
                        value: _appointmentEndsAt,
                        icon: Icons.event_available_rounded,
                        onPick: () => _pickDateTime(
                          initialValue:
                              _appointmentEndsAt ?? _appointmentStartsAt,
                          onChanged: (value) {
                            setState(() {
                              _appointmentEndsAt = value;
                              _validUntil ??= value;
                            });
                          },
                        ),
                      ),
                    ],
                    if (_isSubscriptionCard) ...[
                      const SizedBox(height: 12),
                      _buildDateTimeField(
                        label: 'بداية الاشتراك',
                        value: _validFrom,
                        icon: Icons.play_circle_outline_rounded,
                        onPick: () => _pickDateTime(
                          initialValue: _validFrom,
                          onChanged: (value) =>
                              setState(() => _validFrom = value),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildDateTimeField(
                        label: 'نهاية الاشتراك',
                        value: _validUntil,
                        icon: Icons.event_busy_rounded,
                        onPick: () => _pickDateTime(
                          initialValue: _validUntil ?? _validFrom,
                          onChanged: (value) =>
                              setState(() => _validUntil = value),
                        ),
                      ),
                    ],
                    if (_isAttendanceCard) ...[
                      const SizedBox(height: 12),
                      ShwakelCard(
                        padding: const EdgeInsets.all(14),
                        color: AppTheme.warning.withValues(alpha: 0.06),
                        borderColor: AppTheme.warning.withValues(alpha: 0.15),
                        child: Text(
                          l.text(
                            'كل بطاقة تمثل موظفًا واحدًا. عند فحصها يسجل النظام دخولًا ثم خروجًا بالتناوب، ويظهر تقرير شهري من تقارير الحضور والانصراف.',
                            'Each card represents one employee. When scanned, the system records entry then exit alternately, and a monthly report appears in attendance reports.',
                          ),
                          style: AppTheme.bodyAction.copyWith(
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text(
                  l.text('إعدادات متقدمة', 'Advanced Settings'),
                  style: AppTheme.bodyBold,
                ),
                children: [
                  const SizedBox(height: 12),
                  ShwakelCard(
                    padding: const EdgeInsets.all(16),
                    color: AppTheme.surfaceVariant,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.text('نافذة الصلاحية', 'Validity Window'),
                          style: AppTheme.bodyBold,
                        ),
                        const SizedBox(height: 12),
                        _buildDateTimeField(
                          label: 'فعالة من',
                          value: _validFrom,
                          icon: Icons.login_rounded,
                          onPick: () => _pickDateTime(
                            initialValue: _validFrom ?? _appointmentStartsAt,
                            onChanged: (value) =>
                                setState(() => _validFrom = value),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _buildDateTimeField(
                          label: 'تنتهي في',
                          value: _validUntil,
                          icon: Icons.timer_off_rounded,
                          onPick: () => _pickDateTime(
                            initialValue:
                                _validUntil ?? _appointmentEndsAt ?? _validFrom,
                            onChanged: (value) =>
                                setState(() => _validUntil = value),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _selectCardType(String type) {
    setState(() {
      _applyCardTypeDefaults(type);
      if (_currentStep == 0) {
        _currentStep = 1;
      }
    });
  }

  void _applyCardTypeDefaults(String type) {
    _cardType = type;
    if (_requiresTargetedPrivateCard) {
      _visibilityScope = 'restricted';
    } else if (!_isTrialMode && _cardType == 'standard') {
      _visibilityScope = _mustCreatePrivateBalanceCard
          ? 'restricted'
          : 'general';
    } else if (_cardType == 'delivery') {
      _visibilityScope = 'general';
      _selectedUsers = [];
      _selectedPhoneNumbers = [];
    }
    if (_cardType != 'appointment') {
      _appointmentStartsAt = null;
      _appointmentEndsAt = null;
    }
    if (!_needsTypeDetails) {
      _appointmentLocationC.clear();
      _detailsTitleC.clear();
      _detailsDescriptionC.clear();
    }
    if (_cardType == 'single_use' && _detailsTitleC.text.trim().isEmpty) {
      _detailsTitleC.text = 'بطاقة استخدام خاص';
    }
    if (_cardType == 'attendance') {
      _qtyC.text = '1';
    } else if (_qtyC.text.trim().isEmpty ||
        (int.tryParse(_qtyC.text.trim()) ?? 0) <= 0) {
      _qtyC.text = '$_cardsPerA4Page';
    }
  }

  void _clearSelectedCardType() {
    setState(() {
      _cardType = '';
      _visibilityScope = _isTrialMode ? 'restricted' : 'general';
      _validFrom = null;
      _validUntil = null;
      _appointmentStartsAt = null;
      _appointmentEndsAt = null;
      _appointmentLocationC.clear();
      _detailsTitleC.clear();
      _detailsDescriptionC.clear();
      _selectedUsers = [];
      _selectedPhoneNumbers = [];
      _currentStep = 0;
    });
  }

  Widget _buildCardTypeEmptyState() {
    final l = context.loc;
    return ShwakelCard(
      padding: const EdgeInsets.all(18),
      color: AppTheme.surfaceVariant,
      borderColor: AppTheme.border,
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.border),
            ),
            child: const Icon(Icons.touch_app_rounded, color: AppTheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l.text(
                'اختر نوع البطاقة أولًا. بعد الاختيار ستظهر حقول الإنشاء ومعاينة الدفع فقط لهذا النوع.',
                'Select a card type first. After selection, creation fields and payment preview for that type will appear.',
              ),
              style: AppTheme.bodyAction.copyWith(fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCardTypeSelector() {
    final l = context.loc;
    final visibleTypes = _cardType.trim().isEmpty
        ? _sortedIssuableCardTypes
        : _sortedIssuableCardTypes.where((type) => type == _cardType).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l.tr('screens_create_card_screen.034'), style: AppTheme.bodyBold),
        if (visibleTypes.isEmpty) ...[
          const SizedBox(height: 12),
          ShwakelCard(
            padding: const EdgeInsets.all(16),
            color: AppTheme.warning.withValues(alpha: 0.06),
            borderColor: AppTheme.warning.withValues(alpha: 0.15),
            child: Text(
              l.text(
                'لا توجد أنواع بطاقات متاحة لحسابك حاليًا. تواصل مع الإدارة لتفعيل صلاحية الإصدار المناسبة.',
                'No card types are available for your account currently. Contact admin to activate the appropriate issuance permission.',
              ),
              style: AppTheme.bodyAction.copyWith(fontSize: 13, height: 1.5),
            ),
          ),
        ],
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxWidth < 620;
            final cardWidth = isCompact
                ? constraints.maxWidth
                : ((constraints.maxWidth - 24) / 3).clamp(240.0, 320.0);
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: visibleTypes.map((type) {
                final isSelected = _cardType == type;
                final fee = _issueFeePerCardForType(
                  type,
                  isPrivate: _effectiveVisibilityScope == 'restricted',
                );
                return SizedBox(
                  width: cardWidth,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => _selectCardType(type),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppTheme.primary.withValues(alpha: 0.08)
                            : AppTheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: isSelected
                              ? AppTheme.primary
                              : AppTheme.border,
                          width: isSelected ? 1.4 : 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? AppTheme.primarySoft
                                      : AppTheme.surface,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  _cardTypeIcon(type),
                                  color: isSelected
                                      ? AppTheme.primary
                                      : AppTheme.textSecondary,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _cardTypeLabel(l, type),
                                  style: AppTheme.bodyBold,
                                ),
                              ),
                              if (isSelected &&
                                  _sortedIssuableCardTypes.length > 1)
                                IconButton.filledTonal(
                                  tooltip: l.text(
                                    'تغيير نوع البطاقة',
                                    'Change Card Type',
                                  ),
                                  onPressed: _clearSelectedCardType,
                                  icon: const Icon(Icons.close_rounded),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _cardTypeDescription(type),
                            style: AppTheme.caption.copyWith(fontSize: 12),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: AppTheme.border),
                            ),
                            child: Text(
                              fee > 0
                                  ? l.text(
                                      'رسوم الإصدار: ${CurrencyFormatter.ils(fee)} لكل بطاقة',
                                      'Issue fee: ${CurrencyFormatter.ils(fee)} per card',
                                    )
                                  : l.text(
                                      'بدون رسوم إصدار مباشرة',
                                      'No direct issue fees',
                                    ),
                              style: AppTheme.caption.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }

  Widget _buildCompactCreationFlow() {
    final l = context.loc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ShwakelCard(
          padding: const EdgeInsets.all(14),
          color: AppTheme.surfaceVariant,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _currentStepTitle(l),
                style: AppTheme.h3.copyWith(fontSize: 20),
              ),
              const SizedBox(height: 6),
              Text(
                _currentStepSubtitle(l),
                style: AppTheme.caption.copyWith(fontSize: 13),
              ),
              const SizedBox(height: 12),
              Row(
                children: List.generate(4, (index) {
                  final active = index <= _currentStep;
                  return Expanded(
                    child: Container(
                      height: 4,
                      margin: EdgeInsetsDirectional.only(
                        end: index == 3 ? 0 : 6,
                      ),
                      decoration: BoxDecoration(
                        color: active
                            ? AppTheme.primary
                            : AppTheme.border.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _currentStepContent(),
        _buildStepControls(),
      ],
    );
  }

  Widget _buildStepControls() {
    final l = context.loc;
    final isLast = _currentStep == 3;
    final canContinue = _canContinueCurrentStep();
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Row(
        children: [
          ShwakelButton(
            label: isLast
                ? l.text('إصدار الدفعة الآن', 'Issue Batch Now')
                : l.text('التالي', 'Next'),
            icon: isLast
                ? Icons.verified_user_rounded
                : Icons.arrow_back_rounded,
            onPressed: canContinue
                ? () => _handleStepContinue(isLast: isLast)
                : null,
            isLoading: _isLoading,
            width: isLast ? 210 : 160,
          ),
          const Spacer(),
          if (_currentStep > 0)
            TextButton(
              onPressed: () => setState(() => _currentStep -= 1),
              child: Text(l.text('السابق', 'Previous')),
            )
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }

  String _currentStepTitle(AppLocalizer l) => switch (_currentStep) {
    0 => l.text('اختيار نوع البطاقة', 'Select Card Type'),
    1 => l.text('البيانات والمستفيدون', 'Data and Recipients'),
    2 => l.text('تصميم الطباعة والمعاينة', 'Print Design and Preview'),
    _ => l.text('ملخص الحساب والتأكيد', 'Account Summary and Confirmation'),
  };

  String _currentStepSubtitle(AppLocalizer l) => switch (_currentStep) {
    0 => l.text(
      'تظهر الأنواع المتاحة حسب صلاحيات الحساب.',
      'Available types appear based on account permissions.',
    ),
    1 => l.text(
      'القيمة والكمية والخصوصية في مكان واحد.',
      'Value, quantity, and privacy in one place.',
    ),
    2 => l.text(
      'تحديث مباشر للشعار والعنوان والختم.',
      'Live update for logo, title, and stamp.',
    ),
    _ => l.text(
      'مراجعة الرسوم والتكلفة قبل الإصدار.',
      'Review fees and cost before issuing.',
    ),
  };

  Widget _currentStepContent() {
    if (_currentStep == 0) return _buildCardTypeStep();
    if (!_hasSelectedCardType) return _buildCardTypeEmptyState();
    return switch (_currentStep) {
      1 => _buildForm(),
      2 => _buildDesignStep(),
      _ => _buildConfirmationStep(),
    };
  }

  Widget _buildIssueCostSummary() {
    final l = context.loc;
    final quantity = int.tryParse(_qtyC.text.trim()) ?? 0;
    final note = _issueCostPolicyNote();
    final showIssueFee = _isPrivateIssuance;

    return ShwakelCard(
      padding: const EdgeInsets.all(18),
      color: AppTheme.secondary.withValues(alpha: 0.05),
      borderColor: AppTheme.secondary.withValues(alpha: 0.12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.text('ملخص الدفع والرسوم', 'Payment and Fees Summary'),
            style: AppTheme.bodyBold,
          ),
          const SizedBox(height: 6),
          Text(
            l.text(
              'راجع ما سيتم خصمه الآن لكل بطاقة وفي إجمالي العملية قبل المتابعة.',
              'Review what will be deducted now per card and in total before continuing.',
            ),
            style: AppTheme.caption.copyWith(fontSize: 12),
          ),
          const SizedBox(height: 14),
          _buildPreviewSummaryRow(
            _isPrivateIssuance && _isBalanceCard
                ? l.text('قيمة البطاقة للمستفيد', 'Card Value for Recipient')
                : l.text('قيمة البطاقة الواحدة', 'Single Card Value'),
            CurrencyFormatter.ils(_currentCardFaceValue),
          ),
          if (showIssueFee) ...[
            const SizedBox(height: 8),
            _buildPreviewSummaryRow(
              l.text('رسوم الإصدار لكل بطاقة', 'Issue Fee per Card'),
              CurrencyFormatter.ils(_currentIssueFeePerCard),
            ),
            if (_currentFreeIssueFeeAmount > 0) ...[
              const SizedBox(height: 8),
              _buildPreviewSummaryRow(
                l.text('مجانا عرض خاص', 'Free Special Offer'),
                '- ${CurrencyFormatter.ils(_currentFreeIssueFeeAmount)}',
              ),
              const SizedBox(height: 8),
              _buildPreviewSummaryRow(
                l.text(
                  'من مجموع قيمة البطاقات المجانية هذا الشهر',
                  'From total free card value this month',
                ),
                '${CurrencyFormatter.ils(_currentFreePrivateCardValueApplied)} / ${CurrencyFormatter.ils(_monthlyPrivateCardFreeValueLimit)}',
              ),
            ],
          ],
          const SizedBox(height: 8),
          _buildPreviewSummaryRow(
            l.text('المخصوم الآن لكل بطاقة', 'Deducted Now per Card'),
            CurrencyFormatter.ils(_currentChargeNowPerCard),
          ),
          const SizedBox(height: 8),
          _buildPreviewSummaryRow(
            l.text('إجمالي الخصم الآن', 'Total Deduction Now'),
            quantity > 0 ? CurrencyFormatter.ils(_currentTotalChargeNow) : '-',
          ),
          const SizedBox(height: 12),
          Text(
            note,
            style: AppTheme.caption.copyWith(
              fontSize: 12,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  String _issueCostPolicyNote() {
    final l = context.loc;
    if (_isTrialMode) {
      return l.text(
        'في البطاقات التجريبية يتم احتساب قيمة البطاقة فقط ضمن الحد المتاح لهذا الحساب.',
        'In trial cards, only the card value is counted within the available limit for this account.',
      );
    }

    if (_isBalanceCard && _isPrivateIssuance) {
      return l.text(
        'هذه بطاقة رصيد خاصة: لا يتم خصم قيمة البطاقة من رصيدك عند الإصدار. أول ${CurrencyFormatter.ils(_monthlyPrivateCardFreeValueLimit)} من مجموع قيم البطاقات الخاصة شهريًا لأي حساب مسجل تشمل رسوم إصدار مجانية، وبعدها تُخصم رسوم الإصدار فقط.',
        'This is a private balance card: the card value is not deducted from your balance upon issuance. The first ${CurrencyFormatter.ils(_monthlyPrivateCardFreeValueLimit)} of monthly private card values for any registered account includes free issue fees, after which only issue fees are deducted.',
      );
    }

    if (_isBalanceCard && !_isPrivateIssuance) {
      return l.text(
        'هذه بطاقة رصيد عامة: يتم خصم قيمة البطاقة فقط عند الإنشاء، ورسوم الاستخدام لا تظهر ضمن تكلفة الإنشاء.',
        'This is a public balance card: only the card value is deducted upon creation, and usage fees do not appear in the creation cost.',
      );
    }

    if (!_isPrivateIssuance) {
      return l.text(
        'لا تظهر رسوم الاستخدام ضمن تكلفة الإنشاء، ويتم احتسابها عند استخدام البطاقة.',
        'Usage fees do not appear in the creation cost and are calculated when the card is used.',
      );
    }

    return l.text(
      'رسوم الإصدار لهذه العملية تُخصم الآن حسب نوع البطاقة.',
      'Issue fees for this operation are deducted now based on the card type.',
    );
  }

  Widget _buildPrintPreviewPanel({required bool isCompact}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppTheme.primarySoft,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.preview_rounded, color: AppTheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('معاينة البطاقة', style: AppTheme.h3),
                  const SizedBox(height: 4),
                  Text(
                    'مطابقة لتصميم الطباعة على صفحة A4 بواقع $_cardsPerA4Page بطاقة.',
                    style: AppTheme.caption.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: isCompact ? 14 : 18),
        SizedBox(width: double.infinity, child: _buildPreviewCard()),
      ],
    );
  }

  Widget _buildPreviewSettingsPanel() {
    final l = context.loc;
    return ShwakelCard(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.tr('screens_create_card_screen.044'), style: AppTheme.h3),
          const SizedBox(height: 8),
          Text(
            l.tr('screens_create_card_screen.045'),
            style: AppTheme.bodyAction.copyWith(fontSize: 14),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _titleC,
            onChanged: (_) => setState(() {}),
            maxLength: _printTitleMaxLength,
            inputFormatters: [
              LengthLimitingTextInputFormatter(_printTitleMaxLength),
            ],
            decoration: InputDecoration(
              labelText: l.tr('screens_create_card_screen.046'),
              prefixIcon: const Icon(Icons.title_rounded),
              counterText: '',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _stampC,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: l.tr('screens_create_card_screen.047'),
              prefixIcon: const Icon(Icons.approval_rounded),
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _showLogo,
            title: Text(l.tr('screens_create_card_screen.048')),
            subtitle: Text(
              _hasAccountLogo
                  ? l.tr('screens_create_card_screen.049')
                  : l.tr('screens_create_card_screen.050'),
              style: AppTheme.caption.copyWith(fontSize: 12),
            ),
            onChanged: (value) => setState(() => _showLogo = value),
          ),
          if (_hasAccountLogo)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _useAccountLogo,
              title: Text(l.tr('screens_create_card_screen.051')),
              subtitle: Text(
                l.tr('screens_create_card_screen.052'),
                style: AppTheme.caption.copyWith(fontSize: 12),
              ),
              onChanged: _showLogo
                  ? (value) => setState(() => _useAccountLogo = value)
                  : null,
            ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _showStamp,
            title: Text(l.tr('screens_create_card_screen.053')),
            subtitle: Text(
              l.tr('screens_create_card_screen.054'),
              style: AppTheme.caption.copyWith(fontSize: 12),
            ),
            onChanged: (value) => setState(() => _showStamp = value),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewActionPanel({bool showIssueButton = true}) {
    final l = context.loc;
    final amount = double.tryParse(_amountC.text) ?? 0;
    final quantity = int.tryParse(_qtyC.text) ?? 0;
    final canPreviewPrint = _recent.isNotEmpty;
    final visibilityLabel = _effectiveVisibilityScope == 'restricted'
        ? l.tr('screens_create_card_screen.010')
        : l.tr('screens_create_card_screen.011');
    return ShwakelCard(
      padding: const EdgeInsets.all(24),
      color: AppTheme.secondary.withValues(alpha: 0.05),
      borderColor: AppTheme.secondary.withValues(alpha: 0.12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('جاهزية الطباعة', style: AppTheme.h3),
          const SizedBox(height: 12),
          _buildPreviewSummaryRow('النوع', _cardTypeLabel(l, _cardType)),
          const SizedBox(height: 8),
          _buildPreviewSummaryRow('القيمة', _cardValueLabel(l, amount)),
          const SizedBox(height: 8),
          _buildPreviewSummaryRow(
            'العدد المطلوب',
            quantity > 0 ? '$quantity' : '-',
          ),
          const SizedBox(height: 8),
          _buildPreviewSummaryRow('الخصوصية', visibilityLabel),
          if (_effectiveVisibilityScope == 'restricted') ...[
            const SizedBox(height: 8),
            _buildPreviewSummaryRow(
              'مستفيدون محددون',
              '${_selectedUsers.length} مستخدم - ${_selectedPhoneNumbers.length} رقم',
            ),
          ],
          if (_formatValidityWindow().isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildPreviewSummaryRow('الصلاحية', _formatValidityWindow()),
          ],
          const SizedBox(height: 8),
          _buildPreviewSummaryRow(
            'الشعار والختم',
            '${_showLogo ? 'مفعل' : 'مخفي'} / ${_showStamp ? 'مفعل' : 'مخفي'}',
          ),
          if (showIssueButton) ...[
            const SizedBox(height: 18),
            ShwakelButton(
              label: 'إصدار الدفعة الآن',
              icon: Icons.verified_user_rounded,
              onPressed: _create,
              isLoading: _isLoading,
            ),
          ],
          if (canPreviewPrint) ...[
            const SizedBox(height: 10),
            ShwakelButton(
              label: l.tr('screens_create_card_screen.065'),
              icon: Icons.print_rounded,
              isSecondary: true,
              onPressed: () => _printCards(_recent),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPreviewSummaryRow(String label, String value) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: AppTheme.bodyAction.copyWith(
              color: AppTheme.textSecondary,
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: AppTheme.bodyBold.copyWith(fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _buildTrialInfoCard() {
    return ShwakelCard(
      padding: const EdgeInsets.all(18),
      color: AppTheme.warning.withValues(alpha: 0.07),
      borderColor: AppTheme.warning.withValues(alpha: 0.16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('وضع البطاقات التجريبية', style: AppTheme.bodyBold),
          const SizedBox(height: 8),
          Text(
            'هذا الحساب غير موثق بعد، لذلك يتم إصدار بطاقات تجريبية خاصة بك فقط. مجموع البطاقات غير المستخدمة لا يتجاوز ${CurrencyFormatter.ils(_trialCardsLimit)} وتسجل قيمتها بالسالب على الرصيد.',
            style: AppTheme.bodyAction.copyWith(fontSize: 13, height: 1.6),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _trialInfoChip(
                Icons.account_balance_wallet_rounded,
                'المتبقي ${CurrencyFormatter.ils(_trialCardsRemainingAmount)}',
              ),
              _trialInfoChip(
                Icons.trending_down_rounded,
                'المستخدم ${CurrencyFormatter.ils(_trialCardsOutstandingAmount)}',
              ),
              _trialInfoChip(Icons.lock_rounded, 'خاصة بحسابك'),
              _trialInfoChip(
                Icons.verified_user_rounded,
                'الاعتماد بعد التوثيق',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _trialInfoChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceVariant,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppTheme.primary),
          const SizedBox(width: 6),
          Text(label, style: AppTheme.caption),
        ],
      ),
    );
  }

  Widget _buildPreviewCard() {
    final amount = double.tryParse(_amountC.text) ?? 0;
    final previewCard = VirtualCard(
      id: 'preview',
      barcode: '1234567890123456',
      value: amount,
      cardType: _cardType,
      visibilityScope: _effectiveVisibilityScope,
      createdAt: DateTime.now(),
      details: _currentCardDetails() ?? const {},
    );
    return _buildCardPreviewWidget(previewCard, serialNumber: 1);
  }

  Widget _buildCardPreviewWidget(
    VirtualCard previewCard, {
    required int serialNumber,
  }) {
    final l = context.loc;
    final printedBy = _resolvedIssuerName(l);
    final settings = _currentPdfDesignSettings();
    _pdfService.setDesignSettings(settings);
    final signature = _previewSignatureFor(
      previewCard: previewCard,
      serialNumber: serialNumber,
      printedBy: printedBy,
      settings: settings,
    );
    if (_cardPreviewSignature != signature || _cardPreviewFuture == null) {
      _cardPreviewSignature = signature;
      _cardPreviewFuture = _renderCardPreviewPng(
        previewCard: previewCard,
        serialNumber: serialNumber,
        printedBy: printedBy,
      );
    }

    return FutureBuilder<Uint8List>(
      future: _cardPreviewFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 240,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final data = snapshot.data;
        if (data == null || data.isEmpty) {
          return const ShwakelCard(
            padding: EdgeInsets.all(18),
            color: AppTheme.surfaceVariant,
            child: Text('تعذر توليد معاينة الطباعة.'),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            data,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
          ),
        );
      },
    );
  }

  String _previewSignatureFor({
    required VirtualCard previewCard,
    required int serialNumber,
    required String printedBy,
    required CardDesignSettings settings,
  }) {
    return [
      previewCard.id,
      previewCard.barcode,
      previewCard.value.toStringAsFixed(2),
      previewCard.cardType,
      previewCard.visibilityScope,
      previewCard.title ?? '',
      previewCard.details.toString(),
      previewCard.validUntil?.toIso8601String() ?? '',
      serialNumber,
      printedBy,
      settings.showLogo,
      settings.showStamp,
      settings.logoText,
      settings.stampText,
      settings.logoUrl ?? '',
    ].join('|');
  }

  Future<Uint8List> _renderCardPreviewPng({
    required VirtualCard previewCard,
    required int serialNumber,
    required String printedBy,
  }) async {
    final pdf = await _pdfService.createSmallCardSheetPreviewPDF(
      previewCard,
      printedBy: printedBy,
      serialNumber: serialNumber,
    );
    final bytes = await pdf.save();
    final stream = Printing.raster(bytes, pages: const [0], dpi: 220);
    final page = await stream.first;
    return page.toPng();
  }

  Widget _buildRecent() {
    final l = context.loc;
    return ShwakelCard(
      padding: const EdgeInsets.all(24),
      color: AppTheme.secondary.withValues(alpha: 0.05),
      child: Column(
        children: [
          const Icon(
            Icons.history_rounded,
            color: AppTheme.secondary,
            size: 30,
          ),
          const SizedBox(height: 10),
          Text(
            l.tr('screens_create_card_screen.060'),
            style: AppTheme.h3.copyWith(fontSize: 18),
          ),
          const SizedBox(height: 20),
          _buildRecentRow(
            l.tr('screens_create_card_screen.061'),
            l.tr(
              'screens_create_card_screen.062',
              params: {'count': '${_recent.length}'},
            ),
          ),
          const SizedBox(height: 8),
          _buildRecentRow(
            l.tr('screens_create_card_screen.063'),
            _recent.isNotEmpty
                ? (_recent.first.isPrivate
                      ? l.tr('screens_create_card_screen.010')
                      : l.tr('screens_create_card_screen.011'))
                : '-',
          ),
          const SizedBox(height: 8),
          _buildRecentRow(
            'النوع',
            _recent.isNotEmpty
                ? (_recent.first.isTrial
                      ? 'بطاقة تجريبية'
                      : _cardTypeLabel(l, _recent.first.cardType))
                : '-',
          ),
          const SizedBox(height: 8),
          _buildRecentRow(
            l.tr('screens_create_card_screen.064'),
            _recent.isNotEmpty
                ? (_recent.first.isAppointment && _recent.first.value <= 0
                      ? 'بدون قيمة مالية'
                      : CurrencyFormatter.ils(_recent.first.value))
                : CurrencyFormatter.ils(0),
          ),
          if (_recent.isNotEmpty &&
              _recent.first.title?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 8),
            _buildRecentRow('العنوان', _recent.first.title!.trim()),
          ],
          if (_recent.isNotEmpty && _recent.first.validUntil != null) ...[
            const SizedBox(height: 8),
            _buildRecentRow('تنتهي', _formatDateTime(_recent.first.validUntil)),
          ],
          if (_recent.isNotEmpty) ...[
            const SizedBox(height: 20),
            ShwakelButton(
              label: l.tr('screens_create_card_screen.065'),
              icon: Icons.print_rounded,
              isSecondary: true,
              onPressed: () => _printCards(_recent),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRecentRow(String label, String value) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 320;
        if (isCompact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: AppTheme.bodyAction.copyWith(fontSize: 14)),
              const SizedBox(height: 4),
              Text(value, style: AppTheme.bodyBold.copyWith(fontSize: 14)),
            ],
          );
        }
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                label,
                style: AppTheme.bodyAction.copyWith(fontSize: 14),
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: AppTheme.bodyBold.copyWith(fontSize: 14),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildVisibilityChoiceCard({
    required String value,
    required IconData icon,
    required String label,
  }) {
    final isSelected = _visibilityScope == value;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {
        setState(() {
          _visibilityScope = value;
          if (_visibilityScope != 'restricted') {
            _selectedUsers = [];
            _selectedPhoneNumbers = [];
          }
        });
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primary.withValues(alpha: 0.08)
              : AppTheme.surfaceVariant,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected ? AppTheme.primary : AppTheme.border,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected ? AppTheme.primary : AppTheme.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: AppTheme.bodyBold.copyWith(
                  color: isSelected ? AppTheme.primary : AppTheme.textPrimary,
                ),
              ),
            ),
            if (isSelected)
              const Icon(Icons.check_circle_rounded, color: AppTheme.primary),
          ],
        ),
      ),
    );
  }
}

class _QuickOfflineTransferPayload {
  const _QuickOfflineTransferPayload({
    required this.qrPayload,
    required this.amount,
    required this.expiresAt,
    required this.senderUsername,
  });

  final String qrPayload;
  final double amount;
  final DateTime expiresAt;
  final String senderUsername;
}

class _QuickOfflineTransferCardDialog extends StatefulWidget {
  const _QuickOfflineTransferCardDialog({required this.payload});

  final _QuickOfflineTransferPayload payload;

  @override
  State<_QuickOfflineTransferCardDialog> createState() =>
      _QuickOfflineTransferCardDialogState();
}

class _QuickOfflineTransferCardDialogState
    extends State<_QuickOfflineTransferCardDialog> {
  Timer? _timer;
  late int _remainingSeconds;

  @override
  void initState() {
    super.initState();
    _remainingSeconds = _computeRemainingSeconds();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      final next = _computeRemainingSeconds();
      if (next <= 0) {
        Navigator.of(context).pop();
        return;
      }
      setState(() => _remainingSeconds = next);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  int _computeRemainingSeconds() {
    final diff = widget.payload.expiresAt.difference(DateTime.now());
    return diff.inSeconds < 0 ? 0 : diff.inSeconds;
  }

  String _formatCountdown() {
    final minutes = (_remainingSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_remainingSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _formatExpiry(DateTime value) {
    final y = value.year.toString().padLeft(4, '0');
    final m = value.month.toString().padLeft(2, '0');
    final d = value.day.toString().padLeft(2, '0');
    final hh = value.hour.toString().padLeft(2, '0');
    final mm = value.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: ShwakelCard(
          padding: const EdgeInsets.all(24),
          borderRadius: BorderRadius.circular(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('بطاقة أوفلاين جاهزة', style: AppTheme.h3),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'يعتمدها أي مستلم متصل بالإنترنت عبر فحص الرمز. يتم الخصم من المصدر والإضافة للمستلم على السيرفر مرة واحدة فقط.',
                textAlign: TextAlign.center,
                style: AppTheme.bodyAction,
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: AppTheme.border),
                ),
                child: QrImageView(
                  data: widget.payload.qrPayload,
                  size: 220,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 18),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.success.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  children: [
                    Text(
                      CurrencyFormatter.ils(widget.payload.amount),
                      style: AppTheme.h2.copyWith(color: AppTheme.success),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'متبقي للاستخدام: ${_formatCountdown()}',
                      style: AppTheme.bodyBold,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'تنتهي: ${_formatExpiry(widget.payload.expiresAt)}',
                      style: AppTheme.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
