import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/index.dart';
import '../services/index.dart';
import '../utils/app_permissions.dart';
import '../utils/app_theme.dart';
import '../utils/currency_formatter.dart';
import '../utils/user_display_name.dart';
import '../widgets/admin/admin_pagination_footer.dart';
import '../widgets/app_sidebar.dart';
import '../widgets/app_top_actions.dart';
import '../widgets/rejection_reason_dialog.dart';
import '../widgets/responsive_scaffold_container.dart';
import '../widgets/shwakel_card.dart';
import '../widgets/tool_toggle_hint.dart';

class AdminCardPrintRequestsScreen extends StatefulWidget {
  const AdminCardPrintRequestsScreen({super.key});

  @override
  State<AdminCardPrintRequestsScreen> createState() =>
      _AdminCardPrintRequestsScreenState();
}

class _AdminCardPrintRequestsScreenState
    extends State<AdminCardPrintRequestsScreen> {
  final ApiService _apiService = ApiService();
  final AuthService _authService = AuthService();
  final PDFService _pdfService = PDFService();
  final _searchController = TextEditingController();

  List<Map<String, dynamic>> _requests = const [];
  Map<String, dynamic> _summary = const {};
  bool _isLoading = true;
  bool _isBootstrapping = true;
  bool _isAuthorized = false;
  String _status = 'all';
  int _page = 1;
  int _lastPage = 1;
  String? _busyId;
  bool _isRefreshing = false;
  bool _isCreatingRequest = false;
  String? _pendingCreateFingerprint;
  String? _pendingCreateIdempotencyKey;
  static const Uuid _uuid = Uuid();
  Timer? _searchDebounce;
  int _loadRequestId = 0;
  String _lastSubmittedQuery = '';

  String _cardTypeLabel(BuildContext context, String cardType) {
    final l = context.loc;
    return switch (cardType) {
      'single_use' => l.tr('screens_admin_card_print_requests_screen.018'),
      'delivery' => l.tr('shared.delivery_card_label'),
      'appointment' => l.tr('screens_card_print_requests_screen.055'),
      'queue' => l.tr('screens_card_print_requests_screen.056'),
      _ => l.tr('screens_admin_card_print_requests_screen.019'),
    };
  }

  String _cardTypeUsageNote(String cardType) {
    return cardType == 'delivery'
        ? context.loc.tr('shared.delivery_card_payments_note')
        : '';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({bool preserveContent = false}) async {
    final requestId = ++_loadRequestId;
    final shouldKeepVisible = preserveContent && _requests.isNotEmpty;
    setState(() {
      if (shouldKeepVisible) {
        _isRefreshing = true;
      } else {
        _isLoading = true;
      }
    });
    final requestedPage = _page;
    try {
      final cachedUser =
          AuthService.peekCurrentUser() ?? await _authService.currentUser();
      final cachedPermissions = AppPermissions.fromUser(cachedUser);
      if (!cachedPermissions.canManageCardPrintRequests) {
        if (!mounted) {
          return;
        }
        setState(() {
          _isAuthorized = false;
          _isLoading = false;
          _isBootstrapping = false;
        });
        return;
      }
      if (mounted) {
        setState(() {
          _isAuthorized = true;
          _isBootstrapping = false;
        });
      }
      final results = await Future.wait([
        _apiService.getCardPrintRequests(
          status: _status,
          query: _searchController.text.trim(),
          page: requestedPage,
        ),
        _refreshAndReadCurrentUser(),
      ]);
      final payload = Map<String, dynamic>.from(results[0] as Map);
      final currentUser = results[1];
      final permissions = AppPermissions.fromUser(currentUser);
      if (!permissions.canManageCardPrintRequests) {
        if (!mounted) {
          return;
        }
        setState(() {
          _isAuthorized = false;
          _isLoading = false;
          _isBootstrapping = false;
          _isRefreshing = false;
        });
        return;
      }
      final pagination = Map<String, dynamic>.from(
        payload['pagination'] as Map? ?? const {},
      );
      final requests = List<Map<String, dynamic>>.from(
        payload['requests'] as List? ?? const [],
      );
      final lastPage = (pagination['lastPage'] as num?)?.toInt() ?? 1;
      final currentPage = (pagination['currentPage'] as num?)?.toInt() ?? 1;
      final normalizedPage = currentPage.clamp(1, lastPage);
      if (requestedPage > lastPage && lastPage > 0) {
        if (!mounted) {
          return;
        }
        setState(() => _page = lastPage);
        await _load();
        return;
      }
      if (!mounted || requestId != _loadRequestId) {
        return;
      }
      setState(() {
        _isAuthorized = true;
        _requests = requests;
        _summary = Map<String, dynamic>.from(
          payload['summary'] as Map? ?? const {},
        );
        _page = normalizedPage;
        _lastPage = lastPage;
        _isLoading = false;
        _isBootstrapping = false;
        _isRefreshing = false;
      });
    } catch (error) {
      if (!mounted || requestId != _loadRequestId) {
        return;
      }
      setState(() {
        _isLoading = false;
        _isBootstrapping = false;
        _isRefreshing = false;
      });
      await AppAlertService.showError(
        context,
        title: context.loc.tr(
          'screens_admin_card_print_requests_screen.load_error_title',
        ),
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  Future<Map<String, dynamic>?> _refreshAndReadCurrentUser() async {
    try {
      await _authService.tryRefreshCurrentUser();
    } catch (_) {}
    return _authService.currentUser();
  }

  Future<void> _handleAction(
    Map<String, dynamic> request,
    String action,
  ) async {
    String? rejectionReason;
    if (action == 'reject') {
      rejectionReason = await showRejectionReasonDialog(
        context,
        title: context.loc.tr('shared.rejection_reason_label'),
        confirmText: context.loc.tr('shared.confirm_rejection'),
      );
      if (rejectionReason == null) {
        return;
      }
    }

    setState(() => _busyId = request['id']?.toString());
    try {
      switch (action) {
        case 'approve':
          await _apiService.approveCardPrintRequest(request['id'].toString());
          break;
        case 'start':
          await _apiService.startCardPrintRequest(request['id'].toString());
          break;
        case 'ready':
          await _apiService.readyCardPrintRequest(request['id'].toString());
          break;
        case 'complete':
          await _apiService.completeCardPrintRequest(request['id'].toString());
          break;
        case 'reject':
          await _apiService.rejectCardPrintRequest(
            request['id'].toString(),
            notes: rejectionReason ?? '',
          );
          break;
      }
      await _load();
    } catch (error) {
      if (mounted) {
        await AppAlertService.showError(
          context,
          title: context.loc.tr(
            'screens_admin_card_print_requests_screen.update_error_title',
          ),
          message: ErrorMessageService.sanitize(error),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busyId = null);
      }
    }
  }

  List<VirtualCard> _extractCardsFromRequest(Map<String, dynamic> request) {
    const candidateKeys = [
      'cards',
      'issuedCards',
      'printableCards',
      'generatedCards',
      'preparedCards',
      'cardsSnapshot',
    ];

    for (final key in candidateKeys) {
      final raw = request[key];
      if (raw is! List || raw.isEmpty) {
        continue;
      }
      return raw
          .whereType<Map>()
          .map((item) => _cardFromAny(Map<String, dynamic>.from(item)))
          .where((card) => card.barcode.trim().isNotEmpty)
          .toList();
    }
    return const [];
  }

  VirtualCard _cardFromAny(Map<String, dynamic> item) {
    final normalized = <String, dynamic>{
      'id': item['id'],
      'barcode': item['barcode'],
      'value': item['value'],
      'card_type': item['card_type'] ?? item['cardType'],
      'original_card_type':
          item['original_card_type'] ?? item['originalCardType'],
      'visibility_scope': item['visibility_scope'] ?? item['visibilityScope'],
      'issue_cost': item['issue_cost'] ?? item['issueCost'],
      'owner_id': item['owner_id'] ?? item['ownerId'],
      'owner_username': item['owner_username'] ?? item['ownerUsername'],
      'issued_by_id': item['issued_by_id'] ?? item['issuedById'],
      'issued_by_username':
          item['issued_by_username'] ?? item['issuedByUsername'],
      'redeemed_by_id': item['redeemed_by_id'] ?? item['redeemedById'],
      'allowed_user_ids':
          item['allowed_user_ids'] ?? item['allowedUserIds'] ?? const [],
      'allowed_usernames':
          item['allowed_usernames'] ?? item['allowedUsernames'] ?? const [],
      'allowed_phone_numbers':
          item['allowed_phone_numbers'] ??
          item['allowedPhoneNumbers'] ??
          const [],
      'customer_name': item['customer_name'] ?? item['customerName'],
      'created_at': item['created_at'] ?? item['issuedAt'] ?? item['createdAt'],
      'valid_from': item['valid_from'] ?? item['validFrom'],
      'valid_until': item['valid_until'] ?? item['validUntil'],
      'details': item['details'] ?? item['card_details'] ?? item['cardDetails'],
      'last_resold_at': item['last_resold_at'] ?? item['lastResoldAt'],
      'use_count': item['use_count'] ?? item['useCount'],
      'resale_count': item['resale_count'] ?? item['resaleCount'],
      'total_redeemed_value':
          item['total_redeemed_value'] ?? item['totalRedeemedValue'],
      'status': item['status'],
      'used_at': item['used_at'] ?? item['redeemedAt'],
      'used_by': item['used_by'] ?? item['redeemedByUsername'],
      'sold_price': item['sold_price'],
    };
    return VirtualCard.fromMap(normalized);
  }

  CardDesignSettings _settingsFromRequest(Map<String, dynamic> request) {
    final printDesign = Map<String, dynamic>.from(
      request['printDesign'] as Map? ??
          request['print_design'] as Map? ??
          const {},
    );
    final title =
        (printDesign['logoText']?.toString().trim().isNotEmpty == true)
        ? printDesign['logoText'].toString().trim()
        : UserDisplayName.fromMap(
            request,
            fallback: context.loc.tr('main.001'),
          );
    final settings = CardDesignSettings(
      showLogo: true,
      showStamp: printDesign['showStamp'] is bool
          ? printDesign['showStamp'] as bool
          : true,
      logoText: title,
      stampText: printDesign['stampText']?.toString(),
      valueUnitText: printDesign['valueUnitText']?.toString(),
    );
    final logoUrl = printDesign['logoUrl']?.toString().trim().isNotEmpty == true
        ? printDesign['logoUrl'].toString().trim()
        : request['printLogoUrl']?.toString().trim() ?? '';
    settings.logoUrl = logoUrl.isEmpty ? null : logoUrl;
    return settings;
  }

  Future<bool> _confirmCardOutputSecurity() async {
    final security = await TransferSecurityService.confirmTransfer(context);
    return mounted && security.isVerified;
  }

  Future<void> _exportRequestPdf(Map<String, dynamic> request) async {
    final l = context.loc;
    final cards = _extractCardsFromRequest(request);
    if (cards.isEmpty) {
      await AppAlertService.showInfo(
        context,
        title: l.tr(
          'screens_admin_card_print_requests_screen.file_unavailable_title',
        ),
        message: l.tr(
          'screens_admin_card_print_requests_screen.export_unavailable_message',
        ),
      );
      return;
    }

    if (!await _confirmCardOutputSecurity()) {
      return;
    }

    try {
      final currentUser = await _authService.currentUser();
      final printedBy = UserDisplayName.fromMap(currentUser);
      _pdfService.setDesignSettings(_settingsFromRequest(request));
      final pdf = await _pdfService.createMultiCardPDF(
        cards,
        printedBy: printedBy,
      );
      final requestId =
          request['id']?.toString() ??
          DateTime.now().millisecondsSinceEpoch.toString();
      final file = await _pdfService.savePDF(
        pdf,
        'card_print_request_$requestId',
      );
      if (!mounted) {
        return;
      }
      await AppAlertService.showSuccess(
        context,
        title: l.tr(
          'screens_admin_card_print_requests_screen.pdf_generated_title',
        ),
        message: l.tr(
          'screens_admin_card_print_requests_screen.pdf_generated_message',
          params: {'path': file.path},
        ),
      );
      final requestIdValue = request['id']?.toString();
      if (requestIdValue != null && requestIdValue.isNotEmpty) {
        try {
          await _apiService.markCardPrintRequestPrinted(requestIdValue);
          await _load();
        } catch (_) {}
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      await AppAlertService.showError(
        context,
        title: l.tr(
          'screens_admin_card_print_requests_screen.pdf_failed_title',
        ),
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  Future<void> _printRequestCards(Map<String, dynamic> request) async {
    final l = context.loc;
    final cards = _extractCardsFromRequest(request);
    if (cards.isEmpty) {
      await AppAlertService.showInfo(
        context,
        title: l.tr(
          'screens_admin_card_print_requests_screen.file_unavailable_title',
        ),
        message: l.tr(
          'screens_admin_card_print_requests_screen.print_unavailable_message',
        ),
      );
      return;
    }

    if (!await _confirmCardOutputSecurity()) {
      return;
    }

    try {
      final currentUser = await _authService.currentUser();
      final printedBy = UserDisplayName.fromMap(currentUser);
      _pdfService.setDesignSettings(_settingsFromRequest(request));
      await _pdfService.printCards(cards, printedBy: printedBy);
      final requestId = request['id']?.toString();
      if (requestId != null && requestId.isNotEmpty) {
        try {
          await _apiService.markCardPrintRequestPrinted(requestId);
          await _load();
        } catch (_) {}
      }
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

  Future<void> _showCreateAdminRequestDialog() async {
    if (_isCreatingRequest) {
      return;
    }
    final l = context.loc;
    final valueController = TextEditingController(text: '0');
    final quantityController = TextEditingController(text: '35');
    final notesController = TextEditingController();
    final ownerSearchController = TextEditingController();
    final chargeSearchController = TextEditingController();
    Map<String, dynamic>? selectedOwner;
    Map<String, dynamic>? selectedChargeUser;
    List<Map<String, dynamic>> ownerResults = const [];
    List<Map<String, dynamic>> chargeResults = const [];
    bool searchingOwner = false;
    bool searchingCharge = false;
    String cardType = 'standard';

    Future<void> searchUsers(
      StateSetter setDialogState,
      String query,
      bool chargeSearch,
    ) async {
      setDialogState(() {
        if (chargeSearch) {
          searchingCharge = true;
        } else {
          searchingOwner = true;
        }
      });
      try {
        final results = await _apiService.searchUsers(query);
        setDialogState(() {
          if (chargeSearch) {
            chargeResults = results;
          } else {
            ownerResults = results;
          }
        });
      } catch (_) {
        setDialogState(() {
          if (chargeSearch) {
            chargeResults = const [];
          } else {
            ownerResults = const [];
          }
        });
      } finally {
        setDialogState(() {
          if (chargeSearch) {
            searchingCharge = false;
          } else {
            searchingOwner = false;
          }
        });
      }
    }

    Widget userSearchBox({
      required StateSetter setDialogState,
      required TextEditingController controller,
      required String label,
      required String helper,
      required Map<String, dynamic>? selected,
      required List<Map<String, dynamic>> results,
      required bool loading,
      required bool chargeSearch,
    }) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            decoration: InputDecoration(
              labelText: label,
              helperText: helper,
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: loading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
            onChanged: (value) => unawaited(
              searchUsers(setDialogState, value.trim(), chargeSearch),
            ),
          ),
          if (selected != null) ...[
            const SizedBox(height: 8),
            Chip(
              avatar: const Icon(Icons.account_circle_rounded),
              label: Text(UserDisplayName.fromMap(selected)),
              onDeleted: () {
                setDialogState(() {
                  if (chargeSearch) {
                    selectedChargeUser = null;
                  } else {
                    selectedOwner = null;
                  }
                });
              },
            ),
          ],
          if (results.isNotEmpty) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 150),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: results.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final user = results[index];
                  return ListTile(
                    dense: true,
                    title: Text(UserDisplayName.fromMap(user)),
                    subtitle: Text(user['whatsapp']?.toString() ?? ''),
                    onTap: () {
                      setDialogState(() {
                        if (chargeSearch) {
                          selectedChargeUser = user;
                          chargeResults = const [];
                          chargeSearchController.clear();
                        } else {
                          selectedOwner = user;
                          selectedChargeUser ??= user;
                          ownerResults = const [];
                          ownerSearchController.clear();
                        }
                      });
                    },
                  );
                },
              ),
            ),
          ],
        ],
      );
    }

    final submitted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            l.text('إنشاء طلب طباعة إداري', 'Create Admin Print Request'),
          ),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  userSearchBox(
                    setDialogState: setDialogState,
                    controller: ownerSearchController,
                    label: l.text('صاحب البطاقات', 'Card owner'),
                    helper: l.text(
                      'ابحث عن الحساب الذي ستصدر له البطاقات.',
                      'Search for the account that will own the cards.',
                    ),
                    selected: selectedOwner,
                    results: ownerResults,
                    loading: searchingOwner,
                    chargeSearch: false,
                  ),
                  const SizedBox(height: 14),
                  userSearchBox(
                    setDialogState: setDialogState,
                    controller: chargeSearchController,
                    label: l.text(
                      'حساب خصم رسوم الطباعة',
                      'Printing fee payer',
                    ),
                    helper: l.text(
                      'يمكن خصم رسوم الطباعة من هذا الحساب حتى لو أصبح رصيده بالسالب.',
                      'Printing fees can be deducted from this account even if its balance becomes negative.',
                    ),
                    selected: selectedChargeUser,
                    results: chargeResults,
                    loading: searchingCharge,
                    chargeSearch: true,
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: cardType,
                    decoration: InputDecoration(
                      labelText: l.text('نوع البطاقة', 'Card type'),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'standard',
                        child: Text(l.text('بطاقة رصيد', 'Balance card')),
                      ),
                      DropdownMenuItem(
                        value: 'delivery',
                        child: Text(l.tr('shared.delivery_card_label')),
                      ),
                      DropdownMenuItem(
                        value: 'single_use',
                        child: Text(l.text('بطاقة خاصة', 'Private card')),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => cardType = value);
                      }
                    },
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: valueController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: l.text('قيمة البطاقة', 'Card value'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: quantityController,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: l.text('عدد البطاقات', 'Card count'),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: notesController,
                    minLines: 2,
                    maxLines: 4,
                    decoration: InputDecoration(
                      labelText: l.text('ملاحظات', 'Notes'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l.tr('screens_card_print_requests_screen.015')),
            ),
            FilledButton.icon(
              onPressed: selectedOwner == null
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.print_rounded),
              label: Text(l.text('إنشاء الطلب', 'Create request')),
            ),
          ],
        ),
      ),
    );

    final owner = selectedOwner;
    final chargeUser = selectedChargeUser ?? selectedOwner;
    final value = double.tryParse(valueController.text.trim()) ?? 0;
    final quantity = int.tryParse(quantityController.text.trim()) ?? 35;
    final notes = notesController.text;
    valueController.dispose();
    quantityController.dispose();
    notesController.dispose();
    ownerSearchController.dispose();
    chargeSearchController.dispose();
    if (submitted != true || owner == null) {
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

    final fingerprint = jsonEncode({
      'userId': owner['id']?.toString() ?? '',
      'chargeUserId': chargeUser?['id']?.toString() ?? '',
      'value': value,
      'quantity': quantity,
      'cardType': cardType,
      'notes': notes.trim(),
    });
    if (_pendingCreateFingerprint != fingerprint) {
      _pendingCreateFingerprint = fingerprint;
      _pendingCreateIdempotencyKey = _uuid.v4();
    }

    try {
      setState(() {
        _isCreatingRequest = true;
        _isRefreshing = true;
      });
      await _apiService.createAdminCardPrintRequest(
        idempotencyKey: _pendingCreateIdempotencyKey!,
        userId: owner['id'].toString(),
        chargeUserId: chargeUser?['id']?.toString(),
        value: value,
        quantity: quantity,
        cardType: cardType,
        notes: notes,
        otpCode: security.otpCode,
        securityPin: security.securityPin,
      );
      _pendingCreateFingerprint = null;
      _pendingCreateIdempotencyKey = null;
      await _load(preserveContent: true);
      if (!mounted) return;
      await AppAlertService.showSuccess(
        context,
        message: l.text('تم إنشاء طلب الطباعة.', 'Print request created.'),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _isRefreshing = false);
      await AppAlertService.showError(
        context,
        message: ErrorMessageService.sanitize(error),
      );
    } finally {
      if (mounted) {
        setState(() => _isCreatingRequest = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.loc;
    if (_isBootstrapping) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_isAuthorized) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          title: Text(l.tr('screens_admin_card_print_requests_screen.001')),
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
                  l.tr('screens_admin_card_print_requests_screen.037'),
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
        title: Text(l.tr('screens_admin_card_print_requests_screen.001')),
        actions: [
          IconButton(
            tooltip: context.loc.tr(
              'screens_admin_card_print_requests_screen.040',
            ),
            onPressed: _showHelpDialog,
            icon: const Icon(Icons.info_outline_rounded),
          ),
          const AppNotificationAction(),
          const QuickLogoutAction(),
        ],
      ),
      drawer: AppSidebar.drawerFor(context),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ResponsiveScaffoldContainer(
          padding: const EdgeInsets.all(AppTheme.spacingLg),
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: _isLoading || _requests.isEmpty
                ? 4
                : _requests.length + 4,
            separatorBuilder: (context, index) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              if (index == 0) {
                return _buildOverviewCard();
              }
              if (index == 1) {
                return _buildFiltersCard();
              }
              if (index == 2) {
                return _isRefreshing
                    ? const LinearProgressIndicator(minHeight: 3)
                    : const SizedBox.shrink();
              }
              if (_isLoading) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: CircularProgressIndicator(),
                  ),
                );
              }
              if (_requests.isEmpty) {
                if (index != 3) {
                  return const SizedBox.shrink();
                }
                return ShwakelCard(
                  padding: const EdgeInsets.all(28),
                  child: Center(
                    child: Text(
                      l.tr(
                        'screens_admin_card_print_requests_screen.empty_state',
                      ),
                      style: AppTheme.bodyAction,
                    ),
                  ),
                );
              }
              final requestIndex = index - 3;
              if (requestIndex < _requests.length) {
                return _buildRequestCard(_requests[requestIndex]);
              }
              return AdminPaginationFooter(
                currentPage: _page,
                lastPage: _lastPage,
                onPageChanged: (page) {
                  setState(() => _page = page);
                  _load();
                },
              );
            },
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isLoading || _isCreatingRequest
            ? null
            : () => unawaited(_showCreateAdminRequestDialog()),
        icon: const Icon(Icons.add_rounded),
        label: Text(l.text('طلب طباعة', 'Print request')),
      ),
    );
  }

  Widget _buildOverviewCard() {
    return ShwakelCard(
      padding: const EdgeInsets.all(20),
      borderRadius: BorderRadius.circular(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.print_rounded, color: AppTheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  context.loc.tr(
                    'screens_admin_card_print_requests_screen.001',
                  ),
                  style: AppTheme.bodyBold,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${_requests.length}',
                  style: AppTheme.bodyBold.copyWith(color: AppTheme.primary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            context.loc.tr(
              'screens_admin_card_print_requests_screen.041',
              params: {
                'review':
                    '${(_summary['pendingReviewCount'] as num?)?.toInt() ?? 0}',
                'approved':
                    '${(_summary['approvedCount'] as num?)?.toInt() ?? 0}',
                'completed':
                    '${(_summary['completedCount'] as num?)?.toInt() ?? 0}',
              },
            ),
            style: AppTheme.bodyAction.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          ToolToggleHint(
            message: context.loc.tr(
              'screens_admin_card_print_requests_screen.042',
            ),
            icon: Icons.filter_alt_rounded,
          ),
        ],
      ),
    );
  }

  Widget _buildFiltersCard() {
    final l = context.loc;
    return ShwakelCard(
      padding: const EdgeInsets.all(20),
      borderRadius: BorderRadius.circular(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.loc.tr('screens_admin_card_print_requests_screen.039'),
            style: AppTheme.h2,
          ),
          const SizedBox(height: 8),
          Text(
            context.loc.tr('screens_admin_card_print_requests_screen.042'),
            style: AppTheme.bodyAction.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked = constraints.maxWidth < 760;
              final searchField = TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  labelText: l.tr(
                    'screens_admin_card_print_requests_screen.search_label',
                  ),
                  prefixIcon: const Icon(Icons.search_rounded),
                ),
                onChanged: (_) {
                  _searchDebounce?.cancel();
                  _searchDebounce = Timer(
                    const Duration(milliseconds: 550),
                    () {
                      if (!mounted) {
                        return;
                      }
                      _submitSearch();
                    },
                  );
                },
                onSubmitted: (_) {
                  _page = 1;
                  _submitSearch(force: true);
                },
              );
              final filterField = DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: InputDecoration(
                  labelText: l.tr(
                    'screens_admin_card_print_requests_screen.003',
                  ),
                ),
                items: [
                  DropdownMenuItem(
                    value: 'all',
                    child: Text(
                      l.tr('screens_admin_card_print_requests_screen.004'),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'pending_review',
                    child: Text(
                      l.tr('screens_admin_card_print_requests_screen.005'),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'approved',
                    child: Text(
                      l.tr('screens_admin_card_print_requests_screen.006'),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'printing',
                    child: Text(
                      l.tr('screens_admin_card_print_requests_screen.007'),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'ready',
                    child: Text(
                      l.tr('screens_admin_card_print_requests_screen.008'),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'completed',
                    child: Text(
                      l.tr('screens_admin_card_print_requests_screen.009'),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'rejected',
                    child: Text(
                      l.tr('screens_admin_card_print_requests_screen.010'),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'archive',
                    child: Text(
                      l.tr('screens_admin_card_print_requests_screen.029'),
                    ),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    _status = value;
                    _page = 1;
                  });
                  _load(preserveContent: true);
                },
              );

              if (stacked) {
                return Column(
                  children: [
                    searchField,
                    const SizedBox(height: 12),
                    filterField,
                  ],
                );
              }

              return Column(
                children: [
                  searchField,
                  const SizedBox(height: 12),
                  filterField,
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildRequestCard(Map<String, dynamic> request) {
    final l = context.loc;
    final status = request['status']?.toString() ?? 'pending_review';
    final busy = _busyId == request['id']?.toString();
    final cardsReady = _extractCardsFromRequest(request).isNotEmpty;

    final chargedIssueCostAmount =
        (request['chargedIssueCostAmount'] as num?)?.toDouble() ?? 0;
    final deferredIssueCostAmount =
        (request['deferredIssueCostAmount'] as num?)?.toDouble() ?? 0;
    final printCount = (request['printCount'] as num?)?.toInt() ?? 0;
    final totalAmount = CurrencyFormatter.ils(
      (request['totalAmount'] as num?)?.toDouble() ?? 0,
    );
    final hasFees = chargedIssueCostAmount > 0 || deferredIssueCostAmount > 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: ShwakelCard(
        padding: const EdgeInsets.all(20),
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
                        UserDisplayName.fromMap(
                          request,
                          fallback: l.tr(
                            'screens_admin_card_print_requests_screen.015',
                          ),
                        ),
                        style: AppTheme.h3,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        request['whatsapp']?.toString() ?? '',
                        style: AppTheme.caption,
                      ),
                    ],
                  ),
                ),
                _statusChip(request['statusLabel']?.toString() ?? status),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _infoChip(
                  Icons.credit_card_rounded,
                  _cardTypeLabel(
                    context,
                    request['cardType']?.toString() ?? 'standard',
                  ),
                ),
                _infoChip(
                  Icons.layers_rounded,
                  l.tr(
                    'screens_admin_card_print_requests_screen.quantity_label',
                    params: {'count': '${request['quantity'] ?? 0}'},
                  ),
                ),
                _infoChip(Icons.account_balance_wallet_rounded, totalAmount),
                if (hasFees)
                  _infoChip(
                    Icons.receipt_long_rounded,
                    l.tr('screens_admin_card_print_requests_screen.046'),
                  ),
                _infoChip(
                  Icons.print_rounded,
                  printCount > 0
                      ? l.tr(
                          'screens_admin_card_print_requests_screen.047',
                          params: {'count': '$printCount'},
                        )
                      : l.tr('screens_admin_card_print_requests_screen.048'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _metaItem(
                  l.tr('screens_admin_card_print_requests_screen.016'),
                  request['id']?.toString() ?? '-',
                ),
                _metaItem(
                  l.tr('screens_admin_card_print_requests_screen.017'),
                  _cardTypeLabel(
                    context,
                    request['cardType']?.toString() ?? 'standard',
                  ),
                ),
                if ((request['cardType']?.toString() ?? '') == 'delivery')
                  _metaItem(
                    l.tr('shared.usage_label'),
                    _cardTypeUsageNote(
                      request['cardType']?.toString() ?? 'standard',
                    ),
                  ),
                _metaItem(
                  l.tr('screens_admin_card_print_requests_screen.020'),
                  l.tr(
                    'screens_admin_card_print_requests_screen.quantity_label',
                    params: {'count': '${request['quantity'] ?? 0}'},
                  ),
                ),
                _metaItem(
                  l.tr('screens_admin_card_print_requests_screen.021'),
                  CurrencyFormatter.ils(
                    (request['cardValue'] as num?)?.toDouble() ?? 0,
                  ),
                ),
                if (chargedIssueCostAmount > 0)
                  _metaItem(
                    l.tr('screens_admin_card_print_requests_screen.049'),
                    CurrencyFormatter.ils(chargedIssueCostAmount),
                  ),
                if (deferredIssueCostAmount > 0)
                  _metaItem(
                    l.tr('screens_admin_card_print_requests_screen.050'),
                    CurrencyFormatter.ils(deferredIssueCostAmount),
                  ),
                if (((request['feeAmount'] as num?)?.toDouble() ?? 0) > 0)
                  _metaItem(
                    l.tr('screens_admin_card_print_requests_screen.051'),
                    CurrencyFormatter.ils(
                      (request['feeAmount'] as num?)?.toDouble() ?? 0,
                    ),
                  ),
                _metaItem(
                  l.tr('screens_admin_card_print_requests_screen.022'),
                  totalAmount,
                ),
                _metaItem(
                  l.tr('screens_admin_card_print_requests_screen.031'),
                  _sourceLabel(request['sourceType']?.toString() ?? 'app'),
                ),
                _metaItem(
                  l.tr('screens_admin_card_print_requests_screen.032'),
                  '${request['printCount'] ?? 0}',
                ),
                _metaItem(
                  l.tr('screens_admin_card_print_requests_screen.033'),
                  _formatDateTime(request['lastPrintedAt']?.toString()),
                ),
              ],
            ),
            if ((request['customerNotes']?.toString().trim().isNotEmpty ??
                false))
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  l.tr(
                    'screens_admin_card_print_requests_screen.customer_notes',
                    params: {'notes': request['customerNotes'].toString()},
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: busy || !cardsReady
                      ? null
                      : () => _printRequestCards(request),
                  icon: const Icon(Icons.print_rounded),
                  label: Text(
                    l.tr('screens_admin_card_print_requests_screen.print_now'),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: busy || !cardsReady
                      ? null
                      : () => _exportRequestPdf(request),
                  icon: const Icon(Icons.picture_as_pdf_rounded),
                  label: Text(
                    l.tr('screens_admin_card_print_requests_screen.export_pdf'),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => _showOverrideStatusDialog(request),
                  icon: const Icon(Icons.edit_rounded),
                  label: Text(
                    l.tr('screens_admin_card_print_requests_screen.052'),
                  ),
                ),
                if (status == 'pending_review')
                  _actionButton(
                    l.tr('screens_admin_card_print_requests_screen.023'),
                    busy,
                    () => _handleAction(request, 'approve'),
                  ),
                if (status == 'pending_review')
                  _actionButton(
                    l.tr('screens_admin_card_print_requests_screen.024'),
                    busy,
                    () => _handleAction(request, 'reject'),
                  ),
                if (!cardsReady &&
                    (status == 'approved' ||
                        status == 'printing' ||
                        status == 'ready'))
                  _actionButton(
                    l.tr('screens_admin_card_print_requests_screen.027'),
                    busy,
                    () => _handleAction(request, 'complete'),
                  ),
                if (!cardsReady && status == 'pending_review')
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      l.tr(
                        'screens_admin_card_print_requests_screen.prepare_after_approval_hint',
                      ),
                      style: AppTheme.bodyText.copyWith(
                        fontSize: 13,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showOverrideStatusDialog(Map<String, dynamic> request) async {
    final currentStatus = request['status']?.toString() ?? 'pending_review';
    final l = context.loc;
    final controller = TextEditingController();
    String selected = currentStatus;
    final result = await showDialog<Map<String, String>?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.tr('screens_admin_card_print_requests_screen.053')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: selected,
                decoration: InputDecoration(
                  labelText: l.tr(
                    'screens_admin_card_print_requests_screen.054',
                  ),
                ),
                items: [
                  DropdownMenuItem(
                    value: 'pending_review',
                    child: Text(
                      l.tr('screens_admin_card_print_requests_screen.005'),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'approved',
                    child: Text(
                      l.tr('screens_admin_card_print_requests_screen.006'),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'printing',
                    child: Text(
                      l.tr('screens_admin_card_print_requests_screen.007'),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'ready',
                    child: Text(
                      l.tr('screens_admin_card_print_requests_screen.008'),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'completed',
                    child: Text(
                      l.tr('screens_admin_card_print_requests_screen.009'),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'rejected',
                    child: Text(
                      l.tr('screens_admin_card_print_requests_screen.010'),
                    ),
                  ),
                ],
                onChanged: (value) => selected = value ?? selected,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: l.tr(
                    'screens_admin_card_print_requests_screen.055',
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l.tr('screens_card_print_requests_screen.015')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, {
              'status': selected,
              'notes': controller.text,
            }),
            child: Text(l.tr('screens_admin_card_print_requests_screen.056')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;

    try {
      setState(() => _busyId = request['id']?.toString());
      final res = await _apiService.overrideCardPrintRequestStatus(
        request['id']?.toString() ?? '',
        status: result['status'] ?? currentStatus,
        notes: result['notes'] ?? '',
      );
      final updated = res['request'];
      if (updated is Map) {
        final updatedMap = Map<String, dynamic>.from(updated);
        setState(() {
          _requests = _requests
              .map(
                (item) =>
                    (item['id']?.toString() == updatedMap['id']?.toString())
                    ? updatedMap
                    : item,
              )
              .toList();
          _busyId = null;
        });
      } else {
        setState(() => _busyId = null);
      }
      if (!mounted) return;
      AppAlertService.showSuccess(
        context,
        message:
            res['message']?.toString() ??
            l.tr('screens_admin_card_print_requests_screen.057'),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyId = null);
      AppAlertService.showError(
        context,
        message: ErrorMessageService.sanitize(e),
      );
    }
  }

  Widget _actionButton(String label, bool busy, VoidCallback onPressed) {
    final l = context.loc;
    return ElevatedButton(
      onPressed: busy ? null : onPressed,
      child: Text(
        busy ? l.tr('screens_admin_card_print_requests_screen.028') : label,
      ),
    );
  }

  Future<void> _showHelpDialog() {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          context.loc.tr('screens_admin_card_print_requests_screen.043'),
        ),
        content: Text(
          context.loc.tr('screens_admin_card_print_requests_screen.044'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(
              context.loc.tr('screens_admin_card_print_requests_screen.045'),
            ),
          ),
        ],
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

  Widget _infoChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppTheme.surfaceVariant,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: AppTheme.primary),
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

  String _sourceLabel(String source) {
    final l = context.loc;
    return source == 'local'
        ? l.tr('screens_admin_card_print_requests_screen.034')
        : l.tr('screens_admin_card_print_requests_screen.035');
  }

  String _formatDateTime(String? value) {
    if (value == null || value.trim().isEmpty) {
      return context.loc.tr('screens_admin_card_print_requests_screen.036');
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

  Widget _statusChip(String status) {
    final color = switch (status) {
      'approved' => AppTheme.primary,
      'printing' => AppTheme.warning,
      'ready' => AppTheme.success,
      'completed' => AppTheme.success,
      'rejected' => AppTheme.error,
      _ => AppTheme.textSecondary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status == 'pending_review'
            ? context.loc.tr(
                'screens_admin_card_print_requests_screen.pending_status',
              )
            : status,
        style: AppTheme.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  void _submitSearch({bool force = false}) {
    final query = _searchController.text.trim();
    if (!force && query == _lastSubmittedQuery) {
      return;
    }
    _lastSubmittedQuery = query;
    setState(() => _page = 1);
    _load(preserveContent: true);
  }
}
