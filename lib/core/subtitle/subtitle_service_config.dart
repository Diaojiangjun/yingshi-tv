import 'custom_provider.dart';

/// 用户自填的在线字幕配置（设置 → 字幕与弹幕）。
///
/// 两种来源，都可留空：
/// - **assrt token**：伪射手开放 API，填了才检索这一源；
/// - **自定义字幕 API**：每行 `名称@https://…{title}…`，返回 JSON 列表或字幕文件。
///
/// 都没填时仍可用 SubtitleCat（免 token 的公开网页源）兜底，
/// 只是它在部分网络环境下不可达。
///
/// 持久化在 `player_settings.json` 的 `subtitleService` 对象里（随设置一起备份 / 迁移）。
class SubtitleServiceConfig {
  const SubtitleServiceConfig({this.assrtToken = '', this.customApis = ''});

  static const SubtitleServiceConfig empty = SubtitleServiceConfig();

  /// assrt.net 的访问令牌。
  final String assrtToken;

  /// 自定义字幕 API 的原始多行文本（解析见 [parseCustomSubtitleApis]）。
  final String customApis;

  bool get hasAssrt => assrtToken.trim().isNotEmpty;
  bool get hasCustomApis => parsedCustomApis.isNotEmpty;

  /// 至少有一个自填来源。
  bool get isNotEmpty => hasAssrt || hasCustomApis;
  bool get isEmpty => !isNotEmpty;

  List<CustomSubtitleApi> get parsedCustomApis => parseCustomSubtitleApis(customApis);

  factory SubtitleServiceConfig.fromJson(Object? raw) {
    if (raw is! Map) return empty;
    String text(String key) {
      final v = raw[key];
      return v is String ? v.trim() : '';
    }

    return SubtitleServiceConfig(
      assrtToken: text('assrtToken'),
      customApis: text('customApis'),
    );
  }

  Map<String, dynamic> toJson() => {
        'assrtToken': assrtToken,
        'customApis': customApis,
      };

  SubtitleServiceConfig copyWith({String? assrtToken, String? customApis}) =>
      SubtitleServiceConfig(
        assrtToken: assrtToken ?? this.assrtToken,
        customApis: customApis ?? this.customApis,
      );

  @override
  bool operator ==(Object other) =>
      other is SubtitleServiceConfig &&
      other.assrtToken == assrtToken &&
      other.customApis == customApis;

  @override
  int get hashCode => Object.hash(assrtToken, customApis);

  @override
  String toString() => 'SubtitleServiceConfig('
      'assrt: ${hasAssrt ? '***' : ''}, '
      'custom: ${parsedCustomApis.length})';
}

/// 运行期「当前生效」的字幕配置：由设置仓库在加载 / 保存播放设置时写入。
///
/// 与弹幕同一套思路：检索入口可能在播放器抽屉里、也可能在对话框里，
/// 都不想为了读一份配置去穿 provider；写入点只有一个（设置仓库）。
class SubtitleServiceRuntime {
  static SubtitleServiceConfig _current = SubtitleServiceConfig.empty;

  static SubtitleServiceConfig get current => _current;

  /// 是否配了自填来源（决定是否需要提示「先去设置填 token」）。
  static bool get configured => _current.isNotEmpty;

  static void apply(SubtitleServiceConfig config) {
    _current = config;
  }
}
