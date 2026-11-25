/// 多源测速优选（纯评分 + 可注入测量）。
///
/// 目的：同一部影片在多个站点 / 多条线路都有结果时，按「实际能不能播、播得怎么样」
/// 排序，而不是按配置里的站点顺序。评分只回答「该先点哪个」，**不改变起播链路**——
/// 选中的地址仍原样交给播放器。
///
/// 设计约束（与 `hls_playlist_probe.dart` 同一路子）：
/// - **纯函数决策**：[rankSources] 不联网、不抛异常，单测可 100% 用 fake 样本驱动；
/// - **默认不碰分片**：探测只读目标地址前 ≤[SourceProbeRunner.maxBytes]（清单 / 容器头），
///   仅当 [SourceProbeRunner.deepSampleBytes] 显式 >0 时才会为 HLS 额外拉首个分片的一小段，
///   用于真实带宽估计（计费 / 签名敏感的源请保持默认 0）；
/// - **失败静默**：超时 / 非 2xx / 网络异常只落成失败样本，排在可用源之后，绝不抛给 UI，
///   也绝不因为一次抖动把某条线路拉黑（不落盘、不写记忆）；
/// - **出口一致**：生产抓取走 `HttpClientFactory`（DoH + 系统代理），与 mpv 起播出口相同，
///   否则会出现「测速说快、起播拉不动」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../danmaku/danmaku_api.dart';
import '../net/http_client_factory.dart';

// --- 评分 -------------------------------------------------------------------

/// 三维权重。默认 40/40/20：分辨率 40%、真实速度 40%、延迟 20%。
///
/// 权重为 0 表示「该维度不参与」。缺失维度的权重会按剩余维度重新归一
/// （见 [rankSources]），所以不必凑成 1.0。
class SourceScoreWeights {
  const SourceScoreWeights({
    this.resolution = 0.4,
    this.speed = 0.4,
    this.latency = 0.2,
  });

  /// 常用组合：画质、速度、延迟按 4:4:2。
  static const SourceScoreWeights balanced = SourceScoreWeights();

  /// 保守组合：只要稳，画质权重压低。
  static const SourceScoreWeights stability = SourceScoreWeights(
    resolution: 0.2,
    speed: 0.3,
    latency: 0.5,
  );

  final double resolution;
  final double speed;
  final double latency;

  @override
  bool operator ==(Object other) =>
      other is SourceScoreWeights &&
      other.resolution == resolution &&
      other.speed == speed &&
      other.latency == latency;

  @override
  int get hashCode => Object.hash(resolution, speed, latency);
}

/// 单次测量失败的原因（只用于展示与诊断，不参与评分）。
enum SourceProbeFailure {
  none,
  timeout,
  network,
  forbidden,
  notFound,
  serverError,
  http,
  unsupported;

  bool get isFailure => this != SourceProbeFailure.none;

  /// 用户可读的短标签。
  String get label => switch (this) {
        SourceProbeFailure.none => '可用',
        SourceProbeFailure.timeout => '超时',
        SourceProbeFailure.network => '连不上',
        SourceProbeFailure.forbidden => '被拒绝 (403)',
        SourceProbeFailure.notFound => '不存在 (404)',
        SourceProbeFailure.serverError => '源站错误',
        SourceProbeFailure.http => 'HTTP 错误',
        SourceProbeFailure.unsupported => '不支持的地址',
      };
}

/// 一条线路的测量结果（纯数据；由 [probeSource] 或测试 fake 产生）。
class SourceMeasurement {
  const SourceMeasurement({
    required this.key,
    this.width,
    this.bandwidth,
    this.ttfb,
    this.speedKBps,
    this.failure = SourceProbeFailure.none,
    this.statusCode,
    this.note,
  });

  /// 线路标识（如站点 key、`from@index`、线路名）。评分结果按它回填。
  final String key;

  /// HLS master 声明的画面宽度（`RESOLUTION=1920x1080` 取 1920）。
  final int? width;

  /// HLS master 声明的带宽（bps，`BANDWIDTH=5000000`）。
  final int? bandwidth;

  /// 首字节耗时（含建连 + TLS + 首包）。
  final Duration? ttfb;

