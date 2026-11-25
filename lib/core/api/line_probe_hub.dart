import 'models/vod_models.dart';
import 'source_probe_controller.dart';

/// 播放器内「线路切换」用的测速结果缓存。
///
/// 为什么要缓存而不是每次 new 一个：播放页由大量 provider 驱动，宿主每次
/// build 都会重算 `PlayerLineNav` / `PlayerEpisodeListNav`。如果每次 build
/// 都新建 controller，测速会被反复触发，且结果永远到不了 UI 手里。
/// 按「会话指纹」取同一个实例，才能保证「测一次、到处复用、完成即刷新」。
///
/// 指纹只由「站点 + 影片 + 线路名列表」决定（见 [keyFor]）：
/// - 同一次播放内切集 / 换线不变 → 结果继续有效（换线本来就是换到这些线上）；
/// - 换片 / 换配置自然变成新 key → 旧的淘汰（[maxEntries]）。
class LineProbeHub {
  LineProbeHub._();

  static final LineProbeHub instance = LineProbeHub._();

  /// 同时保留的会话数。播放页同一时刻只有一部片在放，3 个足够覆盖
  /// 「刚退出上一部、又点回上一部」这种来回切换。
  static const int maxEntries = 3;

  /// 插入顺序即最近使用顺序（命中的会先移除再插入到末尾）。
  final Map<String, SourceProbeController> _entries = {};

  /// 会话指纹：线路名参与计算，避免「同一部片换了配置里的线路集合」还命中旧结果。
  static String keyFor({
    required String siteKey,
    required String vodId,
    required List<PlayFrom> sources,
  }) {
    final names = sources.map((source) => source.name).join('\u0001');
    return '$siteKey\u0002$vodId\u0002$names';
  }

  /// 取当前会话的测速控制器（同步、幂等）。
  ///
  /// 只创建不启动：真正的测速由 UI 在「用户要看线路列表」时调用
  /// [SourceProbeController.ensureStarted]，避免每次播放都白跑一批请求。
  SourceProbeController feedFor(String key, List<PlayFrom> sources) {
    final existing = _entries.remove(key);
    if (existing != null) {
      _entries[key] = existing;
      return existing;
    }

    final controller =
        SourceProbeController.forPlayback(sources: sources);
    _entries[key] = controller;

    // 淘汰**不 dispose**：万一还有一行 `ListenableBuilder` 挂在上面，
    // dispose 后它再收到通知会抛「used after being disposed」。
    // controller 自身没有 Timer / 订阅，交给 GC 即可。
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return controller;
  }

  /// 测试用：清空并释放全部条目。
  void clear() {
    for (final controller in _entries.values) {
      controller.dispose();
    }
    _entries.clear();
  }

  int get length => _entries.length;
}
