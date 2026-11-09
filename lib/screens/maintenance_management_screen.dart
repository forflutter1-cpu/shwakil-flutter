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
  String? _syncError;
  String _status = '';
  String? _userId;
  String _actorName = '';
  int _pendingCount = 0;
  bool _hasRetryableMaintenancePending = false;
  bool _offline = false;
  bool _showFilters = false;
  bool _loadInProgress = false;
  bool _loadQueued = false;
  bool _loadingMore = false;
  bool _loadMoreQueued = false;
  Timer? _syncRetryTimer;
  AppPermissions _appPermissions = AppPermissions.fromUser(null);

  List<Map<String, dynamic>> get _orders {
    final query = _search.text.trim().toLowerCase();
    return _list(_data['orders']).where((order) {
      if (_status.isNotEmpty && order['status'] != _status) return false;
      if (query.isEmpty) return true;
      return [
        'orderNumber',
        'customerName',
        'customerPhone',
        'deviceType',
        'brand',
        'model',
        'serialNumber',
        'location',
      ].any(
        (field) =>
            (order[field]?.toString() ?? '').toLowerCase().contains(query),
      );
    }).toList();
  }

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
    _scheduleSyncRetry();
    if (mounted) setState(() {});
  }

  void _scheduleSyncRetry() {
    _syncRetryTimer?.cancel();
    if (!mounted ||
        !ConnectivityService.instance.isOnline.value ||
        !_hasRetryableMaintenancePending) {
      return;
    }
    _syncRetryTimer = Timer(const Duration(seconds: 20), () {
      if (mounted && ConnectivityService.instance.isOnline.value) {
        unawaited(_load());
      }
    });
  }

  bool _shouldAutomaticallyRetryMaintenance(
    List<Map<String, dynamic>> pending,
  ) => pending.any((operation) {
    if (operation['entity'] != 'maintenance') return false;
    if (operation['syncStatus'] != 'failed') return true;
    return operation['syncOutcomeUnknown'] == true ||
        operation['syncOutcomeUnknown'] == null;
  });

  @override
  void dispose() {
    _syncRetryTimer?.cancel();
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
    if (_loadInProgress || _loadingMore) {
      _loadQueued = true;
      return;
    }
    _loadInProgress = true;
    if (mounted) {
      setState(() {
        _loading = _data.isEmpty;
        _error = null;
      });
    }
    try {
      if (_userId != null) {
        try {
          await _offlineStore.syncPending(userId: _userId!, api: _api);
          _syncError = null;
        } catch (error) {
          // A rejected queued operation must not make a reachable maintenance
          // API look offline. Load the live snapshot and keep retrying the
          // operation so the user can continue working online.
          _syncError = ErrorMessageService.sanitize(error);
        }
      }
      final data = await _api.getMaintenanceSnapshot(
        search: _search.text,
        // Cache the complete status set so status shortcuts remain useful
        // without connectivity. Apply the selected state locally below.
        status: '',
        offset: 0,
        limit: 100,
      );
      final visibleData = _userId == null
          ? data
          : await _offlineStore.cacheMaintenanceSnapshot(_userId!, data);
      final pending = _userId == null
          ? const <Map<String, dynamic>>[]
          : await _offlineStore.getPendingOperations(_userId!);
      if (mounted) {
        setState(() {
          _data = visibleData;
          _loading = false;
          _offline = false;
          _pendingCount = pending
              .where((e) => e['entity'] == 'maintenance')
              .length;
          _hasRetryableMaintenancePending =
              _shouldAutomaticallyRetryMaintenance(pending);
        });
        _scheduleSyncRetry();
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
          _hasRetryableMaintenancePending =
              _shouldAutomaticallyRetryMaintenance(pending);
          _error = cached.isEmpty ? ErrorMessageService.sanitize(e) : null;
        });
        _scheduleSyncRetry();
      }
    } finally {
      _loadInProgress = false;
      if (_loadQueued && mounted) {
        _loadQueued = false;
        unawaited(_load());
      } else if (_loadMoreQueued && mounted) {
        _loadMoreQueued = false;
        unawaited(_loadMore());
      }
    }
  }

  bool get _hasMore => _map(_data['pagination'])['hasMore'] == true;

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _userId == null) return;
    if (_loadInProgress) {
      _loadMoreQueued = true;
      return;
    }
    final pagination = _map(_data['pagination']);
    final offset =
        ((pagination['offset'] as num?)?.toInt() ?? 0) +
        ((pagination['pageCount'] as num?)?.toInt() ?? 0);
    if (mounted) setState(() => _loadingMore = true);
    try {
      try {
        await _offlineStore.syncPending(userId: _userId!, api: _api);
        _syncError = null;
      } catch (error) {
        _syncError = ErrorMessageService.sanitize(error);
      }
      final page = await _api.getMaintenanceSnapshot(
        search: _search.text,
        status: '',
        offset: offset,
        limit: 100,
      );
      final merged = await _offlineStore.appendMaintenancePage(_userId!, page);
      final pending = await _offlineStore.getPendingOperations(_userId!);
      if (mounted) {
        setState(() {
          _data = merged;
          _offline = false;
          _pendingCount = pending
              .where((operation) => operation['entity'] == 'maintenance')
              .length;
          _hasRetryableMaintenancePending =
              _shouldAutomaticallyRetryMaintenance(pending);
        });
        _scheduleSyncRetry();
      }
    } catch (error) {
      if (mounted) {
        setState(() => _offline = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMessageService.sanitize(error))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
        if (_loadQueued) {
          _loadQueued = false;
          unawaited(_load());
        } else if (_loadMoreQueued) {
          _loadMoreQueued = false;
          unawaited(_loadMore());
        }
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
      title: Text(context.loc.text('الصيانة', 'Maintenance')),
      actions: [
        IconButton(
          tooltip: _showFilters
              ? context.loc.text('إخفاء الفلاتر', 'Hide filters')
              : context.loc.text('الفلاتر', 'Filters'),
          onPressed: () => setState(() => _showFilters = !_showFilters),
          icon: Icon(
            _showFilters
                ? Icons.filter_alt_off_rounded
                : Icons.filter_alt_rounded,
          ),
        ),
        if (_offline || _pendingCount > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Tooltip(
              message: _syncError,
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
          if (_showFilters) ...[_header(), const SizedBox(height: 12)],
          if (_syncError != null && _pendingCount > 0) ...[
            _syncWarning(),
            const SizedBox(height: 8),
          ],
          TabBar(
            controller: _tabs,
            tabs: [
              Tab(text: context.loc.text('لوحة المتابعة', 'Dashboard')),
              Tab(text: context.loc.text('الصيانات', 'Orders')),
              Tab(text: context.loc.text('التقارير', 'Reports')),
            ],
          ),
          const SizedBox(height: 8),
          _statusShortcuts(),
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

  Widget _statusShortcuts() {
    const statuses = [
      '',
      'received',
      'diagnosing',
      'waiting_customer',
      'waiting_parts',
      'in_progress',
      'completed',
      'delivered',
      'cancelled',
    ];
    final counts = _map(_data['statusCounts']);
    final allCount = counts.values.whereType<num>().fold<int>(
      0,
      (total, value) => total + value.toInt(),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: statuses
            .map(
              (status) => Padding(
                padding: const EdgeInsetsDirectional.only(end: 7),
                child: ChoiceChip(
                  label: Text(
                    '${status.isEmpty ? context.loc.text('كل الحالات', 'All statuses') : _statusLabel(status)} (${status.isEmpty ? allCount : counts[status] ?? 0})',
                  ),
                  selected: _status == status,
                  onSelected: (_) {
                    setState(() => _status = status);
                  },
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _syncWarning() => Material(
    color: Theme.of(context).colorScheme.errorContainer,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 6, 8),
      child: Row(
        children: [
          const Icon(Icons.sync_problem_rounded),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.loc.text(
                'تعذرت مزامنة $_pendingCount عملية. ستبقى محفوظة على هذا الجهاز. ${ErrorMessageService.sanitize(_syncError!)}',
                '$_pendingCount operation(s) could not sync and remain saved on this device. ${ErrorMessageService.sanitize(_syncError!)}',
              ),
            ),
          ),
          IconButton(
            tooltip: context.loc.text(
              'تفاصيل العمليات المعلقة',
              'Pending operation details',
            ),
            onPressed: _showPendingOperations,
            icon: const Icon(Icons.list_alt_rounded),
          ),
          IconButton(
            tooltip: context.loc.text('إعادة المحاولة', 'Retry sync'),
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    ),
  );

  Future<void> _showPendingOperations() async {
    final userId = _userId;
    if (userId == null) return;
    final pending =
        (await _offlineStore.getPendingOperations(
            userId,
          )).where((operation) => operation['entity'] == 'maintenance').toList()
          ..sort(
            (a, b) => (a['queueSequence'] as num? ?? 0).compareTo(
              b['queueSequence'] as num? ?? 0,
            ),
          );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(
          context.loc.text(
            'عمليات الصيانة المعلقة',
            'Pending maintenance operations',
          ),
        ),
        content: SizedBox(
          width: 560,
          child: pending.isEmpty
              ? Text(
                  context.loc.text(
                    'لا توجد عمليات معلقة.',
                    'No pending operations.',
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: pending.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (context, index) {
                    final operation = pending[index];
                    final failed = operation['syncStatus'] == 'failed';
                    final outcomeUnknown =
                        operation['syncOutcomeUnknown'] == true;
                    final opId = operation['opId']?.toString() ?? '';
                    final title = _maintenanceActionLabel(
                      operation['action']?.toString(),
                    );
                    final orderId = operation['orderId']?.toString();
                    final orderClientRef = operation['orderClientRef']
                        ?.toString();
                    final order = _orders
                        .where(
                          (item) =>
                              item['id']?.toString() == orderId ||
                              item['clientRef']?.toString() == orderClientRef ||
                              (operation['action'] == 'create' &&
                                  item['clientRef']?.toString() ==
                                      operation['clientRef']?.toString()),
                        )
                        .firstOrNull;
                    final orderNumber = order?['orderNumber']?.toString();
                    final rawError =
                        operation['lastSyncError']?.toString() ?? '';
                    final error = rawError.isEmpty
                        ? ''
                        : ErrorMessageService.sanitize(rawError);
                    return ListTile(
                      leading: Icon(
                        failed
                            ? Icons.error_outline_rounded
                            : Icons.schedule_rounded,
                      ),
                      title: Text(
                        '$title${orderNumber == null ? '' : ' • $orderNumber'}',
                      ),
                      subtitle: Text(
                        failed && outcomeUnknown
                            ? context.loc.text(
                                'النتيجة غير مؤكدة بسبب انقطاع الاتصال. أعد المحاولة للتحقق بأمان. $error',
                                'The connection ended before confirmation. Retry safely to check the result. $error',
                              )
                            : failed
                            ? context.loc.text(
                                'رفض الخادم العملية: $error',
                                'The server rejected this operation: $error',
                              )
                            : context.loc.text(
                                'بانتظار الاتصال أو دورها في الطابور.',
                                'Waiting for connectivity or its turn in the queue.',
                              ),
                      ),
                      trailing: failed && !outcomeUnknown
                          ? IconButton(
                              tooltip: context.loc.text(
                                'إلغاء هذه العملية وما بعدها للطلب',
                                'Discard this and later operations for the order',
                              ),
                              icon: const Icon(Icons.delete_outline_rounded),
                              onPressed: () async {
                                final discard = await showDialog<bool>(
                                  context: context,
                                  builder: (confirm) => AlertDialog(
                                    title: Text(
                                      context.loc.text(
                                        'إلغاء العملية العالقة؟',
                                        'Discard the stuck operation?',
                                      ),
                                    ),
                                    content: Text(
                                      context.loc.text(
                                        'سيتم حذف العملية الفاشلة والعمليات الأحدث المرتبطة بالطلب نفسه من هذا الجهاز، ثم استعادة آخر حالة مؤكدة. لا يمكن التراجع عن ذلك.',
                                        'The failed operation and newer queued operations for the same order will be removed from this device, then the last confirmed state will be restored. This cannot be undone.',
                                      ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(confirm, false),
                                        child: Text(
                                          context.loc.text('رجوع', 'Keep them'),
                                        ),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(confirm, true),
                                        child: Text(
                                          context.loc.text(
                                            'إلغاء العمليات',
                                            'Discard operations',
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                if (discard != true || !dialog.mounted) return;
                                try {
                                  final removed = await _offlineStore
                                      .discardFailedMaintenanceOperation(
                                        userId: userId,
                                        opId: opId,
                                      );
                                  if (!dialog.mounted) return;
                                  Navigator.pop(dialog);
                                  _showMessage(
                                    context.loc.text(
                                      'تمت إزالة $removed عملية محلية واستعادة آخر حالة مؤكدة.',
                                      '$removed local operation(s) removed. The last confirmed state was restored.',
                                    ),
                                  );
                                  final cached = await _offlineStore
                                      .getMaintenanceSnapshot(userId);
                                  final remaining = await _offlineStore
                                      .getPendingOperations(userId);
                                  if (mounted) {
                                    setState(() {
                                      _data = cached;
                                      _pendingCount = remaining
                                          .where(
                                            (item) =>
                                                item['entity'] == 'maintenance',
                                          )
                                          .length;
                                      _hasRetryableMaintenancePending =
                                          _shouldAutomaticallyRetryMaintenance(
                                            remaining,
                                          );
                                      _syncError = null;
                                    });
                                    unawaited(_load());
                                  }
                                } catch (error) {
                                  if (dialog.mounted) {
                                    _showMessage(
                                      ErrorMessageService.sanitize(error),
                                    );
                                  }
                                }
                              },
                            )
                          : null,
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(context.loc.text('إغلاق', 'Close')),
          ),
          if (pending.isNotEmpty)
            FilledButton.tonalIcon(
              onPressed: () {
                Navigator.pop(dialog);
                _load();
              },
              icon: const Icon(Icons.sync_rounded),
              label: Text(context.loc.text('إعادة المحاولة', 'Retry all')),
            ),
        ],
      ),
    );
  }

  String _maintenanceActionLabel(String? action) => switch (action) {
    'create' => context.loc.text('استلام جهاز', 'Receive device'),
    'update' => context.loc.text(
      'تحديث الطلب أو حالته',
      'Update order or status',
    ),
    'add_part' => context.loc.text('إضافة قطعة غيار', 'Add part'),
    'remove_part' => context.loc.text('إرجاع قطعة للمخزن', 'Return part'),
    'finalize' => context.loc.text('إنشاء الفاتورة', 'Create invoice'),
    'contact' => context.loc.text('تسجيل التواصل', 'Record customer contact'),
    _ => context.loc.text('عملية صيانة', 'Maintenance operation'),
  };

  Widget _header() => ShwakelCard(
    padding: const EdgeInsets.all(14),
    child: Column(
      children: [
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _load(),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: context.loc.text(
              'رقم الصيانة، العميل، الهاتف، الجهاز، السيريال أو المكان',
              'Order, customer, phone, device, serial or location',
            ),
            suffixIcon: IconButton(
              onPressed: () {
                if (_search.text.isEmpty) {
                  _load();
                } else {
                  _search.clear();
                  setState(() {});
                  _load();
                }
              },
              icon: Icon(
                _search.text.isEmpty
                    ? Icons.search_rounded
                    : Icons.close_rounded,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _dashboard() => ListView(
    children: [
      Text(
        context.loc.text('آخر الصيانات', 'Latest maintenance'),
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      if (_orders.isEmpty)
        ShwakelCard(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              const Icon(Icons.build_circle_outlined, color: AppTheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  context.loc.text(
                    'لا توجد عمليات صيانة مسجلة.',
                    'No maintenance orders.',
                  ),
                ),
              ),
            ],
          ),
        ),
      ..._orders.take(8).map(_orderCard),
      const SizedBox(height: 80),
    ],
  );

  Widget _ordersView() => ListView(
    children: [
      if (_map(_data['pagination'])['total'] is num)
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(4, 0, 4, 8),
          child: Builder(
            builder: (context) {
              final page = _map(_data['pagination']);
              final loaded =
                  ((page['offset'] as num?)?.toInt() ?? 0) +
                  ((page['pageCount'] as num?)?.toInt() ?? 0);
              return Text(
                context.loc.text(
                  'المحمّل $loaded من ${page['total']} نتيجة',
                  '$loaded of ${page['total']} results loaded',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              );
            },
          ),
        ),
      if (_orders.isEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Text(
              context.loc.text(
                'لا توجد صيانات مطابقة في النتائج المحمّلة.',
                'No matching orders in the loaded results.',
              ),
            ),
          ),
        )
      else
        ..._orders.map(_orderCard),
      if (_hasMore)
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 90),
          child: Center(
            child: OutlinedButton.icon(
              onPressed: _loadingMore ? null : _loadMore,
              icon: _loadingMore
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.expand_more_rounded),
              label: Text(context.loc.text('تحميل المزيد', 'Load more')),
            ),
          ),
        )
      else
        const SizedBox(height: 80),
    ],
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
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _allowedNextStatuses(order)
                  .where((status) => status != order['status'])
                  .map(
                    (status) => ActionChip(
                      avatar: Icon(_statusIcon(status), size: 16),
                      label: Text(
                        '${context.loc.text('نقل إلى', 'Move to')} ${_statusLabel(status)}',
                      ),
                      onPressed: () => _quickChangeStatus(order, status, sheet),
                    ),
                  )
                  .toList(),
            ),
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
                      'إرسال واتساب',
                      'Message on WhatsApp',
                    ),
                    onPressed: () => _messageCustomer(order, 'whatsapp'),
                    icon: const Icon(Icons.chat_rounded, color: Colors.green),
                  ),
                  IconButton(
                    tooltip: context.loc.text('إرسال SMS', 'Send SMS'),
                    onPressed: () => _messageCustomer(order, 'sms'),
                    icon: const Icon(Icons.sms_outlined),
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
                    _money(order['dueAmount']),
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
                if (_canCreateSales && order['invoiceId'] != null)
                  OutlinedButton.icon(
                    onPressed: () => _openMaintenanceInvoice(order),
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: Text(
                      order['invoiceId'].toString().startsWith('local:')
                          ? context.loc.text(
                              'الفاتورة بانتظار المزامنة',
                              'Invoice waiting to sync',
                            )
                          : context.loc.text('عرض الفاتورة', 'View invoice'),
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
                subtitle: Text(
                  [
                    l['note']?.toString() ?? '',
                    _logChanges(l),
                    l['createdAt']?.toString() ?? '',
                  ].where((line) => line.isNotEmpty).join('\n'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editOrder(
    Map<String, dynamic> order, {
    String? initialStatus,
  }) async {
    final formKey = GlobalKey<FormState>();
    final invoiced = order['invoiceId'] != null;
    String status = initialStatus ?? order['status']?.toString() ?? 'received';
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
                    if (!invoiced) ...[
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
                    ],
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
            if (!invoiced && _canCreateSales)
              'laborPrice': double.tryParse(labor.text) ?? 0,
            if (!invoiced && _canViewProfits)
              'otherCost': double.tryParse(other.text) ?? 0,
            if (!invoiced && _canCreateSales)
              'discount': double.tryParse(discount.text) ?? 0,
            if (!invoiced && _canCreateSales)
              'paidAmount': double.tryParse(paid.text) ?? 0,
            'note': logNote.text,
          },
        ),
      );
    }
  }

  Future<void> _quickChangeStatus(
    Map<String, dynamic> order,
    String status,
    BuildContext sheet,
  ) async {
    Navigator.pop(sheet);
    final assignedTo = _map(order['assignedTo'])['id']?.toString() ?? '';
    final diagnosis = order['diagnosis']?.toString().trim() ?? '';
    if (['completed', 'delivered'].contains(status) &&
        (assignedTo.isEmpty || diagnosis.isEmpty)) {
      await _editOrder(order, initialStatus: status);
      return;
    }
    await _act(
      () => _queueMaintenance('update', order: order, data: {'status': status}),
    );
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
    final existingPaid = (order['paidAmount'] as num?)?.toDouble() ?? 0;
    final total = (order['total'] as num?)?.toDouble() ?? 0;
    var paymentStatus = existingPaid >= total
        ? 'paid'
        : existingPaid > 0
        ? 'partial'
        : 'unpaid';
    final partialAmount = TextEditingController(text: '$existingPaid');
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
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: paymentStatus,
                  decoration: InputDecoration(
                    labelText: context.loc.text(
                      'حالة الفاتورة',
                      'Invoice status',
                    ),
                    prefixIcon: const Icon(Icons.receipt_long_rounded),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'paid',
                      child: Text(
                        context.loc.text('مدفوعة بالكامل', 'Paid in full'),
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'partial',
                      child: Text(
                        context.loc.text('مدفوعة جزئيًا', 'Partially paid'),
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'unpaid',
                      child: Text(context.loc.text('غير مدفوعة', 'Unpaid')),
                    ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => paymentStatus = value ?? 'unpaid'),
                ),
                if (paymentStatus == 'partial') ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: partialAmount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: InputDecoration(
                      labelText: context.loc.text(
                        'المبلغ المدفوع',
                        'Amount paid',
                      ),
                      prefixIcon: const Icon(Icons.payments_outlined),
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                ],
                if (paymentStatus != 'unpaid') ...[
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
              onPressed:
                  (paymentStatus == 'unpaid' ||
                      (paymentMethodId != null &&
                          (paymentStatus != 'partial' ||
                              ((double.tryParse(partialAmount.text) ?? 0) > 0 &&
                                  (double.tryParse(partialAmount.text) ?? 0) <
                                      total))))
                  ? () => Navigator.pop(dialog, true)
                  : null,
              child: Text(context.loc.text('إنشاء الفاتورة', 'Create invoice')),
            ),
          ],
        ),
      ),
    );
    if (accepted != true) {
      partialAmount.dispose();
      return;
    }
    final paidAmount = paymentStatus == 'paid'
        ? total
        : paymentStatus == 'partial'
        ? (double.tryParse(partialAmount.text) ?? 0)
        : 0.0;
    partialAmount.dispose();
    final method = _paymentMethods.firstWhere(
      (item) => item['id']?.toString() == paymentMethodId,
      orElse: () => const <String, dynamic>{},
    );
    await _act(
      () => _queueMaintenance(
        'finalize',
        order: order,
        data: {
          'paidAmount': paidAmount,
          if (paidAmount > 0) ...{
            'paymentMethodId': paymentMethodId,
            'paymentMethodClientRef': method['clientRef']?.toString(),
            'paymentMethod': method['name']?.toString(),
          },
        },
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
    final pending = await _offlineStore.getPendingOperations(_userId!);
    if (mounted) {
      setState(() {
        _data = cached;
        _pendingCount = pending
            .where((operation) => operation['entity'] == 'maintenance')
            .length;
        _hasRetryableMaintenancePending = _shouldAutomaticallyRetryMaintenance(
          pending,
        );
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
            unawaited(_load());
          }
        } catch (_) {}
      }
      await launchUrl(Uri(scheme: 'tel', path: phone.trim()));
    }
  }

  Future<void> _messageCustomer(
    Map<String, dynamic> order,
    String method,
  ) async {
    final phone = order['customerPhone']?.toString().trim() ?? '';
    if (phone.isEmpty) {
      _showMessage(
        context.loc.text(
          'لا يوجد رقم هاتف للعميل.',
          'Customer phone number is missing.',
        ),
      );
      return;
    }
    final name = order['customerName']?.toString().trim() ?? '';
    final orderNumber = order['orderNumber']?.toString() ?? '';
    final status = _statusLabel(order['status']?.toString() ?? '');
    final tracking = order['trackingUrl']?.toString().trim() ?? '';
    final initialMessage = context.loc.text(
      'مرحباً ${name.isEmpty ? '' : '$name، '}بخصوص طلب الصيانة $orderNumber: الحالة الحالية $status.${tracking.isEmpty ? '' : '\nللمتابعة: $tracking'}',
      'Hello ${name.isEmpty ? '' : '$name, '}regarding maintenance order $orderNumber: current status is $status.${tracking.isEmpty ? '' : '\nTrack it here: $tracking'}',
    );
    final openFailureMessage = context.loc.text(
      'تعذر فتح تطبيق المراسلة؛ نُسخت الرسالة لتتمكن من إرسالها يدوياً.',
      'Could not open the messaging app. The message was copied so you can send it manually.',
    );
    final contactNote = context.loc.text(
      'فُتح تطبيق المراسلة مع نص مُعدّ؛ لم يتم تأكيد الإرسال.',
      'Messaging app opened with a prepared message; delivery was not confirmed.',
    );
    final openedMessage = context.loc.text(
      'فُتح التطبيق بالرسالة. تأكد من الضغط على إرسال داخله؛ سجل الصيانة يوثق فتح التطبيق فقط.',
      'The app opened with the message. Tap Send there; the maintenance log records only that the app was opened.',
    );
    final controller = TextEditingController(text: initialMessage);
    final message = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(
          method == 'whatsapp'
              ? context.loc.text('رسالة واتساب', 'WhatsApp message')
              : context.loc.text('رسالة SMS', 'SMS message'),
        ),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            minLines: 4,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: context.loc.text('نص الرسالة', 'Message'),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(context.loc.text('إلغاء', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, controller.text.trim()),
            child: Text(context.loc.text('فتح التطبيق', 'Open app')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (message == null || message.trim().isEmpty) return;

    Uri uri;
    if (method == 'whatsapp') {
      var digits = phone.replaceAll(RegExp(r'\D'), '');
      if (digits.startsWith('00')) digits = digits.substring(2);
      if (digits.startsWith('0')) digits = '970${digits.substring(1)}';
      uri = Uri.https('wa.me', '/$digits', {'text': message});
    } else {
      uri = Uri(scheme: 'sms', path: phone, queryParameters: {'body': message});
    }

    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (!opened) {
      await Clipboard.setData(ClipboardData(text: message));
      _showMessage(openFailureMessage);
      return;
    }
    try {
      await _queueMaintenance(
        'contact',
        order: order,
        data: {'method': method, 'result': 'attempted', 'note': contactNote},
      );
      unawaited(_load());
    } catch (_) {
      // The message handoff succeeded. A local recording failure should not
      // imply that the message was sent or prevent the customer contact.
    }
    _showMessage(openedMessage);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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

  Future<void> _openMaintenanceInvoice(Map<String, dynamic> order) async {
    final invoiceId = order['invoiceId']?.toString() ?? '';
    if (invoiceId.startsWith('local:')) {
      _showMessage(
        context.loc.text(
          'الفاتورة محفوظة محلياً؛ ستظهر هنا بعد اكتمال المزامنة.',
          'The invoice is saved locally and will be available here after sync.',
        ),
      );
      return;
    }
    final userId = _userId;
    if (userId == null) return;
    final invoiceNotFoundMessage = context.loc.text(
      'تعذر العثور على رابط الفاتورة. حدّث القائمة بعد اكتمال المزامنة.',
      'Invoice link is not available yet. Refresh after sync completes.',
    );
    final openFailedMessage = context.loc.text(
      'تعذر فتح الفاتورة؛ تم نسخ رابطها.',
      'Could not open the invoice. Its link was copied.',
    );
    try {
      var snapshot = await _offlineStore.getSnapshot(userId);
      var invoice = _list(
        snapshot['invoices'],
      ).where((item) => item['id']?.toString() == invoiceId).firstOrNull;
      if (invoice == null && ConnectivityService.instance.isOnline.value) {
        snapshot = await _offlineStore.refresh(userId: userId, api: _api);
        invoice = _list(
          snapshot['invoices'],
        ).where((item) => item['id']?.toString() == invoiceId).firstOrNull;
      }
      final shareUrl = invoice?['shareUrl']?.toString().trim() ?? '';
      if (shareUrl.isEmpty) {
        _showMessage(invoiceNotFoundMessage);
        return;
      }
      final opened = await launchUrl(
        Uri.parse(shareUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        await Clipboard.setData(ClipboardData(text: shareUrl));
        _showMessage(openFailedMessage);
      }
    } catch (error) {
      _showMessage(ErrorMessageService.sanitize(error));
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
    if (order['invoiceId'] == null) next.remove('delivered');
    return {current, ...next}.toList();
  }

  Future<void> _exportCsv() async {
    if (_hasMore && !ConnectivityService.instance.isOnline.value) {
      _showMessage(
        context.loc.text(
          'اتصل بالإنترنت لتحميل السجل الكامل قبل التصدير.',
          'Connect to load the full maintenance history before exporting.',
        ),
      );
      return;
    }
    final exportOrders = <Map<String, dynamic>>[];
    var offset = 0;
    var hasMore = true;
    try {
      while (hasMore) {
        final page = await _api.getMaintenanceSnapshot(
          search: _search.text,
          status: '',
          offset: offset,
          limit: 500,
        );
        exportOrders.addAll(
          _list(
            page['orders'],
          ).where((order) => _status.isEmpty || order['status'] == _status),
        );
        final pagination = _map(page['pagination']);
        final pageCount = (pagination['pageCount'] as num?)?.toInt() ?? 0;
        offset += pageCount;
        hasMore = pagination['hasMore'] == true && pageCount > 0;
      }
    } catch (error) {
      _showMessage(ErrorMessageService.sanitize(error));
      return;
    }
    for (final localOrder in _list(
      _data['orders'],
    ).where((order) => order['pendingSync'] == true)) {
      if (_status.isNotEmpty && localOrder['status'] != _status) continue;
      final index = exportOrders.indexWhere(
        (serverOrder) =>
            serverOrder['id']?.toString() == localOrder['id']?.toString() ||
            (localOrder['clientRef'] != null &&
                serverOrder['clientRef']?.toString() ==
                    localOrder['clientRef']?.toString()),
      );
      if (index >= 0) {
        exportOrders[index] = localOrder;
      } else {
        exportOrders.insert(0, localOrder);
      }
    }
    final buffer = StringBuffer()
      ..writeln(
        '\uFEFForder_number,status,priority,customer_name,customer_phone,device_type,brand,model,serial_number,location,technician,total,paid,due,created_at',
      );
    for (final order in exportOrders) {
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
        'received': context.loc.text('مستلمة', 'Received'),
        'diagnosing': context.loc.text('قيد الفحص', 'Diagnosing'),
        'waiting_customer': context.loc.text(
          'بانتظار العميل',
          'Waiting for customer',
        ),
        'waiting_parts': context.loc.text('بانتظار قطع', 'Waiting for parts'),
        'in_progress': context.loc.text('قيد الصيانة', 'In progress'),
        'completed': context.loc.text('جاهزة للتسليم', 'Ready for pickup'),
        'delivered': context.loc.text('تم التسليم', 'Delivered'),
        'cancelled': context.loc.text('ملغاة', 'Cancelled'),
      }[s] ??
      (s.isEmpty ? '-' : s);
  String _logLabel(Map<String, dynamic> log) {
    if (log['action'] == 'created') {
      return context.loc.text('استلام الجهاز', 'Device received');
    }
    if (log['action'] == 'updated') {
      return context.loc.text('تعديل بيانات الصيانة', 'Maintenance updated');
    }
    if (log['action'] == 'status_changed') {
      return context.loc.text('تغيير الحالة', 'Status changed');
    }
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

  String _logChanges(Map<String, dynamic> log) {
    final lines = <String>[];
    if (log['action'] == 'status_changed') {
      final from = log['fromStatus']?.toString() ?? '';
      final to = log['toStatus']?.toString() ?? '';
      if (to.isNotEmpty) {
        lines.add(
          context.loc.text(
            'الحالة: ${from.isEmpty ? '—' : _statusLabel(from)} ← ${_statusLabel(to)}',
            'Status: ${from.isEmpty ? '—' : _statusLabel(from)} → ${_statusLabel(to)}',
          ),
        );
      }
    }
    final changes = _map(_map(log['metadata'])['changes']);
    lines.addAll(
      changes.entries.map((entry) {
        final values = _map(entry.value);
        return '${_logFieldLabel(entry.key)}: ${_logValue(entry.key, values['from'])} → ${_logValue(entry.key, values['to'])}';
      }),
    );
    return lines.join('\n');
  }

  String _logFieldLabel(String field) =>
      {
        'location': context.loc.text('الموقع', 'Location'),
        'diagnosis': context.loc.text('التشخيص', 'Diagnosis'),
        'workNotes': context.loc.text('ملاحظات العمل', 'Work notes'),
        'customerNotes': context.loc.text('ملاحظات العميل', 'Customer notes'),
        'assignedToUserId': context.loc.text(
          'الفني المسؤول',
          'Assigned technician',
        ),
        'laborPrice': context.loc.text('أجرة العمل', 'Labor charge'),
        'otherCost': context.loc.text('تكلفة أخرى', 'Other cost'),
        'discount': context.loc.text('الخصم', 'Discount'),
        'paidAmount': context.loc.text('المبلغ المدفوع', 'Amount paid'),
        'estimatedCost': context.loc.text(
          'التكلفة التقديرية',
          'Estimated cost',
        ),
      }[field] ??
      field;

  String _logValue(String field, dynamic value) {
    if (value == null || value.toString().isEmpty) {
      return context.loc.text('—', '—');
    }
    if (field == 'assignedToUserId') {
      final employee = _employees
          .where((item) => item['id']?.toString() == value.toString())
          .firstOrNull;
      return employee?['name']?.toString() ?? value.toString();
    }
    if ({
      'laborPrice',
      'otherCost',
      'discount',
      'paidAmount',
      'estimatedCost',
    }.contains(field)) {
      return _money(num.tryParse(value.toString()) ?? 0);
    }
    return value.toString();
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
