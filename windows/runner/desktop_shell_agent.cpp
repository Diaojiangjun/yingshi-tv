#include "desktop_shell_agent.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <cstdint>
#include <utility>
#include <vector>

#include "resource.h"

namespace {

constexpr char kChannelName[] = "yingshi/desktop_shell";
constexpr UINT kTrayIconId = 1;

/// 从方法参数里取 bool；缺失或类型不符返回 nullptr。
const bool* ReadBool(const flutter::EncodableMap* args, const char* key) {
  if (args == nullptr) return nullptr;
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return nullptr;
  return std::get_if<bool>(&it->second);
}

std::string ToUtf8(const std::wstring& text) {
  if (text.empty()) return {};
  const int size = ::WideCharToMultiByte(
      CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), nullptr, 0,
      nullptr, nullptr);
  if (size <= 0) return {};
  std::string out(static_cast<size_t>(size), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(),
                        static_cast<int>(text.size()), out.data(), size,
                        nullptr, nullptr);
  return out;
}

std::wstring ToWide(const std::string& text) {
  if (text.empty()) return {};
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, text.c_str(),
                                        static_cast<int>(text.size()), nullptr, 0);
  if (size <= 0) return {};
  std::wstring out(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.c_str(),
                        static_cast<int>(text.size()), out.data(), size);
  return out;
}

/// 从方法参数里取 UTF-8 字符串；缺失或类型不符返回空串。
std::wstring ReadWideString(const flutter::EncodableMap* args, const char* key) {
  if (args == nullptr) return {};
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) return {};
  const auto* text = std::get_if<std::string>(&it->second);
  if (text == nullptr) return {};
  return ToWide(*text);
}

}  // namespace

DesktopShellAgent::DesktopShellAgent(HWND window) : window_(window) {}

DesktopShellAgent::~DesktopShellAgent() {
  // 顺序有讲究：先摘热键与托盘（窗口消息还会来），最后解除休眠约束。
  SetBossKey(false);
  SetTrayEnabled(false, std::wstring());
  SetKeepAwake(false);
}

HICON DesktopShellAgent::LoadTrayIcon() const {
  // 托盘只要 16px 量级：按系统小图标度量取，避免把 256px 的 PNG 压缩帧塞进去。
  const int cx = ::GetSystemMetrics(SM_CXSMICON);
  const int cy = ::GetSystemMetrics(SM_CYSMICON);
  HICON icon = static_cast<HICON>(
      ::LoadImageW(::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON),
                   IMAGE_ICON, cx, cy, LR_DEFAULTCOLOR));
  if (icon == nullptr) {
    // 资源缺失（例如调试构建被裁剪过）时退到系统默认图标，托盘仍然可用。
    icon = ::LoadIconW(nullptr, IDI_APPLICATION);
  }
  return icon;
}

bool DesktopShellAgent::SetKeepAwake(bool enabled) {
  if (enabled == keep_awake_) return true;
  EXECUTION_STATE state = ES_CONTINUOUS;
  if (enabled) {
    // ES_DISPLAY_REQUIRED：正在看片子时屏幕不该黑；只看进度条不看的场景很少见。
    state |= ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED;
  }
  if (::SetThreadExecutionState(state) == 0 && enabled) {
    // 系统拒绝时保持原状态，避免 Dart 侧以为已经生效。
    return false;
  }
  keep_awake_ = enabled;
  return true;
}

