import 'dart:io';

/// Windows 系统代理（「设置 → 网络 → 代理」/ Clash 等写入的注册表项）。
///
/// 弹幕、豆瓣、TMDB、清单探测、在线字幕共用这一个来源：各自读一遍注册表
/// 既慢又可能读到不同结果（缓存窗口不一致）。当前只处理 `ProxyEnable=1`
/// 时的 `ProxyServer`；`http=a:1;https=b:2` 形式取 https 项。
class SystemProxy {
  SystemProxy._();

  static String? _cache;
  static DateTime? _cachedAt;
  static bool _cached = false;

  /// 当前系统代理（`host:port`）；无代理 / 读失败返回 null。
  ///
  /// 结果缓存 60 秒，避免每个请求都起一次 `reg` 进程。
  static String? get current {
    final now = DateTime.now();
    if (_cached && now.difference(_cachedAt!) < const Duration(seconds: 60)) {
      return _cache;
    }
    _cachedAt = now;
    _cached = true;
    _cache = Platform.isWindows ? _readWindowsProxy() : null;
    return _cache;
  }

  /// 测试用：写入 / 清空缓存。
  static void debugSet(String? value) {
    _cache = value;
    _cachedAt = DateTime.now();
    _cached = true;
  }

  static String? _readWindowsProxy() {
    try {
      const key =
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
      final enable = Process.runSync('reg', ['query', key, '/v', 'ProxyEnable']);
      if (!RegExp(r'ProxyEnable\s+REG_DWORD\s+0x0*1\b')
          .hasMatch('${enable.stdout}')) {
        return null;
      }
      final server = Process.runSync('reg', ['query', key, '/v', 'ProxyServer']);
      final m = RegExp(r'ProxyServer\s+REG_SZ\s+(\S+)').firstMatch('${server.stdout}');
      return m == null ? null : parse(m.group(1)!);
    } catch (_) {
      return null;
    }
  }

  /// `127.0.0.1:7890` / `http=127.0.0.1:7890;https=127.0.0.1:7891` / `http://h:p` → `host:port`。
  static String? parse(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return null;
    if (value.contains('=')) {
      final entries = <String, String>{};
      for (final part in value.split(';')) {
        final i = part.indexOf('=');
        if (i > 0) {
          entries[part.substring(0, i).trim().toLowerCase()] =
              part.substring(i + 1).trim();
        }
      }
      value = entries['https'] ?? entries['http'] ?? '';
      if (value.isEmpty) return null;
    }
    value = value.replaceFirst(RegExp(r'^[a-z]+://', caseSensitive: false), '');
    if (value.endsWith('/')) value = value.substring(0, value.length - 1);
    return RegExp(r'^[^\s:/]+:\d+$').hasMatch(value) ? value : null;
  }
}
