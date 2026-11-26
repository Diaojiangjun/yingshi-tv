import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'core/app_info.dart';
import 'core/brand.dart';
import 'core/companion/companion_playback_lease.dart';
import 'core/companion/companion_process_manager.dart';
import 'core/config/config_repository.dart';
import 'core/config/models/builtin_sites.dart';
import 'core/desktop/desktop_shell_bridge.dart';
import 'core/diagnostics/error_log.dart';
import 'core/legal/agreement_providers.dart';
import 'core/legal/agreement_store.dart';
import 'core/net/http_client_factory.dart';
import 'core/danmaku/danmaku_api.dart';
import 'core/player/models/player_state.dart';
import 'core/player/mpv_player_engine.dart';
import 'core/settings/models/appearance_preferences.dart';
import 'core/settings/settings_repository.dart';
import 'core/storage/app_data_reset.dart';
import 'core/storage/data_directory_manager.dart';
import 'ui/desktop/window/desktop_window_manager.dart';
import 'ui/theme/app_icon_assets.dart';
import 'ui/theme/app_palette.dart';

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // ⑥ 内存批：海报 / 台标等网络图解码缓存默认上限 100MB，收紧到 48MB；
    // 超出按 LRU 淘汰、重复浏览会再解码，换取常驻内存下降。
    PaintingBinding.instance.imageCache.maximumSizeBytes = 48 << 20;
    await loadAppVersionLabel();
    // §43：可选服务是否可用（只打印是否配置，不打印地址 / 令牌）。
    // 用户还可以在「设置 → 播放器与解码 → 弹幕 → 弹幕服务」里自填，所以这里只反映内置态。
    debugPrint('[yingshi-tv] 弹幕服务（构建期内置）：${kBuiltinDanmakuApiBase.isNotEmpty ? '已配置' : '未配置'}');

    // 先解析数据目录并执行待定迁移，再创建任何存储（避免运行中双目录写入）。
    // 便携版默认目录是 exe 旁的 user_data，重置标记也放在默认目录，所以必须先解析。
    try {
      await DataDirectoryManager.initialize();
    } catch (error) {
      debugPrint('[yingshi-tv] data directory init failed: $error');
    }

    // 关于页「重置所有设置」：上次会话安排的全部清空，在创建任何存储之前执行
    try {
      if (await AppDataReset.applyPendingAtStartup()) {
        debugPrint('[yingshi-tv] 已按上次的「重置所有设置」清空数据目录');
      }
    } catch (error) {
      debugPrint('[yingshi-tv] reset failed: $error');
    }

    // 关于页「错误日志」：本次运行期间的未捕获异常、框架错误、播放器报错，只放内存（关闭即清空）
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      ErrorLog.instance.record('界面', details.exception, details.stack);
      previousOnError?.call(details);
    };

    final configRepository = ConfigRepository(fallbackHomeSite: builtinDoubanSite);
    await configRepository.initialize();

    final settingsRepository = SettingsRepository();
    await settingsRepository.initialize(
      legacyHwdec: configRepository.currentWindowConfig.hardwareDecoding,
      legacyConfigUrl: configRepository.currentWindowConfig.lastConfigUrl,
    );
    // 应用生命周期内常驻：成功加载的 URL / 本地文件记入配置源历史
    settingsRepository.bindConfigRepository(configRepository);

    // 用户协议与免责声明：同意过才放行主界面（首启由 AgreementGuard 遮挡）。
    final agreementStore = AgreementStore();
    var agreementAccepted = false;
    try {
      agreementAccepted = await agreementStore.isAccepted();
    } catch (error) {
      debugPrint('[yingshi-tv] 读取协议同意状态失败: $error');
    }

    // SET-05：播放历史保留上限从设置同步一次（trim: false——启动不静默裁剪，见方案 §2.2）
    await configRepository.setHistoryLimit(
        settingsRepository.historyPreferences.limit,
        trim: false);
    // §14 无痕浏览：跟随历史偏好（流先给当前值，再推送设置页 / 重新读取后的变更）
    configRepository.setHistoryIncognito(settingsRepository.historyPreferences.incognito);
    settingsRepository.historyPreferencesStream.listen(
        (preferences) => configRepository.setHistoryIncognito(preferences.incognito));
    // §14 安全 DNS：未经工厂创建的 HttpClient（如普通海报 NetworkImage）也接管建连；
    // 选择跟随网络偏好实时切换（读取失败时偏好为默认「关闭」）。
    HttpClientFactory.installGlobalOverrides();
    HttpClientFactory.configureDoh(settingsRepository.networkPreferences.endpoint);
    settingsRepository.networkPreferencesStream.listen(
        (preferences) => HttpClientFactory.configureDoh(preferences.endpoint));

    final companionManager = CompanionProcessManager();
    // §59 站源直连被重置时改走 Windows 系统代理（只在系统代理开启时生效）
    companionManager.fallbackProxy = DanmakuApi.systemProxy;
    // 播放器先于窗口管理器创建：退出钩子要先停播放（窗口已隐藏，声音不能再继续）
    final playerEngine = MpvPlayerEngine();
    // 播放期间持有 companion 租约：网盘直链由本地代理持续传流，没有 RPC 可计时，
    // 旧实现约 30 分钟后把代理进程当空闲停掉，播放中段即断流。
    final playbackLease = CompanionPlaybackLease(
      statusStream: playerEngine.statusStream,
      manager: companionManager,
    );
    final windowManager = DesktopWindowManager(
      configRepository: configRepository,
      beforeClose: () async {
        try {
          await playerEngine.stop().timeout(const Duration(milliseconds: 500));
        } catch (_) {
          // 停播失败 / 超时不阻断关闭：进程退出时 mpv 随之结束
        }
        await playbackLease.dispose();
        await companionManager.shutdown();
      },
    );
    // 首帧前按已保存主题给原生窗口底色，避免浅色主题启动时闪深色边
    final appearance = settingsRepository.appearancePreferences;
    final initialBrightness = switch (appearance.themeMode) {
      AppThemeMode.dark => Brightness.dark,
      AppThemeMode.light => Brightness.light,
      AppThemeMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness,
    };
    await windowManager.initialize(
      backgroundColor: initialBrightness == Brightness.dark
          ? AppPalette.dark.background
          : AppPalette.light.background,
      iconPath: appIconFilePath(),
    );

    // 桌面外壳：系统托盘、老板键（Ctrl + Alt + Y）、播放时阻止系统休眠。
    final desktopShell = DesktopShellBridge.instance;
    desktopShell.installHandler();
    // 托盘「退出」必须走完整关闭链：停播放 → 关 companion → 落盘窗口几何。
    // 原生直接销毁窗口会跳过这些，留下孤儿 Java 进程。
    desktopShell.onExitRequested = () => unawaited(windowManager.close());
    // 老板键只把窗口藏起来，音频还在继续播放，由这里补上暂停。
    desktopShell.onHiddenByBossKey = () => unawaited(playerEngine.pause());
    final windowPreferences = configRepository.currentWindowConfig;
    unawaited(desktopShell
        .applyWindowPreferences(
          trayEnabled: windowPreferences.trayEnabled,
          bossKeyEnabled: windowPreferences.bossKeyEnabled,
          tooltip: AppBrand.name,
        )
        .then((registration) => debugPrint(
            '[yingshi-tv] 桌面外壳：托盘=${windowPreferences.trayEnabled} '
            '老板键=${registration.registered ? registration.hotkey : '未注册(${registration.error})'}')));

    // 播放 / 缓冲期间阻止系统待机与关屏；暂停、结束、出错立即放行。
    // 用局部变量记住最近一次结果，避免每次状态流转都过一次通道。
    var playbackActive = false;
    var keepAwakeWanted = settingsRepository.playerSettings.keepAwake;
    var keepAwakeApplied = false;
    void syncKeepAwake() {
      final next = keepAwakeWanted && playbackActive;
      if (next == keepAwakeApplied) return;
      keepAwakeApplied = next;
      unawaited(desktopShell.setKeepAwake(next).then((applied) {
        // 只在「该拦却没拦住」时说一声，正常播放不刷日志。
        if (next && !applied) {
          debugPrint('[yingshi-tv] 阻止休眠未生效：系统拒绝了执行状态请求');
          // 复位，下一次播放状态流转时再试一次，而不是一直假装已生效。
          keepAwakeApplied = false;
        }
      }));
    }

    playerEngine.statusStream.listen((status) {
      playbackActive =
          status == PlaybackStatus.playing || status == PlaybackStatus.buffering;
      syncKeepAwake();
    });
    settingsRepository.playerSettingsStream.listen((settings) {
      keepAwakeWanted = settings.keepAwake;
      syncKeepAwake();
    });

    // 冷启动有效主入口：启动偏好 +「上次入口」解析（失败按点播首页）
    final startupEntry = settingsRepository.startupPreferences.effectiveEntry;

    // 初始化时捕获默认音量 / 倍速；之后只更新即时参数，不覆盖当前播放默认值
    unawaited(
        playerEngine.applyPlaybackSettings(settingsRepository.playerSettings));
    playerEngine.errorStream.listen((message) {
      if (message != null && message.trim().isNotEmpty) {
        ErrorLog.instance.record('播放器', message);
      }
    });
    settingsRepository.playerSettingsStream
        .skip(1)
        .listen(playerEngine.applyPlaybackSettings);

    runApp(
      ProviderScope(
        overrides: [
          configRepositoryProvider.overrideWithValue(configRepository),
          windowManagerProvider.overrideWithValue(windowManager),
          playerEngineProvider.overrideWithValue(playerEngine),
          settingsRepositoryProvider.overrideWithValue(settingsRepository),
          startupEntryProvider.overrideWithValue(startupEntry),
          agreementStoreProvider.overrideWithValue(agreementStore),
          agreementInitialProvider.overrideWithValue(agreementAccepted),
        ],
        child: const YingshiTvApp(),
      ),
    );

    unawaited(playerEngine.initialize());
  }, (error, stack) {
    debugPrint('[yingshi-tv] startup error: $error\n$stack');
    ErrorLog.instance.record('未捕获异常', error, stack);
  });
}
