import 'tmdb_preferences.dart';

/// 主题模式（持久化用 `dark|light|system`）。
enum AppThemeMode {
  dark('深色'),
  light('浅色'),
  system('跟随系统');

  const AppThemeMode(this.label);

  final String label;

  static AppThemeMode? tryParse(Object? raw) {
    if (raw is! String) return null;
    for (final mode in AppThemeMode.values) {
      if (mode.name == raw) return mode;
    }
    return null;
  }
}

/// 主题色（持久化用枚举名）。只描述色相，具体色值由 UI 层
/// `accentColorsFor()` 按深浅主题分别给出。
enum AppAccent {
  graphite('冷灰', '经典'),
  mist('雾蓝', '冷静'),
  matcha('抹茶绿', '护眼'),
  amber('暖橙', '温暖'),
  lavender('薰衣草', '柔和'),
  berry('莓红', '热情');

  const AppAccent(this.label, this.hint);

  final String label;
  final String hint;

  static AppAccent? tryParse(Object? raw) {
    if (raw is! String) return null;
    for (final accent in AppAccent.values) {
      if (accent.name == raw) return accent;
    }
    return null;
  }
}

/// 外观偏好：主题 + 壁纸（SET-08 / 主题）。
///
/// 持久化于应用数据目录的 `appearance_preferences.json`。
/// **version 3** 起新增 `accent`（主题色）；version 2 新增 `themeMode`。
/// 读取时兼容 version 1（视为深色）与 version 2（主题色取冷灰），写入一律为 version 3。
///
/// 壁纸只存**文件名**（形如 `current.jpg`）：图片本体由 `WallpaperStore`
/// 复制到 `wallpaper/` 子目录，因此用户移动 / 删除原图不会让壁纸失效；
/// 「恢复默认」只删副本，**不触碰用户原图**。
///
/// 读取规则：版本 / 顶层结构 / 字段类型非法时抛出 [FormatException]（调用方保留原文件）。
class AppearancePreferences {
  static const int formatVersion = 3;

  /// 可读取的历史版本：1 没有主题字段（按深色处理）；2 没有主题色（按冷灰处理）。
  static const Set<int> readableVersions = {1, 2, 3};

  /// 文件名允许的字符集：不含路径分隔符，配合 `WallpaperStore` 的目录约束。
  static final RegExp fileNamePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

  /// 当前壁纸副本的文件名（相对 `wallpaper/` 目录）；null 表示使用默认背景。
  final String? wallpaperFileName;

  /// 主题模式；默认深色（与改造前一致）。
  final AppThemeMode themeMode;

  /// 主题色；默认冷灰（与改造前一致）。
  final AppAccent accent;
  final bool sidebarCollapsed;
  final TmdbPreferences tmdb;

  const AppearancePreferences({
    this.wallpaperFileName,
    this.themeMode = AppThemeMode.dark,
    this.accent = AppAccent.graphite,
    this.sidebarCollapsed = false,
    this.tmdb = const TmdbPreferences(),
  });

  /// 未设置壁纸（默认外观）。
  static const AppearancePreferences none = AppearancePreferences();

  bool get hasWallpaper =>
      wallpaperFileName != null && wallpaperFileName!.isNotEmpty;

  AppearancePreferences withWallpaper(String? fileName) => AppearancePreferences(
        wallpaperFileName: fileName,
        tmdb: tmdb,
        themeMode: themeMode,
        accent: accent,
        sidebarCollapsed: sidebarCollapsed,
      );

  AppearancePreferences withThemeMode(AppThemeMode mode) => AppearancePreferences(
        wallpaperFileName: wallpaperFileName,
        themeMode: mode,
        accent: accent,
        tmdb: tmdb,
        sidebarCollapsed: sidebarCollapsed,
      );

  AppearancePreferences withAccent(AppAccent value) => AppearancePreferences(
        wallpaperFileName: wallpaperFileName,
        themeMode: themeMode,
        accent: value,
        tmdb: tmdb,
        sidebarCollapsed: sidebarCollapsed,
      );

  AppearancePreferences withSidebarCollapsed(bool value) => AppearancePreferences(
        wallpaperFileName: wallpaperFileName,
        themeMode: themeMode,
        accent: accent,
        sidebarCollapsed: value,
        tmdb: tmdb,
      );

  AppearancePreferences withTmdb(TmdbPreferences value) => AppearancePreferences(
        wallpaperFileName: wallpaperFileName,
        themeMode: themeMode,
        accent: accent,
        sidebarCollapsed: sidebarCollapsed,
        tmdb: value,
      );

  static AppearancePreferences fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version is! int || !readableVersions.contains(version)) {
      throw const FormatException('外观偏好格式无效');
    }
    final rawMode = json['themeMode'];
    if (rawMode != null && rawMode is! String) {
      throw const FormatException('外观偏好格式无效');
    }
    // version 1 没有该字段：按深色处理，保证旧文件无损
    AppThemeMode themeMode;
    if (rawMode == null) {
      themeMode = AppThemeMode.dark;
    } else {
      final parsed = AppThemeMode.tryParse(rawMode);
      if (parsed == null) throw const FormatException('外观偏好格式无效');
      themeMode = parsed;
    }

    final rawAccent = json['accent'];
    if (rawAccent != null && rawAccent is! String) {
      throw const FormatException('外观偏好格式无效');
    }
    // version 1 / 2 没有该字段：按冷灰处理，保持旧文件观感不变
    AppAccent accent;
    if (rawAccent == null) {
      accent = AppAccent.graphite;
    } else {
      final parsed = AppAccent.tryParse(rawAccent);
      if (parsed == null) throw const FormatException('外观偏好格式无效');
      accent = parsed;
    }

    final rawCollapsed = json['sidebarCollapsed'];
    if (rawCollapsed != null && rawCollapsed is! bool) {
      throw const FormatException('外观偏好格式无效');
    }
    final sidebarCollapsed = rawCollapsed == true;
    final raw = json['wallpaperFileName'];
    if (raw != null && raw is! String) throw const FormatException('外观偏好格式无效');
    final name = (raw as String?)?.trim() ?? '';
    if (name.isNotEmpty && !fileNamePattern.hasMatch(name)) {
      throw const FormatException('外观偏好格式无效');
    }
    return AppearancePreferences(
      wallpaperFileName: name.isEmpty ? null : name,
      themeMode: themeMode,
      accent: accent,
      sidebarCollapsed: sidebarCollapsed,
      tmdb: TmdbPreferences.fromJson(json['tmdb']),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': formatVersion,
        'wallpaperFileName': wallpaperFileName,
        'themeMode': themeMode.name,
        'accent': accent.name,
        'sidebarCollapsed': sidebarCollapsed,
        if (tmdb != const TmdbPreferences()) 'tmdb': tmdb.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      other is AppearancePreferences &&
      other.wallpaperFileName == wallpaperFileName &&
      other.themeMode == themeMode &&
      other.accent == accent &&
      other.sidebarCollapsed == sidebarCollapsed &&
      other.tmdb == tmdb;

  @override
  int get hashCode =>
      Object.hash(wallpaperFileName, themeMode, accent, sidebarCollapsed, tmdb);

  @override
  String toString() =>
      'AppearancePreferences(wallpaperFileName: $wallpaperFileName, '
      'themeMode: ${themeMode.name}, accent: ${accent.name}, '
      'sidebarCollapsed: $sidebarCollapsed)';
}
