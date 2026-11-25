import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../net/http_client_factory.dart';
import '../net/system_proxy.dart';

/// 在线字幕源共用的极简 HTTP 取字节/取文本（UA / 超时 / 体积上限）。
///
/// 走 [HttpClientFactory]：与弹幕、豆瓣同一条链路（系统代理 + 安全 DNS）。
/// 失败返回 null 不抛——单源失败不该让整次搜索报错。
const String subtitleBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

const int _htmlMax = 4 * 1024 * 1024;
const int _fileMax = 20 * 1024 * 1024;

/// 原始响应（需要看状态码时使用，assrt API 依赖它区分 400 / 其它）。
class SubtitleHttpResponse {
  const SubtitleHttpResponse(this.statusCode, this.bytes);

  final int statusCode;
  final List<int> bytes;
}

class SubtitleHttp {
  SubtitleHttp({this.timeout = const Duration(seconds: 15)});

  final Duration timeout;

  /// 取原始响应；网络异常 / 超时 / 超限返回 null。
  Future<SubtitleHttpResponse?> getResponse(
    String url, {
    bool html = false,
    int? maxBytes,
    Map<String, String>? headers,
  }) async {
    final max = maxBytes ?? (html ? _htmlMax : _fileMax);
    final client = HttpClientFactory.createHttpClient(
      connectionTimeout: const Duration(seconds: 8),
      userAgent: subtitleBrowserUserAgent,
      proxy: () => SystemProxy.current,
    );
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      request.followRedirects = true;
      request.headers.set(HttpHeaders.acceptHeader,
          html ? 'text/html,application/xhtml+xml,*/*;q=0.8' : '*/*');
      request.headers
          .set(HttpHeaders.acceptLanguageHeader, 'zh-CN,zh;q=0.9,en;q=0.8');
      for (final entry in (headers ?? const <String, String>{}).entries) {
        request.headers.set(entry.key, entry.value);
      }
      final response = await request.close().timeout(timeout);
      final builder = BytesBuilder(copy: false);
      await for (final part in response.timeout(timeout)) {
        if (builder.length + part.length > max) {
          await response.listen(null).cancel();
          return null;
        }
        builder.add(part);
      }
      final bytes = builder.takeBytes();
      if (bytes.isEmpty) return null;
      return SubtitleHttpResponse(response.statusCode, bytes);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 取二进制（字幕包 / 字幕文件）；取不到或非 200 返回 null。
  Future<List<int>?> getBytes(
    String url, {
    int? maxBytes,
    Map<String, String>? headers,
  }) async {
    final res = await getResponse(url, maxBytes: maxBytes, headers: headers);
    return res != null && res.statusCode == 200 ? res.bytes : null;
  }

  /// 取 HTML / JSON 文本（UTF-8；取不到返回 null）。
  Future<String?> getText(
    String url, {
    Map<String, String>? headers,
  }) async {
    final res = await getResponse(url, html: true, headers: headers);
    if (res == null || res.statusCode != 200) return null;
    final text = utf8.decode(res.bytes, allowMalformed: true);
    return text.trim().isEmpty ? null : text;
  }
}
