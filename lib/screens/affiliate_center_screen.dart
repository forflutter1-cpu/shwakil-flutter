import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/index.dart';
import '../services/secure_storage_config.dart';
import '../utils/app_permissions.dart';
import '../utils/app_theme.dart';
import '../utils/currency_formatter.dart';
import '../utils/user_display_name.dart';
import '../widgets/app_sidebar.dart';
import '../widgets/app_top_actions.dart';
import '../widgets/responsive_scaffold_container.dart';
import '../widgets/shwakel_card.dart';

class AffiliateCenterScreen extends StatefulWidget {
  const AffiliateCenterScreen({super.key});

  @override
  State<AffiliateCenterScreen> createState() => _AffiliateCenterScreenState();
}

class _AffiliateCenterScreenState extends State<AffiliateCenterScreen> {
  static const String _cacheKeyPrefix = 'affiliate_center_cache_';
  static const FlutterSecureStorage _secureStorage = appSecureStorage;
  final ApiService _apiService = ApiService();
  final AuthService _authService = AuthService();

  bool _isLoading = true;
  bool _isAuthorized = true;
  bool _usingOfflineCache = false;
  Map<String, dynamic> _affiliate = const {};

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
    try {
      final currentUser =
          AuthService.peekCurrentUser() ?? await _authService.currentUser();
      final permissions = AppPermissions.fromUser(currentUser);
      if (!permissions.canViewAffiliateCenter) {
        if (!mounted) {
          return;
        }
        setState(() {
          _isAuthorized = false;
          _isLoading = false;
        });
        return;
      }

      if (OfflineSessionService.isOfflineMode ||
          !ConnectivityService.instance.isOnline.value) {
        final cached = await _loadCachedAffiliate(currentUser);
        if (cached != null) {
          if (!mounted) {
            return;
          }
          setState(() {
            _isAuthorized = true;
            _affiliate = cached;
            _usingOfflineCache = true;
            _isLoading = false;
          });
          return;
        }
      }

      final payload = await _apiService.getAffiliateDashboard();
      final affiliate = Map<String, dynamic>.from(
        payload['affiliate'] as Map? ?? const {},
      );
      await _cacheAffiliate(currentUser, affiliate);
      if (!mounted) {
        return;
      }
      setState(() {
        _isAuthorized = true;
        _affiliate = affiliate;
        _usingOfflineCache = false;
        _isLoading = false;
      });
    } catch (error) {
      final currentUser =
          AuthService.peekCurrentUser() ?? await _authService.currentUser();
      final cached = await _loadCachedAffiliate(currentUser);
      if (cached != null && mounted) {
        setState(() {
          _isAuthorized = true;
          _affiliate = cached;
          _usingOfflineCache = true;
          _isLoading = false;
        });
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() => _isLoading = false);
      await AppAlertService.showError(
        context,
        title: context.loc.tr('screens_affiliate_center_screen.001'),
        message: ErrorMessageService.sanitize(error),
      );
    }
  }

  Future<Map<String, dynamic>?> _loadCachedAffiliate(
    Map<String, dynamic>? user,
  ) async {
    final userId = user?['id']?.toString().trim();
    if (userId == null || userId.isEmpty) {
      return null;
    }
    final prefs = await SharedPreferences.getInstance();
    final key = '$_cacheKeyPrefix$userId';
    String? raw;
    try {
      raw = await _secureStorage.read(key: key);
    } catch (_) {
      await prefs.remove(key);
      return null;
    }
    final legacyRaw = prefs.getString(key);
    if ((raw == null || raw.trim().isEmpty) &&
        legacyRaw != null &&
        legacyRaw.trim().isNotEmpty) {
      raw = legacyRaw;
      try {
        await _secureStorage.write(key: key, value: legacyRaw);
        await prefs.remove(key);
      } catch (_) {
        await prefs.remove(key);
        return null;
      }
    }
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  Future<void> _cacheAffiliate(
    Map<String, dynamic>? user,
    Map<String, dynamic> affiliate,
  ) async {
    final userId = user?['id']?.toString().trim();
    if (userId == null || userId.isEmpty || affiliate.isEmpty) {
      return;
    }
    await _secureStorage.write(
      key: '$_cacheKeyPrefix$userId',
      value: jsonEncode(affiliate),
    );
  }

  Future<void> _copyValue(String label, String value) async {
    final l = context.loc;
    if (value.trim().isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) {
      return;
    }
    await AppAlertService.showSuccess(
      context,
      title: l.tr('screens_affiliate_center_screen.002'),
      message: l.tr(
        'screens_affiliate_center_screen.003',
        params: {'label': label},
      ),
    );
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
          title: Text(l.tr('screens_affiliate_center_screen.004')),
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
                  l.tr('screens_affiliate_center_screen.036'),
                  style: AppTheme.h3,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  l.tr('screens_affiliate_center_screen.037'),
                  style: AppTheme.bodyAction,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final enabled = _affiliate['enabled'] == true;
    final summary = Map<String, dynamic>.from(
      _affiliate['summary'] as Map? ?? const {},
    );
    final recentReferrals = List<Map<String, dynamic>>.from(
      (_affiliate['recentReferrals'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );
    final recentCommissions = List<Map<String, dynamic>>.from(
      (_affiliate['recentCommissions'] as List? ?? const []).map(
        (item) => Map<String, dynamic>.from(item as Map),
      ),
    );

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(l.tr('screens_affiliate_center_screen.004')),
        actions: [
          IconButton(
            tooltip: l.tr('screens_affiliate_center_screen.005'),
            onPressed: OfflineSessionService.isOfflineMode ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          if (!OfflineSessionService.isOfflineMode)
            const AppNotificationAction(),
          const QuickLogoutAction(),
        ],
      ),
      drawer: AppSidebar.drawerFor(context),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            ResponsiveScaffoldContainer(
              padding: const EdgeInsets.all(AppTheme.spacingLg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHero(enabled),
                  if (_usingOfflineCache) ...[
                    const SizedBox(height: 12),
                    _buildOfflineCacheNotice(),
                  ],
                  const SizedBox(height: 20),
                  _buildShareCard(),
                  const SizedBox(height: 20),
                  _buildSummaryGrid(summary),
                  const SizedBox(height: 20),
                  _buildSectionTitle(
                    l.tr('screens_affiliate_center_screen.006'),
                    l.tr('screens_affiliate_center_screen.007'),
                  ),
                  const SizedBox(height: 12),
                  if (recentReferrals.isEmpty)
                    _buildEmptyCard(l.tr('screens_affiliate_center_screen.008'))
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: recentReferrals.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 12),
                      itemBuilder: (context, index) =>
                          _buildReferralCard(recentReferrals[index]),
                    ),
                  const SizedBox(height: 20),
                  _buildSectionTitle(
                    l.tr('screens_affiliate_center_screen.009'),
                    l.tr('screens_affiliate_center_screen.010'),
                  ),
                  const SizedBox(height: 12),
                  if (recentCommissions.isEmpty)
                    _buildEmptyCard(l.tr('screens_affiliate_center_screen.011'))
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: recentCommissions.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 12),
                      itemBuilder: (context, index) =>
                          _buildCommissionCard(recentCommissions[index]),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOfflineCacheNotice() {
    return ShwakelCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, color: AppTheme.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'بيانات محفوظة محليًا.',
              style: AppTheme.bodyAction.copyWith(
                color: AppTheme.warning,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHero(bool enabled) {
    final l = context.loc;
    final rewardAmount = (_affiliate['rewardAmount'] as num?)?.toDouble() ?? 0;
    final minAmount =
        (_affiliate['firstTopupMinAmount'] as num?)?.toDouble() ?? 0;

    return ShwakelCard(
      padding: const EdgeInsets.all(24),
      gradient: AppTheme.primaryGradient,
      shadowLevel: ShwakelShadowLevel.premium,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(
                  Icons.campaign_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.tr('screens_affiliate_center_screen.012'),
                      style: AppTheme.h2.copyWith(color: Colors.white),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      enabled
                          ? l.tr('screens_affiliate_center_screen.013')
                          : l.tr('screens_affiliate_center_screen.014'),
                      style: AppTheme.bodyAction.copyWith(
                        color: Colors.white.withValues(alpha: 0.88),
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _heroPill(
                l.tr('screens_affiliate_center_screen.015'),
                CurrencyFormatter.ils(rewardAmount),
              ),
              _heroPill(
                l.tr('screens_affiliate_center_screen.016'),
                CurrencyFormatter.ils(minAmount),
              ),
              _heroPill(
                l.tr('screens_affiliate_center_screen.017'),
                enabled
                    ? l.tr('screens_affiliate_center_screen.018')
                    : l.tr('screens_affiliate_center_screen.019'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildShareCard() {
    final l = context.loc;
    final shareCode = _affiliate['shareCode']?.toString() ?? '';
    final sharePhone = _affiliate['sharePhone']?.toString() ?? '';
    final preferredReferral = shareCode.trim().isNotEmpty
        ? shareCode
        : sharePhone;
    final inviteLink = preferredReferral.trim().isEmpty
        ? ''
        : AppConfig.inviteUri(preferredReferral).toString();
    final isEnglish = Localizations.localeOf(context).languageCode == 'en';
    final inviteLabel = isEnglish ? 'Invite link' : 'رابط الدعوة';

    return ShwakelCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.tr('screens_affiliate_center_screen.020'), style: AppTheme.h3),
          const SizedBox(height: 8),
          Text(
            l.tr('screens_affiliate_center_screen.021'),
            style: AppTheme.caption.copyWith(height: 1.6),
          ),
          const SizedBox(height: 16),
          _shareRow(
            l.tr('screens_affiliate_center_screen.022'),
            shareCode,
            () => _copyValue(
              l.tr('screens_affiliate_center_screen.022'),
              shareCode,
            ),
          ),
          const SizedBox(height: 12),
          _shareRow(
            l.tr('screens_affiliate_center_screen.023'),
            sharePhone,
            () => _copyValue(
              l.tr('screens_affiliate_center_screen.023'),
              sharePhone,
            ),
          ),
          const SizedBox(height: 12),
          _shareActionRow(
            label: inviteLabel,
            hint: l.tr('screens_affiliate_center_screen.038'),
            onCopy: () => _copyValue(inviteLabel, inviteLink),
            enabled: inviteLink.isNotEmpty,
          ),
        ],
      ),
    );
  }

  Widget _shareRow(String label, String value, VoidCallback onCopy) {
    final l = context.loc;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTheme.caption),
                const SizedBox(height: 6),
                Text(
                  value.isEmpty
                      ? l.tr('screens_affiliate_center_screen.024')
                      : value,
                  style: AppTheme.bodyBold,
                ),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: value.isEmpty ? null : onCopy,
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: Text(l.tr('screens_affiliate_center_screen.025')),
          ),
        ],
      ),
    );
  }

  Widget _shareActionRow({
    required String label,
    required String hint,
    required VoidCallback onCopy,
    required bool enabled,
  }) {
    final l = context.loc;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTheme.caption),
                const SizedBox(height: 6),
                Text(
                  hint,
                  style: AppTheme.bodyBold.copyWith(
                    color: enabled
                        ? AppTheme.textPrimary
                        : AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: enabled ? onCopy : null,
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: Text(l.tr('screens_affiliate_center_screen.025')),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryGrid(Map<String, dynamic> summary) {
    final l = context.loc;
    final cards = [
      _summaryCard(
        l.tr('screens_affiliate_center_screen.026'),
        '${(summary['totalReferrals'] as num?)?.toInt() ?? 0}',
        Icons.groups_rounded,
      ),
      _summaryCard(
        l.tr('screens_affiliate_center_screen.027'),
        '${(summary['activeReferrals'] as num?)?.toInt() ?? 0}',
        Icons.local_fire_department_rounded,
      ),
      _summaryCard(
        l.tr('screens_affiliate_center_screen.028'),
        '${(summary['qualifiedReferrals'] as num?)?.toInt() ?? 0}',
        Icons.verified_rounded,
      ),
      _summaryCard(
        l.tr('screens_affiliate_center_screen.029'),
        CurrencyFormatter.ils(
          (summary['totalRewards'] as num?)?.toDouble() ?? 0,
        ),
        Icons.account_balance_wallet_rounded,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 700;
        return GridView.count(
          crossAxisCount: compact ? 2 : 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          mainAxisExtent: compact ? 156 : 150,
          children: cards,
        );
      },
    );
  }

  Widget _summaryCard(String title, String value, IconData icon) {
    return ShwakelCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: AppTheme.primarySoft,
            child: Icon(icon, color: AppTheme.primary),
          ),
          const SizedBox(height: 14),
          Text(value, style: AppTheme.h2),
          const SizedBox(height: 6),
          Flexible(
            child: Text(
              title,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.caption.copyWith(height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppTheme.h3),
        const SizedBox(height: 4),
        Text(subtitle, style: AppTheme.caption.copyWith(height: 1.6)),
      ],
    );
  }

  Widget _buildReferralCard(Map<String, dynamic> item) {
    final l = context.loc;
    final status = item['status']?.toString() ?? 'waiting_for_first_topup';
    final label = switch (status) {
      'rewarded' => l.tr('screens_affiliate_center_screen.030'),
      'waiting_for_qualification' => l.tr(
        'screens_affiliate_center_screen.031',
      ),
      _ => l.tr('screens_affiliate_center_screen.032'),
    };
    final color = switch (status) {
      'rewarded' => AppTheme.success,
      'waiting_for_qualification' => AppTheme.accent,
      _ => AppTheme.textTertiary,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ShwakelCard(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.10),
              child: Icon(Icons.person_add_alt_1_rounded, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    UserDisplayName.fromMap(
                      item,
                      fallback: l.tr('screens_affiliate_center_screen.033'),
                    ),
                    style: AppTheme.bodyBold,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '@${item['username'] ?? 'user'}',
                    style: AppTheme.caption,
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                label,
                style: AppTheme.caption.copyWith(
                  color: color,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCommissionCard(Map<String, dynamic> item) {
    final l = context.loc;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ShwakelCard(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: AppTheme.success.withValues(alpha: 0.10),
              child: const Icon(
                Icons.volunteer_activism_rounded,
                color: AppTheme.success,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item['referredFullName']?.toString().trim().isNotEmpty ==
                            true
                        ? item['referredFullName'].toString()
                        : (item['referredUsername']?.toString() ??
                              l.tr('screens_affiliate_center_screen.034')),
                    style: AppTheme.bodyBold,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l.tr(
                      'screens_affiliate_center_screen.035',
                      params: {
                        'amount': CurrencyFormatter.ils(
                          (item['qualifyingAmount'] as num?)?.toDouble() ?? 0,
                        ),
                      },
                    ),
                    style: AppTheme.caption.copyWith(height: 1.5),
                  ),
                ],
              ),
            ),
            Text(
              CurrencyFormatter.ils(
                (item['commissionAmount'] as num?)?.toDouble() ?? 0,
              ),
              style: AppTheme.bodyBold.copyWith(color: AppTheme.success),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyCard(String text) {
    return ShwakelCard(
      padding: const EdgeInsets.all(22),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: AppTheme.caption.copyWith(height: 1.7),
        ),
      ),
    );
  }

  Widget _heroPill(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label: $value',
        style: AppTheme.caption.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
