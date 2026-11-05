import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:excel_community/excel_community.dart' hide Border;
import 'package:uuid/uuid.dart';

import '../services/index.dart';
import '../services/cashier_sound.dart';
import '../utils/app_permissions.dart';
import '../utils/store_management_privacy.dart';
import '../utils/store_invoice_import_matching.dart';
import '../utils/store_import_header_normalizer.dart';
import '../utils/store_csv_delimiter_detection.dart';
import '../utils/store_spreadsheet_header_detection.dart';
import '../utils/store_spreadsheet_text_decoder.dart';
import '../utils/app_theme.dart';
import '../widgets/app_sidebar.dart';
import '../widgets/app_top_actions.dart';
import '../widgets/barcode_scanner_dialog.dart';
import '../widgets/responsive_scaffold_container.dart';
import '../widgets/shwakel_card.dart';

typedef _SpreadsheetSheetData = ({
  List<String> headers,
  List<List<String>> rows,
});
typedef _SpreadsheetImportData = ({
  List<String> headers,
  List<List<String>> rows,
  Map<String, _SpreadsheetSheetData> sheets,
});

class StoreManagementScreen extends StatefulWidget {
  const StoreManagementScreen({super.key});

  @override
  State<StoreManagementScreen> createState() => _StoreManagementScreenState();
}

