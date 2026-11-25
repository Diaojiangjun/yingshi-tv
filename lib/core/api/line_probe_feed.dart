import 'package:flutter/foundation.dart';

/// 一条线路的测速摘要（纯展示数据）。
///
/// 刻意只给「文案 + 一个标记」：组件不做任何「能不能播」的判断。
/// 这里最重要的语义是 [failed] **不等于线路不可用**——403 防盗链、
/// 需要 Referer、跨境超时都会让测速失败，而播放器带上请求头往往能播。
/// 因此 UI 必须把它画成中性灰，不能复用「不可用」的红色 / 置灰语义。
@immutable
class LineProbeHint {
  const LineProbeHint({
    required this.summary,
    this.compact,
    this.tooltip,
    this.preferred = false,
    this.failed = false,
  });

  /// 完整摘要，例如 `1080p · 3.2 MB/s · 120ms`；失败时是失败原因（`连接失败`）。
  final String summary;

  /// 窄容器用的短摘要（`1080p · 3.2 MB/s`，不含延迟）。
  ///
  /// 播放器设置面板一行只有约 150px 给右侧文字，完整摘要一定被省略号吃掉，
  /// 而延迟恰恰是换线决策里权重最低的一段，所以这里主动去掉它。
  /// 为空时退回 [summary]（见 [short]）。
  final String? compact;

  /// 悬停详情（含各维度得分）；为空时不挂 Tooltip。
  final String? tooltip;

  /// 本批测速里的最优线路（UI 可换成闪电图标 / 加「推荐」）。
  final bool preferred;

  /// 测速失败（中性语义，见类注释）。
  final bool failed;

  /// 窄容器直接用它。
  String get short => compact ?? summary;
}

/// 线路测速结果的可订阅视图：宿主装配，组件只读。
///
/// 之所以做成 `Listenable` 而不是在视图模型里塞一份快照：测速是异步的，
/// 视图模型由宿主在每次 build 时重建，而测速完成时宿主**不一定会重建**
/// （播放页被大量 provider 驱动）。让组件自己订阅，才能在结果到达时
/// 只刷新线路那一小块，不动整棵播放器树。
abstract class LineProbeFeed implements Listenable {
  /// 整批测速进行中。
  bool get loading;

  /// 整批已结束（无论成功与否；全失败也算结束，避免一直显示「测速中」）。
  bool get finished;

  /// 最优线路在 `session.sources` 里的下标；没有结论时为 null。
  int? get recommended;

  /// 按 `session.sources` 的下标取摘要；该线路还没有结论时返回 null。
  LineProbeHint? hintFor(int lineIndex);

  /// 请求开始测速（惰性，由 UI 在「用户要看线路列表」时触发）。
  ///
  /// 必须在 build 之外调用：内部会 `notifyListeners`，在 build 里调用
  /// 会触发 `markNeedsBuild during build`。重复调用无副作用。
  void ensureStarted();
}
