import 'package:flutter/material.dart';

import '../../../core/drive/drive_account.dart';
import '../../../core/drive/drive_account_repository.dart';
import '../../../core/drive/drive_provider.dart';
import '../dialogs/app_dialog.dart';
import '../dialogs/drive_cookie_dialog.dart';
import '../dialogs/drive_login_dialog.dart';
import '../dialogs/uc_tv_login_dialog.dart';
import '../widgets/app_message.dart';
import '../widgets/filter_pill.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 账号筛选：全部 / 已登录 / 待处理（登录态失效）。
enum _AccountFilter { all, loggedIn, attention }

class _RowFeedback {
  const _RowFeedback(this.text, {this.isError = false});

  final String text;
  final bool isError;
}

/// 网盘账户卡片：7 家网盘的登录态与操作。
///
/// 自包含（只依赖 [DriveAccountRepository]），设置页与以后的其它入口共用；
/// 布局按宽度自适应：宽屏一行放下状态与操作，窄屏操作落到第二行。
class DriveAccountsPanel extends StatefulWidget {
  const DriveAccountsPanel({
    super.key,
    required this.repository,
    this.showHeader = true,
  });

  final DriveAccountRepository repository;
  final bool showHeader;

  @override
  State<DriveAccountsPanel> createState() => _DriveAccountsPanelState();
}

class _DriveAccountsPanelState extends State<DriveAccountsPanel> {
  static const _icons = <String, IconData>{
    'quark': Icons.cloud_rounded,
    'uc': Icons.cloud_queue_rounded,
    'baidu': Icons.cloud_circle_rounded,
    '115': Icons.folder_shared_rounded,
    'aliyun': Icons.cloud_sync_rounded,
    'bili': Icons.play_circle_fill_rounded,
    'thunder': Icons.bolt_rounded,
    'guangya': Icons.cloud_download_rounded,
  };

  final Set<String> _busy = <String>{};
  final Map<String, _RowFeedback> _rowFeedback = <String, _RowFeedback>{};

  _AccountFilter _filter = _AccountFilter.all;
  bool _showOptional = false;
  bool _checkingAll = false;
  int _checkAllDone = 0;
  int _checkAllTotal = 0;

  @override
  void initState() {
    super.initState();
    widget.repository.addListener(_onChanged);
    widget.repository.ensureLoaded();
  }