bool DesktopShellAgent::SetTrayEnabled(bool enabled, const std::wstring& tooltip) {
  if (window_ == nullptr) return false;

  if (!enabled) {
    if (tray_added_) {
      NOTIFYICONDATAW nid{};
      nid.cbSize = sizeof(nid);
      nid.hWnd = window_;
      nid.uID = kTrayIconId;
      ::Shell_NotifyIconW(NIM_DELETE, &nid);
      tray_added_ = false;
    }
    if (tray_icon_ != nullptr) {
      ::DestroyIcon(tray_icon_);
      tray_icon_ = nullptr;
    }
    return true;
  }

  if (tray_added_) {
    // 已在显示：只更新悬停提示，不重建图标（重建会让托盘区闪一下）。
    NOTIFYICONDATAW nid{};
    nid.cbSize = sizeof(nid);
    nid.hWnd = window_;
    nid.uID = kTrayIconId;
    nid.uFlags = NIF_TIP;
    wcsncpy_s(nid.szTip, _countof(nid.szTip), tooltip.c_str(), _TRUNCATE);
    ::Shell_NotifyIconW(NIM_MODIFY, &nid);
    return true;
  }

  tray_icon_ = LoadTrayIcon();
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = window_;
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  nid.uCallbackMessage = kTrayCallbackMessage;
  nid.hIcon = tray_icon_;
  wcsncpy_s(nid.szTip, _countof(nid.szTip), tooltip.c_str(), _TRUNCATE);
  if (!::Shell_NotifyIconW(NIM_ADD, &nid)) {
    if (tray_icon_ != nullptr) {
      ::DestroyIcon(tray_icon_);
      tray_icon_ = nullptr;
    }
    return false;
  }
  // VERSION_4：回调的低字直接给事件码（WM_LBUTTONUP / WM_CONTEXTMENU），
  // 不用再自己按旧协议区分「右键其实是 WM_RBUTTONUP 的伪装」。
  nid.uVersion = NOTIFYICON_VERSION_4;
  ::Shell_NotifyIconW(NIM_SETVERSION, &nid);
  tray_added_ = true;
  return true;
}

bool DesktopShellAgent::ShowTrayBalloon(const std::wstring& title,
                                        const std::wstring& body) {
  // 只有图标在托盘上时气泡才有归属，否则什么都不显示（不报错，属正常降级）。
  if (window_ == nullptr || !tray_added_) return false;
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = window_;
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_INFO;
  nid.dwInfoFlags = NIIF_INFO;
  wcsncpy_s(nid.szInfoTitle, _countof(nid.szInfoTitle), title.c_str(),
            _TRUNCATE);
  wcsncpy_s(nid.szInfo, _countof(nid.szInfo), body.c_str(), _TRUNCATE);
  return ::Shell_NotifyIconW(NIM_MODIFY, &nid) != FALSE;
}

BossKeyRegistration DesktopShellAgent::SetBossKey(bool enabled) {
  BossKeyRegistration result;
  if (window_ == nullptr) {
    result.error = ERROR_INVALID_WINDOW_HANDLE;
    return result;
  }
  if (boss_key_registered_) {
    ::UnregisterHotKey(window_, kBossKeyId);
    boss_key_registered_ = false;
  }
  boss_key_modifiers_ = 0;
  boss_key_vk_ = 0;
  if (!enabled) {
    // 主动关闭：没有键要注册，按「解除成功」处理。
    result.registered = true;
    return result;
  }

  // 首选 Ctrl + Alt + Y（影视）。单字母热键被输入法、显卡驱动、聊天软件
  // 抢先注册是常事，注册失败时静默退到更冷门的组合，总比给用户一个
  // 「打开了却没反应」的开关好。
  struct Candidate {
    UINT modifiers;
    UINT virtual_key;
    const wchar_t* label;
  };
  static const Candidate kCandidates[] = {
      {MOD_CONTROL | MOD_ALT, 'Y', L"Ctrl + Alt + Y"},
      {MOD_CONTROL | MOD_ALT | MOD_SHIFT, 'Y', L"Ctrl + Alt + Shift + Y"},
      {MOD_CONTROL | MOD_SHIFT, 'Y', L"Ctrl + Shift + Y"},
      {MOD_ALT | MOD_SHIFT, 'Y', L"Alt + Shift + Y"},
  };
  for (const Candidate& candidate : kCandidates) {
    if (::RegisterHotKey(window_, kBossKeyId,
                         candidate.modifiers | MOD_NOREPEAT,
                         candidate.virtual_key)) {
      boss_key_registered_ = true;
      boss_key_modifiers_ = candidate.modifiers;
      boss_key_vk_ = candidate.virtual_key;
      result.registered = true;
      result.hotkey = candidate.label;
      return result;
    }
    result.error = static_cast<int>(::GetLastError());
  }
  return result;
}

