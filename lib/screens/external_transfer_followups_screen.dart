import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:excel_community/excel_community.dart' hide Border;

import '../services/index.dart';
import '../utils/app_theme.dart';
import '../widgets/app_sidebar.dart';
import '../widgets/app_top_actions.dart';
import '../widgets/responsive_scaffold_container.dart';
import '../widgets/shwakel_card.dart';

class ExternalTransferFollowupsScreen extends StatefulWidget {
  const ExternalTransferFollowupsScreen({super.key});
  @override
  State<ExternalTransferFollowupsScreen> createState() =>
      _ExternalTransferFollowupsScreenState();
}

class _ExternalTransferFollowupsScreenState
    extends State<ExternalTransferFollowupsScreen> {
  final _api = ApiService();
  final _auth = AuthService();
  final _offline = ExternalTransferOfflineService();
  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _employees = [];
  bool _loading = true;
  bool _canManage = false;
  bool _canCreate = false;
  bool _isSubUser = false;
  bool _canReview = false;
  bool _showFilters = false;
  String _status = 'all';
  String _reviewed = 'all';
  String _employeeId = 'all';
  DateTime? _from;
  DateTime? _to;
  Timer? _liveRefresh;
  bool _loadedOnce = false;
  bool _loadingRows = false;
  String? _currentUserId;

  @override
  void initState() {
    super.initState();
    _load();
    // تحديث شبه فوري للحالات والإضافات الجديدة للحسابات المرتبطة بالمحل.
    _liveRefresh = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && !_loading) _load(silent: true);
    });
  }

  @override
  void dispose() {
    _liveRefresh?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (_loadingRows) return;
    _loadingRows = true;
    if (!silent) setState(() => _loading = true);
    try {
      final user = await _auth.currentUser();
      final userId = user?['id']?.toString();
      if (userId == null || userId.isEmpty) {
        throw StateError('تعذر تحديد الحساب الحالي.');
      }
      _currentUserId = userId;
      final isSubUser =
          user?['is_sub_user'] == true ||
          (user?['parent_user_id']?.toString().isNotEmpty ?? false);
      final ownerId = isSubUser
          ? (user?['parent_user_id']?.toString() ?? '')
          : userId;
      await ExternalAppNotificationService().setActiveWorkspaceId(
        isSubUser ? null : ownerId,
      );
      if (ConnectivityService.instance.isOnline.value) {
        await _offline.syncPending(userId: userId, api: _api);
      }
      if (!isSubUser) await _importCapturedNotifications(userId, ownerId);
      if (ConnectivityService.instance.isOnline.value) {
        await _offline.syncPending(userId: userId, api: _api);
      }
      final previous = {
        for (final row in _rows)
          '${row['id']}': '${row['delivery_status']}:${row['reviewed']}',
      };
      final filters = <String, String>{
        if (_from != null) 'from': _date(_from!),
        if (_to != null) 'to': _date(_to!),
        if (_status != 'all') 'status': _status,
        if (_reviewed != 'all') 'reviewed': _reviewed,
        if (_employeeId != 'all') 'employeeId': _employeeId,
      };
      final cacheScope = jsonEncode(filters);
      Map<String, dynamic> body;
      try {
        body = await _api.getExternalTransfers(filters: filters);
        await _offline.saveSnapshot(userId, body, scope: cacheScope);
      } catch (_) {
        if (await ConnectivityService.instance.checkNow()) rethrow;
        body =
            await _offline.getSnapshot(userId, scope: cacheScope) ??
            {
              'transfers': <dynamic>[],
              'employees': <dynamic>[],
              'totals': <String, dynamic>{},
              'canCreate': _canCreate,
              'canManage': _canManage,
              'canReview': _canReview,
              'isSubUser': _isSubUser,
            };
      }
      final pending = await _offline.getPending(userId);
      final localRows = pending
          .map((op) {
            final payload = Map<String, dynamic>.from(op['payload'] as Map);
            final queuedAt =
                op['queuedAt']?.toString() ?? DateTime.now().toIso8601String();
            return <String, dynamic>{
              'id': op['localId'],
              'client_ref': op['clientRef'],
              'record_type': payload['recordType'] ?? 'transfer',
              'source_app_name': payload['sourceAppName'],
              'source_notification_title': payload['sourceNotificationTitle'],
              'source_notification_message':
                  payload['sourceNotificationMessage'],
              'source_notification_at': payload['sourceNotificationAt'],
              'beneficiary_name': payload['beneficiaryName'],
              'beneficiary_mobile': payload['beneficiaryMobile'],
              'amount': payload['amount'],
              'destination_type': payload['destinationType'],
              'destination_name': payload['destinationName'] ?? '',
              'destination_account': payload['destinationAccount'] ?? '',
              'notes': payload['notes'] ?? '',
              'delivery_status': 'pending',
              'reviewed': false,
              'created_by_user_id': userId,
              'assigned_user_id': payload['assignedUserId'] ?? userId,
              'assigned_to_name': payload['assignedToName'] ?? '',
              'created_by_name': user?['name'] ?? user?['username'] ?? 'أنا',
              'created_at': queuedAt,
              'offline_pending': true,
              'sync_status': op['syncStatus'] ?? 'pending',
            };
          })
          .where((row) {
            final created = DateTime.tryParse('${row['created_at']}');
            if (_from != null &&
                (created == null ||
                    created.isBefore(
                      DateTime(_from!.year, _from!.month, _from!.day),
                    ))) {
              return false;
            }
            if (_to != null &&
                (created == null ||
                    created.isAfter(
                      DateTime(_to!.year, _to!.month, _to!.day, 23, 59, 59),
                    ))) {
              return false;
            }
            if (_status != 'all' && _status != 'pending') return false;
            if (_reviewed == '1') return false;
            if (_employeeId != 'all' &&
                '${row['assigned_user_id'] ?? userId}' != _employeeId) {
              return false;
            }
            return true;
          })
          .toList();
      final serverRows = List<Map<String, dynamic>>.from(
        (body['transfers'] as List? ?? []).map(
          (e) => Map<String, dynamic>.from(e as Map),
        ),
      );
      final mergedRows = [...localRows, ...serverRows];
      if (!mounted) return;
      setState(() {
        _rows = mergedRows;
        _employees = List<Map<String, dynamic>>.from(
          (body['employees'] as List? ?? []).map(
            (e) => Map<String, dynamic>.from(e as Map),
          ),
        );
        _canCreate = body['canCreate'] == true;
        _isSubUser = body['isSubUser'] == true;
        _canManage = body['canManage'] == true;
        _canReview = body['canReview'] == true;
        _loading = false;
      });
      if (silent && _loadedOnce) {
        final changed = _rows.any(
          (row) =>
              previous['${row['id']}'] !=
              '${row['delivery_status']}:${row['reviewed']}',
        );
        if (changed && mounted) {
          AppAlertService.showSnack(
            context,
            message: 'تم تحديث حالة إحدى التحويلات الخارجية.',
            type: AppAlertType.info,
          );
        }
      }
      _loadedOnce = true;
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        if (!silent) {
          AppAlertService.showError(
            context,
            title: 'تعذر التحميل',
            message: ErrorMessageService.sanitize(e),
          );
        }
      }
    } finally {
      _loadingRows = false;
    }
  }

  Future<void> _importCapturedNotifications(
    String userId,
    String ownerId,
  ) async {
    final capture = ExternalAppNotificationService();
    if (!capture.isSupported || !await capture.hasNotificationAccess()) return;
    final events = await capture.getPendingEvents();
    if (events.isEmpty) return;
    final existingRefs = (await _offline.getPending(userId))
        .map((operation) => operation['clientRef']?.toString())
        .whereType<String>()
        .toSet();
    final acknowledged = <String>[];
    for (final event in events) {
      final eventId = event['eventId']?.toString().trim() ?? '';
      if (eventId.isEmpty) continue;
      // Capture is bound to the merchant workspace where the notification
      // appeared; never upload an old device event to another signed-in shop.
      if (event['workspaceId']?.toString() != ownerId) continue;
      final clientRef = 'notification-$eventId';
      if (!existingRefs.contains(clientRef)) {
        final postedAt = int.tryParse('${event['postedAt'] ?? ''}');
        await _offline.enqueue(
          userId: userId,
          clientRef: clientRef,
          payload: {
            'recordType': 'app_notification',
            'sourceNotificationKey': eventId,
            'sourceAppPackage': event['packageName']?.toString() ?? '',
            'sourceAppName': event['appName']?.toString() ?? 'تطبيق',
            'sourceNotificationTitle': event['title']?.toString() ?? '',
            'sourceNotificationMessage': event['message']?.toString() ?? '',
            if (postedAt != null && postedAt > 0)
              'sourceNotificationAt': DateTime.fromMillisecondsSinceEpoch(
                postedAt,
              ).toIso8601String(),
          },
        );
        existingRefs.add(clientRef);
      }
      acknowledged.add(eventId);
    }
    await capture.acknowledgeEvents(acknowledged);
  }

  Future<void> _showAppNotificationSettings() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => const _ExternalAppNotificationSettingsDialog(),
    );
    if (saved == true && mounted) {
      AppAlertService.showSnack(
        context,
        message: 'تم حفظ إعدادات متابعة إشعارات التطبيقات.',
        type: AppAlertType.success,
      );
      await _load();
    }
  }

  String _date(DateTime value) => value.toIso8601String().substring(0, 10);

  Future<void> _pickDate(bool from) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: from
          ? (_from ?? DateTime.now())
          : (_to ?? _from ?? DateTime.now()),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      if (from) {
        _from = picked;
      } else {
        _to = picked;
      }
    });
    await _load();
  }

  Future<void> _markDayReviewed() async {
    if (!_canReview) return;
    final pending = _rows
        .where((r) => !(r['reviewed'] == true || r['reviewed'] == 1))
        .toList();
    for (final row in pending) {
      await _api.updateExternalTransfer('${row['id']}', {
        'deliveryStatus': row['delivery_status'] ?? 'pending',
        'reviewed': true,
      });
    }
    await _load();
  }

  Future<void> _exportCsv() async {
    final excel = Excel.createExcel();
    const sheetName = 'التحويلات الخارجية';
    final sheet = excel[sheetName];
    excel.setDefaultSheet(sheetName);
    if (excel.tables.containsKey('Sheet1')) excel.delete('Sheet1');
    const headers = [
      'المستفيد',
      'الجوال',
      'القيمة',
      'الجهة',
      'الحساب',
      'حالة الوصول',
      'المراجعة',
      'بواسطة',
      'التاريخ',
      'مزامنة محلية',
    ];
    sheet.appendRow(headers.map(TextCellValue.new).toList());
    for (final row in _rows) {
      final status = switch (row['delivery_status']?.toString()) {
        'arrived' => 'وصلت',
        'not_arrived' => 'لم تصل',
        _ => 'معلقة',
      };
      sheet.appendRow([
        TextCellValue(row['beneficiary_name']?.toString() ?? ''),
        TextCellValue(row['beneficiary_mobile']?.toString() ?? ''),
        DoubleCellValue(double.tryParse('${row['amount']}') ?? 0),
        TextCellValue(row['destination_name']?.toString() ?? ''),
        TextCellValue(row['destination_account']?.toString() ?? ''),
        TextCellValue(status),
        TextCellValue(
          row['reviewed'] == true || row['reviewed'] == 1 ? 'نعم' : 'لا',
        ),
        TextCellValue(row['created_by_name']?.toString() ?? ''),
        TextCellValue(row['created_at']?.toString() ?? ''),
        TextCellValue(
          row['offline_pending'] == true ? 'بانتظار المزامنة' : 'تمت',
        ),
      ]);
    }
    for (var column = 0; column < headers.length; column++) {
      sheet.setColumnWidth(column, column == 0 || column == 3 ? 24 : 18);
      final cell = sheet.cell(
        CellIndex.indexByColumnRow(columnIndex: column, rowIndex: 0),
      );
      cell.cellStyle = CellStyle(
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
      name:
          'external_transfers_${DateTime.now().toIso8601String().substring(0, 10)}',
      bytes: Uint8List.fromList(bytes),
      fileExtension: 'xlsx',
      mimeType: MimeType.microsoftExcel,
    );
  }

  Future<void> _add() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ExternalTransferDialog(
        employees: _employees,
        defaultAssigneeId: _currentUserId,
      ),
    );
    if (result == null) return;
    try {
      final userId =
          _currentUserId ?? (await _auth.currentUser())?['id']?.toString();
      if (userId == null || userId.isEmpty) {
        throw StateError('تعذر تحديد الحساب الحالي.');
      }
      final operation = await _offline.enqueue(userId: userId, payload: result);
      if (ConnectivityService.instance.isOnline.value) {
        await _offline.syncPending(userId: userId, api: _api);
      }
      final stillPending = (await _offline.getPending(
        userId,
      )).any((item) => item['clientRef'] == operation['clientRef']);
      await _load();
      if (mounted && !stillPending) {
        AppAlertService.showSuccess(
          context,
          title: 'تمت الإضافة',
          message: 'تمت إضافة العملية للمتابعة.',
        );
      } else if (mounted) {
        AppAlertService.showSnack(
          context,
          message: 'حُفظت العملية محلياً وستتم مزامنتها عند عودة الاتصال.',
          type: AppAlertType.info,
        );
      }
    } catch (e) {
      if (mounted) {
        AppAlertService.showError(
          context,
          title: 'تعذر الحفظ',
          message: ErrorMessageService.sanitize(e),
        );
      }
    }
  }

  Future<void> _edit(Map<String, dynamic> row) async {
    if (row['offline_pending'] == true) {
      AppAlertService.showSnack(
        context,
        message: 'تعذر تعديل العملية قبل مزامنتها.',
        type: AppAlertType.info,
      );
      return;
    }
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ExternalTransferDialog(
        initial: row,
        employees: _employees,
        canChooseAssignee: _canManage,
        defaultAssigneeId: _currentUserId,
      ),
    );
    if (result == null) return;
    try {
      await _api.updateExternalTransfer('${row['id']}', result);
      await _load();
    } catch (e) {
      if (mounted) {
        AppAlertService.showError(
          context,
          title: 'تعذر التعديل',
          message: ErrorMessageService.sanitize(e),
        );
      }
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف العملية'),
        content: const Text('هل تريد حذف سجل التحويل الخارجي؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      if (row['offline_pending'] == true) {
        final userId = _currentUserId;
        if (userId == null) return;
        await _offline.deletePending(
          userId: userId,
          clientRef: '${row['client_ref']}',
        );
      } else {
        await _api.deleteExternalTransfer('${row['id']}');
      }
      await _load();
    } catch (e) {
      if (mounted) {
        AppAlertService.showError(
          context,
          title: 'تعذر الحذف',
          message: ErrorMessageService.sanitize(e),
        );
      }
    }
  }

  Future<void> _setReview(
    Map<String, dynamic> row,
    String status,
    bool reviewed,
  ) async {
    if (row['offline_pending'] == true) {
      AppAlertService.showSnack(
        context,
        message: 'ستتاح مراجعة الحالة بعد مزامنة العملية.',
        type: AppAlertType.info,
      );
      return;
    }
    try {
      await _api.updateExternalTransfer('${row['id']}', {
        'deliveryStatus': status,
        'reviewed': reviewed,
      });
      await _load();
    } catch (e) {
      if (mounted) {
        AppAlertService.showError(
          context,
          title: 'تعذر التحديث',
          message: ErrorMessageService.sanitize(e),
        );
      }
    }
  }

  Future<void> _showReport(String period) async {
    try {
      final body = await _api.getExternalTransfersReport(
        filters: {
          'period': period,
          if (_from != null) 'from': _date(_from!),
          if (_to != null) 'to': _date(_to!),
          if (_employeeId != 'all') 'employeeId': _employeeId,
        },
      );
      if (!mounted) return;
      final rows = List<Map<String, dynamic>>.from(
        (body['rows'] as List? ?? []).map(
          (e) => Map<String, dynamic>.from(e as Map),
        ),
      );
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('تقرير التحويلات الخارجية'),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: rows
                    .map(
                      (r) => Text(
                        '${r['period']} • ${r['employeeName']} • ${r['transfers']} عملية • ${r['totalAmount']} القيمة • ${r['arrived']} وصلت • ${r['notArrived']} لم تصل',
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        AppAlertService.showError(
          context,
          title: 'تعذر التقرير',
          message: ErrorMessageService.sanitize(e),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('التحويلات الخارجية'),
        actions: [
          IconButton(
            onPressed: () => setState(() => _showFilters = !_showFilters),
            tooltip: _showFilters ? 'إخفاء الفلاتر' : 'الفلاتر',
            icon: Icon(
              _showFilters
                  ? Icons.filter_alt_off_rounded
                  : Icons.filter_alt_rounded,
            ),
          ),
          if (_canManage)
            IconButton(
              onPressed: _showAppNotificationSettings,
              tooltip: 'إعدادات إشعارات التطبيقات',
              icon: const Icon(Icons.notifications_active_outlined),
            ),
          const AppNotificationAction(),
          const QuickLogoutAction(),
        ],
      ),
      drawer: AppSidebar.drawerFor(context),
      body: _loading
          ? const ShwakelPageLoadingContent()
          : RefreshIndicator(
              onRefresh: _load,
              child: ResponsiveScaffoldContainer(
                padding: const EdgeInsets.all(AppTheme.spacingLg),
                child: ListView(
                  children: [
                    ShwakelCard(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final reportMenu = PopupMenuButton<String>(
                                icon: const Icon(Icons.bar_chart_rounded),
                                tooltip: 'التقرير',
                                onSelected: _showReport,
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'day',
                                    child: Text('تقرير يومي'),
                                  ),
                                  PopupMenuItem(
                                    value: 'week',
                                    child: Text('تقرير أسبوعي'),
                                  ),
                                  PopupMenuItem(
                                    value: 'month',
                                    child: Text('تقرير شهري'),
                                  ),
                                ],
                              );
                              final actions = <Widget>[
                                if (_canCreate)
                                  FilledButton.icon(
                                    onPressed: _add,
                                    icon: const Icon(Icons.add),
                                    label: const Text('إضافة عملية'),
                                  ),
                                if (_canReview)
                                  OutlinedButton.icon(
                                    onPressed: _markDayReviewed,
                                    icon: const Icon(Icons.done_all),
                                    label: const Text('اعتماد مراجعة الفترة'),
                                  ),
                                OutlinedButton.icon(
                                  onPressed: _rows.isEmpty ? null : _exportCsv,
                                  icon: const Icon(
                                    Icons.file_download_outlined,
                                  ),
                                  label: const Text('تصدير Excel'),
                                ),
                              ];
                              if (constraints.maxWidth < 900) {
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            'التحويلات الخارجية',
                                            style: AppTheme.h3,
                                          ),
                                        ),
                                        reportMenu,
                                      ],
                                    ),
                                    if (actions.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: actions,
                                      ),
                                    ],
                                  ],
                                );
                              }
                              return Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'التحويلات الخارجية',
                                      style: AppTheme.h3,
                                    ),
                                  ),
                                  reportMenu,
                                  ...actions.map(
                                    (action) => Padding(
                                      padding: const EdgeInsetsDirectional.only(
                                        start: 8,
                                      ),
                                      child: action,
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                          if (_showFilters) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: () => _pickDate(true),
                                  icon: const Icon(Icons.date_range),
                                  label: Text(
                                    _from == null ? 'من تاريخ' : _date(_from!),
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () => _pickDate(false),
                                  icon: const Icon(Icons.event),
                                  label: Text(
                                    _to == null ? 'إلى تاريخ' : _date(_to!),
                                  ),
                                ),
                                if (_from != null || _to != null)
                                  TextButton(
                                    onPressed: () {
                                      setState(() {
                                        _from = null;
                                        _to = null;
                                      });
                                      _load();
                                    },
                                    child: const Text('مسح التاريخ'),
                                  ),
                                DropdownButton<String>(
                                  value: _status,
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'all',
                                      child: Text('كل الحالات'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'pending',
                                      child: Text('قيد المتابعة'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'arrived',
                                      child: Text('وصلت'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'not_arrived',
                                      child: Text('لم تصل'),
                                    ),
                                  ],
                                  onChanged: (v) {
                                    if (v != null) {
                                      setState(() => _status = v);
                                      _load();
                                    }
                                  },
                                ),
                                DropdownButton<String>(
                                  value: _reviewed,
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'all',
                                      child: Text('كل المراجعات'),
                                    ),
                                    DropdownMenuItem(
                                      value: '0',
                                      child: Text('غير مراجعة'),
                                    ),
                                    DropdownMenuItem(
                                      value: '1',
                                      child: Text('تمت المراجعة'),
                                    ),
                                  ],
                                  onChanged: (v) {
                                    if (v != null) {
                                      setState(() => _reviewed = v);
                                      _load();
                                    }
                                  },
                                ),
                                if (!_isSubUser && _employees.length > 1)
                                  DropdownButton<String>(
                                    value: _employeeId,
                                    hint: const Text('التابع / المنفذ'),
                                    items: [
                                      const DropdownMenuItem(
                                        value: 'all',
                                        child: Text('كل التابعين'),
                                      ),
                                      ..._employees.map(
                                        (employee) => DropdownMenuItem(
                                          value: '${employee['id']}',
                                          child: Text(
                                            employee['name']?.toString() ??
                                                'مستخدم',
                                          ),
                                        ),
                                      ),
                                    ],
                                    onChanged: (v) {
                                      if (v != null) {
                                        setState(() => _employeeId = v);
                                        _load();
                                      }
                                    },
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_rows.isEmpty)
                      const ShwakelCard(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: Text('لا توجد تحويلات خارجية مسجلة.'),
                        ),
                      ),
                    ..._rows.map(_row),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _row(Map<String, dynamic> row) {
    final offlinePending = row['offline_pending'] == true;
    final isAppNotification = row['record_type'] == 'app_notification';
    final status = row['delivery_status']?.toString() ?? 'pending';
    final reviewed = row['reviewed'] == true || row['reviewed'] == 1;
    final statusText = switch (status) {
      'arrived' => 'وصلت',
      'not_arrived' => 'لم تصل',
      _ => 'معلقة',
    };
    final statusColor = switch (status) {
      'arrived' => Colors.green,
      'not_arrived' => Colors.red,
      _ => Colors.blue,
    };
    final destinationDetails = [
      row['destination_name']?.toString().trim() ?? '',
      row['destination_account']?.toString().trim() ?? '',
    ].where((value) => value.isNotEmpty).join(' • ');
    final creator = row['created_by_name']?.toString().trim() ?? '';
    final rawNotes = row['notes']?.toString().trim() ?? '';
    final notes = RegExp(r'^[\s•·\-.,،؛:]+$').hasMatch(rawNotes)
        ? ''
        : rawNotes;
    final assigned = row['assigned_to_name']?.toString().trim() ?? '';
    final attribution = [
      if (assigned.isNotEmpty) 'لـ: $assigned',
      if (creator.isNotEmpty) 'أضافها: $creator',
      if (notes.isNotEmpty) notes,
    ].join(' • ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ShwakelCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    isAppNotification
                        ? 'إشعار تطبيق: ${row['source_app_name'] ?? row['beneficiary_name'] ?? ''}'
                        : '${row['beneficiary_name'] ?? ''} — ${row['beneficiary_mobile'] ?? ''}',
                    style: AppTheme.bodyBold,
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (!isAppNotification) ...[
                      Text(
                        '${row['amount'] ?? 0}',
                        style: AppTheme.bodyBold.copyWith(
                          fontSize: 18,
                          color: AppTheme.primary,
                        ),
                      ),
                      const Text(
                        'القيمة',
                        style: TextStyle(fontSize: 11, color: Colors.black54),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Chip(
                      avatar: Icon(
                        status == 'arrived'
                            ? Icons.check_circle
                            : status == 'not_arrived'
                            ? Icons.cancel
                            : Icons.schedule,
                        size: 16,
                        color: statusColor,
                      ),
                      label: Text(
                        statusText,
                        style: TextStyle(
                          color: statusColor.shade700,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      backgroundColor: statusColor.withValues(alpha: 0.12),
                      side: BorderSide(
                        color: statusColor.withValues(alpha: 0.35),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    if (offlinePending)
                      const Chip(
                        avatar: Icon(Icons.cloud_upload_outlined, size: 15),
                        label: Text('بانتظار المزامنة'),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
                if (_canManage) ...[
                  if (!isAppNotification)
                    IconButton(
                      onPressed: () => _edit(row),
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: 'تعديل',
                    ),
                  IconButton(
                    onPressed: () => _delete(row),
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'حذف',
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            if (isAppNotification) ...[
              if ((row['source_notification_title'] ?? '')
                  .toString()
                  .isNotEmpty)
                Text(
                  '${row['source_notification_title']}',
                  style: AppTheme.bodyBold,
                ),
              SelectableText(
                (row['source_notification_message'] ?? row['notes'] ?? '')
                    .toString(),
              ),
              Text(
                'من ${row['created_by_name'] ?? ''} • ${row['source_notification_at'] ?? row['created_at'] ?? ''}',
                style: AppTheme.caption,
              ),
            ] else ...[
              if (destinationDetails.isNotEmpty) Text(destinationDetails),
              if (attribution.isNotEmpty)
                Text(attribution, style: AppTheme.caption),
            ],
            if (_canReview && !offlinePending)
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('قيد المتابعة'),
                    selected: status == 'pending',
                    onSelected: (_) => _setReview(row, 'pending', reviewed),
                  ),
                  ChoiceChip(
                    label: const Text('وصلت'),
                    selected: status == 'arrived',
                    onSelected: (_) => _setReview(row, 'arrived', true),
                  ),
                  ChoiceChip(
                    label: const Text('لم تصل'),
                    selected: status == 'not_arrived',
                    onSelected: (_) => _setReview(row, 'not_arrived', true),
                  ),
                  FilterChip(
                    label: const Text('تمت المراجعة'),
                    selected: reviewed,
                    onSelected: (v) => _setReview(row, status, v),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ExternalAppNotificationSettingsDialog extends StatefulWidget {
  const _ExternalAppNotificationSettingsDialog();

  @override
  State<_ExternalAppNotificationSettingsDialog> createState() =>
      _ExternalAppNotificationSettingsDialogState();
}

class _ExternalAppNotificationSettingsDialogState
    extends State<_ExternalAppNotificationSettingsDialog> {
  final _capture = ExternalAppNotificationService();
  List<Map<String, dynamic>> _apps = [];
  Set<String> _selected = {};
  bool _hasAccess = false;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_capture.isSupported) {
      setState(() => _loading = false);
      return;
    }
    try {
      final results = await Future.wait([
        _capture.getApps(),
        _capture.getSelectedPackages(),
        _capture.hasNotificationAccess(),
      ]);
      if (!mounted) return;
      setState(() {
        _apps = results[0] as List<Map<String, dynamic>>;
        _selected = (results[1] as List<String>).toSet();
        _hasAccess = results[2] as bool;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _requestAccess() async {
    await _capture.openNotificationAccessSettings();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _load();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _capture.setSelectedPackages(_selected.toList());
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        AppAlertService.showError(
          context,
          title: 'تعذر حفظ الإعدادات',
          message: ErrorMessageService.sanitize(error),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_capture.isSupported) {
      return AlertDialog(
        title: const Text('إشعارات التطبيقات'),
        content: const Text(
          'التقاط إشعارات التطبيقات متاح في تطبيق أندرويد فقط، ولا يعمل من نسخة الويب أو iPhone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إغلاق'),
          ),
        ],
      );
    }
    return AlertDialog(
      title: const Text('إشعارات التطبيقات البنكية'),
      content: SizedBox(
        width: 460,
        child: _loading
            ? const SizedBox(
                height: 180,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'اقتُرحت تطبيقات Jawwal Pay وPalPay وتطبيقات البنوك المثبتة تلقائيًا عند أول فتح. عنوان الإشعار ونصه سيُحفظان ضمن متابعة التحويلات ويظهران للتاجر الرئيسي والتابعين المخولين بعرضها.',
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: Icon(
                        _hasAccess ? Icons.verified_user : Icons.security,
                      ),
                      title: Text(
                        _hasAccess
                            ? 'صلاحية قراءة الإشعارات مفعلة'
                            : 'فعّل صلاحية الوصول للإشعارات',
                      ),
                      subtitle: const Text(
                        'يمكن إيقافها في أي وقت من إعدادات أندرويد.',
                      ),
                      trailing: TextButton(
                        onPressed: _requestAccess,
                        child: Text(_hasAccess ? 'الإعدادات' : 'فتح الإعدادات'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('الإشعارات المختارة ستُشارك مع مساحة المتجر.'),
                  const SizedBox(height: 6),
                  Flexible(
                    child: _apps.isEmpty
                        ? const Center(
                            child: Text(
                              'لم يتم العثور على تطبيقات قابلة للاختيار.',
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: _apps.length,
                            itemBuilder: (context, index) {
                              final app = _apps[index];
                              final packageName =
                                  app['packageName']?.toString() ?? '';
                              return CheckboxListTile(
                                value: _selected.contains(packageName),
                                title: Text(
                                  app['appName']?.toString() ?? packageName,
                                ),
                                subtitle: Text(packageName),
                                dense: true,
                                onChanged: packageName.isEmpty
                                    ? null
                                    : (value) => setState(() {
                                        if (value == true) {
                                          _selected.add(packageName);
                                        } else {
                                          _selected.remove(packageName);
                                        }
                                      }),
                              );
                            },
                          ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: _loading || _saving ? null : _save,
          child: Text(_saving ? 'جار الحفظ…' : 'حفظ الاختيار'),
        ),
      ],
    );
  }
}

class _ExternalTransferDialog extends StatefulWidget {
  final Map<String, dynamic>? initial;
  final List<Map<String, dynamic>> employees;
  final bool canChooseAssignee;
  final String? defaultAssigneeId;

  const _ExternalTransferDialog({
    this.initial,
    this.employees = const [],
    this.canChooseAssignee = true,
    this.defaultAssigneeId,
  });
  @override
  State<_ExternalTransferDialog> createState() =>
      _ExternalTransferDialogState();
}

class _ExternalTransferDialogState extends State<_ExternalTransferDialog> {
  final name = TextEditingController();
  final mobile = TextEditingController();
  final amount = TextEditingController();
  final destination = TextEditingController();
  final account = TextEditingController();
  final notes = TextEditingController();
  String type = 'bank';
  int? assignedUserId;

  @override
  void initState() {
    super.initState();
    final row = widget.initial;
    assignedUserId = int.tryParse(
      '${row?['assigned_user_id'] ?? widget.defaultAssigneeId ?? ''}',
    );
    if (!widget.employees.any(
      (employee) => '${employee['id']}' == '$assignedUserId',
    )) {
      assignedUserId = widget.employees.isEmpty
          ? null
          : int.tryParse('${widget.employees.first['id']}');
    }
    if (row != null) {
      name.text = '${row['beneficiary_name'] ?? ''}';
      mobile.text = '${row['beneficiary_mobile'] ?? ''}';
      amount.text = '${row['amount'] ?? ''}';
      destination.text = '${row['destination_name'] ?? ''}';
      account.text = '${row['destination_account'] ?? ''}';
      notes.text = '${row['notes'] ?? ''}';
      type = '${row['destination_type'] ?? 'bank'}';
    }
  }

  @override
  void dispose() {
    for (final controller in [
      name,
      mobile,
      amount,
      destination,
      account,
      notes,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    Widget field(Widget child) => wide ? Expanded(child: child) : child;
    Widget gap() => SizedBox(width: wide ? 12 : 0, height: wide ? 0 : 8);
    Widget row(List<Widget> children) => wide
        ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: children)
        : Column(children: children);

    return AlertDialog(
      title: Text(
        widget.initial == null ? 'إضافة تحويل خارجي' : 'تعديل تحويل خارجي',
      ),
      content: SizedBox(
        width: wide ? 720 : null,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.employees.length > 1 &&
                  (widget.canChooseAssignee || widget.initial == null)) ...[
                DropdownButtonFormField<int>(
                  initialValue: assignedUserId,
                  decoration: const InputDecoration(
                    labelText: 'تُسجل على حساب',
                  ),
                  items: widget.employees
                      .map(
                        (employee) => DropdownMenuItem<int>(
                          value: int.tryParse('${employee['id']}'),
                          child: Text(employee['name']?.toString() ?? 'تابع'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => assignedUserId = value),
                ),
                const SizedBox(height: 10),
              ],
              row([
                field(
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'اسم المستفيد *',
                    ),
                  ),
                ),
                gap(),
                field(
                  TextField(
                    controller: mobile,
                    decoration: const InputDecoration(
                      labelText: 'رقم الجوال *',
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              row([
                field(
                  TextField(
                    controller: amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'القيمة *',
                      helperText:
                          'أدخل قيمة سالبة لعكس الحركة وخصمها من الإجمالي.',
                    ),
                  ),
                ),
                gap(),
                field(
                  DropdownButtonFormField<String>(
                    initialValue: type,
                    decoration: const InputDecoration(labelText: 'الجهة *'),
                    items: const [
                      DropdownMenuItem(value: 'bank', child: Text('بنك')),
                      DropdownMenuItem(value: 'wallet', child: Text('محفظة')),
                      DropdownMenuItem(
                        value: 'jawwal_pay',
                        child: Text('جوال باي'),
                      ),
                      DropdownMenuItem(value: 'palpay', child: Text('بال باي')),
                      DropdownMenuItem(value: 'cash', child: Text('كاش')),
                      DropdownMenuItem(value: 'other', child: Text('أخرى')),
                    ],
                    onChanged: (value) =>
                        setState(() => type = value ?? 'bank'),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              row([
                field(
                  TextField(
                    controller: destination,
                    decoration: const InputDecoration(
                      labelText: 'اسم البنك أو المحفظة (اختياري)',
                    ),
                  ),
                ),
                gap(),
                field(
                  TextField(
                    controller: account,
                    decoration: const InputDecoration(
                      labelText: 'رقم الحساب / المحفظة (اختياري)',
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              TextField(
                controller: notes,
                decoration: const InputDecoration(
                  labelText: 'ملاحظات (اختياري)',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () {
            final parsedAmount = double.tryParse(amount.text);
            if (name.text.trim().isEmpty ||
                mobile.text.trim().isEmpty ||
                parsedAmount == null ||
                parsedAmount == 0 ||
                assignedUserId == null) {
              return;
            }
            Navigator.pop(context, {
              'beneficiaryName': name.text.trim(),
              'beneficiaryMobile': mobile.text.trim(),
              'amount': parsedAmount,
              'assignedUserId': assignedUserId,
              'assignedToName': widget.employees
                  .where((employee) => '${employee['id']}' == '$assignedUserId')
                  .map((employee) => employee['name']?.toString() ?? '')
                  .firstWhere((name) => name.isNotEmpty, orElse: () => ''),
              'destinationType': type,
              'destinationName': destination.text.trim(),
              'destinationAccount': account.text.trim(),
              'notes': notes.text.trim(),
              'profitMode': 'rate',
              'profitRate': 0,
              'profitFlat': 0,
            });
          },
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}
