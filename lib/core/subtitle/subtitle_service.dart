/// 多字幕源聚合入口：并行检索、单源失败隔离、下载路由。
///
/// 三个来源：
/// - assrt（需 token，中文影视覆盖最好）
/// - 自定义 API（用户自己写的 URL 模板）
/// - SubtitleCat（免 token 的公开网页源，网页改版就会失效）
library;

import 'dart:async';

import 'assrt_provider.dart';
import 'custom_provider.dart';
import 'subtitle_http.dart';
import 'subtitle_models.dart';
import 'subtitle_query.dart';
import 'subtitle_service_config.dart';
import 'subtitlecat_provider.dart';

/// 一次检索的结果：候选 + 各源的可读提示（失败原因 / 被跳过）。
class SubtitleSearchOutcome {
  const SubtitleSearchOutcome({
    required this.candidates,
    this.notes = const [],
    this.hasConfiguredSource = false,
  });

  final List<SubtitleCandidate> candidates;

  /// 例如「assrt：token 无效或已过期」「自定义接口「xx」不可达」。
  final List<String> notes;

  /// 是否至少配了 assrt / 自定义接口（否则只剩免 token 源兜底）。
  final bool hasConfiguredSource;

  static const SubtitleSearchOutcome empty = SubtitleSearchOutcome(
    candidates: [],
  );
}

/// 候选排序（稳定排序）：
///   ① 中文（简/繁/中英）优先；
///   ② 标题精确命中检索标题的优先；
///   ③ 其余保持各源返回顺序。
List<SubtitleCandidate> sortSubtitleCandidates(
  List<SubtitleCandidate> list,
  String title,
) {
  final want = title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
  int zhOf(SubtitleCandidate c) {
    final s = '${c.language} ${c.detail} ${c.subname}';
    return RegExp(r'简|繁|中文|中英|双语|zh', caseSensitive: false).hasMatch(s)
        ? 0
        : 1;
  }

  int exactOf(SubtitleCandidate c) {
    if (want.isEmpty) return 1;
    final t = c.title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    return t.isNotEmpty && t == want ? 0 : 1;
  }

  final rows = <({SubtitleCandidate c, int i, int zh, int exact})>[
    for (var i = 0; i < list.length; i++)
      (c: list[i], i: i, zh: zhOf(list[i]), exact: exactOf(list[i])),
  ]..sort((a, b) {
      final byZh = a.zh.compareTo(b.zh);
      if (byZh != 0) return byZh;
      final byExact = a.exact.compareTo(b.exact);
      if (byExact != 0) return byExact;
      return a.i.compareTo(b.i);
    });
  return rows.map((x) => x.c).toList();
}

class SubtitleService {
  SubtitleService({
    SubtitleHttp? http,
    this.config,
    this.timeout = const Duration(seconds: 15),
  }) : _http = http ?? SubtitleHttp(timeout: timeout);

  final SubtitleHttp _http;

  /// 显式配置（测试 / 一次性检索）；为空时读 [SubtitleServiceRuntime]。
  final SubtitleServiceConfig? config;
  final Duration timeout;

  SubtitleServiceConfig get _effective => config ?? SubtitleServiceRuntime.current;

