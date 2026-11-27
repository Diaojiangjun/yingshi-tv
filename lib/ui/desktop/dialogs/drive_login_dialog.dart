import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'uc_tv_login_dialog.dart';

/// 登录弹窗的三个分段。
enum DriveAccountTab { qr, manual, status }

/// 该网盘是否提供内置扫码登录。
///
/// 迅雷 / 光鸭的会话是 Token，但官方登录页同样可以扫码；登录成功后从
/// WebView 的 localStorage 读取 access_token（参考 MisaTV 的实现）。
/// 阿里云盘仍只提供「粘贴 Token」。
const _webLoginProviders = <String>{
  'quark',
  'uc',
  'baidu',
  '115',
  'bili',
  'thunder',
  'guangya',
};

bool driveSupportsQrLogin(DriveProvider provider) =>
    _webLoginProviders.contains(provider.id);

/// 内置官方登录页扫码登录：登录成功（或本来就已登录）时直接从 WebView
/// 读出 Cookie 保存到本机。
Future<bool?> showDriveLoginDialog(
  BuildContext context, {
  required DriveProvider provider,
  required DriveAccountRepository repository,
  DriveAccountTab initialTab = DriveAccountTab.qr,
}) {
  return showAppDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => DriveLoginDialog(
      provider: provider,
      repository: repository,
      initialTab: initialTab,
    ),
  );
}

class DriveLoginDialog extends StatefulWidget {
  const DriveLoginDialog({
    super.key,
    required this.provider,
    required this.repository,
    this.initialTab = DriveAccountTab.qr,
  });

  final DriveProvider provider;
  final DriveAccountRepository repository;
  final DriveAccountTab initialTab;

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
  bool _pageLoaded = false;
  String? _webViewError;
  String _status = '正在打开官方登录页…';
  String? _actionMessage;
  late bool _qrAvailable;
  late DriveAccountTab _tab;

  // 光鸭设备码授权（参考 MisaTV）：不依赖 WebView，直接展示官方授权二维码。
  String? _gyDeviceCode;
  String? _gyAuthUrl;
  String? _gyUserCode;
  bool _gyLoading = false;
  String? _gyError;

  DriveProvider get _provider => widget.provider;

  @override
  void initState() {
    super.initState();
    _qrAvailable = driveSupportsQrLogin(_provider);
    _tab = widget.initialTab;
    if (_tab == DriveAccountTab.qr && !_qrAvailable) {
      _tab = DriveAccountTab.manual;
    }
    widget.repository.addListener(_onAccountChanged);
    // 平台实现没注册上时不能构建 InAppWebView（会断言失败、整页红屏），
    // 先确认一次，缺了就退化成「粘贴 Cookie」。
    _webViewReady = ensureDriveWebViewPlatform();
    // 光鸭走设备码授权：不需要 WebView，直接取官方二维码。
    if (_provider.id == 'guangya') {
      if (_tab == DriveAccountTab.qr) unawaited(_startGuangyaDeviceAuth());
      return;
    }
    if (!_webViewReady) {
      _status = '内置浏览器不可用，请改用手动粘贴';
      return;
    }
    if (_tab == DriveAccountTab.qr) _startPolling();
  }

  void _onAccountChanged() {
    if (mounted) setState(() {});
  }

