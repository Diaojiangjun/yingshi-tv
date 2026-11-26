import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/drive/drive_account_repository.dart';
import '../../../core/drive/drive_credential.dart';
import '../../../core/drive/drive_webview_support.dart';
import '../../../core/drive/drive_provider.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import 'app_dialog.dart';
import 'drive_cookie_dialog.dart';
import 'escape_closable.dart';

/// 该网盘是否提供内置扫码登录。
///
/// 迅雷 / 光鸭的会话不是 Cookie，而是登录接口下发的 Token（还要走设备授权），
/// 网页里读不到，只提供「粘贴 Token」。
bool driveSupportsQrLogin(DriveProvider provider) => !provider.usesToken;

/// 内置官方登录页扫码登录：登录成功（或本来就已登录）时直接从 WebView
/// 读出 Cookie 保存到本机。
Future<bool?> showDriveLoginDialog(
  BuildContext context, {
  required DriveProvider provider,
  required DriveAccountRepository repository,
}) {
  return showAppDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        DriveLoginDialog(provider: provider, repository: repository),
  );
}

class DriveLoginDialog extends StatefulWidget {
  const DriveLoginDialog({
    super.key,
    required this.provider,
    required this.repository,
  });

  final DriveProvider provider;
  final DriveAccountRepository repository;

  @override
  State<DriveLoginDialog> createState() => _DriveLoginDialogState();
}

class _DriveLoginDialogState extends State<DriveLoginDialog> {
  static const _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  InAppWebViewController? _controller;
  Timer? _poller;
  bool _saving = false;
  bool _done = false;
  bool _webViewReady = false;
  String _status = '正在打开官方登录页…';

  DriveProvider get _provider => widget.provider;

  @override
  void initState() {
    super.initState();
    // 平台实现没注册上时不能构建 InAppWebView（会断言失败、整页红屏），
    // 先确认一次，缺了就退化成「粘贴 Cookie」。
    _webViewReady = ensureDriveWebViewPlatform();
    if (!_webViewReady) {
      _status = '内置浏览器不可用，请改用粘贴 Cookie';
      return;
    }
    // 登录页自己会展示二维码；这里只做轮询，不去注入脚本改版式。
    _poller = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }

  List<String> get _scopes {
    final scopes = <String>{};
    final origin = Uri.tryParse(_provider.loginUrl)?.origin;
    if (origin != null && origin.isNotEmpty && origin != 'null') {
      scopes.add(origin);
    }
    scopes.addAll(_provider.cookieScopes);
    return scopes.toList();
  }

  Future<void> _poll() async {
    if (!mounted || _saving || _done) return;
    // WebView 还没创建好时读取 Cookie 会抛异常，直接跳过这一轮。
    if (_controller == null) return;
    final Map<String, String> jar;
    try {
      jar = await _readCookies();
    } catch (_) {
      return;
    }
    if (!mounted || _done) return;
    final credential = jar.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
    final ready = driveCredentialIsReady(
      token: _provider.usesToken,
      authNames: _provider.authNames,
      readyNames: _provider.readyNames,
      credential: credential,
    );
    if (!ready) {
      final hint =
          driveCredentialHasAuth(
            token: _provider.usesToken,
            authNames: _provider.authNames,
            credential: credential,
          )
          ? '已检测到登录 Cookie，等待会话字段齐全…'
          : '等待扫码登录…';
      if (mounted && hint != _status) setState(() => _status = hint);
      return;
    }
    await _finish(credential);
  }

  Future<Map<String, String>> _readCookies() async {
    final jar = <String, String>{};
    for (final scope in _scopes) {
      final uri = WebUri(scope);
      final cookies = await CookieManager.instance().getCookies(url: uri);
      for (final cookie in cookies) {
        final name = cookie.name.trim();
        if (name.isEmpty) continue;
        // 同名 Cookie 以先读到的（网盘主域）为准。
        jar.putIfAbsent(name, () => cookie.value);
      }
    }
    return jar;
  }

