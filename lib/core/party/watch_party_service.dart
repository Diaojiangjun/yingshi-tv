import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'party_server.dart';
import 'party_state.dart';
import 'party_sync.dart';
import '../../core/brand.dart';

/// 加入房间失败。[toString] 直接给用户看，所以不包一层 `FormatException:` 前缀。
class PartyJoinException implements Exception {
  const PartyJoinException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 「一起看」：房主把播放状态发布到局域网，观众轮询跟随。
///
/// 房主权威：只有房主的进度会被广播，观众不会反向覆盖，避免多人拖动冲突。
/// 传输是**只读 HTTP 轮询**（1 秒一次，几百字节），不是 WebSocket：
/// 家用 Wi-Fi 下这点开销可以忽略，而轮询天然容错——房主重启后下一轮自动恢复。
class WatchPartyService extends ChangeNotifier {
  WatchPartyService({
    required this.server,
    required this.deviceName,
    this.pollInterval = const Duration(seconds: 1),
    this.publishInterval = const Duration(milliseconds: 800),
  });

  final PartyServer server;
  final String Function() deviceName;
  final Duration pollInterval;

  /// 房主两次发布之间的最小间隔。
  ///
  /// 播放器每 1.5 秒才推一次快照，这里的节流是第二道闸：防止上层在
  /// 拖动进度条时把每个 position tick 都转发出去。
  final Duration publishInterval;

  /// 单调时钟：只用来算「快照到现在过了多久」，不受系统时间被改的影响。
  final Stopwatch _clock = Stopwatch()..start();

  bool hosting = false;
  bool joined = false;

  String roomCode = '';
  String hostName = '';
  String hostUrl = '';
  List<String> hostAddresses = const [];

  /// 房主最近发出的状态。
  PartyState? lastPublished;

  /// 观众收到的房主状态。
  PartyState? remote;

  String lastError = '';

  Timer? _poll;
  int _pollFailures = 0;

  /// 上次发布时间；null 表示还没发过。
  ///
  /// 不能用 `Duration.zero` 当哨兵：单调钟刚起步时 `elapsed` 本身就接近 0，
  /// 第一次发布会被误判成「刚发过」而吞掉，房间永远开不起来。
  Duration? _lastPublishAt;
  Duration _remoteReceivedAt = Duration.zero;
  Duration _remoteHalfRtt = Duration.zero;

  bool get active => hosting || joined;
  String get myName => deviceName();

  /// 能否跟随：观众 + 有房主状态 + 还没被判定掉线。
  bool get canFollow => joined && remote != null;

  /// 观众侧的补偿时间：单程延迟 + 收到快照后到现在。
  ///
  /// 房主播放中时，真实进度应该是 `remote.positionMs + 这个值`。
  Duration get remoteCompensation => remote == null
      ? Duration.zero
      : _remoteHalfRtt + (_clock.elapsed - _remoteReceivedAt);

  /// 创建房间（顺带启动局域网服务）。
  Future<String> startHost() async {
    final port = await server.start();
    final code = newPartyCode();
    server.room
      ..code = code
      ..hostName = myName
      ..revision = 0
      ..state = null;

    hosting = true;
    joined = false;
    remote = null;
    roomCode = code;
    hostName = myName;
    lastError = '';
    final addresses = await server.lanAddresses();
    hostAddresses = [for (final ip in addresses) 'http://$ip:$port'];
    hostUrl =
        hostAddresses.isEmpty ? 'http://127.0.0.1:$port' : hostAddresses.first;
    _stopPolling();
    lastPublished = null;
    _lastPublishAt = null;
    notifyListeners();
    return code;
  }