  void _startPolling() {
    if (!_webViewReady || _saving || _done || _tab != DriveAccountTab.qr) {
      return;
    }
    _poller?.cancel();
    // 登录页自己会展示二维码；这里只做轮询，不去注入脚本改版式。
    _poller = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  /// 光鸭设备码授权：向官方账号服务申请 device_code，展示授权二维码并轮询 token。
  Future<void> _startGuangyaDeviceAuth() async {
    if (_gyLoading) return;
    setState(() {
      _gyLoading = true;
      _gyError = null;
      _status = '正在获取光鸭登录二维码…';
    });
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(
        Uri.https('account.guangyapan.com', '/v1/auth/device/code'),
      );
      req.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set(HttpHeaders.refererHeader, 'https://www.guangyapan.com/')
        ..set(HttpHeaders.userAgentHeader, _desktopUserAgent);
      req.write(
        jsonEncode(<String, String>{
          'scope': 'user',
          'client_id': 'aMe-8VSlkrbQXpUR',
        }),
      );
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (!mounted || _done) return;
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final decoded = jsonDecode(body);
        if (decoded is Map) {
          final deviceCode = '${decoded['device_code'] ?? ''}'.trim();
          final userCode = '${decoded['user_code'] ?? ''}'.trim();
          final complete = '${decoded['verification_uri_complete'] ?? ''}'
              .trim();
          final uri = '${decoded['verification_uri'] ?? ''}'.trim();
          final authUrl = complete.isNotEmpty ? complete : uri;
          if (deviceCode.isNotEmpty && authUrl.isNotEmpty) {
            setState(() {
              _gyDeviceCode = deviceCode;
              _gyUserCode = userCode.isEmpty ? null : userCode;
              _gyAuthUrl = authUrl;
              _gyLoading = false;
              _status = userCode.isEmpty
                  ? '请使用光鸭云盘 App 扫码授权'
                  : '请完成光鸭授权（授权码：$userCode）';
            });
            _poller ??= Timer.periodic(
              const Duration(seconds: 2),
              (_) => _poll(),
            );
            return;
          }
        }
      }
      setState(() {
        _gyLoading = false;
        _gyError = '获取光鸭授权码失败（HTTP ${resp.statusCode}）';
        _status = _gyError!;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _gyLoading = false;
        _gyError = '获取光鸭授权码失败：$error';
        _status = _gyError!;
      });
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _pollGuangyaDevice() async {
    final deviceCode = _gyDeviceCode ?? '';
    if (deviceCode.isEmpty || _saving || _done) return;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(
        Uri.https('account.guangyapan.com', '/v1/auth/token'),
      );
      req.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set(HttpHeaders.refererHeader, 'https://www.guangyapan.com/')
        ..set(HttpHeaders.userAgentHeader, _desktopUserAgent);
      req.write(
        jsonEncode(<String, String>{
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'device_code': deviceCode,
          'client_id': 'aMe-8VSlkrbQXpUR',
        }),
      );
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (!mounted || _done) return;
      Map<dynamic, dynamic>? map;
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map) map = decoded;
      } catch (_) {
        // 非 JSON：等下一轮。
      }
      final accessToken = '${map?['access_token'] ?? ''}'.trim();
      if (resp.statusCode >= 200 &&
          resp.statusCode < 300 &&
          accessToken.isNotEmpty) {
        final tokenJson = jsonEncode(<String, String>{
          'token_type': '${map?['token_type'] ?? 'Bearer'}',
          'access_token': accessToken,
          'refresh_token': '${map?['refresh_token'] ?? ''}',
          'sub': '${map?['sub'] ?? ''}',
        });
        await widget.repository.saveRawCredential('guangya', tokenJson);
        if (!mounted) return;
        _done = true;
        _poller?.cancel();
        Navigator.of(context).pop(true);
        return;
      }
      final error = '${map?['error'] ?? ''}'.trim();
      if (error == 'authorization_pending' || error == 'slow_down') return;
      if (error == 'expired_token' || error == 'access_denied') {
        setState(() {
          _gyError = error == 'access_denied'
              ? '授权被拒绝，请重新获取二维码'
              : '二维码已过期，请重新获取';
          _status = _gyError!;
        });
      }
    } catch (_) {
      // 网络抖动：下一轮继续。
    } finally {
      client.close(force: true);
    }
  }

  void _setTab(DriveAccountTab tab) {
    if (_tab == tab) return;
    setState(() => _tab = tab);
    if (tab == DriveAccountTab.qr) {
      if (_provider.id == 'guangya') {
        // 光鸭是设备码二维码：切回扫码页时复用现有码，没有码才重新申请。
        if ((_gyAuthUrl ?? '').isEmpty) {
          unawaited(_startGuangyaDeviceAuth());
        } else {
          _poller ??= Timer.periodic(
            const Duration(seconds: 2),
            (_) => _poll(),
          );
          unawaited(_poll());
        }
      } else {
        _startPolling();
        unawaited(_poll());
      }
    } else {
      _poller?.cancel();
      _poller = null;
    }
  }

  @override
  void dispose() {
    _poller?.cancel();
    widget.repository.removeListener(_onAccountChanged);
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
    // 光鸭设备码：没有 WebView，直接轮询官方 token 接口。
    if (_provider.id == 'guangya' && (_gyDeviceCode ?? '').isNotEmpty) {
      await _pollGuangyaDevice();
      return;
    }
    // WebView 还没创建好时读取 Cookie 会抛异常，直接跳过这一轮。
    if (_controller == null) return;
    // Token 类网盘（迅雷 / 光鸭）优先从 localStorage 读登录接口下发的 access_token。
    if (_provider.usesToken) {
      final token = await _readLocalStorageToken();
      if (!mounted || _done) return;
      if (token != null && token.trim().isNotEmpty) {
        await _finish(token.trim());
        return;
      }
    }
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
    if (_provider.usesToken) {
      // 光鸭 / 阿里这类把 token 直接写进 Cookie 的，取出值本身；
      // 迅雷则保留整串 Cookie（sessionid / userid / loginday）。
      final direct = _tokenValueFromCookie(credential);
      if (direct != null && direct.isNotEmpty) {
        await _finish(direct);
        return;
      }
      final names = driveCookieNames(credential);
      if (_provider.authNames.any(names.contains)) {
        await _finish(credential);
        return;
      }
      if (mounted && _status != '等待扫码登录…') {
        setState(() => _status = '等待扫码登录…');
      }
      return;
    }
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

  /// 从官方登录页的 localStorage 里找 access_token（兼容 `credentials_*` 等键）。
  Future<String?> _readLocalStorageToken() async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      final raw = await controller.evaluateJavascript(source: _tokenScript);
      if (raw is String) {
        final text = raw.trim();
        if (text.isNotEmpty && text != 'null') return text;
      }
    } catch (_) {
      // 页面还没加载完 / 跨域限制：下一轮再试。
    }
    return null;
  }

  String? _tokenValueFromCookie(String cookie) {
    final jar = <String, String>{};
    for (final part in cookie.split(';')) {
      final segment = part.trim();
      final eq = segment.indexOf('=');
      if (eq <= 0) continue;
      jar[segment.substring(0, eq).trim()] = segment.substring(eq + 1).trim();
    }
    for (final key in const <String>[
      'access_token',
      'accessToken',
      'token',
      'refresh_token',
    ]) {
      final value = jar[key] ?? '';
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  static const _tokenScript = r'''
(function() {
  try {
    var fallback = '';
    for (var i = 0; i < localStorage.length; i++) {
      var k = localStorage.key(i);
      if (!k) continue;
      if (k.indexOf('credentials_') === 0 || k === 'token' || k === 'auth_token') {
        var raw = localStorage.getItem(k);
        if (!raw) continue;
        try {
          var o = JSON.parse(raw);
          if (o && typeof o === 'object') {
            var at = o.access_token || o.accessToken || '';
            var rt = o.refresh_token || o.refreshToken || '';
            if (typeof at === 'string' && at.length >= 10) return at;
            if (typeof rt === 'string' && rt.length >= 10) return rt;
          }
        } catch (e) {
          if (!fallback && raw.length >= 20) fallback = raw;
        }
      }
    }
    return fallback || null;
  } catch (e) {
    return null;
  }
})();
''';

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
        _startPolling();
        return;
      }
      _done = true;
      if (mounted) setState(() => _status = '登录成功，正在关闭…');
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

  Future<void> _openUcTvLogin() async {
    final ok = await showUcTvLoginDialog(
      context,
      repository: widget.repository,
    );
    if (!mounted || ok != true) return;
    _done = true;
    _poller?.cancel();
    Navigator.of(context).pop(true);
  }

  Future<void> _openManualCookie() async {
    _poller?.cancel();
    final result = await showDriveCookieDialog(
      context,
      provider: _provider,
      repository: widget.repository,
    );
    if (!mounted) return;
    if (result != null && result.valid != false) {
      _done = true;
      Navigator.of(context).pop(true);
      return;
    }
    if (result != null && result.message.isNotEmpty) {
      setState(() => _status = result.message);
    }
    _startPolling();
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
                '可以在浏览器里登录 ${_provider.name} 网页版，再把'
                '${_provider.usesToken ? 'Token' : 'Cookie'}粘贴进来。',
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
                onPressed: _saving ? null : _openManualCookie,
                icon: const Icon(Icons.content_paste_rounded, size: 16),
                label: Text(_provider.usesToken ? '改用粘贴 Token' : '改用粘贴 Cookie'),
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
    final width = math.min(900.0, math.max(360.0, size.width - 48));
    final height = math.min(720.0, math.max(420.0, size.height - 48));
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
                              _tab == DriveAccountTab.qr
                                  ? _status
                                  : _tab == DriveAccountTab.manual
                                  ? '手动粘贴${_provider.usesToken ? ' Token' : ' Cookie'}'
                                  : '查看本机保存的登录态',
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: _buildTabs(palette),
                ),
                Divider(height: 1, color: palette.divider),
                Expanded(child: _buildBody(palette)),
                Divider(height: 1, color: palette.divider),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.lock_outline_rounded,
                            size: 14,
                            color: palette.textDim,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '凭据只保存在本机（系统加密），不会上传，也不会写入日志。',
                              style: TextStyle(
                                fontSize: AppType.caption,
                                color: palette.textDim,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_provider.note.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          _provider.note,
                          style: TextStyle(
                            fontSize: AppType.caption,
                            color: palette.textSub,
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          alignment: WrapAlignment.end,
                          children: [
                            if (_tab == DriveAccountTab.qr) ...[
                              if (_provider.id == 'guangya')
                                TextButton.icon(
                                  onPressed: _saving
                                      ? null
                                      : _startGuangyaDeviceAuth,
                                  icon: const Icon(
                                    Icons.refresh_rounded,
                                    size: 16,
                                  ),
                                  label: const Text('重新获取二维码'),
                                )
                              else if (_webViewReady) ...[
                                TextButton.icon(
                                  key: const ValueKey('drive-login-check-now'),
                                  onPressed: _saving || _done ? null : _poll,
                                  icon: const Icon(
                                    Icons.search_rounded,
                                    size: 16,
                                  ),
                                  label: const Text('立即检测'),
                                ),
                                TextButton.icon(
                                  onPressed: _saving
                                      ? null
                                      : () => _controller?.reload(),
                                  icon: const Icon(
                                    Icons.refresh_rounded,
                                    size: 16,
                                  ),
                                  label: const Text('刷新页面'),
                                ),
                              ],
                              if (_provider.id == 'uc')
                                TextButton.icon(
                                  key: const ValueKey('drive-login-uc-tv'),
                                  onPressed: _saving ? null : _openUcTvLogin,
                                  icon: const Icon(
                                    Icons.qr_code_2_rounded,
                                    size: 16,
                                  ),
                                  label: const Text('TV 扫码'),
                                ),
                              TextButton.icon(
                                onPressed: _saving ? null : _openManualCookie,
                                icon: const Icon(
                                  Icons.content_paste_rounded,
                                  size: 16,
                                ),
                                label: Text(
                                  _provider.usesToken
                                      ? '改用粘贴 Token'
                                      : '改用粘贴 Cookie',
                                ),
                              ),
                            ] else
                              TextButton(
                                onPressed: _saving
                                    ? null
                                    : () => Navigator.of(context).pop(),
                                child: const Text('关闭'),
                              ),
                          ],
                        ),
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

  Widget _buildTabs(AppPalette palette) {
    final tabs = <(DriveAccountTab, String)>[
      if (_qrAvailable) (DriveAccountTab.qr, '扫码登录'),
      (DriveAccountTab.manual, _provider.usesToken ? '粘贴 Token' : '手动 Cookie'),
      (DriveAccountTab.status, '账号状态'),
    ];
    return Row(
      children: [
        for (var i = 0; i < tabs.length; i++) ...[
          Expanded(
            child: _TabButton(
              key: ValueKey('drive-login-tab-${tabs[i].$1.name}'),
              label: tabs[i].$2,
              selected: _tab == tabs[i].$1,
              palette: palette,
              onTap: _saving ? null : () => _setTab(tabs[i].$1),
            ),
          ),
          if (i != tabs.length - 1) const SizedBox(width: 6),
        ],
      ],
    );
  }

  Widget _buildBody(AppPalette palette) {
    final pages = <Widget>[
      if (_qrAvailable) _buildWebView(palette),
      _buildManualTab(palette),
      _buildStatusTab(palette),
    ];
    final index = switch (_tab) {
      DriveAccountTab.qr => 0,
      DriveAccountTab.manual => _qrAvailable ? 1 : 0,
      DriveAccountTab.status => _qrAvailable ? 2 : 1,
    };
    return IndexedStack(index: index, children: pages);
  }

  Widget _buildManualTab(AppPalette palette) {
    final token = _provider.usesToken;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.content_paste_rounded,
                size: 40,
                color: palette.accentInk,
              ),
              const SizedBox(height: 12),
              Text(
                token
                    ? '粘贴 ${_provider.name} Token'
                    : '粘贴 ${_provider.name} Cookie',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppType.heading,
                  fontWeight: FontWeight.w600,
                  color: palette.textTitle,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                token
                    ? '打开 ${_provider.loginUrl} 登录后，从开发者工具或抓包里复制 Token 粘贴进来。'
                    : '在浏览器登录 ${_provider.cookieHost} 后，按 F12 → 网络（Network）任选一个请求，'
                          '复制请求头里的 Cookie 整串粘贴进来。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: palette.textSub,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('drive-login-manual-open'),
                onPressed: _saving ? null : _openManualCookie,
                icon: const Icon(Icons.content_paste_rounded, size: 17),
                label: Text(token ? '粘贴 Token' : '粘贴 Cookie'),
              ),
              if (_actionMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _actionMessage!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    color: palette.danger,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusTab(AppPalette palette) {
    final account = widget.repository.accountOf(_provider.id);
    final credential = (account?.credential ?? '').trim();
    final hasCredential = credential.isNotEmpty;
    final currentAccount = hasCredential ? account! : null;
    final (statusText, statusColor) = account?.isGuest == true
        ? (
            _provider.optional ? '访客态（可选）' : '访客态',
            _provider.optional ? palette.warning : palette.danger,
          )
        : switch (account?.valid) {
            _ when !hasCredential => ('未登录', palette.textSub),
            true => ('已登录', palette.success),
            false => ('登录态已失效', palette.danger),
            _ => (
              _provider.usesToken ? '已保存 Token' : '已保存（未校验）',
              palette.warning,
            ),
          };
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.verified_user_outlined,
                size: 20,
                color: palette.accentInk,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '本机登录态',
                  style: TextStyle(
                    fontSize: AppType.heading,
                    fontWeight: FontWeight.w600,
                    color: palette.textTitle,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                  border: Border.all(
                    color: statusColor.withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    fontWeight: FontWeight.w600,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (!hasCredential)
            Text(
              '还没有保存登录凭据。可以回到「扫码登录」或「手动 Cookie」完成登录。',
              style: TextStyle(
                fontSize: AppType.caption,
                color: palette.textSub,
                height: 1.5,
              ),
            )
          else ...[
            _statusRow(
              palette,
              '账号',
              currentAccount?.username.trim().isNotEmpty == true
                  ? currentAccount!.username.trim()
                  : '未提供',
            ),
            _statusRow(
              palette,
              '凭据',
              '${_provider.usesToken ? 'Token' : 'Cookie'} 已保存'
                  '（${credential.length} 字符）',
            ),
            _statusRow(palette, '保存时间', _formatTime(currentAccount!.updatedAt)),
            _statusRow(
              palette,
              '上次校验',
              currentAccount.checkedAt > 0
                  ? _formatTime(currentAccount.checkedAt)
                  : '尚未校验',
            ),
          ],
          if (_actionMessage != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: BoxDecoration(
                color: palette.accentWash,
                borderRadius: BorderRadius.circular(AppRadii.sm),
                border: Border.all(
                  color: palette.accentInk.withValues(alpha: 0.30),
                ),
              ),
              child: Text(
                _actionMessage!,
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: palette.accentInk,
                  height: 1.4,
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (hasCredential && !_provider.usesToken)
                OutlinedButton.icon(
                  key: const ValueKey('drive-status-refresh'),
                  onPressed: _saving ? null : _refreshAccount,
                  icon: const Icon(Icons.sync_rounded, size: 16),
                  label: Text(_saving ? '刷新中…' : '刷新会话'),
                ),
              if (hasCredential)
                OutlinedButton.icon(
                  key: const ValueKey('drive-status-revalidate'),
                  onPressed: _saving ? null : _revalidateAccount,
                  icon: const Icon(Icons.verified_outlined, size: 16),
                  label: Text(_saving ? '校验中…' : '重新校验'),
                ),
              if (hasCredential)
                OutlinedButton.icon(
                  key: const ValueKey('drive-status-remove'),
                  onPressed: _saving ? null : _removeAccount,
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 16,
                    color: palette.danger,
                  ),
                  label: Text('清除登录', style: TextStyle(color: palette.danger)),
                ),
              TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusRow(AppPalette palette, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: TextStyle(
                fontSize: AppType.caption,
                color: palette.textDim,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: AppType.caption,
                color: palette.textMain,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _refreshAccount() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _actionMessage = null;
    });
    try {
      final result = await widget.repository.refreshSession(_provider.id);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _actionMessage = result.valid == true
            ? '会话已刷新'
            : (result.message.isEmpty ? '会话刷新失败，请重新登录' : result.message);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _actionMessage = error is FormatException ? error.message : '刷新失败，请重试';
      });
    }
  }

  Future<void> _revalidateAccount() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _actionMessage = null;
    });
    try {
      final result = await widget.repository.revalidate(_provider.id);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _actionMessage = result.message.isEmpty
            ? (result.valid == false ? '登录态已失效' : '校验通过')
            : result.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _actionMessage = error is FormatException ? error.message : '校验失败，请重试';
      });
    }
  }

  Future<void> _removeAccount() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.palette.raised,
        title: Text('清除 ${_provider.name} 登录？'),
        content: const Text('只删除本机保存的登录态，之后可以重新登录。'),
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
      await widget.repository.remove(_provider.id);
      if (!mounted) return;
      setState(() => _actionMessage = '已清除本机登录态');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _actionMessage = error is FormatException ? error.message : '清除失败，请重试';
      });
    }
  }

  String _formatTime(int milliseconds) {
    if (milliseconds <= 0) return '—';
    final local = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _retryPage() async {
    setState(() {
      _webViewError = null;
      _pageLoaded = false;
      _status = '正在重新加载登录页…';
    });
    try {
      await _controller?.reload();
    } catch (_) {
      // 重载失败保留错误条，用户可以再次点击。
    }
  }

  Widget _buildGuangyaDevice(AppPalette palette) {
    if (_gyLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              '正在获取光鸭登录二维码…',
              style: TextStyle(
                fontSize: AppType.caption,
                color: palette.textSub,
              ),
            ),
          ],
        ),
      );
    }
    final authUrl = _gyAuthUrl ?? '';
    if (_gyError != null || authUrl.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 40,
                color: palette.danger,
              ),
              const SizedBox(height: 12),
              Text(
                _gyError ?? '未能获取光鸭登录二维码',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: palette.textSub,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: _startGuangyaDeviceAuth,
                child: const Text('重新获取二维码'),
              ),
            ],
          ),
        ),
      );
    }
    final qrUrl = Uri.https('api.qrserver.com', '/v1/create-qr-code/', {
      'size': '280x280',
      'margin': '12',
      'data': authUrl,
    }).toString();
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppRadii.md),
              ),
              child: Image.network(
                qrUrl,
                width: 220,
                height: 220,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.qr_code_2_rounded, size: 200),
              ),
            ),
            if ((_gyUserCode ?? '').isNotEmpty) ...[
              const SizedBox(height: 16),
              SelectableText(
                '授权码：$_gyUserCode',
                style: TextStyle(
                  fontSize: AppType.heading,
                  fontWeight: FontWeight.w700,
                  color: palette.textTitle,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              '请使用「光鸭云盘 App」扫码确认登录\n'
              '（同一台手机可先截屏，再在光鸭 App 扫一扫 → 相册选择截屏）',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppType.caption,
                height: 1.5,
                color: palette.textSub,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: () => _copyGuangyaAuthUrl(authUrl),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('复制授权链接'),
                ),
                FilledButton.tonal(
                  onPressed: _startGuangyaDeviceAuth,
                  child: const Text('重新获取二维码'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyGuangyaAuthUrl(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) setState(() => _status = '授权链接已复制，可在浏览器中打开');
  }

  Widget _buildWebView(AppPalette palette) {
    if (_provider.id == 'guangya') return _buildGuangyaDevice(palette);
    if (!_webViewReady) return _buildWebViewUnavailable(palette);
    return Stack(
      children: [
        InAppWebView(
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
            if (!mounted) return;
            setState(() {
              _pageLoaded = false;
              _webViewError = null;
              _status = '正在打开官方登录页…';
            });
          },
          onLoadStop: (_, url) {
            if (!mounted) return;
            setState(() {
              _pageLoaded = true;
              _webViewError = null;
              _status = '请在下方网页中扫码登录…';
            });
            // 页面加载完立刻探一次：已登录过的会话可能直接可用。
            unawaited(_poll());
          },
          onReceivedError: (_, request, error) {
            if (!mounted || request.isForMainFrame == false) return;
            setState(() {
              _pageLoaded = true;
              _webViewError = error.description;
              _status = '页面加载失败：${error.description}';
            });
          },
        ),
        if (!_pageLoaded)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                color: palette.background.withValues(alpha: 0.55),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '正在加载登录页…',
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: palette.textSub,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_webViewError != null)
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: _errorBanner(palette),
          ),
      ],
    );
  }

  Widget _errorBanner(AppPalette palette) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: palette.raised,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: palette.danger.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 16, color: palette.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _webViewError!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.caption,
                color: palette.danger,
              ),
            ),
          ),
          TextButton(
            onPressed: _saving ? null : _retryPage,
            child: const Text('重新加载'),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    super.key,
    required this.label,
    required this.selected,
    required this.palette,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final AppPalette palette;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final onAccent = Theme.of(context).colorScheme.onPrimary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.sm),
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppMotion.base,
          curve: AppMotion.ease,
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? palette.accent : palette.card,
            borderRadius: BorderRadius.circular(AppRadii.sm),
            border: Border.all(
              color: selected
                  ? palette.accentInk.withValues(alpha: 0.6)
                  : palette.border,
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppType.caption,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? onAccent : palette.textBody,
            ),
          ),
        ),
      ),
    );
  }
}