class _StoreManagementScreenState extends State<StoreManagementScreen>
    with SingleTickerProviderStateMixin {
  final _api = ApiService();
  final _auth = AuthService();
  final _store = StoreManagementService();
  final TextEditingController _productSearchController =
      TextEditingController();
  final TextEditingController _partySearchController = TextEditingController();
  final FocusNode _productSearchFocusNode = FocusNode(
    debugLabel: 'storeInventorySearch',
  );
  final FocusNode _partySearchFocusNode = FocusNode(
    debugLabel: 'storeAccountsSearch',
  );
  late final TabController _tabs = TabController(length: 6, vsync: this)
    ..addListener(() => setState(() {}));
  Map<String, dynamic>? _user;
  Map<String, dynamic> _snapshot = const {};
  List<Map<String, dynamic>> _publicOrders = const [];
  List<Map<String, dynamic>> _pending = const [];
  bool _loading = true;
  bool _syncing = false;
  bool _creatingInvoice = false;
  String? _stockAlertFilter;
  String? _error;
  String _productSearchQuery = '';
  String _partySearchQuery = '';

  AppPermissions get _permissions => AppPermissions.fromUser(_user);
  String get _userId => _user?['id']?.toString() ?? '';
  String get _actorName =>
      _user?['fullName']?.toString().trim().isNotEmpty == true
      ? _user!['fullName'].toString()
      : _user?['name']?.toString().trim().isNotEmpty == true
      ? _user!['name'].toString()
      : _user?['username']?.toString() ?? '';
  List<Map<String, dynamic>> get _products => _list(_snapshot['products']);
  List<Map<String, dynamic>> get _warehouses => _list(_snapshot['warehouses']);
  List<Map<String, dynamic>> get _parties => _list(_snapshot['parties']);
  List<Map<String, dynamic>> get _invoices => _list(_snapshot['invoices']);
  List<Map<String, dynamic>> get _paymentMethods =>
      _list(_snapshot['paymentMethods']);
  List<Map<String, dynamic>> get _activePaymentMethods =>
      _paymentMethods.where((method) => method['isActive'] != false).toList();
  List<Map<String, dynamic>> get _outOfStockProducts =>
      _products.where((product) => _productStock(product) <= 0).toList();
  List<Map<String, dynamic>> get _lowStockProducts =>
      _products.where((product) {
        final minimum = _productMinimumStock(product);
        final stock = _productStock(product);
        return stock > 0 && minimum > 0 && stock <= minimum;
      }).toList();
  List<Map<String, dynamic>> get _stockAlerts {
    final alerts = [..._outOfStockProducts, ..._lowStockProducts]
      ..sort((left, right) {
        final stock = _productStock(left).compareTo(_productStock(right));
        return stock != 0
            ? stock
            : (left['name']?.toString() ?? '').compareTo(
                right['name']?.toString() ?? '',
              );
      });
    return alerts;
  }

  List<Map<String, dynamic>> get _debtBookAccounts =>
      _list(_snapshot['debtBookAccounts']);
  Map<String, dynamic> get _summary => _snapshot['summary'] is Map
      ? Map<String, dynamic>.from(_snapshot['summary'] as Map)
      : const {};

  static double _productStock(Map<String, dynamic> product) =>
      (product['stockQuantity'] as num?)?.toDouble() ?? 0;

  static double _productMinimumStock(Map<String, dynamic> product) =>
      (product['minimumStock'] as num?)?.toDouble() ?? 0;

  static bool _isOutOfStock(Map<String, dynamic> product) =>
      _productStock(product) <= 0;

  static bool _isLowStock(Map<String, dynamic> product) {
    final stock = _productStock(product);
    final minimum = _productMinimumStock(product);
    return stock > 0 && minimum > 0 && stock <= minimum;
  }

  static bool _needsStockAttention(Map<String, dynamic> product) =>
      _isOutOfStock(product) || _isLowStock(product);

  double _availableStockForWarehouse(
    Map<String, dynamic> product,
    String? warehouseId,
  ) {
    if (warehouseId == null) return _productStock(product);
    final stocks = _list(product['warehouseStocks']);
    if (stocks.isEmpty) return _productStock(product);
    final matching = stocks.where(
      (stock) => stock['warehouseId']?.toString() == warehouseId,
    );
    if (matching.isEmpty) return 0;
    return (matching.first['quantity'] as num?)?.toDouble() ?? 0;
  }

  String _stockHealthLabel(Map<String, dynamic> product) {
    if (_isOutOfStock(product)) {
      return context.loc.text('نفد', 'Out of stock');
    }
    if (_isLowStock(product)) {
      return context.loc.text('مخزون منخفض', 'Low stock');
    }
    return context.loc.text('متوفر', 'In stock');
  }

  Color _stockHealthColor(Map<String, dynamic> product) {
    if (_isOutOfStock(product)) return AppTheme.error;
    if (_isLowStock(product)) return AppTheme.warning;
    return AppTheme.success;
  }

  Widget _stockHealthChip(Map<String, dynamic> product) {
    final color = _stockHealthColor(product);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Text(
        _stockHealthLabel(product),
        style: AppTheme.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  void _openStockAlerts({String filter = 'all'}) {
    if (_stockAlerts.isEmpty) return;
    setState(() {
      _stockAlertFilter = filter;
      _productSearchController.clear();
      _productSearchQuery = '';
    });
    _tabs.animateTo(1);
  }

  String get _syncedAt => _snapshot['syncedAt']?.toString() ?? '';
  String get _syncedAtLabel {
    final parsed = DateTime.tryParse(_syncedAt);
    if (parsed == null) return _syncedAt;
    final local = parsed.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} ${two(local.hour)}:${two(local.minute)}';
  }

  @override
  void initState() {
    super.initState();
    ConnectivityService.instance.isOnline.addListener(_handleConnectivity);
    unawaited(_load());
  }

  void _handleConnectivity() {
    if (ConnectivityService.instance.isOnline.value && _pending.isNotEmpty) {
      unawaited(_sync());
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ConnectivityService.instance.isOnline.removeListener(_handleConnectivity);
    _productSearchController.dispose();
    _partySearchController.dispose();
    _productSearchFocusNode.dispose();
    _partySearchFocusNode.dispose();
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final user = await _auth.currentUser();
      final permissions = AppPermissions.fromUser(user);
      if (!permissions.canAccessStoreManagement) {
        if (!mounted) return;
        setState(() {
          _user = user;
          _loading = false;
          _error = 'لا تملك صلاحية الدخول إلى إدارة المحل.';
        });
        return;
      }
      final userId = user?['id']?.toString() ?? '';
      final local = await _store.getSnapshot(userId);
      final pending = await _store.getPendingOperations(userId);
      if (mounted) {
        setState(() {
          _user = user;
          _snapshot = StoreManagementPrivacy.redactSnapshotForStaff(
            local,
            canViewProfits: permissions.canViewStoreProfits,
          );
          if (!permissions.canManagePublicStorefront) {
            _publicOrders = const [];
          }
          _pending = pending;
          _loading = local.isEmpty;
        });
      }
      await _sync();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = ErrorMessageService.sanitize(error);
      });
    }
  }

  Future<void> _sync() async {
    if (_userId.isEmpty || _syncing) return;
    setState(() {
      _syncing = true;
      _error = null;
    });
    try {
      final snapshot = await _store.syncPending(userId: _userId, api: _api);
      if (!mounted) return;
      setState(() {
        _snapshot = StoreManagementPrivacy.redactSnapshotForStaff(
          snapshot,
          canViewProfits: _permissions.canViewStoreProfits,
        );
        _loading = false;
      });
      final results = await Future.wait<dynamic>([
        _permissions.canManagePublicStorefront
            ? _fetchPublicOrders().catchError((_) => _publicOrders)
            : Future.value(const <Map<String, dynamic>>[]),
        _store.getPendingOperations(_userId),
      ]);
      if (!mounted) return;
      setState(() {
        _publicOrders = List<Map<String, dynamic>>.from(results[0] as List);
        _pending = List<Map<String, dynamic>>.from(results[1] as List);
        _syncing = false;
      });
    } catch (error) {
      if (!mounted) return;
      final local = await _store.getSnapshot(_userId);
      final pending = await _store.getPendingOperations(_userId);
      if (!mounted) return;
      setState(() {
        _snapshot = StoreManagementPrivacy.redactSnapshotForStaff(
          local,
          canViewProfits: _permissions.canViewStoreProfits,
        );
        _pending = pending;
        _loading = false;
        _syncing = false;
        _error = ErrorMessageService.sanitize(error);
      });
    }
  }

  Future<void> _reloadLocalPending() async {
    if (_userId.isEmpty) return;
    final pending = await _store.getPendingOperations(_userId);
    final snapshot = await _store.getSnapshot(_userId);
    if (!mounted) return;
    setState(() {
      _pending = pending;
      _snapshot = StoreManagementPrivacy.redactSnapshotForStaff(
        snapshot,
        canViewProfits: _permissions.canViewStoreProfits,
      );
    });
  }

  Future<void> _deletePendingOperation(Map<String, dynamic> operation) async {
    final l = context.loc;
    final opId = operation['opId']?.toString() ?? '';
    if (opId.isEmpty) return;
    final confirmed = await _confirm(
      title: l.text('حذف عملية معلقة', 'Delete pending operation'),
      message: l.text(
        'سيتم حذف هذه العملية من قائمة المزامنة المحلية. استخدمها فقط للعمليات القديمة أو الخاطئة التي تمنع المزامنة.',
        'This operation will be removed from the local sync queue. Use only for old or incorrect operations blocking sync.',
      ),
      actionLabel: l.text('حذف العملية', 'Delete operation'),
    );
    if (confirmed != true) return;
    await _store.removePendingOperation(userId: _userId, opId: opId);
    await _reloadLocalPending();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          l.text('تم حذف العملية المعلقة.', 'Pending operation deleted.'),
        ),
      ),
    );
  }

  Future<void> _clearPendingOperations() async {
    final l = context.loc;
    final confirmed = await _confirm(
      title: l.text('حذف كل المزامنات المعلقة', 'Delete all pending syncs'),
      message: l.text(
        'سيتم حذف كل العمليات المحلية بانتظار المزامنة. بعد ذلك سنحاول تحديث البيانات من السيرفر حتى تعود الشاشة لآخر بيانات مؤكدة.',
        'All local operations awaiting sync will be deleted. Afterwards we will try to refresh data from the server.',
      ),
      actionLabel: l.text('حذف الكل', 'Delete all'),
    );
    if (confirmed != true) return;
    await _store.clearPendingOperations(_userId);
    await _reloadLocalPending();
    if (!mounted) return;
    await _sync();
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String actionLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.loc.text('إلغاء', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }

  Future<bool?> _openFullScreenForm({
    required String title,
    required Widget Function(BuildContext context, StateSetter setFormState)
    builder,
    required String actionLabel,
    bool Function()? canSubmit,
    FocusNode? primaryFocusNode,
    VoidCallback? onF2,
    VoidCallback? onF4,
  }) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (pageContext) => StatefulBuilder(
          builder: (formContext, setFormState) {
            void submitForm() {
              if (canSubmit?.call() != false) {
                Navigator.pop(pageContext, true);
              }
            }

            return CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.f2):
                    onF2 ?? () => primaryFocusNode?.requestFocus(),
                const SingleActivator(LogicalKeyboardKey.f3): () {},
                const SingleActivator(LogicalKeyboardKey.f4): onF4 ?? () {},
                const SingleActivator(LogicalKeyboardKey.f5): () {},
                const SingleActivator(LogicalKeyboardKey.f7): () {},
                const SingleActivator(LogicalKeyboardKey.f8): () {},
                const SingleActivator(LogicalKeyboardKey.f9): () {},
                const SingleActivator(LogicalKeyboardKey.f6): submitForm,
                const SingleActivator(LogicalKeyboardKey.enter, control: true):
                    submitForm,
                const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                    onF2 ?? () => primaryFocusNode?.requestFocus(),
                const SingleActivator(LogicalKeyboardKey.digit1, alt: true):
                    () {},
                const SingleActivator(LogicalKeyboardKey.digit2, alt: true):
                    () {},
                const SingleActivator(LogicalKeyboardKey.digit3, alt: true):
                    () {},
                const SingleActivator(LogicalKeyboardKey.digit4, alt: true):
                    () {},
                const SingleActivator(LogicalKeyboardKey.digit5, alt: true):
                    () {},
                const SingleActivator(LogicalKeyboardKey.digit6, alt: true):
                    () {},
              },
              child: Focus(
                autofocus: true,
                child: Scaffold(
                  backgroundColor: AppTheme.background,
                  appBar: AppBar(
                    title: Text(title),
                    leading: IconButton(
                      tooltip: context.loc.text('إغلاق', 'Close'),
                      onPressed: () => Navigator.pop(pageContext, false),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                  body: ResponsiveScaffoldContainer(
                    padding: const EdgeInsets.all(16),
                    child: ListView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      children: [
                        ShwakelCard(
                          padding: const EdgeInsets.all(16),
                          child: builder(formContext, setFormState),
                        ),
                        const SizedBox(height: 96),
                      ],
                    ),
                  ),
                  bottomNavigationBar: SafeArea(
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                      decoration: BoxDecoration(
                        color: AppTheme.background,
                        border: Border(
                          top: BorderSide(
                            color: AppTheme.border.withValues(alpha: 0.8),
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () =>
                                  Navigator.pop(pageContext, false),
                              child: Text(context.loc.text('إلغاء', 'Cancel')),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: canSubmit?.call() == false
                                  ? null
                                  : () => Navigator.pop(pageContext, true),
                              child: Text(actionLabel),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _showLocalThenSync({bool sync = true}) async {
    final local = await _store.getSnapshot(_userId);
    final pending = await _store.getPendingOperations(_userId);
    if (mounted) {
      setState(() {
        _snapshot = StoreManagementPrivacy.redactSnapshotForStaff(
          local,
          canViewProfits: _permissions.canViewStoreProfits,
        );
        _pending = pending;
        _loading = false;
      });
    }
    if (sync) await _sync();
  }

  Future<List<Map<String, dynamic>>> _fetchPublicOrders() async {
    final response = await _api.getSellerPublicStoreOrders();
    return List<Map<String, dynamic>>.from(
      (response['orders'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
  }

  Future<void> _updatePublicOrder(String orderId, String action) async {
    try {
      await _api.updatePublicStoreOrder(orderId: orderId, action: action);
      final publicOrders = await _fetchPublicOrders();
      if (!mounted) return;
      setState(() => _publicOrders = publicOrders);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.loc.text('تم تحديث حالة الطلب.', 'Order status updated.'),
          ),
        ),
      );
      await _sync();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorMessageService.sanitize(error))),
      );
    }
  }

  Future<void> _editStorefront() async {
    if (!_permissions.canManagePublicStorefront) return;
    final workspace = _snapshot['workspace'] is Map
        ? Map<String, dynamic>.from(_snapshot['workspace'] as Map)
        : const <String, dynamic>{};
    final storeName = TextEditingController(
      text: workspace['name']?.toString() ?? 'المحل',
    );
    final publicName = TextEditingController(
      text: workspace['publicName']?.toString() ?? '',
    );
    final publicDescription = TextEditingController(
      text: workspace['publicDescription']?.toString() ?? '',
    );
    final minOrder = TextEditingController(
      text: ((workspace['publicMinOrderTotal'] as num?)?.toDouble() ?? 0)
          .toStringAsFixed(2),
    );
    bool publicEnabled = workspace['publicEnabled'] == true;
    String publicOrderMode = workspace['publicOrderMode']?.toString() == 'auto'
        ? 'auto'
        : 'manual';

    final l = context.loc;
    final accepted = await _openFullScreenForm(
      title: l.text('إعداد ظهور المتجر للعامة', 'Public storefront settings'),
      actionLabel: l.text('حفظ الإعدادات', 'Save settings'),
      canSubmit: () => storeName.text.trim().isNotEmpty,
      builder: (context, setDialogState) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: storeName,
            decoration: InputDecoration(
              labelText: l.text('اسم المحل الداخلي', 'Internal store name'),
            ),
          ),
          const SizedBox(height: 10),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: publicEnabled,
            title: Text(l.text('إظهار المتجر في التطبيق', 'Show store in app')),
            subtitle: Text(
              l.text(
                'لن تظهر المنتجات إلا إذا تم تفعيلها كمنتجات عامة.',
                'Products will only appear if enabled as public products.',
              ),
            ),
            onChanged: (value) => setDialogState(() => publicEnabled = value),
          ),
          TextField(
            controller: publicName,
            decoration: InputDecoration(
              labelText: l.text(
                'اسم المتجر الظاهر للعامة',
                'Public store name',
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: publicDescription,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: l.text('وصف مختصر للمتجر', 'Short store description'),
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: publicOrderMode,
            decoration: InputDecoration(
              labelText: l.text('آلية الطلب', 'Order mode'),
            ),
            items: [
              DropdownMenuItem(
                value: 'manual',
                child: Text(
                  l.text(
                    'تأكيد يدوي من التاجر',
                    'Manual confirmation by merchant',
                  ),
                ),
              ),
              DropdownMenuItem(
                value: 'auto',
                child: Text(
                  l.text(
                    'مستقبلاً: تأكيد تلقائي حسب المتوفر',
                    'Future: automatic confirmation based on stock',
                  ),
                ),
              ),
            ],
            onChanged: (value) =>
                setDialogState(() => publicOrderMode = value ?? 'manual'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: minOrder,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l.text('الحد الأدنى للطلب', 'Minimum order amount'),
            ),
          ),
        ],
      ),
    );

    if (accepted == true) {
      await _store.queueWorkspace(
        userId: _userId,
        name: storeName.text,
        businessType: workspace['businessType']?.toString() ?? 'shop',
        currency: workspace['currency']?.toString() ?? 'ILS',
        publicEnabled: publicEnabled,
        publicName: publicName.text,
        publicDescription: publicDescription.text,
        publicOrderMode: publicOrderMode,
        publicMinOrderTotal: double.tryParse(minOrder.text) ?? 0,
      );
      await _showLocalThenSync();
    }

    storeName.dispose();
    publicName.dispose();
    publicDescription.dispose();
    minOrder.dispose();
  }

  Future<void> _addProduct() async {
    final name = TextEditingController();
    final barcode = TextEditingController();
    final sku = TextEditingController();
    final factor = TextEditingController(text: '24');
    final purchasePrice = TextEditingController(text: '0');
    final salePrice = TextEditingController(text: '0');
    final minimumStock = TextEditingController(text: '5');
    final openingStock = TextEditingController(text: '0');
    final publicMaxQuantity = TextEditingController();
    String baseUnit = 'piece';
    String packageUnit = 'carton';
    bool publicVisible = false;
    bool publicAllowOnlineSale = false;
    final l = context.loc;
    final accepted = await _openFullScreenForm(
      title: l.text('إضافة صنف جديد', 'Add new item'),
      actionLabel: l.text('حفظ الصنف', 'Save item'),
      canSubmit: () =>
          name.text.trim().isNotEmpty &&
          (double.tryParse(minimumStock.text) ?? -1) >= 0 &&
          (double.tryParse(openingStock.text) ?? -1) >= 0 &&
          ((double.tryParse(openingStock.text) ?? 0) == 0 ||
              _warehouses.isNotEmpty),
      builder: (context, setDialogState) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: name,
            decoration: InputDecoration(
              labelText: l.text('اسم الصنف *', 'Item name *'),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: sku,
            decoration: InputDecoration(
              labelText: l.text('رمز الصنف (اختياري)', 'Item code (optional)'),
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: baseUnit,
            decoration: InputDecoration(
              labelText: l.text('الوحدة الأساسية *', 'Base unit *'),
            ),
            items: [
              DropdownMenuItem(
                value: 'piece',
                child: Text(l.text('حبة', 'Piece')),
              ),
              DropdownMenuItem(
                value: 'kg',
                child: Text(l.text('كيلو', 'Kilogram')),
              ),
              DropdownMenuItem(
                value: 'liter',
                child: Text(l.text('لتر', 'Liter')),
              ),
              DropdownMenuItem(
                value: 'box',
                child: Text(l.text('صندوق', 'Box')),
              ),
            ],
            onChanged: (value) =>
                setDialogState(() => baseUnit = value ?? 'piece'),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: packageUnit,
            decoration: InputDecoration(
              labelText: l.text(
                'وحدة التجميع أو الكمية الكبيرة',
                'Package or bulk unit',
              ),
              helperText: l.text(
                'مثال: كيس، كرتونة، مشطاح.',
                'Example: bag, carton, pallet.',
              ),
            ),
            items: [
              DropdownMenuItem(
                value: 'carton',
                child: Text(l.text('كرتونة', 'Carton')),
              ),
              DropdownMenuItem(value: 'bag', child: Text(l.text('كيس', 'Bag'))),
              DropdownMenuItem(
                value: 'box',
                child: Text(l.text('صندوق', 'Box')),
              ),
              DropdownMenuItem(
                value: 'pallet',
                child: Text(l.text('مشطاح', 'Pallet')),
              ),
            ],
            onChanged: (value) =>
                setDialogState(() => packageUnit = value ?? 'carton'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: factor,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: l.text(
                'عدد الوحدات الأساسية داخل وحدة التجميع',
                'Number of base units per package unit',
              ),
              helperText: l.text(
                'مثال: الكرتونة = 24 حبة، المشطاح = 50 كرتونة.',
                'Example: carton = 24 pieces, pallet = 50 cartons.',
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: barcode,
            decoration: InputDecoration(
              labelText: l.text(
                'باركود الصنف أو وحدة التجميع',
                'Item or package barcode',
              ),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () async {
                final value = await _scanBarcode(
                  title: l.text('قراءة باركود الصنف', 'Scan item barcode'),
                  description: l.text(
                    'وجه الكاميرا إلى باركود الكرتونة أو الوحدة.',
                    'Point the camera at the carton or unit barcode.',
                  ),
                );
                if (value != null) {
                  barcode.text = value;
                }
              },
              icon: const Icon(Icons.camera_alt_rounded),
              label: Text(l.text('قراءة من الكاميرا', 'Scan with camera')),
            ),
          ),
          if (_permissions.canEditStorePrices &&
              _permissions.canViewStoreProfits) ...[
            const SizedBox(height: 10),
            TextField(
              controller: purchasePrice,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: l.text(
                  'سعر شراء الوحدة الأساسية',
                  'Base unit purchase price',
                ),
                helperText: l.text(
                  'يستخدم تلقائيًا عند فواتير الشراء.',
                  'Used automatically in purchase invoices.',
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          TextField(
            controller: salePrice,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l.text(
                'سعر بيع الوحدة الأساسية',
                'Base unit sale price',
              ),
              helperText: l.text(
                'يظهر تلقائيًا عند البيع أو POS.',
                'Appears automatically when selling or at POS.',
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: minimumStock,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l.text(
                'حد تنبيه المخزون',
                'Low-stock alert threshold',
              ),
              helperText: l.text(
                'يظهر تنبيه عندما يصل الرصيد إلى هذا الحد أو أقل.',
                'An alert appears when stock reaches this level or below.',
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: openingStock,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l.text(
                'الرصيد الافتتاحي (اختياري)',
                'Opening quantity (optional)',
              ),
              helperText: l.text(
                'يُسجل كتسوية مخزون موثقة في المخزن الافتراضي.',
                'Recorded as an audited adjustment in the default warehouse.',
              ),
            ),
          ),
          if (_warehouses.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                l.text(
                  'أضف مخزنًا قبل إدخال رصيد افتتاحي.',
                  'Add a warehouse before entering an opening quantity.',
                ),
                style: AppTheme.caption.copyWith(color: AppTheme.warning),
              ),
            ),
          if (_permissions.canManagePublicStorefront) ...[
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: publicVisible,
              title: Text(
                l.text(
                  'إظهار الصنف في المتجر العام',
                  'Show item in public store',
                ),
              ),
              subtitle: Text(
                l.text(
                  'لن يظهر إلا إذا كان المتجر نفسه منشورًا.',
                  'Only visible if the store itself is published.',
                ),
              ),
              onChanged: (value) => setDialogState(() => publicVisible = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: publicAllowOnlineSale,
              title: Text(
                l.text('السماح بالشراء من التطبيق', 'Allow purchase from app'),
              ),
              subtitle: Text(
                l.text(
                  'يتم إنشاء طلب للمتجر حسب الكمية المتاحة.',
                  'An order is created based on available quantity.',
                ),
              ),
              onChanged: publicVisible
                  ? (value) =>
                        setDialogState(() => publicAllowOnlineSale = value)
                  : null,
            ),
            TextField(
              controller: publicMaxQuantity,
              enabled: publicVisible && publicAllowOnlineSale,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: l.text(
                  'أقصى كمية مسموحة للطلب',
                  'Maximum allowed order quantity',
                ),
                helperText: l.text(
                  'اتركه فارغًا لاستخدام المتوفر بالمخزون.',
                  'Leave empty to use available stock.',
                ),
              ),
            ),
          ],
        ],
      ),
    );
    if (accepted == true && name.text.trim().isNotEmpty) {
      final packageFactor = double.tryParse(factor.text) ?? 1;
      final cost = double.tryParse(purchasePrice.text) ?? 0;
      final price = double.tryParse(salePrice.text) ?? 0;
      final productClientRef = const Uuid().v4();
      await _store.queueProduct(
        userId: _userId,
        clientRef: productClientRef,
        sku: sku.text.trim().isEmpty ? null : sku.text.trim(),
        name: name.text,
        baseUnit: baseUnit,
        minimumStock: double.tryParse(minimumStock.text) ?? 0,
        salePrice: price,
        publicVisible: publicVisible,
        publicAllowOnlineSale: publicAllowOnlineSale,
        publicMaxQuantity: double.tryParse(publicMaxQuantity.text),
        units: [
          {
            'name': _unitName(baseUnit),
            'code': baseUnit,
            'factorToBase': 1,
            'isBase': true,
            'purchasePrice': cost,
            'salePrice': price,
          },
          if (packageFactor > 1)
            {
              'name': _unitName(packageUnit),
              'code': packageUnit,
              'factorToBase': packageFactor,
              'barcode': barcode.text.trim(),
              'purchasePrice': cost * packageFactor,
              'salePrice': price * packageFactor,
            },
        ],
      );
      final initialQuantity = double.tryParse(openingStock.text) ?? 0;
      if (initialQuantity > 0) {
        final latest = await _store.getSnapshot(_userId);
        final product = _list(latest['products']).firstWhere(
          (item) => item['clientRef']?.toString() == productClientRef,
          orElse: () => const <String, dynamic>{},
        );
        final defaultWarehouse = _warehouses.firstWhere(
          (item) => item['isDefault'] == true,
          orElse: () => _warehouses.isNotEmpty ? _warehouses.first : const {},
        );
        if (product.isNotEmpty && defaultWarehouse.isNotEmpty) {
          final productUnits = _list(product['units']);
          final base = productUnits.firstWhere(
            (unit) => unit['isBase'] == true,
            orElse: () => productUnits.isNotEmpty
                ? productUnits.first
                : const <String, dynamic>{},
          );
          await _store.queueStockAdjustment(
            userId: _userId,
            productId: product['id']?.toString(),
            productClientRef: product['clientRef']?.toString(),
            warehouseId: defaultWarehouse['id']?.toString(),
            warehouseClientRef: defaultWarehouse['clientRef']?.toString(),
            productUnitId: base['id']?.toString(),
            unitClientRef: base['clientRef']?.toString(),
            targetQuantity: initialQuantity,
            unitCost: _permissions.canViewStoreProfits ? cost : null,
            clientRef: const Uuid().v4(),
            actorUserId: _userId,
            actorName: _actorName,
          );
        }
      }
      await _showLocalThenSync();
    }
    name.dispose();
    barcode.dispose();
    sku.dispose();
    factor.dispose();
    purchasePrice.dispose();
    salePrice.dispose();
    minimumStock.dispose();
    openingStock.dispose();
    publicMaxQuantity.dispose();
  }

  Future<void> _editProduct(Map<String, dynamic> product) async {
    final name = TextEditingController(text: product['name']?.toString() ?? '');
    final sku = TextEditingController(text: product['sku']?.toString() ?? '');
    final minimum = TextEditingController(
      text: _productMinimumStock(product).toString(),
    );
    final originalUnits = _list(
      product['units'],
    ).map((unit) => Map<String, dynamic>.from(unit)).toList();
    final baseIndex = originalUnits.indexWhere(
      (unit) => unit['isBase'] == true,
    );
    final resolvedBaseIndex = baseIndex >= 0 ? baseIndex : 0;
    final currentSalePrice =
        (product['defaultSalePrice'] as num?)?.toDouble() ?? 0;
    final basePrice = TextEditingController(text: currentSalePrice.toString());
    final l = context.loc;
    final accepted = await _openFullScreenForm(
      title: '${l.text('تعديل الصنف', 'Edit item')} • ${product['name'] ?? ''}',
      actionLabel: l.text('حفظ التعديلات', 'Save changes'),
      canSubmit: () =>
          name.text.trim().isNotEmpty &&
          (double.tryParse(minimum.text) ?? -1) >= 0 &&
          (!_permissions.canEditStorePrices ||
              (double.tryParse(basePrice.text) ?? -1) >= 0),
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: name,
            decoration: InputDecoration(
              labelText: l.text('اسم الصنف', 'Item name'),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: sku,
            decoration: InputDecoration(
              labelText: l.text('رمز الصنف', 'Item code'),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: minimum,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l.text('حد تنبيه المخزون', 'Low-stock threshold'),
            ),
          ),
          if (_permissions.canEditStorePrices) ...[
            const SizedBox(height: 10),
            TextField(
              controller: basePrice,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: l.text(
                  'سعر بيع الوحدة الأساسية',
                  'Base unit sale price',
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            l.text(
              'الوحدات والباركودات الحالية محفوظة. لإدارة تحويلات جديدة استخدم ملف الاستيراد أو شاشة الأصناف المتقدمة.',
              'Existing units and barcodes are preserved. Use import or advanced item setup to change unit conversions.',
            ),
            style: AppTheme.caption,
          ),
        ],
      ),
    );
    if (accepted == true) {
      var salePrice = currentSalePrice;
      if (_permissions.canEditStorePrices) {
        salePrice = double.tryParse(basePrice.text) ?? currentSalePrice;
      }
      if (originalUnits.isNotEmpty &&
          resolvedBaseIndex < originalUnits.length) {
        if (_permissions.canEditStorePrices) {
          final factor =
              (originalUnits[resolvedBaseIndex]['factorToBase'] as num?)
                  ?.toDouble() ??
              1;
          originalUnits[resolvedBaseIndex]['salePrice'] = salePrice;
          for (var index = 0; index < originalUnits.length; index++) {
            if (index != resolvedBaseIndex &&
                (originalUnits[index]['salePrice'] as num?) == null) {
              originalUnits[index]['salePrice'] =
                  salePrice *
                  ((originalUnits[index]['factorToBase'] as num?)?.toDouble() ??
                      factor);
            }
          }
        }
      }
      final clientRef = product['clientRef']?.toString() ?? const Uuid().v4();
      final rawId = product['id']?.toString();
      await _store.queueProduct(
        userId: _userId,
        serverId: rawId != null && !rawId.startsWith('local:') ? rawId : null,
        clientRef: clientRef,
        sku: sku.text.trim().isEmpty ? null : sku.text.trim(),
        name: name.text.trim(),
        baseUnit: product['baseUnit']?.toString() ?? 'piece',
        minimumStock: double.tryParse(minimum.text) ?? 0,
        salePrice: salePrice,
        publicVisible: product['publicVisible'] == true,
        publicAllowOnlineSale: product['publicAllowOnlineSale'] == true,
        publicMaxQuantity: (product['publicMaxQuantity'] as num?)?.toDouble(),
        units: originalUnits,
      );
      await _showLocalThenSync();
    }
    name.dispose();
    sku.dispose();
    minimum.dispose();
    basePrice.dispose();
  }

  Future<void> _adjustProductStock(Map<String, dynamic> product) async {
    if (_warehouses.isEmpty) {
      _showMessage(
        context.loc.text('أضف مخزنًا أولًا.', 'Add a warehouse first.'),
      );
      return;
    }
    final quantity = TextEditingController();
    String? warehouseId = _warehouses
        .firstWhere(
          (warehouse) => warehouse['isDefault'] == true,
          orElse: () => _warehouses.first,
        )['id']
        ?.toString();
    final l = context.loc;
    final accepted = await _openFullScreenForm(
      title:
          '${l.text('تسوية رصيد', 'Adjust stock')} • ${product['name'] ?? ''}',
      actionLabel: l.text('حفظ التسوية', 'Save adjustment'),
      canSubmit: () =>
          warehouseId != null && (double.tryParse(quantity.text) ?? -1) >= 0,
      builder: (context, setDialogState) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: warehouseId,
            decoration: InputDecoration(
              labelText: l.text('المخزن', 'Warehouse'),
            ),
            items: _warehouses
                .map(
                  (warehouse) => DropdownMenuItem(
                    value: warehouse['id']?.toString(),
                    child: Text(warehouse['name']?.toString() ?? ''),
                  ),
                )
                .toList(),
            onChanged: (value) => setDialogState(() => warehouseId = value),
          ),
          const SizedBox(height: 10),
          Text(
            '${l.text('الرصيد الحالي في المخزن', 'Current warehouse stock')}: ${_availableStockForWarehouse(product, warehouseId)} ${_unitName(product['baseUnit']?.toString() ?? '')}',
            style: AppTheme.bodyBold,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: quantity,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l.text('الرصيد الجديد', 'New on-hand quantity'),
              helperText: l.text(
                'أدخل الرصيد الفعلي بعد الجرد. يسجل النظام الفرق كتسوية مدققة.',
                'Enter the counted quantity. The difference is recorded as an audited adjustment.',
              ),
            ),
          ),
        ],
      ),
    );
    if (accepted == true && warehouseId != null) {
      final warehouse = _warehouses.firstWhere(
        (item) => item['id']?.toString() == warehouseId,
        orElse: () => const <String, dynamic>{},
      );
      final units = _list(product['units']);
      final base = units.firstWhere(
        (unit) => unit['isBase'] == true,
        orElse: () =>
            units.isNotEmpty ? units.first : const <String, dynamic>{},
      );
      await _store.queueStockAdjustment(
        userId: _userId,
        productId: product['id']?.toString(),
        productClientRef: product['clientRef']?.toString(),
        warehouseId: warehouseId,
        warehouseClientRef: warehouse['clientRef']?.toString(),
        productUnitId: base['id']?.toString(),
        unitClientRef: base['clientRef']?.toString(),
        targetQuantity: double.tryParse(quantity.text) ?? 0,
        unitCost: _permissions.canViewStoreProfits
            ? (base['purchasePrice'] as num?)?.toDouble()
            : null,
        clientRef: const Uuid().v4(),
        actorUserId: _userId,
        actorName: _actorName,
      );
      await _showLocalThenSync();
    }
    quantity.dispose();
  }

  Widget _productActionsMenu(Map<String, dynamic> product) =>
      PopupMenuButton<String>(
        tooltip: context.loc.text('إجراءات الصنف', 'Item actions'),
        onSelected: (action) {
          if (action == 'edit') unawaited(_editProduct(product));
          if (action == 'stock') unawaited(_adjustProductStock(product));
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'edit',
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.edit_outlined),
              title: Text(context.loc.text('تعديل الصنف', 'Edit item')),
            ),
          ),
          PopupMenuItem(
            value: 'stock',
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.inventory_outlined),
              title: Text(context.loc.text('تسوية الرصيد', 'Adjust stock')),
            ),
          ),
        ],
      );

  Future<void> _addParty() async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final creditLimit = TextEditingController(text: '0');
    String type = 'customer';
    String? selectedDebtBookAccountId;
    String debtSearch = '';
    final l = context.loc;
    final accepted = await _openFullScreenForm(
      title: l.text('إضافة زبون أو تاجر', 'Add customer or supplier'),
      actionLabel: l.text('حفظ الحساب', 'Save account'),
      canSubmit: () =>
          name.text.trim().isNotEmpty &&
          (double.tryParse(creditLimit.text) ?? -1) >= 0,
      builder: (context, setDialogState) {
        final query = debtSearch.trim().toLowerCase();
        final debtAccounts = _debtBookAccounts
            .where((account) {
              if (query.isEmpty) return true;
              final haystack =
                  '${account['fullName'] ?? ''} ${account['phone'] ?? ''}'
                      .toLowerCase();
              return haystack.contains(query);
            })
            .take(30)
            .toList();

        void applyDebtAccount(String? id) {
          selectedDebtBookAccountId = id;
          if (id == null) return;
          final account = _debtBookAccounts.firstWhere(
            (item) => item['id']?.toString() == id,
            orElse: () => const {},
          );
          if (account.isEmpty) return;
          name.text = (account['fullName'] ?? '').toString();
          phone.text = (account['phone'] ?? '').toString();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: type,
              decoration: InputDecoration(
                labelText: l.text('نوع الحساب *', 'Account type *'),
              ),
              items: [
                DropdownMenuItem(
                  value: 'customer',
                  child: Text(l.text('زبون', 'Customer')),
                ),
                DropdownMenuItem(
                  value: 'supplier',
                  child: Text(l.text('تاجر', 'Supplier')),
                ),
                DropdownMenuItem(
                  value: 'both',
                  child: Text(l.text('زبون وتاجر', 'Customer and supplier')),
                ),
              ],
              onChanged: (value) =>
                  setDialogState(() => type = value ?? 'customer'),
            ),
            const SizedBox(height: 10),
            TextField(
              decoration: InputDecoration(
                labelText: l.text('بحث في دفتر الديون', 'Search debt book'),
                prefixIcon: const Icon(Icons.search_rounded),
              ),
              onChanged: (value) => setDialogState(() => debtSearch = value),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String?>(
              initialValue: selectedDebtBookAccountId,
              decoration: InputDecoration(
                labelText: l.text(
                  'اعتماد حساب من دفتر الديون',
                  'Link account from debt book',
                ),
              ),
              items: [
                DropdownMenuItem<String?>(
                  value: null,
                  child: Text(
                    l.text('حساب جديد غير مربوط', 'New unlinked account'),
                  ),
                ),
                ...debtAccounts.map(
                  (account) => DropdownMenuItem<String?>(
                    value: account['id']?.toString(),
                    child: Text(
                      '${account['fullName'] ?? ''} • ${account['phone'] ?? ''}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
              onChanged: (value) =>
                  setDialogState(() => applyDebtAccount(value)),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: name,
              decoration: InputDecoration(
                labelText: l.text('الاسم *', 'Name *'),
              ),
            ),
            TextField(
              controller: phone,
              decoration: InputDecoration(
                labelText: l.text(
                  'رقم الهاتف (اختياري)',
                  'Phone number (optional)',
                ),
              ),
            ),
            if (type == 'customer' || type == 'both') ...[
              const SizedBox(height: 10),
              TextField(
                controller: creditLimit,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: l.text('حد الدين', 'Credit limit'),
                  helperText: l.text(
                    'اتركه 0 للسماح بالدين دون حد.',
                    'Set to 0 for no credit limit.',
                  ),
                  prefixIcon: const Icon(Icons.account_balance_wallet_outlined),
                ),
              ),
            ],
          ],
        );
      },
    );
    if (accepted == true && name.text.trim().isNotEmpty) {
      await _store.queueParty(
        userId: _userId,
        type: type,
        name: name.text,
        phone: phone.text,
        debtBookCustomerId: selectedDebtBookAccountId,
        creditLimit: double.tryParse(creditLimit.text) ?? 0,
      );
      await _showLocalThenSync();
    }
    name.dispose();
    phone.dispose();
    creditLimit.dispose();
  }

  Future<void> _editPartyCreditLimit(Map<String, dynamic> party) async {
    if (!_permissions.canManageStoreDebts) return;
    final limit = TextEditingController(
      text: ((party['creditLimit'] as num?)?.toDouble() ?? 0).toStringAsFixed(
        2,
      ),
    );
    final l = context.loc;
    final accepted = await _openFullScreenForm(
      title: '${l.text('حد الدين', 'Credit limit')} • ${party['name'] ?? ''}',
      actionLabel: l.text('حفظ الحد', 'Save limit'),
      canSubmit: () => (double.tryParse(limit.text) ?? -1) >= 0,
      builder: (_, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: limit,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l.text('حد الدين', 'Credit limit'),
              helperText: l.text(
                'عند 0 لا يوجد حد. عند بلوغ الحد يُمنع تسجيل دين إضافي.',
                '0 means unlimited. New debt is blocked once the limit is reached.',
              ),
            ),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await _store.queueParty(
        userId: _userId,
        serverId: party['id']?.toString().startsWith('local:') == true
            ? null
            : party['id']?.toString(),
        clientRef: party['clientRef']?.toString(),
        type: party['type']?.toString() ?? 'customer',
        name: party['name']?.toString() ?? '',
        phone: party['phone']?.toString() ?? '',
        notes: party['notes']?.toString() ?? '',
        debtBookCustomerId: party['debtBookCustomerId']?.toString(),
        creditLimit: double.tryParse(limit.text) ?? 0,
      );
      await _showLocalThenSync();
    }
    limit.dispose();
  }

  Future<String?> _scanBarcode({
    required String title,
    required String description,
  }) async {
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (pageContext) => Scaffold(
          backgroundColor: AppTheme.background,
          body: SafeArea(
            child: ResponsiveScaffoldContainer(
              padding: const EdgeInsets.all(16),
              child: BarcodeScannerDialog(
                title: title,
                description: description,
                showFrame: true,
                fullScreen: true,
                height: MediaQuery.sizeOf(pageContext).height * 0.56,
              ),
            ),
          ),
        ),
      ),
    );
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  Future<Map<String, dynamic>?> _pickStoreEntry({
    required String title,
    required List<Map<String, dynamic>> entries,
    required String searchHint,
    required String addLabel,
    required Future<void> Function() onAdd,
  }) async {
    final search = TextEditingController();
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final query = search.text.trim().toLowerCase();
          final filtered = entries
              .where((entry) {
                final haystack =
                    '${entry['name'] ?? ''} ${entry['phone'] ?? ''} '
                            '${entry['barcode'] ?? ''}'
                        .toLowerCase();
                return query.isEmpty || haystack.contains(query);
              })
              .take(60)
              .toList();
          return Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              MediaQuery.viewInsetsOf(context).bottom + 16,
            ),
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.72,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(title, style: AppTheme.h3)),
                      IconButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: search,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: searchHint,
                      prefixIcon: const Icon(Icons.search_rounded),
                    ),
                    onChanged: (_) => setSheetState(() {}),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      Navigator.pop(sheetContext);
                      await onAdd();
                    },
                    icon: const Icon(Icons.add_rounded),
                    label: Text(addLabel),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: Text(
                              context.loc.text('لا توجد نتائج', 'No results'),
                            ),
                          )
                        : ListView.separated(
                            itemCount: filtered.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final entry = filtered[index];
                              return ListTile(
                                leading: const Icon(Icons.search_rounded),
                                title: Text(entry['name']?.toString() ?? ''),
                                subtitle:
                                    (entry['phone']?.toString() ?? '').isEmpty
                                    ? null
                                    : Text(entry['phone'].toString()),
                                onTap: () => Navigator.pop(sheetContext, entry),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    search.dispose();
    return result;
  }

  Future<void> _managePaymentMethods() async {
    final l = context.loc;
    final methods = _paymentMethods
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final removed = <Map<String, dynamic>>[];

    Future<String?> askName(BuildContext dialog, [String value = '']) async {
      final controller = TextEditingController(text: value);
      final result = await showDialog<String>(
        context: dialog,
        builder: (context) => AlertDialog(
          title: Text(
            value.isEmpty
                ? l.text('إضافة طريقة دفع', 'Add payment method')
                : l.text('تعديل طريقة الدفع', 'Edit payment method'),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 100,
            decoration: InputDecoration(
              labelText: l.text('اسم طريقة الدفع', 'Payment method name'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l.text('إلغاء', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: Text(l.text('حفظ', 'Save')),
            ),
          ],
        ),
      );
      controller.dispose();
      return result;
    }

    final accepted = await _openFullScreenForm(
      title: l.text('طرق الدفع', 'Payment methods'),
      actionLabel: l.text('حفظ الترتيب', 'Save order'),
      canSubmit: () => methods.any((method) => method['isActive'] != false),
      builder: (dialog, setFormState) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.text(
              'رتّب الطرق التي تظهر للكاشير، وأضف طرقًا خاصة بمتجرك. يجب إبقاء طريقة واحدة فعالة على الأقل.',
              'Arrange cashier payment methods and add store-specific options. Keep at least one active.',
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              final name = await askName(dialog);
              if (name == null || name.isEmpty) return;
              setFormState(
                () => methods.add({
                  'id': 'local:${DateTime.now().microsecondsSinceEpoch}',
                  'clientRef': DateTime.now().microsecondsSinceEpoch.toString(),
                  'name': name,
                  'isActive': true,
                  'isSystem': false,
                }),
              );
            },
            icon: const Icon(Icons.add_rounded),
            label: Text(l.text('إضافة طريقة دفع', 'Add payment method')),
          ),
          const SizedBox(height: 8),
          ...methods.asMap().entries.map((entry) {
            final index = entry.key;
            final method = entry.value;
            return Card(
              child: ListTile(
                leading: Switch(
                  value: method['isActive'] != false,
                  onChanged: (value) =>
                      setFormState(() => method['isActive'] = value),
                ),
                title: Text(method['name']?.toString() ?? ''),
                subtitle: Text(
                  method['isActive'] != false
                      ? l.text('تظهر عند الدفع', 'Shown at checkout')
                      : l.text('مخفية مؤقتًا', 'Temporarily hidden'),
                ),
                trailing: Wrap(
                  spacing: 0,
                  children: [
                    IconButton(
                      tooltip: l.text('للأعلى', 'Move up'),
                      onPressed: index == 0
                          ? null
                          : () => setFormState(() {
                              final item = methods.removeAt(index);
                              methods.insert(index - 1, item);
                            }),
                      icon: const Icon(Icons.arrow_upward_rounded),
                    ),
                    IconButton(
                      tooltip: l.text('للأسفل', 'Move down'),
                      onPressed: index == methods.length - 1
                          ? null
                          : () => setFormState(() {
                              final item = methods.removeAt(index);
                              methods.insert(index + 1, item);
                            }),
                      icon: const Icon(Icons.arrow_downward_rounded),
                    ),
                    IconButton(
                      tooltip: l.text('تعديل', 'Edit'),
                      onPressed: () async {
                        final name = await askName(
                          dialog,
                          method['name']?.toString() ?? '',
                        );
                        if (name != null && name.isNotEmpty) {
                          setFormState(() => method['name'] = name);
                        }
                      },
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: l.text('حذف', 'Delete'),
                      onPressed: methods.length <= 1
                          ? null
                          : () => setFormState(() {
                              removed.add(method);
                              methods.removeAt(index);
                            }),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
    if (accepted != true) return;

    for (final method in removed) {
      final id = method['id']?.toString() ?? '';
      if (id.isNotEmpty && !id.startsWith('local:')) {
        await _store.queueDeletePaymentMethod(
          userId: _userId,
          id: id,
          clientRef: method['clientRef']?.toString(),
        );
      }
    }
    for (var index = 0; index < methods.length; index++) {
      final method = methods[index];
      final rawId = method['id']?.toString();
      await _store.queuePaymentMethod(
        userId: _userId,
        id: rawId?.startsWith('local:') == true ? null : rawId,
        clientRef: method['clientRef']?.toString(),
        name: method['name']?.toString() ?? '',
        sortOrder: (index + 1) * 10,
        isActive: method['isActive'] != false,
      );
    }
    await _showLocalThenSync();
  }

  Future<void> _createInvoice({
    bool quickSale = false,
    String? initialType,
  }) async {
    if (_creatingInvoice) return;
    _creatingInvoice = true;
    try {
      await _createInvoiceFlow(quickSale: quickSale, initialType: initialType);
    } catch (error) {
      if (mounted) {
        _showMessage(
          '${context.loc.text('تعذر حفظ الفاتورة', 'Could not save the invoice')}: ${ErrorMessageService.sanitize(error)}',
        );
      }
    } finally {
      _creatingInvoice = false;
    }
  }

  Future<void> _createInvoiceFlow({
    bool quickSale = false,
    String? initialType,
  }) async {
    unawaited(prepareCashierSound());
    String invoiceType = quickSale
        ? 'sale'
        : initialType ??
              (_permissions.canCreateStoreSales ? 'sale' : 'purchase');
    final generalCustomer = _parties.where((party) {
      final type = party['type']?.toString();
      final name = _normalizeSearch(party['name']?.toString() ?? '');
      return (type == 'customer' || type == 'both') &&
          (party['isGeneralCustomer'] == true ||
              name == _normalizeSearch('زبون عام'));
    }).firstOrNull;
    String? partyId;
    if (invoiceType == 'sale') {
      partyId = generalCustomer?['id']?.toString();
    }
    String? warehouseId = _warehouses
        .firstWhere(
          (warehouse) => warehouse['isDefault'] == true,
          orElse: () => _warehouses.isNotEmpty ? _warehouses.first : const {},
        )['id']
        ?.toString();
    String paymentStatus = 'paid';
    String? paymentMethodId = _activePaymentMethods.firstOrNull?['id']
        ?.toString();
    final paid = TextEditingController(text: '0');
    final discount = TextEditingController(text: '0');
    TextEditingController? autocompleteController;
    FocusNode? autocompleteFocusNode;
    final lines = <Map<String, dynamic>>[];
    String? lastScanFeedback;
    bool lastScanWasError = false;
    Future<void> Function()? barcodeAction;

    Map<String, dynamic> productById(String? id) => _products.firstWhere(
      (item) => item['id']?.toString() == id,
      orElse: () => _products.first,
    );

    Map<String, dynamic>? firstUnit(Map<String, dynamic> product) {
      final units = _list(product['units']);
      if (units.isEmpty) return null;
      return units.firstWhere(
        (unit) => unit['isBase'] == true,
        orElse: () => units.first,
      );
    }

    double defaultPrice(
      Map<String, dynamic> product,
      Map<String, dynamic>? unit,
    ) {
      final factor = (unit?['factorToBase'] as num?)?.toDouble() ?? 1;
      if (invoiceType == 'sale') {
        return (unit?['salePrice'] as num?)?.toDouble() ??
            (product['defaultSalePrice'] as num?)?.toDouble() ??
            0;
      }
      return (unit?['purchasePrice'] as num?)?.toDouble() ??
          ((product['averagePurchaseCost'] as num?)?.toDouble() ?? 0) * factor;
    }

    double defaultSalePrice(
      Map<String, dynamic> product,
      Map<String, dynamic>? unit,
    ) {
      final factor = (unit?['factorToBase'] as num?)?.toDouble() ?? 1;
      return (unit?['salePrice'] as num?)?.toDouble() ??
          ((product['defaultSalePrice'] as num?)?.toDouble() ?? 0) * factor;
    }

    bool addLine(Map<String, dynamic> product, Map<String, dynamic>? unit) {
      final existingIndex = lines.indexWhere(
        (line) =>
            line['productId']?.toString() == product['id']?.toString() &&
            line['unitId']?.toString() == unit?['id']?.toString(),
      );
      final currentQuantity = existingIndex >= 0
          ? (lines[existingIndex]['quantity'] as num?)?.toDouble() ?? 0
          : 0.0;
      final nextQuantity = currentQuantity + 1;
      final factor = (unit?['factorToBase'] as num?)?.toDouble() ?? 1;
      if (invoiceType == 'sale' &&
          nextQuantity * factor >
              _availableStockForWarehouse(product, warehouseId) + 0.000001) {
        lastScanFeedback = context.loc.text(
          'الكمية المتاحة من ${product['name'] ?? ''} غير كافية في هذا المخزن.',
          'Not enough ${product['name'] ?? ''} is available in this warehouse.',
        );
        lastScanWasError = true;
        return false;
      }
      if (existingIndex >= 0) {
        lines[existingIndex]['quantity'] = nextQuantity;
      } else {
        lines.add({
          'productId': product['id']?.toString(),
          'productClientRef': product['clientRef']?.toString(),
          'unitId': unit?['id']?.toString(),
          'unitClientRef': unit?['clientRef']?.toString(),
          'name': product['name']?.toString() ?? '',
          'unitName':
              unit?['name']?.toString() ??
              _unitName(product['baseUnit']?.toString() ?? ''),
          'quantity': 1.0,
          'unitPrice': defaultPrice(product, unit),
          'salePrice': defaultSalePrice(product, unit),
        });
      }
      final remaining =
          _availableStockForWarehouse(product, warehouseId) -
          nextQuantity * factor;
      lastScanFeedback = context.loc.text(
        'أضيف ${product['name'] ?? ''} للفاتورة • المتبقي ${remaining < 0 ? 0 : remaining}',
        'Added ${product['name'] ?? ''} • ${remaining < 0 ? 0 : remaining} remaining',
      );
      lastScanWasError = false;
      unawaited(playCashierBeep());
      return true;
    }

    List<String> stockValidationMessages() {
      if (invoiceType != 'sale') return const [];
      final grouped = <String, double>{};
      final productsById = <String, Map<String, dynamic>>{};
      for (final line in lines) {
        final id = line['productId']?.toString() ?? '';
        if (id.isEmpty) continue;
        final product = productById(id);
        final unit = _list(product['units']).firstWhere(
          (entry) => entry['id']?.toString() == line['unitId']?.toString(),
          orElse: () => firstUnit(product) ?? const <String, dynamic>{},
        );
        final factor = (unit['factorToBase'] as num?)?.toDouble() ?? 1;
        grouped.update(
          id,
          (quantity) =>
              quantity + ((line['quantity'] as num?)?.toDouble() ?? 0) * factor,
          ifAbsent: () =>
              ((line['quantity'] as num?)?.toDouble() ?? 0) * factor,
        );
        productsById[id] = product;
      }
      return grouped.entries
          .where((entry) {
            final product = productsById[entry.key]!;
            return entry.value >
                _availableStockForWarehouse(product, warehouseId) + 0.000001;
          })
          .map((entry) {
            final product = productsById[entry.key]!;
            return '${product['name'] ?? ''}: ${context.loc.text('المطلوب', 'requested')} ${entry.value} • ${context.loc.text('المتوفر', 'available')} ${_availableStockForWarehouse(product, warehouseId)}';
          })
          .toList();
    }

    Map<String, dynamic>? findByBarcode(String barcode) {
      final normalized = barcode.trim();
      if (normalized.isEmpty) return null;
      for (final product in _products) {
        for (final unit in _list(product['units'])) {
          if ((unit['barcode']?.toString().trim() ?? '') == normalized) {
            return {'product': product, 'unit': unit};
          }
        }
      }
      return null;
    }

    final l = context.loc;
    final accepted = await _openFullScreenForm(
      title: quickSale
          ? l.text('البيع السريع', 'Quick sale')
          : invoiceType == 'sale'
          ? l.text('نقطة بيع POS - فاتورة بيع', 'POS - Sale invoice')
          : l.text(
              'نقطة شراء - فاتورة مشتريات',
              'Purchase point - Purchase invoice',
            ),
      actionLabel: l.text('حفظ الفاتورة', 'Save invoice'),
      onF2: () => autocompleteFocusNode?.requestFocus(),
      onF4: () => unawaited(barcodeAction?.call()),
      canSubmit: () {
        final subtotal = lines.fold<double>(
          0,
          (sum, line) =>
              sum +
              (((line['quantity'] as num?)?.toDouble() ?? 0) *
                  ((line['unitPrice'] as num?)?.toDouble() ?? 0)),
        );
        final discountValue = double.tryParse(discount.text) ?? 0;
        final total = (subtotal - discountValue).clamp(0, subtotal).toDouble();
        final paidAmount = paymentStatus == 'paid'
            ? total
            : paymentStatus == 'partial'
            ? double.tryParse(paid.text) ?? 0
            : 0.0;
        final hasDue = total - paidAmount > 0.009;
        final selectedParty = _parties.firstWhere(
          (item) => item['id']?.toString() == partyId,
          orElse: () => const {},
        );
        final creditLimit =
            (selectedParty['creditLimit'] as num?)?.toDouble() ?? 0;
        final currentDebt =
            (selectedParty['receivableBalance'] as num?)?.toDouble() ?? 0;
        final exceedsCreditLimit =
            invoiceType == 'sale' &&
            hasDue &&
            creditLimit > 0 &&
            currentDebt + total - paidAmount > creditLimit + 0.009;
        return lines.isNotEmpty &&
            stockValidationMessages().isEmpty &&
            (invoiceType != 'sale' ||
                _permissions.canEditStorePrices ||
                discountValue == 0) &&
            (!quickSale || (paymentStatus == 'paid' && discountValue == 0)) &&
            (paymentStatus == 'debt' || paymentMethodId != null) &&
            (!hasDue ||
                (_permissions.canManageStoreDebts && partyId != null)) &&
            !exceedsCreditLimit &&
            (paymentStatus != 'partial' ||
                (paidAmount > 0 && paidAmount < total)) &&
            !(invoiceType == 'purchase' && partyId == null);
      },
      builder: (context, setDialogState) {
        final allowedParties = _parties.where((party) {
          final type = party['type']?.toString();
          return invoiceType == 'sale'
              ? type == 'customer' || type == 'both'
              : type == 'supplier' || type == 'both';
        }).toList();
        final subtotal = lines.fold<double>(
          0,
          (sum, line) =>
              sum +
              (((line['quantity'] as num?)?.toDouble() ?? 0) *
                  ((line['unitPrice'] as num?)?.toDouble() ?? 0)),
        );
        final discountValue = double.tryParse(discount.text) ?? 0;
        final invoiceTotal = (subtotal - discountValue)
            .clamp(0, subtotal)
            .toDouble();
        final selectedParty = _parties.firstWhere(
          (item) => item['id']?.toString() == partyId,
          orElse: () => const {},
        );
        final selectedCreditLimit =
            (selectedParty['creditLimit'] as num?)?.toDouble() ?? 0;
        final selectedDebt =
            (selectedParty['receivableBalance'] as num?)?.toDouble() ?? 0;
        final draftDue = paymentStatus == 'paid'
            ? 0.0
            : paymentStatus == 'partial'
            ? (invoiceTotal - (double.tryParse(paid.text) ?? 0))
                  .clamp(0, invoiceTotal)
                  .toDouble()
            : invoiceTotal;
        final creditLimitMessage =
            invoiceType == 'sale' &&
                selectedCreditLimit > 0 &&
                (selectedDebt >= selectedCreditLimit - 0.009 ||
                    (draftDue > 0.009 &&
                        selectedDebt + draftDue >= selectedCreditLimit - 0.009))
            ? l.text(
                selectedDebt >= selectedCreditLimit - 0.009
                    ? 'وصل الزبون حد الدين. يسمح بالبيع النقدي فقط حتى تسديد جزء من الرصيد.'
                    : selectedDebt + draftDue > selectedCreditLimit + 0.009
                    ? 'سيتم إيقاف الفاتورة الآجلة لأنها تتجاوز حد دين الزبون.'
                    : 'ستصل هذه الفاتورة إلى حد الدين؛ بعدها سيتوقف البيع الآجل حتى تسديد جزء من الرصيد.',
                selectedDebt >= selectedCreditLimit - 0.009
                    ? 'The customer has reached the credit limit. Cash sales are still allowed.'
                    : selectedDebt + draftDue > selectedCreditLimit + 0.009
                    ? 'This invoice would exceed the customer credit limit.'
                    : 'This invoice reaches the credit limit. Further credit will stop until the balance is paid down.',
              )
            : null;

        Widget buildInvoiceContextFields() {
          final fields = <Widget>[
            if (!quickSale && _warehouses.isNotEmpty)
              DropdownButtonFormField<String>(
                initialValue: warehouseId,
                decoration: InputDecoration(
                  labelText: l.text('المخزن', 'Warehouse'),
                  prefixIcon: const Icon(Icons.warehouse_rounded),
                ),
                items: _warehouses
                    .where((warehouse) => warehouse['isActive'] != false)
                    .map(
                      (warehouse) => DropdownMenuItem(
                        value: warehouse['id']?.toString(),
                        child: Text(warehouse['name']?.toString() ?? ''),
                      ),
                    )
                    .toList(),
                onChanged: (value) =>
                    setDialogState(() => warehouseId = value),
              ),
            if (!quickSale && _warehouses.isEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  l.text(
                    'سيُستخدم المخزن الرئيسي تلقائيًا.',
                    'The main warehouse will be used automatically.',
                  ),
                ),
              ),
            if (invoiceType == 'sale' || !quickSale)
              InkWell(
                onTap: () async {
                  final selected = await _pickStoreEntry(
                    title: invoiceType == 'sale'
                        ? l.text('اختيار الزبون', 'Choose customer')
                        : l.text('اختيار المورد', 'Choose supplier'),
                    entries: allowedParties,
                    searchHint: l.text(
                      'ابحث بالاسم أو الهاتف',
                      'Search by name or phone',
                    ),
                    addLabel: l.text('إضافة حساب جديد', 'Add new account'),
                    onAdd: _addParty,
                  );
                  if (selected != null) {
                    setDialogState(() => partyId = selected['id']?.toString());
                  }
                },
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: invoiceType == 'sale'
                        ? paymentStatus == 'paid'
                              ? l.text('الزبون (اختياري)', 'Customer (optional)')
                              : l.text(
                                  'الزبون مطلوب للبيع الآجل',
                                  'Customer required for a balance due',
                                )
                        : l.text('المورد المطلوب', 'Required supplier'),
                    prefixIcon: const Icon(Icons.person_search_rounded),
                  ),
                  child: Text(
                    partyId == null
                        ? (invoiceType == 'sale'
                              ? l.text('زبون عام', 'General customer')
                              : l.text('اضغط للاختيار', 'Tap to choose'))
                        : allowedParties
                                  .firstWhere(
                                    (item) => item['id']?.toString() == partyId,
                                    orElse: () => const {},
                                  )['name']
                                  ?.toString() ??
                              '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ];

          if (fields.isEmpty) return const SizedBox.shrink();
          return LayoutBuilder(
            builder: (context, constraints) {
              final sideBySide =
                  constraints.maxWidth >= 720 &&
                  _warehouses.isNotEmpty &&
                  fields.length > 1;
              if (sideBySide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var index = 0; index < fields.length; index++) ...[
                      if (index > 0) const SizedBox(width: 12),
                      Expanded(child: fields[index]),
                    ],
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var index = 0; index < fields.length; index++) ...[
                    if (index > 0) const SizedBox(height: 10),
                    fields[index],
                  ],
                ],
              );
            },
          );
        }

        Future<void> scanIntoInvoice() async {
          final barcode = await _scanBarcode(
            title: l.text('قراءة باركود الصنف', 'Scan item barcode'),
            description: l.text(
              'امسح باركود المنتج ليتم إضافته للفاتورة مباشرة.',
              'Scan the product barcode to add it directly to the invoice.',
            ),
          );
          if (barcode == null) return;
          final match = findByBarcode(barcode);
          if (match == null) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    '${l.text('لا يوجد صنف بهذا الباركود', 'No item found with barcode')}: $barcode',
                  ),
                ),
              );
            }
            return;
          }
          setDialogState(
            () => addLine(
              Map<String, dynamic>.from(match['product'] as Map),
              match['unit'] is Map
                  ? Map<String, dynamic>.from(match['unit'] as Map)
                  : null,
            ),
          );
        }

        barcodeAction = scanIntoInvoice;
        Future<void> addManualInvoiceLine(StateSetter setDialogState) async {
          final nameController = TextEditingController();
          final skuController = TextEditingController();
          final barcodeController = TextEditingController();
          final minimumStockController = TextEditingController(text: '0');
          final quantityController = TextEditingController(text: '1');
          final priceController = TextEditingController(text: '0');
          final salePriceController = TextEditingController(text: '0');
          String unitName = 'piece';
          final formKey = GlobalKey<FormState>();
          final result = await showDialog<Map<String, dynamic>>(
            context: context,
            builder: (dialogContext) => StatefulBuilder(
              builder: (dialogContext, setDialogState) => AlertDialog(
                title: Text(l.text('إضافة صنف يدويًا', 'Add item manually')),
                content: SizedBox(
                  width: 460,
                  child: Form(
                    key: formKey,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextFormField(
                            controller: nameController,
                            autofocus: true,
                            decoration: InputDecoration(
                              labelText: l.text('اسم الصنف *', 'Item name *'),
                              prefixIcon: const Icon(
                                Icons.inventory_2_outlined,
                              ),
                            ),
                            validator: (value) => value?.trim().isEmpty == true
                                ? l.text(
                                    'أدخل اسم الصنف.',
                                    'Enter an item name.',
                                  )
                                : null,
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: skuController,
                            decoration: InputDecoration(
                              labelText: l.text(
                                'رمز الصنف (اختياري)',
                                'Item code (optional)',
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: barcodeController,
                            decoration: InputDecoration(
                              labelText: l.text(
                                'الباركود (اختياري)',
                                'Barcode (optional)',
                              ),
                              prefixIcon: const Icon(Icons.qr_code_2_rounded),
                            ),
                          ),
                          if (invoiceType == 'purchase') ...[
                            const SizedBox(height: 8),
                            TextFormField(
                              controller: minimumStockController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: InputDecoration(
                                labelText: l.text(
                                  'حد التنبيه للمخزون (0 لتعطيله)',
                                  'Low stock alert threshold (0 to disable)',
                                ),
                                helperText: l.text(
                                  'يظهر تنبيه عند وصول الكمية لهذا الحد أو أقل.',
                                  'Shows an alert when stock reaches this level.',
                                ),
                              ),
                              validator: (value) =>
                                  (double.tryParse(value ?? '') ?? -1) < 0
                                  ? l.text(
                                      'حد التنبيه يجب أن يكون صفرًا أو أكثر.',
                                      'Alert threshold must be zero or greater.',
                                    )
                                  : null,
                            ),
                          ],
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            initialValue: unitName,
                            decoration: InputDecoration(
                              labelText: l.text('الوحدة الأساسية', 'Base unit'),
                            ),
                            items: [
                              DropdownMenuItem(
                                value: 'piece',
                                child: Text(l.text('حبة', 'Piece')),
                              ),
                              DropdownMenuItem(
                                value: 'kg',
                                child: Text(l.text('كيلو', 'Kilogram')),
                              ),
                              DropdownMenuItem(
                                value: 'liter',
                                child: Text(l.text('لتر', 'Liter')),
                              ),
                              DropdownMenuItem(
                                value: 'box',
                                child: Text(l.text('صندوق', 'Box')),
                              ),
                            ],
                            onChanged: (value) => setDialogState(
                              () => unitName = value ?? 'piece',
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: quantityController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              labelText: l.text('الكمية *', 'Quantity *'),
                            ),
                            validator: (value) =>
                                (double.tryParse(value ?? '') ?? 0) <= 0
                                ? l.text(
                                    'الكمية يجب أن تكون أكبر من صفر.',
                                    'Quantity must be greater than zero.',
                                  )
                                : null,
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: priceController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              labelText: invoiceType == 'purchase'
                                  ? l.text(
                                      'سعر الشراء للوحدة *',
                                      'Purchase price per unit *',
                                    )
                                  : l.text(
                                      'سعر البيع للوحدة *',
                                      'Sale price per unit *',
                                    ),
                            ),
                            validator: (value) =>
                                (double.tryParse(value ?? '') ?? -1) < 0
                                ? l.text(
                                    'السعر غير صالح.',
                                    'Enter a valid price.',
                                  )
                                : null,
                          ),
                          if (invoiceType == 'purchase' &&
                              _permissions.canEditStorePrices) ...[
                            const SizedBox(height: 8),
                            TextFormField(
                              controller: salePriceController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: InputDecoration(
                                labelText: l.text(
                                  'سعر البيع الافتراضي (اختياري)',
                                  'Default sale price (optional)',
                                ),
                              ),
                              validator: (value) =>
                                  (double.tryParse(value ?? '') ?? 0) < 0
                                  ? l.text(
                                      'السعر غير صالح.',
                                      'Enter a valid price.',
                                    )
                                  : null,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: Text(l.text('إلغاء', 'Cancel')),
                  ),
                  FilledButton.icon(
                    onPressed: () {
                      if (!formKey.currentState!.validate()) return;
                      Navigator.pop(dialogContext, {
                        'productName': nameController.text.trim(),
                        'sku': skuController.text.trim(),
                        'barcode': barcodeController.text.trim(),
                        'minimumStock': invoiceType == 'purchase'
                            ? double.tryParse(minimumStockController.text) ?? 0
                            : 0,
                        'unitName': unitName,
                        'quantity': double.parse(quantityController.text),
                        'unitPrice': double.parse(priceController.text),
                        'salePrice':
                            invoiceType == 'purchase' &&
                                _permissions.canEditStorePrices
                            ? double.tryParse(salePriceController.text) ?? 0
                            : invoiceType == 'sale'
                            ? double.tryParse(priceController.text) ?? 0
                            : 0,
                      });
                    },
                    icon: const Icon(Icons.add_rounded),
                    label: Text(l.text('إضافة للفاتورة', 'Add to invoice')),
                  ),
                ],
              ),
            ),
          );
          nameController.dispose();
          skuController.dispose();
          barcodeController.dispose();
          minimumStockController.dispose();
          quantityController.dispose();
          priceController.dispose();
          salePriceController.dispose();
          if (result == null) return;
          final productRef = const Uuid().v4();
          final unitRef = const Uuid().v4();
          setDialogState(() {
            lines.add({
              ...result,
              'name': result['productName'],
              'manualEntry': true,
              'allowNegativeStock': quickSale && invoiceType == 'sale',
              'productClientRef': productRef,
              'unitClientRef': unitRef,
              'unitId': 'local:$unitRef',
            });
            lastScanFeedback = l.text(
              'أضيف الصنف للفاتورة وسيُسجل تلقائيًا عند الحفظ.',
              'The item was added and will be created when the invoice is saved.',
            );
            lastScanWasError = false;
          });
          unawaited(playCashierBeep());
        }

        void refreshPricesForType() {
          for (final line in lines) {
            if (line['manualEntry'] == true) {
              if (invoiceType == 'sale') {
                line['unitPrice'] = line['salePrice'] ?? line['unitPrice'] ?? 0;
              }
              continue;
            }
            final product = productById(line['productId']?.toString());
            final unit = _list(product['units']).firstWhere(
              (item) => item['id']?.toString() == line['unitId']?.toString(),
              orElse: () => firstUnit(product) ?? const <String, dynamic>{},
            );
            line['unitPrice'] = defaultPrice(product, unit);
            line['salePrice'] = defaultSalePrice(product, unit);
          }
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!quickSale)
              SegmentedButton<String>(
                segments: [
                  if (_permissions.canCreateStoreSales)
                    ButtonSegment(
                      value: 'sale',
                      label: Text(l.text('بيع', 'Sale')),
                    ),
                  if (_permissions.canCreateStorePurchases)
                    ButtonSegment(
                      value: 'purchase',
                      label: Text(l.text('شراء', 'Purchase')),
                    ),
                ],
                selected: {invoiceType},
                onSelectionChanged: (selection) {
                  setDialogState(() {
                    invoiceType = selection.first;
                    if (invoiceType == 'sale') {
                      partyId = generalCustomer?['id']?.toString();
                    } else {
                      partyId = null;
                    }
                    if (invoiceType == 'sale' &&
                        !_permissions.canEditStorePrices) {
                      discount.text = '0';
                    }
                    refreshPricesForType();
                  });
                },
              ),
            const SizedBox(height: 12),
            buildInvoiceContextFields(),
            if (creditLimitMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppTheme.error.withValues(alpha: 0.22),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: AppTheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        creditLimitMessage,
                        style: AppTheme.caption.copyWith(color: AppTheme.error),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (invoiceType == 'sale' &&
                selectedParty.isNotEmpty &&
                _permissions.canManageStoreDebts)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () async {
                    await _editPartyCreditLimit(selectedParty);
                    setDialogState(() {});
                  },
                  icon: const Icon(Icons.tune_rounded),
                  label: Text(l.text('تعديل حد الدين', 'Edit credit limit')),
                ),
              ),
            OutlinedButton.icon(
              onPressed: () async {
                final selected = await _pickStoreEntry(
                  title: l.text('اختيار المنتج', 'Choose product'),
                  entries: _products,
                  searchHint: l.text(
                    'ابحث بالاسم أو الباركود',
                    'Search by name or barcode',
                  ),
                  addLabel: l.text('إضافة منتج جديد', 'Add new product'),
                  onAdd: _addProduct,
                );
                if (selected != null) {
                  setDialogState(() {
                    addLine(selected, firstUnit(selected));
                  });
                }
              },
              icon: const Icon(Icons.add_shopping_cart_rounded),
              label: Text(l.text('بحث وإضافة منتج', 'Search and add product')),
            ),
            if (invoiceType == 'purchase' ||
                (quickSale &&
                    invoiceType == 'sale' &&
                    _permissions.canEditStorePrices)) ...[
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: () => addManualInvoiceLine(setDialogState),
                icon: const Icon(Icons.add_box_outlined),
                label: Text(
                  invoiceType == 'purchase'
                      ? l.text(
                          'إضافة صنف جديد للشراء',
                          'Add a new purchase item',
                        )
                      : l.text('بيع صنف غير مسجل', 'Sell an unlisted item'),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                l.text(
                  'F2 بحث • F4 قراءة باركود • ↑↓ للتنقل • Enter للإضافة • F6 حفظ',
                  'F2 search • F4 barcode • ↑↓ navigate • Enter add • F6 save',
                ),
                style: AppTheme.caption.copyWith(color: AppTheme.textSecondary),
              ),
            ),
            const SizedBox(height: 6),
            Autocomplete<Map<String, dynamic>>(
              displayStringForOption: (option) {
                final product = Map<String, dynamic>.from(
                  option['product'] as Map,
                );
                final unit = Map<String, dynamic>.from(option['unit'] as Map);
                return '${product['name'] ?? ''} • ${unit['name'] ?? ''}';
              },
              optionsBuilder: (value) {
                final query = _normalizeSearch(value.text);
                if (query.isEmpty) return const <Map<String, dynamic>>[];
                final options = <Map<String, dynamic>>[];
                for (final product in _products) {
                  for (final unit in _list(product['units'])) {
                    final searchable = _normalizeSearch(
                      [
                        product['name'],
                        product['sku'],
                        unit['name'],
                        unit['code'],
                        unit['barcode'],
                      ].whereType<Object>().join(' '),
                    );
                    if (searchable.contains(query)) {
                      options.add({'product': product, 'unit': unit});
                      if (options.length == 12) return options;
                    }
                  }
                }
                return options;
              },
              onSelected: (option) {
                setDialogState(
                  () => addLine(
                    Map<String, dynamic>.from(option['product'] as Map),
                    Map<String, dynamic>.from(option['unit'] as Map),
                  ),
                );
                autocompleteController?.clear();
                autocompleteFocusNode?.requestFocus();
              },
              optionsViewBuilder: (context, onSelected, options) {
                final entries = options.toList();
                return Align(
                  alignment: AlignmentDirectional.topStart,
                  child: Material(
                    elevation: 8,
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxHeight: 300,
                        maxWidth: 620,
                      ),
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final option = entries[index];
                          final product = Map<String, dynamic>.from(
                            option['product'] as Map,
                          );
                          final unit = Map<String, dynamic>.from(
                            option['unit'] as Map,
                          );
                          return ListTile(
                            selected:
                                AutocompleteHighlightedOption.of(context) ==
                                index,
                            title: Text(product['name']?.toString() ?? ''),
                            subtitle: Text(
                              '${unit['name'] ?? ''} • ${unit['barcode'] ?? ''}',
                            ),
                            trailing: Text(
                              _money(
                                unit['salePrice'] ??
                                    product['defaultSalePrice'],
                              ),
                            ),
                            onTap: () => onSelected(option),
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
              fieldViewBuilder:
                  (context, controller, focusNode, onFieldSubmitted) {
                    autocompleteController = controller;
                    autocompleteFocusNode = focusNode;
                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      decoration: InputDecoration(
                        labelText: l.text(
                          'بحث أو مسح باركود',
                          'Search or scan barcode',
                        ),
                        hintText: l.text(
                          'اكتب اسم الصنف أو امسح الباركود ثم Enter',
                          'Type an item or scan its barcode, then press Enter',
                        ),
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: controller.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: l.text('مسح', 'Clear'),
                                onPressed: controller.clear,
                                icon: const Icon(Icons.close_rounded),
                              ),
                      ),
                      onSubmitted: (value) {
                        final barcodeMatch = findByBarcode(value);
                        if (barcodeMatch != null) {
                          setDialogState(
                            () => addLine(
                              Map<String, dynamic>.from(
                                barcodeMatch['product'] as Map,
                              ),
                              barcodeMatch['unit'] is Map
                                  ? Map<String, dynamic>.from(
                                      barcodeMatch['unit'] as Map,
                                    )
                                  : null,
                            ),
                          );
                          controller.clear();
                          focusNode.requestFocus();
                        } else {
                          onFieldSubmitted();
                        }
                      },
                    );
                  },
            ),
            if (lastScanFeedback != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: (lastScanWasError ? AppTheme.error : AppTheme.success)
                      .withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      lastScanWasError
                          ? Icons.error_outline
                          : Icons.check_circle_outline,
                      size: 18,
                      color: lastScanWasError
                          ? AppTheme.error
                          : AppTheme.success,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        lastScanFeedback!,
                        style: AppTheme.caption.copyWith(
                          color: lastScanWasError
                              ? AppTheme.error
                              : AppTheme.success,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: scanIntoInvoice,
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: Text(l.text('إضافة بالباركود', 'Add by barcode')),
            ),
            const SizedBox(height: 12),
            _invoiceLinesEditor(
              lines: lines,
              invoiceType: invoiceType,
              setFormState: setDialogState,
            ),
            if (stockValidationMessages().isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppTheme.error.withValues(alpha: 0.22),
                  ),
                ),
                child: Text(
                  '${l.text('لا يمكن حفظ البيع قبل تصحيح الكميات:', 'Sale quantities exceed stock:')}\n${stockValidationMessages().join('\n')}',
                  style: AppTheme.caption.copyWith(color: AppTheme.error),
                ),
              ),
            ],
            const SizedBox(height: 10),
            if (quickSale ||
                (invoiceType == 'sale' && !_permissions.canEditStorePrices))
              InputDecorator(
                decoration: InputDecoration(
                  labelText: l.text('خصم', 'Discount'),
                ),
                child: Text(_money(0)),
              )
            else
              TextField(
                controller: discount,
                onChanged: (_) => setDialogState(() {}),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: l.text('خصم', 'Discount'),
                ),
              ),
            const SizedBox(height: 10),
            if (!quickSale)
              DropdownButtonFormField<String>(
                initialValue: paymentStatus,
                decoration: InputDecoration(
                  labelText: l.text('حالة الفاتورة', 'Invoice status'),
                ),
                items: [
                  DropdownMenuItem(
                    value: 'paid',
                    child: Text(l.text('مدفوعة بالكامل', 'Fully paid')),
                  ),
                  if (_permissions.canManageStoreDebts)
                    DropdownMenuItem(
                      value: 'partial',
                      child: Text(l.text('مدفوعة جزئيًا', 'Partially paid')),
                    ),
                  if (_permissions.canManageStoreDebts)
                    DropdownMenuItem(
                      value: 'debt',
                      child: Text(l.text('دين بالكامل', 'Full debt')),
                    ),
                ],
                onChanged: (value) => setDialogState(() {
                  paymentStatus = value ?? 'paid';
                  if (paymentStatus != 'partial') paid.text = '0';
                }),
              ),
            if (!quickSale && paymentStatus == 'partial') ...[
              const SizedBox(height: 10),
              TextField(
                controller: paid,
                onChanged: (_) => setDialogState(() {}),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: l.text('المبلغ المدفوع', 'Amount paid'),
                ),
              ),
            ],
            if (quickSale || paymentStatus != 'debt') ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: paymentMethodId,
                decoration: InputDecoration(
                  labelText: l.text('طريقة الدفع', 'Payment method'),
                  prefixIcon: const Icon(Icons.payments_rounded),
                ),
                items: _activePaymentMethods
                    .map(
                      (method) => DropdownMenuItem(
                        value: method['id']?.toString(),
                        child: Text(method['name']?.toString() ?? ''),
                      ),
                    )
                    .toList(),
                onChanged: (value) =>
                    setDialogState(() => paymentMethodId = value),
              ),
            ],
            const SizedBox(height: 14),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                'الإجمالي: ${_money(invoiceTotal)}',
                style: AppTheme.h3,
              ),
            ),
          ],
        );
      },
    );

    if (accepted == true) {
      final subtotal = lines.fold<double>(
        0,
        (sum, line) =>
            sum +
            (((line['quantity'] as num?)?.toDouble() ?? 0) *
                ((line['unitPrice'] as num?)?.toDouble() ?? 0)),
      );
      final discountValue = double.tryParse(discount.text) ?? 0;
      final invoiceTotal = (subtotal - discountValue)
          .clamp(0, subtotal)
          .toDouble();
      final paidAmount = paymentStatus == 'paid'
          ? invoiceTotal
          : paymentStatus == 'partial'
          ? double.tryParse(paid.text) ?? 0
          : 0.0;
      if (_warehouses.isEmpty && _permissions.canManageStoreInventory) {
        await _store.queueWarehouse(
          userId: _userId,
          name: 'المخزن الرئيسي',
          code: 'MAIN',
          isDefault: true,
        );
        await _showLocalThenSync(sync: false);
      }
      final selectedParty = _parties.firstWhere(
        (party) => party['id']?.toString() == partyId,
        orElse: () => const <String, dynamic>{},
      );
      final selectedWarehouse = _warehouses.firstWhere(
        (warehouse) => warehouse['id']?.toString() == warehouseId,
        orElse: () => _warehouses.firstWhere(
          (warehouse) => warehouse['isDefault'] == true,
          orElse: () => _warehouses.isNotEmpty ? _warehouses.first : const {},
        ),
      );
      final invoiceWarehouseId =
          warehouseId ?? selectedWarehouse['id']?.toString();
      final selectedPaymentMethod = _activePaymentMethods.firstWhere(
        (method) => method['id']?.toString() == paymentMethodId,
        orElse: () => const <String, dynamic>{},
      );
      final predictedStock = <String, double>{};
      for (final line in lines) {
        final id = line['productId']?.toString() ?? '';
        if (id.isEmpty) continue;
        final product = productById(id);
        final unit = _list(product['units']).firstWhere(
          (item) => item['id']?.toString() == line['unitId']?.toString(),
          orElse: () => firstUnit(product) ?? const <String, dynamic>{},
        );
        final factor = (unit['factorToBase'] as num?)?.toDouble() ?? 1;
        predictedStock.update(
          id,
          (quantity) =>
              quantity + ((line['quantity'] as num?)?.toDouble() ?? 0) * factor,
          ifAbsent: () =>
              ((line['quantity'] as num?)?.toDouble() ?? 0) * factor,
        );
      }
      final depletedNames = <String>[];
      final lowNames = <String>[];
      if (invoiceType == 'sale') {
        for (final line in lines.where(
          (line) => line['allowNegativeStock'] == true,
        )) {
          final manualName = line['productName']?.toString().trim() ?? '';
          if (manualName.isNotEmpty && !depletedNames.contains(manualName)) {
            depletedNames.add(manualName);
          }
        }
      }
      for (final entry in predictedStock.entries) {
        final product = productById(entry.key);
        final available = _availableStockForWarehouse(
          product,
          invoiceWarehouseId,
        );
        final remaining =
            available +
            (invoiceType == 'purchase' ? entry.value : -entry.value);
        if (invoiceType == 'sale' && remaining <= 0) {
          depletedNames.add(product['name']?.toString() ?? '');
        } else if (_productMinimumStock(product) > 0 &&
            remaining <= _productMinimumStock(product)) {
          lowNames.add(product['name']?.toString() ?? '');
        }
      }
      if (invoiceType == 'purchase') {
        for (final line in lines.where((line) => line['manualEntry'] == true)) {
          final threshold = (line['minimumStock'] as num?)?.toDouble() ?? 0;
          final received = (line['quantity'] as num?)?.toDouble() ?? 0;
          final name = line['productName']?.toString().trim() ?? '';
          if (threshold > 0 && received <= threshold && name.isNotEmpty) {
            lowNames.add(name);
          }
        }
      }
      lowNames.removeWhere(
        (name) => name.isEmpty || depletedNames.contains(name),
      );
      final uniqueLowNames = lowNames.toSet().toList();
      lowNames
        ..clear()
        ..addAll(uniqueLowNames);
      try {
        await _store.queueInvoice(
          userId: _userId,
          invoiceType: invoiceType,
          partyId: partyId,
          partyClientRef: selectedParty['clientRef']?.toString(),
          partyName:
              selectedParty['name']?.toString() ??
              (invoiceType == 'sale' ? 'زبون عام' : null),
          warehouseId: invoiceWarehouseId,
          warehouseClientRef: selectedWarehouse['clientRef']?.toString(),
          paidAmount: paidAmount,
          paymentMethod: selectedPaymentMethod['name']?.toString() ?? 'كاش',
          paymentMethodId: paymentStatus == 'debt' ? null : paymentMethodId,
          paymentMethodClientRef: paymentStatus == 'debt'
              ? null
              : selectedPaymentMethod['clientRef']?.toString(),
          discount: discountValue,
          items: lines
              .map(
                (line) => {
                  'productId': line['productId'],
                  'productClientRef': line['productClientRef'],
                  'productUnitId': line['unitId'],
                  'unitClientRef': line['unitClientRef'],
                  'quantity': (line['quantity'] as num?)?.toDouble() ?? 0,
                  'unitPrice': (line['unitPrice'] as num?)?.toDouble() ?? 0,
                  if (line['manualEntry'] == true) ...{
                    'manualEntry': true,
                    'allowNegativeStock': line['allowNegativeStock'] == true,
                    'productName': line['productName'],
                    'sku': line['sku'],
                    'unitName': line['unitName'],
                    'barcode': line['barcode'] ?? '',
                    'minimumStock':
                        (line['minimumStock'] as num?)?.toDouble() ?? 0,
                    'salePrice': (line['salePrice'] as num?)?.toDouble() ?? 0,
                  },
                  if (invoiceType == 'purchase')
                    'salePrice': (line['salePrice'] as num?)?.toDouble() ?? 0,
                },
              )
              .toList(),
          quickSale: quickSale,
          actorUserId: _userId,
          actorName: _actorName,
          canEditStorePrices: _permissions.canEditStorePrices,
          canManageStoreDebts: _permissions.canManageStoreDebts,
        );
        await _showLocalThenSync(sync: false);
        final selectedCreditLimit =
            (selectedParty['creditLimit'] as num?)?.toDouble() ?? 0;
        final currentCustomerDebt =
            (selectedParty['receivableBalance'] as num?)?.toDouble() ?? 0;
        final invoiceDue = invoiceTotal - paidAmount;
        if (mounted &&
            invoiceType == 'sale' &&
            invoiceDue > 0.009 &&
            selectedCreditLimit > 0 &&
            currentCustomerDebt + invoiceDue >= selectedCreditLimit - 0.009) {
          _showMessage(
            l.text(
              'تم الوصول إلى حد الدين لهذا الزبون. تم إيقاف البيع الآجل حتى تسديد جزء من الرصيد.',
              'The customer has reached the credit limit. Further credit is stopped until the balance is reduced.',
            ),
          );
        }
        if (ConnectivityService.instance.isOnline.value) {
          unawaited(_sync());
        }
      } catch (error) {
        if (mounted) {
          _showMessage(
            '${l.text('تعذر حفظ الفاتورة', 'Could not save the invoice')}: ${ErrorMessageService.sanitize(error)}',
          );
        }
      }
      if (mounted && (depletedNames.isNotEmpty || lowNames.isNotEmpty)) {
        final notices = <String>[
          if (depletedNames.isNotEmpty)
            '${l.text('نفد رصيد', 'Out of stock')}: ${depletedNames.join('، ')}',
          if (lowNames.isNotEmpty)
            '${l.text('أصبح منخفضًا', 'Low stock')}: ${lowNames.join('، ')}',
        ];
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(notices.join('\n')),
            action: SnackBarAction(
              label: l.text('مراجعة', 'Review'),
              onPressed: _openStockAlerts,
            ),
          ),
        );
      }
    }

    paid.dispose();
    discount.dispose();
  }

  Future<void> _recordInvoicePayment(Map<String, dynamic> invoice) async {
    final hiddenPurchase =
        invoice['type'] == 'purchase' && !_permissions.canViewStoreProfits;
    final due = (invoice['dueAmount'] as num?)?.toDouble() ?? 0;
    if ((!hiddenPurchase && due <= 0) || !_permissions.canManageStoreDebts) {
      return;
    }
    final amount = TextEditingController(
      text: hiddenPurchase ? '' : due.toStringAsFixed(2),
    );
    String? paymentMethodId = _activePaymentMethods.firstOrNull?['id']
        ?.toString();
    final l = context.loc;
    final accepted = await _openFullScreenForm(
      title:
          '${l.text('تسجيل دفعة', 'Record payment')} ${invoice['invoiceNumber']}',
      actionLabel: l.text('حفظ الدفعة', 'Save payment'),
      canSubmit: () =>
          (double.tryParse(amount.text) ?? 0) > 0 && paymentMethodId != null,
      builder: (context, setFormState) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: amount,
            onChanged: (_) => setFormState(() {}),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l.text('المبلغ المدفوع', 'Amount paid'),
              helperText: hiddenPurchase
                  ? l.text(
                      'أدخل المبلغ المطلوب سداده؛ سيتحقق النظام من الرصيد.',
                      'Enter the payment amount; the system will validate the balance.',
                    )
                  : '${l.text('المتبقي', 'Remaining')} ${_money(due)}',
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: paymentMethodId,
            decoration: InputDecoration(
              labelText: l.text('طريقة الدفع', 'Payment method'),
              prefixIcon: const Icon(Icons.payments_rounded),
            ),
            items: _activePaymentMethods
                .map(
                  (method) => DropdownMenuItem(
                    value: method['id']?.toString(),
                    child: Text(method['name']?.toString() ?? ''),
                  ),
                )
                .toList(),
            onChanged: (value) => setFormState(() => paymentMethodId = value),
          ),
        ],
      ),
    );
    final value = double.tryParse(amount.text) ?? 0;
    amount.dispose();
    if (accepted == true && value > 0) {
      final method = _activePaymentMethods.firstWhere(
        (item) => item['id']?.toString() == paymentMethodId,
        orElse: () => const <String, dynamic>{},
      );
      await _store.queuePayment(
        userId: _userId,
        invoiceId: invoice['id']?.toString(),
        invoiceClientRef: invoice['clientRef']?.toString(),
        partyId: invoice['partyId']?.toString(),
        partyClientRef: _parties
            .firstWhere(
              (party) =>
                  party['id']?.toString() == invoice['partyId']?.toString(),
              orElse: () => const <String, dynamic>{},
            )['clientRef']
            ?.toString(),
        direction: invoice['type'] == 'purchase' ? 'out' : 'in',
        amount: value,
        method: method['name']?.toString() ?? 'كاش',
        paymentMethodId: paymentMethodId,
        paymentMethodClientRef: method['clientRef']?.toString(),
        actorUserId: _userId,
        actorName: _actorName,
      );
      await _showLocalThenSync();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.loc;
    final workspace = _snapshot['workspace'] is Map
        ? Map<String, dynamic>.from(_snapshot['workspace'] as Map)
        : const <String, dynamic>{};
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        if (_permissions.canCreateStoreSales)
          const SingleActivator(LogicalKeyboardKey.f2): () =>
              unawaited(_createInvoice(quickSale: true)),
        if (_permissions.canCreateStoreSales ||
            _permissions.canCreateStorePurchases)
          const SingleActivator(LogicalKeyboardKey.f3): () =>
              unawaited(_createInvoice()),
        const SingleActivator(LogicalKeyboardKey.f5): () => unawaited(_sync()),
        const SingleActivator(LogicalKeyboardKey.digit1, alt: true): () =>
            _tabs.animateTo(0),
        const SingleActivator(LogicalKeyboardKey.digit2, alt: true): () =>
            _tabs.animateTo(1),
        const SingleActivator(LogicalKeyboardKey.digit3, alt: true): () =>
            _tabs.animateTo(2),
        const SingleActivator(LogicalKeyboardKey.digit4, alt: true): () =>
            _tabs.animateTo(3),
        const SingleActivator(LogicalKeyboardKey.digit5, alt: true): () =>
            _tabs.animateTo(4),
        const SingleActivator(LogicalKeyboardKey.digit6, alt: true): () =>
            _tabs.animateTo(5),
        if (_permissions.canManageStoreInventory && _tabs.index == 1)
          const SingleActivator(LogicalKeyboardKey.f7): () =>
              unawaited(_addProduct()),
        if (_permissions.canManageStoreInventory && _tabs.index == 2)
          const SingleActivator(LogicalKeyboardKey.f8): () =>
              unawaited(_addWarehouse()),
        if (_permissions.canManageStoreDebts && _tabs.index == 4)
          const SingleActivator(LogicalKeyboardKey.f9): () =>
              unawaited(_addParty()),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _focusCurrentSearch,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: AppTheme.background,
          appBar: AppBar(
            title: Text(
              workspace['name']?.toString() ??
                  l.text('إدارة المخزون', 'Inventory management'),
            ),
            actions: [
              IconButton(
                onPressed: _syncing ? null : _sync,
                icon: _syncing
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded),
              ),
              const QuickLogoutAction(),
            ],
            bottom: TabBar(
              controller: _tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(
                  text: l.text('الرئيسية', 'Dashboard'),
                  icon: const Icon(Icons.dashboard_rounded),
                ),
                Tab(
                  text: l.text('المخزون', 'Inventory'),
                  icon: const Icon(Icons.inventory_2_rounded),
                ),
                Tab(
                  text: l.text('المخازن', 'Warehouses'),
                  icon: const Icon(Icons.warehouse_rounded),
                ),
                Tab(
                  text: l.text('الفواتير', 'Invoices'),
                  icon: const Icon(Icons.receipt_long_rounded),
                ),
                Tab(
                  text: l.text('الحسابات', 'Accounts'),
                  icon: const Icon(Icons.people_alt_rounded),
                ),
                Tab(
                  text: l.text('التقارير', 'Reports'),
                  icon: const Icon(Icons.insights_rounded),
                ),
              ],
            ),
          ),
          drawer: AppSidebar.drawerFor(context),
          floatingActionButton:
              _tabs.index == 1 && _permissions.canManageStoreInventory
              ? FloatingActionButton.extended(
                  onPressed: _addProduct,
                  icon: const Icon(Icons.add),
                  label: Text(l.text('صنف جديد', 'New item')),
                )
              : _tabs.index == 2 && _permissions.canManageStoreInventory
              ? FloatingActionButton.extended(
                  onPressed: _addWarehouse,
                  icon: const Icon(Icons.add_business_rounded),
                  label: Text(l.text('مخزن جديد', 'New warehouse')),
                )
              : _tabs.index == 4 && _permissions.canManageStoreDebts
              ? FloatingActionButton.extended(
                  onPressed: _addParty,
                  icon: const Icon(Icons.person_add),
                  label: Text(l.text('حساب جديد', 'New account')),
                )
              : _tabs.index == 3 &&
                    (_permissions.canCreateStoreSales ||
                        _permissions.canCreateStorePurchases)
              ? FloatingActionButton.extended(
                  onPressed: () => _createInvoice(),
                  icon: const Icon(Icons.receipt_long),
                  label: Text(l.text('فاتورة جديدة', 'New invoice')),
                )
              : null,
          body: _loading
              ? const ShwakelPageLoadingContent()
              : ResponsiveScaffoldContainer(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      if (_error != null)
                        Text(
                          _error!,
                          style: const TextStyle(color: AppTheme.error),
                        ),
                      if (!ConnectivityService.instance.isOnline.value)
                        _offlineCashierNotice(),
                      if (_pending.isNotEmpty)
                        _pendingSyncNotice()
                      else if (_syncedAt.isNotEmpty)
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Chip(
                            avatar: const Icon(
                              Icons.verified_rounded,
                              size: 18,
                            ),
                            label: Text(
                              '${l.text('آخر مزامنة', 'Last sync')}: $_syncedAtLabel',
                            ),
                            backgroundColor: AppTheme.success.withValues(
                              alpha: 0.10,
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: TabBarView(
                          controller: _tabs,
                          children: [
                            _dashboard(),
                            _productsView(),
                            _warehousesView(),
                            _invoicesView(),
                            _partiesView(),
                            _reportsView(),
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

  Widget _dashboard() {
    final l = context.loc;
    final workspace = _snapshot['workspace'] is Map
        ? Map<String, dynamic>.from(_snapshot['workspace'] as Map)
        : const <String, dynamic>{};
    final cards = [
      (
        l.text('مبيعات اليوم', "Today's sales"),
        _money(_summary['salesToday']),
        Icons.point_of_sale,
      ),
      if (_permissions.canViewStoreProfits)
        (
          l.text('أرباح اليوم', "Today's profits"),
          _money(_summary['profitToday']),
          Icons.trending_up,
        ),
      if (_permissions.canViewStoreProfits)
        (
          l.text('قيمة المخزون', 'Inventory value'),
          _money(_summary['inventoryValue']),
          Icons.warehouse,
        ),
      if (_permissions.canManageStoreDebts || _permissions.canViewStoreReports)
        (
          l.text('ديون الزبائن', 'Customer debts'),
          _money(_summary['customerDebts']),
          Icons.person,
        ),
      if (_permissions.canManageStoreDebts || _permissions.canViewStoreReports)
        (
          l.text('ديون التجار', 'Supplier debts'),
          _money(_summary['supplierDebts']),
          Icons.local_shipping,
        ),
    ];
    return ListView(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final columns = width >= 980
                ? 3
                : width >= 360
                ? 2
                : 1;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: cards.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                mainAxisExtent: 116,
              ),
              itemBuilder: (context, index) {
                final card = cards[index];
                return ShwakelCard(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: AppTheme.primary.withValues(
                          alpha: 0.10,
                        ),
                        child: Icon(card.$3, color: AppTheme.primary),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              card.$1,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppTheme.caption.copyWith(
                                color: AppTheme.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              card.$2,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTheme.h3,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
        const SizedBox(height: 18),
        _storeQuickActions(),
        const SizedBox(height: 12),
        _stockAlertsPanel(),
        const SizedBox(height: 18),
        if (_permissions.canViewSubUsers) ...[
          ShwakelCard(
            child: ListTile(
              leading: const CircleAvatar(
                child: Icon(Icons.point_of_sale_rounded),
              ),
              title: Text(
                l.text('الموظفون والكاشير', 'Employees and cashiers'),
              ),
              subtitle: Text(
                l.text(
                  'أضف أكثر من كاشير وحدد البيع فقط أو صلاحيات المحل المناسبة لكل موظف.',
                  'Add multiple cashiers and assign sales-only or suitable store permissions to each employee.',
                ),
              ),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 18),
              onTap: () => Navigator.pushNamed(context, '/sub-users'),
            ),
          ),
          const SizedBox(height: 18),
        ],
        if (_permissions.canManageStoreInventory) ...[
          ShwakelCard(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.payments_rounded)),
              title: Text(l.text('طرق الدفع', 'Payment methods')),
              subtitle: Text(
                l.text(
                  'إضافة وحذف وترتيب الطرق الظاهرة في الفواتير والصيانة',
                  'Add, remove and arrange methods used in invoices and maintenance',
                ),
              ),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 18),
              onTap: _managePaymentMethods,
            ),
          ),
          const SizedBox(height: 18),
        ],
        if (_canImportStoreWorkbook) ...[
          ShwakelCard(
            child: ListTile(
              leading: const CircleAvatar(
                child: Icon(Icons.settings_backup_restore_rounded),
              ),
              title: Text(
                l.text(
                  'استعادة ملف بيانات كامل',
                  'Restore a full data workbook',
                ),
              ),
              subtitle: Text(
                l.text(
                  'استيراد أوراق المخازن والحسابات والأصناف والأرصدة والفواتير والدفعات بالترتيب، وفق صلاحياتك. يدعم ملف Excel المُصدّر من هذا النظام.',
                  'Import warehouses, accounts, items, stock, invoices, and payments in order, according to your permissions. Supports workbooks exported by this system.',
                ),
              ),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 18),
              onTap: _restoreStoreWorkbook,
            ),
          ),
          const SizedBox(height: 18),
        ],
        if (_permissions.canManagePublicStorefront) ...[
          ShwakelCard(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final enabled = workspace['publicEnabled'] == true;
                final status = enabled
                    ? l.text(
                        'متجرك ظاهر للعامة',
                        'Your store is visible to the public',
                      )
                    : l.text(
                        'متجرك غير ظاهر للعامة',
                        'Your store is not visible to the public',
                      );
                final details = enabled
                    ? l.text(
                        'سيظهر فقط المنتجات المفعلة للبيع العام وبكمياتها المتاحة.',
                        'Only products enabled for public sale will appear with their available quantities.',
                      )
                    : l.text(
                        'فعّل الظهور وحدد المنتجات المسموح بيعها أونلاين.',
                        'Enable visibility and specify the products allowed to be sold online.',
                      );
                final icon = CircleAvatar(
                  backgroundColor:
                      (enabled ? AppTheme.success : AppTheme.textTertiary)
                          .withValues(alpha: 0.14),
                  child: Icon(
                    enabled
                        ? Icons.storefront_rounded
                        : Icons.visibility_off_rounded,
                    color: enabled ? AppTheme.success : AppTheme.textTertiary,
                  ),
                );
                final text = Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(status, style: AppTheme.bodyBold),
                      const SizedBox(height: 6),
                      Text(
                        details,
                        style: AppTheme.caption.copyWith(height: 1.35),
                      ),
                    ],
                  ),
                );
                final action = FilledButton.icon(
                  onPressed: _editStorefront,
                  icon: const Icon(Icons.tune_rounded),
                  label: Text(l.text('إعداد المتجر', 'Store settings')),
                );
                if (constraints.maxWidth < 520) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [icon, const SizedBox(width: 12), text],
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: action,
                      ),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    icon,
                    const SizedBox(width: 12),
                    text,
                    const SizedBox(width: 12),
                    action,
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 18),
          _publicOrdersPanel(),
          const SizedBox(height: 18),
        ],
        Text(
          l.text(
            'الفاتورة هي مصدر المخزون والدين والربح',
            'The invoice is the source of inventory, debt, and profit',
          ),
          style: AppTheme.h3,
        ),
        const SizedBox(height: 6),
        Text(
          l.text(
            'الشراء يزيد المخزون ويحدث متوسط التكلفة ودين التاجر، والبيع يخصم المخزون ويحسب الربح ودين الزبون تلقائيًا.',
            'Purchase increases inventory and updates average cost and supplier debt, while sale decreases inventory and calculates profit and customer debt automatically.',
          ),
        ),
      ],
    );
  }

  Widget _storeQuickActions() {
    final l = context.loc;
    final actions = <Widget>[
      if (_permissions.canCreateStoreSales)
        FilledButton.icon(
          onPressed: () => unawaited(_createInvoice(quickSale: true)),
          icon: const Icon(Icons.point_of_sale_rounded),
          label: Text(l.text('بيع سريع • F2', 'Quick sale • F2')),
        ),
      if (_permissions.canCreateStoreSales)
        OutlinedButton.icon(
          onPressed: () => unawaited(_createInvoice(initialType: 'sale')),
          icon: const Icon(Icons.receipt_long_rounded),
          label: Text(l.text('فاتورة بيع', 'Sale invoice')),
        ),
      if (_permissions.canCreateStorePurchases)
        OutlinedButton.icon(
          onPressed: () => unawaited(_createInvoice(initialType: 'purchase')),
          icon: const Icon(Icons.add_shopping_cart_rounded),
          label: Text(l.text('فاتورة شراء', 'Purchase invoice')),
        ),
      if (_permissions.canManageStoreInventory)
        OutlinedButton.icon(
          onPressed: _addProduct,
          icon: const Icon(Icons.add_box_rounded),
          label: Text(l.text('إضافة صنف • F7', 'Add item • F7')),
        ),
      if (_permissions.canManageStoreInventory)
        OutlinedButton.icon(
          onPressed: _addWarehouse,
          icon: const Icon(Icons.warehouse_rounded),
          label: Text(l.text('إضافة مخزن • F8', 'Add warehouse • F8')),
        ),
      if (_permissions.canManageStoreDebts)
        OutlinedButton.icon(
          onPressed: _addParty,
          icon: const Icon(Icons.person_add_alt_rounded),
          label: Text(l.text('إضافة حساب • F9', 'Add account • F9')),
        ),
    ];
    return ShwakelCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.text('اختصارات وإجراءات سريعة', 'Quick actions'),
            style: AppTheme.h3,
          ),
          const SizedBox(height: 5),
          Text(
            l.text(
              'البيع والفواتير والأصناف والمخازن في مكان واحد.',
              'Open cashier, invoices, items, and warehouses from one place.',
            ),
            style: AppTheme.caption,
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ],
      ),
    );
  }

  Widget _stockAlertsPanel() {
    final l = context.loc;
    final outOfStock = _outOfStockProducts;
    final lowStock = _lowStockProducts;
    final attention = _stockAlerts;
    final hasAlerts = attention.isNotEmpty;
    final color = outOfStock.isNotEmpty ? AppTheme.error : AppTheme.warning;
    return ShwakelCard(
      color: hasAlerts
          ? color.withValues(alpha: 0.055)
          : AppTheme.success.withValues(alpha: 0.045),
      borderColor: color.withValues(alpha: hasAlerts ? 0.24 : 0.14),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: color.withValues(alpha: 0.12),
                child: Icon(
                  hasAlerts
                      ? Icons.inventory_rounded
                      : Icons.check_circle_rounded,
                  color: hasAlerts ? color : AppTheme.success,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasAlerts
                          ? l.text('تنبيهات المخزون', 'Stock alerts')
                          : l.text('المخزون مستقر', 'Stock is healthy'),
                      style: AppTheme.bodyBold,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      hasAlerts
                          ? l.text(
                              '${outOfStock.length} صنف نافد • ${lowStock.length} صنف وصل حد التنبيه',
                              '${outOfStock.length} out of stock • ${lowStock.length} at the alert threshold',
                            )
                          : l.text(
                              'لا توجد أصناف نافدة أو تحت حد التنبيه.',
                              'No items are out of stock or below their alert threshold.',
                            ),
                      style: AppTheme.caption,
                    ),
                  ],
                ),
              ),
              if (hasAlerts)
                FilledButton.tonalIcon(
                  onPressed: _openStockAlerts,
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: Text(l.text('مراجعة', 'Review')),
                ),
            ],
          ),
          if (hasAlerts) ...[
            const SizedBox(height: 10),
            ...attention.take(4).map((product) {
              final stock = _productStock(product);
              final minimum = _productMinimumStock(product);
              final unit = _unitName(product['baseUnit']?.toString() ?? '');
              final isOut = _isOutOfStock(product);
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  isOut
                      ? Icons.remove_shopping_cart_rounded
                      : Icons.warning_amber_rounded,
                  color: isOut ? AppTheme.error : AppTheme.warning,
                ),
                title: Text(product['name']?.toString() ?? ''),
                subtitle: Text(
                  '${l.text('المتوفر', 'Available')}: $stock $unit • ${l.text('حد التنبيه', 'Alert at')}: $minimum',
                ),
                trailing: _stockHealthChip(product),
                onTap: _openStockAlerts,
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _pendingSyncPanel({bool constrainHeight = true}) {
    final l = context.loc;
    final maxPanelHeight = (MediaQuery.sizeOf(context).height * 0.42)
        .clamp(260.0, 420.0)
        .toDouble();
    final panel = ShwakelCard(
      color: AppTheme.warning.withValues(alpha: 0.08),
      borderColor: AppTheme.warning.withValues(alpha: 0.24),
      child: SingleChildScrollView(
        child: ExpansionTile(
          initiallyExpanded: true,
          leading: const Icon(
            Icons.cloud_upload_rounded,
            color: AppTheme.warning,
          ),
          title: Text(
            '${_pending.length} ${l.text('عمليات محفوظة محليًا بانتظار المزامنة', 'operations saved locally awaiting sync')}',
          ),
          subtitle: Text(
            l.text(
              'يمكنك مراجعة كل عملية وحذف القديم أو الخاطئ فقط إذا كان يمنع المزامنة.',
              'You can review each operation and delete old or incorrect ones only if they are blocking sync.',
            ),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _syncing ? null : _sync,
                  icon: const Icon(Icons.sync_rounded),
                  label: Text(l.text('مزامنة الآن', 'Sync now')),
                ),
                OutlinedButton.icon(
                  onPressed: _syncing ? null : _clearPendingOperations,
                  icon: const Icon(Icons.delete_sweep_rounded),
                  label: Text(l.text('حذف كل القديم', 'Delete all old')),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ..._pending.map(_pendingOperationTile),
          ],
        ),
      ),
    );
    if (!constrainHeight) {
      return panel;
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxPanelHeight),
      child: panel,
    );
  }

  Widget _pendingSyncNotice() {
    final l = context.loc;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.20)),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_upload_rounded, color: AppTheme.warning),
              const SizedBox(width: 8),
              Text(
                l.text(
                  '${_pending.length} فواتير/عمليات لم تتم مزامنتها',
                  '${_pending.length} invoices/operations are not synced',
                ),
                style: AppTheme.bodyBold.copyWith(color: AppTheme.warning),
              ),
            ],
          ),
          TextButton.icon(
            onPressed: _openPendingSyncScreen,
            icon: const Icon(Icons.open_in_full_rounded),
            label: Text(l.text('فتح المزامنة', 'Open sync')),
          ),
        ],
      ),
    );
  }

  Widget _offlineCashierNotice() {
    final l = context.loc;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.20)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, color: AppTheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l.text(
                'الكاشير يعمل دون إنترنت. تُحفظ الفواتير على هذا الجهاز وتُزامن تلقائيًا عند عودة الاتصال.',
                'The cashier is working offline. Invoices are saved on this device and sync automatically when the connection returns.',
              ),
              style: AppTheme.caption,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openPendingSyncScreen() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => StatefulBuilder(
          builder: (routeContext, setRouteState) => Scaffold(
            backgroundColor: AppTheme.background,
            appBar: AppBar(
              title: Text(context.loc.text('مزامنة إدارة المحل', 'Store sync')),
              actions: [
                IconButton(
                  onPressed: () async {
                    await _sync();
                    if (routeContext.mounted) {
                      setRouteState(() {});
                    }
                  },
                  icon: const Icon(Icons.sync_rounded),
                ),
              ],
            ),
            body: ResponsiveScaffoldContainer(
              padding: const EdgeInsets.all(16),
              child: _pending.isEmpty
                  ? Center(
                      child: Text(
                        context.loc.text(
                          'لا توجد عمليات معلقة الآن.',
                          'No pending operations now.',
                        ),
                        style: AppTheme.bodyBold,
                      ),
                    )
                  : _pendingSyncPanel(constrainHeight: false),
            ),
          ),
        ),
      ),
    );
    if (mounted) {
      await _sync();
    }
  }

  Widget _pendingOperationTile(Map<String, dynamic> operation) {
    final entity = operation['entity']?.toString() ?? 'operation';
    final type = operation['type']?.toString() ?? '';
    final opId = operation['opId']?.toString() ?? '';
    final shortOpId = opId.length > 8 ? opId.substring(0, 8) : opId;
    final title = _operationTitle(operation);
    final description = _operationDescription(operation);
    final syncError = _syncErrorMessage(operation);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: AppTheme.warning.withValues(alpha: 0.12),
            child: Icon(_operationIcon(entity), color: AppTheme.warning),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTheme.bodyBold),
                const SizedBox(height: 4),
                Text(
                  '$entity/$type${shortOpId.isNotEmpty ? ' • $shortOpId' : ''}',
                  style: AppTheme.caption,
                ),
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: AppTheme.bodyAction.copyWith(height: 1.35),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (syncError.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.error.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppTheme.error.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Text(
                      syncError,
                      style: AppTheme.caption.copyWith(color: AppTheme.error),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: context.loc.text(
              'حذف هذه العملية',
              'Delete this operation',
            ),
            onPressed: _syncing
                ? null
                : () => unawaited(_deletePendingOperation(operation)),
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
    );
  }

  IconData _operationIcon(String entity) => switch (entity) {
    'product' => Icons.inventory_2_rounded,
    'invoice' => Icons.receipt_long_rounded,
    'party' => Icons.people_alt_rounded,
    'payment' => Icons.payments_rounded,
    'workspace' => Icons.storefront_rounded,
    'maintenance' => Icons.build_circle_rounded,
    _ => Icons.sync_problem_rounded,
  };

  String _operationTitle(Map<String, dynamic> operation) {
    final l = context.loc;
    final entity = operation['entity']?.toString() ?? '';
    if (entity == 'product') {
      return '${l.text('صنف', 'Item')}: ${operation['name'] ?? ''}'.trim();
    }
    if (entity == 'invoice') {
      return operation['invoiceType'] == 'purchase'
          ? l.text('فاتورة شراء معلقة', 'Pending purchase invoice')
          : l.text('فاتورة بيع معلقة', 'Pending sale invoice');
    }
    if (entity == 'party') {
      return '${l.text('حساب', 'Account')}: ${operation['name'] ?? ''}'.trim();
    }
    if (entity == 'payment') {
      return l.text('دفعة معلقة', 'Pending payment');
    }
    if (entity == 'workspace') {
      return l.text('تحديث إعدادات المتجر', 'Store settings update');
    }
    if (entity == 'maintenance') {
      final action = operation['action']?.toString() ?? '';
      return switch (action) {
        'create' => l.text('استلام صيانة معلّق', 'Pending maintenance receipt'),
        'add_part' => l.text(
          'سحب قطعة للصيانة معلّق',
          'Pending maintenance part usage',
        ),
        'remove_part' => l.text(
          'إرجاع قطعة صيانة معلّق',
          'Pending maintenance part return',
        ),
        'finalize' => l.text(
          'فاتورة صيانة معلّقة',
          'Pending maintenance invoice',
        ),
        'contact' => l.text(
          'تواصل عميل صيانة معلّق',
          'Pending maintenance contact',
        ),
        _ => l.text('تحديث صيانة معلّق', 'Pending maintenance update'),
      };
    }
    return l.text('عملية مزامنة معلقة', 'Pending sync operation');
  }

  String _operationDescription(Map<String, dynamic> operation) {
    final l = context.loc;
    final entity = operation['entity']?.toString() ?? '';
    if (entity == 'invoice') {
      final items = _list(operation['items']);
      return '${items.length} ${l.text('أصناف', 'items')} • ${l.text('مدفوع', 'paid')} ${_money(operation['paidAmount'])} • ${operation['paymentMethod'] ?? 'cash'}';
    }
    if (entity == 'product') {
      final units = _list(operation['units']);
      return units
          .map(
            (unit) =>
                '${unit['name'] ?? _unitName(unit['code']?.toString() ?? '')}: ${unit['factorToBase'] ?? 1}',
          )
          .join(l.text('، ', ', '));
    }
    if (entity == 'party') {
      return '${_partyTypeLabel(operation['partyType']?.toString())} • ${operation['phone'] ?? ''}';
    }
    if (entity == 'payment') {
      return '${l.text('المبلغ', 'Amount')} ${_money(operation['amount'])}';
    }
    if (entity == 'workspace') {
      return operation['name']?.toString() ?? '';
    }
    if (entity == 'maintenance') {
      final device = operation['deviceType']?.toString() ?? '';
      final customer = operation['customerName']?.toString() ?? '';
      final status = operation['status']?.toString() ?? '';
      return [
        customer,
        device,
        status,
      ].where((value) => value.isNotEmpty).join(' • ');
    }
    return '';
  }

  String _syncErrorMessage(Map<String, dynamic> operation) {
    final raw = operation['lastSyncError']?.toString().trim() ?? '';
    if (raw.isEmpty) return '';
    return ErrorMessageService.sanitize(raw);
  }

  String _partyTypeLabel(String? type) => switch (type) {
    'supplier' => context.loc.text('تاجر', 'Supplier'),
    'both' => context.loc.text('زبون وتاجر', 'Customer and supplier'),
    _ => context.loc.text('زبون', 'Customer'),
  };

  Widget _publicOrdersPanel() {
    final pendingCount = _publicOrders
        .where((order) => order['status']?.toString() == 'pending')
        .length;
    return ShwakelCard(
      child: ExpansionTile(
        initiallyExpanded: pendingCount > 0,
        leading: const Icon(
          Icons.shopping_bag_rounded,
          color: AppTheme.primary,
        ),
        title: Text(
          '${context.loc.text('طلبات المتجر العام', 'Public store orders')} ($pendingCount ${context.loc.text('بانتظار التأكيد', 'awaiting confirmation')})',
        ),
        subtitle: Text(
          context.loc.text(
            'تأكيد الطلب يخصم الكمية من المخزون، ثم يمكن تعليم الطلب كمرسل.',
            'Confirming the order deducts quantity from inventory, then the order can be marked as shipped.',
          ),
        ),
        children: _publicOrders.isEmpty
            ? [
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: Text(
                    context.loc.text(
                      'لا توجد طلبات عامة حاليًا.',
                      'No public orders currently.',
                    ),
                  ),
                ),
              ]
            : _publicOrders.map(_publicOrderTile).toList(),
      ),
    );
  }

  Widget _publicOrderTile(Map<String, dynamic> order) {
    final status = order['status']?.toString() ?? 'pending';
    final items = _list(order['items']);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppTheme.border),
        ),
        child: ListTile(
          title: Text(
            '${order['orderNumber'] ?? ''} • ${_publicOrderStatusLabel(status)}',
          ),
          subtitle: Text(
            '${items.map((item) => '${item['productName']} × ${item['quantity']}').join(context.loc.text('، ', ', '))}\n${context.loc.text('الإجمالي', 'Total')}: ${_money(order['total'])}',
          ),
          isThreeLine: true,
          trailing: PopupMenuButton<String>(
            onSelected: (action) =>
                unawaited(_updatePublicOrder(order['id'].toString(), action)),
            itemBuilder: (context) => [
              if (status == 'pending')
                PopupMenuItem(
                  value: 'accept',
                  child: Text(context.loc.text('تأكيد', 'Confirm')),
                ),
              if (status == 'accepted')
                PopupMenuItem(
                  value: 'ship',
                  child: Text(context.loc.text('تم الإرسال', 'Shipped')),
                ),
              if (status == 'pending' || status == 'accepted')
                PopupMenuItem(
                  value: 'cancel',
                  child: Text(context.loc.text('إلغاء', 'Cancel')),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _publicOrderStatusLabel(String status) {
    return switch (status) {
      'accepted' => context.loc.text('مؤكد', 'Confirmed'),
      'shipped' => context.loc.text('مرسل', 'Shipped'),
      'received' => context.loc.text('مستلم', 'Received'),
      'cancelled' => context.loc.text('ملغي', 'Cancelled'),
      _ => context.loc.text('بانتظار التأكيد', 'Awaiting confirmation'),
    };
  }

  Widget _warehousesView() {
    final l = context.loc;
    return ListView(
      children: [
        Text(
          l.text('المخازن والأرصدة', 'Warehouses and balances'),
          style: AppTheme.h3,
        ),
        const SizedBox(height: 6),
        Text(
          l.text(
            'كل شراء أو بيع مرتبط بمخزن، والتحويل يحفظ أثرًا تدقيقيًا دون تغيير إجمالي المخزون.',
            'Every purchase and sale is assigned to a warehouse; transfers are fully auditable.',
          ),
          style: AppTheme.caption,
        ),
        const SizedBox(height: 12),
        ..._warehouses.map((warehouse) {
          final id = warehouse['id']?.toString();
          final stockedProducts = _products
              .where(
                (product) => _list(product['warehouseStocks']).any(
                  (stock) =>
                      stock['warehouseId']?.toString() == id &&
                      ((stock['quantity'] as num?)?.toDouble() ?? 0) != 0,
                ),
              )
              .length;
          final value = _products.fold<double>(0, (sum, product) {
            final stock = _list(product['warehouseStocks']).firstWhere(
              (item) => item['warehouseId']?.toString() == id,
              orElse: () => const {},
            );
            return sum +
                ((stock['quantity'] as num?)?.toDouble() ?? 0) *
                    ((product['averagePurchaseCost'] as num?)?.toDouble() ?? 0);
          });
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ShwakelCard(
              child: ListTile(
                leading: CircleAvatar(
                  child: Icon(
                    warehouse['isDefault'] == true
                        ? Icons.storefront_rounded
                        : Icons.warehouse_rounded,
                  ),
                ),
                title: Text(
                  '${warehouse['name'] ?? ''}${warehouse['isDefault'] == true ? ' • ${l.text('افتراضي', 'Default')}' : ''}',
                ),
                subtitle: Text(
                  '${l.text('أصناف برصيد', 'Stocked items')}: $stockedProducts • ${l.text('القيمة', 'Value')}: ${_money(value)}',
                ),
                trailing: warehouse['isActive'] == false
                    ? const Icon(Icons.pause_circle_outline)
                    : null,
              ),
            ),
          );
        }),
        if (_permissions.canManageStoreInventory) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _addWarehouse,
            icon: const Icon(Icons.add_business_rounded),
            label: Text(l.text('إضافة مخزن', 'Add warehouse')),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _importWarehousesFile,
            icon: const Icon(Icons.upload_file_rounded),
            label: Text(l.text('استيراد المخازن', 'Import warehouses')),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _warehouses.length < 2 ? null : _transferStock,
            icon: const Icon(Icons.swap_horiz_rounded),
            label: Text(l.text('تحويل بضاعة بين المخازن', 'Transfer stock')),
          ),
        ],
      ],
    );
  }

  Future<void> _addWarehouse() async {
    final name = TextEditingController();
    final code = TextEditingController();
    final notes = TextEditingController();
    final accepted = await _openFullScreenForm(
      title: context.loc.text('إضافة مخزن', 'Add warehouse'),
      actionLabel: context.loc.text('حفظ المخزن', 'Save warehouse'),
      canSubmit: () => name.text.trim().isNotEmpty,
      builder: (_, setState) => Column(
        children: [
          TextField(
            controller: name,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: context.loc.text('اسم المخزن *', 'Warehouse name *'),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: code,
            decoration: InputDecoration(
              labelText: context.loc.text('رمز اختياري', 'Optional code'),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: notes,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: context.loc.text('ملاحظات', 'Notes'),
            ),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await _store.queueWarehouse(
        userId: _userId,
        name: name.text,
        code: code.text,
        notes: notes.text,
      );
      await _showLocalThenSync();
    }
    name.dispose();
    code.dispose();
    notes.dispose();
  }

  Future<void> _transferStock() async {
    String? fromId = _warehouses.first['id']?.toString();
    String? toId = _warehouses.length > 1
        ? _warehouses[1]['id']?.toString()
        : null;
    final quantity = TextEditingController(text: '1');
    Map<String, dynamic>? product;
    final accepted = await _openFullScreenForm(
      title: context.loc.text('تحويل بين المخازن', 'Warehouse transfer'),
      actionLabel: context.loc.text('تأكيد التحويل', 'Confirm transfer'),
      canSubmit: () =>
          product != null &&
          fromId != null &&
          toId != null &&
          fromId != toId &&
          (double.tryParse(quantity.text) ?? 0) > 0,
      builder: (_, setState) => Column(
        children: [
          DropdownButtonFormField<String>(
            initialValue: fromId,
            decoration: InputDecoration(
              labelText: context.loc.text('من مخزن', 'From warehouse'),
            ),
            items: _warehouses
                .map(
                  (w) => DropdownMenuItem(
                    value: w['id']?.toString(),
                    child: Text(w['name']?.toString() ?? ''),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => fromId = value),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: toId,
            decoration: InputDecoration(
              labelText: context.loc.text('إلى مخزن', 'To warehouse'),
            ),
            items: _warehouses
                .map(
                  (w) => DropdownMenuItem(
                    value: w['id']?.toString(),
                    child: Text(w['name']?.toString() ?? ''),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => toId = value),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () async {
              final selected = await _pickStoreEntry(
                title: context.loc.text('اختيار الصنف', 'Choose item'),
                entries: _products,
                searchHint: context.loc.text('ابحث باسم الصنف', 'Search item'),
                addLabel: context.loc.text('إضافة صنف جديد', 'Add new item'),
                onAdd: _addProduct,
              );
              if (selected != null) setState(() => product = selected);
            },
            icon: const Icon(Icons.search_rounded),
            label: Text(
              product?['name']?.toString() ??
                  context.loc.text('اختيار الصنف', 'Choose item'),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: quantity,
            onChanged: (_) => setState(() {}),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: context.loc.text(
                'الكمية بالوحدة الأساسية',
                'Quantity in base unit',
              ),
            ),
          ),
        ],
      ),
    );
    if (accepted == true && product != null) {
      final unit = _list(product!['units']).firstWhere(
        (item) => item['isBase'] == true,
        orElse: () => _list(product!['units']).isNotEmpty
            ? _list(product!['units']).first
            : const {},
      );
      await _store.queueStockTransfer(
        userId: _userId,
        fromWarehouseId: fromId!,
        toWarehouseId: toId!,
        items: [
          {
            'productId': product!['id'],
            'productUnitId': unit['id'],
            'quantity': double.tryParse(quantity.text) ?? 0,
          },
        ],
      );
      await _showLocalThenSync();
    }
    quantity.dispose();
  }

  Widget _productsView() {
    final searchedProducts = _filterProducts(_products, _productSearchQuery);
    final products = switch (_stockAlertFilter) {
      'out' => searchedProducts.where(_isOutOfStock).toList(),
      'low' => searchedProducts.where(_isLowStock).toList(),
      'all' => searchedProducts.where(_needsStockAttention).toList(),
      _ => searchedProducts,
    };
    return Column(
      children: [
        if (_permissions.canManageStoreInventory) ...[
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _exportWorkspaceExcel,
                  icon: const Icon(Icons.download_rounded),
                  label: Text(
                    context.loc.text('تصدير بيانات المحل', 'Export store data'),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _exportProductsExcel,
                  icon: const Icon(Icons.inventory_2_outlined),
                  label: Text(
                    context.loc.text('تصدير الأصناف', 'Export items'),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _importProductsFile,
                  icon: const Icon(Icons.upload_file_rounded),
                  label: Text(
                    context.loc.text(
                      'استيراد Excel أو CSV',
                      'Import Excel/CSV',
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _downloadProductsTemplate,
                  icon: const Icon(Icons.description_outlined),
                  label: Text(
                    context.loc.text('نموذج الاستيراد', 'Import template'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              context.loc.text(
                'إذا احتوى الملف على عمود الكمية الحالية فسيُضبط رصيد الصنف في المخزن الافتراضي بتسوية موثقة. بدون هذا العمود تُستورد بيانات الأصناف فقط. لا تستورد فواتير شراء سابقة لنفس رصيد البداية.',
                'If the file has a current quantity column, the default warehouse balance is set through an audited adjustment. Without it, only item details are imported. Do not reimport purchase invoices already included in that opening stock.',
              ),
              style: AppTheme.caption,
            ),
          ),
          const SizedBox(height: 10),
        ],
        _searchField(
          controller: _productSearchController,
          focusNode: _productSearchFocusNode,
          label: context.loc.text('بحث في الأصناف', 'Search items'),
          hint: context.loc.text(
            'اسم الصنف أو الباركود أو الوحدة',
            'Item name, barcode, or unit',
          ),
          onChanged: (value) => setState(() => _productSearchQuery = value),
          onClear: () {
            _productSearchController.clear();
            setState(() => _productSearchQuery = '');
          },
        ),
        const SizedBox(height: 10),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterChip(
                selected: _stockAlertFilter == 'all',
                avatar: Icon(
                  _stockAlertFilter == 'all'
                      ? Icons.filter_alt
                      : Icons.warning_amber_rounded,
                  size: 18,
                ),
                label: Text(
                  '${context.loc.text('تنبيهات المخزون', 'Stock alerts')} (${_stockAlerts.length})',
                ),
                onSelected: (selected) =>
                    setState(() => _stockAlertFilter = selected ? 'all' : null),
              ),
              FilterChip(
                selected: _stockAlertFilter == 'out',
                avatar: const Icon(
                  Icons.remove_shopping_cart_outlined,
                  size: 18,
                ),
                label: Text(
                  '${context.loc.text('نافد', 'Out')} ${_outOfStockProducts.length}',
                ),
                onSelected: _outOfStockProducts.isEmpty
                    ? null
                    : (selected) => setState(
                        () => _stockAlertFilter = selected ? 'out' : null,
                      ),
              ),
              FilterChip(
                selected: _stockAlertFilter == 'low',
                avatar: const Icon(Icons.warning_amber_rounded, size: 18),
                label: Text(
                  '${context.loc.text('منخفض', 'Low')} ${_lowStockProducts.length}',
                ),
                onSelected: _lowStockProducts.isEmpty
                    ? null
                    : (selected) => setState(
                        () => _stockAlertFilter = selected ? 'low' : null,
                      ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _products.isEmpty
              ? _empty(context.loc.text('لا توجد أصناف بعد', 'No items yet'))
              : products.isEmpty
              ? _empty(
                  context.loc.text(
                    'لا توجد أصناف مطابقة للبحث',
                    'No matching items',
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) => constraints.maxWidth >= 850
                      ? _productsTable(products)
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: 96),
                          itemCount: products.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final item = products[index];
                            final unit = _unitName(
                              item['baseUnit']?.toString() ?? '',
                            );
                            return ShwakelCard(
                              padding: const EdgeInsets.all(14),
                              borderColor: _needsStockAttention(item)
                                  ? _stockHealthColor(
                                      item,
                                    ).withValues(alpha: 0.28)
                                  : item['publicVisible'] == true
                                  ? AppTheme.success.withValues(alpha: 0.22)
                                  : null,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      const CircleAvatar(
                                        child: Icon(Icons.inventory_2),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              item['name']?.toString() ?? '',
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: AppTheme.bodyBold,
                                            ),
                                            Text(
                                              '${context.loc.text('المتوفر', 'Available')}: ${item['stockQuantity'] ?? 0} $unit • ${_money(item['defaultSalePrice'])}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: AppTheme.caption,
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (_permissions.canManageStoreInventory)
                                        _productActionsMenu(item),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 6,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      _stockHealthChip(item),
                                      Text(
                                        '${context.loc.text('حد التنبيه', 'Minimum')}: ${_productMinimumStock(item)}',
                                        style: AppTheme.caption,
                                      ),
                                      if (item['publicVisible'] == true)
                                        Text(
                                          context.loc.text(
                                            'ظاهر للعامة',
                                            'Public',
                                          ),
                                        ),
                                      if (item['publicAllowOnlineSale'] == true)
                                        Text(
                                          context.loc.text(
                                            'بيع أونلاين',
                                            'Online sale',
                                          ),
                                        ),
                                      Text(
                                        _syncLabel(item),
                                        style: AppTheme.caption,
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
        ),
      ],
    );
  }

  Widget _productsTable(List<Map<String, dynamic>> products) {
    final l = context.loc;
    return _tableScroller(
      DataTable(
        headingRowColor: WidgetStatePropertyAll(
          AppTheme.primary.withValues(alpha: 0.08),
        ),
        columns: [
          DataColumn(label: Text(l.text('الصنف', 'Item'))),
          DataColumn(label: Text(l.text('رمز الصنف', 'SKU'))),
          DataColumn(label: Text(l.text('الباركود', 'Barcode'))),
          DataColumn(label: Text(l.text('الوحدة', 'Unit'))),
          DataColumn(label: Text(l.text('الرصيد', 'Stock'))),
          DataColumn(label: Text(l.text('حد التنبيه', 'Minimum'))),
          DataColumn(label: Text(l.text('سعر البيع', 'Sale price'))),
          if (_permissions.canViewStoreProfits)
            DataColumn(label: Text(l.text('سعر الشراء', 'Cost price'))),
          DataColumn(label: Text(l.text('الحالة', 'Status'))),
          if (_permissions.canManageStoreInventory)
            DataColumn(label: Text(l.text('إجراءات', 'Actions'))),
        ],
        rows: products.map((product) {
          final units = _list(product['units']);
          final base = units.firstWhere(
            (unit) => unit['isBase'] == true,
            orElse: () =>
                units.isNotEmpty ? units.first : const <String, dynamic>{},
          );
          return DataRow(
            cells: [
              DataCell(Text(product['name']?.toString() ?? '')),
              DataCell(Text(product['sku']?.toString() ?? '')),
              DataCell(Text(base['barcode']?.toString() ?? '')),
              DataCell(Text(_unitName(product['baseUnit']?.toString() ?? ''))),
              DataCell(Text('${product['stockQuantity'] ?? 0}')),
              DataCell(Text('${product['minimumStock'] ?? 0}')),
              DataCell(Text(_money(product['defaultSalePrice']))),
              if (_permissions.canViewStoreProfits)
                DataCell(
                  Text(
                    _money(
                      base['purchasePrice'] ?? product['averagePurchaseCost'],
                    ),
                  ),
                ),
              DataCell(
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _stockHealthChip(product),
                    const SizedBox(height: 3),
                    Text(_syncLabel(product), style: AppTheme.caption),
                  ],
                ),
              ),
              if (_permissions.canManageStoreInventory)
                DataCell(_productActionsMenu(product)),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _invoiceLinesEditor({
    required List<Map<String, dynamic>> lines,
    required String invoiceType,
    required StateSetter setFormState,
  }) {
    final l = context.loc;
    final canEditFutureSalePrice =
        invoiceType == 'purchase' && _permissions.canEditStorePrices;
    final unitPriceLabel = invoiceType == 'sale'
        ? l.text('سعر البيع', 'Sale price')
        : l.text('سعر الشراء', 'Purchase price');

    String lineKey(Map<String, dynamic> line) =>
        '${line['productId'] ?? line['productClientRef']}-${line['unitId'] ?? line['unitClientRef']}';

    double lineTotal(Map<String, dynamic> line) =>
        ((line['quantity'] as num?)?.toDouble() ?? 0) *
        ((line['unitPrice'] as num?)?.toDouble() ?? 0);

    Widget quantityField(Map<String, dynamic> line) => TextFormField(
      key: ValueKey('qty-${lineKey(line)}'),
      initialValue: ((line['quantity'] as num?)?.toDouble() ?? 1).toString(),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textAlign: TextAlign.center,
      decoration: InputDecoration(
        labelText: l.text('الكمية', 'Qty'),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 12,
        ),
      ),
      onChanged: (value) => setFormState(
        () => line['quantity'] = double.tryParse(value) ?? 0,
      ),
    );

    Widget unitPriceField(Map<String, dynamic> line) {
      if (invoiceType == 'sale' && !_permissions.canEditStorePrices) {
        return InputDecorator(
          decoration: InputDecoration(
            labelText: unitPriceLabel,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 12,
            ),
          ),
          child: Text(_money(line['unitPrice']), textAlign: TextAlign.center),
        );
      }
      return TextFormField(
        key: ValueKey('price-${lineKey(line)}'),
        initialValue:
            ((line['unitPrice'] as num?)?.toDouble() ?? 0).toStringAsFixed(2),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.center,
        decoration: InputDecoration(
          labelText: unitPriceLabel,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 12,
          ),
        ),
        onChanged: (value) => setFormState(
          () => line['unitPrice'] = double.tryParse(value) ?? 0,
        ),
      );
    }

    Widget futureSalePriceField(Map<String, dynamic> line) => TextFormField(
      key: ValueKey('sale-${lineKey(line)}'),
      initialValue:
          ((line['salePrice'] as num?)?.toDouble() ?? 0).toStringAsFixed(2),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textAlign: TextAlign.center,
      decoration: InputDecoration(
        labelText: l.text('سعر البيع لاحقًا', 'Future sale price'),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 12,
        ),
      ),
      onChanged: (value) => setFormState(
        () => line['salePrice'] = double.tryParse(value) ?? 0,
      ),
    );

    Widget totalBadge(Map<String, dynamic> line) => Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(_money(lineTotal(line)), style: AppTheme.bodyBold),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(l.text('أصناف الفاتورة', 'Invoice items'), style: AppTheme.bodyBold),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppTheme.surfaceVariant,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('${lines.length}'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (lines.isEmpty)
          Container(
            constraints: const BoxConstraints(minHeight: 76),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.surfaceVariant.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.border),
            ),
            child: Text(
              l.text('أضف صنفًا لتظهر تفاصيله هنا.', 'Add an item to see its details here.'),
              style: AppTheme.caption,
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 760) {
                return Scrollbar(
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      headingRowHeight: 44,
                      dataRowMinHeight: 66,
                      dataRowMaxHeight: 76,
                      horizontalMargin: 12,
                      columnSpacing: 18,
                      headingRowColor: WidgetStatePropertyAll(
                        AppTheme.primary.withValues(alpha: 0.07),
                      ),
                      columns: [
                        DataColumn(label: Text(l.text('الصنف', 'Item'))),
                        DataColumn(label: Text(l.text('الكمية', 'Qty')), numeric: true),
                        DataColumn(label: Text(unitPriceLabel), numeric: true),
                        if (canEditFutureSalePrice)
                          DataColumn(
                            label: Text(l.text('سعر البيع لاحقًا', 'Future sale price')),
                            numeric: true,
                          ),
                        DataColumn(label: Text(l.text('المجموع', 'Line total')), numeric: true),
                        DataColumn(label: Text(l.text('حذف', 'Remove'))),
                      ],
                      rows: lines.asMap().entries.map((entry) {
                        final index = entry.key;
                        final line = entry.value;
                        return DataRow(
                          cells: [
                            DataCell(
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 240),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      line['name']?.toString() ?? '',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppTheme.bodyBold,
                                    ),
                                    Text(
                                      line['unitName']?.toString() ?? '',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppTheme.caption,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            DataCell(SizedBox(width: 96, child: quantityField(line))),
                            DataCell(SizedBox(width: 132, child: unitPriceField(line))),
                            if (canEditFutureSalePrice)
                              DataCell(
                                SizedBox(width: 148, child: futureSalePriceField(line)),
                              ),
                            DataCell(
                              SizedBox(width: 128, child: totalBadge(line)),
                            ),
                            DataCell(
                              IconButton(
                                tooltip: l.text('حذف الصنف', 'Remove item'),
                                onPressed: () => setFormState(() => lines.removeAt(index)),
                                icon: const Icon(Icons.delete_outline_rounded),
                              ),
                            ),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
                );
              }

              return ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: lines.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final line = lines[index];
                  final fieldWidth = constraints.maxWidth >= 440
                      ? (constraints.maxWidth - 16) / 3
                      : (constraints.maxWidth - 8) / 2;
                  return Card(
                    margin: EdgeInsets.zero,
                    elevation: 0,
                    color: AppTheme.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: AppTheme.border),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      line['name']?.toString() ?? '',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppTheme.bodyBold,
                                    ),
                                    Text(line['unitName']?.toString() ?? '', style: AppTheme.caption),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: l.text('حذف الصنف', 'Remove item'),
                                visualDensity: VisualDensity.compact,
                                onPressed: () => setFormState(() => lines.removeAt(index)),
                                icon: const Icon(Icons.delete_outline_rounded),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              SizedBox(width: fieldWidth, child: quantityField(line)),
                              SizedBox(width: fieldWidth, child: unitPriceField(line)),
                              SizedBox(width: fieldWidth, child: totalBadge(line)),
                              if (canEditFutureSalePrice)
                                SizedBox(width: fieldWidth, child: futureSalePriceField(line)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
      ],
    );
  }

  Widget _tableScroller(Widget table) => Scrollbar(
    thumbVisibility: true,
    child: SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: table,
      ),
    ),
  );

  Future<void> _exportProductsExcel() async {
    final excel = Excel.createExcel();
    final sheet = excel['Inventory'];
    excel.setDefaultSheet('Inventory');
    if (excel.tables.containsKey('Sheet1')) excel.delete('Sheet1');

    final headers = [
      'اسم الصنف',
      'الوحدة الأساسية',
      if (_permissions.canViewStoreProfits) 'سعر الشراء',
      'سعر البيع',
      'الحد الأدنى',
      'الباركود',
      'الكمية الحالية',
      'رمز الصنف',
      'مرجع الصنف',
    ];
    sheet.appendRow(headers.map(TextCellValue.new).toList());
    for (final product in _products) {
      final units = _list(product['units']);
      final base = units.firstWhere(
        (unit) => unit['isBase'] == true,
        orElse: () =>
            units.isNotEmpty ? units.first : const <String, dynamic>{},
      );
      final row = <CellValue>[
        TextCellValue(product['name']?.toString() ?? ''),
        TextCellValue(product['baseUnit']?.toString() ?? ''),
        if (_permissions.canViewStoreProfits)
          DoubleCellValue(
            _spreadsheetDouble(
              base['purchasePrice'] ?? product['averagePurchaseCost'],
            ),
          ),
        DoubleCellValue(_spreadsheetDouble(product['defaultSalePrice'])),
        DoubleCellValue(_spreadsheetDouble(product['minimumStock'])),
        TextCellValue(base['barcode']?.toString() ?? ''),
        DoubleCellValue(_spreadsheetDouble(product['stockQuantity'])),
        TextCellValue(product['sku']?.toString() ?? ''),
        TextCellValue(product['clientRef']?.toString() ?? ''),
      ];
      sheet.appendRow(row);
    }

    for (var column = 0; column < headers.length; column++) {
      sheet.setColumnWidth(column, column == 0 ? 28 : 18);
      final headerCell = sheet.cell(
        CellIndex.indexByColumnRow(columnIndex: column, rowIndex: 0),
      );
      headerCell.cellStyle = CellStyle(
        bold: true,
        fontColorHex: ExcelColor.white,
        backgroundColorHex: ExcelColor.fromHexString('#0F766E'),
        horizontalAlign: HorizontalAlign.Center,
        verticalAlign: VerticalAlign.Center,
      );
    }
    sheet.setRowHeight(0, 26);
    final bytes = excel.encode();
    if (bytes == null) return;
    await FileSaver.instance.saveFile(
      name: 'inventory_${DateTime.now().toIso8601String().substring(0, 10)}',
      bytes: Uint8List.fromList(bytes),
      fileExtension: 'xlsx',
      mimeType: MimeType.microsoftExcel,
    );
  }

  Future<void> _exportWorkspaceExcel() async {
    final excel = Excel.createExcel();
    var exportSnapshot = _snapshot;
    var exportedCachedDataOnly = true;
    if (_permissions.canViewStoreReports ||
        _permissions.canManageStoreDebts ||
        _permissions.canViewStoreProfits) {
      try {
        final fullSnapshot = await _api.getStoreManagementSnapshot(
          includeFullHistory: true,
        );
        exportSnapshot = StoreManagementPrivacy.redactSnapshotForStaff(
          fullSnapshot,
          canViewProfits: _permissions.canViewStoreProfits,
        );
        exportedCachedDataOnly = false;
      } catch (_) {
        // Keep export available offline using the durable local snapshot.
      }
    }
    final exportProducts = _list(exportSnapshot['products']);
    final exportParties = _list(exportSnapshot['parties']);
    final exportWarehouses = _list(exportSnapshot['warehouses']);
    final exportInvoices = _list(exportSnapshot['invoices']);
    final exportPayments = _list(exportSnapshot['payments']);
    final exportPaymentMethods = _list(exportSnapshot['paymentMethods']);
    final purchaseInvoiceIds = exportInvoices
        .where((invoice) => invoice['type'] == 'purchase')
        .map((invoice) => invoice['id']?.toString())
        .whereType<String>()
        .toSet();

    void addSheet(
      String name,
      List<String> headers,
      Iterable<List<dynamic>> rows,
    ) {
      final sheet = excel[name];
      sheet.appendRow(headers.map(TextCellValue.new).toList());
      for (final row in rows) {
        sheet.appendRow(row.map(_spreadsheetCell).toList());
      }
      for (var column = 0; column < headers.length; column++) {
        sheet.setColumnWidth(column, column == 0 ? 24 : 17);
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: column, rowIndex: 0))
            .cellStyle = CellStyle(
          bold: true,
          fontColorHex: ExcelColor.white,
          backgroundColorHex: ExcelColor.fromHexString('#0F766E'),
          horizontalAlign: HorizontalAlign.Center,
          verticalAlign: VerticalAlign.Center,
        );
      }
      sheet.setRowHeight(0, 26);
    }

    addSheet(
      'Inventory',
      [
        'اسم الصنف',
        'الوحدة الأساسية',
        'الباركود',
        'سعر البيع',
        if (_permissions.canViewStoreProfits) 'سعر الشراء',
        'الحد الأدنى',
        'الرصيد الحالي',
        'رمز الصنف',
        'مرجع الصنف',
      ],
      exportProducts.map((product) {
        final units = _list(product['units']);
        final base = units.firstWhere(
          (unit) => unit['isBase'] == true,
          orElse: () =>
              units.isNotEmpty ? units.first : const <String, dynamic>{},
        );
        return [
          product['name'],
          product['baseUnit'],
          base['barcode'],
          product['defaultSalePrice'],
          if (_permissions.canViewStoreProfits)
            base['purchasePrice'] ?? product['averagePurchaseCost'],
          product['minimumStock'],
          product['stockQuantity'],
          product['sku'],
          product['clientRef'],
        ];
      }),
    );

    addSheet(
      'Product Units',
      [
        'مرجع الصنف',
        'اسم الصنف',
        'مرجع الوحدة',
        'اسم الوحدة',
        'رمز الوحدة',
        'المعامل إلى الأساسية',
        'أساسية',
        'الباركود',
        'سعر البيع',
        if (_permissions.canViewStoreProfits) 'سعر الشراء',
      ],
      exportProducts.expand(
        (product) => _list(product['units']).map(
          (unit) => [
            product['clientRef'],
            product['name'],
            unit['clientRef'],
            unit['name'],
            unit['code'],
            unit['factorToBase'],
            unit['isBase'],
            unit['barcode'],
            unit['salePrice'],
            if (_permissions.canViewStoreProfits) unit['purchasePrice'],
          ],
        ),
      ),
    );

    addSheet(
      'Accounts',
      [
        'مرجع الحساب',
        'نوع الحساب',
        'اسم الحساب',
        'الهاتف',
        'ملاحظات',
        'حد الدين',
        if (_permissions.canManageStoreDebts ||
            _permissions.canViewStoreReports)
          'له',
        if (_permissions.canViewStoreProfits) 'عليه',
        if (_permissions.canManageStoreDebts) 'حد الدين',
      ],
      (_permissions.canManageStoreDebts
              ? exportParties
              : const <Map<String, dynamic>>[])
          .map(
            (party) => [
              party['clientRef'],
              _partyTypeLabel(party['type']?.toString() ?? ''),
              party['name'],
              party['phone'],
              party['notes'],
              if (_permissions.canManageStoreDebts ||
                  _permissions.canViewStoreReports)
                party['receivableBalance'],
              if (_permissions.canViewStoreProfits) party['payableBalance'],
              if (_permissions.canManageStoreDebts) party['creditLimit'],
            ],
          ),
    );

    addSheet(
      'Warehouses',
      ['مرجع المخزن', 'اسم المخزن', 'الرمز', 'افتراضي', 'نشط', 'ملاحظات'],
      exportWarehouses.map(
        (warehouse) => [
          warehouse['clientRef'],
          warehouse['name'],
          warehouse['code'],
          warehouse['isDefault'],
          warehouse['isActive'],
          warehouse['notes'],
        ],
      ),
    );

    addSheet(
      'Warehouse Stocks',
      [
        'مرجع الصنف',
        'اسم الصنف',
        'مرجع المخزن',
        'اسم المخزن',
        'الكمية',
        'الحد الأدنى',
      ],
      exportProducts.expand(
        (product) => exportWarehouses.map((warehouse) {
          final stock = _list(product['warehouseStocks']).firstWhere(
            (item) =>
                item['warehouseId']?.toString() == warehouse['id']?.toString(),
            orElse: () => const <String, dynamic>{},
          );
          return [
            product['clientRef'],
            product['name'],
            warehouse['clientRef'],
            warehouse['name'],
            stock['quantity'] ?? 0,
            stock['minimumStock'] ?? product['minimumStock'],
          ];
        }),
      ),
    );

    addSheet(
      'Invoices',
      [
        'رقم الفاتورة',
        'مرجع الفاتورة',
        'النوع',
        'التاريخ',
        'الحساب',
        'المخزن',
        'المجموع',
        'الخصم',
        'الإجمالي',
        'المدفوع',
        'المتبقي',
        'طريقة الدفع',
        'حالة الدفع',
        'ملاحظات',
      ],
      exportInvoices.map(
        (invoice) => [
          invoice['invoiceNumber'],
          invoice['clientRef'],
          invoice['type'] == 'purchase' ? 'شراء' : 'بيع',
          invoice['occurredAt'],
          invoice['partyName'],
          invoice['warehouseName'],
          invoice['subtotal'],
          invoice['discount'],
          invoice['total'],
          invoice['paidAmount'],
          invoice['dueAmount'],
          invoice['paymentMethodName'],
          invoice['paymentStatus'],
          invoice['notes'],
        ],
      ),
    );

    addSheet(
      'Invoice Lines',
      [
        'رقم الفاتورة',
        'مرجع الفاتورة',
        'النوع',
        'التاريخ',
        'اسم الحساب',
        'المخزن',
        'المبلغ المدفوع',
        'الخصم',
        'طريقة الدفع',
        'ملاحظات',
        'الصنف',
        'الوحدة',
        'الكمية',
        'سعر الوحدة',
        'الإجمالي',
        'مرجع الصنف',
        'رمز الصنف',
        'مرجع الوحدة',
        'باركود الوحدة',
        if (_permissions.canViewStoreProfits) 'التكلفة',
        if (_permissions.canViewStoreProfits) 'الربح',
      ],
      exportInvoices.expand(
        (invoice) => _list(invoice['items']).map((line) {
          final product = exportProducts.firstWhere(
            (item) => item['id']?.toString() == line['productId']?.toString(),
            orElse: () => const <String, dynamic>{},
          );
          final unit = _list(product['units']).firstWhere(
            (item) =>
                item['id']?.toString() == line['productUnitId']?.toString(),
            orElse: () => const <String, dynamic>{},
          );
          return [
            invoice['invoiceNumber'],
            invoice['clientRef'],
            invoice['type'] == 'purchase' ? 'شراء' : 'بيع',
            invoice['occurredAt'],
            invoice['partyName'],
            invoice['warehouseName'],
            invoice['paidAmount'],
            invoice['discount'],
            invoice['paymentMethodName'],
            invoice['notes'],
            line['productName'],
            line['unitName'],
            line['quantity'],
            invoice['type'] == 'purchase' && !_permissions.canViewStoreProfits
                ? null
                : line['unitPrice'],
            invoice['type'] == 'purchase' && !_permissions.canViewStoreProfits
                ? null
                : line['lineTotal'],
            product['clientRef'],
            product['sku'],
            unit['clientRef'],
            unit['barcode'],
            if (_permissions.canViewStoreProfits) line['costTotal'],
            if (_permissions.canViewStoreProfits) line['profitTotal'],
          ];
        }),
      ),
    );

    addSheet(
      'Payments',
      [
        'التاريخ',
        'رقم الفاتورة',
        'الحساب',
        'الاتجاه',
        'طريقة الدفع',
        'المبلغ',
        'المرجع',
        'ملاحظات',
        'مرجع الدفعة',
      ],
      exportPayments
          .where((payment) {
            final invoiceId = payment['invoiceId']?.toString();
            return _permissions.canViewStoreProfits ||
                (payment['direction'] != 'out' &&
                    (invoiceId == null ||
                        !purchaseInvoiceIds.contains(invoiceId)));
          })
          .map(
            (payment) => [
              payment['occurredAt'],
              payment['invoiceNumber'],
              payment['partyName'],
              payment['direction'],
              payment['method'] ?? payment['paymentMethod'],
              payment['amount'],
              payment['reference'],
              payment['notes'],
              payment['clientRef'],
            ],
          ),
    );

    addSheet(
      'Payment Methods',
      ['مرجع الطريقة', 'اسم الطريقة', 'الترتيب', 'نشطة'],
      exportPaymentMethods.map(
        (method) => [
          method['clientRef'],
          method['name'],
          method['sortOrder'],
          method['isActive'],
        ],
      ),
    );

    excel.setDefaultSheet('Inventory');
    if (excel.tables.containsKey('Sheet1')) excel.delete('Sheet1');
    final bytes = excel.encode();
    if (bytes == null) return;
    await FileSaver.instance.saveFile(
      name: 'store_data_${DateTime.now().toIso8601String().substring(0, 10)}',
      bytes: Uint8List.fromList(bytes),
      fileExtension: 'xlsx',
      mimeType: MimeType.microsoftExcel,
    );
    if (!mounted) return;
    if (exportedCachedDataOnly) {
      _showMessage(
        context.loc.text(
          'تم تصدير البيانات المحفوظة على هذا الجهاز فقط؛ اتصل بالإنترنت لتصدير سجل الفواتير والدفعات الكامل.',
          'Exported data cached on this device only. Connect to the internet to export the complete invoice and payment history.',
        ),
      );
    }
  }

  CellValue _spreadsheetCell(dynamic value) {
    if (value is num) return DoubleCellValue(value.toDouble());
    if (value is bool) return TextCellValue(value ? 'نعم' : 'لا');
    return TextCellValue(value?.toString() ?? '');
  }

  Future<_SpreadsheetImportData?> _pickSpreadsheetRows({
    required int Function(List<String>) headerScore,
  }) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv', 'xlsx'],
      withData: true,
    );
    if (!mounted) return null;
    if (picked == null || picked.files.isEmpty) return null;
    final file = picked.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      _showMessage(
        context.loc.text('تعذر قراءة الملف.', 'Could not read the file.'),
      );
      return null;
    }
    try {
      if (file.extension?.toLowerCase() == 'xlsx') {
        final workbook = Excel.decodeBytes(bytes);
        final sheets = <String, _SpreadsheetSheetData>{};
        for (final entry in workbook.tables.entries) {
          final table = entry.value;
          if (table.rows.isEmpty) continue;
          final rows = table.rows
              .map(
                (row) =>
                    row.map((cell) => cell?.value?.toString() ?? '').toList(),
              )
              .toList();
          final headerIndex = StoreSpreadsheetHeaderDetection.findBestHeaderRow(
            rows: rows,
            score: headerScore,
          );
          if (headerIndex == null) continue;
          sheets[entry.key] = (
            headers: rows[headerIndex],
            rows: rows.skip(headerIndex + 1).toList(),
          );
        }
        final tables = sheets.entries.toList()
          ..sort(
            (a, b) => headerScore(
              b.value.headers,
            ).compareTo(headerScore(a.value.headers)),
          );
        final table = tables.firstOrNull?.value;
        if (table == null) {
          _showMessage(
            context.loc.text('ملف Excel فارغ.', 'The Excel file is empty.'),
          );
          return null;
        }
        return (headers: table.headers, rows: table.rows, sheets: sheets);
      }
      final contents = StoreSpreadsheetTextDecoder.decode(
        bytes,
        scoreText: (text) => _scoreCsvTextHeaders(text, headerScore),
      );
      final lines = const LineSplitter().convert(
        contents.replaceFirst('\uFEFF', ''),
      );
      if (lines.isEmpty) {
        return (
          headers: <String>[],
          rows: <List<String>>[],
          sheets: const <String, _SpreadsheetSheetData>{},
        );
      }
      final delimiter = _bestCsvDelimiter(lines.take(20).toList(), headerScore);
      final csvRows = lines
          .map((line) => _parseCsvLine(line, delimiter: delimiter))
          .toList();
      final headerIndex = StoreSpreadsheetHeaderDetection.findBestHeaderRow(
        rows: csvRows,
        score: headerScore,
      );
      if (headerIndex == null) {
        _showMessage(
          context.loc.text(
            'لم أجد صف عناوين في الملف.',
            'No header row was found in the file.',
          ),
        );
        return null;
      }
      final csvHeaders = csvRows[headerIndex];
      final dataRows = csvRows.skip(headerIndex + 1).toList();
      return (
        headers: csvHeaders,
        rows: dataRows,
        sheets: <String, _SpreadsheetSheetData>{
          'CSV': (headers: csvHeaders, rows: dataRows),
        },
      );
    } catch (error) {
      if (!mounted) return null;
      _showMessage(
        '${context.loc.text('تعذر قراءة الملف', 'Could not read the file')}: ${ErrorMessageService.sanitize(error)}',
      );
      return null;
    }
  }

  bool get _canImportStoreWorkbook =>
      _permissions.canManageStoreInventory ||
      _permissions.canManageStoreDebts ||
      _permissions.canCreateStoreSales ||
      _permissions.canCreateStorePurchases;

  _SpreadsheetImportData _importDataForSheet(
    _SpreadsheetImportData source,
    _SpreadsheetSheetData sheet,
  ) => (headers: sheet.headers, rows: sheet.rows, sheets: source.sheets);

  int _storeWorkbookHeaderScore(List<String> headers) {
    final scores = [
      headers
          .map(_canonicalInventoryHeader)
          .where(
            (header) => ['name', 'base_unit', 'sale_price'].contains(header),
          )
          .length,
      headers
          .map(_canonicalPartyHeader)
          .where((header) => ['name', 'type'].contains(header))
          .length,
      headers
          .map(_canonicalWarehouseHeader)
          .where((header) => ['name', 'code', 'client_ref'].contains(header))
          .length,
      headers
          .map(_canonicalInvoiceHeader)
          .where(
            (header) =>
                ['type', 'product', 'quantity', 'unit_price'].contains(header),
          )
          .length,
      headers
          .map(_canonicalWarehouseStockHeader)
          .where(
            (header) => [
              'product_ref',
              'product',
              'warehouse_ref',
              'warehouse',
              'quantity',
            ].contains(header),
          )
          .length,
    ];
    var best = 0;
    for (final score in scores) {
      if (score > best) best = score;
    }
    return best;
  }

  Future<void> _restoreStoreWorkbook() async {
    if (!_canImportStoreWorkbook) return;
    final l = context.loc;
    final source = await _pickSpreadsheetRows(
      headerScore: _storeWorkbookHeaderScore,
    );
    if (!mounted || source == null) return;

    final warehouseSheet = _permissions.canManageStoreInventory
        ? _bestSpreadsheetSheet(
            source.sheets,
            (headers) => headers
                .map(_canonicalWarehouseHeader)
                .where(
                  (header) => ['name', 'code', 'client_ref'].contains(header),
                )
                .length,
            minimumScore: 2,
          )
        : null;
    final accountSheet = _permissions.canManageStoreDebts
        ? _bestSpreadsheetSheet(
            source.sheets,
            (headers) => headers
                .map(_canonicalPartyHeader)
                .where((header) => ['name', 'type'].contains(header))
                .length,
            minimumScore: 2,
          )
        : null;
    final inventorySheet = _permissions.canManageStoreInventory
        ? _bestSpreadsheetSheet(
            source.sheets,
            (headers) => headers
                .map(_canonicalInventoryHeader)
                .where(
                  (header) =>
                      ['name', 'base_unit', 'sale_price'].contains(header),
                )
                .length,
            minimumScore: 3,
          )
        : null;
    final invoiceSheet =
        (_permissions.canCreateStoreSales ||
            _permissions.canCreateStorePurchases)
        ? _bestSpreadsheetSheet(
            source.sheets,
            (headers) => headers
                .map(_canonicalInvoiceHeader)
                .where(
                  (header) => [
                    'type',
                    'product',
                    'quantity',
                    'unit_price',
                  ].contains(header),
                )
                .length,
            minimumScore: 4,
          )
        : null;
    final warehouseStockSheet = _permissions.canManageStoreInventory
        ? _bestSpreadsheetSheet(
            source.sheets,
            (headers) => headers
                .map(_canonicalWarehouseStockHeader)
                .where(
                  (header) => [
                    'product_ref',
                    'product',
                    'warehouse_ref',
                    'warehouse',
                    'quantity',
                  ].contains(header),
                )
                .length,
            minimumScore: 4,
          )
        : null;
    final hasAggregateStock =
        inventorySheet != null &&
        inventorySheet.headers
            .map(_canonicalInventoryHeader)
            .contains('stock_quantity');
    final deferStockAdjustments =
        invoiceSheet != null &&
        _permissions.canManageStoreInventory &&
        (warehouseStockSheet != null || hasAggregateStock);

    final importCount = [
      warehouseSheet,
      accountSheet,
      inventorySheet,
      invoiceSheet,
    ].where((sheet) => sheet != null && sheet.rows.isNotEmpty).length;
    if (importCount == 0) {
      _showMessage(
        l.text(
          'لم أجد أوراقًا قابلة للاستيراد أو لا تسمح صلاحياتك بذلك.',
          'No importable sheets were found, or your permissions do not allow importing them.',
        ),
      );
      return;
    }

    final accepted = await _confirm(
      title: l.text('استعادة بيانات المحل', 'Restore store data'),
      message: l.text(
        'سيُقرأ المصنف مرة واحدة وتُعالج الأوراق المتاحة بالترتيب وفق صلاحياتك. تُطابق السجلات بالمراجع والرموز والأسماء، وتُتجاوز الفواتير المكررة. عند وجود الفواتير والأرصدة معًا، يعاد تشغيل الفواتير ثم يُضبط المخزون ليطابق الرصيد النهائي في الملف. الأرصدة الافتتاحية للحسابات لا تُنشأ من عمود الرصيد؛ تُعاد الأرصدة من الفواتير والدفعات المستوردة فقط.',
        'The workbook will be read once and available sheets processed in order under your permissions. Records are matched by references, codes, and names; duplicate invoices are skipped. When both invoices and stock balances are present, invoices replay first and stock is then reset to the final quantities in the file. Account opening balances are not created from balance columns; balances are rebuilt from imported invoices and payments only.',
      ),
      actionLabel: l.text('بدء الاستعادة', 'Start restore'),
    );
    if (accepted != true || !mounted) return;
    final restoreBatchId = const Uuid().v4();

    if (warehouseSheet != null && warehouseSheet.rows.isNotEmpty) {
      await _importWarehousesFile(
        selectedData: _importDataForSheet(source, warehouseSheet),
        confirmed: true,
        syncAfter: false,
      );
    }
    if (accountSheet != null && accountSheet.rows.isNotEmpty) {
      await _importPartiesFile(
        selectedData: _importDataForSheet(source, accountSheet),
        confirmed: true,
        syncAfter: false,
      );
    }
    if (inventorySheet != null && inventorySheet.rows.isNotEmpty) {
      await _importProductsFile(
        selectedData: _importDataForSheet(source, inventorySheet),
        confirmed: true,
        syncAfter: false,
        deferStockAdjustments: deferStockAdjustments,
      );
    }
    if (deferStockAdjustments && inventorySheet != null) {
      await _applyRestoredStockSnapshot(
        warehouseStockSheet: warehouseStockSheet,
        inventorySheet: inventorySheet,
        invoiceSheet: invoiceSheet,
        batchId: restoreBatchId,
        includeHistoricalSales: true,
      );
    }
    if (invoiceSheet != null && invoiceSheet.rows.isNotEmpty) {
      await _importInvoicesFile(
        selectedData: _importDataForSheet(source, invoiceSheet),
        confirmed: true,
        syncAfter: false,
      );
    }
    if (deferStockAdjustments && inventorySheet != null) {
      await _applyRestoredStockSnapshot(
        warehouseStockSheet: warehouseStockSheet,
        inventorySheet: inventorySheet,
        invoiceSheet: invoiceSheet,
        batchId: restoreBatchId,
        includeHistoricalSales: false,
        deferUntilNoPendingInvoices: true,
      );
    }
    if (!mounted) return;
    await _showLocalThenSync();
  }

  Future<void> _applyRestoredStockSnapshot({
    required _SpreadsheetSheetData? warehouseStockSheet,
    required _SpreadsheetSheetData inventorySheet,
    required _SpreadsheetSheetData? invoiceSheet,
    required String batchId,
    required bool includeHistoricalSales,
    bool deferUntilNoPendingInvoices = false,
  }) async {
    final targets =
        <
          String,
          ({
            Map<String, dynamic> product,
            Map<String, dynamic> warehouse,
            double quantity,
          })
        >{};

    void addTarget({
      required String productRef,
      required String productName,
      required String warehouseRef,
      required String warehouseName,
      required double quantity,
    }) {
      final product = _products.firstWhere(
        (item) =>
            (productRef.isNotEmpty &&
                item['clientRef']?.toString() == productRef) ||
            _normalizeSearch(item['name']?.toString() ?? '') ==
                _normalizeSearch(productName),
        orElse: () => const <String, dynamic>{},
      );
      final warehouse = _warehouses.firstWhere(
        (item) =>
            (warehouseRef.isNotEmpty &&
                item['clientRef']?.toString() == warehouseRef) ||
            (warehouseName.isNotEmpty &&
                _normalizeSearch(item['name']?.toString() ?? '') ==
                    _normalizeSearch(warehouseName)),
        orElse: () => _warehouses.firstWhere(
          (item) => item['isDefault'] == true,
          orElse: () => const <String, dynamic>{},
        ),
      );
      if (product.isEmpty || warehouse.isEmpty) return;
      final productKey = product['clientRef']?.toString() ?? product['id'];
      final warehouseKey =
          warehouse['clientRef']?.toString() ?? warehouse['id'];
      final key = '$productKey|$warehouseKey';
      targets[key] = (
        product: product,
        warehouse: warehouse,
        quantity: quantity,
      );
    }

    if (warehouseStockSheet != null) {
      final headers = warehouseStockSheet.headers
          .map(_canonicalWarehouseStockHeader)
          .toList();
      for (final row in warehouseStockSheet.rows) {
        String value(String key) {
          final index = headers.indexOf(key);
          return index >= 0 && index < row.length ? row[index].trim() : '';
        }

        final quantity = _parseSpreadsheetNumber(value('quantity'));
        if (quantity == null || quantity < 0) continue;
        addTarget(
          productRef: value('product_ref'),
          productName: value('product'),
          warehouseRef: value('warehouse_ref'),
          warehouseName: value('warehouse'),
          quantity: quantity,
        );
      }
    } else {
      final headers = inventorySheet.headers
          .map(_canonicalInventoryHeader)
          .toList();
      final stockIndex = headers.indexOf('stock_quantity');
      if (stockIndex >= 0) {
        final defaultWarehouse = _warehouses.firstWhere(
          (item) => item['isDefault'] == true,
          orElse: () => _warehouses.isNotEmpty
              ? _warehouses.first
              : const <String, dynamic>{},
        );
        if (defaultWarehouse.isNotEmpty) {
          for (final row in inventorySheet.rows) {
            String value(String key) {
              final index = headers.indexOf(key);
              return index >= 0 && index < row.length ? row[index].trim() : '';
            }

            final quantity = _parseSpreadsheetNumber(row[stockIndex]);
            if (quantity == null || quantity < 0) continue;
            addTarget(
              productRef: value('client_ref'),
              productName: value('name'),
              warehouseRef: defaultWarehouse['clientRef']?.toString() ?? '',
              warehouseName: defaultWarehouse['name']?.toString() ?? '',
              quantity: quantity,
            );
          }
        }
      }
    }

    final salesByWarehouseProduct = <String, double>{};
    if (includeHistoricalSales && invoiceSheet != null) {
      final headers = invoiceSheet.headers
          .map(_canonicalInvoiceHeader)
          .toList();
      for (final row in invoiceSheet.rows) {
        String value(String key) {
          final index = headers.indexOf(key);
          return index >= 0 && index < row.length ? row[index].trim() : '';
        }

        final type = _normalizeSearch(value('type'));
        if (type != 'sale' &&
            !type.contains('بيع') &&
            !type.contains('مبيعات')) {
          continue;
        }
        final productRef = value('product_ref');
        final productName = value('product');
        final product = _products.firstWhere(
          (item) =>
              (productRef.isNotEmpty &&
                  item['clientRef']?.toString() == productRef) ||
              _normalizeSearch(item['name']?.toString() ?? '') ==
                  _normalizeSearch(productName),
          orElse: () => const <String, dynamic>{},
        );
        final quantity = _parseSpreadsheetNumber(value('quantity'));
        if (product.isEmpty || quantity == null || quantity <= 0) continue;
        final units = _list(product['units']);
        final requestedUnitRef = value('unit_ref');
        final requestedUnit = _normalizeSearch(value('unit'));
        final unit = units.firstWhere(
          (item) =>
              (requestedUnitRef.isNotEmpty &&
                  item['clientRef']?.toString() == requestedUnitRef) ||
              (requestedUnit.isNotEmpty &&
                  (_normalizeSearch(item['name']?.toString() ?? '') ==
                          requestedUnit ||
                      _normalizeSearch(item['code']?.toString() ?? '') ==
                          requestedUnit)),
          orElse: () => units.firstWhere(
            (item) => item['isBase'] == true,
            orElse: () =>
                units.isNotEmpty ? units.first : const <String, dynamic>{},
          ),
        );
        final factor = (unit['factorToBase'] as num?)?.toDouble() ?? 1;
        final warehouseName = _normalizeSearch(value('warehouse'));
        final warehouse = _warehouses.firstWhere(
          (item) =>
              warehouseName.isNotEmpty &&
              _normalizeSearch(item['name']?.toString() ?? '') == warehouseName,
          orElse: () => _warehouses.firstWhere(
            (item) => item['isDefault'] == true,
            orElse: () => _warehouses.isNotEmpty
                ? _warehouses.first
                : const <String, dynamic>{},
          ),
        );
        if (warehouse.isEmpty) continue;
        final key =
            '${product['clientRef'] ?? product['id']}|${warehouse['clientRef'] ?? warehouse['id']}';
        salesByWarehouseProduct.update(
          key,
          (current) => current + quantity * factor,
          ifAbsent: () => quantity * factor,
        );
      }
    }

    for (final entry in targets.entries) {
      final target = entry.value;
      final product = target.product;
      final warehouse = target.warehouse;
      final baseUnit = _list(product['units']).firstWhere(
        (unit) => unit['isBase'] == true,
        orElse: () => _list(product['units']).isNotEmpty
            ? _list(product['units']).first
            : const <String, dynamic>{},
      );
      final quantity =
          target.quantity +
          (includeHistoricalSales
              ? salesByWarehouseProduct[entry.key] ?? 0
              : 0);
      final clientRef = const Uuid().v5(
        Namespace.url.value,
        'store-restore-stock:$_userId:$batchId:${entry.key}:${includeHistoricalSales ? 'seed' : 'final'}',
      );
      await _store.queueStockAdjustment(
        userId: _userId,
        productId: product['id']?.toString(),
        productClientRef: product['clientRef']?.toString(),
        warehouseId: warehouse['id']?.toString(),
        warehouseClientRef: warehouse['clientRef']?.toString(),
        productUnitId: baseUnit['id']?.toString(),
        unitClientRef: baseUnit['clientRef']?.toString(),
        targetQuantity: quantity,
        unitCost: _permissions.canViewStoreProfits
            ? (baseUnit['purchasePrice'] as num?)?.toDouble()
            : null,
        clientRef: clientRef,
        actorUserId: _userId,
        actorName: _actorName,
        deferUntilNoPendingInvoices: deferUntilNoPendingInvoices,
      );
    }
  }

  String _csvDelimiter(String header) {
    var commas = 0;
    var semicolons = 0;
    var tabs = 0;
    var quoted = false;
    for (var index = 0; index < header.length; index++) {
      final char = header[index];
      if (char == '"') {
        if (quoted && index + 1 < header.length && header[index + 1] == '"') {
          index++;
        } else {
          quoted = !quoted;
        }
      } else if (!quoted) {
        if (char == ',') commas++;
        if (char == ';') semicolons++;
        if (char == '\t') tabs++;
      }
    }
    if (tabs > commas && tabs > semicolons) return '\t';
    if (semicolons > commas) return ';';
    return ',';
  }

  String _bestCsvDelimiter(
    List<String> sampleLines,
    int Function(List<String>) headerScore,
  ) => StoreCsvDelimiterDetection.choose(
    sampleLines: sampleLines,
    fallback: _csvDelimiter(sampleLines.join('\n')),
    parseLine: (line, delimiter) => _parseCsvLine(line, delimiter: delimiter),
    scoreHeader: headerScore,
  );

  int _scoreCsvTextHeaders(
    String contents,
    int Function(List<String>) headerScore,
  ) {
    final lines = const LineSplitter().convert(
      contents.replaceFirst('\uFEFF', ''),
    );
    final sampleLines = lines.take(20).toList();
    if (sampleLines.isEmpty) return 0;
    final delimiter = _bestCsvDelimiter(sampleLines, headerScore);
    final rows = sampleLines
        .map((line) => _parseCsvLine(line, delimiter: delimiter))
        .toList();
    final headerIndex = StoreSpreadsheetHeaderDetection.findBestHeaderRow(
      rows: rows,
      score: headerScore,
    );
    return headerIndex == null ? 0 : headerScore(rows[headerIndex]);
  }

  Future<void> _downloadProductsTemplate() async {
    final excel = Excel.createExcel();
    final sheet = excel['Import'];
    excel.setDefaultSheet('Import');
    if (excel.tables.containsKey('Sheet1')) excel.delete('Sheet1');
    final headers = [
      'اسم الصنف',
      'الوحدة الأساسية',
      if (_permissions.canViewStoreProfits) 'سعر الشراء',
      'سعر البيع',
      'الحد الأدنى',
      'الباركود',
    ];
    sheet.appendRow(headers.map(TextCellValue.new).toList());
    sheet.appendRow([
      TextCellValue('مثال صنف'),
      TextCellValue('piece'),
      if (_permissions.canViewStoreProfits) const DoubleCellValue(10),
      const DoubleCellValue(15),
      const DoubleCellValue(5),
      TextCellValue('123456789'),
      const DoubleCellValue(0),
      TextCellValue('ITEM-001'),
    ]);
    final bytes = excel.encode();
    if (bytes == null) return;
    await FileSaver.instance.saveFile(
      name: 'inventory_import_template',
      bytes: Uint8List.fromList(bytes),
      fileExtension: 'xlsx',
      mimeType: MimeType.microsoftExcel,
    );
  }

  Future<void> _importProductsFile({
    _SpreadsheetImportData? selectedData,
    bool confirmed = false,
    bool syncAfter = true,
    bool deferStockAdjustments = false,
  }) async {
    final l = context.loc;
    final data =
        selectedData ??
        await _pickSpreadsheetRows(
          headerScore: (headers) => headers
              .map(_canonicalInventoryHeader)
              .where(
                (header) =>
                    ['name', 'base_unit', 'sale_price'].contains(header),
              )
              .length,
        );
    if (!mounted || data == null) return;
    final rawHeaders = data.headers;
    final rows = data.rows;
    if (rawHeaders.isEmpty || rows.isEmpty) {
      _showMessage(l.text('ملف الاستيراد فارغ.', 'The import file is empty.'));
      return;
    }
    var headers = rawHeaders.map(_canonicalInventoryHeader).toList();
    const requiredHeaders = ['name', 'base_unit', 'sale_price'];
    if (!requiredHeaders.every(headers.contains)) {
      final mappedHeaders = await _mapImportHeaders(
        title: l.text('مطابقة أعمدة الأصناف', 'Match item columns'),
        requiredFields: requiredHeaders,
        rawHeaders: rawHeaders,
        canonicalHeaders: headers,
        rows: rows,
        fieldLabel: (field) => switch (field) {
          'name' => l.text('اسم الصنف', 'Item name'),
          'base_unit' => l.text('الوحدة الأساسية', 'Base unit'),
          'sale_price' => l.text('سعر البيع', 'Sale price'),
          _ => field,
        },
        canonicalize: _canonicalInventoryHeader,
      );
      if (!mounted || mappedHeaders == null) return;
      headers = mappedHeaders;
    }
    final unitSheet = _bestSpreadsheetSheet(
      data.sheets,
      (sheetHeaders) => sheetHeaders
          .map(_canonicalProductUnitHeader)
          .where(
            (header) => [
              'product_ref',
              'product',
              'unit_ref',
              'name',
              'code',
              'factor',
              'is_base',
              'barcode',
              'sale_price',
            ].contains(header),
          )
          .length,
      minimumScore: 5,
    );
    final stockSheet = _bestSpreadsheetSheet(
      data.sheets,
      (sheetHeaders) => sheetHeaders
          .map(_canonicalWarehouseStockHeader)
          .where(
            (header) => [
              'product_ref',
              'product',
              'warehouse_ref',
              'warehouse',
              'quantity',
            ].contains(header),
          )
          .length,
      minimumScore: 4,
    );
    final unitGroups = <String, List<Map<String, dynamic>>>{};
    if (unitSheet != null) {
      final unitHeaders = unitSheet.headers
          .map(_canonicalProductUnitHeader)
          .toList();
      for (final row in unitSheet.rows) {
        String unitValue(String key) {
          final index = unitHeaders.indexOf(key);
          return index >= 0 && index < row.length ? row[index].trim() : '';
        }

        final productRef = unitValue('product_ref');
        final productName = unitValue('product');
        final unitName = unitValue('name');
        final unitCode = unitValue('code');
        final factor = _parseSpreadsheetNumber(unitValue('factor'));
        if (unitName.isEmpty ||
            unitCode.isEmpty ||
            factor == null ||
            factor <= 0) {
          continue;
        }
        final unit = <String, dynamic>{
          if (unitValue('unit_ref').isNotEmpty)
            'clientRef': unitValue('unit_ref'),
          'name': unitName,
          'code': unitCode,
          'factorToBase': factor,
          'isBase': _parseImportBoolean(unitValue('is_base')),
          'barcode': unitValue('barcode'),
          'salePrice': _parseSpreadsheetNumber(unitValue('sale_price')) ?? 0,
          if (_permissions.canViewStoreProfits &&
              unitValue('purchase_price').isNotEmpty)
            'purchasePrice': _parseSpreadsheetNumber(
              unitValue('purchase_price'),
            ),
        };
        if (productRef.isNotEmpty) {
          unitGroups.putIfAbsent('ref:$productRef', () => []).add(unit);
        }
        if (productName.isNotEmpty) {
          unitGroups
              .putIfAbsent('name:${_normalizeSearch(productName)}', () => [])
              .add(unit);
        }
      }
    }
    final rowCount = rows
        .where((row) => row.any((value) => value.trim().isNotEmpty))
        .length;
    final accepted = confirmed
        ? true
        : await _confirm(
            title: l.text('استيراد الأصناف', 'Import products'),
            message: l.text(
              'سيتم استيراد أو تحديث ما يصل إلى $rowCount صنف. المطابقة بالباركود ثم الرمز ثم الاسم. إذا احتوى الملف على عمود الكمية الحالية فسيُضبط رصيد كل صنف في المخزن الافتراضي. عند استيراد الحركات، أدخل فواتير ما بعد تاريخ هذا الرصيد فقط لتجنب تكرار المخزون.',
              'Up to $rowCount products will be imported or updated. Matching uses barcode, item code, then name. If the file has a current quantity column, it sets the default warehouse balance. When importing transactions too, include only invoices after that balance date to avoid duplicating stock.',
            ),
            actionLabel: l.text('استيراد الأصناف', 'Import products'),
          );
    if (accepted != true || !mounted) return;
    var imported = 0;
    var skipped = 0;
    var stockAdjusted = 0;
    var stockSkipped = 0;
    final importedKeys = <String>{};
    final defaultWarehouse = _warehouses.firstWhere(
      (warehouse) => warehouse['isDefault'] == true,
      orElse: () => _warehouses.isNotEmpty
          ? _warehouses.first
          : const <String, dynamic>{},
    );
    for (final values in rows) {
      if (values.every((value) => value.trim().isEmpty)) continue;
      String value(String key) {
        final index = headers.indexOf(key);
        return index >= 0 && index < values.length ? values[index].trim() : '';
      }

      final name = value('name');
      final baseUnit = value('base_unit');
      final purchaseRaw = value('purchase_price');
      final purchase = purchaseRaw.isEmpty
          ? null
          : _parseSpreadsheetNumber(purchaseRaw);
      final sale = _parseSpreadsheetNumber(value('sale_price'));
      final stockRaw = value('stock_quantity');
      final targetStock = stockRaw.isEmpty || stockSheet != null
          ? null
          : _parseSpreadsheetNumber(stockRaw);
      if (name.isEmpty ||
          baseUnit.isEmpty ||
          sale == null ||
          (purchaseRaw.isNotEmpty && (purchase == null || purchase < 0)) ||
          (stockRaw.isNotEmpty && (targetStock == null || targetStock < 0)) ||
          sale < 0) {
        skipped++;
        continue;
      }
      final barcode = value('barcode');
      final sku = value('sku');
      final sourceClientRef = value('client_ref');
      final importKey = barcode.isNotEmpty
          ? 'barcode:${_normalizeSearch(barcode)}'
          : sku.isNotEmpty
          ? 'sku:${_normalizeSearch(sku)}'
          : 'name:${_normalizeSearch(name)}';
      if (!importedKeys.add(importKey)) {
        skipped++;
        continue;
      }
      final existing = _products.firstWhere(
        (product) =>
            barcode.isNotEmpty &&
            _list(
              product['units'],
            ).any((unit) => unit['barcode']?.toString().trim() == barcode),
        orElse: () => _products.firstWhere(
          (product) =>
              sku.isNotEmpty &&
              _normalizeSearch(product['sku']?.toString() ?? '') ==
                  _normalizeSearch(sku),
          orElse: () => _products.firstWhere(
            (product) =>
                _normalizeSearch(product['name']?.toString() ?? '') ==
                _normalizeSearch(name),
            orElse: () => const <String, dynamic>{},
          ),
        ),
      );
      final clientRef =
          existing['clientRef']?.toString() ??
          (sourceClientRef.isNotEmpty ? sourceClientRef : const Uuid().v4());
      final importedUnits =
          unitGroups['ref:$sourceClientRef'] ??
          unitGroups['name:${_normalizeSearch(name)}'] ??
          const <Map<String, dynamic>>[];
      final units = importedUnits.isEmpty
          ? <Map<String, dynamic>>[
              {
                'name': _unitName(baseUnit),
                'code': baseUnit,
                'factorToBase': 1,
                'isBase': true,
                ...?(purchase == null ? null : {'purchasePrice': purchase}),
                'salePrice': sale,
                'barcode': barcode,
              },
            ]
          : importedUnits
                .map((unit) => Map<String, dynamic>.from(unit))
                .toList();
      if (units.every((unit) => unit['isBase'] != true)) {
        final matchingBase = units.indexWhere(
          (unit) => unit['code']?.toString() == baseUnit,
        );
        units[matchingBase >= 0 ? matchingBase : 0]['isBase'] = true;
      }
      if (purchase != null) {
        final baseIndex = units.indexWhere((unit) => unit['isBase'] == true);
        if (baseIndex >= 0) {
          units[baseIndex].putIfAbsent('purchasePrice', () => purchase);
        }
      }
      await _store.queueProduct(
        userId: _userId,
        serverId: existing['id']?.toString().startsWith('local:') == true
            ? null
            : existing['id']?.toString(),
        clientRef: clientRef,
        sku: sku.isEmpty ? null : sku,
        name: name,
        baseUnit: baseUnit,
        minimumStock: _parseSpreadsheetNumber(value('minimum_stock')) ?? 0,
        salePrice: sale,
        units: units,
      );
      imported++;
      if (targetStock != null && !deferStockAdjustments) {
        if (defaultWarehouse.isEmpty) {
          stockSkipped++;
          continue;
        }
        final latest = await _store.getSnapshot(_userId);
        final product = _list(latest['products']).firstWhere(
          (item) => item['clientRef']?.toString() == clientRef,
          orElse: () => const <String, dynamic>{},
        );
        final base = _list(product['units']).firstWhere(
          (unit) => unit['isBase'] == true,
          orElse: () => _list(product['units']).isNotEmpty
              ? _list(product['units']).first
              : const <String, dynamic>{},
        );
        if (product.isEmpty) {
          stockSkipped++;
          continue;
        }
        await _store.queueStockAdjustment(
          userId: _userId,
          productId: product['id']?.toString(),
          productClientRef: clientRef,
          warehouseId: defaultWarehouse['id']?.toString(),
          warehouseClientRef: defaultWarehouse['clientRef']?.toString(),
          productUnitId: base['id']?.toString(),
          unitClientRef: base['clientRef']?.toString(),
          targetQuantity: targetStock,
          unitCost: purchase,
          clientRef: const Uuid().v4(),
          actorUserId: _userId,
          actorName: _actorName,
        );
        stockAdjusted++;
      }
    }
    if (stockSheet != null && !deferStockAdjustments) {
      final stockHeaders = stockSheet.headers
          .map(_canonicalWarehouseStockHeader)
          .toList();
      for (final row in stockSheet.rows) {
        if (row.every((value) => value.trim().isEmpty)) continue;
        String stockValue(String key) {
          final index = stockHeaders.indexOf(key);
          return index >= 0 && index < row.length ? row[index].trim() : '';
        }

        final quantity = _parseSpreadsheetNumber(stockValue('quantity'));
        final productRef = stockValue('product_ref');
        final productName = stockValue('product');
        final warehouseRef = stockValue('warehouse_ref');
        final warehouseName = stockValue('warehouse');
        if (quantity == null || quantity < 0) {
          stockSkipped++;
          continue;
        }
        final latest = await _store.getSnapshot(_userId);
        final product = _list(latest['products']).firstWhere(
          (item) =>
              (productRef.isNotEmpty &&
                  item['clientRef']?.toString() == productRef) ||
              _normalizeSearch(item['name']?.toString() ?? '') ==
                  _normalizeSearch(productName),
          orElse: () => const <String, dynamic>{},
        );
        final warehouse = _list(latest['warehouses']).firstWhere(
          (item) =>
              (warehouseRef.isNotEmpty &&
                  item['clientRef']?.toString() == warehouseRef) ||
              _normalizeSearch(item['name']?.toString() ?? '') ==
                  _normalizeSearch(warehouseName),
          orElse: () => const <String, dynamic>{},
        );
        final base = _list(product['units']).firstWhere(
          (unit) => unit['isBase'] == true,
          orElse: () => _list(product['units']).isNotEmpty
              ? _list(product['units']).first
              : const <String, dynamic>{},
        );
        if (product.isEmpty || warehouse.isEmpty || base.isEmpty) {
          stockSkipped++;
          continue;
        }
        try {
          final stableRef = const Uuid().v5(
            Namespace.url.value,
            'store-stock-import:$_userId:${product['clientRef']}:${warehouse['clientRef']}:$quantity',
          );
          await _store.queueStockAdjustment(
            userId: _userId,
            productId: product['id']?.toString(),
            productClientRef: product['clientRef']?.toString(),
            warehouseId: warehouse['id']?.toString(),
            warehouseClientRef: warehouse['clientRef']?.toString(),
            productUnitId: base['id']?.toString(),
            unitClientRef: base['clientRef']?.toString(),
            targetQuantity: quantity,
            unitCost: _permissions.canViewStoreProfits
                ? (base['purchasePrice'] as num?)?.toDouble()
                : null,
            clientRef: stableRef,
            actorUserId: _userId,
            actorName: _actorName,
          );
          stockAdjusted++;
        } catch (_) {
          stockSkipped++;
        }
      }
    }
    if (imported > 0) await _showLocalThenSync(sync: syncAfter);
    _showMessage(
      l.text(
        'تم استيراد $imported صنف، وضبط رصيد $stockAdjusted صنف${skipped + stockSkipped > 0 ? '، وتجاوز ${skipped + stockSkipped} صف أو رصيد' : ''}.',
        'Imported $imported items and adjusted stock for $stockAdjusted${skipped + stockSkipped > 0 ? '; skipped ${skipped + stockSkipped} rows or stock balances' : ''}.',
      ),
    );
  }

  Future<void> _importWarehousesFile({
    _SpreadsheetImportData? selectedData,
    bool confirmed = false,
    bool syncAfter = true,
  }) async {
    if (!_permissions.canManageStoreInventory) return;
    final data =
        selectedData ??
        await _pickSpreadsheetRows(
          headerScore: (headers) => headers
              .map(_canonicalWarehouseHeader)
              .where(
                (header) => ['name', 'code', 'client_ref'].contains(header),
              )
              .length,
        );
    if (!mounted || data == null) return;
    var headers = data.headers.map(_canonicalWarehouseHeader).toList();
    if (data.rows.isEmpty) {
      _showMessage(
        context.loc.text(
          'ملف المخازن فارغ أو غير صالح.',
          'The warehouse file is empty or invalid.',
        ),
      );
      return;
    }
    if (!headers.contains('name')) {
      final mappedHeaders = await _mapImportHeaders(
        title: context.loc.text(
          'مطابقة أعمدة المخازن',
          'Match warehouse columns',
        ),
        requiredFields: const ['name'],
        rawHeaders: data.headers,
        canonicalHeaders: headers,
        rows: data.rows,
        fieldLabel: (_) => context.loc.text('اسم المخزن', 'Warehouse name'),
        canonicalize: _canonicalWarehouseHeader,
      );
      if (!mounted || mappedHeaders == null) return;
      headers = mappedHeaders;
    }
    final rowCount = data.rows
        .where((row) => row.any((value) => value.trim().isNotEmpty))
        .length;
    final accepted = confirmed
        ? true
        : await _confirm(
            title: context.loc.text('استيراد المخازن', 'Import warehouses'),
            message: context.loc.text(
              'سيتم إضافة أو تحديث $rowCount مخزن. تتم المطابقة بمرجع المخزن ثم الرمز والاسم.',
              '$rowCount warehouses will be added or updated, matching by reference, code, then name.',
            ),
            actionLabel: context.loc.text(
              'استيراد المخازن',
              'Import warehouses',
            ),
          );
    if (accepted != true || !mounted) return;
    var imported = 0;
    var skipped = 0;
    for (final row in data.rows) {
      if (row.every((value) => value.trim().isEmpty)) continue;
      String value(String key) {
        final index = headers.indexOf(key);
        return index >= 0 && index < row.length ? row[index].trim() : '';
      }

      final name = value('name');
      if (name.isEmpty) {
        skipped++;
        continue;
      }
      final code = value('code');
      final sourceRef = value('client_ref');
      final existing = _warehouses.firstWhere(
        (warehouse) =>
            (sourceRef.isNotEmpty &&
                warehouse['clientRef']?.toString() == sourceRef) ||
            (code.isNotEmpty &&
                _normalizeSearch(warehouse['code']?.toString() ?? '') ==
                    _normalizeSearch(code)) ||
            _normalizeSearch(warehouse['name']?.toString() ?? '') ==
                _normalizeSearch(name),
        orElse: () => const <String, dynamic>{},
      );
      final clientRef =
          existing['clientRef']?.toString() ??
          (sourceRef.isNotEmpty
              ? sourceRef
              : const Uuid().v5(
                  Namespace.url.value,
                  'store-warehouse-import:$_userId:${_normalizeSearch(code)}:${_normalizeSearch(name)}',
                ));
      final activeRaw = value('is_active');
      final isActive = activeRaw.isEmpty || _parseImportBoolean(activeRaw);
      await _store.queueWarehouse(
        userId: _userId,
        serverId: existing['id']?.toString().startsWith('local:') == true
            ? null
            : existing['id']?.toString(),
        clientRef: clientRef,
        name: name,
        code: code,
        notes: value('notes'),
        isActive: isActive,
        isDefault: headers.contains('is_default')
            ? _parseImportBoolean(value('is_default'))
            : null,
      );
      imported++;
    }
    if (imported > 0) await _showLocalThenSync(sync: syncAfter);
    if (!mounted) return;
    _showMessage(
      context.loc.text(
        'تم استيراد أو تحديث $imported مخزن${skipped > 0 ? '، وتجاوز $skipped صف غير صالح' : ''}.',
        'Imported or updated $imported warehouses${skipped > 0 ? '; skipped $skipped invalid rows' : ''}.',
      ),
    );
  }

  String _canonicalInventoryHeader(String raw) {
    final value = _normalizedImportHeader(raw);
    const aliases = <String, List<String>>{
      'name': [
        'name',
        'item_name',
        'product_name',
        'اسم_الصنف',
        'اسم_المادة',
        'اسم_الماده',
        'المادة',
        'الصنف',
        'الوصف',
      ],
      'base_unit': [
        'base_unit',
        'unit',
        'الوحدة',
        'وحدة',
        'الوحدة_الأساسية',
        'الوحدة_الرئيسية',
        'وحدة_القياس',
      ],
      'purchase_price': [
        'purchase_price',
        'cost',
        'سعر_الشراء',
        'تكلفة',
        'سعر_التكلفة',
        'سعر_الكلفة',
        'تكلفة_الشراء',
        'سعر_الشراء_1',
      ],
      'sale_price': [
        'sale_price',
        'price',
        'سعر_البيع',
        'سعر_المبيع',
        'السعر_الافرادي',
        'سعر_افرادي',
        'سعر_المفرد',
        'السعر',
        'سعر_بيع_1',
        'سعر_المبيع_1',
      ],
      'minimum_stock': [
        'minimum_stock',
        'min_stock',
        'الحد_الأدنى',
        'حد_الطلب',
        'اقل_كمية',
      ],
      'barcode': ['barcode', 'bar_code', 'الباركود', 'باركود'],
      'stock_quantity': [
        'stock_quantity',
        'quantity',
        'الكمية',
        'الرصيد',
        'الكمية_الحالية',
        'الرصيد_الحالي',
        'رصيد_المخزون',
        'الكمية_المتوفرة',
        'رصيد_الصنف',
      ],
      'sku': [
        'sku',
        'item_code',
        'product_code',
        'كود_الصنف',
        'رقم_الصنف',
        'رمز_الصنف',
        'الرقم_الصنفي',
      ],
      'client_ref': [
        'client_ref',
        'product_ref',
        'مرجع_الصنف',
        'المرجع_الداخلي',
      ],
    };
    for (final entry in aliases.entries) {
      if (StoreImportHeaderNormalizer.matchesAny(value, entry.value)) {
        return entry.key;
      }
    }
    return value;
  }

  double? _parseSpreadsheetNumber(String raw) {
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    const persian = '۰۱۲۳۴۵۶۷۸۹';
    var arabicDigits = raw;
    for (var index = 0; index < 10; index++) {
      arabicDigits = arabicDigits
          .replaceAll(arabic[index], '$index')
          .replaceAll(persian[index], '$index');
    }
    final normalized = arabicDigits
        .replaceAll('٬', '')
        .replaceAll(',', '')
        .replaceAll('٫', '.')
        .replaceAll(RegExp(r'[^0-9.eE+\-]'), '')
        .trim();
    return double.tryParse(normalized);
  }

  String _canonicalPartyHeader(String raw) {
    final value = _normalizedImportHeader(raw);
    const aliases = <String, List<String>>{
      'name': [
        'name',
        'party_name',
        'account_name',
        'customer_name',
        'supplier_name',
        'اسم_الحساب',
        'اسم_الزبون',
        'اسم_العميل',
        'العميل',
        'الزبون',
        'اسم_المورد',
        'المورد',
        'اسم_التاجر',
        'التاجر',
        'الاسم',
      ],
      'type': [
        'type',
        'party_type',
        'account_type',
        'نوع_الحساب',
        'نوع',
        'النوع',
      ],
      'client_ref': ['client_ref', 'party_ref', 'مرجع_الحساب'],
      'phone': [
        'phone',
        'mobile',
        'telephone',
        'الهاتف',
        'الجوال',
        'الموبايل',
        'رقم_الهاتف',
      ],
      'notes': ['notes', 'note', 'description', 'ملاحظات', 'ملاحظة', 'الوصف'],
      'receivable_balance': [
        'receivable_balance',
        'receivable',
        'له',
        'رصيد_لنا',
      ],
      'payable_balance': ['payable_balance', 'payable', 'عليه', 'رصيد_عليه'],
      'credit_limit': [
        'credit_limit',
        'حد_الدين',
        'سقف_الدين',
        'الحد_الائتماني',
      ],
    };
    for (final entry in aliases.entries) {
      if (StoreImportHeaderNormalizer.matchesAny(value, entry.value)) {
        return entry.key;
      }
    }
    return value;
  }

  String _canonicalInvoiceHeader(String raw) {
    final value = _normalizedImportHeader(raw);
    const aliases = <String, List<String>>{
      'invoice_number': [
        'invoice_number',
        'invoice_no',
        'invoice',
        'number',
        'رقم_الفاتورة',
        'رقم_الحركة',
        'رقم_المستند',
        'رقم_السند',
        'رقم_الحركة_المحاسبية',
      ],
      'client_ref': ['client_ref', 'invoice_ref', 'مرجع_الفاتورة'],
      'type': [
        'type',
        'invoice_type',
        'نوع_الفاتورة',
        'النوع',
        'نوع_الحركة',
        'نوع_السند',
      ],
      'date': [
        'date',
        'invoice_date',
        'occurred_at',
        'التاريخ',
        'تاريخ_الفاتورة',
        'تاريخ_الحركة',
        'تاريخ_المستند',
      ],
      'party': [
        'party',
        'party_name',
        'customer',
        'customer_name',
        'supplier',
        'supplier_name',
        'account',
        'account_name',
        'الحساب',
        'الزبون',
        'العميل',
        'المورد',
        'اسم_الحساب',
      ],
      'warehouse': [
        'warehouse',
        'warehouse_name',
        'store',
        'المخزن',
        'المستودع',
        'اسم_المخزن',
      ],
      'product': [
        'product',
        'product_name',
        'item',
        'item_name',
        'الصنف',
        'اسم_الصنف',
        'المادة',
        'اسم_المادة',
      ],
      'product_ref': ['product_ref', 'مرجع_الصنف'],
      'sku': ['sku', 'product_code', 'رمز_الصنف', 'كود_الصنف'],
      'unit': ['unit', 'unit_name', 'الوحدة', 'وحدة_القياس'],
      'unit_ref': ['unit_ref', 'مرجع_الوحدة'],
      'quantity': ['quantity', 'qty', 'الكمية', 'كمية'],
      'unit_price': [
        'unit_price',
        'price',
        'سعر_الوحدة',
        'السعر_الافرادي',
        'سعر_الوحدة_الافرادي',
        'سعر_المفرد',
        'السعر',
        'سعر_البيع',
        'سعر_الشراء',
      ],
      'paid_amount': [
        'paid_amount',
        'paid',
        'amount_paid',
        'المدفوع',
        'المبلغ_المدفوع',
        'المبلغ_المقبوض',
        'قيمة_المدفوع',
        'المقبوض',
      ],
      'discount': ['discount', 'الخصم', 'خصم'],
      'payment_status': ['payment_status', 'حالة_الدفع', 'حالة_الفاتورة'],
      'payment_method': [
        'payment_method',
        'method',
        'طريقة_الدفع',
        'طريقة_السداد',
      ],
      'notes': ['notes', 'note', 'ملاحظات', 'ملاحظة'],
      'barcode': ['barcode', 'باركود', 'الباركود', 'كود_الصنف'],
    };
    for (final entry in aliases.entries) {
      if (StoreImportHeaderNormalizer.matchesAny(value, entry.value)) {
        return entry.key;
      }
    }
    return value;
  }

  String _canonicalPaymentHeader(String raw) {
    final value = _normalizedImportHeader(raw);
    const aliases = <String, List<String>>{
      'date': [
        'date',
        'occurred_at',
        'payment_date',
        'التاريخ',
        'تاريخ_الدفعة',
      ],
      'invoice_number': [
        'invoice_number',
        'invoice_no',
        'رقم_الفاتورة',
        'رقم_المستند',
      ],
      'type': ['type', 'invoice_type', 'نوع_الفاتورة', 'نوع_الحركة'],
      'party': [
        'party',
        'party_name',
        'account',
        'account_name',
        'الحساب',
        'اسم_الحساب',
      ],
      'direction': ['direction', 'اتجاه', 'الاتجاه', 'نوع_الحركة'],
      'method': ['method', 'payment_method', 'طريقة_الدفع', 'طريقة_السداد'],
      'amount': [
        'amount',
        'payment_amount',
        'المبلغ',
        'قيمة_الدفعة',
        'مبلغ_الدفعة',
      ],
      'reference': ['reference', 'ref', 'المرجع', 'رقم_المرجع'],
      'notes': ['notes', 'note', 'ملاحظات', 'ملاحظة'],
      'client_ref': [
        'client_ref',
        'client_reference',
        'payment_ref',
        'مرجع_الدفعة',
        'مرجع_النظام',
      ],
    };
    for (final entry in aliases.entries) {
      if (StoreImportHeaderNormalizer.matchesAny(value, entry.value)) {
        return entry.key;
      }
    }
    return value;
  }

  String _canonicalProductUnitHeader(String raw) {
    final value = _normalizedImportHeader(raw);
    const aliases = <String, List<String>>{
      'product_ref': ['product_ref', 'client_ref', 'مرجع_الصنف'],
      'product': ['product', 'product_name', 'اسم_الصنف', 'الصنف'],
      'unit_ref': ['unit_ref', 'unit_client_ref', 'مرجع_الوحدة'],
      'name': ['unit_name', 'اسم_الوحدة', 'الوحدة'],
      'code': ['unit_code', 'code', 'رمز_الوحدة', 'كود_الوحدة'],
      'factor': [
        'factor_to_base',
        'factor',
        'المعامل_إلى_الأساسية',
        'معامل_التحويل',
      ],
      'is_base': ['is_base', 'base_unit', 'أساسية', 'الوحدة_الأساسية'],
      'barcode': ['barcode', 'باركود', 'الباركود'],
      'sale_price': ['sale_price', 'سعر_البيع'],
      'purchase_price': ['purchase_price', 'سعر_الشراء'],
    };
    for (final entry in aliases.entries) {
      if (StoreImportHeaderNormalizer.matchesAny(value, entry.value)) {
        return entry.key;
      }
    }
    return value;
  }

  String _canonicalWarehouseStockHeader(String raw) {
    final value = _normalizedImportHeader(raw);
    const aliases = <String, List<String>>{
      'product_ref': ['product_ref', 'مرجع_الصنف'],
      'product': ['product', 'product_name', 'اسم_الصنف', 'الصنف'],
      'warehouse_ref': ['warehouse_ref', 'مرجع_المخزن'],
      'warehouse': ['warehouse', 'warehouse_name', 'اسم_المخزن', 'المخزن'],
      'quantity': ['quantity', 'qty', 'الكمية', 'الرصيد'],
      'minimum_stock': ['minimum_stock', 'الحد_الأدنى'],
    };
    for (final entry in aliases.entries) {
      if (StoreImportHeaderNormalizer.matchesAny(value, entry.value)) {
        return entry.key;
      }
    }
    return value;
  }

  String _canonicalWarehouseHeader(String raw) {
    final value = _normalizedImportHeader(raw);
    const aliases = <String, List<String>>{
      'client_ref': ['client_ref', 'warehouse_ref', 'مرجع_المخزن'],
      'name': ['name', 'warehouse_name', 'اسم_المخزن', 'المخزن'],
      'code': ['code', 'الرمز', 'رمز_المخزن'],
      'is_default': ['is_default', 'default', 'افتراضي', 'رئيسي'],
      'is_active': ['is_active', 'active', 'نشط', 'فعال'],
      'notes': ['notes', 'note', 'ملاحظات', 'ملاحظة'],
    };
    for (final entry in aliases.entries) {
      if (StoreImportHeaderNormalizer.matchesAny(value, entry.value)) {
        return entry.key;
      }
    }
    return value;
  }

  String _canonicalPaymentMethodHeader(String raw) {
    final value = _normalizedImportHeader(raw);
    const aliases = <String, List<String>>{
      'name': [
        'name',
        'method',
        'payment_method',
        'اسم_الطريقة',
        'طريقة_الدفع',
      ],
      'client_ref': ['client_ref', 'reference', 'مرجع_الطريقة', 'مرجع'],
      'sort_order': ['sort_order', 'order', 'الترتيب', 'التسلسل'],
      'is_active': ['is_active', 'active', 'نشطة', 'فعال'],
    };
    for (final entry in aliases.entries) {
      if (StoreImportHeaderNormalizer.matchesAny(value, entry.value)) {
        return entry.key;
      }
    }
    return value;
  }

  String _importPaymentDirection(String raw) {
    final normalized = _normalizeSearch(raw);
    if ([
      'in',
      'income',
      'received',
      'receive',
      'قبض',
      'وارد',
      'تحصيل',
      'استلام',
      'دخل',
      'sale',
      'بيع',
      'مبيعات',
    ].contains(normalized)) {
      return 'in';
    }
    if ([
      'out',
      'expense',
      'disbursement',
      'صرف',
      'دفع',
      'خارج',
      'مصروف',
      'تسديد',
      'purchase',
      'شراء',
      'مشتريات',
    ].contains(normalized)) {
      return 'out';
    }
    return '';
  }

  _SpreadsheetSheetData? _bestSpreadsheetSheet(
    Map<String, _SpreadsheetSheetData> sheets,
    int Function(List<String>) score, {
    required int minimumScore,
  }) {
    final candidates = sheets.values.toList()
      ..sort((a, b) => score(b.headers).compareTo(score(a.headers)));
    if (candidates.isEmpty || score(candidates.first.headers) < minimumScore) {
      return null;
    }
    return candidates.first;
  }

  String _normalizedImportHeader(String raw) =>
      StoreImportHeaderNormalizer.normalize(raw);

  DateTime? _parseImportDate(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed;
    final serial = _parseSpreadsheetNumber(value);
    if (serial != null && serial >= 1 && serial <= 100000) {
      return DateTime.utc(1899, 12, 30).add(Duration(days: serial.floor()));
    }
    final match = RegExp(
      r'^(\d{1,2})[./-](\d{1,2})[./-](\d{2,4})$',
    ).firstMatch(value);
    if (match == null) return null;
    final day = int.tryParse(match.group(1)!);
    final month = int.tryParse(match.group(2)!);
    var year = int.tryParse(match.group(3)!);
    if (day == null || month == null || year == null) return null;
    if (year < 100) year += year >= 70 ? 1900 : 2000;
    try {
      return DateTime(year, month, day);
    } on ArgumentError {
      return null;
    }
  }

  bool _parseImportBoolean(String raw) => [
    'true',
    '1',
    'yes',
    'نعم',
    'فعال',
    'اساسي',
    'base',
  ].contains(_normalizeSearch(raw));

  Future<void> _downloadAccountsTemplate() async {
    final excel = Excel.createExcel();
    final sheet = excel['Accounts'];
    excel.setDefaultSheet('Accounts');
    if (excel.tables.containsKey('Sheet1')) excel.delete('Sheet1');
    sheet.appendRow(
      [
        'نوع الحساب',
        'اسم الحساب',
        'الهاتف',
        'ملاحظات',
      ].map(TextCellValue.new).toList(),
    );
    sheet.appendRow([
      TextCellValue('زبون'),
      TextCellValue('مثال زبون'),
      TextCellValue('0590000000'),
      TextCellValue(''),
      TextCellValue('0'),
    ]);
    final bytes = excel.encode();
    if (bytes == null) return;
    await FileSaver.instance.saveFile(
      name: 'accounts_import_template',
      bytes: Uint8List.fromList(bytes),
      fileExtension: 'xlsx',
      mimeType: MimeType.microsoftExcel,
    );
  }

  Future<void> _importPartiesFile({
    _SpreadsheetImportData? selectedData,
    bool confirmed = false,
    bool syncAfter = true,
  }) async {
    if (!_permissions.canManageStoreDebts) return;
    final data =
        selectedData ??
        await _pickSpreadsheetRows(
          headerScore: (headers) => headers
              .map(_canonicalPartyHeader)
              .where((header) => ['name', 'type'].contains(header))
              .length,
        );
    if (!mounted || data == null) return;
    if (data.headers.isEmpty || data.rows.isEmpty) {
      _showMessage(
        context.loc.text('ملف الاستيراد فارغ.', 'The import file is empty.'),
      );
      return;
    }
    var headers = data.headers.map(_canonicalPartyHeader).toList();
    const requiredHeaders = ['name', 'type'];
    if (!requiredHeaders.every(headers.contains)) {
      final mappedHeaders = await _mapImportHeaders(
        title: context.loc.text(
          'مطابقة أعمدة الحسابات',
          'Match account columns',
        ),
        requiredFields: requiredHeaders,
        rawHeaders: data.headers,
        canonicalHeaders: headers,
        rows: data.rows,
        fieldLabel: (field) => switch (field) {
          'name' => context.loc.text('اسم الحساب', 'Account name'),
          'type' => context.loc.text('نوع الحساب', 'Account type'),
          _ => field,
        },
        canonicalize: _canonicalPartyHeader,
      );
      if (!mounted || mappedHeaders == null) return;
      headers = mappedHeaders;
    }
    final rowCount = data.rows
        .where((row) => row.any((value) => value.trim().isNotEmpty))
        .length;
    final accepted = confirmed
        ? true
        : await _confirm(
            title: context.loc.text('استيراد الحسابات', 'Import accounts'),
            message: context.loc.text(
              'سيتم استيراد أو تحديث بيانات ما يصل إلى $rowCount حساب. تُطابق الحسابات بالاسم، ولا تُحمّل الأرصدة أو الحركات من هذا الملف.',
              'Up to $rowCount accounts will be imported or updated by name. Balances and transactions are not loaded from this file.',
            ),
            actionLabel: context.loc.text(
              'استيراد الحسابات',
              'Import accounts',
            ),
          );
    if (accepted != true || !mounted) return;
    var imported = 0;
    var skipped = 0;
    for (final row in data.rows) {
      if (row.every((value) => value.trim().isEmpty)) continue;
      String value(String key) {
        final index = headers.indexOf(key);
        return index >= 0 && index < row.length ? row[index].trim() : '';
      }

      final name = value('name');
      final rawType = _normalizeSearch(value('type'));
      final type = switch (rawType) {
        'supplier' ||
        'vendor' ||
        'merchant' ||
        'مورد' ||
        'المورد' ||
        'تاجر' ||
        'التاجر' => 'supplier',
        'both' || 'كلاهما' || 'زبون ومورد' || 'زبون وتاجر' => 'both',
        'customer' || 'client' || 'زبون' || 'عميل' || 'العميل' => 'customer',
        _ => '',
      };
      if (name.isEmpty || type.isEmpty) {
        skipped++;
        continue;
      }
      final existing = _parties.firstWhere(
        (party) =>
            _normalizeSearch(party['name']?.toString() ?? '') ==
            _normalizeSearch(name),
        orElse: () => const <String, dynamic>{},
      );
      final sourceRef = value('client_ref');
      final rawCreditLimit = value('credit_limit');
      final creditLimit = rawCreditLimit.isEmpty
          ? (existing['creditLimit'] as num?)?.toDouble() ?? 0
          : _parseSpreadsheetNumber(rawCreditLimit);
      if (creditLimit == null || creditLimit < 0) {
        skipped++;
        continue;
      }
      await _store.queueParty(
        userId: _userId,
        serverId: existing['id']?.toString().startsWith('local:') == true
            ? null
            : existing['id']?.toString(),
        clientRef:
            existing['clientRef']?.toString() ??
            (sourceRef.isNotEmpty ? sourceRef : null),
        type: type,
        name: name,
        phone: value('phone'),
        notes: value('notes'),
        debtBookCustomerId: existing['debtBookCustomerId']?.toString(),
        creditLimit: creditLimit,
      );
      imported++;
    }
    if (imported > 0) await _showLocalThenSync(sync: syncAfter);
    if (!mounted) return;
    _showMessage(
      context.loc.text(
        'تم استيراد أو تحديث $imported حساب${skipped > 0 ? '، وتجاوز $skipped صف غير صالح' : ''}. لم تُستورد الأرصدة الافتتاحية.',
        'Imported or updated $imported accounts${skipped > 0 ? '; skipped $skipped invalid rows' : ''}. Opening balances were not imported.',
      ),
    );
  }

  Future<void> _downloadInvoiceTemplate() async {
    final excel = Excel.createExcel();
    final sheet = excel['Invoices'];
    excel.setDefaultSheet('Invoices');
    if (excel.tables.containsKey('Sheet1')) excel.delete('Sheet1');
    final headers = [
      'رقم الفاتورة',
      'النوع',
      'التاريخ',
      'اسم الحساب',
      'المخزن',
      'المبلغ المدفوع',
      'الخصم',
      'طريقة الدفع',
      'ملاحظات',
      'اسم الصنف',
      'الوحدة',
      'الكمية',
      'سعر الوحدة',
      'الباركود',
    ];
    sheet.appendRow(headers.map(TextCellValue.new).toList());
    final bytes = excel.encode();
    if (bytes == null) return;
    await FileSaver.instance.saveFile(
      name: 'invoice_import_template',
      bytes: Uint8List.fromList(bytes),
      fileExtension: 'xlsx',
      mimeType: MimeType.microsoftExcel,
    );
  }

  Future<List<String>?> _mapImportHeaders({
    required String title,
    required List<String> requiredFields,
    required List<String> rawHeaders,
    required List<String> canonicalHeaders,
    required List<List<String>> rows,
    required String Function(String field) fieldLabel,
    required String Function(String raw) canonicalize,
  }) async {
    final selected = <String, int?>{
      for (final field in requiredFields)
        field: canonicalHeaders.contains(field)
            ? canonicalHeaders.indexOf(field)
            : null,
    };
    final sampleRow = rows.firstWhere(
      (row) => row.any((cell) => cell.trim().isNotEmpty),
      orElse: () => const <String>[],
    );
    String optionLabel(int index) {
      final header = rawHeaders[index].trim().isEmpty
          ? context.loc.text('عمود بلا عنوان', 'Unnamed column')
          : rawHeaders[index].trim();
      final sample = index < sampleRow.length ? sampleRow[index].trim() : '';
      return sample.isEmpty
          ? '${index + 1}. $header'
          : '${index + 1}. $header — $sample';
    }

    final accepted = await _openFullScreenForm(
      title: title,
      actionLabel: context.loc.text('متابعة الاستيراد', 'Continue import'),
      canSubmit: () {
        if (requiredFields.any((field) => selected[field] == null)) {
          return false;
        }
        return requiredFields.map((field) => selected[field]).toSet().length ==
            requiredFields.length;
      },
      builder: (formContext, setFormState) => ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Text(
            context.loc.text(
              'اختر العمود المناسب لكل معلومة. تظهر قيمة من أول صف للتمييز بين الأعمدة.',
              'Choose the matching column for each value. A sample from the first row helps distinguish columns.',
            ),
          ),
          const SizedBox(height: 18),
          for (final field in requiredFields) ...[
            DropdownButtonFormField<int>(
              key: ValueKey('invoice-import-column-$field'),
              initialValue: selected[field],
              isExpanded: true,
              decoration: InputDecoration(labelText: fieldLabel(field)),
              items: [
                for (var index = 0; index < rawHeaders.length; index++)
                  DropdownMenuItem<int>(
                    value: index,
                    child: Text(
                      optionLabel(index),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (index) => setFormState(() {
                selected[field] = index;
              }),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
    if (accepted != true || !mounted) return null;

    final mappedHeaders = rawHeaders.map(canonicalize).toList();
    for (var index = 0; index < mappedHeaders.length; index++) {
      if (requiredFields.contains(mappedHeaders[index])) {
        mappedHeaders[index] = '__unmapped_$index';
      }
    }
    for (final field in requiredFields) {
      final index = selected[field];
      if (index != null) mappedHeaders[index] = field;
    }
    return mappedHeaders;
  }

  Future<void> _importInvoicesFile({
    _SpreadsheetImportData? selectedData,
    bool confirmed = false,
    bool syncAfter = true,
  }) async {
    final data =
        selectedData ??
        await _pickSpreadsheetRows(
          headerScore: (headers) => headers
              .map(_canonicalInvoiceHeader)
              .where(
                (header) => [
                  'type',
                  'product',
                  'quantity',
                  'unit_price',
                ].contains(header),
              )
              .length,
        );
    if (!mounted || data == null) return;
    if (data.headers.isEmpty || data.rows.isEmpty) {
      _showMessage(
        context.loc.text('ملف الاستيراد فارغ.', 'The import file is empty.'),
      );
      return;
    }
    final paymentSheet = _bestSpreadsheetSheet(
      data.sheets,
      (sheetHeaders) => sheetHeaders
          .map(_canonicalPaymentHeader)
          .where(
            (header) => [
              'date',
              'invoice_number',
              'party',
              'direction',
              'method',
              'amount',
              'client_ref',
            ].contains(header),
          )
          .length,
      minimumScore: 4,
    );
    final possiblePaymentMethodSheet = _bestSpreadsheetSheet(
      data.sheets,
      (sheetHeaders) => sheetHeaders
          .map(_canonicalPaymentMethodHeader)
          .where(
            (header) => ['name', 'client_ref', 'sort_order'].contains(header),
          )
          .length,
      minimumScore: 2,
    );
    final paymentMethodSheet =
        possiblePaymentMethodSheet?.headers
                .map(_canonicalPaymentMethodHeader)
                .contains('name') ==
            true
        ? possiblePaymentMethodSheet
        : null;
    var headers = data.headers.map(_canonicalInvoiceHeader).toList();
    const required = ['type', 'product', 'quantity', 'unit_price'];
    if (!required.every(headers.contains)) {
      final mappedHeaders = await _mapImportHeaders(
        title: context.loc.text(
          'مطابقة أعمدة الفاتورة',
          'Match invoice columns',
        ),
        requiredFields: required,
        rawHeaders: data.headers,
        canonicalHeaders: headers,
        rows: data.rows,
        fieldLabel: (field) => switch (field) {
          'type' => context.loc.text(
            'نوع الفاتورة أو الحركة',
            'Invoice or movement type',
          ),
          'product' => context.loc.text('اسم الصنف', 'Item name'),
          'quantity' => context.loc.text('الكمية', 'Quantity'),
          'unit_price' => context.loc.text('سعر الوحدة', 'Unit price'),
          _ => field,
        },
        canonicalize: _canonicalInvoiceHeader,
      );
      if (!mounted || mappedHeaders == null) return;
      headers = mappedHeaders;
    }
    String rowValue(List<String> row, List<String> fields) {
      for (final field in fields) {
        final index = headers.indexOf(field);
        if (index >= 0 && index < row.length && row[index].trim().isNotEmpty) {
          return row[index].trim();
        }
      }
      return '';
    }

    final grouped = <String, Map<String, dynamic>>{};
    var skipped = 0;
    for (var rowIndex = 0; rowIndex < data.rows.length; rowIndex++) {
      final row = data.rows[rowIndex];
      if (row.every((value) => value.trim().isEmpty)) continue;
      final rawType = _normalizeSearch(rowValue(row, ['type']));
      final type =
          rawType == 'purchase' ||
              rawType == 'buy' ||
              rawType.contains('شراء') ||
              rawType.contains('مشتريات')
          ? 'purchase'
          : rawType == 'sale' ||
                rawType.contains('بيع') ||
                rawType.contains('مبيعات')
          ? 'sale'
          : '';
      final productName = rowValue(row, ['product']);
      final quantity = _parseSpreadsheetNumber(rowValue(row, ['quantity']));
      final unitPrice = _parseSpreadsheetNumber(rowValue(row, ['unit_price']));
      if (type.isEmpty ||
          productName.isEmpty ||
          quantity == null ||
          unitPrice == null ||
          quantity <= 0 ||
          unitPrice < 0) {
        skipped++;
        continue;
      }
      final invoiceNumber = rowValue(row, ['invoice_number']);
      final occurredAt = _parseImportDate(rowValue(row, ['date']));
      final partyName = rowValue(row, ['party']);
      final key = invoiceNumber.isEmpty
          ? 'row:$rowIndex'
          : '${type}_${_normalizeSearch(invoiceNumber)}';
      final invoice = grouped.putIfAbsent(
        key,
        () => {
          'invoiceNumber': invoiceNumber,
          'clientRef': rowValue(row, ['client_ref']),
          'type': type,
          'occurredAt': occurredAt,
          'partyName': partyName,
          'warehouseName': rowValue(row, ['warehouse']),
          'paidRaw': rowValue(row, ['paid_amount']),
          'discountRaw': rowValue(row, ['discount']),
          'paymentStatus': rowValue(row, ['payment_status']).toLowerCase(),
          'paymentMethod': rowValue(row, ['payment_method']),
          'notes': rowValue(row, ['notes']),
          'items': <Map<String, dynamic>>[],
        },
      );
      (invoice['items'] as List<Map<String, dynamic>>).add({
        'productName': productName,
        'productRef': rowValue(row, ['product_ref']),
        'sku': rowValue(row, ['sku']),
        'barcode': rowValue(row, ['barcode']),
        'unitRef': rowValue(row, ['unit_ref']),
        'unitName': rowValue(row, ['unit']),
        'quantity': quantity,
        'unitPrice': unitPrice,
      });
    }

    final paymentHeaders =
        paymentSheet?.headers.map(_canonicalPaymentHeader).toList() ??
        const <String>[];
    final paymentRows =
        paymentSheet?.rows
            .where((row) => row.any((value) => value.trim().isNotEmpty))
            .toList() ??
        const <List<String>>[];
    final knownInvoiceNumbers = <String>{
      ..._invoices.map(
        (invoice) =>
            _normalizeSearch(invoice['invoiceNumber']?.toString() ?? ''),
      ),
      ...grouped.values.map(
        (invoice) =>
            _normalizeSearch(invoice['invoiceNumber']?.toString() ?? ''),
      ),
    }..remove('');
    final knownPartyNames = _parties
        .map((party) => _normalizeSearch(party['name']?.toString() ?? ''))
        .where((name) => name.isNotEmpty)
        .toSet();
    final availablePaymentMethods = _activePaymentMethods
        .map((method) => _normalizeSearch(method['name']?.toString() ?? ''))
        .where((name) => name.isNotEmpty)
        .toSet();
    if (paymentMethodSheet != null && _permissions.canManageStoreInventory) {
      final methodHeaders = paymentMethodSheet.headers
          .map(_canonicalPaymentMethodHeader)
          .toList();
      for (final row in paymentMethodSheet.rows) {
        final nameIndex = methodHeaders.indexOf('name');
        if (nameIndex < 0 || nameIndex >= row.length) continue;
        final methodName = _normalizeSearch(row[nameIndex]);
        final activeIndex = methodHeaders.indexOf('is_active');
        final activeValue = activeIndex >= 0 && activeIndex < row.length
            ? _normalizeSearch(row[activeIndex])
            : '';
        if (methodName.isNotEmpty &&
            ![
              '0',
              'false',
              'no',
              'لا',
              'غير_فعال',
              'inactive',
            ].contains(activeValue)) {
          availablePaymentMethods.add(methodName);
        }
      }
    }
    bool paymentRowsAreRestorable() {
      if (paymentRows.isEmpty || !paymentHeaders.contains('amount')) {
        return false;
      }
      for (final row in paymentRows) {
        String value(String key) {
          final index = paymentHeaders.indexOf(key);
          return index >= 0 && index < row.length ? row[index].trim() : '';
        }

        final amount = _parseSpreadsheetNumber(value('amount'));
        final invoiceNumber = _normalizeSearch(value('invoice_number'));
        final partyName = _normalizeSearch(value('party'));
        final direction = _importPaymentDirection(value('direction')).isNotEmpty
            ? _importPaymentDirection(value('direction'))
            : _importPaymentDirection(value('type'));
        final methodName = _normalizeSearch(value('method'));
        final linked = invoiceNumber.isNotEmpty
            ? knownInvoiceNumbers.contains(invoiceNumber)
            : knownPartyNames.contains(partyName);
        if (amount == null ||
            amount <= 0 ||
            direction.isEmpty ||
            !linked ||
            (methodName.isNotEmpty &&
                !availablePaymentMethods.contains(methodName)) ||
            (methodName.isEmpty && availablePaymentMethods.isEmpty)) {
          return false;
        }
      }
      return true;
    }

    final hasPaymentHistory =
        _permissions.canManageStoreDebts &&
        _permissions.canViewStoreProfits &&
        paymentRowsAreRestorable();

    final invoices = grouped.values.toList()
      ..sort(
        (a, b) => ((a['occurredAt'] as DateTime?) ?? DateTime(1900)).compareTo(
          (b['occurredAt'] as DateTime?) ?? DateTime(1900),
        ),
      );
    final candidates = <Map<String, dynamic>>[];
    for (final invoice in invoices) {
      final type = invoice['type'] as String;
      if ((type == 'sale' && !_permissions.canCreateStoreSales) ||
          (type == 'purchase' && !_permissions.canCreateStorePurchases)) {
        skipped++;
        continue;
      }
      final invoiceNumber = invoice['invoiceNumber'] as String;
      if (StoreInvoiceImportMatching.hasDuplicateInvoice(
        existingInvoices: _invoices,
        type: type,
        invoiceNumber: invoiceNumber,
        normalize: _normalizeSearch,
      )) {
        skipped++;
        continue;
      }
      final partyName = invoice['partyName'] as String;
      final party = _parties.firstWhere(
        (item) =>
            _normalizeSearch(item['name']?.toString() ?? '') ==
            _normalizeSearch(partyName),
        orElse: () => const <String, dynamic>{},
      );
      if (type == 'purchase' && party.isEmpty) {
        skipped++;
        continue;
      }
      final warehouseName = _normalizeSearch(
        invoice['warehouseName']?.toString() ?? '',
      );
      final warehouse = _warehouses.firstWhere(
        (item) =>
            warehouseName.isNotEmpty &&
            _normalizeSearch(item['name']?.toString() ?? '') == warehouseName,
        orElse: () => _warehouses.firstWhere(
          (item) => item['isDefault'] == true,
          orElse: () => _warehouses.isNotEmpty
              ? _warehouses.first
              : const <String, dynamic>{},
        ),
      );
      if (warehouse.isEmpty) {
        skipped++;
        continue;
      }
      final items = <Map<String, dynamic>>[];
      var invalid = false;
      for (final rawLine in invoice['items'] as List<Map<String, dynamic>>) {
        final productRef = rawLine['productRef']?.toString() ?? '';
        final sku = rawLine['sku']?.toString() ?? '';
        final barcode = rawLine['barcode']?.toString() ?? '';
        final productName = rawLine['productName']?.toString() ?? '';
        final product = _products.firstWhere(
          (item) =>
              (productRef.isNotEmpty &&
                  item['clientRef']?.toString() == productRef) ||
              (sku.isNotEmpty &&
                  _normalizeSearch(item['sku']?.toString() ?? '') ==
                      _normalizeSearch(sku)) ||
              (barcode.isNotEmpty &&
                  _list(item['units']).any(
                    (unit) => unit['barcode']?.toString().trim() == barcode,
                  )) ||
              _normalizeSearch(item['name']?.toString() ?? '') ==
                  _normalizeSearch(productName),
          orElse: () => const <String, dynamic>{},
        );
        if (product.isEmpty) {
          invalid = true;
          break;
        }
        final requestedUnit = _normalizeSearch(
          rawLine['unitName']?.toString() ?? '',
        );
        final requestedUnitRef = rawLine['unitRef']?.toString() ?? '';
        final units = _list(product['units']);
        final unit = StoreInvoiceImportMatching.resolveUnit(
          units: units,
          normalize: _normalizeSearch,
          clientRef: requestedUnitRef,
          name: requestedUnit,
        );
        if (unit == null) {
          invalid = true;
          break;
        }
        items.add({
          'productId': product['id'],
          'productClientRef': product['clientRef'],
          'productUnitId': unit['id'],
          'unitClientRef': unit['clientRef'],
          'quantity': rawLine['quantity'],
          'unitPrice': rawLine['unitPrice'],
        });
      }
      if (invalid || items.isEmpty) {
        skipped++;
        continue;
      }
      final subtotal = items.fold<double>(
        0,
        (sum, line) =>
            sum +
            ((line['quantity'] as num).toDouble() *
                (line['unitPrice'] as num).toDouble()),
      );
      final discount =
          _parseSpreadsheetNumber(invoice['discountRaw']?.toString() ?? '') ??
          0;
      if (discount < 0 || discount > subtotal) {
        skipped++;
        continue;
      }
      final total = subtotal - discount;
      final paymentStatus = invoice['paymentStatus']?.toString() ?? '';
      final paidValue = _parseSpreadsheetNumber(
        invoice['paidRaw']?.toString() ?? '',
      );
      final paidAmount = hasPaymentHistory
          ? 0.0
          : paidValue ??
                ([
                      'paid',
                      'مدفوعة',
                      'مدفوع',
                      'مسددة',
                      'مسدد',
                    ].contains(paymentStatus)
                    ? total
                    : 0);
      if (paidAmount < 0 || paidAmount > total) {
        skipped++;
        continue;
      }
      candidates.add({
        ...invoice,
        'party': party,
        'warehouse': warehouse,
        'items': items,
        'discount': discount,
        'paidAmount': paidAmount,
        'total': total,
        'clientRef':
            (invoice['clientRef']?.toString().trim().isNotEmpty == true)
            ? invoice['clientRef']?.toString()
            : invoiceNumber.trim().isEmpty
            ? null
            : const Uuid().v5(
                Namespace.url.value,
                'store-invoice-import:$_userId:$type:${_normalizeSearch(invoiceNumber)}',
              ),
      });
    }

    if (candidates.isEmpty) {
      _showMessage(
        context.loc.text(
          'لم أجد فواتير قابلة للاستيراد. تأكد من وجود الأصناف والحسابات والمخازن قبل الاستيراد.',
          'No importable invoices were found. Make sure products, accounts, and warehouses exist first.',
        ),
      );
      return;
    }
    final accepted = confirmed
        ? true
        : await _confirm(
            title: context.loc.text('استيراد الفواتير', 'Import invoices'),
            message: context.loc.text(
              'سيتم إضافة ${candidates.length} فاتورة إلى المخزون والحسابات. تم تجاوز $skipped صف أو فاتورة غير صالحة أو موجودة مسبقًا.${hasPaymentHistory
                  ? ' وسيُعاد بناء أرصدة الفواتير من ${paymentRows.length} حركة دفع في المصنف.'
                  : paymentRows.isNotEmpty
                  ? ' لن تُستورد حركات الدفع التفصيلية؛ سيُستخدم المدفوع المسجل داخل الفواتير فقط.'
                  : ''} تأكد من استيراد الأرصدة الافتتاحية قبل فواتير البيع.',
              '${candidates.length} invoices will be added to inventory and accounts. $skipped invalid or duplicate rows/invoices were skipped.${hasPaymentHistory
                  ? ' Invoice balances will be rebuilt from ${paymentRows.length} payment entries in this workbook.'
                  : paymentRows.isNotEmpty
                  ? ' Detailed payment entries will not be imported; only the paid totals on invoices will be used.'
                  : ''} Import opening stock before sales invoices.',
            ),
            actionLabel: context.loc.text(
              'استيراد الفواتير',
              'Import invoices',
            ),
          );
    if (accepted != true || !mounted) return;

    String invoiceRefKey(String type, String number) =>
        '$type:${_normalizeSearch(number)}';
    final invoiceRefs = <String, Map<String, dynamic>>{};
    for (final invoice in _invoices) {
      final number = invoice['invoiceNumber']?.toString().trim() ?? '';
      if (number.isEmpty) continue;
      final type = invoice['type']?.toString() ?? 'sale';
      invoiceRefs[invoiceRefKey(type, number)] = {
        'id': invoice['id']?.toString(),
        'clientRef': invoice['clientRef']?.toString(),
        'type': type,
      };
    }

    final paymentMethodsByName = <String, Map<String, dynamic>>{};
    for (final method in _activePaymentMethods) {
      final name = method['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      paymentMethodsByName[_normalizeSearch(name)] = method;
    }
    if (hasPaymentHistory &&
        paymentMethodSheet != null &&
        _permissions.canManageStoreInventory) {
      final methodHeaders = paymentMethodSheet.headers
          .map(_canonicalPaymentMethodHeader)
          .toList();
      for (final row in paymentMethodSheet.rows) {
        if (row.every((value) => value.trim().isEmpty)) continue;
        String methodValue(String key) {
          final index = methodHeaders.indexOf(key);
          return index >= 0 && index < row.length ? row[index].trim() : '';
        }

        final name = methodValue('name');
        if (name.isEmpty) continue;
        final activeValue = _normalizeSearch(methodValue('is_active'));
        if ([
          '0',
          'false',
          'no',
          'لا',
          'غير_فعال',
          'inactive',
        ].contains(activeValue)) {
          continue;
        }
        final sourceRef = methodValue('client_ref');
        final existing = _paymentMethods.firstWhere(
          (item) =>
              (sourceRef.isNotEmpty &&
                  item['clientRef']?.toString() == sourceRef) ||
              _normalizeSearch(item['name']?.toString() ?? '') ==
                  _normalizeSearch(name),
          orElse: () => const <String, dynamic>{},
        );
        final methodClientRef =
            existing['clientRef']?.toString() ??
            (sourceRef.isNotEmpty
                ? sourceRef
                : const Uuid().v5(
                    Namespace.url.value,
                    'store-payment-method:$_userId:${_normalizeSearch(name)}',
                  ));
        final isActive = existing.isEmpty
            ? true
            : existing['isActive'] != false;
        if (isActive) {
          await _store.queuePaymentMethod(
            userId: _userId,
            id: existing['id']?.toString(),
            clientRef: methodClientRef,
            name: name,
            sortOrder:
                _parseSpreadsheetNumber(methodValue('sort_order'))?.toInt() ??
                paymentMethodsByName.length,
            isActive: true,
          );
          paymentMethodsByName[_normalizeSearch(name)] = {
            'id': existing['id']?.toString() ?? 'local:$methodClientRef',
            'clientRef': methodClientRef,
            'name': name,
            'isActive': true,
          };
        }
      }
    }

    var imported = 0;
    var failed = 0;
    for (final invoice in candidates) {
      final party = invoice['party'] as Map<String, dynamic>;
      final warehouse = invoice['warehouse'] as Map<String, dynamic>;
      final methodName = invoice['paymentMethod']?.toString() ?? '';
      final method = _activePaymentMethods.firstWhere(
        (item) =>
            methodName.isNotEmpty &&
            _normalizeSearch(item['name']?.toString() ?? '') ==
                _normalizeSearch(methodName),
        orElse: () =>
            _activePaymentMethods.firstOrNull ?? const <String, dynamic>{},
      );
      final paidAmount = invoice['paidAmount'] as double;
      if (paidAmount > 0 && method.isEmpty) {
        failed++;
        continue;
      }
      try {
        final invoiceClientRef = invoice['clientRef']?.toString();
        await _store.queueInvoice(
          userId: _userId,
          invoiceType: invoice['type'] as String,
          clientRef: invoiceClientRef,
          invoiceNumber: (invoice['invoiceNumber'] as String).trim().isEmpty
              ? null
              : invoice['invoiceNumber'] as String,
          occurredAt: invoice['occurredAt'] as DateTime?,
          partyId: party['id']?.toString(),
          partyClientRef: party['clientRef']?.toString(),
          partyName: party['name']?.toString(),
          warehouseId: warehouse['id']?.toString(),
          warehouseClientRef: warehouse['clientRef']?.toString(),
          paidAmount: paidAmount,
          paymentMethod: method['name']?.toString() ?? '',
          paymentMethodId: paidAmount > 0 ? method['id']?.toString() : null,
          paymentMethodClientRef: paidAmount > 0
              ? method['clientRef']?.toString()
              : null,
          discount: invoice['discount'] as double,
          notes: invoice['notes']?.toString() ?? '',
          items: List<Map<String, dynamic>>.from(invoice['items'] as List),
          actorUserId: _userId,
          actorName: _actorName,
          canEditStorePrices: _permissions.canEditStorePrices,
          canManageStoreDebts: _permissions.canManageStoreDebts,
        );
        final invoiceNumber = invoice['invoiceNumber']?.toString().trim() ?? '';
        if (invoiceNumber.isNotEmpty) {
          invoiceRefs[invoiceRefKey(
            invoice['type'] as String,
            invoiceNumber,
          )] = {
            'id': invoiceClientRef == null ? null : 'local:$invoiceClientRef',
            'clientRef': invoiceClientRef,
            'type': invoice['type'],
          };
        }
        imported++;
      } catch (_) {
        failed++;
      }
    }

    var importedPayments = 0;
    var failedPayments = 0;
    if (hasPaymentHistory && paymentSheet != null) {
      final paymentHeaders = paymentSheet.headers
          .map(_canonicalPaymentHeader)
          .toList();
      final seenPaymentRefs = _list(_snapshot['payments'])
          .map((payment) => payment['clientRef']?.toString())
          .whereType<String>()
          .toSet();
      for (var rowIndex = 0; rowIndex < paymentSheet.rows.length; rowIndex++) {
        final row = paymentSheet.rows[rowIndex];
        if (row.every((value) => value.trim().isEmpty)) continue;
        String paymentValue(String key) {
          final index = paymentHeaders.indexOf(key);
          return index >= 0 && index < row.length ? row[index].trim() : '';
        }

        final amount = _parseSpreadsheetNumber(paymentValue('amount'));
        final invoiceNumber = paymentValue('invoice_number');
        final partyName = paymentValue('party');
        if (amount == null || amount <= 0) {
          failedPayments++;
          continue;
        }
        var direction = _importPaymentDirection(paymentValue('direction'));
        if (direction.isEmpty) {
          direction = _importPaymentDirection(paymentValue('type'));
        }

        Map<String, dynamic>? invoiceRef;
        if (invoiceNumber.isNotEmpty) {
          if (direction == 'in') {
            invoiceRef = invoiceRefs[invoiceRefKey('sale', invoiceNumber)];
          } else if (direction == 'out') {
            invoiceRef = invoiceRefs[invoiceRefKey('purchase', invoiceNumber)];
          }
          invoiceRef ??= invoiceRefs.entries
              .where(
                (entry) =>
                    entry.key.endsWith(':${_normalizeSearch(invoiceNumber)}'),
              )
              .map((entry) => entry.value)
              .firstOrNull;
          if (invoiceRef != null && direction.isEmpty) {
            direction = invoiceRef['type'] == 'purchase' ? 'out' : 'in';
          }
        }
        if (direction.isEmpty) {
          failedPayments++;
          continue;
        }
        final party = _parties.firstWhere(
          (item) =>
              partyName.isNotEmpty &&
              _normalizeSearch(item['name']?.toString() ?? '') ==
                  _normalizeSearch(partyName),
          orElse: () => const <String, dynamic>{},
        );
        if (invoiceRef == null && party.isEmpty) {
          failedPayments++;
          continue;
        }
        final methodName = paymentValue('method');
        final method =
            paymentMethodsByName[_normalizeSearch(methodName)] ??
            (methodName.isEmpty ? _activePaymentMethods.firstOrNull : null);
        if (method == null || method['isActive'] == false) {
          failedPayments++;
          continue;
        }
        final paymentClientRef = paymentValue('client_ref').isNotEmpty
            ? paymentValue('client_ref')
            : const Uuid().v5(
                Namespace.url.value,
                'store-payment-import:$_userId:${invoiceNumber.isEmpty ? _normalizeSearch(partyName) : _normalizeSearch(invoiceNumber)}:$direction:${paymentValue('date')}:$amount:${_normalizeSearch(methodName)}:$rowIndex',
              );
        if (!seenPaymentRefs.add(paymentClientRef)) continue;
        try {
          await _store.queuePayment(
            userId: _userId,
            invoiceId: invoiceRef?['id']?.toString(),
            invoiceClientRef: invoiceRef?['clientRef']?.toString(),
            partyId: party['id']?.toString(),
            partyClientRef: party['clientRef']?.toString(),
            direction: direction,
            amount: amount,
            method: methodName.isEmpty
                ? method['name']?.toString() ?? 'cash'
                : methodName,
            paymentMethodId: method['id']?.toString(),
            paymentMethodClientRef: method['clientRef']?.toString(),
            notes: paymentValue('notes'),
            reference: paymentValue('reference'),
            clientRef: paymentClientRef,
            occurredAt: _parseImportDate(paymentValue('date')),
            actorUserId: _userId,
            actorName: _actorName,
          );
          importedPayments++;
        } catch (_) {
          failedPayments++;
        }
      }
    }
    if (imported > 0 || importedPayments > 0) {
      await _showLocalThenSync(sync: syncAfter);
    }
    if (!mounted) return;
    _showMessage(
      context.loc.text(
        'تم استيراد $imported فاتورة${hasPaymentHistory ? ' و$importedPayments دفعة' : ''}${failed + skipped + failedPayments > 0 ? '، وتجاوز ${failed + skipped + failedPayments} سجل' : ''}.',
        'Imported $imported invoices${hasPaymentHistory ? ' and $importedPayments payments' : ''}${failed + skipped + failedPayments > 0 ? '; skipped ${failed + skipped + failedPayments} records' : ''}.',
      ),
    );
  }

  double _spreadsheetDouble(dynamic value) =>
      value is num ? value.toDouble() : double.tryParse('$value') ?? 0;

  List<String> _parseCsvLine(String line, {String delimiter = ','}) {
    final values = <String>[];
    final current = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') {
        if (quoted && i + 1 < line.length && line[i + 1] == '"') {
          current.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (char == delimiter && !quoted) {
        values.add(current.toString());
        current.clear();
      } else {
        current.write(char);
      }
    }
    values.add(current.toString());
    return values;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _invoicesView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (_permissions.canCreateStoreSales)
            FilledButton.icon(
              onPressed: () => _createInvoice(quickSale: true),
              icon: const Icon(Icons.bolt_rounded),
              label: Text(context.loc.text('بيع سريع (F2)', 'Quick sale (F2)')),
            ),
          if (_permissions.canCreateStoreSales ||
              _permissions.canCreateStorePurchases)
            OutlinedButton.icon(
              onPressed: () => _createInvoice(),
              icon: const Icon(Icons.receipt_long_rounded),
              label: Text(
                context.loc.text('فاتورة جديدة (F3)', 'New invoice (F3)'),
              ),
            ),
          if (_permissions.canViewStoreReports ||
              _permissions.canManageStoreInventory ||
              _permissions.canManageStoreDebts)
            OutlinedButton.icon(
              onPressed: _exportWorkspaceExcel,
              icon: const Icon(Icons.download_rounded),
              label: Text(context.loc.text('تصدير البيانات', 'Export data')),
            ),
          if (_permissions.canCreateStoreSales ||
              _permissions.canCreateStorePurchases)
            OutlinedButton.icon(
              onPressed: _importInvoicesFile,
              icon: const Icon(Icons.upload_file_rounded),
              label: Text(
                context.loc.text(
                  'استيراد فواتير ودفعات',
                  'Import invoices and payments',
                ),
              ),
            ),
          if (_permissions.canCreateStoreSales ||
              _permissions.canCreateStorePurchases)
            TextButton.icon(
              onPressed: _downloadInvoiceTemplate,
              icon: const Icon(Icons.description_outlined),
              label: Text(
                context.loc.text('قالب الفواتير', 'Invoice template'),
              ),
            ),
          Text(
            context.loc.text(
              'تنقل: Alt+1…6 • حفظ: F6 أو Ctrl+Enter',
              'Navigate: Alt+1…6 • Save: F6 or Ctrl+Enter',
            ),
            style: AppTheme.caption,
          ),
        ],
      ),
      const SizedBox(height: 10),
      Expanded(
        child: _invoices.isEmpty
            ? _empty(context.loc.text('لا توجد فواتير بعد', 'No invoices yet'))
            : LayoutBuilder(
                builder: (context, constraints) => constraints.maxWidth >= 850
                    ? _invoicesTable(_invoices)
                    : ListView.separated(
                        padding: const EdgeInsets.only(bottom: 96),
                        itemCount: _invoices.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final item = _invoices[index];
                          return ShwakelCard(
                            padding: const EdgeInsets.all(14),
                            child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                item['type'] == 'sale'
                                    ? Icons.arrow_upward_rounded
                                    : Icons.arrow_downward_rounded,
                              ),
                              title: Text(
                                '${item['isQuickSale'] == true ? context.loc.text('بيع سريع يومي', 'Daily quick sale') : item['invoiceNumber']} • ${item['partyName']}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: AppTheme.bodyBold,
                              ),
                              subtitle: Text(
                                item['type'] == 'purchase' &&
                                        !_permissions.canViewStoreProfits
                                    ? '${context.loc.text('الكاشير', 'Cashier')}: ${item['cashierName'] ?? ''}\n${context.loc.text('تفاصيل أسعار الشراء خاصة بالحساب الرئيسي', 'Purchase prices are private to the primary account')} • ${_syncLabel(item)}'
                                    : '${context.loc.text('الكاشير', 'Cashier')}: ${item['cashierName'] ?? ''}\n${context.loc.text('المتبقي', 'Remaining')}: ${_money(item['dueAmount'])} • ${_syncLabel(item)}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Text(
                                item['type'] == 'purchase' &&
                                        !_permissions.canViewStoreProfits
                                    ? '—'
                                    : _money(item['total']),
                              ),
                              onTap:
                                  _permissions.canManageStoreDebts &&
                                      (item['type'] == 'purchase' &&
                                              !_permissions
                                                  .canViewStoreProfits ||
                                          ((item['dueAmount'] as num?)
                                                      ?.toDouble() ??
                                                  0) >
                                              0)
                                  ? () => _recordInvoicePayment(item)
                                  : null,
                            ),
                          );
                        },
                      ),
              ),
      ),
    ],
  );

  Widget _invoicesTable(List<Map<String, dynamic>> invoices) {
    final l = context.loc;
    return _tableScroller(
      DataTable(
        headingRowColor: WidgetStatePropertyAll(
          AppTheme.primary.withValues(alpha: 0.08),
        ),
        columns: [
          DataColumn(label: Text(l.text('رقم الفاتورة', 'Invoice'))),
          DataColumn(label: Text(l.text('التاريخ', 'Date'))),
          DataColumn(label: Text(l.text('النوع', 'Type'))),
          DataColumn(label: Text(l.text('الحساب', 'Account'))),
          DataColumn(label: Text(l.text('المخزن', 'Warehouse'))),
          DataColumn(label: Text(l.text('الكاشير', 'Cashier'))),
          DataColumn(label: Text(l.text('الإجمالي', 'Total'))),
          DataColumn(label: Text(l.text('المدفوع', 'Paid'))),
          DataColumn(label: Text(l.text('المتبقي', 'Due'))),
          DataColumn(label: Text(l.text('الدفع', 'Payment'))),
          DataColumn(label: Text(l.text('الحالة', 'Sync'))),
        ],
        rows: invoices.map((invoice) {
          final isPrivatePurchase =
              invoice['type'] == 'purchase' &&
              !_permissions.canViewStoreProfits;
          final canRecordPayment =
              _permissions.canManageStoreDebts &&
              (isPrivatePurchase ||
                  ((invoice['dueAmount'] as num?)?.toDouble() ?? 0) > 0);
          final date = DateTime.tryParse(
            invoice['occurredAt']?.toString() ?? '',
          );
          String two(int value) => value.toString().padLeft(2, '0');
          final dateLabel = date == null
              ? ''
              : '${two(date.toLocal().day)}/${two(date.toLocal().month)}/${date.toLocal().year}';
          return DataRow(
            onSelectChanged: canRecordPayment
                ? (_) => _recordInvoicePayment(invoice)
                : null,
            cells: [
              DataCell(Text(invoice['invoiceNumber']?.toString() ?? '')),
              DataCell(Text(dateLabel)),
              DataCell(
                Text(
                  invoice['type'] == 'purchase'
                      ? l.text('شراء', 'Purchase')
                      : l.text('بيع', 'Sale'),
                ),
              ),
              DataCell(Text(invoice['partyName']?.toString() ?? '')),
              DataCell(Text(invoice['warehouseName']?.toString() ?? '')),
              DataCell(Text(invoice['cashierName']?.toString() ?? '')),
              DataCell(
                Text(isPrivatePurchase ? '—' : _money(invoice['total'])),
              ),
              DataCell(
                Text(isPrivatePurchase ? '—' : _money(invoice['paidAmount'])),
              ),
              DataCell(
                Text(isPrivatePurchase ? '—' : _money(invoice['dueAmount'])),
              ),
              DataCell(Text(invoice['paymentMethodName']?.toString() ?? '')),
              DataCell(Text(_syncLabel(invoice))),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _partiesView() {
    final parties = _filterParties(_parties, _partySearchQuery);
    return Column(
      children: [
        if (_permissions.canManageStoreDebts) ...[
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _exportWorkspaceExcel,
                  icon: const Icon(Icons.download_rounded),
                  label: Text(
                    context.loc.text('تصدير البيانات', 'Export data'),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _importPartiesFile,
                  icon: const Icon(Icons.upload_file_rounded),
                  label: Text(
                    context.loc.text('استيراد حسابات', 'Import accounts'),
                  ),
                ),
                TextButton.icon(
                  onPressed: _downloadAccountsTemplate,
                  icon: const Icon(Icons.description_outlined),
                  label: Text(
                    context.loc.text('نموذج الحسابات', 'Accounts template'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        _searchField(
          controller: _partySearchController,
          focusNode: _partySearchFocusNode,
          label: context.loc.text(
            'بحث في الزبائن والتجار',
            'Search customers and suppliers',
          ),
          hint: context.loc.text(
            'الاسم أو الهاتف أو نوع الحساب',
            'Name, phone, or account type',
          ),
          onChanged: (value) => setState(() => _partySearchQuery = value),
          onClear: () {
            _partySearchController.clear();
            setState(() => _partySearchQuery = '');
          },
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _parties.isEmpty
              ? _empty(
                  context.loc.text(
                    'لا توجد حسابات زبائن أو تجار',
                    'No customer or supplier accounts',
                  ),
                )
              : parties.isEmpty
              ? _empty(
                  context.loc.text(
                    'لا توجد حسابات مطابقة للبحث',
                    'No matching accounts',
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) => constraints.maxWidth >= 850
                      ? _partiesTable(parties)
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: 96),
                          itemCount: parties.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final item = parties[index];
                            return ShwakelCard(
                              padding: const EdgeInsets.all(14),
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const CircleAvatar(
                                  child: Icon(Icons.person_outline),
                                ),
                                title: Text(
                                  item['name']?.toString() ?? '',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTheme.bodyBold,
                                ),
                                subtitle: Text(
                                  [
                                    if (item['phone']?.toString().isNotEmpty ==
                                        true)
                                      item['phone'].toString(),
                                    if (_permissions.canManageStoreDebts ||
                                        _permissions.canViewStoreReports)
                                      '${context.loc.text('عليه', 'Owes')}: ${_money(item['receivableBalance'])}',
                                    if (_permissions.canManageStoreDebts &&
                                        ((item['creditLimit'] as num?)
                                                    ?.toDouble() ??
                                                0) >
                                            0)
                                      '${context.loc.text('حد الدين', 'Credit limit')}: ${_money(item['creditLimit'])} • ${context.loc.text('المتبقي', 'Remaining')}: ${_money(((item['creditLimit'] as num).toDouble() - ((item['receivableBalance'] as num?)?.toDouble() ?? 0)).clamp(0, (item['creditLimit'] as num).toDouble()))}',
                                    if (_permissions.canViewStoreProfits)
                                      '${context.loc.text('له', 'Owed to him')}: ${_money(item['payableBalance'])}',
                                    _syncLabel(item),
                                  ].join(' • '),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: _permissions.canManageStoreDebts
                                    ? IconButton(
                                        tooltip: context.loc.text(
                                          'تعديل حد الدين',
                                          'Edit credit limit',
                                        ),
                                        onPressed: () =>
                                            _editPartyCreditLimit(item),
                                        icon: const Icon(Icons.tune_rounded),
                                      )
                                    : null,
                              ),
                            );
                          },
                        ),
                ),
        ),
      ],
    );
  }

  Widget _partiesTable(List<Map<String, dynamic>> parties) {
    final l = context.loc;
    return _tableScroller(
      DataTable(
        headingRowColor: WidgetStatePropertyAll(
          AppTheme.primary.withValues(alpha: 0.08),
        ),
        columns: [
          DataColumn(label: Text(l.text('الاسم', 'Name'))),
          DataColumn(label: Text(l.text('النوع', 'Type'))),
          DataColumn(label: Text(l.text('الهاتف', 'Phone'))),
          if (_permissions.canManageStoreDebts ||
              _permissions.canViewStoreReports)
            DataColumn(label: Text(l.text('له', 'Receivable'))),
          if (_permissions.canViewStoreProfits)
            DataColumn(label: Text(l.text('عليه', 'Payable'))),
          if (_permissions.canManageStoreDebts)
            DataColumn(label: Text(l.text('حد الدين', 'Credit limit'))),
          DataColumn(label: Text(l.text('المزامنة', 'Sync'))),
        ],
        rows: parties
            .map(
              (party) => DataRow(
                cells: [
                  DataCell(Text(party['name']?.toString() ?? '')),
                  DataCell(Text(_partyTypeLabel(party['type']?.toString()))),
                  DataCell(Text(party['phone']?.toString() ?? '')),
                  if (_permissions.canManageStoreDebts ||
                      _permissions.canViewStoreReports)
                    DataCell(Text(_money(party['receivableBalance']))),
                  if (_permissions.canViewStoreProfits)
                    DataCell(Text(_money(party['payableBalance']))),
                  if (_permissions.canManageStoreDebts)
                    DataCell(
                      TextButton.icon(
                        onPressed: () => _editPartyCreditLimit(party),
                        icon: const Icon(Icons.tune_rounded, size: 16),
                        label: Text(_money(party['creditLimit'])),
                      ),
                    ),
                  DataCell(Text(_syncLabel(party))),
                ],
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _searchField({
    required TextEditingController controller,
    FocusNode? focusNode,
    required String label,
    required String hint,
    required ValueChanged<String> onChanged,
    required VoidCallback onClear,
  }) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: controller.text.trim().isEmpty
            ? null
            : IconButton(
                tooltip: context.loc.text('مسح البحث', 'Clear search'),
                onPressed: onClear,
                icon: const Icon(Icons.close_rounded),
              ),
      ),
    );
  }

  void _focusCurrentSearch() {
    if (_tabs.index == 1) {
      _productSearchFocusNode.requestFocus();
    } else if (_tabs.index == 4) {
      _partySearchFocusNode.requestFocus();
    }
  }

  List<Map<String, dynamic>> _filterProducts(
    List<Map<String, dynamic>> products,
    String query,
  ) {
    final normalized = _normalizeSearch(query);
    if (normalized.isEmpty) return products;
    return products.where((product) {
      final units = _list(product['units'])
          .map(
            (unit) => [
              unit['name'],
              unit['code'],
              unit['barcode'],
            ].whereType<Object>().join(' '),
          )
          .join(' ');
      return _normalizeSearch(
        [
          product['name'],
          product['sku'],
          product['barcode'],
          product['baseUnit'],
          units,
        ].whereType<Object>().join(' '),
      ).contains(normalized);
    }).toList();
  }

  List<Map<String, dynamic>> _filterParties(
    List<Map<String, dynamic>> parties,
    String query,
  ) {
    final normalized = _normalizeSearch(query);
    if (normalized.isEmpty) return parties;
    return parties.where((party) {
      return _normalizeSearch(
        [
          party['name'],
          party['phone'],
          party['type'],
          _partyTypeLabel(party['type']?.toString() ?? ''),
        ].whereType<Object>().join(' '),
      ).contains(normalized);
    }).toList();
  }

  String _normalizeSearch(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\u064B-\u065F]'), '')
        .replaceAll('أ', 'ا')
        .replaceAll('إ', 'ا')
        .replaceAll('آ', 'ا')
        .replaceAll('ة', 'ه')
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  Widget _reportsView() {
    final l = context.loc;
    if (!_permissions.canViewStoreReports) {
      return Center(
        child: ShwakelCard(
          child: ListTile(
            leading: const Icon(Icons.lock_outline_rounded),
            title: Text(
              l.text(
                'التقارير محمية بصلاحية مستقلة',
                'Reports require a dedicated permission',
              ),
            ),
            subtitle: Text(
              l.text(
                'يمكن لمالك الحساب منح صلاحية عرض تقارير المحل لهذا الموظف من إدارة المستخدمين التابعين.',
                'The account owner can grant this employee store-report access from sub-user management.',
              ),
            ),
          ),
        ),
      );
    }
    final now = DateTime.now();
    final sales = _invoices.where((item) => item['type'] == 'sale').toList();
    double salesIn(Duration duration) => sales
        .where((item) {
          final date = DateTime.tryParse(item['occurredAt']?.toString() ?? '');
          return date != null && now.difference(date) <= duration;
        })
        .fold(
          0,
          (sum, item) => sum + ((item['total'] as num?)?.toDouble() ?? 0),
        );
    final yearSales = sales
        .where((item) {
          final date = DateTime.tryParse(item['occurredAt']?.toString() ?? '');
          return date != null && date.year == now.year;
        })
        .fold(
          0.0,
          (sum, item) => sum + ((item['total'] as num?)?.toDouble() ?? 0),
        );
    final profit = sales.fold(
      0.0,
      (sum, item) => sum + ((item['profitTotal'] as num?)?.toDouble() ?? 0),
    );
    final soldByProduct = <String, double>{};
    final soldNames = <String, String>{};
    for (final invoice in sales) {
      for (final item in _list(invoice['items'])) {
        final id = item['productId']?.toString() ?? '';
        if (id.isEmpty) continue;
        soldByProduct[id] =
            (soldByProduct[id] ?? 0) +
            ((item['baseQuantity'] as num?)?.toDouble() ?? 0);
        soldNames[id] = item['productName']?.toString() ?? id;
      }
    }
    final bestSellers = soldByProduct.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final stagnant = _products
        .where(
          (product) => !soldByProduct.containsKey(product['id']?.toString()),
        )
        .take(8)
        .toList();
    final lowStock = _stockAlerts;

    return ListView(
      children: [
        if (_warehouses.isNotEmpty && _permissions.canViewStoreProfits) ...[
          Text(l.text('تقرير المخازن', 'Warehouse report'), style: AppTheme.h3),
          const SizedBox(height: 8),
          ..._warehouses.map((warehouse) {
            final warehouseId = warehouse['id']?.toString();
            final value = _products.fold<double>(0, (sum, product) {
              final stock = _list(product['warehouseStocks']).firstWhere(
                (item) => item['warehouseId']?.toString() == warehouseId,
                orElse: () => const {},
              );
              return sum +
                  ((stock['quantity'] as num?)?.toDouble() ?? 0) *
                      ((product['averagePurchaseCost'] as num?)?.toDouble() ??
                          0);
            });
            final salesTotal = sales
                .where(
                  (invoice) =>
                      invoice['warehouseId']?.toString() == warehouseId,
                )
                .fold<double>(
                  0,
                  (sum, invoice) =>
                      sum + ((invoice['total'] as num?)?.toDouble() ?? 0),
                );
            return _reportTile(
              '${warehouse['name'] ?? ''}',
              '${l.text('قيمة المخزون', 'Inventory value')}: ${_money(value)} • ${l.text('المبيعات', 'Sales')}: ${_money(salesTotal)}',
            );
          }),
          const Divider(height: 28),
        ],
        _reportTile(
          l.text('مبيعات اليوم', "Today's sales"),
          _money(salesIn(const Duration(days: 1))),
        ),
        _reportTile(
          l.text('مبيعات الأسبوع', "This week's sales"),
          _money(salesIn(const Duration(days: 7))),
        ),
        _reportTile(
          l.text('مبيعات الشهر', "This month's sales"),
          _money(salesIn(const Duration(days: 31))),
        ),
        _reportTile(
          l.text('مبيعات السنة', "This year's sales"),
          _money(yearSales),
        ),
        if (_permissions.canViewStoreProfits)
          _reportTile(
            l.text('إجمالي الأرباح الظاهرة', 'Total visible profits'),
            _money(profit),
          ),
        if (_permissions.canViewStoreProfits)
          _reportTile(
            l.text('قيمة المخزون', 'Inventory value'),
            _money(_summary['inventoryValue']),
          ),
        _reportTile(
          l.text('ديون الزبائن', 'Customer debts'),
          _money(_summary['customerDebts']),
        ),
        _reportTile(
          l.text('ديون التجار', 'Supplier debts'),
          _money(_summary['supplierDebts']),
        ),
        const Divider(),
        ListTile(
          title: Text(l.text('أكثر الأصناف مبيعًا', 'Best selling items')),
          subtitle: Text(
            bestSellers.take(5).isEmpty
                ? l.text('لا توجد مبيعات بعد', 'No sales yet')
                : bestSellers
                      .take(5)
                      .map(
                        (entry) => '${soldNames[entry.key]} (${entry.value})',
                      )
                      .join('، '),
          ),
        ),
        ListTile(
          title: Text(l.text('الأصناف الراكدة', 'Stagnant items')),
          subtitle: Text(
            stagnant.isEmpty
                ? l.text('لا توجد أصناف راكدة', 'No stagnant items')
                : stagnant.map((item) => item['name']).join('، '),
          ),
        ),
        ListTile(
          title: Text(l.text('تنبيهات المخزون', 'Stock alerts')),
          subtitle: Text(
            lowStock.isEmpty
                ? l.text(
                    'كل الأصناف أعلى من حد التنبيه',
                    'All items are above the alert threshold',
                  )
                : lowStock.map((item) => item['name']).join('، '),
          ),
        ),
        ListTile(
          title: Text(l.text('حركة المستخدمين', 'User activity')),
          subtitle: Text(
            l.text(
              'تُحفظ كل عمليات الإضافة والفواتير والدفعات في سجل النشاط على السيرفر.',
              'All add operations, invoices, and payments are saved in the activity log on the server.',
            ),
          ),
        ),
      ],
    );
  }

  Widget _reportTile(String title, String value) => ListTile(
    title: Text(title),
    trailing: Text(value, style: AppTheme.bodyBold),
  );

  Widget _empty(String title) => Center(
    child: Text(title, style: AppTheme.h3, textAlign: TextAlign.center),
  );

  static List<Map<String, dynamic>> _list(dynamic value) {
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  static String _money(dynamic value) =>
      '${((value as num?)?.toDouble() ?? 0).toStringAsFixed(2)} ₪';

  static bool _isLocalRecord(Map<String, dynamic> item) =>
      (item['id']?.toString().startsWith('local:') ?? false) ||
      (item['syncStatus']?.toString() == 'pending');

  static String _syncLabel(Map<String, dynamic> item) =>
      _isLocalRecord(item) ? 'Local - pending sync' : 'Synced';

  static String _unitName(String code) => switch (code) {
    'piece' => 'حبة',
    'carton' => 'كرتونة',
    'bag' => 'كيس',
    'pallet' => 'مشطاح',
    'kg' => 'كيلو',
    'liter' => 'لتر',
    'box' => 'صندوق',
    _ => code,
  };
}
