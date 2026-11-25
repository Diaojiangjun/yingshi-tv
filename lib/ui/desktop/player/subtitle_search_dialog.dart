import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/subtitle/subtitle_models.dart';
import '../../../core/subtitle/subtitle_query.dart';
import '../../../core/subtitle/subtitle_service.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import '../dialogs/app_dialog.dart';

/// 播放页「搜索在线字幕」：按关键词聚合检索 assrt / 自定义接口 / SubtitleCat，
/// 选中一条即下载并挂到当前播放器上。
///
/// 与弹幕搜索的区别：字幕必须**下载完整文本**再交给 mpv（弹幕是服务端
/// 直接回列表），所以这里点一行是「下载 → 落临时文件 → sub-add」的完整链路。
Future<void> showSubtitleSearchDialog({
  required BuildContext context,
  required SubtitleQuery query,
  required Future<bool> Function(SubtitleFile file) onApply,
  SubtitleService? service,
}) =>
    showAppDialog<void>(
      context: context,
      barrierLabel: '关闭字幕搜索',
      builder: (_) => SubtitleSearchDialog(
        query: query,
        onApply: onApply,
        service: service,
      ),
    );

class SubtitleSearchDialog extends StatefulWidget {
  const SubtitleSearchDialog({
    super.key,
    required this.query,
    required this.onApply,
    this.service,
  });

  final SubtitleQuery query;

  /// 应用到播放器：返回 true 表示已挂上，弹窗随即可关闭。
  final Future<bool> Function(SubtitleFile file) onApply;

  /// 测试注入；缺省按运行时配置现建。
  final SubtitleService? service;

  @override
  State<SubtitleSearchDialog> createState() => _SubtitleSearchDialogState();
}

class _SubtitleSearchDialogState extends State<SubtitleSearchDialog> {
  late final TextEditingController _keyword;
  late final SubtitleService _service;

  SubtitleSearchOutcome? _outcome;
  bool _searching = false;
  String? _error;

  /// 正在下载的候选（只锁这一行）。
  String? _applyingId;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? SubtitleService();
    final text = buildSearchQuery(
      widget.query.title.trim().isNotEmpty
          ? widget.query.title
          : widget.query.rawName,
    );
    _keyword = TextEditingController(text: text)
      ..selection = TextSelection(baseOffset: 0, extentOffset: text.length);
    // 打开即搜一次：多数情况下列表第一条就是对的
    _searching = true;
    unawaited(_runSearch(text.trim()));
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  /// 用检索框内容换标题：集号仍沿用当前播放信息，用户只改片名。
  SubtitleQuery _queryFor(String keyword) => SubtitleQuery(
        title: keyword,
        year: widget.query.year,
        season: widget.query.season,
        episode: widget.query.episode,
        rawName: widget.query.rawName,
      );

