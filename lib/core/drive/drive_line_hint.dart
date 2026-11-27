import 'drive_provider.dart';

/// 一条线路或一段错误文案指向的网盘。
///
/// 只做纯映射：不读账号、不发请求，供播放页决定「是否提示登录」。
class DriveLineHint {
  const DriveLineHint({
    required this.provider,
    required this.name,
    required this.supported,
    this.optional = false,
  });

  /// 与 [driveProviders] / 账号存储一致的键。
  final String provider;

  /// 展示名。
  final String name;

  /// 本机是否支持保存该网盘凭据（登录 / 粘贴 Cookie / Token）。
  final bool supported;

  /// 可选增强：没有凭据也能播，只是画质或可用性受限（哔哩哔哩）。
  final bool optional;
}

class _HintRule {
  const _HintRule(this.provider, this.name, this.patterns);

  final String provider;
  final String name;
  final List<Pattern> patterns;
}

/// 顺序即优先级：先认能登录的网盘，再认只用于提示「不支持」的网盘。
final List<_HintRule> _rules = <_HintRule>[
  _HintRule('quark', '夸克网盘', [
    '夸克',
    '夸父',
    RegExp('quark', caseSensitive: false),
  ]),
  _HintRule('baidu', '百度网盘', ['百度', RegExp('baidu', caseSensitive: false)]),
  _HintRule('uc', 'UC 网盘', [
    RegExp(r'(^|[^a-z])uc([^a-z]|$)', caseSensitive: false),
    '优视',
    '优汐',
  ]),
  // 哔哩要排在「115」等数字规则之前，避免 B站线路被其他规则抢走。
  _HintRule('bili', '哔哩哔哩', [
    RegExp(r'^b\s*站', caseSensitive: false),
    RegExp('bilibili', caseSensitive: false),
    RegExp(r'(^|[^a-z])bili([^a-z]|$)', caseSensitive: false),
    '哔哩',
  ]),
  _HintRule('115', '115 网盘', [RegExp(r'(^|[^0-9])115([^0-9]|$)')]),
  _HintRule('thunder', '迅雷云盘', [
    '迅雷',
    RegExp('thunder', caseSensitive: false),
    RegExp('xunlei', caseSensitive: false),
  ]),
  _HintRule('guangya', '光鸭云盘', [
    '光鸭',
    '光雅',
    RegExp('guangya', caseSensitive: false),
  ]),
  _HintRule('aliyun', '阿里云盘', [
    '阿里',
    RegExp('aliyun', caseSensitive: false),
    RegExp(r'(^|[^a-z])ali([^a-z]|$)', caseSensitive: false),
  ]),
  _HintRule('pan123', '123 云盘', [RegExp(r'(^|[^0-9])123([^0-9]|$)'), '123盘']),
  _HintRule('pan139', '移动云盘', [RegExp(r'(^|[^0-9])139([^0-9]|$)'), '移动云']),
  _HintRule('pan189', '天翼云盘', [RegExp(r'(^|[^0-9])189([^0-9]|$)'), '天翼']),
  _HintRule('pikpak', 'PikPak', [RegExp('pikpak', caseSensitive: false)]),
  _HintRule('magnet', '磁力链接', ['磁力', RegExp('magnet', caseSensitive: false)]),
];

DriveLineHint? _match(String text) {
  final value = text.trim();
  if (value.isEmpty) return null;
  for (final rule in _rules) {
    for (final pattern in rule.patterns) {
      if (pattern.allMatches(value).isNotEmpty) {
        final provider = driveProviderById(rule.provider);
        return DriveLineHint(
          provider: rule.provider,
          name: provider?.name ?? rule.name,
          supported: provider != null,
          optional: provider?.optional ?? false,
        );
      }
    }
  }
  return null;
}

/// 线路名（如「夸克原画」「百度」「UC」）→ 需要的网盘。
DriveLineHint? driveHintFromFlag(String flag) => _match(flag);

/// 播放失败文案（如「还没有配置百度网盘 Cookie」）→ 需要补登录的网盘。
DriveLineHint? driveHintFromMessage(String message) => _match(message);
