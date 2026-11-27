import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:xml/xml.dart';
import '../diagnostics/error_log.dart';
import '../net/http_client_factory.dart';
import '../player/models/player_state.dart';
import 'push_input_resolver.dart';

/// 单次浏览使用的内存凭据；连接记录由独立加密存储负责。
/// 输出的目录与媒体地址须位于同源的选定根目录内。
class WebDavConnection {
  final Uri root;
  final Map<String, String> headers;

  const WebDavConnection._(this.root, this.headers);

  factory WebDavConnection.parse(
    String url, {
    String username = '',
    String password = '',
  }) {
    var uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !_safePath(uri) ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      throw const FormatException('请输入不含凭据、查询参数或片段的完整 HTTP(S) WebDAV 根地址');
    }
    if (!uri.path.endsWith('/')) uri = Uri.parse('$uri/');
    final user = username.trim();
    if (user.contains(':') || (user.isEmpty && password.isNotEmpty)) {
      throw const FormatException('WebDAV 用户名不能为空或包含冒号');
    }
    return WebDavConnection._(
      uri,
      Map.unmodifiable({
        if (user.isNotEmpty)
          'Authorization':
              'Basic ${base64Encode(utf8.encode('$user:$password'))}',
      }),
    );
  }

  bool contains(Uri uri) {
    if (uri.scheme != root.scheme ||
        uri.host != root.host ||
        uri.port != root.port ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !_safePath(uri)) {
      return false;
    }
    final parent = _segments(root);
    final child = _segments(uri);
    return child.length >= parent.length &&
        List.generate(
          parent.length,
          (index) => parent[index] == child[index],
        ).every((matches) => matches);
  }

  MediaPlaySpec playSpec(WebDavEntry entry) {
    if (!contains(entry.uri) || entry.isDirectory || !entry.isMedia) {
      throw const FormatException('请选择此 WebDAV 目录中的媒体文件');
    }
    return MediaPlaySpec(
      url: entry.uri.toString(),
      title: entry.name,
      headers: headers.isEmpty ? null : headers,
    );
  }
}

class WebDavEntry {
  final Uri uri;
  final String name;
  final bool isDirectory;
  final bool isMedia;
  final int? size;

  /// 服务端返回的最后修改时间；未提供或格式非法时为 null。
  final DateTime? modifiedAt;

  const WebDavEntry({
    required this.uri,
    required this.name,
    required this.isDirectory,
    required this.isMedia,
    this.size,
    this.modifiedAt,
  });
}

/// 只读 WebDAV 浏览与媒体直链解析；不自动跟随重定向，也不对根目录外的 href 发请求。
class WebDavRepository {
  final Dio _dio;
  final bool _ownsDio;
  bool _disposed = false;