  Future<void> _runSearch(String keyword) async {
    try {
      final outcome = await _service.search(_queryFor(keyword));
      if (!mounted || _keyword.text.trim() != keyword) return;
      setState(() {
        _searching = false;
        _outcome = outcome;
        _error = null;
      });
    } on SubtitleException catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _outcome = null;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _outcome = null;
        _error = '字幕检索失败，请检查网络或换一个关键词';
      });
    }
  }

  void _submit() {
    final keyword = _keyword.text.trim();
    if (keyword.isEmpty) {
      setState(() {
        _searching = false;
        _outcome = null;
        _error = '请输入片名';
      });
      return;
    }
    setState(() {
      _searching = true;
      _outcome = null;
      _error = null;
    });
    unawaited(_runSearch(keyword));
  }

  Future<void> _apply(SubtitleCandidate candidate) async {
    if (_applyingId != null) return;
    setState(() {
      _applyingId = candidate.id;
      _error = null;
    });
    try {
      final file = await _service.download(
        candidate,
        videoName: candidate.videoName.isNotEmpty
            ? candidate.videoName
            : candidate.subname,
        ep: candidate.episodeHint,
      );
      final applied = await widget.onApply(file);
      if (!mounted) return;
      if (applied) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _applyingId = null;
        _error = '字幕已下载，但播放器未能加载它（可能格式不受支持）';
      });
    } on SubtitleException catch (e) {
      if (!mounted) return;
      setState(() {
        _applyingId = null;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _applyingId = null;
        _error = '字幕下载失败，请换一条候选再试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Dialog(
      backgroundColor: palette.panel,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        side: BorderSide(color: palette.borderStrong),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(palette),
              const SizedBox(height: 14),
              _buildSearchRow(palette),
              const SizedBox(height: 4),
              SizedBox(
                height: 2,
                child: _searching ? const LinearProgressIndicator() : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  key: const ValueKey('subtitle-search-error'),
                  style:
                      TextStyle(color: palette.danger, fontSize: AppType.label),
                ),
              ],
              const SizedBox(height: 10),
              Flexible(
                child: SizedBox(height: 320, child: _buildResultArea(palette)),
              ),
              const SizedBox(height: 6),
              _buildFooter(palette),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(AppPalette palette) {
    final title = widget.query.title.trim().isNotEmpty
        ? widget.query.title
        : widget.query.rawName;
    final subtitle = [
      if (title.trim().isNotEmpty) title.trim(),
      if (widget.query.episode != null) '第 ${widget.query.episode} 集',
      '字幕保存在本机临时目录',
    ].join(' · ');
    return Row(children: [
      Icon(Icons.subtitles_rounded, color: palette.accentInk, size: 24),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '搜索在线字幕',
              style: TextStyle(
                  fontSize: AppType.h2,
                  fontWeight: FontWeight.bold,
                  color: palette.textTitle),
            ),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: AppType.caption, color: palette.textSub),
            ),
          ],
        ),
      ),
      IconButton(
        tooltip: '关闭字幕搜索',
        onPressed: () => Navigator.of(context).pop(),
        icon: Icon(Icons.close_rounded, color: palette.textSub),
      ),
    ]);
  }

  Widget _buildSearchRow(AppPalette palette) {
    return Row(children: [
      Expanded(
        child: TextField(
          key: const ValueKey('subtitle-search-field'),
          controller: _keyword,
          autofocus: true,
          textInputAction: TextInputAction.search,
          enabled: !_searching,
          onSubmitted: (_) => _submit(),
          style: TextStyle(color: palette.textMain, fontSize: AppType.label),
          decoration: InputDecoration(
            hintText: '输入片名（可带集号），回车搜索',
            prefixIcon:
                Icon(Icons.search_rounded, color: palette.textSub, size: 20),
            hintStyle: TextStyle(color: palette.textDim, fontSize: AppType.body),
            filled: true,
            fillColor: palette.raised,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadii.md)),
          ),
        ),
      ),
      const SizedBox(width: 10),
      FilledButton.icon(
        key: const ValueKey('subtitle-search-submit'),
        style: FilledButton.styleFrom(backgroundColor: palette.accent),
        onPressed: _searching ? null : _submit,
        icon: const Icon(Icons.search_rounded, size: 18),
        label: const Text('搜索'),
      ),
    ]);
  }

  Widget _buildResultArea(AppPalette palette) {
    final outcome = _outcome;
    if (_searching && outcome == null) {
      return Center(
        child: Text(
          '正在检索「${_keyword.text.trim()}」…',
          style: TextStyle(color: palette.textSub, fontSize: AppType.label),
        ),
      );
    }
    if (outcome == null) {
      return Center(
        child: Text(
          _error == null ? '输入片名后点「搜索」' : '检索失败，可以改关键词再试',
          textAlign: TextAlign.center,
          style: TextStyle(color: palette.textSub, fontSize: AppType.label),
        ),
      );
    }
    if (outcome.candidates.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded, color: palette.textDim, size: 32),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                _emptyMessage(outcome),
                key: const ValueKey('subtitle-search-empty'),
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textSub, fontSize: AppType.label),
              ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      key: const ValueKey('subtitle-search-results'),
      padding: EdgeInsets.zero,
      itemCount: outcome.candidates.length,
      separatorBuilder: (_, __) => Divider(height: 1, color: palette.divider),
      itemBuilder: (_, index) =>
          _buildRow(palette, outcome.candidates[index], index),
    );
  }

  String _emptyMessage(SubtitleSearchOutcome outcome) {
    if (!outcome.hasConfiguredSource) {
      return '没有找到字幕。当前只用了免 token 的公开源，'
          '可以到「设置 → 字幕与弹幕」填 assrt token 或自定义字幕 API 后再试。';
    }
    if (outcome.notes.isNotEmpty) {
      return '没有找到字幕。\n${outcome.notes.join('\n')}';
    }
    return '没有找到字幕，可以改片名（比如只留主标题）再搜一次。';
  }

  Widget _buildRow(AppPalette palette, SubtitleCandidate item, int index) {
    final applying = _applyingId == item.id;
    final summary = item.summary;
    return ListTile(
      key: ValueKey('subtitle-search-row-$index'),
      dense: true,
      enabled: _applyingId == null,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      onTap: _applyingId == null ? () => unawaited(_apply(item)) : null,
      leading: Icon(Icons.subtitles_rounded, size: 18, color: palette.textDim),
      title: Tooltip(
        message: item.title,
        waitDuration: const Duration(milliseconds: 600),
        child: Row(children: [
          Flexible(
            child: Text(
              item.title.isEmpty ? item.providerName : item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: palette.textMain,
                  fontSize: AppType.label,
                  fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          _buildTag(palette, item.providerName),
        ]),
      ),
      subtitle: summary.isEmpty
          ? null
          : Text(
              summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.textSub, fontSize: AppType.caption),
            ),
      trailing: applying
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.download_rounded, size: 18, color: palette.textDim),
    );
  }

  Widget _buildTag(AppPalette palette, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: palette.accentWash,
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
      child: Text(
        text,
        style: TextStyle(color: palette.accentInk, fontSize: AppType.micro),
      ),
    );
  }

  Widget _buildFooter(AppPalette palette) {
    final outcome = _outcome;
    final hint = _applyingId != null
        ? '正在下载并加载字幕…'
        : (outcome != null && outcome.candidates.isNotEmpty
            ? '共 ${outcome.candidates.length} 条候选，选中一条即下载并立即生效'
            : 'assrt 需要 token；自定义接口可用 {title} {episode} 占位符');
    return Row(children: [
      Expanded(
        child: Text(
          hint,
          maxLines: 2,
          style: TextStyle(color: palette.textDim, fontSize: AppType.caption),
        ),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('关闭'),
      ),
    ]);
  }
}
