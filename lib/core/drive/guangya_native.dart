import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'drive_descriptor.dart';

/// 光鸭云盘分享链接 / 描述符 → 可播放直链（只读，不转存）。
///
/// 分享页本身无需登录：先用 shareId（+ 提取码）换分享访问令牌，再列目录、
/// 取该文件的分享下载地址。分享者未开启「免登录下载」时，需要绑定光鸭账号
/// （账号 Token 会作为 Bearer 一起带上）。
Future<NativeDriveLink> resolveGuangyaDirect(
  String text, {
  required String token,
  String flag = '',
  String episodeName = '',
}) async {
  final ref = _parseGuangyaShare(text);
  if (ref == null) return NativeDriveLink.failed('无法识别光鸭云盘分享链接');
  final account = _accountToken(token);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final shareToken = await _shareAccessToken(client, ref, account);
    if (shareToken.isEmpty) {
      return NativeDriveLink.failed('光鸭分享令牌获取失败（提取码错误或分享已失效）');
    }
    final files = <_GFile>[];
    await _collect(
      client,
      shareToken,
      account,
      '',
      files,
      depth: 0,
      wanted: _episodeKeys(episodeName),
      budget: <int>[80],
    );
    if (files.isEmpty) return NativeDriveLink.failed('光鸭分享为空或没有访问权限');
    final target = _pickTarget(files, ref.fileId, episodeName);
    if (target == null) {
      return NativeDriveLink.failed(
        episodeName.isEmpty ? '光鸭分享中没有可播放文件' : '光鸭分享中未找到匹配的剧集文件',
      );
    }
    final download = await _download(client, shareToken, account, target.id);
    if (download.url.isEmpty) {
      return NativeDriveLink.failed(download.reason);
    }
    return NativeDriveLink(
      ok: true,
      url: download.url,
      headers: <String, String>{
        HttpHeaders.userAgentHeader: _ua,
        HttpHeaders.refererHeader: 'https://www.guangyapan.com/',
      },
    );
  } catch (error) {
    return NativeDriveLink.failed('光鸭云盘解链失败：$error');
  } finally {
    client.close(force: true);
  }
}

const _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const _api = 'https://api.guangyapan.com/nd.bizuserres.s/v1';
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

class _GuangyaShareRef {
  const _GuangyaShareRef({
    required this.shareId,
    required this.code,
    this.fileId = '',
  });

  final String shareId;
  final String code;
  final String fileId;
}

class _GFile {
  const _GFile({required this.id, required this.name, required this.isDir});

  final String id;
  final String name;
  final bool isDir;
}

_GuangyaShareRef? _parseGuangyaShare(String text) {
  final value = text.trim();
  if (value.isEmpty) return null;
  final descriptor = parseDriveDescriptor(value);
  if (descriptor != null && descriptor.provider == 'guangya') {
    final shareId = descriptorField(descriptor.data, <String>[
      'share_id',
      'shareId',
      'sid',
    ]);
    if (shareId.isEmpty) return null;
    return _GuangyaShareRef(
      shareId: shareId,
      code: descriptorField(descriptor.data, <String>[
        'code',
        'pwd',
        'passcode',
        'password',
      ]),
      fileId: descriptorField(descriptor.data, <String>[
        'file_id',
        'fileId',
        'fid',
      ]),
    );
  }
  final match = RegExp(
    r'(?:https?://)?(?:[\w-]+\.)*guangyapan\.(?:com|cn)/s/([^/?#\s]+)',
    caseSensitive: false,
  ).firstMatch(value);
  if (match == null) return null;
  var code = '';
  final query = RegExp(
    r'[?&](?:code|pwd|password|passcode)=([^&\s#]+)',
  ).firstMatch(value);
  if (query != null) code = query.group(1) ?? '';
  return _GuangyaShareRef(shareId: match.group(1)!, code: code);
}

String _accountToken(String credential) {
  final value = credential.trim();
  if (!value.startsWith('{')) return value;
  try {
    final decoded = jsonDecode(value);
    if (decoded is Map) {
      final access =
          '${decoded['access_token'] ?? decoded['accessToken'] ?? ''}'.trim();
      if (access.isNotEmpty) return access;
    }
  } catch (_) {
    // 按原值使用。
  }
  return '';
}

Map<String, String> _headers(String account) => <String, String>{
  HttpHeaders.userAgentHeader: _ua,
  HttpHeaders.acceptHeader: 'application/json, text/plain, */*',
  HttpHeaders.contentTypeHeader: 'application/json',
  'origin': 'https://www.guangyapan.com',
  'referer': 'https://www.guangyapan.com/',
  'did': _generateDid(),
  'dt': '4',
  if (account.isNotEmpty) HttpHeaders.authorizationHeader: 'Bearer $account',
};

String _generateDid() {
  final random = Random.secure();
  return List<String>.generate(
    16,
    (_) => random.nextInt(16).toRadixString(16),
  ).join();
}

Future<String> _shareAccessToken(
  HttpClient client,
  _GuangyaShareRef ref,
  String account,
) async {
  final json = await _post(client, '$_api/get_share_access_token', account, {
    'shareId': ref.shareId,
    'code': ref.code,
  });
  return _digString(json, <Object>['data', 'accessToken']);
}

