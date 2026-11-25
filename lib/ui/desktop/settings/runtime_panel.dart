part of 'settings_page.dart';

/// 设置 → 运行时：把体积大、只在特定源类型下才用到的运行时改成按需下载。
///
/// 背景：JRE 之前由 `build_windows.ps1` 打进发布包（minimal JRE ~40 MB），
/// 但只有 `csp_` / dex 蜘蛛源才需要它——绝大多数用户的安装包为此多背了 40 MB。
/// 现在组件下载到 `%APPDATA%/YingshiTV/runtime/<组件>`，与
/// `CompanionProcessManager.javaCandidates` 的 AppData 候选项一致，
/// 装完即被伴随服务识别，不需要额外写配置。
class RuntimeSettingsPanel extends StatelessWidget {
  const RuntimeSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return _PanelScaffold(
      title: '运行时',
      subtitle: '按需下载，不再随安装包分发。卸载或换机后可随时重新下载。',
      children: [
        Container(
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(color: palette.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: Row(
                  children: [
                    Icon(Icons.memory_rounded,
                        size: 18, color: palette.accentInk),
                    const SizedBox(width: 8),
                    Text('运行时组件',
                        style: TextStyle(
                            fontSize: AppType.label,
                            fontWeight: FontWeight.w600,
                            color: palette.textTitle)),
                    const Spacer(),
                    Text('JVM',
                        style: TextStyle(
                            fontSize: AppType.caption,
                            color: palette.textSub)),
                  ],
                ),
              ),
              Divider(height: 1, color: palette.divider),
              for (var i = 0; i < runtimeComponents.length; i++) ...[
                if (i > 0) Divider(height: 1, color: palette.divider),
                _RuntimeComponentTile(component: runtimeComponents[i]),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '加固壳解密库（lib-unidbg）仍随主程序提供：它是原生库、体量小，'
          '缺失时加固站点会直接不可用。装好上面任意一项后，解析层优先使用应用'
          '自带的那份——本机卸掉 Java / Python / Node / PHP 都不影响播放。',
          style: TextStyle(
              fontSize: AppType.caption,
              color: palette.textSub,
              height: 1.6),
        ),
      ],
    );
  }
}

class _RuntimeComponentTile extends StatefulWidget {
  final RuntimeComponent component;

  const _RuntimeComponentTile({required this.component});

  @override
  State<_RuntimeComponentTile> createState() => _RuntimeComponentTileState();
}

class _RuntimeComponentTileState extends State<_RuntimeComponentTile> {
  final RuntimeInstaller _installer = RuntimeInstaller.instance;

  RuntimeStatus? _status;

  /// 本机已有、可被伴随服务复用的 JVM。非空时「未安装」的结论是错的——
  /// 站点其实能跑，只是没用应用下载的那份。
  ExternalRuntime? _externalRuntime;

  RuntimeProgress? _progress;
  bool _busy = false;
  bool _loading = true;
  String? _error;