void DesktopShellAgent::ShowMainWindow() {
  if (window_ == nullptr) return;
  if (::IsIconic(window_)) {
    ::ShowWindow(window_, SW_RESTORE);
  } else if (!::IsWindowVisible(window_)) {
    ::ShowWindow(window_, SW_SHOW);
  }
  ::SetForegroundWindow(window_);
}

void DesktopShellAgent::ToggleBossKey() {
  if (window_ == nullptr) return;
  if (::IsWindowVisible(window_) && !::IsIconic(window_)) {
    ::ShowWindow(window_, SW_HIDE);
    // 只隐藏窗口的话声音会继续放——老板键的意义就是「立刻没人看得出」。
    // 真正的暂停交给 Dart 做（播放器状态在那边），这里只负责通知。
    NotifyDart("bossKeyHidden", "1");
    return;
  }
  ShowMainWindow();
}

void DesktopShellAgent::ShowTrayMenu(POINT anchor) {
  if (window_ == nullptr) return;
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) return;
  ::AppendMenuW(menu, MF_STRING, kTrayMenuShow, L"显示主界面");
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kTrayMenuExit, L"退出");
  // 不先置前台，点击菜单外部时菜单不会收起（Win32 老问题）。
  ::SetForegroundWindow(window_);
  ::TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, anchor.x,
                   anchor.y, 0, window_, nullptr);
  // 菜单关闭后补一条消息，否则焦点可能停在已销毁的菜单上。
  ::PostMessageW(window_, WM_NULL, 0, 0);
  ::DestroyMenu(menu);
}

void DesktopShellAgent::NotifyDart(const char* method,
                                   const std::string& value) {
  if (messenger_ == nullptr) return;
  flutter::EncodableMap arguments{
      {flutter::EncodableValue("value"), flutter::EncodableValue(value)}};
  const flutter::MethodCall<flutter::EncodableValue> call(
      std::string(method),
      std::make_unique<flutter::EncodableValue>(arguments));
  const auto encoded =
      flutter::StandardMethodCodec::GetInstance().EncodeMethodCall(call);
  if (!encoded) return;
  messenger_->Send(kChannelName, encoded->data(), encoded->size(),
                   [](const uint8_t*, size_t) {});
}

bool DesktopShellAgent::ConsumeTrayExit() {
  const bool pending = tray_exit_pending_;
  tray_exit_pending_ = false;
  return pending;
}

