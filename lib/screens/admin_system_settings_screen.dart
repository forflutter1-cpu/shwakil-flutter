import 'dart:async';

import 'package:flutter/material.dart';

import '../services/index.dart';
import '../utils/app_permissions.dart';
import '../utils/app_theme.dart';
import '../utils/currency_formatter.dart';
import '../widgets/admin/admin_section_header.dart';
import '../widgets/app_sidebar.dart';
import '../widgets/app_top_actions.dart';
import '../widgets/responsive_scaffold_container.dart';
import '../widgets/shwakel_button.dart';
import '../widgets/shwakel_card.dart';

class AdminSystemSettingsScreen extends StatefulWidget {
  const AdminSystemSettingsScreen({super.key});

  @override
  State<AdminSystemSettingsScreen> createState() =>
      _AdminSystemSettingsScreenState();
}

class _AdminSystemSettingsScreenState extends State<AdminSystemSettingsScreen> {
  final ApiService _apiService = ApiService();
  final AuthService _authService = AuthService();

  final _contactTitleController = TextEditingController();
  final _contactWhatsappController = TextEditingController();
  final _contactEmailController = TextEditingController();
  final _contactAddressController = TextEditingController();
  final _policyTitleController = TextEditingController();
  final _policyContentController = TextEditingController();
  final _unverifiedTransferLimitController = TextEditingController(text: '200');
  final _topupRequestInstructionsController = TextEditingController();
  final _minSupportedVersionController = TextEditingController();
  final _latestVersionController = TextEditingController();
  final _androidStoreUrlController = TextEditingController();
  final _iosStoreUrlController = TextEditingController();
  final _webStoreUrlController = TextEditingController();
  final _walletTopupFeeController = TextEditingController();
  final _walletTransferFeeController = TextEditingController();
  final _cardRedeemFeeController = TextEditingController();
  final _cardResellFeeController = TextEditingController();
  final _cardPrintRequestFeeController = TextEditingController();
  final _cardPrintCardsPerA4PageController = TextEditingController();
  final _cardPrintPageGroupSizeController = TextEditingController();
  final _cardPrintPageGroupFeeController = TextEditingController();
  final _withdrawFeeController = TextEditingController();
  final _standardCardIssueCostController = TextEditingController();
  final _deliveryCardIssueCostController = TextEditingController();
  final _privateCardIssueCostController = TextEditingController();
  final _singleUseTicketIssueCostController = TextEditingController();
  final _appointmentTicketIssueCostController = TextEditingController();
  final _queueTicketIssueCostController = TextEditingController();
  final _subscriptionCardIssueCostController = TextEditingController();
  final _attendanceCardIssueCostController = TextEditingController();
  final _scanDefaultLimitController = TextEditingController();
  final _scanRestrictedLimitController = TextEditingController();
  final _scanBasicLimitController = TextEditingController();
  final _scanVerifiedLimitController = TextEditingController();
  final _scanDriverLimitController = TextEditingController();
  final _scanMarketerLimitController = TextEditingController();
  final _scanSupportLimitController = TextEditingController();
  final _scanFinanceLimitController = TextEditingController();
  final _scanAdminLimitController = TextEditingController();
  final _scanWithoutRedeemChargeEveryController = TextEditingController();
  final _scanWithoutRedeemChargeAmountController = TextEditingController();
  final _offlineMaxPendingAmountController = TextEditingController();
  final _offlineMaxPendingCountController = TextEditingController();
  final _offlineCacheLimitController = TextEditingController();
  final _offlineSyncIntervalController = TextEditingController();
  final _prepaidMaxCardAmountController = TextEditingController();
  final _prepaidMaxPaymentAmountController = TextEditingController();
  final _prepaidMaxActiveCardsController = TextEditingController();
  final _prepaidMaxExpiryDaysController = TextEditingController();
  final _prepaidDailyAmountLimitController = TextEditingController();
  final _prepaidDailyCountLimitController = TextEditingController();
  final _prepaidReportBuyerIdController = TextEditingController();
  final _prepaidReportMerchantIdController = TextEditingController();
  final _prepaidReportDateFromController = TextEditingController();
  final _prepaidReportDateToController = TextEditingController();
  final _prepaidReportSearchController = TextEditingController();
  final _affiliateRewardAmountController = TextEditingController();
  final _affiliateFirstTopupMinAmountController = TextEditingController();
  final _affiliateMarketerDebtLimitController = TextEditingController();
  final _withdrawalRequestInstructionsController = TextEditingController();
  final _withdrawalMinAmountController = TextEditingController();
  final _withdrawalMaxAmountController = TextEditingController();
  final _topupMinAmountController = TextEditingController();
  final _topupMaxAmountController = TextEditingController();
  final _cardQtyDefaultController = TextEditingController();
  final _cardQtyRestrictedController = TextEditingController();
  final _cardQtyBasicController = TextEditingController();
  final _cardQtyVerifiedController = TextEditingController();
  final _cardQtyDriverController = TextEditingController();
  final _cardQtyMarketerController = TextEditingController();
  final _cardQtySupportController = TextEditingController();
  final _cardQtyFinanceController = TextEditingController();
  final _cardQtyAdminController = TextEditingController();
  final _externalStoreBaseUrlController = TextEditingController();
  final _externalStoreApiTokenController = TextEditingController();
  final _externalStoreBearerTokenController = TextEditingController();
  final _externalStoreUsernameController = TextEditingController();
  final _externalStorePasswordController = TextEditingController();
  final _externalStorePlatformController = TextEditingController(
    text: 'android',
  );
  final _externalStoreAppVersionController = TextEditingController(
    text: '99.0.0',
  );
  final _externalStoreBuildNumberController = TextEditingController(
    text: '999',
  );
  final _externalStoreLanguageController = TextEditingController(text: 'ar');
  final _externalStoreDiscountController = TextEditingController(text: '0');
  final _externalStoreUsdRateController = TextEditingController(text: '3.05');
  final _externalStoreProfitController = TextEditingController(text: '3');
  final _externalStoreCatalogSearchController = TextEditingController();
  final Map<String, TextEditingController> _externalStoreRoleProfitControllers =
      {};