  /// 实测下载速度（KB/s）；样本太小时为 null 表示「未测」而非「零速」。
  final double? speedKBps;

  final SourceProbeFailure failure;

  final int? statusCode;

  /// 诊断备注（如 `hls` / `hls-master` / `binary`），不展示给普通用户。
  final String? note;

  bool get usable => !failure.isFailure;

  @override
  String toString() => 'SourceMeasurement($key, failure: ${failure.name}, '
      'ttfb: ${ttfb?.inMilliseconds}ms, speed: $speedKBps KB/s)';
}

/// 单个线路的评分结果。
class SourceScore {
  const SourceScore({
    required this.key,
    required this.total,
    required this.order,
    required this.measurement,
    this.parts = const {},
    this.notes = const [],
  });

  final String key;

  /// 综合分（0–100）。失败样本为 0。
  final double total;

  /// 输入顺序（同分时保持稳定排序，不让列表莫名跳动）。
  final int order;

  final SourceMeasurement measurement;

  /// 各维度归一化后的得分（0–100），键为 `resolution` / `speed` / `latency`。
  /// 缺失的维度不会出现在这里——「缺失」和「得了 0 分」是两件事。
  final Map<String, double> parts;

  /// 诊断备注，如 `resolution-missing` / `speed-missing`。
  final List<String> notes;

  bool get usable => measurement.usable;

  /// 可直接放在 UI 副标题里的一句话，例如 `1080p · 3.2 MB/s · 120ms`。
  String get summary {
    if (!usable) return measurement.failure.label;
    final bits = <String>[];
    final quality = resolutionLabel;
    if (quality != null) bits.add(quality);
    final speed = measurement.speedKBps;
    if (speed != null && speed > 0) bits.add(formatSpeed(speed));
    final ttfb = measurement.ttfb;
    if (ttfb != null) bits.add('${ttfb.inMilliseconds}ms');
    return bits.isEmpty ? '未测速' : bits.join(' · ');
  }

  /// 画质标签；无声明时为 null（此时 UI 可以退回显示带宽）。
  String? get resolutionLabel {
    final width = measurement.width;
    if (width != null && width > 0) {
      if (width >= 3840) return '4K';
      if (width >= 2560) return '2K';
      if (width >= 1920) return '1080p';
      if (width >= 1280) return '720p';
      if (width >= 854) return '480p';
      return '${width}p';
    }
    final bandwidth = measurement.bandwidth;
    if (bandwidth != null && bandwidth > 0) {
      return '${(bandwidth / 1000000).toStringAsFixed(1)} Mbps';
    }
    return null;
  }

  /// 速度格式化：≥1 MB/s 用 MB/s，否则 KB/s。
  static String formatSpeed(double kbPerSec) {
    if (kbPerSec >= 1024) return '${(kbPerSec / 1024).toStringAsFixed(1)} MB/s';
    return '${kbPerSec.toStringAsFixed(0)} KB/s';
  }
}

/// 排序结果。
class SourceRanking {
  const SourceRanking({required this.ranked, required this.failed});

  static const SourceRanking empty = SourceRanking(ranked: [], failed: []);

  /// 可用线路，综合分降序；同分保持输入顺序。
  final List<SourceScore> ranked;

  /// 不可用线路，保持输入顺序（UI 通常折叠或置灰）。
  final List<SourceScore> failed;

  bool get isEmpty => ranked.isEmpty && failed.isEmpty;

  /// 首选线路；全部失败时为 null（调用方应回退到「按原顺序让用户自己选」）。
  SourceScore? get best => ranked.isEmpty ? null : ranked.first;

  String? get bestKey => best?.key;

  /// 按 key 取回评分（不分可用 / 失败）。
  SourceScore? scoreFor(String key) {
    for (final item in ranked) {
      if (item.key == key) return item;
    }
    for (final item in failed) {
      if (item.key == key) return item;
    }
    return null;
  }
}

