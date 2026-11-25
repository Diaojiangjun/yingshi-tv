import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'runtime_component.dart';

/// 安装阶段。UI 只关心「在做什么」，不解析日志文本。
enum RuntimePhase { preparing, probing, downloading, extracting, finalizing, done }

/// 一次安装的进度快照。
class RuntimeProgress {
  const RuntimeProgress({
    required this.phase,
    required this.message,
    required this.value,
    this.receivedBytes = 0,
    this.totalBytes = 0,
  });

  final RuntimePhase phase;

  /// 面向用户的短句，例如「下载 JVM 运行时 12.4 / 46.0 MB」。
  final String message;

  /// 0–1；测速阶段无法准确估计时给一个很小的值。
  final double value;

  final int receivedBytes;
  final int totalBytes;
}

/// 组件安装状态。
class RuntimeStatus {
  const RuntimeStatus({
    required this.component,
    this.installedPath,
    this.bundledPath,
    this.version,
  });

  final RuntimeComponent component;

  /// 下载安装目录（`%APPDATA%/YingshiTV/runtime/<dirName>`），未安装为 null。
  final String? installedPath;

  /// 随安装包提供的目录（开发机 `runtime/jre`、正式包内置时也可能存在）。
  final String? bundledPath;

  /// 下载安装的版本号；随包提供时为空（版本随应用走）。
  final String? version;

  /// 只要有一种来源可用，蜘蛛源就能跑起来。
  bool get usable => installedPath != null || bundledPath != null;

  bool get downloaded => installedPath != null;
}

/// 本机已装、可直接复用的运行时（不是应用下载的那份）。
///
/// 存在这种运行时时，对应的源其实已经能跑——`CompanionProcessManager` 与 Java 侧
/// 的查找链都会回退到 `JAVA_HOME` / PATH。设置页若只读应用目录，就会一边显示
/// 「未安装」一边正常加载，用户无从判断哪种状态是真的。
class ExternalRuntime {
  const ExternalRuntime({
    required this.path,
    required this.versionLabel,
    required this.source,
  });

  /// 可执行文件绝对路径；来自 PATH 时是命令名（`node.exe` 等）。
  final String path;

  /// 展示用版本号（`21.0.9` / `22.22.2` / `3.13.14` / `8.3.37`）。
  final String versionLabel;

  /// 来源标签：`JAVA_HOME` 或 `PATH`，用于文案说明「凭什么能用」。
  final String source;

  /// 路径对用户展示时只保留父目录，太长的全路径会把一行文案挤爆。
  String get displayPath {
    if (!path.contains(Platform.pathSeparator) && !path.contains('/')) {
      return '系统 PATH';
    }
    final dir = p.dirname(path);
    return dir.isEmpty ? path : dir;
  }
}

/// 外部运行时的探测命令。
class _RuntimeProbe {
  const _RuntimeProbe(this.command, this.arguments);
  final String command;
  final List<String> arguments;
}

/// 运行时组件下载 / 安装器。
///
/// 设计要点：
///  * 不依赖 Flutter（只用 dart:io / package:archive），可以直接在命令行里跑通
///    下载-解压-替换全流程，避免「UI 能点但装不上」这种只能靠真人试的错误；
///  * 先解压到同级 `.stage-*` 目录，找到含 `probes` 的那层再整体 rename 到目标位置。
///    中途失败或断电只会留下 stage，不会让半截目录被误判为「已安装」；
///  * 多个镜像并发测速后按速度重排，单线路失败自动换下一个。
class RuntimeInstaller {
  RuntimeInstaller({String? runtimeRoot, List<String>? applicationRoots})
      : _runtimeRootOverride = runtimeRoot,
        _applicationRootsOverride = applicationRoots;

  static final RuntimeInstaller instance = RuntimeInstaller();

  final String? _runtimeRootOverride;
  final List<String>? _applicationRootsOverride;

  /// 同一组件的并发安装共享同一个 Future：连点两次「下载」不该下两份 46 MB。
  final Map<String, Future<void>> _running = {};

  /// 外部运行时探测结果缓存，按组件 id 存。
  final Map<String, Future<ExternalRuntime?>> _externalRuntimeProbes = {};