  RuntimeComponent get _component => widget.component;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final status = await _installer.status(_component);
    // 已装/随包时不必再 spawn java -version；只有两者都没有时才去问系统。
    final external = status.usable ? null : await _installer.externalRuntime(_component);
    if (!mounted) return;
    setState(() {
      _status = status;
      _externalRuntime = external;
      _loading = false;
    });
  }

  Future<void> _install() async {
    if (_busy) return;
    // 下载只改变「下一次启动用哪份 JVM」：正在运行的伴随服务已经握着自己的
    // java 进程，不会因为文件就位就切过去。
    final wasUsingExternal = _externalRuntime != null;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _installer.install(
        _component,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      await _refresh();
      if (!mounted) return;
      final manager = CompanionProcessManager();
      if (wasUsingExternal && manager.isRunning) {
        showAppMessage(
          '${_component.name}已就绪，重启解析服务后生效',
          type: AppMessageType.success,
          duration: const Duration(seconds: 8),
          action: AppMessageAction(
            label: '重启服务',
            onPressed: () => unawaited(manager.restart()),
          ),
        );
        return;
      }
      showAppMessage('${_component.name}已就绪', type: AppMessageType.success);
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _remove() async {
    if (_busy) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.palette.card,
        title: Text('删除${_component.name}？',
            style: TextStyle(
                color: context.palette.textTitle, fontSize: AppType.heading)),
        content: Text(
          '只会删除本机下载的运行时文件，不影响配置源、播放历史与收藏。'
          '使用 .jar 蜘蛛源的站点在重新下载前将不可用。',
          style: TextStyle(
              color: context.palette.textBody,
              fontSize: AppType.label,
              height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: context.palette.textSub)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: context.palette.danger,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadii.sm)),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _installer.remove(_component);
      await _refresh();
      if (mounted) showAppMessage('已删除${_component.name}');
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final status = _status;
    final installed = status?.downloaded ?? false;
    final bundled = status?.bundledPath != null;
    final external = _externalRuntime;
    final progress = _progress;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: palette.accentWash,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(Icons.developer_board_rounded,
                    size: 20, color: palette.accentInk),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(_component.name,
                            style: TextStyle(
                                fontSize: AppType.label,
                                fontWeight: FontWeight.w600,
                                color: palette.textTitle)),
                        const SizedBox(width: 8),
                        _RuntimeBadge(
                          text: installed
                              ? '已安装'
                              : bundled
                                  ? '随程序提供'
                                  : external != null
                                      ? '使用系统运行时'
                                      : '未安装',
                          highlight: installed || (external != null && !bundled),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _describe(installed: installed, bundled: bundled, external: external),
                      style: TextStyle(
                          fontSize: AppType.caption,
                          color: palette.textSub,
                          height: 1.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _buildAction(context,
                  installed: installed, bundled: bundled, external: external),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.sm),
              child: LinearProgressIndicator(
                value: progress.value <= 0 || progress.value >= 1
                    ? null
                    : progress.value,
                minHeight: 4,
                backgroundColor: palette.raised,
                valueColor: AlwaysStoppedAnimation<Color>(palette.accentInk),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(progress.message,
                      style: TextStyle(
                          fontSize: AppType.caption, color: palette.textSub)),
                ),
                if (_busy && progress.value > 0 && progress.value < 1)
                  Text('${(progress.value * 100).round()}%',
                      style: TextStyle(
                          fontSize: AppType.caption,
                          color: palette.textSub,
                          fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: TextStyle(fontSize: AppType.caption, color: palette.danger)),
          ],
        ],
      ),
    );
  }

  /// 组件对应的语言名，用于「当前用 PATH 里的 Node 22.22.2」这类文案。
  String get _noun {
    switch (_component.id) {
      case 'jvm':
        return 'Java';
      case 'node':
        return 'Node';
      case 'python':
        return 'Python';
      case 'php':
        return 'PHP';
      default:
        return _component.name;
    }
  }

  /// 一行说清「现在凭什么能用」——这是本页最容易误导人的地方：
  /// 只查应用目录会把「有系统 JDK、dex 源正常」显示成「未安装」。
  String _describe({
    required bool installed,
    required bool bundled,
    ExternalRuntime? external,
  }) {
    final noun = _noun;
    if (installed && _status?.version != null) {
      return '已安装 ${_status!.version}，优先使用应用自带的版本，不再依赖本机 $noun';
    }
    if (bundled) return '随程序提供，使用包内版本，不依赖本机 $noun';
    if (external != null) {
      return '当前用 ${external.source} 里的 $noun ${external.versionLabel}'
          '（${external.displayPath}）运行对应源，不下载也能用；'
          '该运行时被移除或降级后需回来下载（${_component.sizeLabel}）';
    }
    return '${_component.summary}（${_component.sizeLabel}）';
  }

  Widget _buildAction(BuildContext context,
      {required bool installed,
      required bool bundled,
      ExternalRuntime? external}) {
    final palette = context.palette;
    if (_loading) {
      return const SizedBox(
        width: 76,
        height: 36,
        child: Center(
            child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    if (bundled && !installed) {
      return SizedBox(
        width: 96,
        child: Text('已随程序提供',
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: AppType.caption, color: palette.textSub)),
      );
    }
    if (installed) {
      return TextButton(
        onPressed: _busy ? null : _remove,
        style: TextButton.styleFrom(
          foregroundColor: palette.textSub,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: const TextStyle(fontSize: AppType.label),
        ),
        child: const Text('删除'),
      );
    }
    // 系统 JVM 已经够用时，下载是「可选加固」而不是「必须修复」，
    // 用次级按钮，避免用户以为不点就用不了。
    if (external != null) {
      return TextButton(
        onPressed: _busy ? null : _install,
        style: TextButton.styleFrom(
          foregroundColor: palette.accentInk,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: const TextStyle(fontSize: AppType.label),
        ),
        child: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('下载独立版'),
      );
    }
    return ElevatedButton(
      onPressed: _busy ? null : _install,
      style: _primaryStyle(context),
      child: _busy
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Theme.of(context).colorScheme.onPrimary),
            )
          : const Text('下载'),
    );
  }
}

class _RuntimeBadge extends StatelessWidget {
  final String text;
  final bool highlight;

  const _RuntimeBadge({required this.text, required this.highlight});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: highlight ? palette.accentWash : palette.raised,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: AppType.caption,
              color: highlight ? palette.accentInk : palette.textSub)),
    );
  }
}
