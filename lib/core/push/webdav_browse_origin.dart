import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 从 WebDAV 浏览器起播前的浏览位置；退出播放器后据此回到原目录。
///
/// 只在内存中流转（消费一次即清空），不写入磁盘：账号密码原本就只存在于
/// 弹窗输入框与已加密的连接记录里，这里不新增持久化面。
class WebDavBrowseOrigin {
  const WebDavBrowseOrigin({
    required this.url,
    required this.username,
    required this.password,
    required this.trail,
    required this.playUrl,
  });

  final String url;
  final String username;
  final String password;

  /// 从根目录到起播时所在目录的路径，首项固定为根。
  final List<Uri> trail;

  /// 本次起播的媒体地址；用于判定退出时是否仍是同一次 WebDAV 播放。
  final String playUrl;
}

/// 当前 WebDAV 播放的来源快照。播放器退出时消费一次并清空。
final webDavBrowseOriginProvider =
    StateProvider<WebDavBrowseOrigin?>((ref) => null);
