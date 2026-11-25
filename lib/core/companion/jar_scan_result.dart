/// 扫描 JAR 内 Spider 类的结果。
///
/// [classes] 为空且 [stage] 非空时，说明 jar 没准备好（下载 / 解密 / dex2jar 失败），
/// 界面据此给出可操作的提示，而不是只说「没找到类」。
class JarScanResult {
  final List<String> classes;
  final String? stage;
  final String? detail;

  const JarScanResult({
    this.classes = const [],
    this.stage,
    this.detail,
  });

  bool get isEmpty => classes.isEmpty;

  /// 类名简写（`com.github.catvod.spider.Xxx` → `Xxx`）。
  static String simpleName(String className) => className.split('.').last;

  /// 对应的 `csp_` 站源 api。
  static String apiFor(String className) {
    final simple = simpleName(className).trim();
    if (simple.isEmpty) return '';
    return simple.startsWith('csp_') ? simple : 'csp_$simple';
  }

  /// 失败阶段的人话说明；无失败阶段时返回 null。
  String? get failureText {
    final stage = this.stage;
    if (stage == null || stage.isEmpty) return null;
    final head = switch (stage) {
      'resolve' => 'JAR 地址无法使用',
      'download' => 'JAR 下载失败',
      'md5' => 'JAR 摘要校验失败',
      'decrypt' => '加固壳解密失败',
      'dex2jar' => 'DEX 转 JVM 失败',
      'class' => 'JAR 内没有 Spider 类',
      _ => '解析失败（$stage）',
    };
    final detail = this.detail;
    return detail == null || detail.isEmpty ? head : '$head：$detail';
  }
}
