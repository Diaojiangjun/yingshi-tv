import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/drive/drive_account_repository.dart';
import '../../../core/drive/drive_credential.dart';
import '../../../core/drive/drive_probe.dart';
import '../../../core/drive/drive_provider.dart';
import '../../../core/update/installer_launcher.dart';
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
  final InstallerLauncher _launcher = InstallerLauncher();
  bool _busy = false;
  bool _obscure = true;
  String? _error;
  String? _notice;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  bool get _isToken => widget.provider.usesToken;

  String get _trimmed => _input.text.trim();

  bool _containsName(String name) {
    if (name.isEmpty) return false;
    return RegExp(
      '(^|[;\\s,])${RegExp.escape(name)}\\s*=',
      caseSensitive: true,
    ).hasMatch(_input.text);
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
      _notice = '已从剪贴板粘贴';
      _input.text = text;
      _input.selection = TextSelection.collapsed(offset: text.length);
    });
  }

  Future<void> _openLoginPage() async {
    final ok = await _launcher.openUrl(widget.provider.loginUrl);
    if (!mounted) return;
    setState(() {
      _notice = ok
          ? '已在浏览器打开登录页；登录后复制 Cookie / Token 粘贴回来'
          : '无法打开浏览器，请手动访问 ${widget.provider.loginUrl}';
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
    final media = MediaQuery.sizeOf(context);
    final contentWidth = math.min(620.0, math.max(240.0, media.width - 96));

    final authOk = driveCredentialHasAuth(
      token: asToken,
      authNames: provider.authNames,
      credential: _input.text,
    );
    final missingReady = provider.readyNames
        .where((name) => !_containsName(name))
        .toList();
    final hasInput = _trimmed.isNotEmpty;

    return EscapeClosable(
      autofocus: false,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
            if (!_busy) _save();
          },
        },
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
              width: contentWidth,
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
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          key: const ValueKey('drive-cookie-open-login'),
                          onPressed: _busy ? null : _openLoginPage,
                          icon: const Icon(Icons.open_in_new_rounded, size: 15),
                          label: const Text('打开登录页'),
                        ),
                        TextButton.icon(
                          onPressed: _busy ? null : _paste,
                          icon: const Icon(
                            Icons.content_paste_rounded,
                            size: 15,
                          ),
                          label: const Text('从剪贴板粘贴'),
                        ),
                        if (hasInput)
                          TextButton.icon(
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                    _input.clear();
                                    _error = null;
                                    _notice = null;
                                  }),
                            icon: const Icon(
                              Icons.backspace_outlined,
                              size: 15,
                            ),
                            label: const Text('清空'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('drive-cookie-input'),
                      controller: _input,
                      enabled: !_busy,
                      autofocus: true,
                      obscureText: _obscure,
                      maxLines: _obscure ? 1 : 7,
                      minLines: _obscure ? 1 : 4,
                      enableSuggestions: false,
                      autocorrect: false,
                      onChanged: (_) => setState(() {
                        _error = null;
                        _notice = null;
                      }),
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
                        suffixIcon: Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: IconButton(
                            tooltip: _obscure ? '显示内容' : '隐藏内容',
                            onPressed: _busy
                                ? null
                                : () => setState(() => _obscure = !_obscure),
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildChecklist(palette, authOk, missingReady),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: _Banner(
                          icon: Icons.error_outline_rounded,
                          color: palette.danger,
                          text: _error!,
                          textKey: const ValueKey('drive-cookie-error'),
                        ),
                      ),
                    if (_notice != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: _Banner(
                          icon: Icons.info_outline_rounded,
                          color: palette.accentInk,
                          text: _notice!,
                        ),
                      ),
                    if (provider.note.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          provider.note,
                          style: TextStyle(
                            fontSize: AppType.micro,
                            color: palette.textDim,
                            height: 1.5,
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
              FilledButton(
                key: const ValueKey('drive-cookie-save'),
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 8),
                          Text('校验中…'),
                        ],
                      )
                    : const Text('保存并校验'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChecklist(
    AppPalette palette,
    bool authOk,
    List<String> missingReady,
  ) {
    if (_isToken) {
      if (_trimmed.isNotEmpty) {
        return _fieldChip(
          palette,
          label: '已填写 Token',
          ok: true,
          isRequired: true,
        );
      }
      return Text(
        'Token 只保存在本机，不会显示或上传。',
        style: TextStyle(fontSize: AppType.micro, color: palette.textDim),
      );
    }
    if (_trimmed.isEmpty) {
      return Text(
        '粘贴后会自动检查是否包含登录字段。',
        style: TextStyle(fontSize: AppType.micro, color: palette.textDim),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _fieldChip(
          palette,
          label: authOk ? '已包含登录字段' : '缺少登录字段',
          ok: authOk,
          isRequired: true,
        ),
        for (final name in widget.provider.readyNames)
          _fieldChip(
            palette,
            label: missingReady.contains(name) ? '$name 缺失' : '$name 已包含',
            ok: !missingReady.contains(name),
            isRequired: true,
          ),
      ],
    );
  }

  Widget _fieldChip(
    AppPalette palette, {
    required String label,
    required bool ok,
    required bool isRequired,
  }) {
    final color = ok
        ? palette.success
        : isRequired
        ? palette.warning
        : palette.textDim;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            ok
                ? Icons.check_circle_outline_rounded
                : Icons.help_outline_rounded,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: AppType.micro,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.color,
    required this.text,
    this.textKey,
  });

  final IconData icon;
  final Color color;
  final String text;
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              key: textKey,
              style: TextStyle(
                fontSize: AppType.caption,
                color: color,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