  bool _isLoading = true;
  bool _isSaving = false;
  bool _isAuthorized = false;
  bool _registrationEnabled = true;
  bool _loginOtpRequired = false;
  bool _registrationWhatsappVerificationRequired = true;
  String _whatsappUsageMode = 'all';
  String _messageDeliveryPriority = 'whatsapp';
  bool _adminAlertsWhatsappEnabled = true;
  bool _adminAlertsSmsEnabled = true;
  bool _topupRequestEnabled = true;
  bool _withdrawalRequestEnabled = true;
  bool _affiliateEnabled = true;
  bool _scanAutoRedeemGlobalForced = false;
  bool _externalStoreEnabled = false;
  bool _isLoadingPrepaidReport = false;
  bool _isLoadingGatewayDashboard = false;
  bool _isTestingSmsGateway = false;
  bool _isSyncingExternalCatalog = false;
  bool _isLoadingExternalCatalog = false;
  String? _gatewayBusyChannelKey;
  String _prepaidReportCardStatus = 'all';
  List<Map<String, dynamic>> _topupPaymentMethods = const [];
  List<Map<String, dynamic>> _withdrawalMethods = const [];
  List<Map<String, dynamic>> _prepaidReportPayments = const [];
  Map<String, dynamic> _prepaidReportSummary = const {};
  Map<String, dynamic> _messageGatewayDashboard = const {};
  Map<String, dynamic> _externalProviderBalance = const {};
  List<Map<String, dynamic>> _externalCatalogCategories = const [];
  List<Map<String, dynamic>> _externalCatalogCards = const [];
  List<Map<String, dynamic>> _externalStoreRoleProfitRows = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _contactTitleController.dispose();
    _contactWhatsappController.dispose();
    _contactEmailController.dispose();
    _contactAddressController.dispose();
    _policyTitleController.dispose();
    _policyContentController.dispose();
    _unverifiedTransferLimitController.dispose();
    _topupRequestInstructionsController.dispose();
    _minSupportedVersionController.dispose();
    _latestVersionController.dispose();
    _androidStoreUrlController.dispose();
    _iosStoreUrlController.dispose();
    _webStoreUrlController.dispose();
    _walletTopupFeeController.dispose();
    _walletTransferFeeController.dispose();
    _cardRedeemFeeController.dispose();
    _cardResellFeeController.dispose();
    _cardPrintRequestFeeController.dispose();
    _cardPrintCardsPerA4PageController.dispose();
    _cardPrintPageGroupSizeController.dispose();
    _cardPrintPageGroupFeeController.dispose();
    _withdrawFeeController.dispose();
    _standardCardIssueCostController.dispose();
    _deliveryCardIssueCostController.dispose();
    _privateCardIssueCostController.dispose();
    _singleUseTicketIssueCostController.dispose();
    _appointmentTicketIssueCostController.dispose();
    _queueTicketIssueCostController.dispose();
    _subscriptionCardIssueCostController.dispose();
    _attendanceCardIssueCostController.dispose();
    _scanDefaultLimitController.dispose();
    _scanRestrictedLimitController.dispose();
    _scanBasicLimitController.dispose();
    _scanVerifiedLimitController.dispose();
    _scanDriverLimitController.dispose();
    _scanMarketerLimitController.dispose();
    _scanSupportLimitController.dispose();
    _scanFinanceLimitController.dispose();
    _scanAdminLimitController.dispose();
    _scanWithoutRedeemChargeEveryController.dispose();
    _scanWithoutRedeemChargeAmountController.dispose();
    _offlineMaxPendingAmountController.dispose();
    _offlineMaxPendingCountController.dispose();
    _offlineCacheLimitController.dispose();
    _offlineSyncIntervalController.dispose();
    _prepaidMaxCardAmountController.dispose();
    _prepaidMaxPaymentAmountController.dispose();
    _prepaidMaxActiveCardsController.dispose();
    _prepaidMaxExpiryDaysController.dispose();
    _prepaidDailyAmountLimitController.dispose();
    _prepaidDailyCountLimitController.dispose();
    _prepaidReportBuyerIdController.dispose();
    _prepaidReportMerchantIdController.dispose();
    _prepaidReportDateFromController.dispose();
    _prepaidReportDateToController.dispose();
    _prepaidReportSearchController.dispose();
    _affiliateRewardAmountController.dispose();
    _affiliateFirstTopupMinAmountController.dispose();
    _affiliateMarketerDebtLimitController.dispose();
    _withdrawalRequestInstructionsController.dispose();
    _withdrawalMinAmountController.dispose();
    _withdrawalMaxAmountController.dispose();
    _topupMinAmountController.dispose();
    _topupMaxAmountController.dispose();
    _cardQtyDefaultController.dispose();
    _cardQtyRestrictedController.dispose();
    _cardQtyBasicController.dispose();
    _cardQtyVerifiedController.dispose();
    _cardQtyDriverController.dispose();
    _cardQtyMarketerController.dispose();
    _cardQtySupportController.dispose();
    _cardQtyFinanceController.dispose();
    _cardQtyAdminController.dispose();
    _externalStoreBaseUrlController.dispose();
    _externalStoreApiTokenController.dispose();
    _externalStoreBearerTokenController.dispose();
    _externalStoreUsernameController.dispose();
    _externalStorePasswordController.dispose();
    _externalStorePlatformController.dispose();
    _externalStoreAppVersionController.dispose();
    _externalStoreBuildNumberController.dispose();
    _externalStoreLanguageController.dispose();
    _externalStoreDiscountController.dispose();
    _externalStoreUsdRateController.dispose();
    _externalStoreProfitController.dispose();
    _externalStoreCatalogSearchController.dispose();
    for (final controller in _externalStoreRoleProfitControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final loadWarnings = <String>[];
      Future<T> safeLoad<T>(
        Future<T> future, {
        required T fallback,
        required String section,
      }) async {
        try {
          return await future;
        } catch (_) {
          loadWarnings.add(section);
          return fallback;
        }
      }

      final currentAppVersionFuture = safeLoad<String>(
        AppVersionService.currentVersion(),
        fallback: '',
        section: 'app_version',
      );
      final currentUser = await _authService.currentUser();
      final permissions = AppPermissions.fromUser(currentUser);
      if (!permissions.canManageSystemSettings) {
        if (!mounted) {
          return;
        }
        setState(() {
          _isAuthorized = false;
          _isLoading = false;
        });
        return;
      }
      final results = await Future.wait<dynamic>([
        currentAppVersionFuture,
        safeLoad<Map<String, dynamic>>(
          _apiService.getContactInfo(),
          fallback: const {},
          section: 'contact',
        ),
        safeLoad<Map<String, dynamic>>(
          _apiService.getAuthSettings(),
          fallback: const {},
          section: 'auth',
        ),
        safeLoad<Map<String, dynamic>>(
          _apiService.getTransferSettings(),
          fallback: const {},
          section: 'transfer',
        ),
        safeLoad<Map<String, dynamic>>(
          _apiService.getOfflineCardSettings(),
          fallback: const {},
          section: 'offline',
        ),
        safeLoad<Map<String, dynamic>>(
          _apiService.getFeeSettings(),
          fallback: const {},
          section: 'fees',
        ),
        safeLoad<Map<String, dynamic>>(
          _apiService.getCardScanLimitSettings(),
          fallback: const {},
          section: 'card_scan_limits',
        ),
        safeLoad<Map<String, dynamic>>(
          _apiService.getAdminTopupRequestSettings(),
          fallback: const {},
          section: 'topup_requests',
        ),
        safeLoad<Map<String, dynamic>>(
          _apiService.getAdminWithdrawalRequestSettings(),
          fallback: const {},
          section: 'withdrawal_requests',
        ),
        safeLoad<Map<String, dynamic>>(
          _apiService.getAdminAffiliateSettings(),
          fallback: const {
            'enabled': true,
            'rewardAmount': 5,
            'firstTopupMinAmount': 100,
            'marketerDebtLimit': 50,
          },
          section: 'affiliate',
        ),
        safeLoad<List<Map<String, dynamic>>>(
          _apiService.getAdminTopupPaymentMethods(),
          fallback: const [],
          section: 'topup_methods',
        ),
        safeLoad<List<Map<String, dynamic>>>(
          _apiService.getAdminWithdrawalMethods(),
          fallback: const [],
          section: 'withdrawal_methods',
        ),
        safeLoad<Map<String, dynamic>>(
          _apiService.getUsagePolicy(),
          fallback: const {},
          section: 'usage_policy',
        ),
        safeLoad<Map<String, dynamic>>(
          _apiService.getAdminPrepaidMultipaySettings(),
          fallback: const {},
          section: 'prepaid_multipay',
        ),
        safeLoad<Map<String, dynamic>>(
          _apiService.getCardQuantityLimitSettings(),
          fallback: const {},
          section: 'card_quantity_limits',
        ),
        safeLoad<Map<String, dynamic>>(
          _apiService.getAdminExternalCardStoreSettings(),
          fallback: const {},
          section: 'external_card_store',
        ),
      ]);

      if (!mounted) {
        return;
      }

      final currentAppVersion = results[0] as String;
      final contactSettings = Map<String, dynamic>.from(results[1] as Map);
      final authSettings = Map<String, dynamic>.from(results[2] as Map);
      final transferSettings = Map<String, dynamic>.from(results[3] as Map);
      final offlineCardSettings = Map<String, dynamic>.from(results[4] as Map);
      final feeSettings = Map<String, dynamic>.from(results[5] as Map);
      final cardScanLimitSettings = Map<String, dynamic>.from(
        results[6] as Map,
      );
      final topupRequestSettings = Map<String, dynamic>.from(results[7] as Map);
      final withdrawalRequestSettings = Map<String, dynamic>.from(
        results[8] as Map,
      );
      final affiliateSettings = Map<String, dynamic>.from(results[9] as Map);
      final topupPaymentMethods = List<Map<String, dynamic>>.from(
        (results[10] as List).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
      final withdrawalMethods = List<Map<String, dynamic>>.from(
        (results[11] as List).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
      final usagePolicy = Map<String, dynamic>.from(results[12] as Map);
      final prepaidMultipaySettings = Map<String, dynamic>.from(
        results[13] as Map,
      );
      final cardQuantityLimitSettings = Map<String, dynamic>.from(
        results[14] as Map,
      );
      final externalStorePayload = Map<String, dynamic>.from(
        results[15] as Map,
      );
      final externalStoreSettings = Map<String, dynamic>.from(
        externalStorePayload['externalCardStore'] as Map? ?? const {},
      );
      final externalCatalogControls = Map<String, dynamic>.from(
        externalStorePayload['catalogControls'] as Map? ?? const {},
      );
      final externalCatalogCategories = List<Map<String, dynamic>>.from(
        (externalCatalogControls['categories'] as List? ?? const []).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
      final externalCatalogCards = List<Map<String, dynamic>>.from(
        (externalCatalogControls['cards'] as List? ?? const []).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
      final externalProviderBalance = Map<String, dynamic>.from(
        externalStorePayload['providerBalance'] as Map? ?? const {},
      );

      _contactTitleController.text = contactSettings['title'] ?? '';
      _contactWhatsappController.text =
          contactSettings['supportWhatsapp'] ?? '';
      _contactEmailController.text = contactSettings['supportEmail'] ?? '';
      _contactAddressController.text = contactSettings['address'] ?? '';
      _registrationEnabled = authSettings['registrationEnabled'] == true;
      _loginOtpRequired = authSettings['loginOtpRequired'] != false;
      _registrationWhatsappVerificationRequired =
          authSettings['registrationWhatsappVerificationRequired'] != false;
      _whatsappUsageMode = _normalizeWhatsappUsageMode(
        authSettings['whatsappUsageMode'],
      );
      _messageDeliveryPriority = _normalizeMessageDeliveryPriority(
        authSettings['messageDeliveryPriority'],
      );
      _adminAlertsWhatsappEnabled =
          authSettings['adminAlertsWhatsappEnabled'] != false;
      _adminAlertsSmsEnabled = authSettings['adminAlertsSmsEnabled'] != false;
      final minSupportedVersion =
          authSettings['minSupportedVersion']?.toString().trim() ?? '';
      final latestVersion =
          authSettings['latestVersion']?.toString().trim() ?? '';
      _minSupportedVersionController.text = minSupportedVersion.isNotEmpty
          ? minSupportedVersion
          : currentAppVersion;
      _latestVersionController.text = latestVersion.isNotEmpty
          ? latestVersion
          : currentAppVersion;
      _androidStoreUrlController.text =
          authSettings['androidStoreUrl']?.toString() ?? '';
      _iosStoreUrlController.text =
          authSettings['iosStoreUrl']?.toString() ?? '';
      _webStoreUrlController.text =
          authSettings['webStoreUrl']?.toString() ?? '';
      _unverifiedTransferLimitController.text =
          (transferSettings['unverifiedTransferLimit'] as num?)
              ?.toStringAsFixed(2) ??
          '200';
      _walletTopupFeeController.text =
          (feeSettings['walletTopupPercent'] as num?)?.toString() ?? '1';
      _walletTransferFeeController.text =
          (feeSettings['walletTransferPercent'] as num?)?.toString() ?? '1';
      _cardRedeemFeeController.text =
          (feeSettings['cardRedeemPercent'] as num?)?.toString() ?? '1';
      _cardResellFeeController.text =
          (feeSettings['cardResellPercent'] as num?)?.toString() ?? '1';
      _cardPrintRequestFeeController.text =
          (feeSettings['cardPrintRequestPercent'] as num?)?.toString() ?? '1';
      _cardPrintCardsPerA4PageController.text =
          (feeSettings['cardPrintCardsPerA4Page'] as num?)?.toString() ?? '35';
      _cardPrintPageGroupSizeController.text =
          (feeSettings['cardPrintPageGroupSize'] as num?)?.toString() ?? '3';
      _cardPrintPageGroupFeeController.text =
          (feeSettings['cardPrintPageGroupFee'] as num?)?.toString() ?? '1';
      _withdrawFeeController.text =
          (feeSettings['withdrawPercent'] as num?)?.toString() ?? '1';
      _standardCardIssueCostController.text =
          (feeSettings['standardCardIssueCost'] as num?)?.toString() ?? '0';
      _deliveryCardIssueCostController.text =
          (feeSettings['deliveryCardIssueCost'] as num?)?.toString() ?? '0';
      _privateCardIssueCostController.text =
          (feeSettings['privateCardIssueCost'] as num?)?.toString() ?? '0.01';
      _singleUseTicketIssueCostController.text =
          (feeSettings['singleUseTicketIssueCost'] as num?)?.toString() ??
          '0.02';
      _appointmentTicketIssueCostController.text =
          (feeSettings['appointmentTicketIssueCost'] as num?)?.toString() ??
          '0.25';
      _queueTicketIssueCostController.text =
          (feeSettings['queueTicketIssueCost'] as num?)?.toString() ?? '0.10';
      _subscriptionCardIssueCostController.text =
          (feeSettings['subscriptionCardIssueCost'] as num?)?.toString() ??
          '0.25';
      _attendanceCardIssueCostController.text =
          (feeSettings['attendanceCardIssueCost'] as num?)?.toString() ??
          '0.10';
      _scanDefaultLimitController.text =
          (cardScanLimitSettings['defaultLimit'] as num?)?.toString() ?? '30';
      _scanRestrictedLimitController.text =
          (cardScanLimitSettings['restrictedLimit'] as num?)?.toString() ??
          '10';
      _scanBasicLimitController.text =
          (cardScanLimitSettings['basicLimit'] as num?)?.toString() ?? '30';
      _scanVerifiedLimitController.text =
          (cardScanLimitSettings['verifiedLimit'] as num?)?.toString() ?? '60';
      _scanDriverLimitController.text =
          (cardScanLimitSettings['driverLimit'] as num?)?.toString() ?? '200';
      _scanMarketerLimitController.text =
          (cardScanLimitSettings['marketerLimit'] as num?)?.toString() ?? '40';
      _scanSupportLimitController.text =
          (cardScanLimitSettings['supportLimit'] as num?)?.toString() ?? '0';
      _scanFinanceLimitController.text =
          (cardScanLimitSettings['financeLimit'] as num?)?.toString() ?? '0';
      _scanAdminLimitController.text =
          (cardScanLimitSettings['adminLimit'] as num?)?.toString() ?? '0';
      _scanWithoutRedeemChargeEveryController.text =
          (cardScanLimitSettings['withoutRedeemChargeEvery'] as num?)
              ?.toString() ??
          '0';
      _scanWithoutRedeemChargeAmountController.text =
          (cardScanLimitSettings['withoutRedeemChargeAmount'] as num?)
              ?.toString() ??
          '0';
      _scanAutoRedeemGlobalForced =
          cardScanLimitSettings['autoRedeemGlobalForced'] == true;
      _offlineMaxPendingAmountController.text =
          (offlineCardSettings['maxPendingAmount'] as num?)?.toString() ??
          '500';
      _offlineMaxPendingCountController.text =
          (offlineCardSettings['maxPendingCount'] as num?)?.toString() ?? '50';
      _offlineCacheLimitController.text =
          (offlineCardSettings['maxCachedCards'] as num?)?.toString() ?? '1000';
      _offlineSyncIntervalController.text =
          (offlineCardSettings['syncIntervalMinutes'] as num?)?.toString() ??
          '60';
      _prepaidMaxCardAmountController.text =
          (prepaidMultipaySettings['maxCardAmount'] as num?)?.toString() ??
          '500';
      _prepaidMaxPaymentAmountController.text =
          (prepaidMultipaySettings['maxPaymentAmount'] as num?)?.toString() ??
          '250';
      _prepaidMaxActiveCardsController.text =
          (prepaidMultipaySettings['maxActiveCards'] as num?)?.toString() ??
          '5';
      _prepaidMaxExpiryDaysController.text =
          (prepaidMultipaySettings['maxExpiryDays'] as num?)?.toString() ??
          '365';
      _prepaidDailyAmountLimitController.text =
          (prepaidMultipaySettings['dailyPaymentAmountLimit'] as num?)
              ?.toString() ??
          '500';
      _prepaidDailyCountLimitController.text =
          (prepaidMultipaySettings['dailyPaymentCountLimit'] as num?)
              ?.toString() ??
          '20';
      _topupRequestEnabled = topupRequestSettings['enabled'] == true;
      _topupRequestInstructionsController.text =
          topupRequestSettings['instructions']?.toString() ?? '';
      _topupMinAmountController.text =
          (topupRequestSettings['minAmount'] as num?)?.toString() ?? '10';
      _topupMaxAmountController.text =
          (topupRequestSettings['maxAmount'] as num?)?.toString() ?? '10000';
      _withdrawalRequestEnabled = withdrawalRequestSettings['enabled'] == true;
      _withdrawalRequestInstructionsController.text =
          withdrawalRequestSettings['instructions']?.toString() ?? '';
      _withdrawalMinAmountController.text =
          (withdrawalRequestSettings['minAmount'] as num?)?.toString() ?? '100';
      _withdrawalMaxAmountController.text =
          (withdrawalRequestSettings['maxAmount'] as num?)?.toString() ??
          '10000';
      _cardQtyDefaultController.text =
          (cardQuantityLimitSettings['defaultLimit'] as num?)?.toString() ??
          '1';
      _cardQtyRestrictedController.text =
          (cardQuantityLimitSettings['restrictedLimit'] as num?)?.toString() ??
          '1';
      _cardQtyBasicController.text =
          (cardQuantityLimitSettings['basicLimit'] as num?)?.toString() ?? '30';
      _cardQtyVerifiedController.text =
          (cardQuantityLimitSettings['verifiedLimit'] as num?)?.toString() ??
          '30';
      _cardQtyDriverController.text =
          (cardQuantityLimitSettings['driverLimit'] as num?)?.toString() ??
          '30';
      _cardQtyMarketerController.text =
          (cardQuantityLimitSettings['marketerLimit'] as num?)?.toString() ??
          '10';
      _cardQtySupportController.text =
          (cardQuantityLimitSettings['supportLimit'] as num?)?.toString() ??
          '1';
      _cardQtyFinanceController.text =
          (cardQuantityLimitSettings['financeLimit'] as num?)?.toString() ??
          '1';
      _cardQtyAdminController.text =
          (cardQuantityLimitSettings['adminLimit'] as num?)?.toString() ?? '1';
      _affiliateEnabled = affiliateSettings['enabled'] == true;
      _affiliateRewardAmountController.text =
          (affiliateSettings['rewardAmount'] as num?)?.toString() ?? '5';
      _affiliateFirstTopupMinAmountController.text =
          (affiliateSettings['firstTopupMinAmount'] as num?)?.toString() ??
          '100';
      _affiliateMarketerDebtLimitController.text =
          (affiliateSettings['marketerDebtLimit'] as num?)?.toString() ?? '50';
      _policyTitleController.text = usagePolicy['title'] ?? '';
      _policyContentController.text = usagePolicy['content'] ?? '';
      _externalStoreEnabled = externalStoreSettings['enabled'] == true;
      _externalStoreBaseUrlController.text =
          externalStoreSettings['baseUrl']?.toString() ?? 'https://ajnec.com';
      _externalStoreApiTokenController.text =
          externalStoreSettings['apiToken']?.toString() ?? '';
      _externalStoreBearerTokenController.text =
          externalStoreSettings['bearerToken']?.toString() ?? '';
      _externalStoreUsernameController.text =
          externalStoreSettings['username']?.toString() ?? '';
      _externalStorePasswordController.text =
          externalStoreSettings['password']?.toString() ?? '';
      _externalStorePlatformController.text =
          externalStoreSettings['platform']?.toString() ?? 'android';
      _externalStoreAppVersionController.text =
          externalStoreSettings['appVersion']?.toString() ?? '99.0.0';
      _externalStoreBuildNumberController.text =
          externalStoreSettings['appBuildNumber']?.toString() ?? '999';
      _externalStoreLanguageController.text =
          externalStoreSettings['language']?.toString() ?? 'ar';
      _externalStoreDiscountController.text =
          (externalStoreSettings['discountPercent'] as num?)?.toString() ?? '0';
      _externalStoreUsdRateController.text =
          (externalStoreSettings['usdToIlsRate'] as num?)?.toString() ?? '3.05';
      _externalStoreProfitController.text =
          (externalStoreSettings['profitPercent'] as num?)?.toString() ?? '3';
      final roleProfitMap = Map<String, dynamic>.from(
        externalStoreSettings['profitPercentsByRole'] as Map? ?? const {},
      );
      final roleProfitRows = roleProfitMap.values
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList();
      for (final row in roleProfitRows) {
        final role = row['role']?.toString() ?? '';
        if (role.isEmpty) {
          continue;
        }
        _externalRoleProfitController(role).text =
            (row['profitPercent'] as num?)?.toString() ??
            _externalStoreProfitController.text;
      }

      setState(() {
        _isAuthorized = true;
        _topupPaymentMethods = topupPaymentMethods;
        _withdrawalMethods = withdrawalMethods;
        _externalProviderBalance = externalProviderBalance;
        _externalCatalogCategories = externalCatalogCategories;
        _externalCatalogCards = externalCatalogCards;
        _externalStoreRoleProfitRows = roleProfitRows;
        _isLoading = false;
      });
      if (loadWarnings.isNotEmpty) {
        await AppAlertService.showInfo(
          context,
          title: context.loc.tr('screens_admin_system_settings_screen.016'),
          message:
              'تعذر تحميل بعض أقسام إعدادات النظام مؤقتًا، وتم عرض القيم المتاحة أو الافتراضية لحين إعادة المحاولة.',
        );
      }
      unawaited(_loadPrepaidReport());
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _isLoading = false);
      await AppAlertService.showError(
        context,
        title: context.loc.tr('screens_admin_system_settings_screen.016'),
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  Future<void> _loadPrepaidReport() async {
    if (!_isAuthorized) {
      return;
    }
    setState(() => _isLoadingPrepaidReport = true);
    try {
      final payload = await _apiService.getAdminPrepaidMultipayPayments(
        buyerUserId: _prepaidReportBuyerIdController.text,
        merchantUserId: _prepaidReportMerchantIdController.text,
        dateFrom: _prepaidReportDateFromController.text,
        dateTo: _prepaidReportDateToController.text,
        query: _prepaidReportSearchController.text,
        cardStatus: _prepaidReportCardStatus,
        perPage: 50,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _prepaidReportPayments = List<Map<String, dynamic>>.from(
          (payload['payments'] as List? ?? const []).map(
            (item) => Map<String, dynamic>.from(item as Map),
          ),
        );
        _prepaidReportSummary = Map<String, dynamic>.from(
          payload['summary'] as Map? ?? const {},
        );
        _isLoadingPrepaidReport = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _isLoadingPrepaidReport = false);
      await AppAlertService.showError(
        context,
        title: context.loc.tr('screens_admin_system_settings_screen.125'),
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  Future<void> _refreshMessageGatewayDashboard() async {
    if (!_isAuthorized) {
      return;
    }
    final l = context.loc;
    setState(() => _isLoadingGatewayDashboard = true);
    try {
      final payload = await _apiService.getAdminMessageGatewayDashboard();
      if (!mounted) {
        return;
      }
      setState(() {
        _messageGatewayDashboard = payload;
        _isLoadingGatewayDashboard = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _isLoadingGatewayDashboard = false);
      await AppAlertService.showError(
        context,
        title: l.text(
          'تعذر تحميل متابعة الرسائل',
          'Failed to load message tracking',
        ),
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  Future<void> _toggleWhatsAppChannel(String channelKey, bool enabled) async {
    final l = context.loc;
    setState(() => _gatewayBusyChannelKey = channelKey);
    try {
      final payload = await _apiService.toggleWhatsAppGatewayChannel(
        channelKey: channelKey,
        enabled: enabled,
      );
      _replaceGatewayDashboard(payload);
      if (!mounted) {
        return;
      }
      await AppAlertService.showSuccess(
        context,
        title: enabled ? 'تم التفعيل' : 'تم الإيقاف',
        message: (payload['message']?.toString().trim().isNotEmpty ?? false)
            ? payload['message'].toString()
            : 'تم تحديث حالة التوكن.',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      await AppAlertService.showError(
        context,
        title: l.text(
          'تعذر تحديث حالة التوكن',
          'Failed to update token status',
        ),
        message: ErrorMessageService.sanitize(error),
      );
    } finally {
      if (mounted) {
        setState(() => _gatewayBusyChannelKey = null);
      }
    }
  }

  Future<void> _testWhatsAppChannel(String channelKey) async {
    final l = context.loc;
    setState(() => _gatewayBusyChannelKey = channelKey);
    try {
      final payload = await _apiService.testWhatsAppGatewayChannel(
        channelKey: channelKey,
      );
      _replaceGatewayDashboard(payload);
      if (!mounted) {
        return;
      }
      await AppAlertService.showSuccess(
        context,
        title: l.text('نجح الاختبار', 'Test succeeded'),
        message: (payload['message']?.toString().trim().isNotEmpty ?? false)
            ? payload['message'].toString()
            : 'تم اختبار التوكن بنجاح.',
      );
    } catch (error) {
      await _refreshMessageGatewayDashboard();
      if (!mounted) {
        return;
      }
      await AppAlertService.showError(
        context,
        title: l.text('فشل اختبار التوكن', 'Token test failed'),
        message: ErrorMessageService.sanitize(error),
      );
    } finally {
      if (mounted) {
        setState(() => _gatewayBusyChannelKey = null);
      }
    }
  }

  Future<void> _testSmsGateway() async {
    final l = context.loc;
    setState(() => _isTestingSmsGateway = true);
    try {
      final payload = await _apiService.testSmsGateway();
      _replaceGatewayDashboard(payload);
      if (!mounted) {
        return;
      }
      if (payload['ok'] == true) {
        await AppAlertService.showSuccess(
          context,
          title: l.text('بوابة SMS جاهزة', 'SMS gateway ready'),
          message: payload['message']?.toString() ?? 'الفحص ناجح.',
        );
      } else {
        await AppAlertService.showInfo(
          context,
          title: l.text('فحص SMS', 'SMS check'),
          message: payload['message']?.toString() ?? 'تم تنفيذ الفحص.',
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      await AppAlertService.showError(
        context,
        title: l.text('تعذر فحص SMS', 'Failed to check SMS'),
        message: ErrorMessageService.sanitize(error),
      );
    } finally {
      if (mounted) {
        setState(() => _isTestingSmsGateway = false);
      }
    }
  }

  void _replaceGatewayDashboard(Map<String, dynamic> payload) {
    final dashboard = payload['dashboard'];
    if (dashboard is Map) {
      setState(() {
        _messageGatewayDashboard = Map<String, dynamic>.from(dashboard);
      });
    }
  }

  Future<void> _exportPrepaidReport() async {
    if (_prepaidReportPayments.isEmpty) {
      await AppAlertService.showError(
        context,
        title: context.loc.tr('screens_admin_system_settings_screen.126'),
        message: context.loc.tr('screens_admin_system_settings_screen.127'),
      );
      return;
    }

    try {
      await _apiService.exportAdminPrepaidMultipayPaymentsCsv(
        payments: _prepaidReportPayments,
      );
      if (!mounted) {
        return;
      }
      await AppAlertService.showSuccess(
        context,
        title: context.loc.tr('screens_admin_system_settings_screen.128'),
        message: context.loc.tr('screens_admin_system_settings_screen.129'),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      await AppAlertService.showError(
        context,
        title: context.loc.tr('screens_admin_system_settings_screen.130'),
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  Future<void> _save() async {
    final l = context.loc;
    setState(() => _isSaving = true);
    try {
      await Future.wait([
        _apiService.updateContactInfo(
          title: _contactTitleController.text,
          supportWhatsapp: _contactWhatsappController.text,
          supportEmail: _contactEmailController.text,
          address: _contactAddressController.text,
        ),
        _apiService.updateAuthSettings(
          registrationEnabled: _registrationEnabled,
          loginOtpRequired: _loginOtpRequired,
          registrationWhatsappVerificationRequired:
              _registrationWhatsappVerificationRequired,
          whatsappUsageMode: _whatsappUsageMode,
          messageDeliveryPriority: _messageDeliveryPriority,
          adminAlertsWhatsappEnabled: _adminAlertsWhatsappEnabled,
          adminAlertsSmsEnabled: _adminAlertsSmsEnabled,
          minSupportedVersion: _minSupportedVersionController.text,
          latestVersion: _latestVersionController.text,
          androidStoreUrl: _androidStoreUrlController.text,
          iosStoreUrl: _iosStoreUrlController.text,
          webStoreUrl: _webStoreUrlController.text,
        ),
        _apiService.updateTransferSettings(
          unverifiedTransferLimit:
              double.tryParse(_unverifiedTransferLimitController.text) ?? 200,
        ),
        _apiService.updateFeeSettings(
          walletTopupPercent:
              double.tryParse(_walletTopupFeeController.text) ?? 1,
          walletTransferPercent:
              double.tryParse(_walletTransferFeeController.text) ?? 1,
          cardRedeemPercent:
              double.tryParse(_cardRedeemFeeController.text) ?? 1,
          cardResellPercent:
              double.tryParse(_cardResellFeeController.text) ?? 1,
          cardPrintRequestPercent:
              double.tryParse(_cardPrintRequestFeeController.text) ?? 1,
          cardPrintCardsPerA4Page:
              int.tryParse(_cardPrintCardsPerA4PageController.text) ?? 35,
          cardPrintPageGroupSize:
              int.tryParse(_cardPrintPageGroupSizeController.text) ?? 3,
          cardPrintPageGroupFee:
              double.tryParse(_cardPrintPageGroupFeeController.text) ?? 1,
          withdrawPercent: double.tryParse(_withdrawFeeController.text) ?? 1,
          standardCardIssueCost:
              double.tryParse(_standardCardIssueCostController.text) ?? 0,
          deliveryCardIssueCost:
              double.tryParse(_deliveryCardIssueCostController.text) ?? 0,
          privateCardIssueCost:
              double.tryParse(_privateCardIssueCostController.text) ?? 0.01,
          singleUseTicketIssueCost:
              double.tryParse(_singleUseTicketIssueCostController.text) ?? 0.02,
          appointmentTicketIssueCost:
              double.tryParse(_appointmentTicketIssueCostController.text) ??
              0.25,
          queueTicketIssueCost:
              double.tryParse(_queueTicketIssueCostController.text) ?? 0.10,
          subscriptionCardIssueCost:
              double.tryParse(_subscriptionCardIssueCostController.text) ??
              0.25,
          attendanceCardIssueCost:
              double.tryParse(_attendanceCardIssueCostController.text) ?? 0.10,
        ),
        _apiService.updateCardScanLimitSettings(
          defaultLimit: int.tryParse(_scanDefaultLimitController.text) ?? 30,
          restrictedLimit:
              int.tryParse(_scanRestrictedLimitController.text) ?? 10,
          basicLimit: int.tryParse(_scanBasicLimitController.text) ?? 30,
          verifiedLimit: int.tryParse(_scanVerifiedLimitController.text) ?? 60,
          driverLimit: int.tryParse(_scanDriverLimitController.text) ?? 200,
          marketerLimit: int.tryParse(_scanMarketerLimitController.text) ?? 40,
          supportLimit: int.tryParse(_scanSupportLimitController.text) ?? 0,
          financeLimit: int.tryParse(_scanFinanceLimitController.text) ?? 0,
          adminLimit: int.tryParse(_scanAdminLimitController.text) ?? 0,
          autoRedeemGlobalForced: _scanAutoRedeemGlobalForced,
          withoutRedeemChargeEvery:
              int.tryParse(_scanWithoutRedeemChargeEveryController.text) ?? 0,
          withoutRedeemChargeAmount:
              double.tryParse(_scanWithoutRedeemChargeAmountController.text) ??
              0,
        ),
        _apiService.updateAdminOfflineCardSettings(
          maxPendingAmount:
              double.tryParse(_offlineMaxPendingAmountController.text) ?? 500,
          maxPendingCount:
              int.tryParse(_offlineMaxPendingCountController.text) ?? 50,
          maxCachedCards:
              int.tryParse(_offlineCacheLimitController.text) ?? 1000,
          syncIntervalMinutes:
              int.tryParse(_offlineSyncIntervalController.text) ?? 60,
        ),
        _apiService.updateAdminPrepaidMultipaySettings(
          maxCardAmount:
              double.tryParse(_prepaidMaxCardAmountController.text) ?? 500,
          maxPaymentAmount:
              double.tryParse(_prepaidMaxPaymentAmountController.text) ?? 250,
          maxActiveCards:
              int.tryParse(_prepaidMaxActiveCardsController.text) ?? 5,
          maxExpiryDays:
              int.tryParse(_prepaidMaxExpiryDaysController.text) ?? 365,
          dailyPaymentAmountLimit:
              double.tryParse(_prepaidDailyAmountLimitController.text) ?? 500,
          dailyPaymentCountLimit:
              int.tryParse(_prepaidDailyCountLimitController.text) ?? 20,
        ),
        _apiService.updateAdminTopupRequestSettings(
          enabled: _topupRequestEnabled,
          instructions: _topupRequestInstructionsController.text,
          minAmount: double.tryParse(_topupMinAmountController.text) ?? 10,
          maxAmount: double.tryParse(_topupMaxAmountController.text) ?? 10000,
        ),
        _apiService.updateAdminWithdrawalRequestSettings(
          enabled: _withdrawalRequestEnabled,
          instructions: _withdrawalRequestInstructionsController.text,
          minAmount:
              double.tryParse(_withdrawalMinAmountController.text) ?? 100,
          maxAmount:
              double.tryParse(_withdrawalMaxAmountController.text) ?? 10000,
        ),
        _apiService.updateCardQuantityLimitSettings(
          defaultLimit: int.tryParse(_cardQtyDefaultController.text) ?? 1,
          restrictedLimit: int.tryParse(_cardQtyRestrictedController.text) ?? 1,
          basicLimit: int.tryParse(_cardQtyBasicController.text) ?? 30,
          verifiedLimit: int.tryParse(_cardQtyVerifiedController.text) ?? 30,
          driverLimit: int.tryParse(_cardQtyDriverController.text) ?? 30,
          marketerLimit: int.tryParse(_cardQtyMarketerController.text) ?? 10,
          supportLimit: int.tryParse(_cardQtySupportController.text) ?? 1,
          financeLimit: int.tryParse(_cardQtyFinanceController.text) ?? 1,
          adminLimit: int.tryParse(_cardQtyAdminController.text) ?? 1,
        ),
        _apiService.updateAffiliateSettings(
          enabled: _affiliateEnabled,
          rewardAmount:
              double.tryParse(_affiliateRewardAmountController.text) ?? 5,
          firstTopupMinAmount:
              double.tryParse(_affiliateFirstTopupMinAmountController.text) ??
              100,
          marketerDebtLimit:
              double.tryParse(_affiliateMarketerDebtLimitController.text) ?? 50,
        ),
        _apiService.updateUsagePolicy(
          title: _policyTitleController.text,
          content: _policyContentController.text,
        ),
        _apiService.updateAdminExternalCardStoreSettings({
          'enabled': _externalStoreEnabled,
          'baseUrl': _externalStoreBaseUrlController.text,
          'apiToken': _externalStoreApiTokenController.text,
          'bearerToken': _externalStoreBearerTokenController.text,
          'username': _externalStoreUsernameController.text,
          'password': _externalStorePasswordController.text,
          'platform': _externalStorePlatformController.text,
          'appVersion': _externalStoreAppVersionController.text,
          'appBuildNumber': _externalStoreBuildNumberController.text,
          'language': _externalStoreLanguageController.text,
          'discountPercent':
              double.tryParse(_externalStoreDiscountController.text) ?? 0,
          'usdToIlsRate':
              double.tryParse(_externalStoreUsdRateController.text) ?? 3.05,
          'profitPercent':
              double.tryParse(_externalStoreProfitController.text) ?? 3,
          'profitPercentsByRole': {
            for (final row in _externalStoreRoleProfitRows)
              if ((row['role']?.toString() ?? '').isNotEmpty)
                row['role'].toString():
                    double.tryParse(
                      _externalRoleProfitController(
                        row['role'].toString(),
                      ).text,
                    ) ??
                    double.tryParse(_externalStoreProfitController.text) ??
                    3,
          },
        }),
      ]);
      if (!mounted) {
        return;
      }
      await AppAlertService.showSuccess(
        context,
        title: l.tr('screens_admin_system_settings_screen.001'),
        message: l.tr('screens_admin_system_settings_screen.035'),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      await AppAlertService.showError(
        context,
        title: l.tr('screens_admin_system_settings_screen.002'),
        message: ErrorMessageService.sanitize(error),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  TextEditingController _externalRoleProfitController(String role) {
    return _externalStoreRoleProfitControllers.putIfAbsent(
      role,
      () => TextEditingController(text: _externalStoreProfitController.text),
    );
  }

  Future<void> _syncExternalCatalog() async {
    if (_isSyncingExternalCatalog) return;
    final l = context.loc;
    setState(() => _isSyncingExternalCatalog = true);
    try {
      final payload = await _apiService.syncAdminExternalCardStoreCatalog();
      _applyExternalCatalogControls(payload['catalogControls']);
      if (!mounted) return;
      final synced = Map<String, dynamic>.from(
        payload['synced'] as Map? ?? const {},
      );
      await AppAlertService.showSuccess(
        context,
        title: l.text('تمت المزامنة', 'Sync complete'),
        message:
            'الأقسام: ${synced['categories'] ?? 0}، البطاقات: ${synced['cards'] ?? 0}.',
      );
    } catch (error) {
      if (!mounted) return;
      await AppAlertService.showError(
        context,
        title: l.text('تعذر مزامنة الكتالوج', 'Failed to sync catalog'),
        message: ErrorMessageService.sanitize(error),
      );
    } finally {
      if (mounted) {
        setState(() => _isSyncingExternalCatalog = false);
      }
    }
  }

  Future<void> _loadExternalCatalogControls() async {
    if (_isLoadingExternalCatalog) return;
    final l = context.loc;
    setState(() => _isLoadingExternalCatalog = true);
    try {
      final payload = await _apiService.getAdminExternalCardStoreCatalog(
        query: _externalStoreCatalogSearchController.text,
      );
      _applyExternalCatalogControls(payload['catalogControls']);
    } catch (error) {
      if (!mounted) return;
      await AppAlertService.showError(
        context,
        title: l.text('تعذر تحميل الكتالوج', 'Failed to load catalog'),
        message: ErrorMessageService.sanitize(error),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoadingExternalCatalog = false);
      }
    }
  }

  Future<void> _refreshExternalProviderBalance() async {
    final l = context.loc;
    try {
      final payload = await _apiService.getAdminExternalCardStoreSettings();
      if (!mounted) return;
      setState(() {
        _externalProviderBalance = Map<String, dynamic>.from(
          payload['providerBalance'] as Map? ?? const {},
        );
      });
    } catch (error) {
      if (!mounted) return;
      await AppAlertService.showError(
        context,
        title: l.text(
          'تعذر تحديث رصيد المصدر',
          'Failed to update provider balance',
        ),
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  Future<void> _updateExternalCatalogItem({
    required String kind,
    required String id,
    String? title,
    String? description,
    String? imageUrl,
    int? sortOrder,
    bool? hidden,
    bool? forceUnavailable,
  }) async {
    final l = context.loc;
    try {
      final payload = await _apiService.updateAdminExternalCardStoreCatalogItem(
        kind: kind,
        id: id,
        title: title,
        description: description,
        imageUrl: imageUrl,
        sortOrder: sortOrder,
        hidden: hidden,
        forceUnavailable: forceUnavailable,
      );
      _applyExternalCatalogControls(payload['catalogControls']);
    } catch (error) {
      if (!mounted) return;
      await AppAlertService.showError(
        context,
        title: l.text('تعذر تحديث الكتالوج', 'Failed to update catalog'),
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  Future<void> _editExternalCatalogItem({
    required String kind,
    required Map<String, dynamic> item,
  }) async {
    final l = context.loc;
    final id = (kind == 'card' ? item['ean'] : item['id'])?.toString() ?? '';
    if (id.isEmpty) return;

    final titleController = TextEditingController(
      text: item['title']?.toString() ?? '',
    );
    final descriptionController = TextEditingController(
      text: item['description']?.toString() ?? '',
    );
    final imageController = TextEditingController(
      text: item['imageUrl']?.toString() ?? '',
    );
    final sortController = TextEditingController(
      text: (item['sortOrder'] as num?)?.toInt().toString() ?? '0',
    );

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(kind == 'card' ? 'تعديل البطاقة' : 'تعديل القسم'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: InputDecoration(
                  labelText: l.text('الاسم المعروض', 'Display name'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descriptionController,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: l.text('الوصف', 'Description'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: imageController,
                decoration: InputDecoration(
                  labelText: l.text('رابط الصورة', 'Image URL'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: sortController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: l.text('الترتيب', 'Sort order'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.text('إلغاء', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.text('حفظ', 'Save')),
          ),
        ],
      ),
    );

    if (saved != true) {
      titleController.dispose();
      descriptionController.dispose();
      imageController.dispose();
      sortController.dispose();
      return;
    }

    await _updateExternalCatalogItem(
      kind: kind,
      id: id,
      title: titleController.text,
      description: descriptionController.text,
      imageUrl: imageController.text,
      sortOrder: int.tryParse(sortController.text) ?? 0,
    );

    titleController.dispose();
    descriptionController.dispose();
    imageController.dispose();
    sortController.dispose();
  }

  void _applyExternalCatalogControls(dynamic value) {
    if (!mounted) return;
    final controls = Map<String, dynamic>.from(value as Map? ?? const {});
    setState(() {
      _externalCatalogCategories = List<Map<String, dynamic>>.from(
        (controls['categories'] as List? ?? const []).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
      _externalCatalogCards = List<Map<String, dynamic>>.from(
        (controls['cards'] as List? ?? const []).map(
          (item) => Map<String, dynamic>.from(item as Map),
        ),
      );
    });
  }

  Future<void> _showTopupMethodDialog({Map<String, dynamic>? method}) async {
    final l = context.loc;
    final titleController = TextEditingController(
      text: method?['title']?.toString() ?? '',
    );
    final descriptionController = TextEditingController(
      text: method?['description']?.toString() ?? '',
    );
    final imageUrlController = TextEditingController(
      text: method?['imageUrl']?.toString() ?? '',
    );
    final accountNumberController = TextEditingController(
      text: method?['accountNumber']?.toString() ?? '',
    );
    final sortOrderController = TextEditingController(
      text: (method?['sortOrder'] ?? 0).toString(),
    );
    var isActive = method?['isActive'] != false;
    var isSaving = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> submit() async {
            if (titleController.text.trim().isEmpty ||
                accountNumberController.text.trim().isEmpty) {
              await AppAlertService.showError(
                dialogContext,
                title: l.tr('screens_admin_system_settings_screen.003'),
                message: l.tr('screens_admin_system_settings_screen.036'),
              );
              return;
            }
            setDialogState(() => isSaving = true);
            try {
              final methods = await _apiService.saveAdminTopupPaymentMethod(
                methodId: method?['id']?.toString(),
                title: titleController.text,
                description: descriptionController.text,
                imageUrl: imageUrlController.text,
                accountNumber: accountNumberController.text,
                isActive: isActive,
                sortOrder: int.tryParse(sortOrderController.text) ?? 0,
              );
              if (!dialogContext.mounted) {
                return;
              }
              Navigator.pop(dialogContext);
              if (!mounted) {
                return;
              }
              setState(() => _topupPaymentMethods = methods);
            } catch (error) {
              if (!dialogContext.mounted) {
                return;
              }
              setDialogState(() => isSaving = false);
              await AppAlertService.showError(
                dialogContext,
                title: l.tr('screens_admin_system_settings_screen.004'),
                message: ErrorMessageService.sanitize(error),
              );
            }
          }

          return AlertDialog(
            title: Text(
              method == null
                  ? l.tr('screens_admin_system_settings_screen.005')
                  : l.tr('screens_admin_system_settings_screen.006'),
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    TextField(
                      controller: titleController,
                      decoration: InputDecoration(
                        labelText: l.tr(
                          'screens_admin_system_settings_screen.007',
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: accountNumberController,
                      decoration: InputDecoration(
                        labelText: l.tr(
                          'screens_admin_system_settings_screen.037',
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: imageUrlController,
                      decoration: InputDecoration(
                        labelText: l.tr(
                          'screens_admin_system_settings_screen.008',
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: sortOrderController,
                      decoration: InputDecoration(
                        labelText: l.tr(
                          'screens_admin_system_settings_screen.009',
                        ),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descriptionController,
                      decoration: InputDecoration(
                        labelText: l.tr(
                          'screens_admin_system_settings_screen.010',
                        ),
                      ),
                      minLines: 2,
                      maxLines: 4,
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: isActive,
                      onChanged: (value) =>
                          setDialogState(() => isActive = value),
                      title: Text(
                        l.tr('screens_admin_system_settings_screen.011'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSaving ? null : () => Navigator.pop(dialogContext),
                child: Text(l.tr('screens_admin_system_settings_screen.012')),
              ),
              ElevatedButton(
                onPressed: isSaving ? null : submit,
                child: Text(
                  isSaving
                      ? l.tr('screens_admin_system_settings_screen.013')
                      : l.tr('screens_admin_system_settings_screen.014'),
                ),
              ),
            ],
          );
        },
      ),
    );

    titleController.dispose();
    descriptionController.dispose();
    imageUrlController.dispose();
    accountNumberController.dispose();
    sortOrderController.dispose();
  }

  Future<void> _deleteTopupMethod(Map<String, dynamic> method) async {
    final l = context.loc;
    final methodId = method['id']?.toString().trim() ?? '';
    if (methodId.isEmpty) {
      await AppAlertService.showError(
        context,
        title: l.tr('screens_admin_system_settings_screen.015'),
        message: 'تعذر تحديد طريقة الشحن المطلوبة.',
      );
      return;
    }

    try {
      final methods = await _apiService.deleteAdminTopupPaymentMethod(methodId);
      if (!mounted) {
        return;
      }
      setState(() => _topupPaymentMethods = methods);
    } catch (error) {
      if (!mounted) {
        return;
      }
      await AppAlertService.showError(
        context,
        title: l.tr('screens_admin_system_settings_screen.015'),
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  Future<void> _showWithdrawalMethodDialog({
    Map<String, dynamic>? method,
  }) async {
    final l = context.loc;
    final codeController = TextEditingController(
      text: method?['code']?.toString() ?? '',
    );
    final titleController = TextEditingController(
      text: method?['title']?.toString() ?? '',
    );
    final descriptionController = TextEditingController(
      text: method?['description']?.toString() ?? '',
    );
    final accountLabelController = TextEditingController(
      text: method?['accountLabel']?.toString() ?? 'رقم الحساب أو المحفظة',
    );
    final sortOrderController = TextEditingController(
      text: (method?['sortOrder'] ?? 0).toString(),
    );
    var requiresBankName = method?['requiresBankName'] == true;
    var isActive = method?['isActive'] != false;
    var isSaving = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> submit() async {
            if (codeController.text.trim().isEmpty ||
                titleController.text.trim().isEmpty ||
                accountLabelController.text.trim().isEmpty) {
              await AppAlertService.showError(
                dialogContext,
                title: l.tr('screens_admin_system_settings_screen.131'),
                message: l.tr('screens_admin_system_settings_screen.132'),
              );
              return;
            }
            setDialogState(() => isSaving = true);
            try {
              final methods = await _apiService.saveAdminWithdrawalMethod(
                methodId: method?['id']?.toString(),
                code: codeController.text,
                title: titleController.text,
                description: descriptionController.text,
                accountLabel: accountLabelController.text,
                requiresBankName: requiresBankName,
                isActive: isActive,
                sortOrder: int.tryParse(sortOrderController.text) ?? 0,
              );
              if (!dialogContext.mounted) {
                return;
              }
              Navigator.pop(dialogContext);
              if (!mounted) {
                return;
              }
              setState(() => _withdrawalMethods = methods);
            } catch (error) {
              if (!dialogContext.mounted) {
                return;
              }
              setDialogState(() => isSaving = false);
              await AppAlertService.showError(
                dialogContext,
                title: l.tr('screens_admin_system_settings_screen.133'),
                message: ErrorMessageService.sanitize(error),
              );
            }
          }

          return AlertDialog(
            title: Text(
              method == null
                  ? l.tr('screens_admin_system_settings_screen.134')
                  : l.tr('screens_admin_system_settings_screen.135'),
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    TextField(
                      controller: codeController,
                      decoration: InputDecoration(
                        labelText: l.tr(
                          'screens_admin_system_settings_screen.136',
                        ),
                        helperText: l.tr(
                          'screens_admin_system_settings_screen.137',
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: titleController,
                      decoration: InputDecoration(
                        labelText: l.tr(
                          'screens_admin_system_settings_screen.138',
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: accountLabelController,
                      decoration: InputDecoration(
                        labelText: l.tr(
                          'screens_admin_system_settings_screen.139',
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: sortOrderController,
                      decoration: InputDecoration(
                        labelText: l.tr(
                          'screens_admin_system_settings_screen.140',
                        ),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descriptionController,
                      decoration: InputDecoration(
                        labelText: l.tr(
                          'screens_admin_system_settings_screen.141',
                        ),
                      ),
                      minLines: 2,
                      maxLines: 4,
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: requiresBankName,
                      onChanged: (value) =>
                          setDialogState(() => requiresBankName = value),
                      title: Text(
                        l.tr('screens_admin_system_settings_screen.142'),
                      ),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: isActive,
                      onChanged: (value) =>
                          setDialogState(() => isActive = value),
                      title: Text(
                        l.tr('screens_admin_system_settings_screen.143'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: isSaving ? null : () => Navigator.pop(dialogContext),
                child: Text(l.tr('screens_admin_system_settings_screen.012')),
              ),
              ElevatedButton(
                onPressed: isSaving ? null : submit,
                child: Text(
                  isSaving
                      ? l.tr('screens_admin_system_settings_screen.144')
                      : l.tr('screens_admin_system_settings_screen.145'),
                ),
              ),
            ],
          );
        },
      ),
    );

    codeController.dispose();
    titleController.dispose();
    descriptionController.dispose();
    accountLabelController.dispose();
    sortOrderController.dispose();
  }

  Future<void> _deleteWithdrawalMethod(Map<String, dynamic> method) async {
    final l = context.loc;
    final methodId = method['id']?.toString().trim() ?? '';
    if (methodId.isEmpty) {
      await AppAlertService.showError(
        context,
        title: l.text('تعذر الحذف', 'Failed to delete'),
        message: 'تعذر تحديد طريقة السحب المطلوبة.',
      );
      return;
    }

    try {
      final methods = await _apiService.deleteAdminWithdrawalMethod(methodId);
      if (!mounted) {
        return;
      }
      setState(() => _withdrawalMethods = methods);
    } catch (error) {
      if (!mounted) {
        return;
      }
      await AppAlertService.showError(
        context,
        title: l.text('تعذر الحذف', 'Failed to delete'),
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.loc;
    if (_isLoading) {
      return const ShwakelPageLoadingScaffold();
    }

    if (!_isAuthorized) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          title: Text(
            l.text('إعدادات النظام', 'System settings'),
            style: AppTheme.bodyBold,
          ),
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
                  l.tr('screens_admin_system_settings_screen.058'),
                  style: AppTheme.h3,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return DefaultTabController(
      length: 10,
      child: Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          title: Text(
            l.text('إعدادات النظام', 'System settings'),
            style: AppTheme.bodyBold,
          ),
          actions: const [AppNotificationAction(), QuickLogoutAction()],
        ),
        drawer: AppSidebar.drawerFor(context),
        body: ResponsiveScaffoldContainer(
          padding: const EdgeInsets.all(AppTheme.spacingLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShwakelCard(
                padding: const EdgeInsets.all(28),
                gradient: AppTheme.primaryGradient,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.tr('screens_admin_system_settings_screen.017'),
                      style: AppTheme.h2.copyWith(color: Colors.white),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l.tr('screens_admin_system_settings_screen.038'),
                      style: AppTheme.bodyAction.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              ShwakelCard(
                padding: const EdgeInsets.all(10),
                borderRadius: BorderRadius.circular(24),
                shadowLevel: ShwakelShadowLevel.soft,
                child: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  dividerColor: Colors.transparent,
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicatorPadding: const EdgeInsets.all(4),
                  tabs: [
                    Tab(
                      icon: const Icon(Icons.support_agent_rounded),
                      text: l.tr('screens_admin_system_settings_screen.053'),
                    ),
                    Tab(
                      icon: const Icon(Icons.system_update_rounded),
                      text: l.tr('screens_admin_system_settings_screen.054'),
                    ),
                    Tab(
                      icon: const Icon(Icons.notifications_active_rounded),
                      text: l.text('الرسائل', 'Messages'),
                    ),
                    Tab(
                      icon: const Icon(Icons.add_card_rounded),
                      text: l.tr('screens_admin_system_settings_screen.055'),
                    ),
                    Tab(
                      icon: const Icon(Icons.cloud_off_rounded),
                      text: l.tr('screens_admin_system_settings_screen.075'),
                    ),
                    const Tab(
                      icon: Icon(Icons.credit_card_rounded),
                      text: 'بطاقات الدفع',
                    ),
                    const Tab(
                      icon: Icon(Icons.storefront_rounded),
                      text: 'متجر البطاقات',
                    ),
                    Tab(
                      icon: const Icon(Icons.campaign_rounded),
                      text: l.tr('screens_admin_system_settings_screen.066'),
                    ),
                    Tab(
                      icon: const Icon(Icons.policy_rounded),
                      text: l.tr('screens_admin_system_settings_screen.056'),
                    ),
                    Tab(
                      icon: const Icon(Icons.percent_rounded),
                      text: l.tr('screens_admin_system_settings_screen.057'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildContactTab(),
                    _buildAppTab(),
                    _buildMessagingTab(),
                    _buildTopupTab(),
                    _buildOfflineCardsTab(),
                    _buildPrepaidMultipayTab(),
                    _buildExternalCardStoreTab(),
                    _buildAffiliateTab(),
                    _buildPolicyTab(),
                    _buildFeesTab(),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ShwakelButton(
                label: l.tr('screens_admin_system_settings_screen.034'),
                icon: Icons.save_rounded,
                onPressed: _save,
                isLoading: _isSaving,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(Widget child) {
    return ShwakelCard(padding: const EdgeInsets.all(20), child: child);
  }

  String _normalizeWhatsappUsageMode(Object? value) {
    final mode = value?.toString().trim().toLowerCase();
    if (mode == 'registration' || mode == 'financial' || mode == 'all') {
      return mode!;
    }
    return 'all';
  }

  String _normalizeMessageDeliveryPriority(Object? value) {
    final priority = value?.toString().trim().toLowerCase();
    if (priority == 'whatsapp' || priority == 'sms') {
      return priority!;
    }
    return 'whatsapp';
  }

  Widget _buildContactTab() {
    final l = context.loc;
    return _tabScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminSectionHeader(
            title: l.tr('screens_admin_system_settings_screen.018'),
            subtitle: l.tr('screens_admin_system_settings_screen.061'),
            icon: Icons.support_agent_rounded,
          ),
          const SizedBox(height: 16),
          _card(
            Column(
              children: [
                TextField(
                  controller: _contactTitleController,
                  decoration: InputDecoration(
                    labelText: l.tr('screens_admin_system_settings_screen.019'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _contactWhatsappController,
                  decoration: InputDecoration(
                    labelText: l.text('رقم SMS للدعم', 'Support SMS number'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _contactEmailController,
                  decoration: InputDecoration(
                    labelText: l.tr('screens_admin_system_settings_screen.021'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _contactAddressController,
                  decoration: InputDecoration(
                    labelText: l.tr('screens_admin_system_settings_screen.022'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppTab() {
    final l = context.loc;
    return _tabScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminSectionHeader(
            title: l.tr('screens_admin_system_settings_screen.040'),
            subtitle: l.tr('screens_admin_system_settings_screen.062'),
            icon: Icons.tune_rounded,
          ),
          const SizedBox(height: 16),
          _card(
            Column(
              children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _registrationEnabled,
                  onChanged: (value) =>
                      setState(() => _registrationEnabled = value),
                  title: Text(l.tr('screens_admin_system_settings_screen.042')),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _loginOtpRequired,
                  onChanged: (value) =>
                      setState(() => _loginOtpRequired = value),
                  title: Text(l.tr('screens_admin_system_settings_screen.146')),
                  subtitle: Text(
                    l.tr('screens_admin_system_settings_screen.147'),
                  ),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _adminAlertsSmsEnabled,
                  onChanged: (value) =>
                      setState(() => _adminAlertsSmsEnabled = value),
                  title: Text(
                    l.text('تنبيهات الإدارة عبر SMS', 'Admin alerts via SMS'),
                  ),
                  subtitle: const Text(
                    'عند إيقافه لن يستخدم SMS لتنبيهات الإدارة الخارجية.',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _unverifiedTransferLimitController,
                  decoration: InputDecoration(
                    labelText: l.tr('screens_admin_system_settings_screen.043'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _minSupportedVersionController,
                  decoration: InputDecoration(
                    labelText: l.tr('screens_admin_system_settings_screen.044'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _latestVersionController,
                  decoration: InputDecoration(
                    labelText: l.tr('screens_admin_system_settings_screen.045'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _androidStoreUrlController,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: l.tr('screens_admin_system_settings_screen.051'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _iosStoreUrlController,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: l.tr('screens_admin_system_settings_screen.052'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _webStoreUrlController,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: l.tr('screens_admin_system_settings_screen.059'),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    l.tr('screens_admin_system_settings_screen.060'),
                    style: AppTheme.caption,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessagingTab() {
    final l = context.loc;
    final summary = Map<String, dynamic>.from(
      _messageGatewayDashboard['summary'] as Map? ?? const {},
    );
    final whatsappSummary = Map<String, dynamic>.from(
      summary['whatsapp'] as Map? ?? const {},
    );
    final smsSummary = Map<String, dynamic>.from(
      summary['sms'] as Map? ?? const {},
    );
    final channels = List<Map<String, dynamic>>.from(
      (_messageGatewayDashboard['channels'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );

    return _tabScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminSectionHeader(
            title: l.text('متابعة الرسائل', 'Message tracking'),
            subtitle:
                'مراقبة الإشعارات وOTP وبيانات الحساب خلال آخر 24 ساعة مع إدارة القنوات يدويًا.',
            icon: Icons.wifi_tethering_rounded,
          ),
          const SizedBox(height: 16),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _buildGatewayStatCard(
                      title: l.text('واتساب 24 ساعة', 'WhatsApp 24h'),
                      value: '${whatsappSummary['sentCount24h'] ?? 0} إرسال',
                      subtitle:
                          '${whatsappSummary['uniqueRecipients24h'] ?? 0} رقم مختلف',
                      icon: Icons.mark_chat_unread_rounded,
                    ),
                    _buildGatewayStatCard(
                      title: l.text('فشل واتساب', 'WhatsApp failures'),
                      value: '${whatsappSummary['failedCount24h'] ?? 0} عملية',
                      subtitle: '${summary['blockedChannels'] ?? 0} توكن متوقف',
                      icon: Icons.warning_amber_rounded,
                    ),
                    _buildGatewayStatCard(
                      title: 'SMS 24 ساعة',
                      value: '${smsSummary['sentCount24h'] ?? 0} إرسال',
                      subtitle:
                          '${smsSummary['uniqueRecipients24h'] ?? 0} رقم مختلف',
                      icon: Icons.sms_rounded,
                    ),
                    _buildGatewayStatCard(
                      title: l.text('أجهزة SMS', 'SMS devices'),
                      value: '${smsSummary['onlineDevicesCount'] ?? 0} أونلاين',
                      subtitle: '${smsSummary['devicesCount'] ?? 0} إجمالي',
                      icon: Icons.phonelink_ring_rounded,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _isLoadingGatewayDashboard
                            ? 'جارٍ تحديث لوحة المتابعة...'
                            : 'يمكنك اختبار كل توكن، وإذا فشل سيتم إيقافه تلقائيًا حتى تعيد تفعيله يدويًا.',
                        style: AppTheme.caption.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ShwakelButton(
                      label: l.text('تحديث', 'Refresh'),
                      icon: Icons.refresh_rounded,
                      onPressed: _refreshMessageGatewayDashboard,
                      isLoading: _isLoadingGatewayDashboard,
                    ),
                    const SizedBox(width: 8),
                    ShwakelButton(
                      label: l.text('فحص SMS', 'Check SMS'),
                      icon: Icons.sms_rounded,
                      onPressed: _testSmsGateway,
                      isLoading: _isTestingSmsGateway,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: channels.length,
            separatorBuilder: (context, index) => const SizedBox(height: 14),
            itemBuilder: (context, index) =>
                _buildWhatsAppChannelCard(channels[index]),
          ),
          if (channels.isEmpty)
            _card(
              const Text(
                'لا توجد توكنات واتساب معرفة حاليًا داخل إعدادات البيئة.',
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWhatsAppChannelCard(Map<String, dynamic> channel) {
    final l = context.loc;
    final channelKey = channel['channelKey']?.toString() ?? '';
    final isBusy = _gatewayBusyChannelKey == channelKey;
    final isEnabled = channel['isEnabled'] == true;
    final isBlocked = channel['isBlocked'] == true;
    final status = _channelStatusLabel(
      channel['lastHealthStatus']?.toString(),
      isEnabled: isEnabled,
      isBlocked: isBlocked,
    );
    final stats = Map<String, dynamic>.from(
      channel['stats24h'] as Map? ?? const {},
    );
    final blockedReason = channel['blockedReason']?.toString().trim() ?? '';
    final lastTestMessage = channel['lastTestMessage']?.toString().trim() ?? '';
    final lastFailureReason =
        channel['lastFailureReason']?.toString().trim() ?? '';

    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      channel['displayName']?.toString() ?? 'توكن واتساب',
                      style: AppTheme.bodyBold,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'آخر 8 أحرف: ${channel['tokenLastEight'] ?? '-'}',
                      style: AppTheme.caption.copyWith(
                        color: AppTheme.textSecondary,
                      ),
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
                  color: _channelStatusColor(status).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  status,
                  style: AppTheme.caption.copyWith(
                    color: _channelStatusColor(status),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _buildMiniInfoChip(
                'أرقام 24 ساعة',
                '${stats['uniqueRecipients24h'] ?? 0}',
              ),
              _buildMiniInfoChip(
                'إرسال 24 ساعة',
                '${stats['sentCount24h'] ?? 0}',
              ),
              _buildMiniInfoChip(
                'فشل 24 ساعة',
                '${stats['failedCount24h'] ?? 0}',
              ),
              _buildMiniInfoChip(
                'آخر نجاح',
                _shortDateTime(channel['lastSuccessAt']?.toString()),
              ),
              _buildMiniInfoChip(
                'آخر اختبار',
                _shortDateTime(channel['lastTestedAt']?.toString()),
              ),
            ],
          ),
          if (blockedReason.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'سبب الإيقاف: $blockedReason',
              style: AppTheme.caption.copyWith(color: AppTheme.error),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (lastFailureReason.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'آخر خطأ: $lastFailureReason',
              style: AppTheme.caption.copyWith(color: AppTheme.error),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (lastTestMessage.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'ملاحظة الاختبار: $lastTestMessage',
              style: AppTheme.caption.copyWith(color: AppTheme.textSecondary),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              ShwakelButton(
                label: l.text('اختبار', 'Test'),
                icon: Icons.play_arrow_rounded,
                onPressed: isBusy
                    ? null
                    : () => _testWhatsAppChannel(channelKey),
                isLoading: isBusy,
              ),
              ShwakelButton(
                label: isEnabled ? 'إيقاف يدوي' : 'تفعيل يدوي',
                icon: isEnabled
                    ? Icons.pause_circle_filled_rounded
                    : Icons.check_circle_rounded,
                onPressed: isBusy
                    ? null
                    : () => _toggleWhatsAppChannel(channelKey, !isEnabled),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGatewayStatCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
  }) {
    return SizedBox(
      width: 220,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: AppTheme.primary),
            const SizedBox(height: 12),
            Text(title, style: AppTheme.caption),
            const SizedBox(height: 6),
            Text(value, style: AppTheme.bodyBold),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: AppTheme.caption.copyWith(color: AppTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniInfoChip(String title, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: RichText(
        text: TextSpan(
          style: AppTheme.caption.copyWith(color: AppTheme.textSecondary),
          children: [
            TextSpan(text: '$title: '),
            TextSpan(
              text: value,
              style: AppTheme.caption.copyWith(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _channelStatusLabel(
    String? value, {
    required bool isEnabled,
    required bool isBlocked,
  }) {
    if (!isEnabled) {
      return 'موقوف يدويًا';
    }
    if (isBlocked) {
      return 'متوقف ويحتاج تفعيل';
    }

    return switch ((value ?? '').trim()) {
      'healthy' => 'سليم',
      'manual_enabled' => 'تم تفعيله',
      'failed' => 'فشل',
      'unknown' || '' => 'غير مفحوص',
      _ => value!.trim(),
    };
  }

  Color _channelStatusColor(String status) {
    if (status.contains('سليم') || status.contains('تفعيله')) {
      return AppTheme.primary;
    }
    if (status.contains('غير')) {
      return AppTheme.warning;
    }
    return AppTheme.error;
  }

  String _shortDateTime(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) {
      return '—';
    }

    final parsed = DateTime.tryParse(text);
    if (parsed == null) {
      return text;
    }

    final local = parsed.toLocal();
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mi = local.minute.toString().padLeft(2, '0');
    return '$mm/$dd $hh:$mi';
  }

  Widget _buildTopupTab() {
    final l = context.loc;
    return _tabScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminSectionHeader(
            title: l.tr('screens_admin_system_settings_screen.024'),
            subtitle: l.tr('screens_admin_system_settings_screen.063'),
            icon: Icons.add_card_rounded,
          ),
          const SizedBox(height: 16),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _topupRequestEnabled,
                  onChanged: (value) =>
                      setState(() => _topupRequestEnabled = value),
                  title: Text(l.tr('screens_admin_system_settings_screen.047')),
                ),
                TextField(
                  controller: _topupRequestInstructionsController,
                  minLines: 3,
                  maxLines: 5,
                  decoration: InputDecoration(
                    labelText: l.tr('screens_admin_system_settings_screen.048'),
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    _buildNumberField(
                      'الحد الأدنى لطلب الشحن',
                      _topupMinAmountController,
                      decimal: true,
                    ),
                    _buildNumberField(
                      'الحد الأعلى لطلب الشحن',
                      _topupMaxAmountController,
                      decimal: true,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l.tr('screens_admin_system_settings_screen.155'),
                        style: AppTheme.bodyBold,
                      ),
                    ),
                    ShwakelButton(
                      label: l.tr('screens_admin_system_settings_screen.025'),
                      icon: Icons.playlist_add_rounded,
                      onPressed: _showTopupMethodDialog,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_topupPaymentMethods.isEmpty)
                  Text(
                    l.tr('screens_admin_system_settings_screen.049'),
                    style: AppTheme.bodyAction,
                  )
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _topupPaymentMethods.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final method = _topupPaymentMethods[index];
                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: AppTheme.border),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    method['title']?.toString() ?? '-',
                                    style: AppTheme.bodyBold,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    method['accountNumber']?.toString() ?? '-',
                                    style: AppTheme.bodyAction,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: () =>
                                  _showTopupMethodDialog(method: method),
                              icon: const Icon(Icons.edit_rounded),
                            ),
                            IconButton(
                              onPressed: () => _deleteTopupMethod(method),
                              icon: const Icon(Icons.delete_outline_rounded),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l.tr('screens_admin_system_settings_screen.156'),
                        style: AppTheme.bodyBold,
                      ),
                    ),
                    ShwakelButton(
                      label: l.tr('screens_admin_system_settings_screen.134'),
                      icon: Icons.playlist_add_rounded,
                      onPressed: _showWithdrawalMethodDialog,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _withdrawalRequestEnabled,
                  onChanged: (value) =>
                      setState(() => _withdrawalRequestEnabled = value),
                  title: Text(l.tr('screens_admin_system_settings_screen.157')),
                ),
                TextField(
                  controller: _withdrawalRequestInstructionsController,
                  minLines: 3,
                  maxLines: 5,
                  decoration: InputDecoration(
                    labelText: l.tr('screens_admin_system_settings_screen.158'),
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    _buildNumberField(
                      l.tr('screens_admin_system_settings_screen.159'),
                      _withdrawalMinAmountController,
                      decimal: true,
                    ),
                    _buildNumberField(
                      l.tr('screens_admin_system_settings_screen.160'),
                      _withdrawalMaxAmountController,
                      decimal: true,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_withdrawalMethods.isEmpty)
                  Text(
                    l.tr('screens_admin_system_settings_screen.161'),
                    style: AppTheme.bodyAction,
                  )
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _withdrawalMethods.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final method = _withdrawalMethods[index];
                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: AppTheme.border),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    method['title']?.toString() ?? '-',
                                    style: AppTheme.bodyBold,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${method['code']} | ${method['accountLabel']}',
                                    style: AppTheme.bodyAction,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: () =>
                                  _showWithdrawalMethodDialog(method: method),
                              icon: const Icon(Icons.edit_rounded),
                            ),
                            IconButton(
                              onPressed: () => _deleteWithdrawalMethod(method),
                              icon: const Icon(Icons.delete_outline_rounded),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.tr('screens_admin_system_settings_screen.173'),
                  style: AppTheme.bodyBold,
                ),
                const SizedBox(height: 8),
                Text(
                  l.tr('screens_admin_system_settings_screen.174'),
                  style: AppTheme.bodyAction,
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    _buildNumberField(
                      l.tr('screens_admin_system_settings_screen.175'),
                      _cardQtyDefaultController,
                    ),
                    _buildNumberField(
                      l.tr('screens_admin_system_settings_screen.176'),
                      _cardQtyRestrictedController,
                    ),
                    _buildNumberField(
                      l.tr('screens_admin_system_settings_screen.177'),
                      _cardQtyBasicController,
                    ),
                    _buildNumberField(
                      l.tr('screens_admin_system_settings_screen.178'),
                      _cardQtyVerifiedController,
                    ),
                    _buildNumberField(
                      l.tr('screens_admin_system_settings_screen.179'),
                      _cardQtyDriverController,
                    ),
                    _buildNumberField(
                      l.tr('screens_admin_system_settings_screen.180'),
                      _cardQtyMarketerController,
                    ),
                    _buildNumberField(
                      l.tr('screens_admin_system_settings_screen.181'),
                      _cardQtySupportController,
                    ),
                    _buildNumberField(
                      l.tr('screens_admin_system_settings_screen.182'),
                      _cardQtyFinanceController,
                    ),
                    _buildNumberField(
                      l.tr('screens_admin_system_settings_screen.183'),
                      _cardQtyAdminController,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOfflineCardsTab() {
    final l = context.loc;
    return _tabScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminSectionHeader(
            title: l.tr('screens_admin_system_settings_screen.075'),
            subtitle: l.tr('screens_admin_system_settings_screen.076'),
            icon: Icons.cloud_off_rounded,
          ),
          const SizedBox(height: 16),
          _card(
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _buildNumberField(
                  l.tr('screens_admin_system_settings_screen.077'),
                  _offlineSyncIntervalController,
                  suffixText: l.tr('screens_admin_system_settings_screen.081'),
                ),
                _buildNumberField(
                  l.tr('screens_admin_system_settings_screen.078'),
                  _offlineCacheLimitController,
                ),
                _buildNumberField(
                  l.tr('screens_admin_system_settings_screen.079'),
                  _offlineMaxPendingCountController,
                ),
                _buildNumberField(
                  l.tr('screens_admin_system_settings_screen.080'),
                  _offlineMaxPendingAmountController,
                  decimal: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrepaidMultipayTab() {
    final reportCount = (_prepaidReportSummary['count'] as num?)?.toInt() ?? 0;
    final reportTotal =
        (_prepaidReportSummary['totalAmount'] as num?)?.toDouble() ?? 0;

    return _tabScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminSectionHeader(
            title: context.loc.tr('screens_admin_system_settings_screen.184'),
            subtitle: context.loc.tr(
              'screens_admin_system_settings_screen.185',
            ),
            icon: Icons.credit_card_rounded,
          ),
          const SizedBox(height: 16),
          _card(
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _buildNumberField(
                  context.loc.tr('screens_admin_system_settings_screen.186'),
                  _prepaidMaxCardAmountController,
                  decimal: true,
                ),
                _buildNumberField(
                  context.loc.tr('screens_admin_system_settings_screen.187'),
                  _prepaidMaxPaymentAmountController,
                  decimal: true,
                ),
                _buildNumberField(
                  context.loc.tr('screens_admin_system_settings_screen.188'),
                  _prepaidMaxActiveCardsController,
                ),
                _buildNumberField(
                  context.loc.tr('screens_admin_system_settings_screen.189'),
                  _prepaidMaxExpiryDaysController,
                ),
                _buildNumberField(
                  context.loc.tr('screens_admin_system_settings_screen.190'),
                  _prepaidDailyAmountLimitController,
                  decimal: true,
                ),
                _buildNumberField(
                  context.loc.tr('screens_admin_system_settings_screen.191'),
                  _prepaidDailyCountLimitController,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AdminSectionHeader(
            title: context.loc.tr('screens_admin_system_settings_screen.162'),
            subtitle: context.loc.tr(
              'screens_admin_system_settings_screen.163',
            ),
            icon: Icons.receipt_long_rounded,
            trailing: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _isLoadingPrepaidReport
                      ? null
                      : _loadPrepaidReport,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(
                    context.loc.tr('screens_admin_system_settings_screen.164'),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _isLoadingPrepaidReport
                      ? null
                      : _exportPrepaidReport,
                  icon: const Icon(Icons.file_download_rounded),
                  label: const Text('CSV'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    _buildTextField(
                      context.loc.tr(
                        'screens_admin_system_settings_screen.165',
                      ),
                      _prepaidReportSearchController,
                      hintText: context.loc.tr(
                        'screens_admin_system_settings_screen.166',
                      ),
                    ),
                    _buildNumberField(
                      context.loc.tr(
                        'screens_admin_system_settings_screen.192',
                      ),
                      _prepaidReportBuyerIdController,
                    ),
                    _buildNumberField(
                      context.loc.tr(
                        'screens_admin_system_settings_screen.193',
                      ),
                      _prepaidReportMerchantIdController,
                    ),
                    _buildTextField(
                      context.loc.tr(
                        'screens_admin_system_settings_screen.194',
                      ),
                      _prepaidReportDateFromController,
                      hintText: '2026-04-26',
                    ),
                    _buildTextField(
                      context.loc.tr(
                        'screens_admin_system_settings_screen.195',
                      ),
                      _prepaidReportDateToController,
                      hintText: '2026-04-26',
                    ),
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<String>(
                        initialValue: _prepaidReportCardStatus,
                        decoration: InputDecoration(
                          labelText: context.loc.tr(
                            'screens_admin_system_settings_screen.167',
                          ),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text(
                              context.loc.tr(
                                'screens_admin_system_settings_screen.168',
                              ),
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'active',
                            child: Text(
                              context.loc.tr(
                                'screens_admin_system_settings_screen.196',
                              ),
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'frozen',
                            child: Text(
                              context.loc.tr(
                                'screens_admin_system_settings_screen.197',
                              ),
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'spent',
                            child: Text(
                              context.loc.tr(
                                'screens_admin_system_settings_screen.198',
                              ),
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'expired',
                            child: Text(
                              context.loc.tr(
                                'screens_admin_system_settings_screen.199',
                              ),
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'cancelled',
                            child: Text(
                              context.loc.tr(
                                'screens_admin_system_settings_screen.200',
                              ),
                            ),
                          ),
                        ],
                        onChanged: (value) => setState(
                          () => _prepaidReportCardStatus = value ?? 'all',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _reportPill(
                      Icons.format_list_numbered_rounded,
                      'عدد العمليات',
                      '$reportCount',
                    ),
                    _reportPill(
                      Icons.payments_rounded,
                      'الإجمالي',
                      CurrencyFormatter.ils(reportTotal),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_isLoadingPrepaidReport)
                  const Center(child: CircularProgressIndicator())
                else if (_prepaidReportPayments.isEmpty)
                  Text(
                    'لا توجد مدفوعات مطابقة للفلاتر الحالية.',
                    style: AppTheme.bodyAction,
                  )
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _prepaidReportPayments.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) =>
                        _buildPrepaidReportRow(_prepaidReportPayments[index]),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _reportPill(IconData icon, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AppTheme.primary),
          const SizedBox(width: 8),
          Text('$label: $value', style: AppTheme.caption),
        ],
      ),
    );
  }

  Widget _buildPrepaidReportRow(Map<String, dynamic> payment) {
    final amount = (payment['amount'] as num?)?.toDouble() ?? 0;
    final buyer = payment['buyerUsername']?.toString() ?? '-';
    final merchant = payment['merchantUsername']?.toString() ?? '-';
    final note = payment['note']?.toString() ?? '';
    final createdAt = payment['createdAt']?.toString() ?? '';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.receipt_long_rounded, color: AppTheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$buyer ← $merchant',
                  style: AppTheme.bodyBold,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  note.isEmpty ? createdAt : '$note · $createdAt',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.caption,
                ),
              ],
            ),
          ),
          Text(
            CurrencyFormatter.ils(amount),
            style: AppTheme.bodyBold.copyWith(color: AppTheme.success),
          ),
        ],
      ),
    );
  }

  Widget _buildPolicyTab() {
    final l = context.loc;
    return _tabScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminSectionHeader(
            title: l.tr('screens_admin_system_settings_screen.026'),
            subtitle: l.tr('screens_admin_system_settings_screen.064'),
            icon: Icons.policy_rounded,
          ),
          const SizedBox(height: 16),
          _card(
            Column(
              children: [
                TextField(
                  controller: _policyTitleController,
                  decoration: InputDecoration(
                    labelText: l.tr('screens_admin_system_settings_screen.027'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _policyContentController,
                  minLines: 4,
                  maxLines: 6,
                  decoration: InputDecoration(
                    labelText: l.tr('screens_admin_system_settings_screen.028'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAffiliateTab() {
    return _tabScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminSectionHeader(
            title: context.loc.tr('screens_admin_system_settings_screen.067'),
            subtitle: context.loc.tr(
              'screens_admin_system_settings_screen.068',
            ),
            icon: Icons.campaign_rounded,
          ),
          const SizedBox(height: 16),
          _card(
            Column(
              children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _affiliateEnabled,
                  onChanged: (value) =>
                      setState(() => _affiliateEnabled = value),
                  title: Text(
                    context.loc.tr('screens_admin_system_settings_screen.069'),
                  ),
                  subtitle: Text(
                    context.loc.tr('screens_admin_system_settings_screen.070'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _affiliateRewardAmountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: context.loc.tr(
                      'screens_admin_system_settings_screen.071',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _affiliateFirstTopupMinAmountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: context.loc.tr(
                      'screens_admin_system_settings_screen.072',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _affiliateMarketerDebtLimitController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: context.loc.tr(
                      'screens_admin_system_settings_screen.073',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    context.loc.tr('screens_admin_system_settings_screen.074'),
                    style: AppTheme.caption.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExternalCardStoreTab() {
    return _tabScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AdminSectionHeader(
            title: 'إعدادات متجر البطاقات الخارجية',
            subtitle:
                'تفعيل المتجر، سعر الدولار بالشيكل، نسبة الربح، وربط Ajnadeen API.',
            icon: Icons.storefront_rounded,
          ),
          const SizedBox(height: 16),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _externalStoreEnabled,
                  onChanged: (value) =>
                      setState(() => _externalStoreEnabled = value),
                  title: const Text('تفعيل متجر البطاقات'),
                  subtitle: const Text(
                    'عند التفعيل تظهر شاشة المتجر للحسابات التي تملك الصلاحية.',
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _buildTextField(
                      'رابط API',
                      _externalStoreBaseUrlController,
                      hintText: 'https://ajnec.com',
                    ),
                    _buildTextField(
                      'API Token',
                      _externalStoreApiTokenController,
                      obscureText: true,
                    ),
                    _buildTextField(
                      'Bearer Token اختياري',
                      _externalStoreBearerTokenController,
                      obscureText: true,
                    ),
                    _buildTextField('User', _externalStoreUsernameController),
                    _buildTextField(
                      'Password',
                      _externalStorePasswordController,
                      obscureText: true,
                    ),
                    _buildNumberField(
                      'سعر الدولار بالشيكل',
                      _externalStoreUsdRateController,
                      suffixText: '₪',
                      decimal: true,
                    ),
                    _buildNumberField(
                      'نسبة الربح',
                      _externalStoreProfitController,
                      suffixText: '%',
                      decimal: true,
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text('نسبة الربح حسب نوع الحساب', style: AppTheme.bodyBold),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final row in _externalStoreRoleProfitRows)
                      _buildNumberField(
                        row['label']?.toString() ?? row['role'].toString(),
                        _externalRoleProfitController(
                          row['role']?.toString() ?? '',
                        ),
                        suffixText: '%',
                        decimal: true,
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _card(_buildExternalProviderBalancePanel()),
          const SizedBox(height: 16),
          _card(_buildExternalCatalogControls()),
        ],
      ),
    );
  }

  Widget _buildExternalProviderBalancePanel() {
    final available = _externalProviderBalance['available'] == true;
    final amount = (_externalProviderBalance['amount'] as num?)?.toDouble();
    final checkedAt = _externalProviderBalance['checkedAt']?.toString() ?? '';
    final error = _externalProviderBalance['error']?.toString() ?? '';

    return Row(
      children: [
        Icon(
          available
              ? Icons.account_balance_wallet_rounded
              : Icons.warning_rounded,
          color: available ? AppTheme.success : AppTheme.warning,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('رصيد أجنادين من المصدر', style: AppTheme.bodyBold),
              const SizedBox(height: 4),
              Text(
                available && amount != null
                    ? '\$${amount.toStringAsFixed(4)}'
                    : 'غير متاح حالياً${error.isNotEmpty ? ' - $error' : ''}',
                style: AppTheme.bodyText,
              ),
              if (checkedAt.isNotEmpty)
                Text('آخر فحص: $checkedAt', style: AppTheme.caption),
            ],
          ),
        ),
        OutlinedButton.icon(
          onPressed: _refreshExternalProviderBalance,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('تحديث'),
        ),
      ],
    );
  }

  Widget _buildExternalCatalogControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('تحكم كتالوج العرض السريع', style: AppTheme.h3),
            ),
            OutlinedButton.icon(
              onPressed: _isLoadingExternalCatalog
                  ? null
                  : _loadExternalCatalogControls,
              icon: _isLoadingExternalCatalog
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
              label: const Text('تحديث'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _isSyncingExternalCatalog
                  ? null
                  : _syncExternalCatalog,
              icon: _isSyncingExternalCatalog
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded),
              label: const Text('مزامنة'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _externalStoreCatalogSearchController,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _loadExternalCatalogControls(),
          decoration: InputDecoration(
            hintText: 'بحث عن قسم، بطاقة، أو EAN',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: IconButton(
              tooltip: 'بحث',
              onPressed: _loadExternalCatalogControls,
              icon: const Icon(Icons.manage_search_rounded),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: AppTheme.border),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _catalogSummaryStrip(),
        const SizedBox(height: 16),
        Text('الأقسام', style: AppTheme.bodyBold),
        const SizedBox(height: 8),
        if (_externalCatalogCategories.isEmpty)
          Text('لا توجد أقسام مزامنة بعد.', style: AppTheme.caption)
        else
          ..._externalCatalogCategories
              .take(80)
              .map((item) => _externalCategoryControlTile(item)),
        const SizedBox(height: 16),
        Text('البطاقات', style: AppTheme.bodyBold),
        const SizedBox(height: 8),
        if (_externalCatalogCards.isEmpty)
          Text('لا توجد بطاقات مزامنة بعد.', style: AppTheme.caption)
        else
          ..._externalCatalogCards
              .take(120)
              .map((item) => _externalCardControlTile(item)),
      ],
    );
  }

  Widget _catalogSummaryStrip() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _summaryChip(
          Icons.folder_rounded,
          '${_externalCatalogCategories.length} قسم',
        ),
        _summaryChip(
          Icons.style_rounded,
          '${_externalCatalogCards.length} بطاقة',
        ),
        _summaryChip(
          Icons.visibility_off_rounded,
          '${_externalCatalogCategories.where((e) => e['hidden'] == true).length + _externalCatalogCards.where((e) => e['hidden'] == true).length} مخفي',
        ),
        _summaryChip(
          Icons.block_rounded,
          '${_externalCatalogCards.where((e) => e['forceUnavailable'] == true).length} غير متوفر',
        ),
      ],
    );
  }

  Widget _summaryChip(IconData icon, String label) {
    return Chip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      side: const BorderSide(color: AppTheme.border),
      backgroundColor: AppTheme.surface,
    );
  }

  Widget _externalCategoryControlTile(Map<String, dynamic> item) {
    final id = item['id']?.toString() ?? '';
    final sortOrder = (item['sortOrder'] as num?)?.toInt() ?? 0;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.folder_rounded),
      title: Text(item['title']?.toString() ?? 'قسم'),
      subtitle: Text('ID: $id | ترتيب: $sortOrder'),
      trailing: Wrap(
        spacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          IconButton(
            tooltip: 'تعديل',
            onPressed: id.isEmpty
                ? null
                : () => _editExternalCatalogItem(kind: 'category', item: item),
            icon: const Icon(Icons.edit_rounded),
          ),
          Switch.adaptive(
            value: item['hidden'] == true,
            onChanged: id.isEmpty
                ? null
                : (value) => _updateExternalCatalogItem(
                    kind: 'category',
                    id: id,
                    hidden: value,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _externalCardControlTile(Map<String, dynamic> item) {
    final ean = item['ean']?.toString() ?? '';
    final price = (item['providerPriceUsd'] as num?)?.toDouble() ?? 0;
    final sortOrder = (item['sortOrder'] as num?)?.toInt() ?? 0;
    return Column(
      children: [
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.style_rounded),
          title: Text(item['title']?.toString() ?? 'بطاقة'),
          subtitle: Text(
            'EAN: $ean | \$${price.toStringAsFixed(4)} | ترتيب: $sortOrder',
          ),
          trailing: Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                tooltip: 'تعديل',
                onPressed: ean.isEmpty
                    ? null
                    : () => _editExternalCatalogItem(kind: 'card', item: item),
                icon: const Icon(Icons.edit_rounded),
              ),
              Switch.adaptive(
                value: item['hidden'] == true,
                onChanged: ean.isEmpty
                    ? null
                    : (value) => _updateExternalCatalogItem(
                        kind: 'card',
                        id: ean,
                        hidden: value,
                      ),
              ),
            ],
          ),
        ),
        CheckboxListTile(
          dense: true,
          contentPadding: const EdgeInsetsDirectional.only(start: 48),
          value: item['forceUnavailable'] == true,
          onChanged: ean.isEmpty
              ? null
              : (value) => _updateExternalCatalogItem(
                  kind: 'card',
                  id: ean,
                  forceUnavailable: value ?? false,
                ),
          title: const Text('عرضها كغير متوفرة'),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _buildFeesTab() {
    final l = context.loc;
    return _tabScroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminSectionHeader(
            title: l.tr('screens_admin_system_settings_screen.057'),
            subtitle: l.tr('screens_admin_system_settings_screen.065'),
            icon: Icons.percent_rounded,
          ),
          const SizedBox(height: 16),
          _card(
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _buildFeeField(
                  l.tr('screens_admin_system_settings_screen.029'),
                  _walletTopupFeeController,
                ),
                _buildFeeField(
                  l.tr('screens_admin_system_settings_screen.030'),
                  _walletTransferFeeController,
                ),
                _buildFeeField(
                  l.tr('screens_admin_system_settings_screen.031'),
                  _cardRedeemFeeController,
                ),
                _buildFeeField(
                  l.tr('screens_admin_system_settings_screen.032'),
                  _cardResellFeeController,
                ),
                _buildFeeField(
                  l.tr('screens_admin_system_settings_screen.033'),
                  _cardPrintRequestFeeController,
                ),
                _buildFeeField(
                  'عدد البطاقات في صفحة A4',
                  _cardPrintCardsPerA4PageController,
                ),
                _buildFeeField(
                  'عدد صفحات A4 لكل رسم',
                  _cardPrintPageGroupSizeController,
                ),
                _buildFeeField(
                  'رسم كل مجموعة صفحات',
                  _cardPrintPageGroupFeeController,
                ),
                _buildFeeField('رسوم السحب', _withdrawFeeController),
                _buildFeeField(
                  'رسوم إصدار بطاقة الرصيد (على مُصدر البطاقة)',
                  _standardCardIssueCostController,
                ),
                _buildFeeField(
                  'رسوم إصدار بطاقة التوصيل (على مُصدر البطاقة)',
                  _deliveryCardIssueCostController,
                ),
                _buildFeeField(
                  'رسوم البطاقة الخاصة عند الإنشاء',
                  _privateCardIssueCostController,
                ),
                _buildFeeField(
                  'رسوم إصدار بطاقة خاصة',
                  _singleUseTicketIssueCostController,
                ),
                _buildFeeField(
                  'رسوم إصدار تذكرة موعد',
                  _appointmentTicketIssueCostController,
                ),
                _buildFeeField(
                  'رسوم إصدار تذكرة طابور',
                  _queueTicketIssueCostController,
                ),
                _buildFeeField(
                  'رسوم إصدار بطاقة اشتراك',
                  _subscriptionCardIssueCostController,
                ),
                _buildFeeField(
                  'رسوم إصدار بطاقة حضور وانصراف',
                  _attendanceCardIssueCostController,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.loc.tr('screens_admin_system_settings_screen.169'),
                  style: AppTheme.bodyBold,
                ),
                const SizedBox(height: 8),
                Text(
                  context.loc.tr('screens_admin_system_settings_screen.170'),
                  style: AppTheme.caption.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    _buildNumberField(
                      context.loc.tr(
                        'screens_admin_system_settings_screen.201',
                      ),
                      _scanDefaultLimitController,
                    ),
                    _buildNumberField(
                      context.loc.tr(
                        'screens_admin_system_settings_screen.202',
                      ),
                      _scanRestrictedLimitController,
                    ),
                    _buildNumberField(
                      context.loc.tr(
                        'screens_admin_system_settings_screen.177',
                      ),
                      _scanBasicLimitController,
                    ),
                    _buildNumberField(
                      context.loc.tr(
                        'screens_admin_system_settings_screen.203',
                      ),
                      _scanVerifiedLimitController,
                    ),
                    _buildNumberField(
                      context.loc.tr(
                        'screens_admin_system_settings_screen.179',
                      ),
                      _scanDriverLimitController,
                    ),
                    _buildNumberField(
                      context.loc.tr(
                        'screens_admin_system_settings_screen.180',
                      ),
                      _scanMarketerLimitController,
                    ),
                    _buildNumberField(
                      context.loc.tr(
                        'screens_admin_system_settings_screen.204',
                      ),
                      _scanSupportLimitController,
                    ),
                    _buildNumberField(
                      context.loc.tr(
                        'screens_admin_system_settings_screen.182',
                      ),
                      _scanFinanceLimitController,
                    ),
                    _buildNumberField(
                      context.loc.tr(
                        'screens_admin_system_settings_screen.183',
                      ),
                      _scanAdminLimitController,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    context.loc.tr('screens_admin_system_settings_screen.171'),
                  ),
                  subtitle: Text(
                    context.loc.tr('screens_admin_system_settings_screen.172'),
                  ),
                  value: _scanAutoRedeemGlobalForced,
                  onChanged: (value) =>
                      setState(() => _scanAutoRedeemGlobalForced = value),
                ),
                const SizedBox(height: 16),
                Text('خصم قراءات بدون استخدام', style: AppTheme.bodyBold),
                const SizedBox(height: 8),
                Text(
                  'حدد كل كم قراءة بدون استرداد يتم الخصم، وقيمة الخصم. اترك العدد أو القيمة 0 لتعطيل الخصم.',
                  style: AppTheme.caption.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    _buildNumberField(
                      'عدد القراءات قبل الخصم',
                      _scanWithoutRedeemChargeEveryController,
                    ),
                    _buildFeeField(
                      'قيمة الخصم',
                      _scanWithoutRedeemChargeAmountController,
                      suffixText: '₪',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabScroll({required Widget child}) {
    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(padding: const EdgeInsets.only(bottom: 8), child: child),
      ),
    );
  }

  Widget _buildFeeField(
    String label,
    TextEditingController controller, {
    String suffixText = '%',
  }) {
    return SizedBox(
      width: 190,
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, suffixText: suffixText),
      ),
    );
  }

  Widget _buildNumberField(
    String label,
    TextEditingController controller, {
    String? suffixText,
    bool decimal = false,
  }) {
    return SizedBox(
      width: 220,
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
        decoration: InputDecoration(labelText: label, suffixText: suffixText),
      ),
    );
  }

  Widget _buildTextField(
    String label,
    TextEditingController controller, {
    String? hintText,
    bool obscureText = false,
  }) {
    return SizedBox(
      width: 220,
      child: TextField(
        controller: controller,
        obscureText: obscureText,
        decoration: InputDecoration(labelText: label, hintText: hintText),
      ),
    );
  }
}