/// 给一组测量样本打分并排序（纯函数，不联网、不抛异常）。
///
/// 归一化规则（比「缺失维度记 0 分」更公平）：
/// - 速度：`speed / maxSpeed × 100`，分母只取**有速度样本**的源；
/// - 延迟：`(maxTtfb − ttfb) / (maxTtfb − minTtfb) × 100`，全部相同则记 100；
/// - 分辨率：按宽度 / 带宽查表，是绝对分而非相对分（同批都是 4K 时不该集体掉分）；
/// - 某维度在当前批次里一个样本都没有 → 该维度权重不参与，总权重按剩余维度重新归一；
///   一个维度都算不出来 → 中性 50 分，保持输入顺序，不制造虚假差异。
SourceRanking rankSources(
  List<SourceMeasurement> measurements, {
  SourceScoreWeights weights = SourceScoreWeights.balanced,
}) {
  if (measurements.isEmpty) return SourceRanking.empty;

  final usable = <SourceMeasurement>[];
  final failed = <SourceScore>[];
  for (var i = 0; i < measurements.length; i++) {
    final item = measurements[i];
    if (item.usable) {
      usable.add(item);
    } else {
      failed.add(SourceScore(
        key: item.key,
        total: 0,
        order: i,
        measurement: item,
        notes: ['probe-${item.failure.name}'],
      ));
    }
  }

  if (usable.isEmpty) {
    return SourceRanking(ranked: const [], failed: List.unmodifiable(failed));
  }

  // --- 批次统计（只统计真实存在的样本，缺失不参与分母）---
  double? maxSpeed;
  for (final item in usable) {
    final speed = item.speedKBps;
    if (speed == null || speed <= 0) continue;
    maxSpeed = maxSpeed == null ? speed : math.max(maxSpeed, speed);
  }

  Duration? minTtfb;
  Duration? maxTtfb;
  for (final item in usable) {
    final ttfb = item.ttfb;
    if (ttfb == null || ttfb.isNegative) continue;
    minTtfb = minTtfb == null ? ttfb : (ttfb < minTtfb ? ttfb : minTtfb);
    maxTtfb = maxTtfb == null ? ttfb : (ttfb > maxTtfb ? ttfb : maxTtfb);
  }

  final wResolution = math.max(0.0, weights.resolution);
  final wSpeed = math.max(0.0, weights.speed);
  final wLatency = math.max(0.0, weights.latency);

  final scored = <SourceScore>[];
  for (var i = 0; i < measurements.length; i++) {
    final item = measurements[i];
    if (!item.usable) continue;

    final parts = <String, double>{};
    final notes = <String>[];
    var weighted = 0.0;
    var weightSum = 0.0;

    final resolution = _resolutionScore(item);
    if (resolution != null && wResolution > 0) {
      parts['resolution'] = resolution;
      weighted += resolution * wResolution;
      weightSum += wResolution;
    } else if (resolution == null) {
      notes.add('resolution-missing');
    }

    final speed = item.speedKBps;
    if (speed != null && speed > 0 && maxSpeed != null && wSpeed > 0) {
      final normalized = (speed / maxSpeed * 100).clamp(0.0, 100.0);
      parts['speed'] = normalized;
      weighted += normalized * wSpeed;
      weightSum += wSpeed;
    } else {
      notes.add('speed-missing');
    }

    final ttfb = item.ttfb;
    if (ttfb != null && !ttfb.isNegative && wLatency > 0) {
      final double normalized;
      if (minTtfb == null || maxTtfb == null || maxTtfb <= minTtfb) {
        normalized = 100;
      } else {
        final span = (maxTtfb - minTtfb).inMilliseconds;
        final offset = (ttfb - minTtfb).inMilliseconds;
        normalized = span <= 0 ? 100 : (1 - offset / span) * 100;
      }
      final latency = normalized.clamp(0.0, 100.0);
      parts['latency'] = latency;
      weighted += latency * wLatency;
      weightSum += wLatency;
    } else {
      notes.add('latency-missing');
    }

    final total = weightSum > 0 ? weighted / weightSum : 50.0;
    scored.add(SourceScore(
      key: item.key,
      total: _round2(total),
      order: i,
      measurement: item,
      parts: Map.unmodifiable(parts),
      notes: List.unmodifiable(notes),
    ));
  }

  scored.sort((a, b) {
    final byScore = b.total.compareTo(a.total);
    if (byScore != 0) return byScore;
    return a.order.compareTo(b.order);
  });

  return SourceRanking(
    ranked: List.unmodifiable(scored),
    failed: List.unmodifiable(failed),
  );
}

