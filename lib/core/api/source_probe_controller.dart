import 'dart:async';

import 'package:flutter/foundation.dart';

import 'line_probe_feed.dart';
import 'models/vod_models.dart';
import 'source_scorer.dart';

/// 线路测速状态（详情页与播放器内线路切换共用）。
///
/// 职责边界：
/// - **只提供「该优先点哪条」**，不改任何线路数据、不插手起播；
/// - **不阻塞 UI**：`start` / `ensureStarted` 立即返回，结果异步到达后通知；
/// - **静默失败**：整批测不出来时保持 `recommended == null`，调用方不改默认选中，
///   用户看到的行为与接入前完全一致（这是重要的回退保证）。
///
/// 已卸载后（[dispose]）不会再通知，避免在已卸载的 State 上 setState。
class SourceProbeController extends ChangeNotifier implements LineProbeFeed {
  /// 详情页用：轻量深测（每条 HLS 采 64 KiB 分片，10 条线路 ≈ 640 KiB）。
  ///
  /// 不直接用 [sharedSourceProbeRunner]（deepSampleBytes = 0）：那样 HLS 只有
  /// 分辨率与延迟、没有速度，详情页上「测速」名不副实。
  SourceProbeController({SourceProbeRunner? runner, List<PlayFrom>? sources})
      : _runner = runner ?? _detailRunner,
        _sources = sources ?? const [];

  /// 播放器内用：正在放视频，测速不能抢带宽。
  ///
  /// 并发从 3 降到 2、分片从 64 KiB 降到 32 KiB：10 条线路合计约 320 KiB，
  /// 且两条两条地测，尽量避免把正在缓冲的播放拖卡。
  SourceProbeController.forPlayback({
    SourceProbeRunner? runner,
    required List<PlayFrom> sources,
  })  : _runner = runner ?? _playbackRunner,
        _sources = sources;

  static final SourceProbeRunner _detailRunner = SourceProbeRunner(
    concurrency: 3,
    totalBudget: const Duration(seconds: 10),
    deepSampleBytes: 64 * 1024,
  );

  static final SourceProbeRunner _playbackRunner = SourceProbeRunner(
    concurrency: 2,
    totalBudget: const Duration(seconds: 8),
    deepSampleBytes: 32 * 1024,
  );

  final SourceProbeRunner _runner;

  /// 惰性启动时测量的线路列表（[ensureStarted] 用）。
  final List<PlayFrom> _sources;

  bool _disposed = false;
  bool _started = false;
  bool _loading = false;
  bool _finished = false;
  Map<int, SourceScore> _scores = const {};
  int? _recommended;

  @override
  bool get loading => _loading;

  @override
  bool get finished => _finished;

  /// 是否有任何可用结论（全失败时为 false）。
  bool get hasResult => _scores.isNotEmpty;

  @override
  int? get recommended => _recommended;

  /// 按线路下标取评分（含失败样本，失败样本 `usable == false`）。
  SourceScore? scoreOf(int sourceIndex) => _scores[sourceIndex];

  @override
  LineProbeHint? hintFor(int lineIndex) {
    final score = _scores[lineIndex];
    if (score == null) return null;
    return LineProbeHint(
      summary: score.summary,
      compact: _compactSummary(score),
      tooltip: tooltipFor(lineIndex),
      preferred: lineIndex == _recommended,
      failed: !score.usable,
    );
  }

  /// 面板窄行用的短摘要：只保留「画质 · 速度」。
  ///
  /// 完整摘要带 TTFB，但面板右侧文字区只有一半宽度，显示全了会变成
  /// `44 KB/s · 725…` 这种既没画质也看不出速度的残句。延迟留在 tooltip 里。
  static String _compactSummary(SourceScore score) {
    if (!score.usable) return score.summary;
    final bits = <String>[];
    final quality = score.resolutionLabel;
    if (quality != null) bits.add(quality);
    final speed = score.measurement.speedKBps;
    if (speed != null && speed > 0) bits.add(SourceScore.formatSpeed(speed));
    if (bits.isEmpty) {
      final ttfb = score.measurement.ttfb;
      if (ttfb != null) bits.add('${ttfb.inMilliseconds}ms');
    }
    return bits.isEmpty ? score.summary : bits.join(' · ');
  }

  /// 供 UI 用的悬浮说明；无结论时返回 null（不显示 tooltip）。
  String? tooltipFor(int sourceIndex) {
    final score = _scores[sourceIndex];
    if (score == null) return null;
    if (!score.usable) return '测速失败：${score.summary}';
    final parts = <String>['测速结果：${score.summary}'];
    if (score.parts['resolution'] != null) {
      parts.add('画质 ${score.parts['resolution']!.round()} 分');
    }
    if (score.parts['speed'] != null) {
      parts.add('速度 ${score.parts['speed']!.round()} 分');
    }
    if (score.parts['latency'] != null) {
      parts.add('延迟 ${score.parts['latency']!.round()} 分');
    }
    return parts.join('\n');
  }

  /// 用构造时传入的线路列表开始测速（没有则什么都不做）。
  @override
  void ensureStarted() {
    if (_sources.isNotEmpty) unawaited(start(_sources));
  }

  /// 开始测速；重复调用无副作用。
  ///
  /// 少于两条线路、或所有线路都没有可播地址时直接返回（不测、不显示指示）。
  Future<void> start(List<PlayFrom> sources) async {
    if (_started || _disposed) return;
    _started = true;
    if (sources.length < 2) return;

    final targets = <SourceTarget>[];
    final indexByKey = <String, int>{};
    for (var i = 0; i < sources.length; i++) {
      final episodes = sources[i].episodes;
      if (episodes.isEmpty) continue;
      final url = episodes.first.url.trim();
      if (url.isEmpty) continue;
      final key = '$i';
      targets.add(SourceTarget(key: key, url: url));
      indexByKey[key] = i;
    }
    if (targets.length < 2) return;

    _loading = true;
    _safeNotify();

    final ranking = await _runner.rank(targets);
    if (_disposed) return;

    final scores = <int, SourceScore>{};
    for (final score in [...ranking.ranked, ...ranking.failed]) {
      final index = indexByKey[score.key];
      if (index != null) scores[index] = score;
    }

    _scores = Map.unmodifiable(scores);
    _recommended = _bestIndex(ranking, indexByKey);
    _loading = false;
    _finished = true;
    _safeNotify();
  }

  int? _bestIndex(SourceRanking ranking, Map<String, int> indexByKey) {
    for (final score in ranking.ranked) {
      final index = indexByKey[score.key];
      if (index != null) return index;
    }
    return null;
  }

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
