#ifndef RUNNER_DESKTOP_SHELL_AGENT_H_
#define RUNNER_DESKTOP_SHELL_AGENT_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <optional>
#include <string>

/// 老板键注册结果。`hotkey` 是真正生效的组合键（可能与首选不同），
/// `error` 是最后一次 `RegisterHotKey` 的 GetLastError（1409 = 已被占用）。
struct BossKeyRegistration {
  bool registered = false;
  std::wstring hotkey;
  int error = 0;
};

// 桌面外壳能力：系统托盘图标、老板键、播放时阻止系统休眠。
//
// 三项都必须在原生侧做：
//  * `Shell_NotifyIcon` / `RegisterHotKey` 只能在持有窗口句柄的线程注册，
//    且回调依赖窗口消息（`WM_HOTKEY`、自定义托盘消息），Dart 侧没有对应通道；
//  * `SetThreadExecutionState` 的状态是**线程级**的，必须与 `ES_CONTINUOUS`
//    在同一线程成对设置与解除，放在 platform thread 才不会被别处覆盖。
class DesktopShellAgent {
 public:
  explicit DesktopShellAgent(HWND window);
  ~DesktopShellAgent();

  DesktopShellAgent(const DesktopShellAgent&) = delete;
  DesktopShellAgent& operator=(const DesktopShellAgent&) = delete;

  void set_messenger(flutter::BinaryMessenger* messenger) {
    messenger_ = messenger;
  }

  /// 播放期间阻止系统待机与关屏；关闭时恢复系统默认策略。
  /// 返回调用后是否处于目标状态（系统拒绝时会保持原值）。
  bool SetKeepAwake(bool enabled);
  bool keep_awake() const { return keep_awake_; }

  /// 显示 / 隐藏托盘图标。[tooltip] 是鼠标悬停提示（应用名）。
  bool SetTrayEnabled(bool enabled, const std::wstring& tooltip);
  bool tray_enabled() const { return tray_added_; }

  /// 注册 / 注销老板键。
  ///
  /// 首选 Ctrl + Alt + Y；被其他程序占用时按候选列表依次回退，保证用户总能
  /// 拿到一个可用的键位。返回实际生效的组合键，全部失败时 `registered` 为 false。
  BossKeyRegistration SetBossKey(bool enabled);
  bool boss_key_registered() const { return boss_key_registered_; }

  /// 返回非空表示消息已处理，调用方不要再往下传。
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                       LPARAM lparam);

 private:
  void ShowMainWindow();
  void ToggleBossKey();
  void ShowTrayMenu(POINT anchor);
  /// 反向通知 Dart：托盘菜单命令、老板键隐藏。
  void NotifyDart(const char* method, const std::string& value);
  HICON LoadTrayIcon() const;

  // 托盘回调消息、菜单项与热键 id 都取 WM_APP 之后的自定义区段，
  // 避免和 Flutter / 插件已占用的消息号冲突。
  static constexpr UINT kTrayCallbackMessage = WM_APP + 0x51;
  static constexpr UINT kTrayMenuShow = 0x5A01;
  static constexpr UINT kTrayMenuExit = 0x5A02;
  static constexpr int kBossKeyId = 0x5B01;

  HWND window_;
  flutter::BinaryMessenger* messenger_ = nullptr;
  bool keep_awake_ = false;
  bool tray_added_ = false;
  HICON tray_icon_ = nullptr;
  bool boss_key_registered_ = false;
  UINT boss_key_modifiers_ = 0;
  UINT boss_key_vk_ = 0;
};

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterDesktopShellChannel(flutter::BinaryMessenger* messenger,
                            DesktopShellAgent* agent);

#endif  // RUNNER_DESKTOP_SHELL_AGENT_H_
