/// 网盘凭据的清洗、粗筛与 Cookie 合并（纯函数，便于单元测试）。
///
/// 用户粘贴的来源五花八门：请求头原文、`Cookie:` 前缀、cURL 的 `-H`、每行一个
/// `a=b`、`Set-Cookie`……这里统一收成 `a=b; c=d`，再由 [driveCredentialHasAuth]
/// 判断是否像登录态。**最终是否可用以在线校验为准**（见 `drive_probe.dart`）。
library;

import 'dart:convert';

/// Set-Cookie 里常见、但不是会话字段的属性名。
const Set<String> _cookieAttributes = <String>{
  'path',
  'domain',
  'expires',
  'max-age',
  'secure',
  'httponly',
  'samesite',
  'priority',
  'partitioned',
};

/// 把用户粘贴的内容清洗成 `a=b; c=d`；Token 类网盘只做去引号 / 去 `Bearer `。
///
/// 支持：
///   · 请求头里的原始 Cookie 串；
///   · 带 `Cookie:` 前缀的整段请求头；
///   · cURL 的 `-H 'Cookie: ...'`（只取 Cookie 这一段）；
///   · 每行一个 `a=b` 的列表；
///   · `Set-Cookie` 形式（丢弃 Path / Domain / Expires 等属性）。
String normalizeDriveCredentialInput(String raw, {bool token = false}) {
  return token ? normalizeDriveTokenInput(raw) : normalizeDriveCookieInput(raw);
}

/// Token 类：去引号、去 `Bearer ` 前缀；粘贴整段 JSON 时取其中的 token 字段。
String normalizeDriveTokenInput(String raw) {
  var value = raw.trim();
  // 顺序有意义：`Bearer "x"` 必须先去前缀，再去引号。
  if (value.toLowerCase().startsWith('bearer ')) {
    value = value.substring(7).trim();
  }
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    value = value.substring(1, value.length - 1).trim();
  }
  if (value.startsWith('{') && value.endsWith('}')) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        for (final key in const <String>[
          'refresh_token',
          'refreshToken',
          'access_token',
          'accessToken',
          'token',
        ]) {
          final candidate = decoded[key];
          if (candidate is String && candidate.trim().isNotEmpty) {
            return candidate.trim();
          }
        }
      }
    } on FormatException {
      // 不是 JSON：按原样返回。
    }
  }
  return value;
}

/// Cookie 类：清洗成 `a=b; c=d`。
String normalizeDriveCookieInput(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';
  final prefix = text.toLowerCase().indexOf('cookie:');
  if (prefix >= 0) text = text.substring(prefix + 7);
  // cURL 里 Cookie 值后面通常跟着引号，取到引号之前即可。
  final quote = text.indexOf(RegExp("['\"]"));
  if (quote >= 0) text = text.substring(0, quote);
  text = text
      .replaceAll('\\\r\n', ' ')
      .replaceAll('\\\n', ' ')
      .replaceAll('\r', '\n');
  final jar = <String, String>{};
  for (final part in text.split(RegExp(r'[;\n]'))) {
    final segment = part.trim();
    if (segment.isEmpty) continue;
    final eq = segment.indexOf('=');
    if (eq <= 0) continue;
    final name = segment.substring(0, eq).trim();
    final value = segment.substring(eq + 1).trim();
    if (name.isEmpty || value.isEmpty) continue;
    if (name.contains(RegExp(r'[=;,\s]'))) continue;
    if (_cookieAttributes.contains(name.toLowerCase())) continue;
    jar[name] = value;
  }
  return jar.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');
}

/// Cookie 里出现的字段名集合。
Set<String> driveCookieNames(String cookie) {
  final names = <String>{};
  for (final part in cookie.split(';')) {
    final segment = part.trim();
    final eq = segment.indexOf('=');
    if (eq <= 0) continue;
    names.add(segment.substring(0, eq).trim());
  }
  return names;
}

/// 清掉历史版本合并出错留下的坏键（键名带 `$`，如 `$1__puus`）：
/// 这类键不会被服务端识别，还会让同名 `Set-Cookie` 永远命中不到、吞掉新的 `__puus`。
String sanitizeDriveCookie(String cookie) {
  final parts = <String>[];
  for (final segment in cookie.split(';')) {
    final value = segment.trim();
    final eq = value.indexOf('=');
    if (eq <= 0) continue;
    if (value.substring(0, eq).contains(r'$')) continue;
    parts.add(value);
  }
  return parts.join('; ');
}

/// 上游 `Set-Cookie` 合并进账号 Cookie（同名覆盖、新键追加）。
///
/// 夸克 / UC 常在校验或取链响应里下发新的 `__puus`，不合并就会一直用旧值。
String mergeDriveSetCookies(String base, Iterable<String> setCookies) {
  var out = base.trim();
  for (final line in setCookies) {
    final pair = line.split(';').first.trim();
    final eq = pair.indexOf('=');
    if (eq <= 0) continue;
    final key = pair.substring(0, eq).trim();
    if (key.isEmpty) continue;
    final value = pair.substring(eq + 1).trim();
    final pattern = RegExp(
      '(^|;\\s*)${RegExp.escape(key)}=[^;]*',
      caseSensitive: false,
    );
    // Dart 的 replaceFirst 不解析 `$1`（会按字面量插入），必须用映射版取分组。
    out = pattern.hasMatch(out)
        ? out.replaceFirstMapped(
            pattern,
            (m) => '${m.group(1) ?? ''}$key=$value',
          )
        : (out.isEmpty ? '$key=$value' : '$out; $key=$value');
  }
  return out;
}

/// 是否具备登录态字段（粗筛）。
bool driveCredentialHasAuth({
  required bool token,
  required List<String> authNames,
  required String credential,
}) {
  if (token) return credential.trim().isNotEmpty;
  if (authNames.isEmpty) return credential.trim().isNotEmpty;
  final names = driveCookieNames(credential);
  return authNames.any(names.contains);
}

/// 会话字段是否齐全（含必需字段）。
bool driveCredentialIsReady({
  required bool token,
  required List<String> authNames,
  required List<String> readyNames,
  required String credential,
}) {
  if (token) return credential.trim().isNotEmpty;
  if (!driveCredentialHasAuth(
    token: token,
    authNames: authNames,
    credential: credential,
  )) {
    return false;
  }
  if (readyNames.isEmpty) return true;
  final names = driveCookieNames(credential);
  return readyNames.every(names.contains);
}

/// 缺少登录态字段时给用户看的提示。
String driveCredentialMissingHint({
  required bool token,
  required List<String> authNames,
  required List<String> readyNames,
  required String credential,
}) {
  if (credential.trim().isEmpty) {
    return token ? 'Token 为空' : 'Cookie 为空';
  }
  if (token) return '';
  final names = driveCookieNames(credential);
  if (readyNames.length > 1) {
    final missing = readyNames.where((name) => !names.contains(name)).toList();
    if (missing.isNotEmpty) {
      return '缺少会话字段 ${missing.join(' / ')}：'
          '请确认复制的是已登录状态下的完整 Cookie';
    }
  }
  return 'Cookie 里没有登录态字段（${authNames.join(' / ')}），'
      '请确认复制的是已登录状态下的完整 Cookie';
}