double _round2(double value) => (value * 100).round() / 100.0;

/// 分辨率 / 带宽 → 0–100 的绝对分。
double? _resolutionScore(SourceMeasurement item) {
  final width = item.width;
  if (width != null && width > 0) {
    if (width >= 3840) return 100;
    if (width >= 2560) return 88;
    if (width >= 1920) return 76;
    if (width >= 1280) return 62;
    if (width >= 854) return 44;
    if (width >= 640) return 32;
    return 24;
  }
  final bandwidth = item.bandwidth;
  if (bandwidth != null && bandwidth > 0) {
    if (bandwidth >= 8000000) return 76;
    if (bandwidth >= 5000000) return 62;
    if (bandwidth >= 2000000) return 44;
    return 28;
  }
  return null;
}

// --- 测量 -------------------------------------------------------------------

/// 待测线路。
class SourceTarget {
  const SourceTarget({
    required this.key,
    required this.url,
    this.headers = const <String, String>{},
  });

  final String key;
  final String url;

  /// 附加请求头（Referer / UA 等），**必须与起播时一致**，否则会测出
  /// 「测速能过、起播 403」的假阳性。
  final Map<String, String> headers;

  @override
  String toString() => 'SourceTarget($key)';
}

/// 可注入的测量实现：[budget] 是本次允许的最长耗时。
typedef SourceMeasure = Future<SourceMeasurement> Function(
  SourceTarget target,
  Duration budget,
);

/// 批量测量 + 排序。
///
/// 与 `HlsPlaylistProbe` 的区别：那个只判「点播 / 直播」，这个要拿到**可比的分值**，
/// 所以会读完受控的一小段字节来估算速度（可选再采样一个分片），但不碰整片。
class SourceProbeRunner {
  SourceProbeRunner({
    SourceMeasure? measure,
    this.concurrency = 3,
    this.totalBudget = const Duration(seconds: 8),
    this.deepSampleBytes = 0,
    this.maxBytes = 64 * 1024,
  }) : _override = measure;

  final SourceMeasure? _override;

  /// 同时测量的线路数。源站多半同域，开太大容易被限速反而测不准。
  final int concurrency;

  /// 整批测量的总预算；用尽后剩余线路直接记超时（不让 UI 无限转圈）。
  final Duration totalBudget;

  /// HLS 深测时每个分片采样的字节数；0 = 不拉分片（默认）。
  final int deepSampleBytes;

  /// 单次请求最多读取字节数。
  final int maxBytes;

  Future<SourceMeasurement> _measure(SourceTarget target, Duration budget) {
    final override = _override;
    if (override != null) return override(target, budget);
    return probeSource(
      target,
      budget,
      deepSampleBytes: deepSampleBytes,
      maxBytes: maxBytes,
    );
  }

  /// 测量并排序；永不抛异常，预算用尽的线路以 [SourceProbeFailure.timeout]
  /// 出现在 [SourceRanking.failed] 里。
  Future<SourceRanking> rank(
    List<SourceTarget> targets, {
    SourceScoreWeights weights = SourceScoreWeights.balanced,
  }) async {
    if (targets.isEmpty) return SourceRanking.empty;

    final deadline = DateTime.now().add(totalBudget);
    final samples = <SourceMeasurement>[];
    final batchSize = math.max(1, concurrency);

    for (var start = 0; start < targets.length; start += batchSize) {
      final batch = targets.skip(start).take(batchSize).toList();
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        for (final target in batch) {
          samples.add(SourceMeasurement(
            key: target.key,
            failure: SourceProbeFailure.timeout,
            note: 'budget-exhausted',
          ));
        }
        continue;
      }

      final results = await Future.wait(batch.map((target) async {
        try {
          return await _measure(target, remaining).timeout(remaining);
        } on TimeoutException {
          return SourceMeasurement(
            key: target.key,
            failure: SourceProbeFailure.timeout,
          );
        } catch (_) {
          return SourceMeasurement(
            key: target.key,
            failure: SourceProbeFailure.network,
          );
        }
      }));
      samples.addAll(results);
    }

    return rankSources(samples, weights: weights);
  }
}