  /// 并行检索；单源失败 / 超时只丢该源，整体不抛。
  Future<SubtitleSearchOutcome> search(SubtitleQuery query) async {
    if (query.isEmpty) return SubtitleSearchOutcome.empty;
    final ctx = _buildContext(query);
    if (ctx.keywords.isEmpty) return SubtitleSearchOutcome.empty;

    final config = _effective;
    final notes = <String>[];
    final pending = <Future<List<SubtitleCandidate>>>[];

    if (config.hasAssrt) {
      pending.add(_isolate(
        () => searchAssrt(
          http: _http,
          token: config.assrtToken.trim(),
          query: query,
          keywords: ctx.keywords,
        ).timeout(timeout),
        notes,
        'assrt',
      ));
    }
    for (final api in config.parsedCustomApis) {
      pending.add(_isolate(
        () => searchCustomSubtitleApi(_http, api, query).timeout(timeout),
        notes,
        '自定义接口「${api.name}」',
      ));
    }
    // 免 token 源始终参与：没填任何配置时它是唯一可用的来源。
    pending.add(_isolate(
      () => searchSubtitleCat(
        http: _http,
        query: query,
        keywords: ctx.keywords,
      ).timeout(timeout),
      notes,
      'SubtitleCat',
    ));

    final settled = await Future.wait(pending);
    final all = <SubtitleCandidate>[
      for (final list in settled) ...list,
    ];
    return SubtitleSearchOutcome(
      candidates: sortSubtitleCandidates(all, ctx.title),
      notes: List.unmodifiable(notes),
      hasConfiguredSource: config.isNotEmpty,
    );
  }

  /// 下载并解出真正的字幕字节；失败抛 [SubtitleException]（中文原因）。
  Future<SubtitleFile> download(
    SubtitleCandidate candidate, {
    String videoName = '',
    String ep = '',
  }) async {
    final config = _effective;
    if (candidate.providerId.startsWith('custom:')) {
      CustomSubtitleApi? api;
      for (final e in config.parsedCustomApis) {
        if (e.id == candidate.providerId) {
          api = e;
          break;
        }
      }
      if (api == null) {
        throw SubtitleException('自定义字幕接口已不存在：${candidate.providerName}');
      }
      return downloadCustomSubtitleApi(_http, api, candidate);
    }
    if (candidate.providerId == assrtProviderId) {
      final token = config.assrtToken.trim();
      if (token.isEmpty) {
        throw const SubtitleException(
          '尚未配置 assrt token，请先在「设置 → 字幕与弹幕」中填写',
        );
      }
      return assrtDownload(
        _http,
        token,
        candidate,
        videoName: videoName,
        ep: ep,
      );
    }
    if (candidate.providerId == catProviderId) {
      return fetchSubtitleCat(_http, candidate, ep: ep);
    }
    throw SubtitleException('未知的字幕源：${candidate.providerId}');
  }

  Future<List<SubtitleCandidate>> _isolate(
    Future<List<SubtitleCandidate>> Function() run,
    List<String> notes,
    String label,
  ) async {
    try {
      return await run();
    } on SubtitleException catch (e) {
      notes.add('$label：${e.message}');
      return const <SubtitleCandidate>[];
    } on TimeoutException {
      notes.add('$label：检索超时');
      return const <SubtitleCandidate>[];
    } catch (_) {
      notes.add('$label：不可达或返回异常');
      return const <SubtitleCandidate>[];
    }
  }
}

/// 由公开查询构造内部检索上下文（标题 / 集号 / 关键词候选）。
({String title, String ep, List<String> keywords}) _buildContext(
  SubtitleQuery query,
) {
  final source = query.title.trim().isNotEmpty ? query.title : query.rawName;
  var title = normalizeTitle(source);
  if (title.isEmpty) title = source.trim();
  final ep = query.episode == null
      ? extractEp(query.rawName.isNotEmpty ? query.rawName : source)
      : query.episode.toString();

  final keywords = <String>[];
  void add(String value) {
    final t = value.trim();
    if (t.isNotEmpty && !keywords.contains(t)) keywords.add(t);
  }

  final variants = titleVariants(title);
  for (final v in variants) {
    add(v);
  }
  if (query.title.trim().isNotEmpty && query.rawName.trim().isNotEmpty) {
    final fromRaw = normalizeTitle(query.rawName);
    if (fromRaw.isNotEmpty && fromRaw != title) {
      for (final v in titleVariants(fromRaw)) {
        add(v);
      }
    }
  }
  if (ep.isNotEmpty) {
    add('$title $ep');
    for (final v in variants) {
      add('$v $ep');
    }
  }
  return (title: title, ep: ep, keywords: keywords.take(6).toList());
}
