import 'package:flutter/material.dart';

import '../../../core/drive/drive_account.dart';
import '../../../core/drive/drive_account_repository.dart';
import '../../../core/drive/drive_provider.dart';
import '../dialogs/app_dialog.dart';
import '../dialogs/drive_cookie_dialog.dart';
import '../dialogs/drive_login_dialog.dart';
import '../widgets/app_message.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';

/// 网盘账户卡片：7 家网盘的登录态与操作。
///
/// 自包含（只依赖 [DriveAccountRepository]），设置页与以后的其它入口共用；
/// 布局按宽度自适应：宽屏一行放下全部按钮，窄屏按钮自动换行到第二行。
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
    'bili': Icons.play_circle_fill_rounded,
    'thunder': Icons.bolt_rounded,
    'guangya': Icons.cloud_download_rounded,
  };

  final Set<String> _busy = <String>{};

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
    if (mounted) setState(() {});
  }

  Future<void> _login(DriveProvider provider) async {
    _mark(provider.id, true);
    try {
      final ok = await showDriveLoginDialog(
        context,
        provider: provider,
        repository: widget.repository,
      );
      if (!mounted) return;
      if (ok == true) {
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

  Future<void> _manualCookie(DriveProvider provider) async {
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
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _revalidate(DriveProvider provider) async {
    if (_busy.contains(provider.id)) return;
    _mark(provider.id, true);
    try {
      final result = await widget.repository.revalidate(provider.id);
      if (!mounted) return;
      showAppMessage(
        result.message.isEmpty ? '${provider.name} 校验完成' : result.message,
        type: switch (result.valid) {
          true => AppMessageType.success,
          false => AppMessageType.error,
          null => AppMessageType.warning,
        },
      );
    } catch (error) {
      if (mounted) {
        showAppMessage(
          error is FormatException ? error.message : '${provider.name} 校验失败',
          type: AppMessageType.error,
        );
      }
    } finally {
      _mark(provider.id, false);
    }
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
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.repository.remove(provider.id);
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

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final repository = widget.repository;
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
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
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
                      Text(
                        repository.loading
                            ? '读取中…'
                            : '${repository.loggedInCount} / ${driveProviders.length} 已登录',
                        key: const ValueKey('drive-account-count'),
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: palette.textSub,
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: palette.divider),
              ],
              for (var i = 0; i < driveProviders.length; i++) ...[
                if (i > 0) Divider(height: 1, color: palette.divider),
                _buildRow(palette, driveProviders[i], compact),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildRow(AppPalette palette, DriveProvider provider, bool compact) {
    final account = widget.repository.accountOf(provider.id);
    final hasCredential = (account?.credential ?? '').trim().isNotEmpty;
    final status = _statusOf(palette, provider, account);
    final busy = _busy.contains(provider.id);
    final actions = <Widget>[
      if (hasCredential)
        IconButton(
          tooltip: '重新校验',
          visualDensity: VisualDensity.compact,
          onPressed: busy ? null : () => _revalidate(provider),
          icon: const Icon(Icons.verified_outlined, size: 18),
        ),
      if (driveSupportsQrLogin(provider))
        TextButton(
          key: ValueKey('drive-login-${provider.id}'),
          onPressed: busy ? null : () => _login(provider),
          child: Text(hasCredential ? '更新登录' : '扫码登录'),
        ),
      TextButton(
        key: ValueKey('drive-cookie-${provider.id}'),
        onPressed: busy ? null : () => _manualCookie(provider),
        child: Text(provider.usesToken ? '粘贴 Token' : '手动 Cookie'),
      ),
      if (hasCredential)
        IconButton(
          tooltip: '清除 ${provider.name} 登录',
          visualDensity: VisualDensity.compact,
          onPressed: busy ? null : () => _remove(provider),
          icon: const Icon(Icons.delete_outline_rounded, size: 18),
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
      children: [
        Icon(
          _icons[provider.id] ?? Icons.cloud_rounded,
          size: 20,
          color: hasCredential ? palette.accentInk : palette.textDim,
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
                      child: Text(
                        '可选',
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: palette.textDim,
                        ),
                      ),
                    ),
                ],
              ),
              Text(
                status.text,
                key: ValueKey('drive-status-${provider.id}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: status.color,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    if (actions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: info,
      );
    }
    // 窄屏：按钮整体落到第二行右对齐，状态文字不被挤没。
    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            info,
            Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
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
    return switch (account.valid) {
      true => _DriveStatus('已登录$who', palette.accentInk),
      false => _DriveStatus('登录态已失效，请重新登录', palette.danger),
      null => _DriveStatus(
        provider.usesToken ? '已保存 Token' : '已保存$who（未校验）',
        palette.textSub,
      ),
    };
  }
}

class _DriveStatus {
  const _DriveStatus(this.text, this.color);
  final String text;
  final Color color;
}
