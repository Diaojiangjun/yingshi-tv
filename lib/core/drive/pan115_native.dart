import 'dart:convert';
import 'dart:io';

import 'drive_descriptor.dart';
import 'pan115_crypto.dart';

/// 115 分享链接 / 描述符 → 可播放直链（只读，不转存）。
///
/// 优先走网页分享接口；网页接口拒绝时，回退到 App 分享下载接口
/// （使用 m115 加密载荷）。需要用户已保存 115 Cookie。
Future<NativeDriveLink> resolve115Direct(
  String text, {
  required String cookie,
  String flag = '',
  String episodeName = '',
}) async {
  final base = cookie.trim();
  if (base.isEmpty) {
    return NativeDriveLink.failed('未绑定 115 账号（Cookie 缺失）');
  }
  final ref = _parse115Share(text);
  if (ref == null) return NativeDriveLink.failed('无法识别 115 分享链接');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final files = <_Pan115File>[];
    await _collect(
      client,
      ref,
      ref.fileId.isEmpty ? '' : '',
      base,
      files,
      depth: 0,
    );
    if (files.isEmpty) return NativeDriveLink.failed('115 分享为空或需要提取码');
    final target = _pickTarget(files, ref.fileId, episodeName);
    if (target == null) {
      return NativeDriveLink.failed(
        episodeName.isEmpty ? '115 分享中没有可播放文件' : '115 分享中未找到匹配的剧集文件',
      );
    }
    final url = await _download(client, ref, target.id, base);
    if (url.isEmpty) return NativeDriveLink.failed('115 直链获取失败');
    return NativeDriveLink(
      ok: true,
      url: url,
      headers: <String, String>{
        HttpHeaders.userAgentHeader: _ua,
        HttpHeaders.refererHeader: _referer(ref),
        HttpHeaders.cookieHeader: base,
      },
    );
  } catch (error) {
    return NativeDriveLink.failed('115 解链失败：$error');
  } finally {
    client.close(force: true);
  }
}

const _ua = 'Mozilla/5.0 115Browser/27.0.5.7';
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

class _Pan115ShareRef {
  const _Pan115ShareRef({
    required this.code,
    required this.password,
    this.fileId = '',
    this.name = '',
  });

  final String code;
  final String password;
  final String fileId;
  final String name;
}

String _referer(_Pan115ShareRef ref) =>
    'https://115cdn.com/s/${ref.code}?password=${ref.password}&';

_Pan115ShareRef? _parse115Share(String text) {
  final value = text.trim();
  if (value.isEmpty) return null;
  final descriptor = parseDriveDescriptor(value);
  if (descriptor != null && descriptor.provider == '115') {
    final code = descriptorField(descriptor.data, <String>[
      'share_code',
      'shareCode',
      'code',
      'shareId',
      'share_id',
    ]);
    if (code.isEmpty) return null;
    return _Pan115ShareRef(
      code: code,
      password: descriptorField(descriptor.data, <String>[
        'receive_code',
        'receiveCode',
        'password',
        'pwd',
        'passcode',
      ]),
      fileId: descriptorField(descriptor.data, <String>[
        'file_id',
        'fileId',
        'fid',
      ]),
      name: descriptorField(descriptor.data, <String>['name', 'fileName']),
    );
  }
  final match = RegExp(
    r'(?:https?://)?(?:[\w-]+\.)*115(?:cdn)?\.com/s/([A-Za-z0-9]+)'
    r'(?:\?([^\s]*))?',
    caseSensitive: false,
  ).firstMatch(value);
  if (match == null) return null;
  var password = '';
  final query = match.group(2) ?? '';
  if (query.isNotEmpty) {
    final uri = Uri.tryParse('https://x/?$query');
    password =
        uri?.queryParameters['password'] ??
        uri?.queryParameters['pwd'] ??
        uri?.queryParameters['p'] ??
        '';
  }
  if (password.isEmpty) {
    final pwd = RegExp(
      r'(?:password|pwd|提取码|访问码|码)\s*[:：=]?\s*([A-Za-z0-9]{1,12})',
      caseSensitive: false,
    ).firstMatch(value);
    password = pwd?.group(1)?.trim() ?? '';
  }
  return _Pan115ShareRef(code: match.group(1)!, password: password);
}

class _Pan115File {
  const _Pan115File({
    required this.id,
    required this.name,
    required this.isDir,
  });

  final String id;
  final String name;
  final bool isDir;
}

