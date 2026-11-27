import 'dart:convert';
import 'dart:io';

import 'drive_descriptor.dart';

/// 阿里云盘分享链接 / 描述符 → 可播放直链（只读，不转存）。
///
/// 账号凭据是 refresh_token：先换 access_token，再取 share_token，
/// 最后调用分享下载地址接口。需要用户已保存阿里云盘 Token。
Future<NativeDriveLink> resolveAliyunDirect(
  String text, {
  required String token,
  String flag = '',
  String episodeName = '',
}) async {
  final credential = token.trim();
  if (credential.isEmpty) {
    return NativeDriveLink.failed('未绑定阿里云盘账号（Token 缺失）');
  }
  final ref = _parseAliShare(text);
  if (ref == null) return NativeDriveLink.failed('无法识别阿里云盘分享链接');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final accessToken = await _accessToken(client, credential);
    if (accessToken.isEmpty) {
      return NativeDriveLink.failed('阿里云盘 Token 无效或已过期');
    }
    final shareToken = await _shareToken(client, ref);
    if (shareToken.isEmpty) {
      return NativeDriveLink.failed('阿里分享令牌获取失败，请检查提取码');
    }
    final files = <_AliFile>[];
    await _collect(client, ref, shareToken, 'root', files, depth: 0);
    final target = _pickTarget(files, ref.fileId, episodeName);
    if (target == null) {
      return NativeDriveLink.failed(
        episodeName.isEmpty ? '阿里分享中没有可播放文件' : '阿里分享中未找到匹配的剧集文件',
      );
    }
    final driveId = ref.driveId.isNotEmpty
        ? ref.driveId
        : (target.driveId.isNotEmpty ? target.driveId : _firstDrive(files));
    final url = await _downloadUrl(
      client,
      ref,
      target.id,
      driveId,
      accessToken,
      shareToken,
    );
    if (url.isEmpty) return NativeDriveLink.failed('阿里云盘直链获取失败');
    return NativeDriveLink(
      ok: true,
      url: url,
      headers: <String, String>{
        HttpHeaders.userAgentHeader: _ua,
        HttpHeaders.refererHeader: 'https://www.alipan.com/',
      },
    );
  } catch (error) {
    return NativeDriveLink.failed('阿里云盘解链失败：$error');
  } finally {
    client.close(force: true);
  }
}

const _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const _canary = 'client=web,app=share,version=v2.3.1';
const _mediaExt = <String>{
  'mp4',
  'mkv',
  'avi',
  'ts',
  'm2ts',
  'mov',
  'flv',
  'wmv',
  'webm',
  'm4v',
  'rmvb',
  'rm',
  'mpg',
  'mpeg',
  'mp3',
  'flac',
  'm4a',
  'aac',
  'wav',
  'ogg',
};

class _AliShareRef {
  const _AliShareRef({
    required this.shareId,
    required this.password,
    this.fileId = '',
    this.driveId = '',
    this.name = '',
  });

  final String shareId;
  final String password;
  final String fileId;
  final String driveId;
  final String name;
}

_AliShareRef? _parseAliShare(String text) {
  final value = text.trim();
  if (value.isEmpty) return null;
  final descriptor = parseDriveDescriptor(value);
  if (descriptor != null &&
      (descriptor.provider == 'ali' ||
          descriptor.provider == 'aliyun' ||
          descriptor.provider == 'alipan')) {
    final shareId = descriptorField(descriptor.data, <String>[
      'share_id',
      'shareId',
      'shareid',
      'share',
    ]);
    if (shareId.isEmpty) return null;
    return _AliShareRef(
      shareId: shareId,
      password: descriptorField(descriptor.data, <String>[
        'share_pwd',
        'sharePwd',
        'password',
        'pwd',
        'passcode',
      ]),
      fileId: descriptorField(descriptor.data, <String>[
        'file_id',
        'fileId',
        'fid',
      ]),
      driveId: descriptorField(descriptor.data, <String>[
        'drive_id',
        'driveId',
      ]),
      name: descriptorField(descriptor.data, <String>['name', 'fileName']),
    );
  }
  final match = RegExp(
    r'(?:https?://)?(?:[\w-]+\.)*(?:alipan|aliyundrive)\.com/s/([A-Za-z0-9]+)'
    r'(?:/folder/([A-Za-z0-9]+))?(?:\?([^\s]*))?',
    caseSensitive: false,
  ).firstMatch(value);
  if (match == null) return null;
  var password = '';
  final query = match.group(3) ?? '';
  if (query.isNotEmpty) {
    final uri = Uri.tryParse('https://x/?$query');
    password =
        uri?.queryParameters['pwd'] ??
        uri?.queryParameters['password'] ??
        uri?.queryParameters['passcode'] ??
        '';
  }
  return _AliShareRef(
    shareId: match.group(1)!,
    password: password,
    fileId: match.group(2) ?? '',
  );
}

class _AliFile {
  const _AliFile({
    required this.id,
    required this.name,
    required this.isDir,
    required this.driveId,
  });

  final String id;
  final String name;
  final bool isDir;
  final String driveId;
}

Future<String> _accessToken(HttpClient client, String credential) async {
  var refreshToken = credential;
  var accessToken = '';
  if (credential.startsWith('{') && credential.endsWith('}')) {
    try {
      final decoded = jsonDecode(credential);
      if (decoded is Map) {
        refreshToken = (decoded['refresh_token'] ?? '').toString();
        accessToken = (decoded['access_token'] ?? '').toString();
      }
    } catch (_) {
      // 保留原样，按 refresh_token 尝试。
    }
  }
  if (refreshToken.isNotEmpty) {
    try {
      final json = await _postJson(
        client,
        Uri.https('auth.alipan.com', '/v2/account/token'),
        <String, Object?>{
          'refresh_token': refreshToken,
          'grant_type': 'refresh_token',
        },
      );
      final token = (json['access_token'] ?? '').toString();
      if (token.isNotEmpty) return token;
    } catch (_) {
      // 失败后再把原值当 access_token 试一次。
    }
  }
  return accessToken.isNotEmpty ? accessToken : credential;
}

