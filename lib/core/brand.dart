/// 品牌信息：对外展示的软件名称集中在这里。
///
/// 只影响「用户看得见」的字（窗口标题、侧栏、关于页、协议、备份文件名、
/// 发给朋友的房主名）；包名 `xiugou_tv`、exe 文件名、`%APPDATA%/XiugouTV`
/// 数据目录、User-Agent 等内部标识保持不动——改它们会让老用户的配置、
/// 播放历史、一起看房间码全部对不上。
class AppBrand {
  const AppBrand._();

  /// 软件名称。
  static const String name = '影视';

  /// 一句话定位（关于页副标题）。
  static const String tagline = '本地影视播放器 · 播放源由你自行配置';
}