  @override
  void dispose() {
    widget.repository.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {
      // 清除已经不再有凭据的行的临时反馈，避免「登录已更新」挂在未登录状态上。
      _rowFeedback.removeWhere((id, _) => !_hasCredentialById(id));
    });
  }

  bool _hasCredential(DriveProvider provider) {
    final credential =
        widget.repository.accountOf(provider.id)?.credential ?? '';
    return credential.trim().isNotEmpty;
  }

  bool _hasCredentialById(String id) {
    final credential = widget.repository.accountOf(id)?.credential ?? '';
    return credential.trim().isNotEmpty;
  }

  bool _needsAttention(DriveProvider provider) {
    final account = widget.repository.accountOf(provider.id);
    return account != null &&
        account.credential.trim().isNotEmpty &&
        account.valid != true;
  }

  bool _matchesFilter(DriveProvider provider) {
    return switch (_filter) {
      _AccountFilter.all => true,
      _AccountFilter.loggedIn => _hasCredential(provider),
      _AccountFilter.attention => _needsAttention(provider),
    };
  }

  int _rank(DriveProvider provider) {
    final account = widget.repository.accountOf(provider.id);
    final hasCredential = (account?.credential ?? '').trim().isNotEmpty;
    if (hasCredential && account?.valid == false) return 0;
    if (hasCredential && account?.valid == true) return 1;
    if (hasCredential) return 2;
    return 3;
  }

  Future<void> _login(DriveProvider provider) async {
    _mark(provider.id, true);
    _clearFeedback(provider.id);
    try {
      final ok = await showDriveLoginDialog(
        context,
        provider: provider,
        repository: widget.repository,
      );
      if (!mounted) return;
      if (ok == true) {
        setState(() {
          _rowFeedback[provider.id] = const _RowFeedback('登录已更新');
        });
        showAppMessage('${provider.name} 登录已更新', type: AppMessageType.success);
      }
    } catch (error) {
      if (mounted) {
        showAppMessage(
          error is FormatException ? error.message : '${provider.name} 登录失败',
          type: AppMessageType.error,
        );
      }
    } finally {
      _mark(provider.id, false);
    }
  }

  Future<void> _ucTvLogin(DriveProvider provider) async {
    _clearFeedback(provider.id);
    try {
      final ok = await showUcTvLoginDialog(
        context,
        repository: widget.repository,
      );
      if (!mounted) return;
      if (ok == true) {
        showAppMessage('UC TV 授权已保存', type: AppMessageType.success);
        setState(() {
          _rowFeedback[provider.id] = const _RowFeedback('UC TV 授权已保存');
        });
      }
    } catch (error) {
      if (mounted) {
        showAppMessage('UC TV 授权失败：$error', type: AppMessageType.error);
      }
    }
  }

  Future<void> _manualCookie(DriveProvider provider) async {
    _clearFeedback(provider.id);
    try {
      final result = await showDriveCookieDialog(
        context,
        provider: provider,
        repository: widget.repository,
      );
      if (!mounted || result == null) return;
      showAppMessage(
        result.valid == false
            ? '${provider.name} 已保存，但校验未通过：${result.message}'
            : '${provider.name} 登录已更新',
        type: result.valid == false
            ? AppMessageType.warning
            : AppMessageType.success,
      );
      if (result.valid == false && result.message.isNotEmpty) {
        setState(() {
          _rowFeedback[provider.id] = _RowFeedback(
            result.message,
            isError: true,
          );
        });
      } else if (result.valid != false) {
        setState(() {
          _rowFeedback[provider.id] = const _RowFeedback('登录已更新');
        });
      }
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _revalidate(DriveProvider provider) async {
    if (_busy.contains(provider.id)) return;
    _mark(provider.id, true);
    _clearFeedback(provider.id);
    try {
      final result = await widget.repository.revalidate(provider.id);
      if (!mounted) return;
      setState(() {
        _rowFeedback[provider.id] = _RowFeedback(
          result.message.isEmpty
              ? (result.valid == false ? '登录态已失效' : '校验通过')
              : result.message,
          isError: result.valid == false,
        );
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _rowFeedback[provider.id] = _RowFeedback(
            error is FormatException ? error.message : '${provider.name} 校验失败',
            isError: true,
          );
        });
      }
    } finally {
      _mark(provider.id, false);
    }
  }

  Future<void> _refreshSession(DriveProvider provider) async {
    if (_busy.contains(provider.id)) return;
    _mark(provider.id, true);
    _clearFeedback(provider.id);
    try {
      final result = await widget.repository.refreshSession(provider.id);
      if (!mounted) return;
      setState(() {
        _rowFeedback[provider.id] = _RowFeedback(
          result.valid == true
              ? '会话已刷新'
              : (result.message.isEmpty ? '会话刷新失败，请重新登录' : result.message),
          isError: result.valid != true,
        );
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _rowFeedback[provider.id] = _RowFeedback(
            error is FormatException ? error.message : '${provider.name} 刷新失败',
            isError: true,
          );
        });
      }
    } finally {
      _mark(provider.id, false);
    }
  }

  Future<void> _checkAll() async {
    if (_checkingAll) return;
    final targets = driveProviders.where(_hasCredential).toList();
    if (targets.isEmpty) {
      showAppMessage('还没有已保存的登录态', type: AppMessageType.warning);
      return;
    }
    setState(() {
      _checkingAll = true;
      _checkAllDone = 0;
      _checkAllTotal = targets.length;
    });
    var ok = 0;
    var expired = 0;
    var unknown = 0;
    for (final provider in targets) {
      if (!mounted) return;
      _mark(provider.id, true);
      _clearFeedback(provider.id);
      try {
        final result = await widget.repository.revalidate(provider.id);
        if (!mounted) return;
        setState(() {
          _rowFeedback[provider.id] = _RowFeedback(
            result.message.isEmpty
                ? (result.valid == false ? '登录态已失效' : '校验通过')
                : result.message,
            isError: result.valid == false,
          );
        });
        switch (result.valid) {
          case true:
            ok++;
            break;
          case false:
            expired++;
            break;
          case null:
            unknown++;
            break;
        }
      } catch (error) {
        if (mounted) {
          setState(() {
            _rowFeedback[provider.id] = _RowFeedback(
              error is FormatException
                  ? error.message
                  : '${provider.name} 校验失败',
              isError: true,
            );
          });
        }
        expired++;
      } finally {
        _mark(provider.id, false);
        if (mounted) setState(() => _checkAllDone++);
      }
    }
    if (!mounted) return;
    setState(() => _checkingAll = false);
    final details = <String>[
      '$ok 个正常',
      if (expired > 0) '$expired 个已失效',
      if (unknown > 0) '$unknown 个未确认',
    ].join('，');
    showAppMessage(
      '检测完成：$details',
      type: expired > 0 ? AppMessageType.warning : AppMessageType.success,
    );
  }

  Future<void> _remove(DriveProvider provider) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('清除 ${provider.name} 登录？'),
        content: const Text('只删除本机保存的登录态，之后需要重新登录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.palette.danger,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.repository.remove(provider.id);
      _clearFeedback(provider.id);
      if (mounted) showAppMessage('已清除 ${provider.name} 登录');
    } catch (error) {
      if (mounted) {
        showAppMessage(
          error is FormatException ? error.message : '清除失败，请重试',
          type: AppMessageType.error,
        );
      }
    }
  }

  void _mark(String id, bool busy) {
    if (!mounted) return;
    setState(() {
      if (busy) {
        _busy.add(id);
      } else {
        _busy.remove(id);
      }
    });
  }

  void _clearFeedback(String id) {
    if (!mounted || !_rowFeedback.containsKey(id)) return;
    setState(() => _rowFeedback.remove(id));
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final repository = widget.repository;
    final loggedIn = repository.loggedInCount;
    final expired = driveProviders.where(_needsAttention).length;
    final lastActivity = _lastActivity();

    final regular = driveProviders
        .where((provider) => !provider.optional)
        .toList();
    final optional = driveProviders
        .where((provider) => provider.optional)
        .toList();
    final visibleRegular = _sorted(regular.where(_matchesFilter));
    final visibleOptional = _sorted(optional.where(_matchesFilter));
    final showOptionalRows =
        visibleOptional.isNotEmpty &&
        (_showOptional || _filter != _AccountFilter.all);

    return Container(
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: palette.border),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 设置页最窄时约 480（收起侧栏 + 小窗口），低于 600 换成两行布局。
          final compact = constraints.maxWidth < 600;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.showHeader) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: Row(
                    children: [
                      Icon(
                        Icons.cloud_sync_rounded,
                        size: 18,
                        color: palette.accentInk,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '网盘账户',
                        style: TextStyle(
                          fontSize: AppType.label,
                          fontWeight: FontWeight.w600,
                          color: palette.textTitle,
                        ),
                      ),
                      const Spacer(),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            repository.loading
                                ? '读取中…'
                                : '$loggedIn / ${driveProviders.length} 已登录',
                            key: const ValueKey('drive-account-count'),
                            style: TextStyle(
                              fontSize: AppType.caption,
                              color: palette.textSub,
                            ),
                          ),
                          if (!repository.loading && lastActivity.at > 0) ...[
                            const SizedBox(height: 1),
                            Text(
                              '${lastActivity.checked ? '上次校验' : '最近登录'} '
                              '${_relativeTime(lastActivity.at)}',
                              style: TextStyle(
                                fontSize: AppType.micro,
                                color: palette.textDim,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilterPill(
                        label: '全部',
                        count: driveProviders.length,
                        isSelected: _filter == _AccountFilter.all,
                        onTap: () =>
                            setState(() => _filter = _AccountFilter.all),
                      ),
                      FilterPill(
                        label: '已登录',
                        count: loggedIn,
                        isSelected: _filter == _AccountFilter.loggedIn,
                        onTap: () =>
                            setState(() => _filter = _AccountFilter.loggedIn),
                      ),
                      FilterPill(
                        label: '待处理',
                        count: expired,
                        isSelected: _filter == _AccountFilter.attention,
                        onTap: () =>
                            setState(() => _filter = _AccountFilter.attention),
                      ),
                      TextButton.icon(
                        key: const ValueKey('drive-check-all'),
                        onPressed: _checkingAll || loggedIn == 0
                            ? null
                            : _checkAll,
                        icon: _checkingAll
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.fact_check_outlined, size: 16),
                        label: Text(
                          _checkingAll
                              ? '检测中 $_checkAllDone/$_checkAllTotal'
                              : '一键检测',
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: palette.divider),
              ],
              if (visibleRegular.isEmpty && !showOptionalRows)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
                  child: Text(
                    _filter == _AccountFilter.loggedIn
                        ? '还没有已登录的网盘'
                        : '当前没有需要处理的网盘',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: AppType.caption,
                      color: palette.textSub,
                    ),
                  ),
                ),
              for (var i = 0; i < visibleRegular.length; i++) ...[
                if (i > 0) Divider(height: 1, color: palette.divider),
                _buildRow(palette, visibleRegular[i], compact),
              ],
              if (optional.isNotEmpty && _filter == _AccountFilter.all) ...[
                if (visibleRegular.isNotEmpty)
                  Divider(height: 1, color: palette.divider),
                _buildOptionalToggle(palette, optional.length),
              ],
              if (showOptionalRows) ...[
                if (visibleRegular.isNotEmpty || _filter == _AccountFilter.all)
                  Divider(height: 1, color: palette.divider),
                for (var i = 0; i < visibleOptional.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: palette.divider),
                  _buildRow(palette, visibleOptional[i], compact),
                ],
              ],
            ],
          );
        },
      ),
    );
  }

  List<DriveProvider> _sorted(Iterable<DriveProvider> providers) {
    final list = providers.toList();
    list.sort((a, b) {
      final byRank = _rank(a).compareTo(_rank(b));
      if (byRank != 0) return byRank;
      return driveProviders.indexOf(a).compareTo(driveProviders.indexOf(b));
    });
    return list;
  }

  Widget _buildOptionalToggle(AppPalette palette, int count) {
    return InkWell(
      key: const ValueKey('drive-optional-toggle'),
      onTap: () => setState(() => _showOptional = !_showOptional),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          children: [
            Icon(Icons.auto_awesome_rounded, size: 16, color: palette.textDim),
            const SizedBox(width: 8),
            Text(
              '可选增强（$count）',
              style: TextStyle(
                fontSize: AppType.caption,
                color: palette.textSub,
              ),
            ),
            const Spacer(),
            Icon(
              _showOptional
                  ? Icons.expand_less_rounded
                  : Icons.expand_more_rounded,
              size: 18,
              color: palette.textDim,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(AppPalette palette, DriveProvider provider, bool compact) {
    final account = widget.repository.accountOf(provider.id);
    final hasCredential = (account?.credential ?? '').trim().isNotEmpty;
    final status = _statusOf(palette, provider, account);
    final busy = _busy.contains(provider.id);
    final feedback = _rowFeedback[provider.id];
    final timeLabel = _timeLabel(account);

    final actions = <Widget>[
      if (!driveSupportsQrLogin(provider))
        TextButton(
          key: ValueKey('drive-cookie-${provider.id}'),
          onPressed: busy ? null : () => _manualCookie(provider),
          child: const Text('粘贴 Token'),
        )
      else ...[
        TextButton(
          key: ValueKey('drive-login-${provider.id}'),
          onPressed: busy ? null : () => _login(provider),
          child: Text(hasCredential ? '更新登录' : '扫码登录'),
        ),
        if (provider.id == 'uc')
          TextButton(
            key: const ValueKey('drive-uc-tv-login'),
            onPressed: busy ? null : () => _ucTvLogin(provider),
            child: const Text('TV 扫码'),
          ),
        IconButton(
          key: ValueKey('drive-cookie-${provider.id}'),
          tooltip: provider.usesToken ? '手动粘贴 Token' : '手动 Cookie',
          visualDensity: VisualDensity.compact,
          onPressed: busy ? null : () => _manualCookie(provider),
          icon: const Icon(Icons.content_paste_rounded, size: 17),
        ),
      ],
      if (hasCredential)
        PopupMenuButton<String>(
          tooltip: '更多操作',
          enabled: !busy,
          onSelected: (action) {
            switch (action) {
              case 'refresh':
                _refreshSession(provider);
                break;
              case 'check':
                _revalidate(provider);
                break;
              case 'remove':
                _remove(provider);
                break;
            }
          },
          itemBuilder: (_) => [
            if (!provider.usesToken)
              PopupMenuItem(
                value: 'refresh',
                key: ValueKey('drive-refresh-${provider.id}'),
                child: const Row(
                  children: [
                    Icon(Icons.sync_rounded, size: 18),
                    SizedBox(width: 10),
                    Text('刷新会话'),
                  ],
                ),
              ),
            PopupMenuItem(
              value: 'check',
              key: ValueKey('drive-revalidate-${provider.id}'),
              child: const Row(
                children: [
                  Icon(Icons.verified_outlined, size: 18),
                  SizedBox(width: 10),
                  Text('重新校验'),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'remove',
              key: ValueKey('drive-remove-${provider.id}'),
              child: Row(
                children: [
                  Icon(
                    Icons.delete_outline_rounded,
                    size: 18,
                    color: palette.danger,
                  ),
                  const SizedBox(width: 10),
                  Text('清除登录', style: TextStyle(color: palette.danger)),
                ],
              ),
            ),
          ],
        ),
      if (busy)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
    ];

    final info = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 34,
          height: 34,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: hasCredential ? palette.accentWash : palette.raised,
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                ),
                child: Icon(
                  _icons[provider.id] ?? Icons.cloud_rounded,
                  size: 19,
                  color: hasCredential ? palette.accentInk : palette.textDim,
                ),
              ),
              Positioned(
                right: -1,
                bottom: -1,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: status.color,
                    shape: BoxShape.circle,
                    border: Border.all(color: palette.card, width: 2),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      provider.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.label,
                        fontWeight: FontWeight.w600,
                        color: palette.textMain,
                      ),
                    ),
                  ),
                  if (provider.optional)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: palette.raised,
                          borderRadius: BorderRadius.circular(AppRadii.pill),
                          border: Border.all(color: palette.border),
                        ),
                        child: Text(
                          '可选',
                          style: TextStyle(
                            fontSize: AppType.micro,
                            color: palette.textDim,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: status.color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(AppRadii.pill),
                        border: Border.all(
                          color: status.color.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Text(
                        status.text,
                        key: ValueKey('drive-status-${provider.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.caption,
                          fontWeight: FontWeight.w600,
                          color: status.color,
                        ),
                      ),
                    ),
                  ),
                  if (timeLabel != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      timeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.micro,
                        color: palette.textDim,
                      ),
                    ),
                  ],
                ],
              ),
              if (feedback != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        feedback.isError
                            ? Icons.error_outline_rounded
                            : Icons.check_circle_outline_rounded,
                        size: 13,
                        color: feedback.isError
                            ? palette.danger
                            : palette.success,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          feedback.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppType.micro,
                            color: feedback.isError
                                ? palette.danger
                                : palette.success,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
    if (actions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: info,
      );
    }
    // 窄屏：操作整体落到第二行右对齐，状态文字不被挤没。
    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            info,
            const SizedBox(height: 2),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      child: Row(
        children: [
          Expanded(child: info),
          Row(mainAxisSize: MainAxisSize.min, children: actions),
        ],
      ),
    );
  }

  _DriveStatus _statusOf(
    AppPalette palette,
    DriveProvider provider,
    DriveAccount? account,
  ) {
    if (account == null || account.credential.trim().isEmpty) {
      return _DriveStatus(
        provider.optional ? '未配置（不登录也能播基础画质）' : '未登录',
        palette.textSub,
      );
    }
    final who = account.username.isEmpty ? '' : ' · ${account.username}';
    if (account.isGuest) {
      return _DriveStatus(
        provider.optional ? '访客态（不登录仍可播低画质）' : '访客态，请重新登录',
        provider.optional ? palette.warning : palette.danger,
      );
    }
    return switch (account.valid) {
      true => _DriveStatus('已登录$who', palette.success),
      false => _DriveStatus('登录态已失效，请重新登录', palette.danger),
      null => _DriveStatus(
        provider.usesToken ? '已保存 Token' : '已保存$who（未校验）',
        palette.warning,
      ),
    };
  }

  ({int at, bool checked}) _lastActivity() {
    var latest = 0;
    var checked = false;
    for (final provider in driveProviders) {
      final account = widget.repository.accountOf(provider.id);
      if (account == null) continue;
      final checkedAt = account.checkedAt;
      if (checkedAt > latest) {
        latest = checkedAt;
        checked = true;
      }
      if (account.updatedAt > latest) {
        latest = account.updatedAt;
        checked = false;
      }
    }
    return (at: latest, checked: checked);
  }

  String? _timeLabel(DriveAccount? account) {
    if (account == null) return null;
    if (account.checkedAt > 0) {
      return '${_relativeTime(account.checkedAt)}校验';
    }
    if (account.updatedAt > 0) {
      return '保存于 ${_relativeTime(account.updatedAt)}';
    }
    return null;
  }

  String _relativeTime(int milliseconds) {
    if (milliseconds <= 0) return '';
    final time = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    final delta = DateTime.now().difference(time);
    if (delta.inMinutes < 1) return '刚刚';
    if (delta.inHours < 1) return '${delta.inMinutes} 分钟前';
    if (delta.inDays < 1) return '${delta.inHours} 小时前';
    if (delta.inDays < 30) return '${delta.inDays} 天前';
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    return '${time.year}-$month-$day';
  }
}

class _DriveStatus {
  const _DriveStatus(this.text, this.color);
  final String text;
  final Color color;
}
