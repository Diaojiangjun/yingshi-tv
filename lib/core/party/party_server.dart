import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'party_state.dart';

/// 「一起看」的局域网 HTTP 服务。
///
/// 只做一件事：把房主当前房间以只读 JSON 暴露给同一局域网的其他设备。
/// **不转发媒体流**——观众本地各自解析自己的播放地址，服务里只有几百字节状态。
///
/// 安全边界：
///   · 只监听 IPv4，不做公网映射（家用路由器默认也不转发）；
///   · `/party` 必须带房间码，房间码只显示在房主界面上；
///   · 只提供 GET，没有任何写入 / 读文件 / 代理端点；
///   · 不返回 CORS 头，网页无法跨站读取响应。
class PartyServer {
  PartyServer({required this.deviceName});

  /// 默认端口；被占用时回落到系统分配的临时端口。
  static const int defaultPort = 9979;

  /// 协议版本，方便将来同时兼容新旧客户端。
  static const int apiVersion = 1;

  final String Function() deviceName;

  /// 房间数据（房主进程内直接读写这个对象，不经过 HTTP）。
  final PartyRoom room = PartyRoom();

  HttpServer? _server;
  int _port = 0;

  bool get running => _server != null;
  int get port => _port;

  /// 启动服务；已启动时直接返回既有端口（幂等）。
  Future<int> start({int port = defaultPort}) async {
    final existing = _server;
    if (existing != null) return _port;
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } on SocketException {
      // 端口被别的程序占了（或上一轮没退干净）：改由系统分配。
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    server.autoCompress = false;
    _server = server;
    _port = server.port;
    // 单个请求出错不应带走整个服务（例如观众中途关掉客户端）。
    server.listen(_handle, onError: (Object _) {});
    return _port;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _port = 0;
    room.clear();
    if (server != null) {
      await server.close(force: true);
    }
  }

  /// 本机的局域网 IPv4 地址（用于界面展示，不含回环）。
  Future<List<String>> lanAddresses() async {
    final out = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final item in interfaces) {
        for (final address in item.addresses) {
          if (address.isLoopback) continue;
          if (!out.contains(address.address)) out.add(address.address);
        }
      }
    } catch (_) {
      // 拿不到网卡列表时退到回环地址，界面仍能显示一个可用值。
    }
    if (out.isEmpty) out.add('127.0.0.1');
    return out;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != 'GET') {
        await _json(response, 405, {'error': 'method not allowed'});
        return;
      }
      switch (request.uri.path) {
        case '/ping':
          await _json(response, 200, {
            'app': 'xiugou-tv',
            'api': apiVersion,
            'name': deviceName(),
            'party': room.open,
          });
          return;
        case '/party':
          final code = (request.uri.queryParameters['code'] ?? '').trim();
          if (!room.open || code.isEmpty || code != room.code) {
            // 房间不存在与房间码不对返回同一个响应：不给枚举探测留口子。
            await _json(response, 403, {'error': 'room not found'});
            return;
          }
          await _json(response, 200, room.toJson());
          return;
        default:
          await _json(response, 404, {'error': 'not found'});
          return;
      }
    } catch (e) {
      await _json(response, 500, {'error': '$e'});
    }
  }

  Future<void> _json(
    HttpResponse response,
    int status,
    Map<String, dynamic> body,
  ) async {
    response.statusCode = status;
    response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    final bytes = utf8.encode(jsonEncode(body));
    response.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }
}

/// 局域网客户端（观众侧）。**直连，不走系统代理**——
/// 系统代理通常是本机翻墙端口，走它反而访问不到 192.168.x.x。
class PartyClient {
  PartyClient._();

  static Future<Map<String, dynamic>> getJson(
    String url, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    client.connectionTimeout = timeout;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      final text = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(timeout);
      final decoded = jsonDecode(text);
      if (decoded is! Map) throw const FormatException('应答不是 JSON 对象');
      return Map<String, dynamic>.from(decoded);
    } finally {
      client.close(force: true);
    }
  }
}
