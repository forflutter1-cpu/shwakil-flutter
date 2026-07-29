import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';

import '../services/index.dart';
import '../utils/app_permissions.dart';
import '../utils/app_theme.dart';
import '../widgets/app_sidebar.dart';
import '../widgets/app_top_actions.dart';
import '../widgets/barcode_scanner_dialog.dart';
import '../widgets/responsive_scaffold_container.dart';
import '../widgets/shwakel_card.dart';

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
  late final TabController _tabs = TabController(length: 6, vsync: this)
    ..addListener(() => setState(() {}));
  Map<String, dynamic>? _user;
  Map<String, dynamic> _snapshot = const {};
  List<Map<String, dynamic>> _publicOrders = const [];
  List<Map<String, dynamic>> _pending = const [];
  bool _loading = true;
  bool _syncing = false;
  String? _error;
  String _productSearchQuery = '';
  String _partySearchQuery = '';

  AppPermissions get _permissions => AppPermissions.fromUser(_user);
  String get _userId => _user?['id']?.toString() ?? '';
  List<Map<String, dynamic>> get _products => _list(_snapshot['products']);
  List<Map<String, dynamic>> get _warehouses => _list(_snapshot['warehouses']);
  List<Map<String, dynamic>> get _parties => _list(_snapshot['parties']);
  List<Map<String, dynamic>> get _invoices => _list(_snapshot['invoices']);
  List<Map<String, dynamic>> get _debtBookAccounts =>
      _list(_snapshot['debtBookAccounts']);
  Map<String, dynamic> get _summary => _snapshot['summary'] is Map
      ? Map<String, dynamic>.from(_snapshot['summary'] as Map)
      : const {};
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
      final publicOrders = permissions.canManagePublicStorefront
          ? await _fetchPublicOrders()
          : const <Map<String, dynamic>>[];
      if (mounted) {
        setState(() {
          _user = user;
          _snapshot = local;
          _publicOrders = publicOrders;
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
      final publicOrders = _permissions.canManagePublicStorefront
          ? await _fetchPublicOrders()
          : const <Map<String, dynamic>>[];
      final pending = await _store.getPendingOperations(_userId);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _publicOrders = publicOrders;
        _pending = pending;
        _loading = false;
        _syncing = false;
      });
    } catch (error) {
      if (!mounted) return;
      final local = await _store.getSnapshot(_userId);
      final pending = await _store.getPendingOperations(_userId);
      if (!mounted) return;
      setState(() {
        _snapshot = local;
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
      _snapshot = snapshot;
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
  }) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (pageContext) => StatefulBuilder(
          builder: (formContext, setFormState) => Scaffold(
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
                        onPressed: () => Navigator.pop(pageContext, false),
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
      ),
    );
  }

  Future<void> _showLocalThenSync() async {
    final local = await _store.getSnapshot(_userId);
    final pending = await _store.getPendingOperations(_userId);
    if (mounted) {
      setState(() {
        _snapshot = local;
        _pending = pending;
        _loading = false;
      });
    }
    await _sync();
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
    final factor = TextEditingController(text: '24');
    final purchasePrice = TextEditingController(text: '0');
    final salePrice = TextEditingController(text: '0');
    final publicMaxQuantity = TextEditingController();
    String baseUnit = 'piece';
    String packageUnit = 'carton';
    bool publicVisible = false;
    bool publicAllowOnlineSale = false;
    final l = context.loc;
    final accepted = await _openFullScreenForm(
      title: l.text('إضافة صنف جديد', 'Add new item'),
      actionLabel: l.text('حفظ الصنف', 'Save item'),
      canSubmit: () => name.text.trim().isNotEmpty,
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
          const SizedBox(height: 10),
          TextField(
            controller: purchasePrice,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
      await _store.queueProduct(
        userId: _userId,
        name: name.text,
        baseUnit: baseUnit,
        minimumStock: 0,
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
      await _showLocalThenSync();
    }
    name.dispose();
    barcode.dispose();
    factor.dispose();
    purchasePrice.dispose();
    salePrice.dispose();
    publicMaxQuantity.dispose();
  }

  Future<void> _addParty() async {
    final name = TextEditingController();
    final phone = TextEditingController();
    String type = 'customer';
    String? selectedDebtBookAccountId;
    String debtSearch = '';
    final l = context.loc;
    final accepted = await _openFullScreenForm(
      title: l.text('إضافة زبون أو تاجر', 'Add customer or supplier'),
      actionLabel: l.text('حفظ الحساب', 'Save account'),
      canSubmit: () => name.text.trim().isNotEmpty,
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
      );
      await _showLocalThenSync();
    }
    name.dispose();
    phone.dispose();
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

  Future<void> _createInvoice({bool quickSale = false}) async {
    if (_products.isEmpty) return;
    String invoiceType = quickSale || _permissions.canCreateStoreSales
        ? 'sale'
        : 'purchase';
    String? partyId;
    String? warehouseId = _warehouses
        .firstWhere(
          (warehouse) => warehouse['isDefault'] == true,
          orElse: () => _warehouses.isNotEmpty ? _warehouses.first : const {},
        )['id']
        ?.toString();
    String paymentStatus = 'paid';
    final paid = TextEditingController(text: '0');
    final discount = TextEditingController(text: '0');
    final lines = <Map<String, dynamic>>[];

    Map<String, dynamic> productById(String? id) => _products.firstWhere(
      (item) => item['id']?.toString() == id,
      orElse: () => _products.first,
    );

    Map<String, dynamic>? firstUnit(Map<String, dynamic> product) {
      final units = _list(product['units']);
      return units.isEmpty ? null : units.first;
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

    void addLine(Map<String, dynamic> product, Map<String, dynamic>? unit) {
      final existingIndex = lines.indexWhere(
        (line) =>
            line['productId']?.toString() == product['id']?.toString() &&
            line['unitId']?.toString() == unit?['id']?.toString(),
      );
      if (existingIndex >= 0) {
        lines[existingIndex]['quantity'] =
            ((lines[existingIndex]['quantity'] as num?)?.toDouble() ?? 0) + 1;
        return;
      }
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
      canSubmit: () =>
          lines.isNotEmpty &&
          warehouseId != null &&
          !(invoiceType == 'purchase' && partyId == null),
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

        void refreshPricesForType() {
          for (final line in lines) {
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
                    partyId = null;
                    refreshPricesForType();
                  });
                },
              ),
            const SizedBox(height: 12),
            if (!quickSale)
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
                onChanged: (value) => setDialogState(() => warehouseId = value),
              ),
            if (!quickSale) const SizedBox(height: 10),
            if (!quickSale) ...[
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
                        ? l.text('الزبون (اختياري)', 'Customer (optional)')
                        : l.text('المورد المطلوب', 'Required supplier'),
                    prefixIcon: const Icon(Icons.person_search_rounded),
                  ),
                  child: Text(
                    partyId == null
                        ? (invoiceType == 'sale'
                              ? l.text('زبون نقدي', 'Cash customer')
                              : l.text('اضغط للاختيار', 'Tap to choose'))
                        : allowedParties
                                  .firstWhere(
                                    (item) => item['id']?.toString() == partyId,
                                    orElse: () => const {},
                                  )['name']
                                  ?.toString() ??
                              '',
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
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
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: scanIntoInvoice,
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: Text(l.text('إضافة بالباركود', 'Add by barcode')),
            ),
            const SizedBox(height: 12),
            if (lines.isEmpty)
              Text(
                l.text(
                  'أضف صنفًا واحدًا على الأقل للفاتورة.',
                  'Add at least one item to the invoice.',
                ),
              )
            else
              ...lines.asMap().entries.map((entry) {
                final index = entry.key;
                final line = entry.value;
                final lineTotal =
                    ((line['quantity'] as num?)?.toDouble() ?? 0) *
                    ((line['unitPrice'] as num?)?.toDouble() ?? 0);
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${line['name']} • ${line['unitName']}',
                                style: AppTheme.bodyBold,
                              ),
                            ),
                            IconButton(
                              onPressed: () =>
                                  setDialogState(() => lines.removeAt(index)),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final compact = constraints.maxWidth < 560;
                            final fields = [
                              TextFormField(
                                key: ValueKey('qty-$index-${line['quantity']}'),
                                initialValue:
                                    ((line['quantity'] as num?)?.toDouble() ??
                                            1)
                                        .toString(),
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: InputDecoration(
                                  labelText: l.text('الكمية', 'Quantity'),
                                ),
                                onChanged: (value) => setDialogState(
                                  () => line['quantity'] =
                                      double.tryParse(value) ?? 0,
                                ),
                              ),
                              TextFormField(
                                key: ValueKey(
                                  'price-$index-${line['unitPrice']}',
                                ),
                                initialValue:
                                    ((line['unitPrice'] as num?)?.toDouble() ??
                                            0)
                                        .toStringAsFixed(2),
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: InputDecoration(
                                  labelText: invoiceType == 'sale'
                                      ? l.text('سعر البيع', 'Sale price')
                                      : l.text('سعر الشراء', 'Purchase price'),
                                ),
                                onChanged: (value) => setDialogState(
                                  () => line['unitPrice'] =
                                      double.tryParse(value) ?? 0,
                                ),
                              ),
                              if (invoiceType == 'purchase' &&
                                  _permissions.canEditStorePrices)
                                TextFormField(
                                  key: ValueKey(
                                    'sale-$index-${line['salePrice']}',
                                  ),
                                  initialValue:
                                      ((line['salePrice'] as num?)
                                                  ?.toDouble() ??
                                              0)
                                          .toStringAsFixed(2),
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  decoration: InputDecoration(
                                    labelText: l.text(
                                      'سعر البيع لاحقًا',
                                      'Future sale price',
                                    ),
                                  ),
                                  onChanged: (value) => setDialogState(
                                    () => line['salePrice'] =
                                        double.tryParse(value) ?? 0,
                                  ),
                                ),
                            ];
                            return Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: fields
                                  .map(
                                    (field) => SizedBox(
                                      width: compact
                                          ? constraints.maxWidth
                                          : (constraints.maxWidth - 16) /
                                                fields.length,
                                      child: field,
                                    ),
                                  )
                                  .toList(),
                            );
                          },
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${l.text('المجموع', 'Total')}: ${_money(lineTotal)}',
                        ),
                      ],
                    ),
                  ),
                );
              }),
            const SizedBox(height: 10),
            TextField(
              controller: discount,
              onChanged: (_) => setDialogState(() {}),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(labelText: l.text('خصم', 'Discount')),
            ),
            const SizedBox(height: 10),
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
                DropdownMenuItem(
                  value: 'partial',
                  child: Text(l.text('مدفوعة جزئيًا', 'Partially paid')),
                ),
                DropdownMenuItem(
                  value: 'debt',
                  child: Text(l.text('دين بالكامل', 'Full debt')),
                ),
              ],
              onChanged: (value) =>
                  setDialogState(() => paymentStatus = value ?? 'paid'),
            ),
            if (paymentStatus == 'partial') ...[
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
      final selectedParty = _parties.firstWhere(
        (party) => party['id']?.toString() == partyId,
        orElse: () => const <String, dynamic>{},
      );
      final selectedWarehouse = _warehouses.firstWhere(
        (warehouse) => warehouse['id']?.toString() == warehouseId,
        orElse: () => const <String, dynamic>{},
      );
      await _store.queueInvoice(
        userId: _userId,
        invoiceType: invoiceType,
        partyId: partyId,
        partyClientRef: selectedParty['clientRef']?.toString(),
        warehouseId: warehouseId,
        warehouseClientRef: selectedWarehouse['clientRef']?.toString(),
        paidAmount: paidAmount,
        paymentMethod: 'cash',
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
                if (invoiceType == 'purchase')
                  'salePrice': (line['salePrice'] as num?)?.toDouble() ?? 0,
              },
            )
            .toList(),
        quickSale: quickSale,
      );
      await _showLocalThenSync();
    }
    paid.dispose();
    discount.dispose();
  }

  Future<void> _recordInvoicePayment(Map<String, dynamic> invoice) async {
    final due = (invoice['dueAmount'] as num?)?.toDouble() ?? 0;
    if (due <= 0 || !_permissions.canManageStoreDebts) return;
    final amount = TextEditingController(text: due.toStringAsFixed(2));
    final l = context.loc;
    final accepted = await _openFullScreenForm(
      title:
          '${l.text('تسجيل دفعة', 'Record payment')} ${invoice['invoiceNumber']}',
      actionLabel: l.text('حفظ الدفعة', 'Save payment'),
      canSubmit: () => (double.tryParse(amount.text) ?? 0) > 0,
      builder: (context, setFormState) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: amount,
            onChanged: (_) => setFormState(() {}),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l.text('المبلغ المدفوع', 'Amount paid'),
              helperText: '${l.text('المتبقي', 'Remaining')} ${_money(due)}',
            ),
          ),
        ],
      ),
    );
    final value = double.tryParse(amount.text) ?? 0;
    amount.dispose();
    if (accepted == true && value > 0) {
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
    return Scaffold(
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
          ? const Center(child: CircularProgressIndicator())
          : ResponsiveScaffoldContainer(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (_error != null)
                    Text(
                      _error!,
                      style: const TextStyle(color: AppTheme.error),
                    ),
                  if (_pending.isNotEmpty)
                    _pendingSyncNotice()
                  else if (_syncedAt.isNotEmpty)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Chip(
                        avatar: const Icon(Icons.verified_rounded, size: 18),
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
    final products = _filterProducts(_products, _productSearchQuery);
    if (_products.isEmpty) {
      return _empty(context.loc.text('لا توجد أصناف بعد', 'No items yet'));
    }
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
                  onPressed: _exportProductsCsv,
                  icon: const Icon(Icons.download_rounded),
                  label: Text(
                    context.loc.text('تصدير الأصناف', 'Export items'),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _importProductsCsv,
                  icon: const Icon(Icons.upload_file_rounded),
                  label: Text(context.loc.text('استيراد CSV', 'Import CSV')),
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
                'الاستيراد ينشئ أو يحدّث تعريف الأصناف فقط؛ أرصدة المخزون تُسجل نظاميًا عبر فواتير الشراء أو التحويل بين المخازن.',
                'Import creates or updates item definitions only; stock balances must be recorded through purchase invoices or warehouse transfers.',
              ),
              style: AppTheme.caption,
            ),
          ),
          const SizedBox(height: 10),
        ],
        _searchField(
          controller: _productSearchController,
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
        Expanded(
          child: products.isEmpty
              ? _empty(
                  context.loc.text(
                    'لا توجد أصناف مطابقة للبحث',
                    'No matching items',
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: products.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = products[index];
                    final unit = _unitName(item['baseUnit']?.toString() ?? '');
                    return ShwakelCard(
                      padding: const EdgeInsets.all(14),
                      borderColor: item['publicVisible'] == true
                          ? AppTheme.success.withValues(alpha: 0.22)
                          : null,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const CircleAvatar(
                          child: Icon(Icons.inventory_2),
                        ),
                        title: Text(
                          item['name']?.toString() ?? '',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTheme.bodyBold,
                        ),
                        subtitle: Text(
                          '${context.loc.text('المتوفر', 'Available')}: ${item['stockQuantity'] ?? 0} $unit'
                          '${item['publicVisible'] == true ? ' • ${context.loc.text('ظاهر للعامة', 'visible to public')}' : ''}'
                          '${item['publicAllowOnlineSale'] == true ? ' • ${context.loc.text('بيع أونلاين', 'online sale')}' : ''}'
                          ' • ${_syncLabel(item)}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(_money(item['defaultSalePrice'])),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _exportProductsCsv() async {
    final buffer = StringBuffer()
      ..writeln(
        '\uFEFFname,base_unit,purchase_price,sale_price,minimum_stock,barcode,stock_quantity',
      );
    for (final product in _products) {
      final units = _list(product['units']);
      final base = units.firstWhere(
        (unit) => unit['isBase'] == true,
        orElse: () =>
            units.isNotEmpty ? units.first : const <String, dynamic>{},
      );
      buffer.writeln(
        [
          product['name'],
          product['baseUnit'],
          base['purchasePrice'] ?? product['averagePurchaseCost'],
          product['defaultSalePrice'],
          product['minimumStock'],
          base['barcode'],
          product['stockQuantity'],
        ].map(_csvCell).join(','),
      );
    }
    await _saveCsv(
      'inventory_${DateTime.now().toIso8601String().substring(0, 10)}',
      buffer.toString(),
    );
  }

  Future<void> _downloadProductsTemplate() => _saveCsv(
    'inventory_import_template',
    '\uFEFFname,base_unit,purchase_price,sale_price,minimum_stock,barcode\n'
        'مثال صنف,piece,10,15,5,123456789\n',
  );

  Future<void> _importProductsCsv() async {
    final l = context.loc;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv'],
      withData: true,
    );
    final bytes = picked?.files.single.bytes;
    if (bytes == null) return;
    final lines = const LineSplitter().convert(
      utf8.decode(bytes, allowMalformed: true),
    );
    if (lines.length < 2) {
      _showMessage(l.text('ملف الاستيراد فارغ.', 'The import file is empty.'));
      return;
    }
    final headers = _parseCsvLine(
      lines.first.replaceFirst('\uFEFF', ''),
    ).map((value) => value.trim().toLowerCase()).toList();
    final requiredHeaders = [
      'name',
      'base_unit',
      'purchase_price',
      'sale_price',
    ];
    if (!requiredHeaders.every(headers.contains)) {
      _showMessage(
        l.text(
          'عناوين الملف غير صحيحة. استخدم نموذج الاستيراد المعتمد.',
          'Invalid columns. Please use the official import template.',
        ),
      );
      return;
    }
    var imported = 0;
    var skipped = 0;
    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) continue;
      final values = _parseCsvLine(line);
      String value(String key) {
        final index = headers.indexOf(key);
        return index >= 0 && index < values.length ? values[index].trim() : '';
      }

      final name = value('name');
      final baseUnit = value('base_unit');
      final purchase = double.tryParse(value('purchase_price'));
      final sale = double.tryParse(value('sale_price'));
      if (name.isEmpty ||
          baseUnit.isEmpty ||
          purchase == null ||
          sale == null ||
          purchase < 0 ||
          sale < 0) {
        skipped++;
        continue;
      }
      final existing = _products.firstWhere(
        (product) =>
            product['name']?.toString().trim().toLowerCase() ==
            name.toLowerCase(),
        orElse: () => const <String, dynamic>{},
      );
      await _store.queueProduct(
        userId: _userId,
        serverId: existing['id']?.toString(),
        clientRef: existing['clientRef']?.toString(),
        name: name,
        baseUnit: baseUnit,
        minimumStock: double.tryParse(value('minimum_stock')) ?? 0,
        salePrice: sale,
        units: [
          {
            'name': _unitName(baseUnit),
            'code': baseUnit,
            'factorToBase': 1,
            'isBase': true,
            'purchasePrice': purchase,
            'salePrice': sale,
            'barcode': value('barcode'),
          },
        ],
      );
      imported++;
    }
    if (imported > 0) await _showLocalThenSync();
    _showMessage(
      l.text(
        'تم استيراد $imported صنف${skipped > 0 ? '، وتجاوز $skipped صف غير صالح' : ''}.',
        'Imported $imported items${skipped > 0 ? '; skipped $skipped invalid rows' : ''}.',
      ),
    );
  }

  Future<void> _saveCsv(String name, String content) =>
      FileSaver.instance.saveFile(
        name: name,
        bytes: Uint8List.fromList(utf8.encode(content)),
        fileExtension: 'csv',
        mimeType: MimeType.csv,
      );

  String _csvCell(dynamic value) =>
      '"${(value ?? '').toString().replaceAll('"', '""')}"';

  List<String> _parseCsvLine(String line) {
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
      } else if (char == ',' && !quoted) {
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
      if (_permissions.canCreateStoreSales) ...[
        FilledButton.icon(
          onPressed: () => _createInvoice(quickSale: true),
          icon: const Icon(Icons.bolt_rounded),
          label: Text(context.loc.text('بيع سريع', 'Quick sale')),
        ),
        const SizedBox(height: 10),
      ],
      Expanded(
        child: _invoices.isEmpty
            ? _empty(context.loc.text('لا توجد فواتير بعد', 'No invoices yet'))
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
                        '${context.loc.text('الكاشير', 'Cashier')}: ${item['cashierName'] ?? ''}\n${context.loc.text('المتبقي', 'Remaining')}: ${_money(item['dueAmount'])} • ${_syncLabel(item)}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(_money(item['total'])),
                      onTap: () => _recordInvoicePayment(item),
                    ),
                  );
                },
              ),
      ),
    ],
  );

  Widget _partiesView() {
    final parties = _filterParties(_parties, _partySearchQuery);
    if (_parties.isEmpty) {
      return _empty(
        context.loc.text(
          'لا توجد حسابات زبائن أو تجار',
          'No customer or supplier accounts',
        ),
      );
    }
    return Column(
      children: [
        _searchField(
          controller: _partySearchController,
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
          child: parties.isEmpty
              ? _empty(
                  context.loc.text(
                    'لا توجد حسابات مطابقة للبحث',
                    'No matching accounts',
                  ),
                )
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
                          '${context.loc.text('عليه', 'Owes')}: ${_money(item['receivableBalance'])} • ${context.loc.text('له', 'Owed to him')}: ${_money(item['payableBalance'])} • ${_syncLabel(item)}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(
                          item['phone']?.toString() ?? '',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _searchField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required ValueChanged<String> onChanged,
    required VoidCallback onClear,
  }) {
    return TextField(
      controller: controller,
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
    final lowStock = _products.where((product) {
      final min = (product['minimumStock'] as num?)?.toDouble() ?? 0;
      final stock = (product['stockQuantity'] as num?)?.toDouble() ?? 0;
      return min > 0 && stock <= min;
    }).toList();

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
          title: Text(l.text('المخزون المنخفض', 'Low stock')),
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