/// 共享实例（整批 8 s、并发 3、不拉分片）。UI 侧直接用这个即可。
final SourceProbeRunner sharedSourceProbeRunner = SourceProbeRunner();

/// 生产测量：读一小段字节，拿延迟、（HLS 时）分辨率、以及（可选）真实速度。
///
/// [budget] 同时用作建连超时与整体截止时间；任何异常都落成失败样本。
Future<SourceMeasurement> probeSource(
  SourceTarget target,
  Duration budget, {
  int deepSampleBytes = 0,
  int maxBytes = 64 * 1024,
}) async {
  final uri = Uri.tryParse(target.url.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    return SourceMeasurement(
      key: target.key,
      failure: SourceProbeFailure.unsupported,
    );
  }

  // 内网 / 本机地址不走系统代理：局域网 NAS、自建 CMS 走代理只会失败。
  final proxy = isPrivateHost(uri.host) ? null : DanmakuApi.systemProxy;
  final client = HttpClientFactory.createHttpClient(
    connectionTimeout: budget,
    idleTimeout: HttpClientFactory.dioDefaultIdleTimeout,
    proxy: proxy,
  );

  try {
    final sample = await _fetchSample(
      client,
      uri,
      target.headers,
      budget,
      maxBytes: maxBytes,
    );
    final ttfb = sample.ttfb;

    if (sample.statusCode < 200 || sample.statusCode >= 300) {
      return SourceMeasurement(
        key: target.key,
        ttfb: ttfb,
        statusCode: sample.statusCode,
        failure: _failureForStatus(sample.statusCode),
      );
    }

    final text = _asPlaylistText(sample.bytes);
    if (text == null) {
      // 容器直链（mp4 / ts）：字节数足够就能算出带宽。
      return SourceMeasurement(
        key: target.key,
        ttfb: ttfb,
        speedKBps: speedFromSample(
          sample.bytes.length,
          sample.elapsed - ttfb,
        ),
        statusCode: sample.statusCode,
        note: 'binary',
      );
    }

    final signals = parseMasterSignals(text, base: uri);
    var speed = speedFromSample(sample.bytes.length, sample.elapsed - ttfb);
    var note = 'hls';
    if (signals.isMaster) {
      // master 只是索引，速度没有参考价值；要真速度得深测分片。
      speed = null;
      note = 'hls-master';
    }

    if (deepSampleBytes > 0) {
      final deep = await _deepSpeed(
        client,
        uri,
        text,
        target.headers,
        budget,
        deepSampleBytes,
      );
      if (deep != null && deep > 0) {
        speed = deep;
        note = '$note+deep';
      }
    }

    return SourceMeasurement(
      key: target.key,
      width: signals.width,
      bandwidth: signals.bandwidth,
      ttfb: ttfb,
      speedKBps: speed,
      statusCode: sample.statusCode,
      note: note,
    );
  } on TimeoutException {
    return SourceMeasurement(
      key: target.key,
      failure: SourceProbeFailure.timeout,
    );
  } on HandshakeException {
    return SourceMeasurement(
      key: target.key,
      failure: SourceProbeFailure.network,
      note: 'tls',
    );
  } on SocketException {
    return SourceMeasurement(
      key: target.key,
      failure: SourceProbeFailure.network,
    );
  } on HttpException {
    return SourceMeasurement(
      key: target.key,
      failure: SourceProbeFailure.network,
    );
  } catch (_) {
    return SourceMeasurement(
      key: target.key,
      failure: SourceProbeFailure.network,
      note: 'unknown',
    );
  } finally {
    client.close(force: true);
  }
}