  WebDavRepository({Dio? dio})
    : _ownsDio = dio == null,
      _dio =
          dio ??
          HttpClientFactory.createDio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
            ),
          );

  Future<List<WebDavEntry>> list(
    WebDavConnection connection, {
    Uri? directory,
  }) async {
    if (_disposed) throw StateError('WebDAV 连接已关闭');
    final target = directory ?? connection.root;
    if (!connection.contains(target) || !target.path.endsWith('/')) {
      throw const FormatException('不能访问选定 WebDAV 根目录之外的位置');
    }
    try {
      final response = await _propfindWithRetry(target, connection);
      final status = response.statusCode ?? 0;
      if (status != 200 && status != 207) {
        await response.data?.stream.listen((_) {}).cancel();
        if (status == 401 || status == 403) {
          throw const FormatException('WebDAV 认证失败或无访问权限，请检查用户名和密码');
        }
        if (status >= 300 && status < 400) {
          throw const FormatException('WebDAV 返回重定向，请填写最终目录地址后重试');
        }
        throw FormatException('WebDAV 返回 HTTP $status');
      }
      final body = response.data;
      if (body == null) throw const FormatException('WebDAV 返回空内容');
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in body.stream.timeout(
        const Duration(seconds: 15),
      )) {
        if (buffer.length + chunk.length > 5 * 1024 * 1024) {
          throw const FormatException('WebDAV 目录响应过大，请使用范围更小的根目录');
        }
        buffer.add(chunk);
      }
      if (_disposed) throw StateError('WebDAV 连接已关闭');
      return _parse(utf8.decode(buffer.takeBytes()), connection, target);
    } on DioException catch (error, stack) {
      // 只在连接层失败时把手原因抛给用户，并记进「错误日志」方便排查
      // （403/404 等已在上面的状态码分支里处理过）。
      final reason = _describeDioFailure(error);
      ErrorLog.instance.record('WebDAV', reason, stack);
      throw FormatException('WebDAV 连接失败：$reason');
    } on TimeoutException {
      throw const FormatException('WebDAV 请求超时，请检查网络后重试');
    } on XmlException {
      throw const FormatException('WebDAV 返回的 XML 无法解析');
    }
  }

  /// 起播前解析媒体直链。
  ///
  /// alist 等 WebDAV 服务常把媒体 302 到对象存储的签名地址，而 mpv 会把
  /// `Authorization` 一起带到跳转目标；对象存储不认 WebDAV 凭据，会直接
  /// 回 400 Bad Request（实测同一签名地址：带 Authorization=400，不带=206）。
  /// 这里先替播放器完成跳转，跨主机时改用签名地址并丢掉凭据。
  /// 预解析失败（弱网 / 超时）时退回原地址，不让这一步挡住播放。
  Future<MediaPlaySpec> resolvePlaySpec(
    WebDavConnection connection,
    WebDavEntry entry,
  ) async {
    final spec = connection.playSpec(entry);
    if (_disposed) throw StateError('WebDAV 连接已关闭');
    late final Response<ResponseBody> response;
    try {
      response = await _withTransientRetry(
        () => _dio.requestUri<ResponseBody>(
          entry.uri,
          options: Options(
            method: 'HEAD',
            headers: connection.headers,
            responseType: ResponseType.stream,
            followRedirects: false,
            validateStatus: (_) => true,
          ),
        ),
      );
    } on DioException catch (error, stack) {
      // 直链解析只是优化：网络抖动时按原地址播放，不新增失败路径。
      ErrorLog.instance.record(
        'WebDAV',
        '取媒体直链失败，改用原地址：${_describeDioFailure(error)}',
        stack,
      );
      return spec;
    }
    await _discardBody(response);
    final status = response.statusCode ?? 0;
    if (status == 401 || status == 403) {
      throw const FormatException('WebDAV 认证失败或无访问权限，请检查用户名和密码');
    }
    if (status >= 300 && status < 400) {
      final location = response.headers.value('location')?.trim() ?? '';
      if (location.isEmpty) {
        throw const FormatException('WebDAV 服务返回重定向但没有目标地址');
      }
      final locationUri = Uri.tryParse(location);
      if (locationUri == null) return spec;
      final redirect = entry.uri.resolveUri(locationUri);
      // 只有跨主机的安全 http(s) 目标才需要去掉凭据；
      // 同源跳转（含 alist 自己的路径）继续用原地址，避免签名地址提前过期。
      if (_isSafeRedirectTarget(redirect) &&
          !_sameOrigin(entry.uri, redirect)) {
        return MediaPlaySpec.vod(url: redirect.toString(), title: spec.title);
      }
      return spec;
    }
    if (status >= 400) {
      throw FormatException('WebDAV 取媒体地址失败：HTTP $status');
    }
    return spec;
  }

  Future<void> _discardBody(Response<ResponseBody> response) async {
    final body = response.data;
    if (body == null) return;
    await body.stream.listen((_) {}).cancel();
  }

  /// PROPFIND 是只读请求：连接层失败（超时 / 被对端重置）重试一次，
  /// 弱网与 Cloudflare 边缘偶发重置时用户就不用自己再点一遍。
  Future<Response<ResponseBody>> _propfindWithRetry(
    Uri target,
    WebDavConnection connection,
  ) async {
    Future<Response<ResponseBody>> send() => _dio.requestUri<ResponseBody>(
      target,
      data:
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<d:propfind xmlns:d="DAV:"><d:prop>'
          '<d:displayname/><d:resourcetype/><d:getcontentlength/>'
          '<d:getcontenttype/><d:getlastmodified/></d:prop></d:propfind>',
      options: Options(
        method: 'PROPFIND',
        headers: {
          ...connection.headers,
          'Depth': '1',
          'Content-Type': 'application/xml; charset=utf-8',
        },
        responseType: ResponseType.stream,
        followRedirects: false,
        validateStatus: (_) => true,
      ),
    );
    return _withTransientRetry(send);
  }

  Future<T> _withTransientRetry<T>(Future<T> Function() send) async {
    try {
      return await send();
    } on DioException catch (error) {
      if (!_isTransientFailure(error)) rethrow;
      if (_disposed) throw StateError('WebDAV 连接已关闭');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (_disposed) throw StateError('WebDAV 连接已关闭');
      return send();
    }
  }

  List<WebDavEntry> _parse(
    String text,
    WebDavConnection connection,
    Uri directory,
  ) {
    final document = XmlDocument.parse(text);
    if (document.rootElement.name.local != 'multistatus') {
      throw const FormatException('返回内容不是 WebDAV 目录，请确认服务根地址');
    }
    final entries = <String, WebDavEntry>{};
    final parent = _segments(directory);
    for (final response in _children(document.rootElement, 'response')) {
      final href = _childText(response, 'href');
      final reference = Uri.tryParse(href);
      if (reference == null || href.isEmpty || !_safePath(reference)) continue;
      var uri = directory.resolveUri(reference);
      if (!connection.contains(uri)) continue;
      final path = _segments(uri);
      if (path.length != parent.length + 1 ||
          !List.generate(
            parent.length,
            (index) => parent[index] == path[index],
          ).every((matches) => matches)) {
        continue;
      }

      final properties = <String, XmlElement>{};
      var successful = false;
      for (final propstat in _children(response, 'propstat')) {
        if (!RegExp(
          r'^\s*HTTP/\S+\s+2\d\d(?:\s|$)',
          caseSensitive: false,
        ).hasMatch(_childText(propstat, 'status'))) {
          continue;
        }
        successful = true;
        for (final prop in _children(propstat, 'prop')) {
          for (final property in prop.childElements) {
            properties[property.name.local] = property;
          }
        }
      }
      if (!successful) continue;
      final type = properties['resourcetype'];
      final isDirectory =
          type != null && _children(type, 'collection').isNotEmpty;
      if (isDirectory && !uri.path.endsWith('/')) uri = Uri.parse('$uri/');
      final display = properties['displayname']?.innerText.trim() ?? '';
      final contentType =
          properties['getcontenttype']?.innerText.toLowerCase() ?? '';
      final size = int.tryParse(
        properties['getcontentlength']?.innerText.trim() ?? '',
      );
      final modifiedAt = _parseHttpDate(
        properties['getlastmodified']?.innerText.trim() ?? '',
      );
      final entry = WebDavEntry(
        uri: uri,
        name: display.isEmpty ? path.last : display,
        isDirectory: isDirectory,
        isMedia:
            !isDirectory &&
            (PushInputResolver.isMediaFileName(path.last) ||
                contentType.startsWith('video/') ||
                contentType.startsWith('audio/') ||
                contentType.startsWith('application/vnd.apple.mpegurl') ||
                contentType.startsWith('application/x-mpegurl')),
        size: size != null && size >= 0 ? size : null,
        modifiedAt: modifiedAt,
      );
      entries.putIfAbsent(uri.toString(), () => entry);
    }
    return List.unmodifiable(
      entries.values.toList()..sort((left, right) {
        if (left.isDirectory != right.isDirectory) {
          return left.isDirectory ? -1 : 1;
        }
        return left.name.toLowerCase().compareTo(right.name.toLowerCase());
      }),
    );
  }

  void dispose() {
    _disposed = true;
    if (_ownsDio) _dio.close(force: true);
  }
}

