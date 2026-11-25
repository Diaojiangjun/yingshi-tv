/// 用户自填的弹幕服务配置（设置 → 播放 → 弹幕 → 弹幕服务）。
///
/// 与构建期注入的私有配置（`config/app.env`，见 `danmaku_api.dart`）并存：
/// **这里填了就用这里，留空回落到构建期内置值**。这样用户装上安装包之后
/// 也能自己补 / 换一个接口，不必由打包方写死；没内置也没自填时就等于没启用弹幕。
///
/// 持久化在 `player_settings.json` 的 `danmakuService` 对象里（随设置一起备份 / 迁移）。
class DanmakuServiceConfig {
  const DanmakuServiceConfig({this.url = '', this.token = ''});

  static const DanmakuServiceConfig empty = DanmakuServiceConfig();

  /// 服务根地址：不带令牌、末尾不带 `/`，例如 `https://danmu.example.com`。
  final String url;

  /// 访问令牌（danmu_api 把它放在路径第一段）；服务没设令牌时留空。
  final String token;

  bool get isNotEmpty => url.trim().isNotEmpty;
  bool get isEmpty => !isNotEmpty;

  factory DanmakuServiceConfig.fromJson(Object? raw) {
    if (raw is! Map) return empty;
    String text(String key) {
      final v = raw[key];
      return v is String ? v.trim() : '';
    }

    return DanmakuServiceConfig(url: text('url'), token: text('token'));
  }

  Map<String, dynamic> toJson() => {'url': url, 'token': token};

  DanmakuServiceConfig copyWith({String? url, String? token}) => DanmakuServiceConfig(
        url: url ?? this.url,
        token: token ?? this.token,
      );

  @override
  bool operator ==(Object other) =>
      other is DanmakuServiceConfig && other.url == url && other.token == token;

  @override
  int get hashCode => Object.hash(url, token);

  @override
  String toString() => 'DanmakuServiceConfig(url: $url, token: ${token.isEmpty ? '' : '***'})';
}

/// `https://host/` + `tk` → `https://host/tk`；地址为空返回空串；令牌可空（服务未设令牌时）。
///
/// 两端空白与斜杠一起去掉（用户从别处复制时常带 `/` 或空格），令牌中间的字符保持原样。
String composeDanmakuApiBase(String url, String token) {
  var base = url.trim();
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  if (base.isEmpty) return '';
  final t = token.replaceAll(RegExp(r'^[\s/]+|[\s/]+$'), '');
  return t.isEmpty ? base : '$base/$t';
}

/// 运行期「当前生效」的用户配置：由 [SettingsRepository] 在加载 / 保存播放设置时写入。
///
/// 为什么要一个可变的全局：`danmakuApiBaseFor()` 被接口下拉、匹配控制器、搜索框
/// 等**同步**调用点共用，这些地方没有 Widget 树可读 provider；而配置只有一个，
/// 单一写入点（设置仓库）足够保证一致性。改动只在设置保存后发生，不涉及时序竞争。
class DanmakuServiceRuntime {
  static DanmakuServiceConfig _current = DanmakuServiceConfig.empty;

  static DanmakuServiceConfig get current => _current;

  /// 用户自填并拼接好的主接口地址；未填返回空串。
  static String get primaryBase =>
      composeDanmakuApiBase(_current.url, _current.token);

  static bool get configured => primaryBase.isNotEmpty;

  static void apply(DanmakuServiceConfig config) {
    _current = config;
  }
}