/// 深测：master → 变体清单 → 首个分片，只读 [sampleBytes] 估真实带宽。
///
/// 不抛异常；任何一步失败返回 null（保持「未测」而不是给个假速度）。
Future<double?> _deepSpeed(
  HttpClient client,
  Uri playlistUri,
  String content,
  Map<String, String> headers,
  Duration budget,
  int sampleBytes,
) async {
  // 深测单独限时，避免把整批预算吃光。
  final deepBudget = Duration(
    milliseconds: math.max(1500, budget.inMilliseconds ~/ 2),
  );
  var currentUri = playlistUri;
  var current = content;

  try {
    // 最多两跳：master → media，media → 分片。
    for (var hop = 0; hop < 2; hop++) {
      final signals = parseMasterSignals(current, base: currentUri);
      final next = signals.firstUri;
      if (next == null) return null;
      final nextUri = Uri.tryParse(next);
      if (nextUri == null || !nextUri.hasScheme) return null;

      final sample = await _fetchSample(
        client,
        nextUri,
        headers,
        deepBudget,
        maxBytes: sampleBytes,
      );
      if (sample.statusCode < 200 || sample.statusCode >= 300) return null;

      final text = _asPlaylistText(sample.bytes);
      if (text == null) {
        // 已经是分片，按读到的字节算速度。
        final window = sample.elapsed - sample.ttfb;
        return speedFromSample(
          sample.bytes.length,
          window,
          minBytes: math.min(sampleBytes, 32 * 1024),
        );
      }
      currentUri = nextUri;
      current = text;
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// 一次受控读取的结果。
class _Sample {
  const _Sample({
    required this.bytes,
    required this.ttfb,
    required this.elapsed,
    required this.statusCode,
  });

  final Uint8List bytes;
  final Duration ttfb;
  final Duration elapsed;
  final int statusCode;
}

/// GET 一小段：`ttfb` = 拿到响应头的时刻，`elapsed` = 读完（或断流）的时刻。
Future<_Sample> _fetchSample(
  HttpClient client,
  Uri uri,
  Map<String, String> headers,
  Duration budget, {
  required int maxBytes,
}) async {
  final stopwatch = Stopwatch()..start();
  final request = await client.getUrl(uri).timeout(budget);
  request.followRedirects = true;
  request.maxRedirects = 5;
  headers.forEach(request.headers.set);
  final response = await request.close().timeout(budget);
  final ttfb = stopwatch.elapsed;

  if (response.statusCode < 200 || response.statusCode >= 300) {
    try {
      await response.drain<void>();
    } catch (_) {
      // 丢弃响应体失败不影响结论。
    }
    return _Sample(
      bytes: Uint8List(0),
      ttfb: ttfb,
      elapsed: stopwatch.elapsed,
      statusCode: response.statusCode,
    );
  }

  final bytes = await _readHead(response, maxBytes, budget);
  return _Sample(
    bytes: bytes,
    ttfb: ttfb,
    elapsed: stopwatch.elapsed,
    statusCode: response.statusCode,
  );
}

/// 读完受控长度后断开；超时 / 读失败都按已读到的部分返回（不抛）。
Future<Uint8List> _readHead(
  HttpClientResponse response,
  int maxBytes,
  Duration budget,
) async {
  final builder = BytesBuilder(copy: false);
  try {
    await for (final chunk in response.timeout(budget)) {
      final remain = maxBytes - builder.length;
      if (remain <= 0) break;
      if (chunk.length <= remain) {
        builder.add(chunk);
      } else {
        builder.add(chunk.sublist(0, remain));
      }
      if (builder.length >= maxBytes) break;
    }
  } catch (_) {
    // 中途超时：用已读到的字节继续评估（足以区分快慢）。
  }
  return builder.takeBytes();
}

// --- 纯解析 ----------------------------------------------------------------

/// 清单里与画质相关的声明。
class HlsMasterSignals {
  const HlsMasterSignals({
    required this.isMaster,
    this.width,
    this.bandwidth,
    this.firstUri,
  });

  /// 是否含 `#EXT-X-STREAM-INF` 且有可用变体行。
  final bool isMaster;

  /// 所有 `RESOLUTION=` 里最大的宽度。
  final int? width;

  /// 所有 `BANDWIDTH=` 里的最大值（bps）。
  final int? bandwidth;

  /// 第一个变体（master）或第一个分片（media）的地址；传了 [base] 时为绝对地址。
  final String? firstUri;
}

/// 解析清单的画质声明（纯函数，不联网、不抛异常）。
///
/// 与点播/直播探测分开：那边关心 `ENDLIST` / `MEDIA-SEQUENCE`，这边只关心
/// `RESOLUTION` / `BANDWIDTH` / 首个地址，互不干扰。
HlsMasterSignals parseMasterSignals(String content, {Uri? base}) {
  var isMaster = false;
  int? maxWidth;
  int? maxBandwidth;
  String? pendingVariant;
  String? firstNonComment;

  for (final raw in const LineSplitter().convert(content)) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#EXT-X-STREAM-INF:')) {
      isMaster = true;
      final widthMatch =
          RegExp(r'RESOLUTION=(\d+)x(\d+)', caseSensitive: false).firstMatch(line);
      if (widthMatch != null) {
        final value = int.tryParse(widthMatch.group(1)!);
        if (value != null && value > 0 && (maxWidth == null || value > maxWidth)) {
          maxWidth = value;
        }
      }
      final bandwidthMatch =
          RegExp(r'(?:^|[:,])BANDWIDTH=(\d+)', caseSensitive: false).firstMatch(line);
      if (bandwidthMatch != null) {
        final value = int.tryParse(bandwidthMatch.group(1)!);
        if (value != null && value > 0 && (maxBandwidth == null || value > maxBandwidth)) {
          maxBandwidth = value;
        }
      }
      // 只记第一个变体：后续 STREAM-INF 不能覆盖已取到的地址。
      pendingVariant ??= '';
      continue;
    }

    if (line.startsWith('#')) continue;

    firstNonComment ??= line;
    if (pendingVariant != null && pendingVariant.isEmpty) {
      pendingVariant = line;
    }
  }

  // 非 master 且根本不是清单（如 403 的 HTML 片段）：不臆造「首个地址」。
  final looksLikePlaylist =
      isMaster || content.replaceFirst('\uFEFF', '').trimLeft().startsWith('#EXTM3U');
  final first = isMaster ? pendingVariant : (looksLikePlaylist ? firstNonComment : null);
  String? resolved;
  if (first != null && first.isNotEmpty) {
    final parsed = Uri.tryParse(first);
    if (parsed != null && parsed.hasScheme) {
      resolved = parsed.toString();
    } else if (base != null) {
      resolved = base.resolve(first).toString();
    } else {
      resolved = first;
    }
  }

  return HlsMasterSignals(
    isMaster: isMaster && first != null && first.isNotEmpty,
    width: maxWidth,
    bandwidth: maxBandwidth,
    firstUri: resolved,
  );
}

/// 是否本机 / 内网地址（这些地址不该走系统代理，否则局域网源一律失败）。
bool isPrivateHost(String host) {
  final value = host.toLowerCase();
  if (value.isEmpty) return false;
  if (value == 'localhost' || value == '::1' || value.endsWith('.localhost')) {
    return true;
  }
  if (value.endsWith('.local')) return true;

  final parts = value.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final part in parts) {
    final n = int.tryParse(part);
    if (n == null || n < 0 || n > 255) return false;
    octets.add(n);
  }
  final a = octets[0];
  final b = octets[1];
  if (a == 127 || a == 10) return true;
  if (a == 192 && b == 168) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 169 && b == 254) return true; // link-local
  return false;
}