Future<String> _shareToken(HttpClient client, _AliShareRef ref) async {
  final body = <String, Object?>{'share_id': ref.shareId};
  if (ref.password.isNotEmpty) body['share_pwd'] = ref.password;
  final json = await _postJson(
    client,
    Uri.https('api.alipan.com', '/v2/share_link/get_share_token'),
    body,
  );
  return (json['share_token'] ?? '').toString();
}

Future<void> _collect(
  HttpClient client,
  _AliShareRef ref,
  String shareToken,
  String parentId,
  List<_AliFile> out, {
  required int depth,
}) async {
  if (depth > 5 || out.length > 800) return;
  var marker = '';
  do {
    final body = <String, Object?>{
      'share_id': ref.shareId,
      'parent_file_id': parentId,
      'limit': 200,
      'order_by': 'name',
      'order_direction': 'ASC',
      'image_thumbnail_process': 'image/resize,w_160/format,jpeg',
      'video_thumbnail_process': 'video/snapshot,t_1000,f_jpg,ar_auto,w_300',
      'image_url_process': 'image/resize,w_1920/format,jpeg',
    };
    if (marker.isNotEmpty) body['marker'] = marker;
    final json = await _postJson(
      client,
      Uri.https('api.alipan.com', '/adrive/v3/file/list'),
      body,
      headers: <String, String>{'x-share-token': shareToken},
    );
    final items = json['items'];
    if (items is! List) break;
    for (final item in items) {
      if (item is! Map) continue;
      final id = (item['file_id'] ?? '').toString();
      final name = (item['name'] ?? '').toString();
      if (id.isEmpty || name.isEmpty) continue;
      final isDir = (item['type'] ?? '') == 'folder';
      final driveId = (item['drive_id'] ?? '').toString();
      out.add(_AliFile(id: id, name: name, isDir: isDir, driveId: driveId));
      if (isDir) {
        await _collect(client, ref, shareToken, id, out, depth: depth + 1);
      }
    }
    marker = (json['next_marker'] ?? '').toString();
  } while (marker.isNotEmpty);
}

_AliFile? _pickTarget(List<_AliFile> files, String fileId, String episodeName) {
  if (fileId.isNotEmpty) {
    for (final file in files) {
      if (file.id == fileId && !file.isDir) return file;
    }
  }
  final media = files
      .where((file) => !file.isDir && _isMedia(file.name))
      .toList(growable: false);
  if (media.isEmpty) return null;
  final wanted = _episodeKeys(episodeName);
  if (wanted.isNotEmpty) {
    for (final file in media) {
      if (_episodeKeys(file.name).any(wanted.contains)) return file;
    }
    return null;
  }
  return media.first;
}

String _firstDrive(List<_AliFile> files) {
  for (final file in files) {
    if (file.driveId.isNotEmpty) return file.driveId;
  }
  return '';
}

bool _isMedia(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return false;
  return _mediaExt.contains(name.substring(dot + 1).toLowerCase());
}

Set<String> _episodeKeys(String value) {
  final out = <String>{};
  final lower = value.toLowerCase();
  final digits = RegExp(r'\d+').allMatches(lower).map((m) => m.group(0)!);
  for (final number in digits) {
    out.add('$number集');
    out.add('e$number');
    out.add('第$number');
  }
  final normalized = lower.replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fa5]'), '');
  if (normalized.isNotEmpty) out.add(normalized);
  return out;
}

Future<String> _downloadUrl(
  HttpClient client,
  _AliShareRef ref,
  String fileId,
  String driveId,
  String accessToken,
  String shareToken,
) async {
  final json = await _postJson(
    client,
    Uri.https('api.alipan.com', '/v2/file/get_share_link_download_url'),
    <String, Object?>{
      'drive_id': driveId,
      'file_id': fileId,
      'share_id': ref.shareId,
      'expire_sec': 600,
    },
    headers: <String, String>{
      'authorization': 'Bearer $accessToken',
      'x-share-token': shareToken,
    },
  );
  return (json['download_url'] ?? json['url'] ?? '').toString();
}

Future<Map<String, dynamic>> _postJson(
  HttpClient client,
  Uri uri,
  Map<String, Object?> body, {
  Map<String, String> headers = const <String, String>{},
}) async {
  final request = await client.postUrl(uri);
  final payload = utf8.encode(jsonEncode(body));
  request.headers
    ..set(HttpHeaders.userAgentHeader, _ua)
    ..set(HttpHeaders.refererHeader, 'https://www.alipan.com/')
    ..set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*')
    ..set(HttpHeaders.contentTypeHeader, 'application/json')
    ..set('X-Canary', _canary);
  for (final entry in headers.entries) {
    request.headers.set(entry.key, entry.value);
  }
  request.headers.contentLength = payload.length;
  request.add(payload);
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  final decoded = jsonDecode(text);
  if (decoded is! Map) {
    throw const FormatException('阿里接口返回非 JSON');
  }
  final code = (decoded['code'] ?? '').toString();
  if (code.isNotEmpty && code != 'Success') {
    throw FormatException((decoded['message'] ?? '阿里接口错误 $code').toString());
  }
  return decoded.map((key, value) => MapEntry(key.toString(), value));
}
