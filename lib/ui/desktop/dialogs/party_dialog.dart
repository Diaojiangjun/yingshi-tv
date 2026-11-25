import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/party/watch_party_service.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import 'app_dialog.dart';

/// 打开「一起看」面板。
///
/// 入口只在播放页出现（房主必须正在播，观众也必须在播放页才对得上进度），
/// 所以这里不做任何「未在播放」的兜底文案。
Future<void> showPartyDialog(BuildContext context, WatchPartyService service) {
  return showAppDialog<void>(
    context: context,
    barrierLabel: '关闭一起看',
    builder: (_) => PartyDialog(service: service),
  );
}

class PartyDialog extends StatefulWidget {
  const PartyDialog({super.key, required this.service});

  final WatchPartyService service;

  @override
  State<PartyDialog> createState() => _PartyDialogState();
}

class _PartyDialogState extends State<PartyDialog> {
  final TextEditingController _address = TextEditingController();
  final TextEditingController _code = TextEditingController();

  bool _joining = false;
  bool _starting = false;
  bool _showJoinForm = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 「加入」按钮的可用性依赖地址输入，输入时要重建一次。
    _address.addListener(_onFieldChanged);
  }

  void _onFieldChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _address.removeListener(_onFieldChanged);
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _startHost() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      await widget.service.startHost();
    } catch (e) {
      if (mounted) setState(() => _error = '创建房间失败：$e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _join() async {
    if (_joining) return;
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      await widget.service.join(
        baseUrl: _address.text,
        code: _code.text,
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  void _leave() {
    widget.service.leave();
    Navigator.of(context).pop();
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('已复制'), duration: Duration(seconds: 2)),
    );
  }

  InputDecoration _decoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: context.palette.textDim),
        filled: true,
        fillColor: context.palette.raised,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
          borderSide: BorderSide(color: context.palette.borderStrong),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      );

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) {
        final service = widget.service;
        return AlertDialog(
          backgroundColor: context.palette.raised,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.lg)),
          title: Text(
            service.hosting
                ? '一起看 · 房主'
                : service.joined
                    ? '一起看 · 观众'
                    : '一起看',
            style: TextStyle(
              fontSize: AppType.heading,
              color: context.palette.textTitle,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SizedBox(
            width: 440,
            child: service.active
                ? _buildRoom(context, service)
                : _buildChooser(context),
          ),
          actions: service.active
              ? [
                  TextButton(
                    onPressed: _leave,
                    child: Text('退出房间',
                        style: TextStyle(color: context.palette.danger)),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: context.palette.accent,
                      foregroundColor: Theme.of(context).colorScheme.onPrimary,
                      shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppRadii.sm)),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('开始看',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ]
              : [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text('关闭',
                        style: TextStyle(color: context.palette.textSub)),
                  ),
                ],
        );
      },
    );
  }

  Widget _buildChooser(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '同一 Wi-Fi 下同步追剧：房主控制进度，其他人自动跟随。'
          '双方需要打开同一部片子，各自用自己的线路播放。',
          style: TextStyle(
              fontSize: AppType.label,
              height: 1.5,
              color: context.palette.textBody),
        ),
        const SizedBox(height: 14),
        _ActionTile(
          icon: Icons.add_rounded,
          title: '创建房间',
          subtitle: '本机作为房主，生成 6 位房间码',
          busy: _starting,
          onTap: _startHost,
        ),
        const SizedBox(height: 8),
        _ActionTile(
          icon: Icons.login_rounded,
          title: '加入房间',
          subtitle: '输入房主地址与房间码',
          busy: false,
          onTap: () => setState(() {
            _showJoinForm = true;
            _error = null;
          }),
        ),
        if (_showJoinForm) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _address,
            autofocus: true,
            style: TextStyle(
                fontSize: AppType.label, color: context.palette.textMain),
            decoration: _decoration('房主地址，例如 192.168.1.10:9979'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            style: TextStyle(
                fontSize: AppType.label, color: context.palette.textMain),
            decoration: _decoration('房间码，6 位字母数字'),
            onSubmitted: (_) => _join(),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: context.palette.accent,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.sm)),
                ),
                onPressed: _joining ? null : _join,
                child: const Text('加入',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!,
              key: const ValueKey('party-error'),
              style:
                  TextStyle(fontSize: AppType.body, color: context.palette.danger)),
        ],
      ],
    );
  }

  Widget _buildRoom(BuildContext context, WatchPartyService service) {
    final remote = service.remote;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('房间码',
                style: TextStyle(
                    fontSize: AppType.label, color: context.palette.textSub)),
            const SizedBox(width: 12),
            SelectableText(
              service.roomCode,
              style: TextStyle(
                fontSize: 26,
                letterSpacing: 4,
                fontWeight: FontWeight.bold,
                color: context.palette.textTitle,
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: '复制房间码',
              onPressed: () => _copy(service.roomCode),
              icon: Icon(Icons.copy_rounded,
                  size: 18, color: context.palette.textSub),
            ),
          ],
        ),
        if (service.hosting) ...[
          const SizedBox(height: 4),
          Text('把下面的地址和房间码发给朋友',
              style: TextStyle(
                  fontSize: AppType.body, color: context.palette.textSub)),
          const SizedBox(height: 8),
          for (final url in service.hostAddresses)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      url.replaceFirst('http://', ''),
                      style: TextStyle(
                          fontSize: AppType.label,
                          color: context.palette.textMain),
                    ),
                  ),
                  IconButton(
                    tooltip: '复制地址',
                    onPressed: () =>
                        _copy(url.replaceFirst('http://', '')),
                    icon: Icon(Icons.copy_rounded,
                        size: 16, color: context.palette.textSub),
                  ),
                ],
              ),
            ),
          // 预告片 / 直播这类没有剧集会话的内容不会发布状态，
          // 让房主知道「现在连上了也不会有进度」比事后被问更有用。
          if (service.lastPublished == null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '开始播放后自动同步（预告片、直播暂不支持一起看）',
                key: const ValueKey('party-host-waiting'),
                style: TextStyle(
                    fontSize: AppType.caption, color: context.palette.textDim),
              ),
            ),
        ] else ...[
          const SizedBox(height: 4),
          Text(
            '房主：${service.hostName.isEmpty ? service.hostUrl : service.hostName}',
            style: TextStyle(
                fontSize: AppType.label, color: context.palette.textMain),
          ),
          if (remote != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '正在看：${remote.title}'
                '${remote.episodeName.isEmpty ? '' : ' · ${remote.episodeName}'}',
                style: TextStyle(
                    fontSize: AppType.label, color: context.palette.textBody),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '已连上房主，等待房主开始播放…',
                key: const ValueKey('party-guest-waiting'),
                style: TextStyle(
                    fontSize: AppType.caption, color: context.palette.textDim),
              ),
            ),
        ],
        if (service.lastError.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              service.lastError,
              key: const ValueKey('party-room-error'),
              style:
                  TextStyle(fontSize: AppType.body, color: context.palette.danger),
            ),
          ),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.busy,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(AppRadii.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: context.palette.card,
          borderRadius: BorderRadius.circular(AppRadii.sm),
          border: Border.all(color: context.palette.border),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: context.palette.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: AppType.label,
                          fontWeight: FontWeight.bold,
                          color: context.palette.textTitle)),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: AppType.caption,
                          color: context.palette.textSub)),
                ],
              ),
            ),
            if (busy)
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: context.palette.textDim),
          ],
        ),
      ),
    );
  }
}
