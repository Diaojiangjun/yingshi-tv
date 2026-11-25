import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/app_env.dart';
import '../net/http_client_factory.dart';
import '../net/system_proxy.dart';
import 'danmaku_models.dart';
import 'danmaku_service_config.dart';
import 'danmaku_source.dart';

/// §43 弹幕服务地址与访问令牌：由维护者在 `config/app.env` 里配置，代码与仓库里不保存真实值。
///
/// - 面向用户：用户用的是维护者打包好的安装包（打包时自动注入），**不需要也看不到**这项配置；
/// - 维护者本机：`flutter run`（带不带其它参数都行）开发态会自动读 `config/app.env`，见 [AppEnv]；
/// - 其他开发者：这是留给你的「可选」口子——不建 `config/app.env` 就是不启用弹幕，
///   播放页没有弹幕按钮 / D 键、设置页没有「弹幕」分组、不发任何请求，其余功能照常；
/// - `config/app.env` 已被 `.gitignore` 排除，**不要提交**；入库的只有空值模板 `config/app.env.example`。
///
/// 服务是自部署的 LogVar Danmu API（https://github.com/Diaojiangjun/danmu_api），令牌放在路径第一段。
/// 注意：值会编进发布的 exe，只能防「拿仓库代码就能用」，挡不住拆包或抓包；防滥用靠服务端限流 / 换令牌。
/// 构建期内置的主接口地址（不含用户自填值）：设置页据此区分「有内置服务」与「完全没配」。
String get kBuiltinDanmakuApiBase => composeDanmakuApiBase(
    AppEnv.get('YINGSHI_DANMAKU_URL'), AppEnv.get('YINGSHI_DANMAKU_TOKEN'));

/// 主接口的「当前生效」地址：用户在设置里填的优先，留空回落到构建期内置值。
String get kDanmakuApiBase {
  final userBase = DanmakuServiceRuntime.primaryBase;
  if (userBase.isNotEmpty) return userBase;
  return kBuiltinDanmakuApiBase;
}

/// 各接口独立取配置：备用地址已包含其访问路径，不复用默认接口的令牌。
///
/// 备用接口目前只来自构建期内置——设置页只暴露主接口的地址与令牌，
/// 用户自填的主接口生效时会覆盖掉「主接口」，不会连带影响备用接口。
String danmakuApiBaseFor(DanmakuSource source) => switch (source) {
      DanmakuSource.primary => kDanmakuApiBase,
      DanmakuSource.secondary =>
        composeDanmakuApiBase(AppEnv.get('YINGSHI_DANMAKU_SECONDARY_URL'), ''),
    };

List<DanmakuSource> get configuredDanmakuSources => [
      for (final source in DanmakuSource.values)
        if (danmakuApiBaseFor(source).isNotEmpty) source,
    ];

/// 保存的接口在本次构建中缺失时，仅回落到已配置的接口。
DanmakuSource resolveDanmakuSource(DanmakuSource preferred) {
  final sources = configuredDanmakuSources;
  return sources.contains(preferred)
      ? preferred
      : sources.firstOrNull ?? DanmakuSource.primary;
}

/// 是否配置了弹幕服务（为 false 时弹幕功能整体不出现）。
bool get danmakuServiceConfigured => configuredDanmakuSources.isNotEmpty;

/// 取不到弹幕的原因（只用于状态提示，不打断播放）。
class DanmakuException implements Exception {
  const DanmakuException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 可取消标记：换集 / 换线 / 退出时置位，在途请求立刻中止。
class DanmakuCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in List.of(_listeners)) {
      l();
    }
    _listeners.clear();
  }

  void _onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }
}

/// 弹幕服务客户端。
///
/// - 匹配：`GET <base>/danmaku?name=&episode=`（FongMi 兼容接口，候选已按片名 + 集数打分排序；
///   网盘文件名式集名如「[1.76 GB]01-4K.高码率.mkv」也能识别，实测见 docs/DANMAKU_PLAN.md §2）；
/// - 取数：候选 `url` 换成 `format=json`。
///
/// 网络：跟随 Windows 系统代理（`HttpClient.findProxyFromEnvironment` 不读注册表，
/// 这里显式读取，见 [systemProxy]），直连失败的网络环境下仍可用。
class DanmakuApi {
  DanmakuApi({
    String? base,
    this.source = DanmakuSource.primary,
    HttpClient? client,
    String? Function()? proxy,
  })  : _explicitBase = base == null ? null : _trimSlash(base),
        _client = client ?? _defaultClient(proxy ?? systemProxy);