  /// 加入房间；[baseUrl] 允许只填 `192.168.1.5:9979`。
  Future<void> join({required String baseUrl, required String code}) async {
    final base = normalizePartyBase(baseUrl);
    final room = normalizePartyCode(code);
    if (base.isEmpty) throw const PartyJoinException('请填写房主地址');
    if (room.isEmpty) throw const PartyJoinException('请填写房间码');
    if (room.length != 6) throw const PartyJoinException('房间码是 6 位');

    final requestAt = _clock.elapsed;
    Map<String, dynamic> data;
    try {
      data = await PartyClient.getJson('$base/party?code=$room');
    } catch (_) {
      throw PartyJoinException('连不上房主（$base），请确认在同一网络且房主已开房');
    }
    final receivedAt = _clock.elapsed;

    if (data['ok'] != true) {
      throw const PartyJoinException('房间不存在或已关闭，请核对房间码');
    }
    final rawState = data['state'];
    remote = rawState is Map
        ? PartyState.fromJson(Map<String, dynamic>.from(rawState))
        : null;
    _remoteReceivedAt = receivedAt;
    _remoteHalfRtt = (receivedAt - requestAt) ~/ 2;

    hosting = false;
    joined = true;
    roomCode = room;
    hostName = (data['host'] ?? '').toString();
    hostUrl = base;
    hostAddresses = const [];
    lastError = '';
    _pollFailures = 0;
    _stopPolling();
    _poll = Timer.periodic(pollInterval, (_) => unawaited(_pollOnce()));
    notifyListeners();
  }

  /// 房主发布状态（内部按 [publishInterval] 节流；长时间没变化时降到 4 秒一次）。
  void publish(PartyState state) {
    if (!hosting) return;
    final now = _clock.elapsed;
    final last = _lastPublishAt;
    final previous = lastPublished;
    final stillSame = previous != null &&
        previous.sameContentAs(state) &&
        (previous.positionMs - state.positionMs).abs() < 1200;
    if (stillSame && last != null && now - last < const Duration(seconds: 4)) {
      return;
    }
    if (last != null && now - last < publishInterval) return;
    _lastPublishAt = now;
    final next = state.copyWith(sender: myName);
    final wasEmpty = lastPublished == null;
    lastPublished = next;
    server.room.publish(next);
    // 只在「第一次发布」时刷新界面：房主面板要据此把「等待开始播放」
    // 换成正常房间信息。之后每次发布都 notify 会让面板每秒重建一次。
    if (wasEmpty) notifyListeners();
  }

  /// 观众拉取房主状态。
  Future<void> _pollOnce() async {
    if (!joined || hostUrl.isEmpty || roomCode.isEmpty) return;
    final requestAt = _clock.elapsed;
    try {
      final data = await PartyClient.getJson(
        '$hostUrl/party?code=$roomCode',
        timeout: const Duration(seconds: 5),
      );
      final receivedAt = _clock.elapsed;
      _pollFailures = 0;
      // 被拒（403）说明房间关了 / 房间码失效，与网络抖动区分提示。
      if (data['ok'] != true) {
        if (lastError != '房主已关闭房间') {
          lastError = '房主已关闭房间';
          notifyListeners();
        }
        return;
      }
      if (lastError.isNotEmpty) {
        lastError = '';
      }
      final raw = data['state'];
      if (raw is! Map) {
        notifyListeners();
        return;
      }
      final next = PartyState.fromJson(Map<String, dynamic>.from(raw));
      remote = next;
      _remoteReceivedAt = receivedAt;
      _remoteHalfRtt = (receivedAt - requestAt) ~/ 2;
      hostName = (data['host'] ?? hostName).toString();
      // 状态没变也通知：补偿时间在走，调用方据此重新评估是否该校正。
      notifyListeners();
    } catch (_) {
      _pollFailures++;
      // 偶发丢包不打扰用户；连续失败才提示（房主可能已经关掉播放器）。
      if (_pollFailures >= 3 && lastError.isEmpty) {
        lastError = '与房主的连接中断，正在重试…';
        notifyListeners();
      }
    }
  }

  void leave() {
    if (hosting) server.room.clear();
    hosting = false;
    joined = false;
    roomCode = '';
    hostName = '';
    hostUrl = '';
    hostAddresses = const [];
    remote = null;
    lastPublished = null;
    _lastPublishAt = null;
    lastError = '';
    _pollFailures = 0;
    _remoteHalfRtt = Duration.zero;
    _stopPolling();
    notifyListeners();
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }
}

/// 本机显示名：优先系统主机名，取不到就用一个中性的固定名。
String defaultPartyDeviceName() {
  try {
    final name = Platform.localHostname.trim();
    if (name.isNotEmpty) return name;
  } catch (_) {
    // 某些环境（无网络栈 / 受限沙箱）拿不到主机名，忽略。
  }
  return AppBrand.name;
}