std::optional<LRESULT> DesktopShellAgent::HandleMessage(UINT message,
                                                        WPARAM wparam,
                                                        LPARAM lparam) {
  if (message == kTrayCallbackMessage && tray_added_) {
    // VERSION_4 协议：低字为事件码，wparam 的低 / 高字是锚点坐标。
    switch (LOWORD(lparam)) {
      case WM_LBUTTONUP:
      case WM_LBUTTONDBLCLK:
      case NIN_SELECT:
        ShowMainWindow();
        return 0;
      case WM_CONTEXTMENU:
      case WM_RBUTTONUP: {
        POINT anchor{};
        anchor.x = static_cast<LONG>(static_cast<short>(LOWORD(wparam)));
        anchor.y = static_cast<LONG>(static_cast<short>(HIWORD(wparam)));
        if (anchor.x == 0 && anchor.y == 0) ::GetCursorPos(&anchor);
        ShowTrayMenu(anchor);
        return 0;
      }
      default:
        break;
    }
    return std::nullopt;
  }

  if (message == WM_HOTKEY && static_cast<int>(wparam) == kBossKeyId) {
    ToggleBossKey();
    return 0;
  }

  if (message == WM_COMMAND) {
    switch (LOWORD(wparam)) {
      case kTrayMenuShow:
        ShowMainWindow();
        return 0;
      case kTrayMenuExit:
        // 退出要走 Dart 的关闭链：停播放、关 companion、落盘窗口几何。
        // 但不能在这里直接发通道消息——实测从托盘命令回调里直接进关闭链，
        // 进程收尾会在第三方 WebView 插件创建的 DispatcherQueue 上
        // 崩在 coremessaging.dll（0xC0000005）。改为置位后投递 WM_CLOSE，
        // 让退出复用标题栏关闭键那条已验证的入口，由 Dart 读标记决定关还是藏。
        tray_exit_pending_ = true;
        ::PostMessage(window_, WM_CLOSE, 0, 0);
        return 0;
      default:
        break;
    }
  }
  return std::nullopt;
}

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterDesktopShellChannel(flutter::BinaryMessenger* messenger,
                            DesktopShellAgent* agent) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  agent->set_messenger(messenger);
  channel->SetMethodCallHandler(
      [agent](const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                  result) {
        const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments());

        if (call.method_name() == "setKeepAwake") {
          const bool* value = ReadBool(args, "enabled");
          if (value == nullptr) {
            result->Error("bad_args", "enabled 必须是 bool");
            return;
          }
          agent->SetKeepAwake(*value);
          result->Success(flutter::EncodableValue(agent->keep_awake()));
          return;
        }

        if (call.method_name() == "setTrayEnabled") {
          const bool* value = ReadBool(args, "enabled");
          if (value == nullptr) {
            result->Error("bad_args", "enabled 必须是 bool");
            return;
          }
          std::wstring tooltip;
          if (args != nullptr) {
            const auto it = args->find(flutter::EncodableValue("tooltip"));
            if (it != args->end()) {
              if (const auto* text = std::get_if<std::string>(&it->second)) {
                // MethodChannel 的 string 是 UTF-8。
                tooltip = ToWide(*text);
              }
            }
          }
          result->Success(flutter::EncodableValue(
              agent->SetTrayEnabled(*value, tooltip)));
          return;
        }

        if (call.method_name() == "quitNow") {
          // 关闭链已经收尾（停播放 / 关 companion / 落盘几何），直接以退出码 0
          // 结束进程。不能走引擎自身析构：托盘开启时收尾会经过 WebView 插件
          // 启动时创建的 STA DispatcherQueue，实测稳定崩在 coremessaging.dll
          // （0xC0000005），用户看到的是「退出时程序停止工作」。
          // 成功时不会返回；返回 false 说明调用失败，交回 Dart 回退。
          if (!::TerminateProcess(::GetCurrentProcess(), 0)) {
            result->Success(flutter::EncodableValue(false));
          }
          return;
        }

        if (call.method_name() == "consumeTrayExit") {
          result->Success(flutter::EncodableValue(agent->ConsumeTrayExit()));
          return;
        }

        if (call.method_name() == "notifyTray") {
          result->Success(flutter::EncodableValue(agent->ShowTrayBalloon(
              ReadWideString(args, "title"), ReadWideString(args, "body"))));
          return;
        }

        if (call.method_name() == "setBossKey") {
          const bool* value = ReadBool(args, "enabled");
          if (value == nullptr) {
            result->Error("bad_args", "enabled 必须是 bool");
            return;
          }
          const BossKeyRegistration registration = agent->SetBossKey(*value);
          flutter::EncodableMap reply{
              {flutter::EncodableValue("registered"),
               flutter::EncodableValue(registration.registered)},
              {flutter::EncodableValue("hotkey"),
               flutter::EncodableValue(ToUtf8(registration.hotkey))},
              {flutter::EncodableValue("error"),
               flutter::EncodableValue(registration.error)},
          };
          result->Success(flutter::EncodableValue(reply));
          return;
        }

        result->NotImplemented();
      });
  return channel;
}
