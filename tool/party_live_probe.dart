// 手动联调探针：对着**真实运行中的房主**验证观众端链路。
//
// 不是常规单测（依赖本机有房主在开房），所以不放 test/ 目录，
// 默认 `flutter test` 不会跑到它。用法：
//   flutter test tool/party_live_probe.dart --plain-name "live" \
//     --dart-define=PARTY_BASE=http://127.0.0.1:9979 --dart-define=PARTY_CODE=8V6XUA
//
// 它做三件事：
//   1. 真的 join 一次，确认 /party 能被解析成 PartyState；
//   2. 连续轮询，确认 positionMs 随房主播放推进；
//   3. 用真实快照喂 decidePartyFollow，确认落后 / 超前都会给出 seek。
import 'package:flutter_test/flutter_test.dart';
import 'package:yingshi_tv/core/party/party_server.dart';
import 'package:yingshi_tv/core/party/party_sync.dart';
import 'package:yingshi_tv/core/party/watch_party_service.dart';

const _base = String.fromEnvironment(
  'PARTY_BASE',
  defaultValue: 'http://127.0.0.1:9979',
);
const _code = String.fromEnvironment('PARTY_CODE', defaultValue: '');

void main() {
  test('live: 观众端能从真实房主同步', () async {
    expect(_code, isNotEmpty, reason: '用 --dart-define=PARTY_CODE= 传房间码');

    final service = WatchPartyService(
      server: PartyServer(deviceName: () => 'probe'),
      deviceName: () => 'probe',
      pollInterval: const Duration(seconds: 1),
    );
    addTearDown(service.dispose);

    await service.join(baseUrl: _base, code: _code);
    expect(service.joined, isTrue);
    expect(service.remote, isNotNull, reason: '房主应已有状态');

    final first = service.remote!;
    // ignore: avoid_print
    print('首次快照: title=${first.title} ep=${first.episodeName} '
        'index=${first.episodeIndex} pos=${first.positionMs}ms '
        'playing=${first.playing} host=${service.hostName}');

    expect(first.title, isNotEmpty);
    expect(service.canFollow, isTrue);

    // 轮询 2 轮：房主播放中时 positionMs 应当往前走。
    final startPos = first.positionMs;
    await Future<void>.delayed(const Duration(seconds: 3));
    final second = service.remote!;
    // ignore: avoid_print
    print('3 秒后: pos=${second.positionMs}ms playing=${second.playing} '
        'compensation=${service.remoteCompensation.inMilliseconds}ms');

    if (first.playing && second.playing) {
      expect(second.positionMs, greaterThan(startPos),
          reason: '房主在播，快照位置应推进');
    }

    // 真实快照 + 三种本地状态，看决策是否符合预期。
    final remote = second;
    final comp = service.remoteCompensation;

    final behind = decidePartyFollow(
      remote: remote,
      localEpisodeIndex: remote.episodeIndex,
      localPosition: Duration(milliseconds: remote.positionMs - 10000),
      localPlaying: remote.playing,
      compensation: comp,
    );
    // ignore: avoid_print
    print('落后 10s -> ${behind.reason} seek=${behind.seekTo} '
        'playing=${behind.setPlaying}');
    expect(behind.seekTo, isNotNull, reason: '落后 10s 应 seek');

    final ahead = decidePartyFollow(
      remote: remote,
      localEpisodeIndex: remote.episodeIndex,
      localPosition: Duration(milliseconds: remote.positionMs + 10000),
      localPlaying: remote.playing,
      compensation: comp,
    );
    // ignore: avoid_print
    print('领先 10s -> ${ahead.reason} seek=${ahead.seekTo}');
    expect(ahead.seekTo, isNotNull, reason: '领先 10s 也应拉回');

    final same = decidePartyFollow(
      remote: remote,
      localEpisodeIndex: remote.episodeIndex,
      localPosition: Duration(
        milliseconds: remote.positionMs + (remote.playing ? comp.inMilliseconds : 0),
      ),
      localPlaying: remote.playing,
      compensation: comp,
    );
    // ignore: avoid_print
    print('已对齐 -> ${same.reason} idle=${same.isIdle}');
    expect(same.isIdle, isTrue, reason: '已对齐时不应有多余动作');

    final switched = decidePartyFollow(
      remote: remote,
      localEpisodeIndex: remote.episodeIndex + 1,
      localPosition: Duration.zero,
      localPlaying: false,
      compensation: comp,
    );
    // ignore: avoid_print
    print('集不同 -> ${switched.reason} switch=${switched.switchToEpisode} '
        'seek=${switched.seekTo} playing=${switched.setPlaying}');
    expect(switched.switchToEpisode, remote.episodeIndex);
    expect(switched.setPlaying, remote.playing, reason: '切集要带走播放状态');

    service.leave();
    expect(service.active, isFalse);
  }, timeout: const Timeout(Duration(seconds: 40)));
}
