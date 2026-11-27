import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'drive_credential.dart';
import 'drive_provider.dart';

/// 一次在线校验的结论。
class DriveProbeResult {
  const DriveProbeResult({
    required this.provider,
    required this.valid,
    this.username = '',
    this.credential = '',
    this.message = '',
  });

  final String provider;

  /// true = 确认登录态；false = 确认未登录 / 会话过期；null = 网络异常无法判断。
  final bool? valid;

  /// 校验接口给出的显示名（部分网盘只有数字 uid）。
  final String username;

  /// 可能被服务端刷新的凭据（已合并 `Set-Cookie`）；调用方应覆盖保存。
  final String credential;

  /// 给人看的一句话说明。
  final String message;
}

/// 网盘登录态校验：只发只读的账号信息请求，不碰文件列表与转存。
///
/// 全部用 `dart:io` 的 HttpClient（不经过全局 Dio 拦截器），
/// 凭据只出现在请求头里，不写日志。
class DriveProbe {
  DriveProbe({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;

  static const _browserUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  /// 夸克的接口只认桌面客户端身份（见 MisaTV 的踩坑记录：浏览器 UA 会 401 / 23018）。
  static const _quarkUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 '
      'Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch';

  Future<DriveProbeResult> check(
    DriveProvider provider,
    String credential,
  ) async {
    final value = credential.trim();
    if (value.isEmpty) {
      return DriveProbeResult(
        provider: provider.id,
        valid: false,
        message: provider.usesToken ? 'Token 为空' : 'Cookie 为空',
      );
    }
    if (provider.usesToken && provider.id != 'aliyun') {
      return DriveProbeResult(
        provider: provider.id,
        valid: null,
        credential: value,
        message: 'Token 已保存，播放时由解析层校验',
      );
    }
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      return switch (provider.id) {
        'quark' => await _checkQuark(client, value),
        'uc' => await _checkUc(client, value),
        'baidu' => await _checkBaidu(client, value),
        '115' => await _check115(client, value),
        'bili' => await _checkBili(client, value),
        'aliyun' => await _checkAliyun(client, value),
        _ => DriveProbeResult(
          provider: provider.id,
          valid: null,
          credential: value,
          message: '该网盘暂不支持在线校验',
        ),
      };
    } finally {
      client.close(force: true);
    }
  }

  /// 阿里云盘：refresh_token 换 access_token 成功即视为登录有效。
  ///
  /// 不把「取不到昵称」当失败：账号信息接口偶发风控，只要 token 能换到
  /// access_token，分享解链就能用；只有明确的 401/403 才判失效。
  Future<DriveProbeResult> _checkAliyun(
    HttpClient client,
    String credential,
  ) async {
    var refreshToken = credential;
    var accessToken = '';
    if (credential.startsWith('{') && credential.endsWith('}')) {
      try {
        final decoded = jsonDecode(credential);
        if (decoded is Map) {
          refreshToken = (decoded['refresh_token'] ?? '').toString().trim();
          accessToken = (decoded['access_token'] ?? '').toString().trim();
        }
      } catch (_) {
        // 保留原样，按 refresh_token 尝试。
      }
    }
    var refreshed = false;
    if (refreshToken.isNotEmpty) {
      try {
        final res = await _request(
          client,
          'https://auth.alipan.com/v2/account/token',
          method: 'POST',
          headers: <String, String>{
            HttpHeaders.userAgentHeader: _browserUa,
            HttpHeaders.contentTypeHeader: 'application/json',
            HttpHeaders.acceptHeader: 'application/json',
          },
          body: jsonEncode(<String, Object?>{
            'refresh_token': refreshToken,
            'grant_type': 'refresh_token',
          }),
        );
        final token = '${res.json['access_token'] ?? ''}'.trim();
        if (token.isNotEmpty) {
          accessToken = token;
          refreshed = true;
        }
      } catch (_) {
        // 网络异常：交给下面的账号信息请求再判一次。
      }
    }
    if (accessToken.isEmpty) accessToken = credential;

    final res = await _request(
      client,
      'https://api.alipan.com/adrive/v1/user/get',
      headers: <String, String>{
        HttpHeaders.userAgentHeader: _browserUa,
        HttpHeaders.acceptHeader: 'application/json',
        'Authorization': 'Bearer $accessToken',
        'X-Canary': 'client=web,app=share,version=v2.3.1',
      },
    );
    final data = res.json['data'];
    final name = data is Map
        ? (data['name'] ??
                  data['nick_name'] ??
                  data['nickName'] ??
                  data['user_name'] ??
                  '')
              .toString()
              .trim()
        : '';
    final valid = refreshed || (res.status == 200 && data is Map);
    final expired = res.status == 401 || res.status == 403;
    return DriveProbeResult(
      provider: 'aliyun',
      valid: valid ? true : (expired ? false : null),
      username: valid ? name : '',
      credential: credential,
      message: valid
          ? '登录有效'
          : expired
          ? 'Token 无效或已过期'
          : '校验接口返回异常（HTTP ${res.status}）',
    );
  }

  Future<DriveProbeResult> _checkQuark(HttpClient client, String cookie) async {
    final base = sanitizeDriveCookie(cookie);
    final response = await _get(
      client,
      'https://drive-pc.quark.cn/1/clouddrive/member'
      '?pr=ucpro&fr=pc&uc_param_str=&fetch_subscribe=true&_ch=home'
      '&fetch_identity=true',
      headers: <String, String>{
        HttpHeaders.userAgentHeader: _quarkUa,
        HttpHeaders.refererHeader: 'https://pan.quark.cn/',
        'Origin': 'https://pan.quark.cn',
        HttpHeaders.acceptHeader: 'application/json, text/plain, */*',
      },
      cookie: base,
    );
    final merged = mergeDriveSetCookies(base, response.setCookies);
    final code = response.json['code'];
    final valid = response.status == 200 && code == 0;
    final guest = response.status == 401 || code == 31001;
    final data = response.json['data'];
    final nickname = data is Map
        ? (data['nickname'] ?? data['nick_name'] ?? data['user_name'] ?? '')
              .toString()
              .trim()
        : '';
    return DriveProbeResult(
      provider: 'quark',
      valid: valid ? true : (guest ? false : null),
      username: nickname,
      credential: merged,
      message: valid
          ? '登录有效'
          : guest
          ? 'Cookie 已失效，请重新登录'
          : '校验接口返回异常（HTTP ${response.status}）',
    );
  }

  Future<DriveProbeResult> _checkUc(HttpClient client, String cookie) async {
    final base = sanitizeDriveCookie(cookie);
    final response = await _get(
      client,
      'https://pc-api.uc.cn/1/clouddrive/member'
      '?entry=ft&fr=pc&pr=UCBrowser&fetch_subscribe=true&_ch=home',
      headers: <String, String>{
        HttpHeaders.userAgentHeader: _browserUa,
        HttpHeaders.refererHeader: 'https://drive.uc.cn/',
        'Origin': 'https://drive.uc.cn',
        HttpHeaders.acceptHeader: 'application/json, text/plain, */*',
      },
      cookie: base,
    );
    final merged = mergeDriveSetCookies(base, response.setCookies);
    final code = response.json['code'];
    final guest = response.status == 401 || code == 31001;
    if (response.status == 200 && code == 0) {
      final nickname = await _ucNickname(client, merged);
      return DriveProbeResult(
        provider: 'uc',
        valid: true,
        username: nickname,
        credential: merged,
        message: '登录有效',
      );
    }
    // 响应形态异常时用账号信息接口复核一次，避免把限流当成登出。
    if (!guest) {
      final nickname = await _ucNickname(client, merged);
      if (nickname.isNotEmpty) {
        return DriveProbeResult(
          provider: 'uc',
          valid: true,
          username: nickname,
          credential: merged,
          message: '登录有效',
        );
      }
    }
    return DriveProbeResult(
      provider: 'uc',
      valid: guest ? false : null,
      credential: merged,
      message: guest ? 'UC 会话已失效，请重新登录' : '校验接口返回异常（HTTP ${response.status}）',
    );
  }

  Future<String> _ucNickname(HttpClient client, String cookie) async {
    try {
      final response = await _request(
        client,
        'https://fast.uc.cn/api/info?fr=pc&pr=UCBrowser',
        method: 'POST',
        headers: <String, String>{
          HttpHeaders.userAgentHeader: _browserUa,
          HttpHeaders.refererHeader: 'https://drive.uc.cn/',
          HttpHeaders.contentTypeHeader: 'application/json',
          'x-biz-retry': '0',
        },
        cookie: cookie,
        body: jsonEncode(<String, String>{'st': ''}),
      );
      if (response.json['success'] != true) return '';
      final data = response.json['data'];
      return data is Map ? (data['nickname'] ?? '').toString().trim() : '';
    } catch (_) {
      return '';
    }
  }

  Future<DriveProbeResult> _checkBaidu(HttpClient client, String cookie) async {
    final base = sanitizeDriveCookie(cookie);
    final response = await _get(
      client,
      'https://pan.baidu.com/api/gettemplatevariable'
      '?fields=%5B%22bdstoken%22%2C%22uk%22%5D&channel=chunlei&web=1'
      '&app_id=250528&clienttype=0',
      headers: <String, String>{
        HttpHeaders.userAgentHeader: _browserUa,
        HttpHeaders.refererHeader: 'https://pan.baidu.com/',
        HttpHeaders.acceptHeader: 'application/json, text/plain, */*',
      },
      cookie: base,
    );
    final merged = mergeDriveSetCookies(base, response.setCookies);
    final errno = (response.json['errno'] as num?)?.toInt();
    final valid = response.status == 200 && errno == 0;
    // -6 = 未登录 / 会话失效；其它负值是接口临时错误，不能误判成游客态。
    final guest = errno == -6;
    var username = '';
    if (valid) {
      username = await _baiduName(client, merged);
    }
    return DriveProbeResult(
      provider: 'baidu',
      valid: valid ? true : (guest ? false : null),
      username: username,
      credential: merged,
      message: valid
          ? '登录有效'
          : guest
          ? 'BDUSS 已失效，或缺少 STOKEN（半个会话），请重新登录'
          : '校验接口返回异常（errno=${errno ?? '-'}）',
    );
  }

  Future<String> _baiduName(HttpClient client, String cookie) async {
    try {
      final response = await _get(
        client,
        'https://pan.baidu.com/rest/2.0/xpan/nas?method=uinfo',
        headers: <String, String>{
          HttpHeaders.userAgentHeader: _browserUa,
          HttpHeaders.refererHeader: 'https://pan.baidu.com/',
          HttpHeaders.acceptHeader: 'application/json, text/plain, */*',
        },
        cookie: cookie,
      );
      if ((response.json['errno'] as num?)?.toInt() != 0) return '';
      for (final key in const <String>['baidu_name', 'netdisk_name', 'uk']) {
        final value = (response.json[key] ?? '').toString().trim();
        if (value.isNotEmpty) return value;
      }
    } catch (_) {
      // 昵称只是锦上添花，失败不影响登录态结论。
    }
    return '';
  }

  Future<DriveProbeResult> _check115(HttpClient client, String cookie) async {
    final base = sanitizeDriveCookie(cookie);
    final response = await _get(
      client,
      'https://my.115.com/?ct=ajax&ac=nav',
      headers: <String, String>{
        HttpHeaders.userAgentHeader: _browserUa,
        HttpHeaders.refererHeader: 'https://115.com/',
        HttpHeaders.acceptHeader: 'application/json, text/plain, */*',
      },
      cookie: base,
    );
    final merged = mergeDriveSetCookies(base, response.setCookies);
    final state = response.json['state'];
    final valid = response.status == 200 && state == true;
    final guest = response.status == 200 && state == false;
    final data = response.json['data'];
    final name = data is Map
        ? (data['user_name'] ?? data['uname'] ?? '').toString().trim()
        : '';
    return DriveProbeResult(
      provider: '115',
      valid: valid ? true : (guest ? false : null),
      username: name,
      credential: merged,
      message: valid
          ? '登录有效'
          : guest
          ? '缺少 UID / CID / SEID 三件套，请重新登录'
          : '校验接口返回异常（HTTP ${response.status}）',
    );
  }

  Future<DriveProbeResult> _checkBili(HttpClient client, String cookie) async {
    final base = sanitizeDriveCookie(cookie);
    final response = await _get(
      client,
      'https://api.bilibili.com/x/web-interface/nav',
      headers: <String, String>{
        HttpHeaders.userAgentHeader: _browserUa,
        HttpHeaders.refererHeader: 'https://www.bilibili.com/',
        HttpHeaders.acceptHeader: 'application/json, text/plain, */*',
      },
      cookie: base,
    );
    final merged = mergeDriveSetCookies(base, response.setCookies);
    final code = (response.json['code'] as num?)?.toInt();
    final data = response.json['data'];
    final isLogin = data is Map && data['isLogin'] == true;
    final valid = response.status == 200 && code == 0 && isLogin;
    final guest = code == -101;
    final uname = data is Map ? (data['uname'] ?? '').toString().trim() : '';
    return DriveProbeResult(
      provider: 'bili',
      valid: valid ? true : (guest ? false : null),
      username: valid ? uname : '',
      credential: merged,
      message: valid
          ? '登录有效'
          : guest
          ? 'SESSDATA 已失效（不登录仍可播 360P / 480P）'
          : '校验接口返回异常（code=${code ?? '-'}）',
    );
  }

  Future<_HttpResult> _get(
    HttpClient client,
    String url, {
    required Map<String, String> headers,
    String cookie = '',
  }) => _request(client, url, headers: headers, cookie: cookie);

  Future<_HttpResult> _request(
    HttpClient client,
    String url, {
    String method = 'GET',
    required Map<String, String> headers,
    String cookie = '',
    String? body,
  }) async {
    final request = await client
        .openUrl(method, Uri.parse(url))
        .timeout(const Duration(seconds: 12));
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (cookie.isNotEmpty)
      request.headers.set(HttpHeaders.cookieHeader, cookie);
    if (body != null) request.write(body);
    final response = await request.close().timeout(const Duration(seconds: 15));
    final text = await response
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .timeout(const Duration(seconds: 15));
    final setCookies = <String>[];
    response.headers.forEach((name, values) {
      if (name.toLowerCase() == HttpHeaders.setCookieHeader) {
        setCookies.addAll(values);
      }
    });
    var json = <String, dynamic>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) json = decoded;
    } on FormatException {
      // 非 JSON（风控页 / 网关错误）：调用方只看 status。
    }
    return _HttpResult(
      status: response.statusCode,
      json: json,
      setCookies: setCookies,
    );
  }
}

class _HttpResult {
  const _HttpResult({
    required this.status,
    required this.json,
    required this.setCookies,
  });

  final int status;
  final Map<String, dynamic> json;
  final List<String> setCookies;
}