  static String _trimSlash(String s) => s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  /// 构造时显式给定的地址（测试 / 用户填的地址直接测）；为 null 时按 [source] 现取。
  final String? _explicitBase;

  /// 使用哪个接口：只决定「地址从哪来」，不影响请求内容。
  final DanmakuSource source;
  final HttpClient _client;

  /// 每次请求现取，不在构造时定死：用户在设置里改了地址后，
  /// 已存在的控制器 / 搜索框不必重建就能连上新服务。
  String get _base => _explicitBase ?? _trimSlash(danmakuApiBaseFor(source));

  static const Duration searchTimeout = Duration(seconds: 30);

  /// 单集弹幕可达 4 万条 / 4 MB，Serverless 冷启动 + 源站实抓实测 11–44 s。
  static const Duration commentTimeout = Duration(seconds: 90);

  static HttpClient _defaultClient(String? Function() proxy) {
    return HttpClientFactory.createHttpClient(
      connectionTimeout: const Duration(seconds: 12),
      userAgent: 'yingshi-tv',
      proxy: proxy,
    );
  }

  /// 按片名 + 集名搜索候选（已按匹配度排序）。
  Future<List<DanmakuCandidate>> search(String name, String episode,
          {DanmakuCancelToken? cancel}) =>
      _search({'name': name, 'episode': episode}, cancel);

  /// 只按关键词（片名）搜索候选：播放页「搜索弹幕」拿当前片名当关键词，
  /// 服务端会把该片各集的候选一起返回（实测 `?name=醉梦` 可用）。
  Future<List<DanmakuCandidate>> searchKeyword(String keyword,
          {DanmakuCancelToken? cancel}) =>
      _search({'name': keyword}, cancel);

  Future<List<DanmakuCandidate>> _search(
      Map<String, String> queryParameters, DanmakuCancelToken? cancel) async {
    final uri =
        Uri.parse('$_base/danmaku').replace(queryParameters: queryParameters);
    final body = await _get(uri, searchTimeout, cancel);
    return DanmakuCandidate.listFromJson(jsonDecode(body));
  }

  /// 取某个候选的弹幕原始 JSON 文本（交给缓存层落盘，再由 [DanmakuTrack] 解析）。
  Future<String> fetchComments(DanmakuCandidate candidate, {DanmakuCancelToken? cancel}) =>
      _get(Uri.parse(candidate.jsonUrl), commentTimeout, cancel);

  Future<String> _get(Uri uri, Duration timeout, DanmakuCancelToken? cancel) async {
    if (cancel?.isCancelled ?? false) throw const DanmakuException('已取消');
    if (_base.isEmpty) throw const DanmakuException('未配置弹幕服务');
    HttpClientRequest? request;
    cancel?._onCancel(() => request?.abort());
    try {
      request = await _client.getUrl(uri).timeout(timeout);
      if (cancel?.isCancelled ?? false) {
        request.abort();
        throw const DanmakuException('已取消');
      }
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      final bytes = await response.fold<List<int>>(<int>[], (a, b) => a..addAll(b)).timeout(timeout);
      if (cancel?.isCancelled ?? false) throw const DanmakuException('已取消');
      if (response.statusCode == HttpStatus.notFound) throw const DanmakuException('无弹幕');
      if (response.statusCode != HttpStatus.ok) {
        throw DanmakuException('弹幕服务返回 ${response.statusCode}');
      }
      return utf8.decode(bytes, allowMalformed: true);
    } on DanmakuException {
      rethrow;
    } on TimeoutException {
      request?.abort();
      throw const DanmakuException('弹幕服务超时');
    } catch (_) {
      if (cancel?.isCancelled ?? false) throw const DanmakuException('已取消');
      throw const DanmakuException('弹幕服务不可达');
    }
  }

  void close() => _client.close(force: true);

  /// Windows 系统代理；实现已抽到 [SystemProxy]（豆瓣 / TMDB / 清单探测 / 在线字幕共用）。
  static String? systemProxy() => SystemProxy.current;

  /// `127.0.0.1:7890` / `http=127.0.0.1:7890;https=127.0.0.1:7891` / `http://h:p` → `host:port`。
  static String? parseProxyServer(String raw) => SystemProxy.parse(raw);
}