  Future<void> _finish(String credential) async {
    if (_saving || _done) return;
    _saving = true;
    _poller?.cancel();
    if (mounted) setState(() => _status = '正在保存登录态…');
    try {
      final result = await widget.repository.save(_provider.id, credential);
      if (!mounted) return;
      if (result.valid == false) {
        _saving = false;
        setState(() {
          _status = result.message.isEmpty ? '登录态校验未通过，请重新扫码' : result.message;
        });
        // 会话可能只是过期字段，重新起轮询让用户再扫一次。
        _poller = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
        return;
      }
      _done = true;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      _saving = false;
      setState(
        () => _status = error is FormatException
            ? error.message
            : '保存登录态失败，请改用粘贴 Cookie',
      );
    }
  }

  Future<void> _pasteManually() async {
    _poller?.cancel();
    final result = await showDriveCookieDialog(
      context,
      provider: _provider,
      repository: widget.repository,
    );
    if (!mounted) return;
    if (result != null) {
      _done = true;
      Navigator.of(context).pop(true);
      return;
    }
    _poller = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  /// WebView 平台实现缺失时的降级界面：给出手动粘贴入口，不让整个弹窗崩掉。
  Widget _buildWebViewUnavailable(AppPalette palette) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.public_off_rounded, size: 40, color: palette.textDim),
              const SizedBox(height: 12),
              Text(
                '内置网页登录不可用',
                key: const ValueKey('drive-login-unavailable'),
                style: TextStyle(
                  fontSize: AppType.label,
                  fontWeight: FontWeight.w600,
                  color: palette.textMain,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '本机没能加载 WebView2 组件，扫码页面无法打开。'
                '可以在浏览器里登录 ${_provider.name} 网页版，再把 Cookie 粘贴进来。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppType.caption,
                  height: 1.5,
                  color: palette.textSub,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('drive-login-paste-instead'),
                onPressed: _saving ? null : _pasteManually,
                icon: const Icon(Icons.content_paste_rounded, size: 16),
                label: const Text('改用粘贴 Cookie'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final size = MediaQuery.sizeOf(context);
    final width = size.width < 960 ? size.width - 60 : 900.0;
    final height = size.height < 780 ? size.height - 60 : 720.0;
    return EscapeClosable(
      autofocus: false,
      child: PopScope(
        canPop: !_saving,
        child: Dialog(
          backgroundColor: palette.raised,
          insetPadding: const EdgeInsets.all(24),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.lg),
          ),
          child: SizedBox(
            width: width,
            height: height,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 8, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '登录 ${_provider.name}',
                              style: TextStyle(
                                fontSize: AppType.heading,
                                fontWeight: FontWeight.w600,
                                color: palette.textTitle,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _status,
                              key: const ValueKey('drive-login-status'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: AppType.caption,
                                color: palette.textSub,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: _saving
                            ? null
                            : () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded, size: 20),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: palette.divider),
                Expanded(child: _buildWebView(palette)),
                Divider(height: 1, color: palette.divider),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Row(
                    children: [
                      Text(
                        _provider.note,
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: palette.textDim,
                        ),
                      ),
                      const Spacer(),
                      if (_webViewReady)
                        TextButton.icon(
                          onPressed: _saving
                              ? null
                              : () => _controller?.reload(),
                          icon: const Icon(Icons.refresh_rounded, size: 16),
                          label: const Text('刷新页面'),
                        ),
                      TextButton.icon(
                        onPressed: _saving ? null : _pasteManually,
                        icon: const Icon(Icons.content_paste_rounded, size: 16),
                        label: const Text('改用粘贴 Cookie'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWebView(AppPalette palette) {
    if (!_webViewReady) return _buildWebViewUnavailable(palette);
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_provider.loginUrl)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        supportMultipleWindows: false,
        userAgent: _desktopUserAgent,
        useWideViewPort: true,
        loadWithOverviewMode: true,
        supportZoom: true,
        builtInZoomControls: true,
        transparentBackground: false,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        if (mounted) setState(() => _status = '请在下方网页中扫码登录…');
      },
      onLoadStart: (_, url) {
        if (mounted) setState(() => _status = '正在打开官方登录页…');
      },
      onLoadStop: (_, url) {
        if (!mounted) return;
        setState(() => _status = '请在下方网页中扫码登录…');
        // 页面加载完立刻探一次：已登录过的会话可能直接可用。
        unawaited(_poll());
      },
      onReceivedError: (_, request, error) {
        if (!mounted || request.isForMainFrame == false) return;
        setState(() => _status = '页面加载失败：${error.description}');
      },
    );
  }
}
