import 'package:flutter/material.dart';

import '../services/index.dart';
import '../utils/app_theme.dart';
import '../widgets/app_sidebar.dart';
import '../widgets/app_top_actions.dart';
import '../widgets/responsive_scaffold_container.dart';
import '../widgets/shwakel_card.dart';

class ExternalTransferAccountingScreen extends StatefulWidget {
  const ExternalTransferAccountingScreen({super.key});

  @override
  State<ExternalTransferAccountingScreen> createState() =>
      _ExternalTransferAccountingScreenState();
}

class _ExternalTransferAccountingScreenState
    extends State<ExternalTransferAccountingScreen> {
  final _api = ApiService();
  bool _loading = true;
  bool _showFilters = false;
  String _employeeId = 'all';
  DateTime? _from;
  DateTime? _to;
  int? _settlingEmployeeId;
  List<Map<String, dynamic>> _employees = [];
  List<Map<String, dynamic>> _summary = [];
  List<Map<String, dynamic>> _dailyRows = [];
  List<Map<String, dynamic>> _settlements = [];
  Map<String, dynamic> _dailyTotals = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _date(DateTime value) => value.toIso8601String().substring(0, 10);

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final result = await _api.getExternalTransferAccounting(
        filters: {
          if (_from != null) 'from': _date(_from!),
          if (_to != null) 'to': _date(_to!),
          if (_employeeId != 'all') 'employeeId': _employeeId,
        },
      );
      if (!mounted) return;
      setState(() {
        _employees = _mapList(result['employees']);
        _summary = _mapList(result['summary']);
        _dailyRows = _mapList(result['dailyRows']);
        _settlements = _mapList(result['settlements']);
        _dailyTotals = Map<String, dynamic>.from(
          result['dailyTotals'] as Map? ?? const {},
        );
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppAlertService.showError(
        context,
        title: 'تعذر تحميل التصفية',
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  List<Map<String, dynamic>> _mapList(dynamic value) =>
      (value as List? ?? const [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();

  Future<void> _pickDate(bool isFrom) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: isFrom
          ? (_from ?? DateTime.now())
          : (_to ?? _from ?? DateTime.now()),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (selected == null) return;
    setState(() {
      if (isFrom) {
        _from = selected;
        if (_to != null && _to!.isBefore(selected)) _to = selected;
      } else {
        _to = selected;
        if (_from != null && _from!.isAfter(selected)) _from = selected;
      }
    });
    await _load();
  }

  Future<void> _closeAccount(Map<String, dynamic> employee) async {
    final id = int.tryParse('${employee['employeeId'] ?? employee['id']}');
    if (id == null) return;
    final count = int.tryParse('${employee['openTransfers'] ?? 0}') ?? 0;
    if (count == 0) return;
    final name = employee['employeeName'] ?? employee['name'] ?? 'التابع';
    final amount = _money(employee['openAmount']);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إغلاق الفترة المحاسبية'),
        content: Text(
          'سيتم إغلاق $count حركة لحساب $name بإجمالي $amount ₪ وحفظها في سجل الإغلاقات. تبدأ بعد ذلك فترة جديدة للحركات التالية.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('رجوع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('إغلاق الحساب'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _settlingEmployeeId = id);
    try {
      final result = await _api.settleExternalTransferAccount(id);
      if (!mounted) return;
      final settlement = result['settlement'];
      if (settlement == null) {
        AppAlertService.showSnack(
          context,
          message: result['message']?.toString() ?? 'لا توجد حركات مفتوحة.',
          type: AppAlertType.info,
        );
      } else {
        AppAlertService.showSuccess(
          context,
          title: 'تم إغلاق الفترة',
          message:
              '${settlement['employeeName']} • ${settlement['transferCount']} حركة • ${_money(settlement['totalAmount'])} ₪',
        );
      }
      await _load();
    } catch (error) {
      if (mounted) {
        AppAlertService.showError(
          context,
          title: 'تعذر إغلاق الحساب',
          message: ErrorMessageService.sanitize(error),
        );
      }
    } finally {
      if (mounted) setState(() => _settlingEmployeeId = null);
    }
  }

  String _money(dynamic value) =>
      (double.tryParse('$value') ?? 0).toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('تصفية الحسابات'),
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
          IconButton(
            onPressed: _loading ? null : _load,
            tooltip: 'تحديث',
            icon: const Icon(Icons.refresh_rounded),
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
                          Text('تصفية حسابات التابعين', style: AppTheme.h3),
                          const SizedBox(height: 5),
                          Text(
                            'راجع الحركات اليومية والإجماليات، ثم أغلق فترة كل تابع على حدة.',
                            style: AppTheme.caption,
                          ),
                          if (_showFilters) ...[
                            const SizedBox(height: 14),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: () => _pickDate(true),
                                  icon: const Icon(Icons.date_range_rounded),
                                  label: Text(
                                    _from == null ? 'من تاريخ' : _date(_from!),
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () => _pickDate(false),
                                  icon: const Icon(Icons.event_rounded),
                                  label: Text(
                                    _to == null ? 'إلى تاريخ' : _date(_to!),
                                  ),
                                ),
                                if (_employees.length > 1)
                                  DropdownButton<String>(
                                    value: _employeeId,
                                    hint: const Text('كل الحسابات'),
                                    items: [
                                      const DropdownMenuItem(
                                        value: 'all',
                                        child: Text('كل الحسابات'),
                                      ),
                                      ..._employees.map(
                                        (employee) => DropdownMenuItem(
                                          value: '${employee['id']}',
                                          child: Text(
                                            employee['name']?.toString() ??
                                                'تابع',
                                          ),
                                        ),
                                      ),
                                    ],
                                    onChanged: (value) {
                                      if (value == null) return;
                                      setState(() => _employeeId = value);
                                      _load();
                                    },
                                  ),
                                if (_from != null ||
                                    _to != null ||
                                    _employeeId != 'all')
                                  TextButton.icon(
                                    onPressed: () {
                                      setState(() {
                                        _from = null;
                                        _to = null;
                                        _employeeId = 'all';
                                      });
                                      _load();
                                    },
                                    icon: const Icon(Icons.clear_rounded),
                                    label: const Text('مسح الفلاتر'),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    _sectionTitle('الحسابات المفتوحة'),
                    if (_summary.isEmpty)
                      const ShwakelCard(
                        padding: EdgeInsets.all(20),
                        child: Text('لا توجد حسابات تابعة مرتبطة بهذا التاجر.'),
                      ),
                    ..._summary.map(_employeeCard),
                    const SizedBox(height: 8),
                    _sectionTitle('الحركات اليومية'),
                    _totalsCard(),
                    if (_dailyRows.isEmpty)
                      const ShwakelCard(
                        padding: EdgeInsets.all(20),
                        child: Text('لا توجد حركات ضمن الفترة المحددة.'),
                      ),
                    ..._dailyRows.map(_dailyCard),
                    const SizedBox(height: 8),
                    _sectionTitle('سجل الإغلاقات'),
                    if (_settlements.isEmpty)
                      const ShwakelCard(
                        padding: EdgeInsets.all(20),
                        child: Text('لم تُغلق فترات محاسبية بعد.'),
                      ),
                    ..._settlements.map(_settlementCard),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8, top: 4),
    child: Text(title, style: AppTheme.bodyBold),
  );

  Widget _employeeCard(Map<String, dynamic> employee) {
    final id = int.tryParse('${employee['employeeId']}') ?? 0;
    final count = int.tryParse('${employee['openTransfers']}') ?? 0;
    final amount = _money(employee['openAmount']);
    final profit = _money(employee['openProfit']);
    final busy = _settlingEmployeeId == id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: ShwakelCard(
        padding: const EdgeInsets.all(15),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 560;
            final details = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  employee['employeeName']?.toString() ?? 'تابع',
                  style: AppTheme.bodyBold,
                ),
                const SizedBox(height: 7),
                Wrap(
                  spacing: 14,
                  runSpacing: 4,
                  children: [
                    Text('$count حركة مفتوحة'),
                    Text('الإجمالي: $amount ₪'),
                    Text('الربح: $profit ₪'),
                  ],
                ),
              ],
            );
            final button = FilledButton.tonalIcon(
              onPressed: count == 0 || _settlingEmployeeId != null
                  ? null
                  : () => _closeAccount(employee),
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.lock_clock_rounded),
              label: const Text('إغلاق الفترة'),
            );
            return narrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [details, const SizedBox(height: 12), button],
                  )
                : Row(
                    children: [
                      Expanded(child: details),
                      const SizedBox(width: 12),
                      button,
                    ],
                  );
          },
        ),
      ),
    );
  }

  Widget _totalsCard() => ShwakelCard(
    padding: const EdgeInsets.all(14),
    child: Wrap(
      spacing: 18,
      runSpacing: 8,
      children: [
        Text('الحركات: ${_dailyTotals['transfers'] ?? 0}'),
        Text('الإجمالي: ${_money(_dailyTotals['amount'])} ₪'),
        Text('الربح: ${_money(_dailyTotals['profit'])} ₪'),
      ],
    ),
  );

  Widget _dailyCard(Map<String, dynamic> row) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: ShwakelCard(
      padding: const EdgeInsets.all(14),
      child: Wrap(
        spacing: 16,
        runSpacing: 5,
        children: [
          Text('${row['day'] ?? ''}', style: AppTheme.bodyBold),
          Text('${row['employeeName'] ?? ''}'),
          Text('${row['transfers'] ?? 0} حركة'),
          Text('${_money(row['totalAmount'])} ₪'),
          Text('مفتوح: ${row['openTransfers'] ?? 0}'),
        ],
      ),
    ),
  );

  Widget _settlementCard(Map<String, dynamic> row) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: ShwakelCard(
      padding: const EdgeInsets.all(14),
      child: Wrap(
        spacing: 16,
        runSpacing: 5,
        children: [
          Text('${row['employee_name'] ?? ''}', style: AppTheme.bodyBold),
          Text('${row['transfer_count'] ?? 0} حركة'),
          Text('${_money(row['total_amount'])} ₪'),
          Text('أُغلق: ${row['period_end'] ?? ''}'),
          Text('بواسطة: ${row['closed_by_name'] ?? ''}'),
        ],
      ),
    ),
  );
}
