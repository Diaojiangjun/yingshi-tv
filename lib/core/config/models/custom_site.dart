import 'dart:math';

import 'vod_config.dart';

/// 用户自建的站源（不来自订阅配置，单独落盘）。
///
/// 与配置里的站点共用 [Site] 契约：key 固定为 `xgc_<id>`，编辑时 id 不变，
/// 因此播放历史、收藏、首页站源偏好不会因为改名而失联。
class CustomSite {
  /// 稳定标识；为空表示新建（保存时由 [newId] 生成）。
  final String id;
  final String name;

  /// 接口：JAR 蜘蛛为 `csp_类名`，普通站源为接口地址。
  final String api;

  /// JAR 地址：http(s) 或本地绝对路径；非 JAR 站源为空。
  final String jar;
  final String ext;

  /// 0 XML / 1 JSON / 3 蜘蛛 / 4 HTTP。自建站源默认 3。
  final int type;
  final bool searchable;
  final bool filterable;

  const CustomSite({
    this.id = '',
    required this.name,
    required this.api,
    this.jar = '',
    this.ext = '',
    this.type = 3,
    this.searchable = true,
    this.filterable = true,
  });

  bool get isNew => id.isEmpty;

  String get key => '$prefix$id';

  /// 自建站源的 key 前缀：与配置里的 key 隔离，避免互相覆盖。
  static const String prefix = 'xgc_';

  /// 扫描出的类名统一落成 `csp_Xxx`，与配置里的写法一致。
  static String apiForClass(String className) {
    final simple = className.split('.').last.trim();
    if (simple.isEmpty) return '';
    return simple.startsWith('csp_') ? simple : 'csp_$simple';
  }

  static String newId() {
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final salt = Random().nextInt(46656).toRadixString(36).padLeft(3, '0');
    return '$stamp$salt';
  }

  Site toSite() => Site(
        key: key,
        name: name,
        type: type,
        api: api,
        jar: jar.trim().isEmpty ? null : jar.trim(),
        ext: ext.trim().isEmpty ? null : ext,
        searchable: searchable ? 1 : 0,
        filterable: filterable ? 1 : 0,
      );

  CustomSite copyWith({
    String? id,
    String? name,
    String? api,
    String? jar,
    String? ext,
    int? type,
    bool? searchable,
    bool? filterable,
  }) =>
      CustomSite(
        id: id ?? this.id,
        name: name ?? this.name,
        api: api ?? this.api,
        jar: jar ?? this.jar,
        ext: ext ?? this.ext,
        type: type ?? this.type,
        searchable: searchable ?? this.searchable,
        filterable: filterable ?? this.filterable,
      );

  /// 缺字段的记录按「无效」跳过（由调用方丢弃），只要求 id / api / 名称之一存在。
  static CustomSite? tryFromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final api = json['api']?.toString().trim() ?? '';
    final name = json['name']?.toString().trim() ?? '';
    if (id.isEmpty || (api.isEmpty && name.isEmpty)) return null;
    return CustomSite(
      id: id,
      name: name.isEmpty ? id : name,
      api: api,
      jar: json['jar']?.toString() ?? '',
      ext: json['ext']?.toString() ?? '',
      type: int.tryParse('${json['type'] ?? ''}') ?? 3,
      searchable: json['searchable'] != false,
      filterable: json['filterable'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'api': api,
        'jar': jar,
        'ext': ext,
        'type': type,
        'searchable': searchable,
        'filterable': filterable,
      };
}
