import 'package:flutter/material.dart';

import '../../../core/drive/drive_account_repository.dart';
import '../../../core/drive/drive_line_hint.dart';
import '../../../core/drive/drive_provider.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import 'app_dialog.dart';
import 'drive_cookie_dialog.dart';
import 'drive_login_dialog.dart';
import 'escape_closable.dart';
import '../widgets/app_message.dart';

/// 线路需要网盘凭据时的就地登录提示。
///
/// 返回 true 表示当前已经具备可尝试播放的凭据；false 表示用户选择换线路或登录失败。
/// 可选增强（哔哩哔哩）永远直接放行，不阻断播放。
Future<bool> promptDriveLogin(
  BuildContext context, {
  required DriveAccountRepository repository,
  required DriveLineHint hint,
}) async {
  if (hint.optional) return true;
  if (!hint.supported) {
    await _showUnsupported(context, hint);
    return false;
  }
  final provider = driveProviderById(hint.provider);
  if (provider == null) {
    await _showUnsupported(context, hint);
    return false;
  }

  final account = repository.accountOf(provider.id);
  final credential = (account?.credential ?? '').trim();
  final hasCredential = credential.isNotEmpty;
  if (!repository.needsLogin(provider.id)) return true;
  final guest = account?.isGuest == true;
  final expired = hasCredential && account?.valid == false;

  final action = await showAppDialog<String>(
    context: context,
    builder: (_) => _DrivePromptDialog(
      provider: provider,
      guest: guest,
      expired: expired,
      allowRefresh: hasCredential && !provider.usesToken,
    ),
  );
  if (action == null || !context.mounted) return false;

  switch (action) {
    case 'refresh':
      final result = await repository.refreshSession(provider.id);
      if (result.valid != true) {
        showAppMessage(
          result.message.isEmpty ? '会话刷新失败，请重新登录' : result.message,
          type: AppMessageType.warning,
        );
      }
      return result.valid == true;
    case 'qr':
      final ok = await showDriveLoginDialog(
        context,
        provider: provider,
        repository: repository,
      );
      return ok == true;
    case 'cookie':
      final result = await showDriveCookieDialog(
        context,
        provider: provider,
        repository: repository,
      );
      return result != null && result.valid != false;
  }
  return false;
}

Future<void> _showUnsupported(BuildContext context, DriveLineHint hint) {
  final palette = context.palette;
  return showAppDialog<void>(
    context: context,
    builder: (dialogContext) => EscapeClosable(
      child: AlertDialog(
        backgroundColor: palette.raised,
        title: Text(
          '暂不支持该网盘',
          style: TextStyle(fontSize: AppType.heading, color: palette.textTitle),
        ),
        content: Text(
          '这条线路需要${hint.name}，当前桌面端暂不支持登录该网盘。请换其他可用线路再试。',
          style: TextStyle(
            fontSize: AppType.caption,
            color: palette.textSub,
            height: 1.5,
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    ),
  );
}

class _DrivePromptDialog extends StatelessWidget {
  const _DrivePromptDialog({
    required this.provider,
    required this.guest,
    required this.expired,
    required this.allowRefresh,
  });

  final DriveProvider provider;
  final bool guest;
  final bool expired;
  final bool allowRefresh;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final token = provider.usesToken;
    final title = guest
        ? '${provider.name}处于访客态'
        : expired
        ? '${provider.name}登录已失效'
        : '需要${provider.name}登录';
    final description = guest
        ? '服务端已把当前凭据判为访客态。刷新会话或重新登录后即可继续播放这条线路。'
        : expired
        ? '已保存的登录态已失效。重新登录后即可继续播放这条线路。'
        : '这条线路需要 ${provider.name} 凭据。登录后即可尝试播放，凭据只保存在本机。';
    return EscapeClosable(
      child: AlertDialog(
        backgroundColor: palette.raised,
        title: Row(
          children: [
            Icon(
              guest || expired
                  ? Icons.error_outline_rounded
                  : Icons.cloud_outlined,
              size: 20,
              color: guest || expired ? palette.danger : palette.accentInk,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: AppType.heading,
                  color: palette.textTitle,
                ),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                description,
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: palette.textSub,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                decoration: BoxDecoration(
                  color: palette.accentWash,
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  border: Border.all(
                    color: palette.accentInk.withValues(alpha: 0.30),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 14,
                      color: palette.accentInk,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '凭据由当前 Windows 用户加密保存，不会上传，也不会写入日志。',
                        style: TextStyle(
                          fontSize: AppType.micro,
                          color: palette.accentInk,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('换线路'),
          ),
          if (allowRefresh)
            TextButton(
              onPressed: () => Navigator.of(context).pop('refresh'),
              child: const Text('刷新会话'),
            ),
          if (!token)
            TextButton(
              onPressed: () => Navigator.of(context).pop('cookie'),
              child: const Text('粘贴 Cookie'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(token ? 'cookie' : 'qr'),
            child: Text(
              token
                  ? '粘贴 Token'
                  : guest || expired
                  ? '重新登录'
                  : '扫码登录',
            ),
          ),
        ],
      ),
    );
  }
}
