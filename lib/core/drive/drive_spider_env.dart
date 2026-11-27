import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 把已绑定的网盘凭据同步成「Cloud-drive」类加固蜘蛛期望的落盘格式。
///
/// 背景（实测 jar 反编译）：`Cloud_quark` 这类载荷**不读** ext 里的 `quark` 键，
/// 而是在 `init(context, ext)` 里取 ext 的 `Cloud-drive` 指向的 JSON，读取其中的
/// `quarkCookie` 等字段；拿不到时 `playerContent` 直接回
/// 「未扫码授权无法播放，请去扫码或刷新」。
///
/// 该 JSON 由蜘蛛自己的配置中心写在 `Context.getFilesDir()`，再由 `ProxyOrigin.getFileUrl()`
/// 映射成本机文件服务地址。桌面端没有那套宿主配置页，所以在每次站源调用前由这里写一份。
///
/// `Cloud-drive` 的取值约定与 jar 内部一致：`./xxx` → 本机文件 `<filesDir>/xxx`
/// （jar 会删掉所有 `.` 再拼接）。
///
/// 绝对 http(s) 地址不碰：那是源作者维护的远端配置，覆盖它可能丢掉其中的其它字段。
void syncCloudDriveFile({
  required String? ext,
  required Map<String, String> credentials,
  required String filesDir,
}) {
  final source = ext?.trim() ?? '';
  if (!source.startsWith('{') || credentials.isEmpty) return;
  Object? decoded;
  try {
    decoded = jsonDecode(source);
  } catch (_) {
    return;
  }
  if (decoded is! Map) return;
  final map = decoded.map((key, value) => MapEntry('$key', value));
  final declared = '${map['Cloud-drive'] ?? ''}'.trim();
  if (declared.isEmpty) return;
  if (RegExp(r'^https?://', caseSensitive: false).hasMatch(declared)) return;

  // jar 侧的路径是 `declared.replace(".", "")`，文件名里的点也会被抹掉。
  final rel = declared.replaceAll('.', '').replaceFirst(RegExp(r'^/+'), '');
  if (rel.isEmpty) return;

  final file = File(p.joinAll(<String>[filesDir, ...rel.split('/')]));
  final ali = (credentials['aliyun'] ?? '').trim();
  // Cloud_ali 只认 32 位 refresh_token；用户若粘贴的是 JSON，先把 refresh_token 取出来。
  var aliToken = ali;
  if (ali.startsWith('{')) {
    try {
      final decoded = jsonDecode(ali);
      if (decoded is Map) {
        final refresh = '${decoded['refresh_token'] ?? ''}'.trim();
        final access = '${decoded['access_token'] ?? ''}'.trim();
        aliToken = refresh.isNotEmpty ? refresh : access;
      }
    } catch (_) {
      // 保留原样。
    }
  }
  final thunder = (credentials['thunder'] ?? '').trim();
  final guangya = (credentials['guangya'] ?? '').trim();
  final body = <String, String>{
    if ((credentials['quark'] ?? '').trim().isNotEmpty)
      'quarkCookie': credentials['quark']!.trim(),
    if ((credentials['uc'] ?? '').trim().isNotEmpty)
      'ucCookie': credentials['uc']!.trim(),
    // UC 电视端设备授权令牌（非会员原画）；与 ucCookie 分开注入。
    if ((credentials['ucToken'] ?? '').trim().isNotEmpty)
      'ucToken': credentials['ucToken']!.trim(),
    if ((credentials['baidu'] ?? '').trim().isNotEmpty)
      'baiduCookie': credentials['baidu']!.trim(),
    if ((credentials['115'] ?? '').trim().isNotEmpty)
      '115Cookie': credentials['115']!.trim(),
    // Cloud_ali 只认 `token`，且要求长度恰为 32（阿里 refresh_token 正是 32 位）；
    // 其它阿里系载荷读 `aliyunCookie` / `aliToken`，一并写上。
    if (ali.isNotEmpty) 'aliyunCookie': ali,
    if (aliToken.isNotEmpty) 'aliToken': aliToken,
    if (aliToken.isNotEmpty) 'token': aliToken,
    // 迅雷 / 光鸭在 TVBox 生态里没有统一键名，按各家族实际读取的三种写法都写一份。
    if (thunder.isNotEmpty) 'xunleiToken': thunder,
    if (thunder.isNotEmpty) 'xunleiCookie': thunder,
    if (thunder.isNotEmpty) 'thunderCookie': thunder,
    if (guangya.isNotEmpty) 'guangyaToken': guangya,
    if (guangya.isNotEmpty) 'guangyaCookie': guangya,
    if ((credentials['bili'] ?? '').trim().isNotEmpty)
      'biliCookie': credentials['bili']!.trim(),
  };
  if (body.isEmpty) return;

  final content = jsonEncode(body);
  try {
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    if (!file.existsSync() || file.readAsStringSync() != content) {
      file.writeAsStringSync(content, flush: true);
    }
  } catch (_) {
    // 写盘失败不阻断播放调用，下次再试。
  }
}