  /// 安装根目录：`%APPDATA%/YingshiTV/runtime`。
  ///
  /// 必须与 `CompanionProcessManager.javaCandidates` 的 AppData 候选项一致，
  /// 否则装完仍然找不到 java.exe。
  Future<Directory> rootDirectory() async {
    final override = _runtimeRootOverride;
    if (override != null && override.isNotEmpty) return Directory(override);
    final appData = Platform.environment['APPDATA'];
    if (Platform.isWindows && appData != null && appData.isNotEmpty) {
      return Directory(p.join(appData, 'YingshiTV', 'runtime'));
    }
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    return Directory(p.join(home ?? '.', '.local', 'share', 'YingshiTV', 'runtime'));
  }

  /// 随包运行时可能出现的位置：可执行文件目录与开发期工作目录。
  /// 与 `javaCandidates` 的「安装目录优先、再开发回退」保持一致。
  List<String> _applicationRoots() {
    final override = _applicationRootsOverride;
    if (override != null) return override;
    final roots = <String>[];
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      if (exeDir.isNotEmpty) roots.add(exeDir);
    } catch (_) {
      // 极端环境下取不到可执行文件路径，退回工作目录即可。
    }
    roots.add(Directory.current.path);
    return roots;
  }

  bool _hasProbes(Directory dir, RuntimeComponent component) {
    if (!dir.existsSync()) return false;
    for (final probe in component.probes) {
      final file = File(p.join(dir.path, p.joinAll(probe.split('/'))));
      if (!file.existsSync() || file.lengthSync() == 0) return false;
    }
    return true;
  }

  /// 读取状态（不触发下载，供设置页与启动检查调用）。
  Future<RuntimeStatus> status(RuntimeComponent component) async {
    final root = await rootDirectory();
    final installedDir = Directory(p.join(root.path, component.dirName));
    final installed = _hasProbes(installedDir, component);
    String? version;
    if (installed) {
      final marker = File(p.join(installedDir.path, '.version'));
      if (marker.existsSync()) {
        try {
          version = marker.readAsStringSync().trim();
        } catch (_) {
          version = null;
        }
      }
      version ??= component.version;
    }

    String? bundled;
    for (final base in _applicationRoots()) {
      final candidate = Directory(p.join(base, 'runtime', component.dirName));
      if (_hasProbes(candidate, component)) {
        bundled = candidate.path;
        break;
      }
    }

    return RuntimeStatus(
      component: component,
      installedPath: installed ? installedDir.path : null,
      bundledPath: bundled,
      version: version,
    );
  }

  /// 探测本机已有、可直接复用的运行时（不是应用下载的那份）。
  ///
  /// 只回答「现在能不能跑」，不负责安装。对 JVM，顺序与
  /// `CompanionProcessManager.resolveJavaExecutable()` 的后两级一致
  /// （`JAVA_HOME` → PATH）；Node / Python / PHP 的安装位置不可枚举，只查 PATH，
  /// 与 `CatNodeRuntime` / `PyRuntime` / `PhpRuntime` 的兜底分支对应。
  /// 结果按组件缓存，避免每进一次设置页就 spawn 一串 `--version`。
  Future<ExternalRuntime?> externalRuntime(RuntimeComponent component,
      {bool refresh = false}) {
    if (refresh) _externalRuntimeProbes.remove(component.id);
    return _externalRuntimeProbes[component.id] ??=
        _probeExternalRuntime(component);
  }

  Future<ExternalRuntime?> _probeExternalRuntime(
      RuntimeComponent component) async {
    final probe = _probeFor(component.id);
    if (probe == null) return null;
    final executable =
        Platform.isWindows ? '${probe.command}.exe' : probe.command;

    if (component.id == 'jvm') {
      final javaHome = Platform.environment['JAVA_HOME'];
      if (javaHome != null && javaHome.isNotEmpty) {
        final candidate = File(p.join(javaHome, 'bin', executable));
        if (candidate.existsSync()) {
          final found =
              await _runProbe(component, candidate.path, probe, 'JAVA_HOME');
          if (found != null) return found;
        }
      }
    }

    return _runProbe(component, executable, probe, 'PATH');
  }

  Future<ExternalRuntime?> _runProbe(
    RuntimeComponent component,
    String executable,
    _RuntimeProbe probe,
    String source,
  ) async {
    try {
      final result = await Process.run(executable, probe.arguments);
      final output = '${result.stdout}\n${result.stderr}'.trim();
      if (result.exitCode != 0) return null;
      final match = RegExp(r'(\d+)\.(\d+)(?:\.(\d+))?').firstMatch(output);
      if (match == null) return null;
      final major = int.tryParse(match.group(1) ?? '');
      if (major == null) return null;
      // JVM 有硬约束（jar 的 class 主版本），版本不够等于不能用；
      // 其他运行时的兼容范围由脚本自己决定，这里只如实展示版本让用户判断。
      if (component.id == 'jvm' && major < component.majorVersion) return null;
      final label = [match.group(1), match.group(2), match.group(3)]
          .whereType<String>()
          .join('.');
      return ExternalRuntime(
        path: executable,
        versionLabel: label,
        source: source,
      );
    } catch (_) {
      return null;
    }
  }

  static _RuntimeProbe? _probeFor(String id) {
    switch (id) {
      case 'jvm':
        return const _RuntimeProbe('java', ['-version']);
      case 'node':
        return const _RuntimeProbe('node', ['--version']);
      case 'python':
        return const _RuntimeProbe('python', ['--version']);
      case 'php':
        return const _RuntimeProbe('php', ['--version']);
      default:
        return null;
    }
  }

  /// 安装组件；已有安装且非 [force] 时直接返回。
  Future<void> install(
    RuntimeComponent component, {
    void Function(RuntimeProgress progress)? onProgress,
    bool force = false,
  }) {
    final running = _running[component.id];
    if (running != null) return running;

    final task = _install(component, onProgress, force);
    _running[component.id] = task;
    return task.whenComplete(() => _running.remove(component.id));
  }

  /// 删除下载安装的运行时。伴随服务正在使用 `java.exe` 时删除会失败，
  /// 这里转成可读提示，而不是把 Win32 错误码抛给用户。
  Future<void> remove(RuntimeComponent component) async {
    final root = await rootDirectory();
    final dir = Directory(p.join(root.path, component.dirName));
    if (!dir.existsSync()) return;
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException catch (error) {
      throw StateError(
        '删除失败：${error.osError?.message ?? '文件被占用'}。'
        '伴随服务可能正在运行，请先退出应用后重试。',
      );
    }
  }

  // ---------------------------------------------------------------------

  Future<void> _install(
    RuntimeComponent component,
    void Function(RuntimeProgress progress)? onProgress,
    bool force,
  ) async {
    // 多产物时进度是按「第几个产物」粗分的，收尾阶段可能比最后一个产物
    // 刚跳到的值还小；不夹住就会出现进度条倒退。
    var lastValue = 0.0;
    void emit(RuntimePhase phase, String message, double value) {
      final monotonic = value < lastValue ? lastValue : value.clamp(0.0, 1.0);
      lastValue = monotonic;
      onProgress?.call(RuntimeProgress(
        phase: phase,
        message: message,
        value: monotonic,
      ));
    }

    if (!Platform.isWindows) {
      throw StateError('运行时组件目前只支持 Windows');
    }

    final root = await rootDirectory();
    final target = Directory(p.join(root.path, component.dirName));
    if (!force && _hasProbes(target, component)) {
      emit(RuntimePhase.done, '${component.name}已安装', 1);
      return;
    }

    emit(RuntimePhase.preparing,
        '准备下载 ${component.name}（${component.sizeLabel}）…', 0.01);
    root.createSync(recursive: true);

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final stage = Directory(p.join(root.path, '.stage-${component.id}-$stamp'));
    var succeeded = false;

    try {
      stage.createSync(recursive: true);
      final artifacts = component.artifacts;
      for (var i = 0; i < artifacts.length; i++) {
        await _installArtifact(
          component: component,
          artifact: artifacts[i],
          index: i,
          total: artifacts.length,
          stage: stage,
          root: root,
          stamp: stamp,
          emit: emit,
        );
      }

      // 各产物的布局不一样（Adoptium/Node/Python 都多一层目录，PHP 是平铺），
      // 统一在最后下钻找「同时具备所有 probes」的那层，而不是让每个组件各自写死。
      final found = _findRoot(stage, component);
      if (found == null) {
        throw StateError(
          '${component.name}安装包结构异常：未找到 ${component.probes.join(' / ')}',
        );
      }

      emit(RuntimePhase.finalizing, '正在安装 ${component.name}…', 0.97);
      await _applyPostStep(component, found);

      if (target.existsSync()) {
        try {
          target.deleteSync(recursive: true);
        } on FileSystemException {
          throw StateError('目标目录被占用，无法覆盖。请先退出正在使用该运行时的应用。');
        }
      }
      await _moveDirectory(found, target);
      // 版本标记写在目标目录里：删掉或换掉整个目录时版本信息自然失效，
      // 不需要额外的全局状态文件来同步。
      File(p.join(target.path, '.version')).writeAsStringSync(component.version);

      succeeded = true;
      emit(RuntimePhase.done, '${component.name}已就绪', 1);
    } finally {
      _deleteQuietly(stage);
      if (!succeeded) {
        // 失败时清掉可能存在的半截目标目录，避免下次被误判为已安装。
        if (!_hasProbes(target, component)) _deleteQuietly(target);
      }
    }
  }

  /// 安装单个产物。多产物组件（Python 是 1 个解释器 + 14 个 wheel）按序号
  /// 均分进度条，避免「下到第 9 个 wheel 时进度条一直卡在 50%」。
  Future<void> _installArtifact({
    required RuntimeComponent component,
    required RuntimeArtifact artifact,
    required int index,
    required int total,
    required Directory stage,
    required Directory root,
    required int stamp,
    required void Function(RuntimePhase, String, double) emit,
  }) async {
    final base = index / total;
    final span = 1 / total;
    // 单产物组件不显示序号，避免「下载 JVM 运行时（1/1）」这种废话。
    final suffix = total > 1 ? '（${index + 1}/$total）' : '';

    emit(RuntimePhase.probing, '正在为 ${artifact.label} 选择线路$suffix…',
        base + span * 0.02);

    final ranked = await _rankMirrors(artifact.mirrors);
    final download =
        File(p.join(root.path, '.download-${component.id}-$stamp-$index.bin'));
    String? lastError;
    try {
      for (var i = 0; i < ranked.length; i++) {
        final url = ranked[i];
        final host = Uri.tryParse(url)?.host ?? url;
        try {
          await _download(
            url,
            download,
            artifact: artifact,
            onTick: (received, totalBytes) {
              final ratio = totalBytes > 0 ? received / totalBytes : 0.0;
              emit(
                RuntimePhase.downloading,
                '下载 ${artifact.label}$suffix '
                '${_formatSize(received)} / ${totalBytes > 0 ? _formatSize(totalBytes) : '?'}'
                '（$host）',
                base + span * (0.05 + ratio * 0.85),
              );
            },
          );
          lastError = null;
          break;
        } catch (error) {
          lastError = '$host：${_shortError(error)}';
          _deleteQuietly(download);
          // 还有线路就继续试，别让一次 404 把整个安装打死。
          if (i < ranked.length - 1) {
            emit(RuntimePhase.probing, '${artifact.label} 线路不可用，换下一条…',
                base + span * 0.03);
          }
        }
      }
      if (lastError != null) {
        throw StateError(
            '${artifact.label} 下载失败，已尝试 ${ranked.length} 条线路。\n$lastError');
      }

      if (artifact.kind == RuntimeArtifactKind.file) {
        final destination = File(
            p.join(stage.path, artifact.target, artifact.fileName ?? 'artifact'));
        destination.parent.createSync(recursive: true);
        download.copySync(destination.path);
        return;
      }

      emit(RuntimePhase.extracting, '正在解压 ${artifact.label}$suffix…',
          base + span * 0.93);
      final destination = Directory(p.join(stage.path, artifact.target));
      destination.createSync(recursive: true);
      await _extractZip(download, destination);
      _dropPrefixes(destination, artifact.dropPrefixes);
    } finally {
      _deleteQuietly(download);
    }
  }

  /// 删掉产物里用不到的部分（PHP 的 `include/`、`lib/` 是 C 头文件，占一半体积）。
  void _dropPrefixes(Directory root, List<String> prefixes) {
    if (prefixes.isEmpty || !root.existsSync()) return;
    final names = prefixes
        .map((prefix) => prefix.endsWith('/')
            ? prefix.substring(0, prefix.length - 1)
            : prefix)
        .toSet();
    for (final entity in root.listSync(followLinks: false)) {
      if (names.contains(p.basename(entity.path))) _deleteQuietly(entity);
    }
  }

  /// 安装后处理：不同运行时的「最后一公里」不一样，集中在这里而不是散落各处。
  Future<void> _applyPostStep(RuntimeComponent component, Directory root) async {
    switch (component.postStep) {
      case RuntimePostStep.none:
        return;

      case RuntimePostStep.pythonSitePackages:
        // embeddable CPython 的 ._pth 是「隔离模式」的 sys.path：不写进去
        // 就等于没装 site-packages，`import requests` 会直接 ModuleNotFoundError。
        File? pth;
        for (final entity in root.listSync(followLinks: false)) {
          if (entity is File && entity.path.endsWith('._pth')) {
            pth = entity;
            break;
          }
        }
        if (pth == null) {
          throw StateError('Python 运行时缺少 ._pth 配置，压缩包结构异常');
        }
        final kept = <String>[];
        for (final line in pth.readAsLinesSync()) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;
          if (trimmed.startsWith('#')) continue; // 丢掉注释掉的 `#import site`
          if (trimmed.toLowerCase() == 'import site') continue; // 下面统一补
          kept.add(trimmed);
        }
        kept.add(r'Lib\site-packages');
        kept.add('import site');
        pth.writeAsStringSync('${kept.join('\n')}\n');

      case RuntimePostStep.phpVcRuntime:
        // PHP 8.3 是 vs16 构建，需要 VC++ 2015-2022 运行库。应用目录里本来
        // 就有这三个 dll（Flutter Windows 包自带），借过来比要求用户装运行库稳。
        final appDir = File(Platform.resolvedExecutable).parent;
        for (final name in const [
          'vcruntime140.dll',
          'vcruntime140_1.dll',
          'msvcp140.dll',
        ]) {
          final destination = File(p.join(root.path, name));
          if (destination.existsSync()) continue;
          final source = File(p.join(appDir.path, name));
          if (source.existsSync()) source.copySync(destination.path);
        }
    }
  }

  /// 并发测速：每个线路只取首 ~64 KB，读够立刻断开。
  ///
  /// 不做 Range 请求：部分加速站不认 Range，反而把可用线路测成不可用。
  /// 只要拿到 200 且首包有数据就算可用，速度只用于排序。
  Future<List<String>> _rankMirrors(List<String> mirrors) async {
    if (mirrors.length <= 1) return mirrors;

    final scores = await Future.wait(mirrors.map((url) async {
      final watch = Stopwatch()..start();
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      try {
        final request = await client
            .getUrl(Uri.parse(url))
            .timeout(const Duration(seconds: 8));
        request.headers.set(HttpHeaders.userAgentHeader, 'YingshiTV-Runtime/1.0');
        final response = await request.close().timeout(const Duration(seconds: 10));
        if (response.statusCode != HttpStatus.ok) {
          await response.drain<void>();
          return MapEntry(url, 1 << 30);
        }
        var read = 0;
        await for (final chunk in response) {
          read += chunk.length;
          if (read >= 64 * 1024) break;
        }
        watch.stop();
        // 首包都拿不到 16 KB 的线路，排到最后但保留机会（可能是瞬时抖动）。
        return MapEntry(url, read < 16 * 1024 ? 1 << 29 : watch.elapsedMilliseconds);
      } catch (_) {
        return MapEntry(url, 1 << 30);
      } finally {
        client.close(force: true);
      }
    }));

    scores.sort((a, b) => a.value.compareTo(b.value));
    return scores.map((entry) => entry.key).toList();
  }

  Future<void> _download(
    String url,
    File target, {
    required RuntimeArtifact artifact,
    required void Function(int received, int total) onTick,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 45);
    IOSink? sink;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'YingshiTV-Runtime/1.0');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw StateError('HTTP ${response.statusCode}');
      }

      final total = response.contentLength;
      var received = 0;
      var lastEmit = 0;
      sink = target.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastEmit >= 120) {
          lastEmit = now;
          onTick(received, total);
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      onTick(received, total > 0 ? total : received);

      // 加速站返回 200 + HTML 错误页是常见故障。体积阈值对 wheel 不适用
      // （idna 只有几十 KB），改用 zip 魔数判定：所有 zip/wheel 都以 PK 开头。
      if (received < 1024) {
        throw StateError('下载内容异常（仅 $received 字节）');
      }
      if (artifact.kind == RuntimeArtifactKind.zip) {
        final head = await _readHeader(target, 2);
        if (head != 'PK') {
          throw StateError('下载内容不是压缩包（可能是错误页）');
        }
      }
      if (total > 0 && received < total) {
        throw StateError('下载不完整（$received / $total 字节）');
      }
    } finally {
      try {
        await sink?.close();
      } catch (_) {
        // 写盘失败时 close 也可能抛，真实错误已经在上面的异常里。
      }
      client.close(force: true);
    }
  }

  /// 「12.4 MB」「812 KB」——小于 1 MB 按 KB 显示，否则 wheel 会全变成
  /// 「0.0 / 0.0 MB」。
  static String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).round()} KB';
  }

  /// 读文件头几个字节，用来识别 zip 魔数（`PK`）。
  Future<String> _readHeader(File file, int length) async {
    final raf = await file.open();
    try {
      final bytes = await raf.read(length);
      return String.fromCharCodes(bytes);
    } finally {
      await raf.close();
    }
  }

  Future<void> _extractZip(File zip, Directory target) async {
    final input = InputFileStream(zip.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      for (final entry in archive.files) {
        final name = entry.name.replaceAll('\\', '/');
        if (name.startsWith('/') ||
            name.contains('../') ||
            RegExp(r'^[a-zA-Z]:').hasMatch(name)) {
          throw StateError('压缩包包含可疑路径：${entry.name}');
        }
      }
      await extractArchiveToDisk(archive, target.path);
    } on FormatException {
      throw StateError('压缩包损坏或不完整，请重试');
    } finally {
      input.closeSync();
    }
  }

  /// 在解压结果里找「同时具备所有 probes」的那层目录（Adoptium 包多一层
  /// `jdk-21…-jre/`，不同镜像的层级可能不一样）。
  Directory? _findRoot(Directory stage, RuntimeComponent component) {
    final queue = <Directory>[stage];
    for (var depth = 0; depth < 4 && queue.isNotEmpty; depth++) {
      final next = <Directory>[];
      for (final dir in queue) {
        if (_hasProbes(dir, component)) return dir;
        try {
          for (final entity in dir.listSync(followLinks: false)) {
            if (entity is Directory) next.add(entity);
          }
        } on FileSystemException {
          continue;
        }
      }
      queue
        ..clear()
        ..addAll(next);
    }
    return null;
  }

  /// 同卷直接 rename（瞬时）；跨卷退化为递归复制 + 删除源。
  Future<void> _moveDirectory(Directory source, Directory target) async {
    target.parent.createSync(recursive: true);
    try {
      source.renameSync(target.path);
      return;
    } on FileSystemException {
      // 目标卷不同或目录被占用，走复制。
    }
    target.createSync(recursive: true);
    await for (final entity in source.list(recursive: true, followLinks: false)) {
      final relative = p.relative(entity.path, from: source.path);
      final destination = p.join(target.path, relative);
      if (entity is Directory) {
        Directory(destination).createSync(recursive: true);
      } else if (entity is File) {
        File(destination).parent.createSync(recursive: true);
        entity.copySync(destination);
      }
    }
    try {
      source.deleteSync(recursive: true);
    } on FileSystemException {
      // 源目录删不掉不影响可用性，stage 下次清理。
    }
  }

  void _deleteQuietly(FileSystemEntity entity) {
    try {
      if (!entity.existsSync()) return;
      entity.deleteSync(recursive: true);
    } catch (_) {
      // 清理失败不覆盖真实错误。
    }
  }

  String _shortError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '');
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }
}
