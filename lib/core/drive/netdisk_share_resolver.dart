import 'aliyun_native.dart';
import 'baidu_native.dart';
import 'drive_descriptor.dart';
import 'guangya_native.dart';
import 'pan115_native.dart';
import 'quark_native.dart';
import 'uc_native.dart';

/// 分享链接 / 描述符 / 集参数 → 免转存直链。
///
/// 覆盖夸克 / UC / 百度 / 115 / 阿里 / 光鸭；其余网盘仍交给站源 Spider 处理。
/// 解链实现参考并适配自 MisaTV（GPL-3.0）的纯 Dart 取链代码。
class NetdiskShareResolver {
  NetdiskShareResolver({required this.credentials});

  /// 从账号仓库读取当前可用于解链的凭据（访客态已被过滤）。
  final Map<String, String> Function() credentials;

  static final _quarkLink = RegExp(
    r'(https?://)?(?:[\w-]+\.)*pan\.quark\.cn/s/[^\s]+',
    caseSensitive: false,
  );
  static final _ucLink = RegExp(
    r'(https?://)?(?:[\w-]+\.)*(?:drive|fast)\.uc\.cn/s/[^\s]+',
    caseSensitive: false,
  );
  static final _baiduLink = RegExp(
    r'(https?://)?(?:[\w-]+\.)*(?:pan|yun)\.baidu\.com/s/[^\s]+',
    caseSensitive: false,
  );
  static final _pan115Link = RegExp(
    r'(https?://)?(?:[\w-]+\.)*115(?:cdn)?\.com/s/[^\s]+',
    caseSensitive: false,
  );
  static final _aliLink = RegExp(
    r'(https?://)?(?:[\w-]+\.)*(?:alipan|aliyundrive)\.com/s/[^\s]+',
    caseSensitive: false,
  );
  static final _guangyaLink = RegExp(
    r'(https?://)?(?:[\w-]+\.)*guangyapan\.(?:com|cn)/s/[^\s]+',
    caseSensitive: false,
  );

  static const _supported = <String>{
    'quark',
    'uc',
    'baidu',
    '115',
    'aliyun',
    'guangya',
  };

  /// 这段文本是否是需要本机解链的网盘分享。
  ///
  /// [flag] 是线路名（如「夸父原1」「UC」）。加固壳常把分享编码进集参数
  /// （`~~` / `++` / `sId+fid` JSON），此时 id 本身看不出网盘，必须结合线路名判断。
  bool looksLikeShare(String text, {String flag = ''}) =>
      _providerOf(text, flag) != null;

  /// 解析为可播放直链；失败时 [NativeDriveLink.reason] 给出中文原因。
  Future<NativeDriveLink> resolve(
    String text, {
    String flag = '',
    String episodeName = '',
  }) async {
    final value = text.trim();
    if (value.isEmpty) return NativeDriveLink.failed('播放地址为空');
    final provider = _providerOf(value, flag) ?? '';
    final tokens = credentials();
    switch (provider) {
      case 'quark':
        return resolveQuarkDirect(
          value,
          cookie: (tokens['quark'] ?? '').trim(),
          flag: flag,
          episodeName: episodeName,
        );
      case 'uc':
        return resolveUcDirect(
          value,
          cookie: (tokens['uc'] ?? '').trim(),
          flag: flag,
          episodeName: episodeName,
        );
      case 'baidu':
        return resolveBaiduDirect(
          value,
          cookie: (tokens['baidu'] ?? '').trim(),
          episodeName: episodeName,
        );
      case '115':
        return resolve115Direct(
          value,
          cookie: (tokens['115'] ?? '').trim(),
          flag: flag,
          episodeName: episodeName,
        );
      case 'aliyun':
        return resolveAliyunDirect(
          value,
          token: (tokens['aliyun'] ?? '').trim(),
          flag: flag,
          episodeName: episodeName,
        );
      case 'guangya':
        return resolveGuangyaDirect(
          value,
          token: (tokens['guangya'] ?? '').trim(),
          flag: flag,
          episodeName: episodeName,
        );
      default:
        return NativeDriveLink.failed('暂不支持该网盘解链');
    }
  }

  String _normalizeProvider(String provider) {
    final value = provider.trim().toLowerCase();
    return value == 'ali' || value == 'alipan' ? 'aliyun' : value;
  }

  /// 判定文本指向哪家网盘；识别不了返回 null。
  ///
  /// 顺序即优先级：显式描述符 / 链接最可信；加固壳的集参数其次——
  /// UC 的复合串结构专有，要先于夸克判断，避免「夸克无限」线路下发的 UC 分享被抢走。
  String? _providerOf(String text, String flag) {
    final value = text.trim();
    if (value.isEmpty) return null;
    final desc = parseDriveDescriptor(value);
    if (desc != null) {
      final provider = _normalizeProvider(desc.provider);
      return _supported.contains(provider) ? provider : null;
    }
    final fromText = _providerFromText(value);
    if (fromText != null) return fromText;
    if (looksLikeUcShare(value, flag: flag)) return 'uc';
    // 夸克的集参数解析在「线路名为空」时会信任任意 sId+fid JSON，
    // 放到全局播放入口会误伤其它站源的 JSON 集地址，所以这里必须有明确线路名。
    if (flag.trim().isNotEmpty && looksLikeQuarkShare(value, flag: flag)) {
      return 'quark';
    }
    if (looksLikeBaiduShare(value)) return 'baidu';
    return null;
  }

  String? _providerFromText(String value) {
    if (_quarkLink.hasMatch(value)) return 'quark';
    if (_ucLink.hasMatch(value)) return 'uc';
    if (_baiduLink.hasMatch(value)) return 'baidu';
    if (_pan115Link.hasMatch(value)) return '115';
    if (_aliLink.hasMatch(value)) return 'aliyun';
    if (_guangyaLink.hasMatch(value)) return 'guangya';
    return null;
  }
}
