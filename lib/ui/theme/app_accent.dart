import 'package:flutter/material.dart';

import '../../core/settings/models/appearance_preferences.dart';

/// 一套主题色在某一明暗下的五个相关色。
///
/// 与 [AppPalette] 的分工一致：**填充**用 [fill]（主按钮底 / 选中胶囊底），
/// **前景**用 [ink]（图标 / 文字 / 进度条 / 选中描边），[wash] 是浅色块底，
/// [selectionFill] / [selectionInk] 用于列表持久选中态。
@immutable
class AccentColors {
  const AccentColors({
    required this.fill,
    required this.ink,
    required this.wash,
    required this.selectionFill,
    required this.selectionInk,
  });

  final Color fill;
  final Color ink;
  final Color wash;
  final Color selectionFill;
  final Color selectionInk;
}

/// 主题色 × 明暗 → 具体色值。
///
/// 同一色相在深浅主题各给一套：深色主题的填充是低明度雾面（白字 8:1 以上），
/// 浅色主题的填充是高明度粉彩（深字 9:1 以上），两组都不直接把填充当文字用。
/// 取值与 [AppPalette.dark] / [AppPalette.light] 的既有品牌色同明度，
/// 因此换色只改色相、不改对比度与观感层次。
AccentColors accentColorsFor(AppAccent accent, Brightness brightness) {
  final table = brightness == Brightness.dark ? _dark : _light;
  return table[accent]!;
}

const Map<AppAccent, AccentColors> _dark = {
  AppAccent.graphite: AccentColors(
    fill: Color(0xFF414A5B),
    ink: Color(0xFF94A3B8),
    wash: Color(0xFF232632),
    selectionFill: Color(0xFF163A60),
    selectionInk: Color(0xFF83C4FF),
  ),
  AppAccent.mist: AccentColors(
    fill: Color(0xFF3E516B),
    ink: Color(0xFF9DC0E8),
    wash: Color(0xFF1E2430),
    selectionFill: Color(0xFF1A3B5F),
    selectionInk: Color(0xFF8FC6FF),
  ),
  AppAccent.matcha: AccentColors(
    fill: Color(0xFF45543F),
    ink: Color(0xFFA7C79A),
    wash: Color(0xFF1F261D),
    selectionFill: Color(0xFF1E3B26),
    selectionInk: Color(0xFF86DB9B),
  ),
  AppAccent.amber: AccentColors(
    fill: Color(0xFF5A4736),
    ink: Color(0xFFE0B48A),
    wash: Color(0xFF262019),
    selectionFill: Color(0xFF4A3218),
    selectionInk: Color(0xFFFFC078),
  ),
  AppAccent.lavender: AccentColors(
    fill: Color(0xFF4B4463),
    ink: Color(0xFFC3B2E8),
    wash: Color(0xFF23202E),
    selectionFill: Color(0xFF35285A),
    selectionInk: Color(0xFFC7A6FF),
  ),
  AppAccent.berry: AccentColors(
    fill: Color(0xFF5A3B44),
    ink: Color(0xFFE3A0AE),
    wash: Color(0xFF261C20),
    selectionFill: Color(0xFF4C1E2B),
    selectionInk: Color(0xFFFF9DB1),
  ),
};

const Map<AppAccent, AccentColors> _light = {
  AppAccent.graphite: AccentColors(
    fill: Color(0xFFD8E3F8),
    ink: Color(0xFF334155),
    wash: Color(0xFFE4EBFA),
    selectionFill: Color(0xFFC5D9F8),
    selectionInk: Color(0xFF1D4ED8),
  ),
  AppAccent.mist: AccentColors(
    fill: Color(0xFFD3E1F7),
    ink: Color(0xFF2F4A6B),
    wash: Color(0xFFE1EBF9),
    selectionFill: Color(0xFFBFD8F5),
    selectionInk: Color(0xFF1B4E9B),
  ),
  AppAccent.matcha: AccentColors(
    fill: Color(0xFFDCE9D4),
    ink: Color(0xFF3A4C2E),
    wash: Color(0xFFE7F0E0),
    selectionFill: Color(0xFFCBE3BC),
    selectionInk: Color(0xFF2F6B2A),
  ),
  AppAccent.amber: AccentColors(
    fill: Color(0xFFF6E3CB),
    ink: Color(0xFF6B4A22),
    wash: Color(0xFFFAEDDD),
    selectionFill: Color(0xFFF1D5B2),
    selectionInk: Color(0xFF8A4B0B),
  ),
  AppAccent.lavender: AccentColors(
    fill: Color(0xFFE5DDF7),
    ink: Color(0xFF4A3A72),
    wash: Color(0xFFEDE7FA),
    selectionFill: Color(0xFFD8CDF3),
    selectionInk: Color(0xFF5B34C0),
  ),
  AppAccent.berry: AccentColors(
    fill: Color(0xFFF7D9DF),
    ink: Color(0xFF6E2B3A),
    wash: Color(0xFFFBE6EA),
    selectionFill: Color(0xFFF3C6D0),
    selectionInk: Color(0xFFA31E3F),
  ),
};
