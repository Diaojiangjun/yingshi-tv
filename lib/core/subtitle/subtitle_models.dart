/// 外挂字幕的数据模型（检索条件 / 候选 / 下载结果）。
///
/// 只服务「在线字幕搜索」这一条链路：播放器原生轨道、站源自带字幕
/// 走的是 `core/player/source_subtitle.dart`，两套互不替代。
library;

/// 检索条件。
class SubtitleQuery {
  const SubtitleQuery({
    required this.title,
    this.year,
    this.season,
    this.episode,
    this.rawName = '',
  });

  /// 剧名（详情页片名，可含副名）。
  final String title;

  final int? year;
  final int? season;
  final int? episode;

  /// 资源文件名（可选；用来补集号 / 兜底剧名）。
  final String rawName;

  bool get isEmpty => title.trim().isEmpty && rawName.trim().isEmpty;

  @override
  String toString() => 'SubtitleQuery($title, year=$year, season=$season, '
      'episode=$episode, raw=$rawName)';
}

/// 一个字幕候选。
class SubtitleCandidate {
  const SubtitleCandidate({
    required this.providerId,
    required this.providerName,
    required this.id,
    required this.title,
    required this.language,
    required this.format,
    required this.downloadUrl,
    this.subname = '',
    this.detail = '',
    this.videoName = '',
    this.episodeHint = '',
  });

  /// `assrt` / `subtitlecat` / `custom:<n>`
  final String providerId;
  final String providerName;

  /// provider 内唯一 id / 下载 key。
  final String id;

  final String title;
  final String language;

  /// srt / ass / ssa / vtt / zip …（未知为空串）
  final String format;

  /// 可直接下载的地址；assrt 搜索阶段为空（下载时再取 detail）。
  final String downloadUrl;

  /// 片源 / 视频文件名（用于压缩包内挑条目）。
  final String subname;

  /// 备注（体积 / 下载量等）。
  final String detail;

  /// 更精确的视频名提示（SubtitleCat 用行名）。
  final String videoName;

  /// 集号提示（下载时挑包内条目）。
  final String episodeHint;

  /// 列表里显示的一行附加信息：语言 · 格式 · 备注。
  String get summary => [
        if (language.trim().isNotEmpty) language.trim(),
        if (format.trim().isNotEmpty) format.trim().toUpperCase(),
        if (detail.trim().isNotEmpty) detail.trim(),
      ].join(' · ');
}

/// 下载并解出后的字幕文件。
///
/// 保留**原始字节**而不是解码后的字符串：ASS 的样式与 GBK 编码字幕
/// 交给 mpv / libass 自己识别，Dart 侧再做一次转码只会丢信息。
class SubtitleFile {
  const SubtitleFile({
    required this.name,
    required this.format,
    required this.bytes,
  });

  /// 真实字幕文件名（含扩展名）。
  final String name;

  /// 规范化格式：srt / ass / ssa / vtt / sub；未知为空串。
  final String format;

  final List<int> bytes;

  /// 落盘用的文件名。
  ///
  /// 本地字幕校验只放行 srt / ass / ssa / vtt，所以 `.sub`（MicroDVD）、
  /// `.txt` 或没有扩展名的一律补成 `.srt`：mpv 的 `sub-add` 按内容嗅探，
  /// 不看扩展名，不会因此解析错。
  String get fileName {
    final lower = name.toLowerCase();
    for (final ext in const ['srt', 'ass', 'ssa', 'vtt']) {
      if (lower.endsWith('.$ext')) return name;
    }
    return format == 'ass' || format == 'ssa' || format == 'vtt'
        ? 'subtitle.$format'
        : 'subtitle.srt';
  }
}

/// 字幕服务可读异常（消息直接面向用户）。
class SubtitleException implements Exception {
  const SubtitleException(this.message);

  final String message;

  @override
  String toString() => message;
}
