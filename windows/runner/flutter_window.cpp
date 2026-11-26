#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  native_playback_.reset();
  if (webdav_secrets_channel_) {
    webdav_secrets_channel_->SetMethodCallHandler(nullptr);
    webdav_secrets_channel_.reset();
  }
  if (secrets_channel_) {
    secrets_channel_->SetMethodCallHandler(nullptr);
    secrets_channel_.reset();
  }
  if (desktop_shell_channel_) {
    desktop_shell_channel_->SetMethodCallHandler(nullptr);
    desktop_shell_channel_.reset();
  }
  desktop_shell_.reset();
  // S48: safety net. ~unique_ptr does not null the pointer before deleting,
  // so messages arriving during teardown would reach a half-destroyed
  // controller; reset() nulls first, so MessageHandler sees nullptr.
  flutter_controller_.reset();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  auto* engine = flutter_controller_->engine();
  native_playback_ = std::make_unique<native_playback::PlaybackChannel>(
      engine->messenger(), engine->GetRegistrarForPlugin("YingshiNativePlayback"), GetHandle());
  process_job_channel_ =
      RegisterProcessJobChannel(flutter_controller_->engine()->messenger());
  webdav_secrets_channel_ =
      RegisterWebDavSecretsChannel(flutter_controller_->engine()->messenger());
  secrets_channel_ = RegisterSecretsChannel(
      flutter_controller_->engine()->messenger(), "yingshi/secrets");
  fullscreen_ = std::make_unique<WindowFullscreen>(GetHandle());
  fullscreen_channel_ = RegisterWindowFullscreenChannel(
      flutter_controller_->engine()->messenger(), fullscreen_.get());
  desktop_shell_ = std::make_unique<DesktopShellAgent>(GetHandle());
  desktop_shell_channel_ = RegisterDesktopShellChannel(
      flutter_controller_->engine()->messenger(), desktop_shell_.get());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Drop the channel before the engine it is bound to.
  native_playback_.reset();
  if (webdav_secrets_channel_) {
    webdav_secrets_channel_->SetMethodCallHandler(nullptr);
    webdav_secrets_channel_.reset();
  }
  if (secrets_channel_) {
    secrets_channel_->SetMethodCallHandler(nullptr);
    secrets_channel_.reset();
  }
  process_job_channel_ = nullptr;
  fullscreen_channel_ = nullptr;
  // 窗口销毁前必须摘掉托盘图标与热键，否则托盘区会留下一个点不动的幽灵图标。
  if (desktop_shell_channel_) {
    desktop_shell_channel_->SetMethodCallHandler(nullptr);
    desktop_shell_channel_ = nullptr;
  }
  desktop_shell_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // §52：全屏期间的 WM_NCCALCSIZE 必须先于 window_manager 插件处理。
  if (fullscreen_) {
    if (auto handled = fullscreen_->HandleMessage(message, wparam, lparam)) {
      return *handled;
    }
  }

  // 托盘回调、托盘菜单命令与 WM_HOTKEY 都是本窗口私有的消息号，
  // 必须在交给 Flutter 之前拦下（插件不认识它们，会当成未知消息往下穿）。
  if (desktop_shell_) {
    if (auto handled = desktop_shell_->HandleMessage(message, wparam, lparam)) {
      return *handled;
    }
  }

  if (message == WM_TIMER && native_playback_ && native_playback_->HandleTimer(wparam)) return 0;

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      // S48: the controller may already be released during teardown.
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
