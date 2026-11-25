import '../../core/brand.dart';
/// 用户协议与免责声明的文案（纯数据，UI 与测试共用）。
///
/// 口径固定为「本地播放器 + 用户自带内容源」：本软件不含任何片源、不代理媒体流，
/// 条款里不能出现「提供 / 收录 / 分享影视资源」这类会被当成内容提供方的表述。
/// 改文案属于实质变更，记得同步 `AgreementStore.currentVersion`。
class AgreementTerms {
  const AgreementTerms._();

  static const String title = '用户协议与免责声明';

  static const String welcome = '欢迎使用 ${AppBrand.name}。开始使用前，请阅读并同意以下条款：';

  static const List<String> clauses = [
    '本软件是本地影视播放器与信息聚合客户端，仅用于个人学习、研究和技术交流，'
        '不提供、不存储、不分发任何音视频内容。',
    '软件不内置任何影视源、解析接口或直播源。所有站点配置、订阅源、直播源均由你自行提供，'
        '其内容与合法性由你自行负责。',
    '请遵守你所在地区的法律法规及内容服务条款，不得将本软件用于商业用途或任何违法用途。',
    '使用本软件产生的一切后果由你自行承担；开发者不对第三方内容的可用性、合法性或安全性负责。',
    '软件无账号、无遥测，数据默认只保存在本机；仅在你主动启用备份、云同步或弹幕服务时，'
        '相关数据才会发送到你指定的服务。',
  ];

  static const String footnote = '点击「同意并继续」即表示你已阅读并同意以上条款。';

  static const String acceptLabel = '同意并继续';

  /// 关于页只读查看时用的关闭文案。
  static const String closeLabel = '我已阅读';
}
