import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 老板键注册结果。
///
/// [hotkey] 是**实际生效**的组合键：首选 Ctrl + Alt + Y 被占用时会依次回退到
/// 更冷门的组合，所以界面上要显示它，而不是写死首选值。
/// [error] 是最后一次 Win32 `GetLastError`（1409 表示已被其他程序占用）。
class BossKeyRegistration {
  final bool registered;
  final String hotkey;
  final int error;

  const BossKeyRegistration({
    required this.registered,
    this.hotkey = '',
    this.error = 0,
  });

  /// 当前环境没有原生实现（单元测试 / 非 Windows 宿主）。
  static const BossKeyRegistration unavailable =
      BossKeyRegistration(registered: false, error: -1);
}

/// Windows 桌面外壳能力：系统托盘、老板键、播放时阻止系统休眠。
///
/// 这三项都落在原生侧（见 `windows/runner/desktop_shell_agent.*`），
/// 这里只做通道封装：调用失败一律吞掉并返回 false——外壳能力缺失不该让
/// 播放或设置页报错，最坏结果只是对应开关不生效。
class DesktopShellBridge {
  DesktopShellBridge._();

  static final DesktopShellBridge instance = DesktopShellBridge._();

  static const MethodChannel channel = MethodChannel('yingshi/desktop_shell');

  bool _handlerInstalled = false;

  /// 老板键隐藏窗口后回调：此时窗口已不可见，但音频还在放，
  /// 由调用方暂停播放，避免「藏起来了却还有声音」。
  VoidCallback? onHiddenByBossKey;

  /// 安装反向调用处理。重复调用无副作用。
  void installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'bossKeyHidden') onHiddenByBossKey?.call();
      return null;
    });
  }

  /// 取走「托盘菜单点了退出」标记（读后即清）。
  ///
  /// 原生按下托盘退出后只置位并投递 `WM_CLOSE`，随后窗口管理器在
  /// `onWindowClose` 里问一次：true 走关闭链，false 收进托盘。这样退出入口
  /// 与标题栏关闭键完全一致——从托盘命令回调里直接触发关闭，进程收尾会在
  /// WebView 插件创建的 DispatcherQueue 上崩在 coremessaging.dll。
  ///
  /// 通道不可用时返回 false：退化成「收进托盘」比误退出更安全。
  Future<bool> consumeTrayExit() async {
    final reply = await _invoke<bool>('consumeTrayExit', const {});
    return reply ?? false;
  }

  /// 关闭链收尾：清理完成后以退出码 0 结束进程。
  ///
  /// 走原生 `TerminateProcess` 而不是让引擎自己拆：托盘开启时引擎收尾会经过
  /// WebView 插件启动时创建的 STA DispatcherQueue，实测稳定崩在
  /// coremessaging.dll（0xC0000005），用户侧表现为「退出时弹出程序停止工作」。
  ///
  /// 返回 false 表示原生不可用（非 Windows / 单元测试），调用方应回退到
  /// `windowManager.destroy()`。
  Future<bool> quitNow() async {
    final applied = await _invoke<bool>('quitNow', const {});
    return applied ?? false;
  }

  /// 播放期间阻止系统待机与关屏。返回原生侧实际是否处于该状态。
  Future<bool> setKeepAwake(bool enabled) async {
    final applied = await _invoke<bool>('setKeepAwake', {'enabled': enabled});
    return applied ?? false;
  }

  /// 显示 / 隐藏系统托盘图标。
  Future<bool> setTrayEnabled({
    required bool enabled,
    required String tooltip,
  }) async {
    final applied = await _invoke<bool>(
      'setTrayEnabled',
      {'enabled': enabled, 'tooltip': tooltip},
    );
    return applied ?? false;
  }

  /// 弹一条托盘气泡。图标不在托盘上时返回 false（不报错）。
  Future<bool> notifyTray({
    required String title,
    required String body,
  }) async {
    final applied = await _invoke<bool>(
      'notifyTray',
      {'title': title, 'body': body},
    );
    return applied ?? false;
  }

  /// 注册 / 注销老板键。首选 Ctrl + Alt + Y，被占用时自动回退到候选组合键。
  Future<BossKeyRegistration> setBossKeyEnabled(bool enabled) async {
    final reply = await _invoke<Map<Object?, Object?>>(
      'setBossKey',
      {'enabled': enabled},
    );
    if (reply == null) return BossKeyRegistration.unavailable;
    return BossKeyRegistration(
      registered: reply['registered'] == true,
      hotkey: reply['hotkey']?.toString() ?? '',
      error: (reply['error'] as num?)?.toInt() ?? 0,
    );
  }

  /// 按窗口配置一次性装配托盘与老板键。
  Future<BossKeyRegistration> applyWindowPreferences({
    required bool trayEnabled,
    required bool bossKeyEnabled,
    required String tooltip,
  }) async {
    await setTrayEnabled(enabled: trayEnabled, tooltip: tooltip);
    return setBossKeyEnabled(bossKeyEnabled);
  }

  Future<T?> _invoke<T>(String method, Map<String, Object?> arguments) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      // 非 Windows 宿主 / 单元测试：静默降级。
      return null;
    } on PlatformException catch (error) {
      debugPrint('[yingshi-tv] desktop shell $method failed: ${error.message}');
      return null;
    }
  }
}