/// 读到的字节像不像 HLS 清单（`#EXTM3U` 开头或含 `#EXT-X-`）；不是则返回 null。
String? _asPlaylistText(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  final head = utf8.decode(
    bytes.length > 2048 ? bytes.sublist(0, 2048) : bytes,
    allowMalformed: true,
  ).replaceFirst('\uFEFF', '').trimLeft();
  if (!head.startsWith('#EXTM3U') && !head.contains('#EXT-X-')) return null;
  return utf8.decode(bytes, allowMalformed: true);
}

/// 采样速度（KB/s）。样本太小或耗时太短时返回 null——那只是「清单很快」，不是带宽。
double? speedFromSample(
  int bytes,
  Duration window, {
  int minBytes = 32 * 1024,
}) {
  if (bytes < minBytes) return null;
  final micros = window.inMicroseconds;
  if (micros <= 0) return null;
  final kb = bytes / 1024.0;
  final seconds = micros / 1000000.0;
  if (seconds <= 0) return null;
  return (kb / seconds * 10).round() / 10.0;
}

SourceProbeFailure _failureForStatus(int status) {
  if (status == 401 || status == 403) return SourceProbeFailure.forbidden;
  if (status == 404 || status == 410) return SourceProbeFailure.notFound;
  if (status >= 500) return SourceProbeFailure.serverError;
  return SourceProbeFailure.http;
}
