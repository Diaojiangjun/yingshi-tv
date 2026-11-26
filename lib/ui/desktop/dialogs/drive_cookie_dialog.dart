import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/drive/drive_account_repository.dart';
import '../../../core/drive/drive_probe.dart';
import '../../../core/drive/drive_provider.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import 'app_dialog.dart';
import 'escape_closable.dart';

/// 手动粘贴 Cookie / Token。
///
/// 保存前先做一次清洗 + 字段粗筛，再交给 [DriveAccountRepository.save] 做在线校验；
/// 校验失败不会静默丢弃，而是把原因留在弹窗里让用户改。
Future<DriveProbeResult?> showDriveCookieDialog(
  BuildContext context, {
  required DriveProvider provider,
  required DriveAccountRepository repository,
  String? initial,
}) {
  return showAppDialog<DriveProbeResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => DriveCookieDialog(
      provider: provider,
      repository: repository,
      initial: initial ?? repository.credentialOf(provider.id),
    ),
  );
}

class DriveCookieDialog extends StatefulWidget {
  const DriveCookieDialog({
    super.key,
    required this.provider,
    required this.repository,
    this.initial = '',
  });

  final DriveProvider provider;
  final DriveAccountRepository repository;
  final String initial;

  @override
  State<DriveCookieDialog> createState() => _DriveCookieDialogState();
}

class _DriveCookieDialogState extends State<DriveCookieDialog> {
  late final TextEditingController _input = TextEditingController(
    text: widget.initial,
  );
  bool _busy = false;
  String? _error;
  String? _notice;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      setState(() => _error = '剪贴板里没有文本');
      return;
    }
    setState(() {
      _error = null;
      _notice = null;
      _input.text = text;
      _input.selection = TextSelection.collapsed(offset: text.length);
    });
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = await widget.repository.save(
        widget.provider.id,
        _input.text,
      );
      if (!mounted) return;
      if (result.valid == false) {
        setState(() {
          _busy = false;
          _error = result.message.isEmpty ? '登录态校验未通过' : result.message;
        });
        return;
      }
      Navigator.of(context).pop(result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error is FormatException ? error.message : '保存失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final provider = widget.provider;
    final asToken = provider.usesToken;
    final fields = provider.authNames.join(' / ');
    return EscapeClosable(
      child: PopScope(
        canPop: !_busy,
        child: AlertDialog(
          backgroundColor: palette.raised,
          title: Text(
            asToken
                ? '粘贴 ${provider.name} Token'
                : '粘贴 ${provider.name} Cookie',
            style: TextStyle(
              fontSize: AppType.heading,
              color: palette.textTitle,
            ),
          ),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    asToken
                        ? '打开 ${provider.loginUrl} 登录后，从开发者工具或抓包里'
                              '复制 Token 粘贴到这里。'
                        : '在浏览器里登录 ${provider.cookieHost} 后，按 F12 → 网络（Network）'
                              '任选一个请求，复制请求头里的 Cookie 整串粘贴到这里。'
                              '需要包含 ${provider.authNames.take(2).join(' / ')} 等字段。',
                    style: TextStyle(
                      fontSize: AppType.caption,
                      color: palette.textSub,
                      height: 1.55,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('drive-cookie-input'),
                    controller: _input,
                    enabled: !_busy,
                    maxLines: 7,
                    minLines: 4,
                    style: TextStyle(
                      fontSize: AppType.label,
                      color: palette.textMain,
                      height: 1.5,
                    ),
                    decoration: InputDecoration(
                      hintText: asToken
                          ? '例如：refresh_token 的值'
                          : '例如：$fields=…; …',
                      hintStyle: TextStyle(
                        fontSize: AppType.caption,
                        color: palette.textDim,
                      ),
                      filled: true,
                      fillColor: palette.panel,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadii.sm),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: _busy ? null : _paste,
                        icon: const Icon(Icons.content_paste_rounded, size: 16),
                        label: const Text('从剪贴板粘贴'),
                      ),
                      if (provider.note.isNotEmpty)
                        Text(
                          provider.note,
                          style: TextStyle(
                            fontSize: AppType.caption,
                            color: palette.textDim,
                          ),
                        ),
                    ],
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        key: const ValueKey('drive-cookie-error'),
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: palette.danger,
                          height: 1.5,
                        ),
                      ),
                    ),
                  if (_notice != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _notice!,
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: palette.textSub,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _input.clear();
                      _error = null;
                    }),
              child: const Text('清空'),
            ),
            FilledButton(
              key: const ValueKey('drive-cookie-save'),
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存并校验'),
            ),
          ],
        ),
      ),
    );
  }
}
