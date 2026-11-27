import 'dart:convert';

/// 把已登录网盘凭据并入 Spider 的 `ext`（provider 名即 ext 键名）。
///
/// 只在 `ext` 本身是 JSON 对象时注入；空值 / 非 JSON 原样返回，避免改变源作者
/// 预期的格式。访客态凭据应由调用方提前过滤。
String enrichDriveSpiderExt(String? ext, Map<String, String> credentials) {
  final source = ext?.trim() ?? '';
  if (source.isEmpty || credentials.isEmpty) return ext ?? '';
  try {
    final decoded = jsonDecode(source);
    if (decoded is! Map) return ext ?? '';
    var changed = false;
    for (final entry in credentials.entries) {
      final key = entry.key.trim();
      final value = entry.value.trim();
      if (key.isEmpty || value.isEmpty) continue;
      if (decoded[key] == value) continue;
      decoded[key] = value;
      // 阿里在 TVBox 生态里同时存在 `ali` / `aliyun` 两种键名，补一个别名。
      if (key == 'aliyun' && !decoded.containsKey('ali')) {
        decoded['ali'] = value;
      }
      changed = true;
    }
    return changed ? jsonEncode(decoded) : (ext ?? '');
  } catch (_) {
    return ext ?? '';
  }
}
