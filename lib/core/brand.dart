/// 品牌信息：「影视」这个名字只在这里定义一次。
///
/// 展示名（窗口标题、侧栏、关于页、协议、备份文件名、发给朋友的房主名）
/// 与内部标识（包名 `yingshi_tv`、exe 名、`%APPDATA%/YingshiTV`、User-Agent）
/// 已经统一到 yingshi 这套命名；旧版 `XiugouTV` 目录由
/// `DataDirectoryManager` 在首次启动时整体搬迁，不需要用户手工处理。
class AppBrand {
  const AppBrand._();

  /// 软件名称。
  static const String name = '影视';

  /// 一句话定位（关于页副标题）。
  static const String tagline = '本地影视播放器 · 播放源由你自行配置';
}
