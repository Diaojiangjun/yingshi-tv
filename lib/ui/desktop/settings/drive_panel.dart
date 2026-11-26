part of 'settings_page.dart';

/// 设置 → 网盘：账号（扫码 / 手动 Cookie）+ WebDAV 服务器。
///
/// 凭据只保存在本机（DPAPI 加密），用于校验登录态与后续的分享链接解析；
/// 面板本身不发任何网络请求，除了用户点「检测」「扫码」时。
class DriveSettingsPanel extends StatefulWidget {
  const DriveSettingsPanel({
    super.key,
    required this.repository,
    this.onPlayMedia,
  });

  final DriveAccountRepository repository;

  /// WebDAV 里选中媒体后的播放回调；缺省只浏览不播放。
  final Future<void> Function(MediaPlaySpec spec)? onPlayMedia;

  @override
  State<DriveSettingsPanel> createState() => _DriveSettingsPanelState();
}

class _DriveSettingsPanelState extends State<DriveSettingsPanel> {
  List<WebDavProfile> _webDavProfiles = const <WebDavProfile>[];
  bool _webDavReadable = true;

  @override
  void initState() {
    super.initState();
    widget.repository.addListener(_onAccountsChanged);
    unawaited(widget.repository.ensureLoaded());
    unawaited(_readWebDavProfiles());
  }

  @override
  void dispose() {
    widget.repository.removeListener(_onAccountsChanged);
    super.dispose();
  }

  void _onAccountsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _readWebDavProfiles() async {
    try {
      final profiles = await WebDavProfileStore().read();
      if (mounted) setState(() => _webDavProfiles = profiles);
    } catch (_) {
      if (mounted) {
        setState(() {
          _webDavReadable = false;
          _webDavProfiles = const <WebDavProfile>[];
        });
      }
    }
  }

  Future<void> _openWebDav() async {
    final spec = await showAppDialog<MediaPlaySpec>(
      context: context,
      builder: (_) => const WebDavBrowserDialog(),
    );
    await _readWebDavProfiles();
    if (spec == null || !mounted) return;
    final play = widget.onPlayMedia;
    if (play == null) {
      showAppMessage('已选中：${spec.title ?? spec.url}');
      return;
    }
    await play(spec);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return _PanelScaffold(
      title: '网盘与 WebDAV',
      subtitle: '登录态只保存在本机（系统加密），用于校验账号与解析网盘分享链接。',
      children: [
        if (widget.repository.error != null) ...[
          _DriveNotice(
            icon: Icons.error_outline_rounded,
            color: palette.danger,
            text: widget.repository.error!,
          ),
          const SizedBox(height: 12),
        ],
        DriveAccountsPanel(repository: widget.repository),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(color: palette.border),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
            leading: Icon(
              Icons.folder_open_rounded,
              size: 20,
              color: palette.accentInk,
            ),
            title: Text(
              'WebDAV',
              style: TextStyle(
                fontSize: AppType.label,
                fontWeight: FontWeight.w600,
                color: palette.textTitle,
              ),
            ),
            subtitle: Text(
              _webDavReadable
                  ? '${_webDavProfiles.length} 个已保存服务器 · 浏览并按需播放'
                  : '已保存的连接无法读取，可重新添加',
              style: TextStyle(
                fontSize: AppType.caption,
                color: palette.textSub,
              ),
            ),
            trailing: OutlinedButton(
              key: const ValueKey('settings-webdav-open'),
              style: _outlinedStyle(context),
              onPressed: _openWebDav,
              child: const Text('管理 / 浏览'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '扫码登录使用系统 WebView2 打开网盘官方登录页，登录成功后自动读取 Cookie。'
          '手动粘贴适用于需要短信验证、或扫码页打不开的情况。'
          '凭据不会上传到任何服务器，也不会写入日志；退出应用后仍然保留，'
          '可在对应网盘上点「清除」删除。',
          style: TextStyle(
            fontSize: AppType.caption,
            color: palette.textSub,
            height: 1.6,
          ),
        ),
      ],
    );
  }
}

class _DriveNotice extends StatelessWidget {
  const _DriveNotice({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: AppType.caption,
                color: color,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
