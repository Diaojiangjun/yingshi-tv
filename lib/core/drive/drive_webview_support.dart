import 'dart:io';

import 'package:flutter/foundation.dart';
// flutter_inappwebview 会把平台接口整体转发出来，InAppWebViewPlatform 从它取。
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';

bool _registrationAttempted = false;

/// 仅供测试：置为 true 时跳过兜底注册，用来模拟「本机没有 WebView2」。
@visibleForTesting
bool debugSkipDriveWebViewRegistration = false;

/// 内置网页登录（WebView2）在本机是否可用。
///
/// 只反映「平台实现是否被注册」，不代表 WebView2 运行时一定装好；
/// 页面真打不开时由弹窗内的加载失败提示兜底。
bool get driveWebViewAvailable => InAppWebViewPlatform.instance != null;

/// 兜底注册 Windows 端 WebView 平台实现，返回是否可用。
///
/// 正常情况下 Flutter 生成的 `dart_plugin_registrant` 会在启动时调用
/// `WindowsInAppWebViewPlatform.registerWith()`；但实测在部分构建产物里
/// 这一步没有生效，点「扫码登录」会直接断言
/// `InAppWebViewPlatform.instance != null` 失败并弹出红屏。
/// 这里再补一次（幂等：已注册时不做任何事），注册失败也不会抛给调用方。
bool ensureDriveWebViewPlatform() {
  if (InAppWebViewPlatform.instance != null) return true;
  if (!Platform.isWindows) return false;
  if (debugSkipDriveWebViewRegistration) return false;
  if (!_registrationAttempted) {
    _registrationAttempted = true;
    try {
      WindowsInAppWebViewPlatform.registerWith();
    } catch (error) {
      debugPrint('[yingshi-tv] WebView2 平台注册失败: $error');
    }
  }
  final available = InAppWebViewPlatform.instance != null;
  debugPrint(
    '[yingshi-tv] WebView2 平台实现：${available ? '就绪' : '缺失（改用粘贴 Cookie）'}',
  );
  return available;
}