/// 递归列分享目录；命中目标集（或没有指定集名时的第一个媒体）就提前返回。
///
/// [budget] 是请求次数上限：大型合集可能有上百个子目录，不能无限制扫下去。
Future<bool> _collect(
  HttpClient client,
  String shareToken,
  String account,
  String parentId,
  List<_GFile> out, {
  required int depth,
  required Set<String> wanted,
  required List<int> budget,
}) async {
  if (depth > 4 || out.length > 600 || budget[0] <= 0) return false;
  for (var page = 1; page <= 10 && budget[0] > 0; page++) {
    budget[0]--;
    final json =
        await _post(client, '$_api/get_share_page_files_list', account, {
          'accessToken': shareToken,
          'parentId': parentId,
          'page': page,
          'pageSize': 100,
          'orderBy': 0,
          'sortType': 0,
        });
    final data = json['data'];
    if (data is! Map) return false;
    final list = data['list'];
    if (list is! List || list.isEmpty) return false;
    for (final item in list) {
      if (item is! Map) continue;
      final id = '${item['fileId'] ?? ''}'.trim();
      final name = '${item['fileName'] ?? ''}'.trim();
      if (id.isEmpty || name.isEmpty) continue;
      // resType：1=文件，2=目录（实测样本）；没有该字段时按扩展名兜底。
      final resType = item['resType'];
      final ext = '${item['ext'] ?? ''}'.trim();
      final isDir = resType == 2 || (resType == null && ext.isEmpty);
      if (isDir) {
        final found = await _collect(
          client,
          shareToken,
          account,
          id,
          out,
          depth: depth + 1,
          wanted: wanted,
          budget: budget,
        );
        if (found) return true;
        continue;
      }
      // 分享里常混着封面图 / 字幕 / 说明文件：只收媒体，避免第一张图就把扫描提前结束。
      if (!_isMedia(name)) continue;
      out.add(_GFile(id: id, name: name, isDir: false));
      if (wanted.isEmpty || _episodeKeys(name).any(wanted.contains)) {
        return true;
      }
    }
    final total = int.tryParse('${data['total'] ?? ''}') ?? 0;
    if (list.length < 100 || (total > 0 && page * 100 >= total)) break;
  }
  return false;
}

_GFile? _pickTarget(List<_GFile> files, String fileId, String episodeName) {
  final media = files
      .where((file) => !file.isDir && _isMedia(file.name))
      .toList(growable: false);
  if (media.isEmpty) return null;
  if (fileId.isNotEmpty) {
    for (final file in media) {
      if (file.id == fileId) return file;
    }
  }
  final wanted = _episodeKeys(episodeName);
  if (wanted.isNotEmpty) {
    for (final file in media) {
      if (_episodeKeys(file.name).any(wanted.contains)) return file;
    }
    return null;
  }
  return media.first;
}

bool _isMedia(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return false;
  return _mediaExt.contains(name.substring(dot + 1).toLowerCase());
}

Set<String> _episodeKeys(String value) {
  final out = <String>{};
  final lower = value.toLowerCase();
  for (final match in RegExp(r'\d+').allMatches(lower)) {
    final number = match.group(0)!;
    out.add('$number集');
    out.add('e$number');
    out.add('第$number');
  }
  final normalized = lower.replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fa5]'), '');
  if (normalized.isNotEmpty) out.add(normalized);
  return out;
}

Future<({String url, String reason})> _download(
  HttpClient client,
  String shareToken,
  String account,
  String fileId,
) async {
  final json = await _post(client, '$_api/get_share_download_url', account, {
    'fileId': fileId,
    'accessToken': shareToken,
  });
  final data = json['data'];
  final url = _urlOf(data);
  if (url.isNotEmpty) return (url: url, reason: '');
  final code = json['code'];
  if (code == 207) {
    return (url: '', reason: '分享者未开启免登录下载，请先在设置里绑定光鸭账号');
  }
  final message = '${json['msg'] ?? json['message'] ?? ''}'.trim();
  return (
    url: '',
    reason: '光鸭分享下载地址获取失败${message.isEmpty ? '' : '（$message）'}',
  );
}

String _urlOf(Object? data) {
  if (data is String) return data.trim();
  if (data is Map) {
    for (final key in const <String>[
      'url',
      'downloadUrl',
      'download_url',
      'link',
    ]) {
      final value = '${data[key] ?? ''}'.trim();
      if (value.isNotEmpty) return value;
    }
  }
  return '';
}

String _digString(Map<String, dynamic> json, List<Object> path) {
  Object? current = json;
  for (final key in path) {
    if (current is Map) {
      current = current[key];
    } else if (current is List && key is int && key < current.length) {
      current = current[key];
    } else {
      return '';
    }
  }
  return '${current ?? ''}'.trim();
}

Future<Map<String, dynamic>> _post(
  HttpClient client,
  String url,
  String account,
  Map<String, Object?> body,
) async {
  final request = await client.postUrl(Uri.parse(url));
  _headers(account).forEach(request.headers.set);
  final text = jsonEncode(body);
  request.headers.contentLength = utf8.encode(text).length;
  request.write(text);
  final response = await request.close();
  final raw = await response.transform(utf8.decoder).join();
  final decoded = jsonDecode(raw);
  return decoded is Map
      ? decoded.map((key, value) => MapEntry(key.toString(), value))
      : <String, dynamic>{};
}