Future<void> _collect(
  HttpClient client,
  _Pan115ShareRef ref,
  String cid,
  String cookie,
  List<_Pan115File> out, {
  required int depth,
}) async {
  if (depth > 4 || out.length > 800) return;
  final query = <String, String>{
    'share_code': ref.code,
    'receive_code': ref.password,
    'cid': cid,
    'limit': '120',
    'offset': '0',
    'asc': '0',
    'format': 'json',
  };
  final json = await _getJson(
    client,
    Uri.https('115cdn.com', '/webapi/share/snap', query),
    cookie: cookie,
    referer: _referer(ref),
  );
  final data = json['data'];
  if (json['state'] != true || data is! Map) {
    final message = json['error'] ?? json['msg'] ?? '分享接口返回异常';
    throw FormatException(message.toString());
  }
  final list = data['list'];
  if (list is! List) return;
  for (final item in list) {
    if (item is! Map) continue;
    final isDir = item['fc'] == 0;
    final id = isDir
        ? (item['cid'] ?? item['fid'] ?? '').toString()
        : (item['fid'] ?? item['cid'] ?? '').toString();
    final name = (item['n'] ?? item['name'] ?? '').toString();
    if (id.isEmpty || name.isEmpty) continue;
    out.add(_Pan115File(id: id, name: name, isDir: isDir));
    if (isDir) {
      await _collect(client, ref, id, cookie, out, depth: depth + 1);
    }
  }
}

_Pan115File? _pickTarget(
  List<_Pan115File> files,
  String fileId,
  String episodeName,
) {
  if (fileId.isNotEmpty) {
    for (final file in files) {
      if (file.id == fileId) return file;
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
  return media.length == 1 ? media.first : media.first;
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

Future<String> _download(
  HttpClient client,
  _Pan115ShareRef ref,
  String fileId,
  String cookie,
) async {
  final legacy = await _downloadLegacy(client, ref, fileId, cookie);
  if (legacy.isNotEmpty) return legacy;
  return _downloadApp(client, ref, fileId, cookie);
}

Future<String> _downloadLegacy(
  HttpClient client,
  _Pan115ShareRef ref,
  String fileId,
  String cookie,
) async {
  try {
    final json = await _getJson(
      client,
      Uri.https('115cdn.com', '/webapi/share/downurl', <String, String>{
        'share_code': ref.code,
        'receive_code': ref.password,
        'file_id': fileId,
        'dl': '1',
      }),
      cookie: cookie,
      referer: _referer(ref),
    );
    if (json['state'] != true) return '';
    final data = json['data'];
    if (data is Map) {
      final url = data['url'];
      if (url is Map) return (url['url'] ?? '').toString();
      if (url is String) return url;
    }
    return '';
  } catch (_) {
    return '';
  }
}

Future<String> _downloadApp(
  HttpClient client,
  _Pan115ShareRef ref,
  String fileId,
  String cookie,
) async {
  final key = Pan115Crypto.generateKey();
  final encoded = Pan115Crypto.encode(<String, Object?>{
    'share_code': ref.code,
    'receive_code': ref.password,
    'file_id': fileId,
  }, key);
  final json = await _postForm(
    client,
    Uri.https('proapi.115.com', '/app/share/downurl', <String, String>{
      't': (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
    }),
    <String, String>{'data': encoded},
    cookie: cookie,
    referer: _referer(ref),
  );
  final payload = json['data'];
  final Map<String, dynamic> decoded;
  if (payload is String && payload.isNotEmpty) {
    decoded = Pan115Crypto.decode(payload, key);
  } else if (payload is Map) {
    decoded = payload.map((key, value) => MapEntry(key.toString(), value));
  } else {
    final message = json['error'] ?? json['msg'] ?? 'App 分享接口返回异常';
    throw FormatException(message.toString());
  }
  final url = decoded['url'];
  if (url is Map) return (url['url'] ?? '').toString();
  if (url is String) return url;
  return '';
}

Future<Map<String, dynamic>> _getJson(
  HttpClient client,
  Uri uri, {
  required String cookie,
  required String referer,
}) async {
  final request = await client.getUrl(uri);
  request.headers
    ..set(HttpHeaders.userAgentHeader, _ua)
    ..set(HttpHeaders.refererHeader, referer)
    ..set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*')
    ..set(HttpHeaders.cookieHeader, cookie);
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  final decoded = jsonDecode(body);
  return decoded is Map
      ? decoded.map((key, value) => MapEntry(key.toString(), value))
      : <String, dynamic>{};
}

Future<Map<String, dynamic>> _postForm(
  HttpClient client,
  Uri uri,
  Map<String, String> form, {
  required String cookie,
  required String referer,
}) async {
  final request = await client.postUrl(uri);
  request.headers
    ..set(HttpHeaders.userAgentHeader, _ua)
    ..set(HttpHeaders.refererHeader, referer)
    ..set(HttpHeaders.acceptHeader, 'application/json;charset=UTF-8')
    ..set(HttpHeaders.contentTypeHeader, 'application/x-www-form-urlencoded')
    ..set(HttpHeaders.cookieHeader, cookie);
  final formBody = Uri(queryParameters: form).query;
  request.headers.contentLength = utf8.encode(formBody).length;
  request.write(formBody);
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  final decoded = jsonDecode(body);
  return decoded is Map
      ? decoded.map((key, value) => MapEntry(key.toString(), value))
      : <String, dynamic>{};
}
