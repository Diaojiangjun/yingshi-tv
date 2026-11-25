import 'party_state.dart';

/// 观众需要执行的动作集合。
///
/// 刻意做成「一次评估给出全部该做的事」而不是单个动作：切集 / 校正进度 /
/// 跟随播放暂停是相互独立的维度，合成一个动作会让调用方要么丢信息、
/// 要么下一轮再来一遍（多浪费一个轮询周期）。
class PartyFollow {
  const PartyFollow({
    this.switchToEpisode,
    this.seekTo,
    this.setPlaying,
    this.drift = Duration.zero,
    this.reason = '',
  });

  /// 需要切到的集（下标）；为空表示不用切。
  final int? switchToEpisode;

  /// 需要跳到的位置；为空表示不用跳。
  final Duration? seekTo;

  /// 需要切换的播放状态；为空表示保持当前。
  ///
  /// 切集时同样会带上它：新房主暂停着切集，观众加载完也不该自动播。
  final bool? setPlaying;

  /// 决策时的进度偏差（正数表示观众落后）。
  final Duration drift;

  /// 决策依据（提示文案 / 自检日志用）。
  final String reason;

  bool get isIdle =>
      switchToEpisode == null && seekTo == null && setPlaying == null;
}

/// 观众跟随决策（纯函数，不碰播放器）。
///
/// 参数 [compensation] 是「房主快照到现在已经过去多久」，它把两件事算进去：
/// 网络单程延迟，以及本地收到快照后到真正评估之间的间隔。播放中必须加上它，
/// 否则每次都会落后一个往返时延，看起来"永远慢半秒还在慢慢变大"。
///
/// 阈值刻意分开：播放中容忍大一些（频繁 seek 会打断解码、闪一下画面），
/// 暂停时容忍小一些（暂停状态下 seek 没有代价，可以直接对齐到帧）。
PartyFollow decidePartyFollow({
  required PartyState remote,
  required int localEpisodeIndex,
  required Duration localPosition,
  required bool localPlaying,
  Duration compensation = Duration.zero,
  Duration playingSeekThreshold = const Duration(seconds: 4),
  Duration pausedSeekThreshold = const Duration(milliseconds: 1500),
}) {
  final target = Duration(
    milliseconds: remote.playing
        ? remote.positionMs + compensation.inMilliseconds
        : remote.positionMs,
  );
  final safeTarget = target.isNegative ? Duration.zero : target;

  // 1. 集不同：先切集，位置由调用方在新集加载完成后应用。
  if (remote.episodeIndex != localEpisodeIndex) {
    return PartyFollow(
      switchToEpisode: remote.episodeIndex,
      seekTo: safeTarget,
      setPlaying: remote.playing,
      drift: safeTarget - localPosition,
      reason: '房主在第 ${remote.episodeIndex + 1} 集',
    );
  }

  final drift = safeTarget - localPosition;
  final threshold =
      remote.playing ? playingSeekThreshold : pausedSeekThreshold;

  // 2. 进度偏差超阈值才跳。绝对值比较：领先太多也要退回去，
  //    否则观众因为本地缓冲跑快了之后再也追不回来。
  final needSeek = drift.abs() > threshold;

  // 3. 播放 / 暂停状态跟随。
  final needState = remote.playing != localPlaying;

  if (!needSeek && !needState) {
    return PartyFollow(drift: drift, reason: '已在同步范围');
  }

  return PartyFollow(
    seekTo: needSeek ? safeTarget : null,
    setPlaying: needState ? remote.playing : null,
    drift: drift,
    reason: needSeek ? '偏差 ${drift.inMilliseconds}ms' : '房主${remote.playing ? '播放' : '暂停'}',
  );
}

/// 片名宽松匹配：两边有一边包含另一边即视为同一部。
///
/// 站点的片名常带年份 / 副标题（`流浪地球2` vs `流浪地球2 (2023)`），
/// 严格相等会让观众永远"打不开同一部片子"。空串一律视为匹配，
/// 因为房主可能还没发布过标题。
bool samePartyShow(String a, String b) {
  final x = a.trim().toLowerCase();
  final y = b.trim().toLowerCase();
  if (x.isEmpty || y.isEmpty) return true;
  return x.contains(y) || y.contains(x);
}

/// 把房间码归一：大写、去空白、去分隔符（用户手抄时爱写 `ABC-123`）。
String normalizePartyCode(String raw) =>
    raw.replaceAll(RegExp(r'[\s\-_]'), '').toUpperCase();
