/// 一条已保存的网盘登录态。
///
/// 只存在本机（DPAPI 加密文件），不上传、不写日志。
class DriveAccount {
  const DriveAccount({
    required this.provider,
    required this.credential,
    required this.updatedAt,
    this.username = '',
    this.extra = const <String, String>{},
  });

  /// 网盘 id（注入键）。
  final String provider;

  /// Cookie 串或 Token。
  final String credential;

  /// 本机保存时间（毫秒时间戳）。
  final int updatedAt;

  /// 账号显示名（校验接口能给出时才有）。
  final String username;

  /// 附加信息：`state`（ok / expired / unknown）、`checkedAt`、`deviceId` 等。
  final Map<String, String> extra;

  /// 最近一次在线校验的结论；`null` 表示从未校验或无法判断。
  bool? get valid => switch (extra['state']) {
    'ok' => true,
    'expired' => false,
    _ => null,
  };

  int get checkedAt => int.tryParse(extra['checkedAt'] ?? '') ?? 0;

  DriveAccount copyWith({
    String? credential,
    String? username,
    int? updatedAt,
    Map<String, String>? extra,
  }) => DriveAccount(
    provider: provider,
    credential: credential ?? this.credential,
    username: username ?? this.username,
    updatedAt: updatedAt ?? this.updatedAt,
    extra: extra ?? this.extra,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider': provider,
    'credential': credential,
    'username': username,
    'updatedAt': updatedAt,
    if (extra.isNotEmpty) 'extra': extra,
  };

  static DriveAccount? fromJson(Object? value) {
    if (value is! Map) return null;
    final provider = (value['provider'] ?? '').toString().trim();
    if (provider.isEmpty) return null;
    final extra = <String, String>{};
    final rawExtra = value['extra'];
    if (rawExtra is Map) {
      for (final entry in rawExtra.entries) {
        extra[entry.key.toString()] = entry.value.toString();
      }
    }
    return DriveAccount(
      provider: provider,
      credential: (value['credential'] ?? '').toString(),
      username: (value['username'] ?? '').toString(),
      updatedAt: (value['updatedAt'] as num?)?.toInt() ?? 0,
      extra: extra,
    );
  }
}