DateTime? _parseHttpDate(String value) {
  if (value.isEmpty) return null;
  try {
    return HttpDate.parse(value);
  } catch (_) {
    return DateTime.tryParse(value);
  }
}

bool _isSafeRedirectTarget(Uri uri) =>
    const {'http', 'https'}.contains(uri.scheme) &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty &&
    _safePath(uri);

bool _sameOrigin(Uri left, Uri right) =>
    left.scheme == right.scheme &&
    left.host == right.host &&
    left.port == right.port;

/// 连接层偶发失败（握手 / DNS / 被重置），值得原样重试一次。
bool _isTransientFailure(DioException error) {
  const transient = {
    DioExceptionType.connectionTimeout,
    DioExceptionType.connectionError,
    DioExceptionType.unknown,
  };
  if (!transient.contains(error.type)) return false;
  final inner = error.error;
  // 证书问题重试也不会好，别浪费一次往返。
  if (inner is HandshakeException || inner is TlsException) return false;
  return true;
}

/// 把 Dio 的连接类异常翻译成一句能看懂的短原因。
String _describeDioFailure(DioException failure) {
  final inner = failure.error;
  if (inner is HandshakeException || inner is TlsException) {
    return 'TLS 握手失败（证书或协议不被支持）';
  }
  if (inner is SocketException) {
    final osMessage = inner.osError?.message.trim() ?? '';
    if (osMessage.isNotEmpty) return '无法建立连接（$osMessage）';
    final own = inner.message.trim();
    return own.isEmpty ? '无法建立连接' : '无法建立连接（$own）';
  }
  switch (failure.type) {
    case DioExceptionType.connectionTimeout:
      return '连接超时';
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.transformTimeout:
      return '服务响应超时';
    case DioExceptionType.badCertificate:
      return '证书校验未通过';
    case DioExceptionType.cancel:
      return '请求已取消';
    case DioExceptionType.badResponse:
      return '服务返回异常状态';
    case DioExceptionType.connectionError:
    case DioExceptionType.unknown:
      final detail = failure.message?.trim() ?? '';
      return detail.isEmpty ? '网络异常' : '网络异常（$detail）';
  }
}

Iterable<XmlElement> _children(XmlElement element, String name) =>
    element.childElements.where((child) => child.name.local == name);

String _childText(XmlElement element, String name) {
  final nodes = _children(element, name);
  return nodes.isEmpty ? '' : nodes.first.innerText.trim();
}

List<String> _segments(Uri uri) =>
    uri.pathSegments.where((part) => part.isNotEmpty).toList();

bool _safePath(Uri uri) => uri.pathSegments.every(
  (part) => part != '.' && part != '..' && !part.contains(RegExp(r'[/\\\x00]')),
);
