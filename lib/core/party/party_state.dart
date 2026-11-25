import 'dart:math';

/// 「一起看」的房间状态与传输格式。
///
/// 设计为**房主权威**：只有房主的进度会被广播，其他人（观众）跟随。
/// 这样不需要处理多方同时拖动进度带来的冲突，也避免观众的口误操作影响全房间。
class PartyState {
  const PartyState({
    this.title = '',
    this.episodeName = '',
    this.episodeIndex = 0,
    this.positionMs = 0,
    this.playing = false,
    this.sender = '',
  });

  /// 剧名（观众可据此确认自己开的是同一部片子）。
  final String title;
  final String episodeName;
  final int episodeIndex;
  final int positionMs;
  final bool playing;

  /// 发送方设备名。
  final String sender;

  PartyState copyWith({
    String? title,
    String? episodeName,
    int? episodeIndex,
    int? positionMs,
    bool? playing,
    String? sender,
  }) =>
      PartyState(
        title: title ?? this.title,
        episodeName: episodeName ?? this.episodeName,
        episodeIndex: episodeIndex ?? this.episodeIndex,
        positionMs: positionMs ?? this.positionMs,
        playing: playing ?? this.playing,
        sender: sender ?? this.sender,
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'episodeName': episodeName,
        'episodeIndex': episodeIndex,
        'positionMs': positionMs,
        'playing': playing,
        'sender': sender,
      };

  /// 宽松解析：任何字段缺失或类型不对都退到安全默认值。
  ///
  /// 这条 HTTP 接口对局域网开放，不能假设对面一定是本程序的某个版本。
  factory PartyState.fromJson(Map<String, dynamic> json) => PartyState(
        title: (json['title'] ?? '').toString(),
        episodeName: (json['episodeName'] ?? '').toString(),
        episodeIndex: max(0, (json['episodeIndex'] as num?)?.toInt() ?? 0),
        positionMs: max(0, (json['positionMs'] as num?)?.toInt() ?? 0),
        playing: json['playing'] == true,
        sender: (json['sender'] ?? '').toString(),
      );

  /// 内容是否一致（不用于判新旧，只用于节流）。
  bool sameContentAs(PartyState other) =>
      title == other.title &&
      episodeName == other.episodeName &&
      episodeIndex == other.episodeIndex &&
      playing == other.playing;
}

/// 房主进程内的房间数据（局域网服务直接读它）。
class PartyRoom {
  String code = '';
  String hostName = '';
  PartyState? state;

  /// 每次发布 +1。
  ///
  /// **新旧判定只认它**：观众与房主的系统时钟可能差几分钟，
  /// 用时间戳比较会让一个慢钟的房主永远"没有新状态"。
  int revision = 0;

  /// 房间是否开放。
  ///
  /// **只看房间码，不看有没有状态**：房主刚开房、或当前内容是预告片 / 直播这类
  /// 拿不到剧集会话的场景，位置状态可能一次都没发布过。若这里要求 `state`
  /// 非空，观众一加入就会收到「房间不存在」，看起来像房间码抄错了。
  bool get open => code.isNotEmpty;

  void publish(PartyState next) {
    state = next;
    revision++;
  }

  void clear() {
    code = '';
    hostName = '';
    state = null;
    revision = 0;
  }

  Map<String, dynamic> toJson() => {
        'ok': open,
        'host': hostName,
        'revision': revision,
        if (state != null) 'state': state!.toJson(),
      };
}

/// 6 位房间码（去掉了 0/O/1/I 等容易读错的字符）。
String newPartyCode([Random? random]) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final source = random ?? Random.secure();
  return String.fromCharCodes(
    List.generate(6, (_) => alphabet.codeUnitAt(source.nextInt(alphabet.length))),
  );
}

/// 归一房主地址：允许只填 `192.168.1.5:9979`，也允许尾部斜杠。
String normalizePartyBase(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';
  if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(text)) {
    text = 'http://$text';
  }
  while (text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}
