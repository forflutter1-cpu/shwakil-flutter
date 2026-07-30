import 'dart:async';
import 'dart:convert';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/index.dart';
import '../utils/app_permissions.dart';
import '../utils/app_theme.dart';
import '../widgets/app_sidebar.dart';
import '../widgets/responsive_scaffold_container.dart';
import '../widgets/shwakel_card.dart';

class MaintenanceManagementScreen extends StatefulWidget {
  const MaintenanceManagementScreen({super.key});
  @override
  State<MaintenanceManagementScreen> createState() =>
      _MaintenanceManagementScreenState();
}

class _MaintenanceManagementScreenState
    extends State<MaintenanceManagementScreen>
    with SingleTickerProviderStateMixin {
  final _api = ApiService();
  final _offlineStore = StoreManagementService();
  final _auth = AuthService();
  final _search = TextEditingController();
  late final TabController _tabs = TabController(length: 3, vsync: this);
  Map<String, dynamic> _data = const {};
  bool _loading = true;
  String? _error;
  String _status = '';
  String? _userId;
  String _actorName = '';
  int _pendingCount = 0;
  bool _offline = false;
  AppPermissions _appPermissions = AppPermissions.fromUser(null);

  List<Map<String, dynamic>> get _orders => _list(_data['orders']);
  List<Map<String, dynamic>> get _employees => _list(_data['employees']);
  List<Map<String, dynamic>> get _products => _list(_data['products']);
  List<Map<String, dynamic>> get _warehouses => _list(_data['warehouses']);
  List<Map<String, dynamic>> get _paymentMethods => _list(
    _data['paymentMethods'],
  ).where((method) => method['isActive'] != false).toList();
  List<Map<String, dynamic>> get _technicianPerformance =>
      _list(_data['technicianPerformance']);
  Map<String, dynamic> get _summary => _map(_data['summary']);
  Map<String, dynamic> get _permissions => _map(_data['permissions']);
  bool get _canManageInventory =>
      _permissions['canManageStoreInventory'] == true;
  bool get _canCreateSales => _permissions['canCreateStoreSales'] == true;
  bool get _canViewProfits => _permissions['canViewStoreProfits'] == true;
  bool get _canViewReports => _permissions['canViewStoreReports'] == true;
  bool get _canOpenEmployees => _appPermissions.canViewSubUsers;
  bool get _canManageEmployees => _appPermissions.canManageSubUsers;

  @override
  void initState() {
    super.initState();
    ConnectivityService.instance.isOnline.addListener(_handleConnectivity);
    unawaited(_bootstrap());
  }

  void _handleConnectivity() {
    if (ConnectivityService.instance.isOnline.value && _pendingCount > 0) {
      unawaited(_load());
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ConnectivityService.instance.isOnline.removeListener(_handleConnectivity);
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final user = await _auth.currentUser();
    _appPermissions = AppPermissions.fromUser(user);
    _userId = user?['id']?.toString();
    _actorName = user?['fullName']?.toString().trim().isNotEmpty == true
        ? user!['fullName'].toString()
        : user?['name']?.toString().trim().isNotEmpty == true
        ? user!['name'].toString()
        : user?['username']?.toString() ?? '';
    if (_userId != null) {
      final cached = await _offlineStore.getMaintenanceSnapshot(_userId!);
      if (cached.isNotEmpty && mounted) {
        setState(() {
          _data = cached;
          _loading = false;
        });
      }
    }
    await _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      if (_userId != null) {
        await _offlineStore.syncPending(userId: _userId!, api: _api);
      }
      final data = await _api.getMaintenanceSnapshot(
        search: _search.text,
        status: _status,
      );
      if (_userId != null) {
        await _offlineStore.cacheMaintenanceSnapshot(_userId!, data);
      }
      final pending = _userId == null
          ? const <Map<String, dynamic>>[]
          : await _offlineStore.getPendingOperations(_userId!);
      if (mounted) {
        setState(() {
          _data = data;
          _loading = false;
          _offline = false;
          _pendingCount = pending
              .where((e) => e['entity'] == 'maintenance')
              .length;
        });
      }
    } catch (e) {
      final cached = _userId == null
          ? const <String, dynamic>{}
          : await _offlineStore.getMaintenanceSnapshot(_userId!);
      final pending = _userId == null
          ? const <Map<String, dynamic>>[]
          : await _offlineStore.getPendingOperations(_userId!);
      if (mounted) {
        setState(() {
          _loading = false;
          if (cached.isNotEmpty) _data = cached;
          _offline = true;
          _pendingCount = pending
              .where((item) => item['entity'] == 'maintenance')
              .length;
          _error = cached.isEmpty ? ErrorMessageService.sanitize(e) : null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppTheme.background,
    drawer: AppSidebar.drawerFor(
      context,
      currentRouteName: '/maintenance-management',
    ),
    appBar: AppBar(
      title: Text(context.loc.text('إدارة الصيانة', 'Maintenance management')),
      actions: [
        if (_offline || _pendingCount > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Chip(
              avatar: Icon(
                _offline ? Icons.cloud_off_rounded : Icons.sync_rounded,
                size: 17,
              ),
              label: Text(
                _offline
                    ? context.loc.text(
                        'دون إنترنت • $_pendingCount معلّق',
                        'Offline • $_pendingCount pending',
                      )
                    : context.loc.text(
                        '$_pendingCount بانتظار المزامنة',
                        '$_pendingCount pending',
                      ),
              ),
            ),
          ),
        if (_canViewReports)
          IconButton(
            tooltip: context.loc.text('تصدير CSV', 'Export CSV'),
            onPressed: _orders.isEmpty ? null : _exportCsv,
            icon: const Icon(Icons.download_rounded),
          ),
        IconButton(
          tooltip: context.loc.text('تحديث', 'Refresh'),
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _newOrder,
      icon: const Icon(Icons.add_rounded),
      label: Text(context.loc.text('استلام جهاز', 'Receive device')),
    ),
    body: ResponsiveScaffoldContainer(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _header(),
          const SizedBox(height: 12),
          TabBar(
            controller: _tabs,
            tabs: [
              Tab(text: context.loc.text('لوحة المتابعة', 'Dashboard')),
              Tab(text: context.loc.text('الصيانات', 'Orders')),
              Tab(text: context.loc.text('التقارير', 'Reports')),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? _errorView()
                : TabBarView(
                    controller: _tabs,
                    children: [_dashboard(), _ordersView(), _reports()],
                  ),
          ),
        ],
      ),
    ),
  );

  Widget _header() => ShwakelCard(
    padding: const EdgeInsets.all(14),
    child: Column(
      children: [
        TextField(
          controller: _search,
          onSubmitted: (_) => _load(),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: context.loc.text(
              'رقم الصيانة، العميل، الهاتف، الجهاز، السيريال أو المكان',
              'Order, customer, phone, device, serial or location',
            ),
            suffixIcon: IconButton(
              onPressed: _load,
              icon: const Icon(Icons.arrow_forward_rounded),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children:
                [
                      '',
                      'received',
                      'diagnosing',
                      'waiting_customer',
                      'waiting_parts',
                      'in_progress',
                      'completed',
                      'delivered',
                    ]
                    .map(
                      (s) => Padding(
                        padding: const EdgeInsetsDirectional.only(end: 8),
                        child: ChoiceChip(
                          label: Text(
                            s.isEmpty
                                ? context.loc.text('الكل', 'All')
                                : _statusLabel(s),
                          ),
                          selected: _status == s,
                          onSelected: (_) {
                            setState(() => _status = s);
                            _load();
                          },
                        ),
                      ),
                    )
                    .toList(),
          ),
        ),
      ],
    ),
  );

  Widget _dashboard() => ListView(
    children: [
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _metric(
            context.loc.text('قيد المتابعة', 'Active'),
            _summary['active'],
            Icons.engineering_rounded,
            Colors.blue,
          ),
          _metric(
            context.loc.text('بانتظار العميل', 'Waiting customer'),
            _summary['waitingCustomer'],
            Icons.phone_in_talk_rounded,
            Colors.orange,
          ),
          _metric(
            context.loc.text('جاهزة للتسليم', 'Ready'),
            _summary['completed'],
            Icons.task_alt_rounded,
            Colors.green,
          ),
        ],
      ),
      const SizedBox(height: 14),
      Text(
        context.loc.text('آخر الصيانات', 'Latest maintenance'),
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      ..._orders.take(8).map(_orderCard),
      const SizedBox(height: 80),
    ],
  );

  Widget _ordersView() => _orders.isEmpty
      ? Center(
          child: Text(
            context.loc.text('لا توجد صيانات مطابقة.', 'No matching orders.'),
          ),
        )
      : ListView(
          children: [..._orders.map(_orderCard), const SizedBox(height: 80)],
        );

  Widget _reports() => !_canViewReports
      ? Center(
          child: ShwakelCard(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline_rounded, size: 42),
                const SizedBox(height: 10),
                Text(
                  context.loc.text(
                    'لا تملك صلاحية عرض تقارير الصيانة.',
                    'You do not have permission to view maintenance reports.',
                  ),
                ),
              ],
            ),
          ),
        )
      : ListView(
          children: [
            _periodReport(
              context.loc.text('اليوم', 'Today'),
              _map(_summary['today']),
              Icons.today_rounded,
            ),
            _periodReport(
              context.loc.text('هذا الشهر', 'This month'),
              _map(_summary['month']),
              Icons.calendar_month_rounded,
            ),
            _periodReport(
              context.loc.text('هذه السنة', 'This year'),
              _map(_summary['year']),
              Icons.date_range_rounded,
            ),
            const SizedBox(height: 8),
            Text(
              context.loc.text('أداء فنيي الصيانة', 'Technician performance'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            if (_technicianPerformance.isEmpty)
              ShwakelCard(
                padding: const EdgeInsets.all(18),
                child: Text(
                  context.loc.text(
                    'لا توجد عمليات مسندة لفنيين بعد.',
                    'No assigned maintenance yet.',
                  ),
                ),
              ),
            ..._technicianPerformance.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ShwakelCard(
                  padding: const EdgeInsets.all(14),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(
                      child: Icon(Icons.engineering_rounded),
                    ),
                    title: Text(
                      _map(item['employee'])['name']?.toString() ?? '-',
                    ),
                    subtitle: Text(
                      '${context.loc.text('المنجزة', 'Completed')}: ${item['completedCount'] ?? 0}  •  '
                      '${context.loc.text('النشطة', 'Active')}: ${item['activeCount'] ?? 0}  •  '
                      '${context.loc.text('الإيراد', 'Revenue')}: ${_money(item['revenue'])}',
                    ),
                    trailing: _canViewProfits
                        ? Text(
                            _money(item['profit']),
                            style: const TextStyle(
                              color: Colors.green,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : null,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 80),
          ],
        );

  Widget _metric(String title, dynamic value, IconData icon, Color color) =>
      SizedBox(
        width: 220,
        child: ShwakelCard(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: color.withValues(alpha: .12),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title),
                  Text(
                    '${value ?? 0}',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _periodReport(
    String title,
    Map<String, dynamic> report,
    IconData icon,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: ShwakelCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon),
              const SizedBox(width: 8),
              Text(title, style: Theme.of(context).textTheme.titleLarge),
            ],
          ),
          const Divider(height: 28),
          Wrap(
            spacing: 28,
            runSpacing: 12,
            children: [
              _reportValue(
                context.loc.text('عدد الصيانات', 'Orders'),
                report['count'],
              ),
              _reportValue(
                context.loc.text('الإيراد', 'Revenue'),
                _money(report['revenue']),
              ),
              if (_canViewProfits)
                _reportValue(
                  context.loc.text('التكلفة', 'Cost'),
                  _money(report['cost']),
                ),
              if (_canViewProfits)
                _reportValue(
                  context.loc.text('الربح', 'Profit'),
                  _money(report['profit']),
                  color: Colors.green,
                ),
            ],
          ),
        ],
      ),
    ),
  );
  Widget _reportValue(String label, dynamic value, {Color? color}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      Text(
        '$value',
        style: Theme.of(context).textTheme.titleLarge?.copyWith(color: color),
      ),
    ],
  );

  Widget _orderCard(Map<String, dynamic> order) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: ShwakelCard(
      onTap: () => _details(order),
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${order['orderNumber']} • ${order['deviceType']}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              _statusChip(order['status']?.toString() ?? ''),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            order['customerName']?.toString() ?? '',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 3),
          Row(
            children: [
              const Icon(Icons.phone_rounded, size: 16),
              const SizedBox(width: 5),
              Text(order['customerPhone']?.toString() ?? ''),
            ],
          ),
          Text(
            '${order['brand'] ?? ''} ${order['model'] ?? ''}  •  ${context.loc.text('المكان', 'Location')}: ${order['location']?.toString().isEmpty == false ? order['location'] : '-'}',
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${context.loc.text('الفني', 'Technician')}: ${_map(order['assignedTo'])['name'] ?? '-'}',
                ),
              ),
              Text(
                _money(order['total']),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _statusChip(String status) => Chip(
    avatar: Icon(_statusIcon(status), size: 17),
    label: Text(_statusLabel(status)),
    visualDensity: VisualDensity.compact,
  );

  Future<void> _newOrder() async {
    final formKey = GlobalKey<FormState>();
    final customer = TextEditingController(),
        phone = TextEditingController(),
        device = TextEditingController(),
        brand = TextEditingController(),
        model = TextEditingController(),
        serial = TextEditingController(),
        issue = TextEditingController(),
        condition = TextEditingController(),
        accessories = TextEditingController(),
        location = TextEditingController(),
        estimate = TextEditingController();
    String? employeeId;
    bool showAdditional = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(
            context.loc.text('استلام جهاز للصيانة', 'Receive a device'),
          ),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  children: [
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        context.loc.text(
                          'الحقول المميزة بنجمة (*) إلزامية لضمان استلام واضح وقابل للمتابعة.',
                          'Fields marked (*) are required for a clear, traceable receipt.',
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _field(
                      phone,
                      context.loc.text('رقم الجوال *', 'Mobile number *'),
                      type: TextInputType.phone,
                      required: true,
                      autofocus: true,
                    ),
                    _field(
                      customer,
                      context.loc.text('اسم العميل *', 'Customer name *'),
                      required: true,
                    ),
                    _field(
                      device,
                      context.loc.text('نوع الجهاز *', 'Device type *'),
                      required: true,
                    ),
                    _field(
                      issue,
                      context.loc.text(
                        'العطل حسب العميل *',
                        'Reported issue *',
                      ),
                      lines: 2,
                      required: true,
                    ),
                    _field(
                      condition,
                      context.loc.text(
                        'حالة الجهاز عند الاستلام *',
                        'Condition at receipt *',
                      ),
                      required: true,
                    ),
                    _field(
                      location,
                      context.loc.text('مكان الحفظ *', 'Storage location *'),
                      required: true,
                    ),
                    const SizedBox(height: 4),
                    OutlinedButton.icon(
                      onPressed: () =>
                          setLocal(() => showAdditional = !showAdditional),
                      icon: Icon(
                        showAdditional
                            ? Icons.expand_less_rounded
                            : Icons.add_circle_outline_rounded,
                      ),
                      label: Text(
                        showAdditional
                            ? context.loc.text(
                                'إخفاء البيانات الإضافية',
                                'Hide additional details',
                              )
                            : context.loc.text(
                                'إضافة بيانات أخرى (اختياري)',
                                'Add more details (optional)',
                              ),
                      ),
                    ),
                    if (showAdditional) ...[
                      const SizedBox(height: 12),
                      if (_canCreateSales)
                        Row(
                          children: [
                            Expanded(
                              child: _field(
                                brand,
                                context.loc.text('الماركة', 'Brand'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _field(
                                model,
                                context.loc.text('الموديل', 'Model'),
                              ),
                            ),
                          ],
                        ),
                      _field(
                        serial,
                        context.loc.text('الرقم التسلسلي', 'Serial number'),
                      ),
                      _field(
                        accessories,
                        context.loc.text(
                          'الملحقات المستلمة',
                          'Received accessories',
                        ),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: employeeId,
                              decoration: InputDecoration(
                                labelText: context.loc.text(
                                  'الفني أو المسؤول',
                                  'Technician or assignee',
                                ),
                              ),
                              items: _employees
                                  .map(
                                    (employee) => DropdownMenuItem(
                                      value: employee['id']?.toString(),
                                      child: Text(
                                        employee['phone']
                                                    ?.toString()
                                                    .trim()
                                                    .isNotEmpty ==
                                                true
                                            ? '${employee['name']} • ${employee['phone']}'
                                            : employee['name']?.toString() ??
                                                  '',
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (value) =>
                                  setLocal(() => employeeId = value),
                            ),
                          ),
                          if (_canOpenEmployees) ...[
                            const SizedBox(width: 8),
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: IconButton.filledTonal(
                                tooltip: _canManageEmployees
                                    ? context.loc.text(
                                        'إضافة فني أو مسؤول',
                                        'Add technician or assignee',
                                      )
                                    : context.loc.text(
                                        'عرض الموظفين',
                                        'View employees',
                                      ),
                                onPressed: () async {
                                  await Navigator.of(
                                    dialog,
                                  ).pushNamed('/sub-users');
                                  if (!mounted) return;
                                  await _load();
                                  if (dialog.mounted) setLocal(() {});
                                },
                                icon: Icon(
                                  _canManageEmployees
                                      ? Icons.person_add_alt_1_rounded
                                      : Icons.people_outline_rounded,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (_canOpenEmployees)
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            context.loc.text(
                              'يُضاف الفني أو المسؤول من حسابات الموظفين، ثم يظهر هنا مباشرة بعد العودة.',
                              'Add technicians or assignees from employee accounts; they appear here after returning.',
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      const SizedBox(height: 4),
                      _field(
                        estimate,
                        context.loc.text('التكلفة التقديرية', 'Estimated cost'),
                        type: TextInputType.number,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(context.loc.text('إلغاء', 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() == true) {
                  Navigator.pop(dialog, true);
                }
              },
              child: Text(context.loc.text('حفظ الاستلام', 'Save receipt')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) {
      return;
    }
    await _act(
      () => _queueMaintenance(
        'create',
        data: {
          'customerName': customer.text,
          'customerPhone': phone.text,
          'deviceType': device.text,
          'brand': brand.text,
          'model': model.text,
          'serialNumber': serial.text,
          'reportedIssue': issue.text,
          'deviceCondition': condition.text,
          'accessories': accessories.text,
          'location': location.text,
          'assignedToUserId': employeeId,
          'estimatedCost': double.tryParse(estimate.text) ?? 0,
        },
      ),
    );
  }

  Future<void> _details(Map<String, dynamic> order) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .9,
        maxChildSize: .98,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(18),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${order['orderNumber']} • ${order['deviceType']}',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(sheet),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            _statusChip(order['status']?.toString() ?? ''),
            const SizedBox(height: 10),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person),
              title: Text(order['customerName']?.toString() ?? ''),
              subtitle: Text(order['customerPhone']?.toString() ?? ''),
              trailing: Wrap(
                children: [
                  IconButton(
                    tooltip: context.loc.text('اتصال', 'Call'),
                    onPressed: () => _call(
                      order['customerPhone']?.toString() ?? '',
                      order['id']?.toString() ?? '',
                    ),
                    icon: const Icon(Icons.call),
                  ),
                  IconButton(
                    tooltip: context.loc.text('نسخ الرقم', 'Copy number'),
                    onPressed: () =>
                        _copy(order['customerPhone']?.toString() ?? ''),
                    icon: const Icon(Icons.copy),
                  ),
                  IconButton(
                    tooltip: context.loc.text(
                      'نسخ رابط التتبع',
                      'Copy tracking link',
                    ),
                    onPressed: () =>
                        _copyTracking(order['trackingUrl']?.toString() ?? ''),
                    icon: const Icon(Icons.link_rounded),
                  ),
                ],
              ),
            ),
            _info(context.loc.text('العطل', 'Issue'), order['reportedIssue']),
            _info(context.loc.text('التشخيص', 'Diagnosis'), order['diagnosis']),
            _info(context.loc.text('الموقع', 'Location'), order['location']),
            ShwakelCard(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 22,
                runSpacing: 10,
                children: [
                  _reportValue(
                    context.loc.text('قطع الغيار', 'Parts'),
                    _money(order['partsPrice']),
                  ),
                  _reportValue(
                    context.loc.text('أجرة العمل', 'Labor'),
                    _money(order['laborPrice']),
                  ),
                  _reportValue(
                    context.loc.text('الإجمالي', 'Total'),
                    _money(order['total']),
                  ),
                  _reportValue(
                    context.loc.text('المدفوع', 'Paid'),
                    _money(order['paidAmount']),
                  ),
                  _reportValue(
                    context.loc.text('المتبقي', 'Due'),
                    _money(
                      ((order['total'] as num?)?.toDouble() ?? 0) -
                          ((order['paidAmount'] as num?)?.toDouble() ?? 0),
                    ),
                  ),
                  if (_canViewProfits)
                    _reportValue(
                      context.loc.text('الربح', 'Profit'),
                      _money(order['profit']),
                      color: Colors.green,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(sheet);
                    _editOrder(order);
                  },
                  icon: const Icon(Icons.edit),
                  label: Text(context.loc.text('تحديث ومتابعة', 'Update')),
                ),
                if (_canManageInventory && order['invoiceId'] == null)
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(sheet);
                      _addPart(order);
                    },
                    icon: const Icon(Icons.inventory_2),
                    label: Text(context.loc.text('سحب قطعة', 'Use part')),
                  ),
                if (_canCreateSales &&
                    order['invoiceId'] == null &&
                    ['completed', 'delivered'].contains(order['status']))
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(sheet);
                      _finalize(order);
                    },
                    icon: const Icon(Icons.receipt_long),
                    label: Text(
                      context.loc.text('إنشاء الفاتورة', 'Create invoice'),
                    ),
                  ),
              ],
            ),
            const Divider(height: 30),
            Text(
              context.loc.text('متابعة التواصل', 'Customer contacts'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (_list(order['contacts']).isEmpty)
              ListTile(
                leading: const Icon(Icons.phone_disabled_outlined),
                title: Text(
                  context.loc.text(
                    'لم يُسجل تواصل مع العميل بعد.',
                    'No customer contact has been recorded yet.',
                  ),
                ),
              ),
            ..._list(order['contacts']).map(
              (contact) => ListTile(
                leading: const Icon(Icons.contact_phone_outlined),
                title: Text(
                  '${_contactMethodLabel(contact['method']?.toString())} • ${_contactResultLabel(contact['result']?.toString())}',
                ),
                subtitle: Text(
                  '${contact['note'] ?? ''}\n${_map(contact['actor'])['name'] ?? ''} • ${contact['createdAt'] ?? ''}',
                ),
              ),
            ),
            const Divider(height: 30),
            Text(
              context.loc.text('القطع المستخدمة', 'Used parts'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            ..._list(order['parts']).map(
              (p) => ListTile(
                title: Text(p['productName']?.toString() ?? ''),
                subtitle: Text('${p['quantity']} ${p['unitName']}'),
                trailing: _canManageInventory && order['invoiceId'] == null
                    ? IconButton(
                        tooltip: context.loc.text(
                          'إرجاع للمخزن',
                          'Return to inventory',
                        ),
                        onPressed: () {
                          Navigator.pop(sheet);
                          _removePart(order, p);
                        },
                        icon: const Icon(Icons.undo_rounded, color: Colors.red),
                      )
                    : Text(_money(p['priceTotal'])),
              ),
            ),
            const Divider(height: 30),
            Text(
              context.loc.text('سجل الصيانة', 'Maintenance log'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            ..._list(order['logs']).map(
              (l) => ListTile(
                leading: const Icon(Icons.history),
                title: Text(
                  '${_logLabel(l)} • ${_map(l['actor'])['name'] ?? ''}',
                ),
                subtitle: Text('${l['note'] ?? ''}\n${l['createdAt'] ?? ''}'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editOrder(Map<String, dynamic> order) async {
    final formKey = GlobalKey<FormState>();
    String status = order['status']?.toString() ?? 'received';
    String? employee = _map(order['assignedTo'])['id']?.toString();
    final diagnosis = TextEditingController(
          text: order['diagnosis']?.toString(),
        ),
        notes = TextEditingController(text: order['workNotes']?.toString()),
        location = TextEditingController(text: order['location']?.toString()),
        labor = TextEditingController(text: '${order['laborPrice'] ?? 0}'),
        other = TextEditingController(text: '${order['otherCost'] ?? 0}'),
        discount = TextEditingController(text: '${order['discount'] ?? 0}'),
        paid = TextEditingController(text: '${order['paidAmount'] ?? 0}'),
        logNote = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(context.loc.text('متابعة الصيانة', 'Update maintenance')),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: status,
                      decoration: InputDecoration(
                        labelText: context.loc.text('الحالة', 'Status'),
                      ),
                      items: _allowedNextStatuses(order)
                          .map(
                            (s) => DropdownMenuItem(
                              value: s,
                              child: Text(_statusLabel(s)),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setLocal(() => status = v ?? status),
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: employee,
                      decoration: InputDecoration(
                        labelText: context.loc.text(
                          ['completed', 'delivered'].contains(status)
                              ? 'الفني المسؤول *'
                              : 'الفني المسؤول',
                          ['completed', 'delivered'].contains(status)
                              ? 'Technician *'
                              : 'Technician',
                        ),
                      ),
                      items: _employees
                          .map(
                            (e) => DropdownMenuItem(
                              value: e['id']?.toString(),
                              child: Text(e['name']?.toString() ?? ''),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setLocal(() => employee = v),
                      validator: (_) =>
                          ['completed', 'delivered'].contains(status) &&
                              employee == null
                          ? context.loc.text(
                              'حدد الفني المسؤول.',
                              'Select the technician.',
                            )
                          : null,
                    ),
                    _field(
                      diagnosis,
                      context.loc.text(
                        ['completed', 'delivered'].contains(status)
                            ? 'التشخيص *'
                            : 'التشخيص',
                        ['completed', 'delivered'].contains(status)
                            ? 'Diagnosis *'
                            : 'Diagnosis',
                      ),
                      lines: 2,
                      required: ['completed', 'delivered'].contains(status),
                    ),
                    _field(
                      notes,
                      context.loc.text('ملاحظات العمل', 'Work notes'),
                      lines: 2,
                    ),
                    _field(
                      location,
                      context.loc.text('مكان الجهاز *', 'Device location *'),
                      required: true,
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: _field(
                            labor,
                            context.loc.text('أجرة العمل', 'Labor'),
                            type: TextInputType.number,
                          ),
                        ),
                        if (_canViewProfits) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: _field(
                              other,
                              context.loc.text('تكلفة أخرى', 'Other cost'),
                              type: TextInputType.number,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (_canCreateSales)
                      Row(
                        children: [
                          Expanded(
                            child: _field(
                              discount,
                              context.loc.text('الخصم', 'Discount'),
                              type: TextInputType.number,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _field(
                              paid,
                              context.loc.text('المدفوع', 'Paid'),
                              type: TextInputType.number,
                            ),
                          ),
                        ],
                      ),
                    _field(
                      logNote,
                      context.loc.text('ملاحظة للسجل', 'Log note'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(context.loc.text('إلغاء', 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() == true) {
                  Navigator.pop(dialog, true);
                }
              },
              child: Text(context.loc.text('حفظ', 'Save')),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      await _act(
        () => _queueMaintenance(
          'update',
          order: order,
          data: {
            'status': status,
            'assignedToUserId': employee,
            'diagnosis': diagnosis.text,
            'workNotes': notes.text,
            'location': location.text,
            if (_canCreateSales) 'laborPrice': double.tryParse(labor.text) ?? 0,
            if (_canViewProfits) 'otherCost': double.tryParse(other.text) ?? 0,
            if (_canCreateSales)
              'discount': double.tryParse(discount.text) ?? 0,
            if (_canCreateSales) 'paidAmount': double.tryParse(paid.text) ?? 0,
            'note': logNote.text,
          },
        ),
      );
    }
  }

  Future<void> _addPart(Map<String, dynamic> order) async {
    String? productId, warehouseId;
    final quantity = TextEditingController(text: '1'),
        price = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setLocal) {
          final product = _products
              .where((p) => p['id']?.toString() == productId)
              .firstOrNull;
          return AlertDialog(
            title: Text(
              context.loc.text('سحب قطعة من المخزن', 'Use inventory part'),
            ),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: productId,
                    decoration: InputDecoration(
                      labelText: context.loc.text('الصنف', 'Product'),
                    ),
                    items: _products
                        .map(
                          (p) => DropdownMenuItem(
                            value: p['id']?.toString(),
                            child: Text(p['name']?.toString() ?? ''),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setLocal(() {
                      productId = v;
                      final p = _products
                          .where((x) => x['id']?.toString() == v)
                          .firstOrNull;
                      price.text = '${p?['salePrice'] ?? 0}';
                    }),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: warehouseId,
                    decoration: InputDecoration(
                      labelText: context.loc.text('المخزن', 'Warehouse'),
                    ),
                    items: _warehouses
                        .map(
                          (w) => DropdownMenuItem(
                            value: w['id']?.toString(),
                            child: Text(w['name']?.toString() ?? ''),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setLocal(() => warehouseId = v),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _field(
                          quantity,
                          context.loc.text('الكمية', 'Quantity'),
                          type: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _field(
                          price,
                          context.loc.text('سعر البيع', 'Sale price'),
                          type: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  if (product != null && warehouseId != null)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        '${context.loc.text('المتوفر', 'Available')}: ${_list(product['stocks']).where((s) => s['warehouseId'] == warehouseId).firstOrNull?['quantity'] ?? 0}',
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: Text(context.loc.text('إلغاء', 'Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(context.loc.text('سحب وإضافة', 'Use part')),
              ),
            ],
          );
        },
      ),
    );
    if (ok == true && productId != null && warehouseId != null) {
      await _act(
        () => _queueMaintenance(
          'add_part',
          order: order,
          data: {
            'productId': productId,
            'warehouseId': warehouseId,
            'quantity': double.tryParse(quantity.text) ?? 0,
            'unitPrice': double.tryParse(price.text) ?? 0,
          },
        ),
      );
    }
  }

  Future<void> _finalize(Map<String, dynamic> order) async {
    final paidAmount = (order['paidAmount'] as num?)?.toDouble() ?? 0;
    String? paymentMethodId = _paymentMethods.firstOrNull?['id']?.toString();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            context.loc.text(
              'إنشاء فاتورة الصيانة',
              'Create maintenance invoice',
            ),
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${context.loc.text('الإجمالي', 'Total')}: ${order['total']}',
                ),
                Text('${context.loc.text('المدفوع', 'Paid')}: $paidAmount'),
                if (paidAmount > 0) ...[
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: paymentMethodId,
                    decoration: InputDecoration(
                      labelText: context.loc.text(
                        'طريقة الدفع',
                        'Payment method',
                      ),
                      prefixIcon: const Icon(Icons.payments_rounded),
                    ),
                    items: _paymentMethods
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
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(context.loc.text('إلغاء', 'Cancel')),
            ),
            FilledButton(
              onPressed: paidAmount <= 0 || paymentMethodId != null
                  ? () => Navigator.pop(dialog, true)
                  : null,
              child: Text(context.loc.text('إنشاء الفاتورة', 'Create invoice')),
            ),
          ],
        ),
      ),
    );
    if (accepted != true) return;
    final method = _paymentMethods.firstWhere(
      (item) => item['id']?.toString() == paymentMethodId,
      orElse: () => const <String, dynamic>{},
    );
    await _act(
      () => _queueMaintenance(
        'finalize',
        order: order,
        data: paidAmount > 0
            ? {
                'paymentMethodId': paymentMethodId,
                'paymentMethodClientRef': method['clientRef']?.toString(),
                'paymentMethod': method['name']?.toString(),
              }
            : const {},
      ),
    );
  }

  Future<void> _removePart(
    Map<String, dynamic> order,
    Map<String, dynamic> part,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(
          context.loc.text('إرجاع القطعة للمخزن', 'Return part to inventory'),
        ),
        content: Text(
          context.loc.text(
            'سيتم حذف ${part['productName']} من الصيانة وإرجاع الكمية إلى المخزن مع تسجيل الحركة.',
            '${part['productName']} will be removed and returned to inventory with an audit movement.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(context.loc.text('إلغاء', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.loc.text('إرجاع', 'Return')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _act(
        () => _queueMaintenance('remove_part', order: order, part: part),
      );
    }
  }

  Future<void> _act(Future<Map<String, dynamic>> Function() action) async {
    try {
      final result = await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result['message']?.toString() ??
                  context.loc.text('تم الحفظ', 'Saved'),
            ),
          ),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessageService.sanitize(e))),
        );
      }
    }
  }

  Future<Map<String, dynamic>> _queueMaintenance(
    String action, {
    Map<String, dynamic>? order,
    Map<String, dynamic>? part,
    Map<String, dynamic> data = const {},
  }) async {
    if (_userId == null) throw StateError('لا توجد جلسة محلية صالحة.');
    final savedMessage = context.loc.text(
      'تم الحفظ محليًا وستتم المزامنة تلقائيًا.',
      'Saved offline and will sync automatically.',
    );
    final orderId = order?['id']?.toString();
    final orderClientRef =
        order?['clientRef']?.toString() ??
        (orderId?.startsWith('local:') == true ? orderId!.substring(6) : null);
    final partId = part?['id']?.toString();
    final partClientRef =
        part?['clientRef']?.toString() ??
        (partId?.startsWith('local:') == true ? partId!.substring(6) : null);
    final preparedData = Map<String, dynamic>.from(data);
    preparedData['actorUserId'] = _userId;
    preparedData['actorName'] = _actorName;
    if (action == 'add_part') {
      final productId = data['productId']?.toString();
      final warehouseId = data['warehouseId']?.toString();
      final product = _products
          .where((item) => item['id']?.toString() == productId)
          .firstOrNull;
      final warehouse = _warehouses
          .where((item) => item['id']?.toString() == warehouseId)
          .firstOrNull;
      preparedData['productClientRef'] =
          product?['clientRef'] ??
          (productId?.startsWith('local:') == true
              ? productId!.substring(6)
              : null);
      preparedData['warehouseClientRef'] =
          warehouse?['clientRef'] ??
          (warehouseId?.startsWith('local:') == true
              ? warehouseId!.substring(6)
              : null);
    }
    await _offlineStore.queueMaintenance(
      userId: _userId!,
      action: action,
      orderId: orderId,
      orderClientRef: orderClientRef,
      partId: partId,
      partClientRef: partClientRef,
      data: preparedData,
    );
    final cached = await _offlineStore.getMaintenanceSnapshot(_userId!);
    if (mounted) {
      setState(() {
        _data = cached;
        _pendingCount++;
      });
    }
    return {'message': savedMessage};
  }

  Future<void> _call(String phone, String orderId) async {
    if (phone.trim().isNotEmpty) {
      if (orderId.isNotEmpty) {
        try {
          final order = _orders
              .where((item) => item['id']?.toString() == orderId)
              .firstOrNull;
          if (order != null) {
            await _queueMaintenance(
              'contact',
              order: order,
              data: const {'method': 'call', 'result': 'attempted'},
            );
          }
        } catch (_) {}
      }
      await launchUrl(Uri(scheme: 'tel', path: phone.trim()));
    }
  }

  Future<void> _copyTracking(String url) async {
    if (url.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.loc.text(
              'تم نسخ رابط متابعة الصيانة.',
              'Tracking link copied.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _copy(String phone) async {
    await Clipboard.setData(ClipboardData(text: phone));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.loc.text('تم نسخ الرقم', 'Number copied')),
        ),
      );
    }
  }

  Widget _field(
    TextEditingController c,
    String label, {
    int lines = 1,
    TextInputType? type,
    bool required = false,
    bool autofocus = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextFormField(
      controller: c,
      maxLines: lines,
      keyboardType: type,
      autofocus: autofocus,
      decoration: InputDecoration(labelText: label),
      validator: required
          ? (value) => value == null || value.trim().isEmpty
                ? context.loc.text(
                    'هذا الحقل مطلوب.',
                    'This field is required.',
                  )
                : null
          : null,
    ),
  );

  List<String> _allowedNextStatuses(Map<String, dynamic> order) {
    final current = order['status']?.toString() ?? 'received';
    final transitions = _map(_data['statusTransitions']);
    final next = transitions[current] is List
        ? List<String>.from(transitions[current] as List)
        : const <String>[];
    return {current, ...next}.toList();
  }

  Future<void> _exportCsv() async {
    final buffer = StringBuffer()
      ..writeln(
        '\uFEFForder_number,status,priority,customer_name,customer_phone,device_type,brand,model,serial_number,location,technician,total,paid,due,created_at',
      );
    for (final order in _orders) {
      final row = [
        order['orderNumber'],
        _statusLabel(order['status']?.toString() ?? ''),
        order['priority'],
        order['customerName'],
        order['customerPhone'],
        order['deviceType'],
        order['brand'],
        order['model'],
        order['serialNumber'],
        order['location'],
        _map(order['assignedTo'])['name'],
        order['total'],
        order['paidAmount'],
        order['dueAmount'],
        order['createdAt'],
      ].map(_csvCell).join(',');
      buffer.writeln(row);
    }
    await FileSaver.instance.saveFile(
      name: 'maintenance_${DateTime.now().toIso8601String().substring(0, 10)}',
      bytes: Uint8List.fromList(utf8.encode(buffer.toString())),
      fileExtension: 'csv',
      mimeType: MimeType.csv,
    );
  }

  String _csvCell(dynamic value) =>
      '"${(value ?? '').toString().replaceAll('"', '""')}"';
  Widget _info(String label, dynamic value) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 90,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        Expanded(
          child: Text(
            value?.toString().isNotEmpty == true ? value.toString() : '-',
          ),
        ),
      ],
    ),
  );
  Widget _errorView() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_error!),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _load,
          child: Text(context.loc.text('إعادة المحاولة', 'Retry')),
        ),
      ],
    ),
  );
  String _money(dynamic value) =>
      '${((value as num?)?.toDouble() ?? 0).toStringAsFixed(2)} ${context.loc.text('ش.ج', 'ILS')}';
  static List<Map<String, dynamic>> _list(dynamic v) => v is List
      ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : const [];
  static Map<String, dynamic> _map(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : const {};
  String _statusLabel(String s) =>
      {
        'received': 'مستلمة',
        'diagnosing': 'قيد الفحص',
        'waiting_customer': 'بانتظار العميل',
        'waiting_parts': 'بانتظار قطع',
        'in_progress': 'قيد الصيانة',
        'completed': 'جاهزة للتسليم',
        'delivered': 'تم التسليم',
        'cancelled': 'ملغاة',
      }[s] ??
      (s.isEmpty ? '-' : s);
  String _logLabel(Map<String, dynamic> log) {
    if (log['action'] == 'customer_contacted') {
      return context.loc.text('تم التواصل مع العميل', 'Customer contacted');
    }
    if (log['action'] == 'part_added') {
      return context.loc.text('إضافة قطعة غيار', 'Part added');
    }
    if (log['action'] == 'part_removed') {
      return context.loc.text('إرجاع قطعة للمخزن', 'Part returned');
    }
    if (log['action'] == 'invoice_created') {
      return context.loc.text('إنشاء الفاتورة', 'Invoice created');
    }
    return _statusLabel(log['toStatus']?.toString() ?? '');
  }

  String _contactMethodLabel(String? method) => switch (method) {
    'sms' => 'SMS',
    'whatsapp' => context.loc.text('واتساب', 'WhatsApp'),
    'in_person' => context.loc.text('حضوري', 'In person'),
    _ => context.loc.text('اتصال', 'Call'),
  };

  String _contactResultLabel(String? result) => switch (result) {
    'answered' => context.loc.text('تم الرد', 'Answered'),
    'no_answer' => context.loc.text('لم يرد', 'No answer'),
    'confirmed' => context.loc.text('تم التأكيد', 'Confirmed'),
    'declined' => context.loc.text('رفض', 'Declined'),
    _ => context.loc.text('محاولة تواصل', 'Attempted'),
  };

  IconData _statusIcon(String s) =>
      {
        'received': Icons.move_to_inbox,
        'diagnosing': Icons.search,
        'waiting_customer': Icons.phone_paused,
        'waiting_parts': Icons.inventory,
        'in_progress': Icons.build,
        'completed': Icons.task_alt,
        'delivered': Icons.handshake,
        'cancelled': Icons.cancel,
      }[s] ??
      Icons.build_circle;
}
