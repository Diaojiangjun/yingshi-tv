/// 网盘商元数据。
///
/// [DriveProvider.id] 同时是蜘蛛 `ext` 里的注入键（与 TVBox 生态一致）：
/// `quark` / `uc` / `baidu` / `115` / `bili` / `thunder` / `guangya`。
///
/// 本文件不依赖 `dart:io`，只放常量与查询函数，便于在纯 Dart 测试里引用。
library;

/// 凭据形态：整串 Cookie，还是单个 Token。
enum DriveCredentialKind {
  /// 一整个 `a=b; c=d` Cookie 串（夸克 / UC / 百度 / 115 / 哔哩）。
  cookie,

  /// 单个 Token（迅雷 / 光鸭），由蜘蛛拿去做刷新。
  token,
}

class DriveProvider {
  const DriveProvider({
    required this.id,
    required this.name,
    required this.cookieHost,
    required this.authNames,
    required this.loginUrl,
    required this.cookieScopes,
    this.readyNames = const <String>[],
    this.kind = DriveCredentialKind.cookie,
    this.optional = false,
    this.note = '',
  });

  /// 注入键 / 存储键，不要改名。
  final String id;

  /// 界面上显示的名字。
  final String name;

  /// Cookie 应该来自哪个站点（输入框提示、扫码时读取 Cookie 的主域）。
  final String cookieHost;

  /// 命中任意一个字段即视为「已登录」（粗筛，最终以在线校验为准）。
  final List<String> authNames;

  /// 会话齐全必须同时具备的字段（百度 STOKEN 晚于 BDUSS 下发）。
  final List<String> readyNames;

  /// 内置扫码登录页。
  final String loginUrl;

  /// 扫码登录时除登录页域名外还要一并读取 Cookie 的站点。
  final List<String> cookieScopes;

  final DriveCredentialKind kind;

  /// 可选增强：不配置也能用（哔哩的基础画质）。
  final bool optional;

  /// 行内补充说明。
  final String note;

  bool get usesToken => kind == DriveCredentialKind.token;
}

/// 顺序即界面顺序（与常见使用频率一致）。
const List<DriveProvider> driveProviders = <DriveProvider>[
  DriveProvider(
    id: 'quark',
    name: '夸克网盘',
    cookieHost: 'pan.quark.cn',
    authNames: <String>['__puus', '__pus', '__puuk', '__pusd'],
    loginUrl: 'https://pan.quark.cn/login',
    cookieScopes: <String>[
      'https://pan.quark.cn',
      'https://drive-pc.quark.cn',
      'https://drive.quark.cn',
    ],
    note: '扫码后在网页里完成登录，返回时自动保存',
  ),
  DriveProvider(
    id: 'uc',
    name: 'UC 网盘',
    cookieHost: 'drive.uc.cn',
    authNames: <String>['PUVID', '__puus', '__pus', 'drive_uc'],
    loginUrl: 'https://drive.uc.cn/',
    cookieScopes: <String>[
      'https://drive.uc.cn',
      'https://pc-api.uc.cn',
      'https://fast.uc.cn',
    ],
    note: '登录页顶部可切换微信扫码 / UC 扫码',
  ),
  DriveProvider(
    id: 'baidu',
    name: '百度网盘',
    cookieHost: 'pan.baidu.com',
    authNames: <String>['BDUSS'],
    readyNames: <String>['STOKEN'],
    loginUrl:
        'https://passport.baidu.com/v2/?login&tpl=netdisk'
        '&u=https%3A%2F%2Fpan.baidu.com%2Fdisk%2Fhome',
    cookieScopes: <String>[
      'https://pan.baidu.com',
      'https://passport.baidu.com',
    ],
    note: '用百度 APP 扫码；登录后会自动跳回网盘页',
  ),
  DriveProvider(
    id: '115',
    name: '115 网盘',
    cookieHost: '115.com',
    authNames: <String>['UID', 'CID', 'SEID', 'KID'],
    readyNames: <String>['UID', 'CID', 'SEID'],
    loginUrl: 'https://115.com/',
    cookieScopes: <String>[
      'https://115.com',
      'https://webapi.115.com',
      'https://proapi.115.com',
    ],
    note: '需要短信验证时请改用「手动 Cookie」',
  ),
  DriveProvider(
    id: 'bili',
    name: '哔哩哔哩',
    cookieHost: 'bilibili.com',
    authNames: <String>['SESSDATA', 'bili_jct', 'DedeUserID'],
    readyNames: <String>['SESSDATA', 'DedeUserID'],
    loginUrl: 'https://passport.bilibili.com/login',
    cookieScopes: <String>[
      'https://www.bilibili.com',
      'https://passport.bilibili.com',
      'https://api.bilibili.com',
    ],
    optional: true,
    note: '可选增强：登录后才能取高清画质',
  ),
  DriveProvider(
    id: 'thunder',
    name: '迅雷云盘',
    cookieHost: 'pan.xunlei.com',
    authNames: <String>['sessionid', 'userid', 'loginday'],
    loginUrl: 'https://pan.xunlei.com/',
    cookieScopes: <String>[
      'https://pan.xunlei.com',
      'https://xluser-ssl.xunlei.com',
    ],
    kind: DriveCredentialKind.token,
    note: '保存的是会话 Token，不做在线校验',
  ),
  DriveProvider(
    id: 'guangya',
    name: '光鸭云盘',
    cookieHost: 'guangyapan.com',
    authNames: <String>['token', 'access_token', 'refresh_token'],
    loginUrl: 'https://www.guangyapan.com/home/',
    cookieScopes: <String>[
      'https://www.guangyapan.com',
      'https://app.guangyapan.com',
    ],
    kind: DriveCredentialKind.token,
    note: '保存的是登录 Token，不做在线校验',
  ),
];

/// 按 id 取元数据；未知 id 返回 null。
DriveProvider? driveProviderById(String id) {
  final key = id.trim().toLowerCase();
  for (final provider in driveProviders) {
    if (provider.id == key) return provider;
  }
  return null;
}
