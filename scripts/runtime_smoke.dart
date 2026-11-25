// 运行时组件冒烟脚本：真实下载 → 解压 → 就位 → 跑一次可执行文件。
// 用法：dart run scripts/runtime_smoke.dart [组件id] [安装根目录]
//
// 组件 id：jvm / node / python / php（默认 jvm）。不传安装根目录时落到临时目录，
// 不会污染 %APPDATA% 里真正在用的那份。
//
// 用途：`runtime_component.dart` 里的地址是版本固定的 URL，上游发新版后旧地址会
// 404（PHP 尤其明显）。升级版本号前先跑一遍，能直接看出哪条线路还能用。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yingshi_tv/core/runtime/runtime_component.dart';
import 'package:yingshi_tv/core/runtime/runtime_installer.dart';

Future<void> main(List<String> args) async {
  final id = args.isNotEmpty ? args.first : 'jvm';
  final root = args.length > 1
      ? args[1]
      : p.join(Directory.systemTemp.path, 'xg-runtime-smoke', id);

  final component = runtimeComponents.firstWhere(
    (item) => item.id == id,
    orElse: () => throw StateError(
        '未知组件：$id（可选 ${runtimeComponents.map((c) => c.id).join(' / ')}）'),
  );

  final installer = RuntimeInstaller(runtimeRoot: root);
  final watch = Stopwatch()..start();
  stdout.writeln('component=${component.name} root=$root');
  try {
    await installer.install(
      component,
      force: true,
      onProgress: (progress) {
        stdout.writeln(
            '[${progress.phase.name}] ${progress.value.toStringAsFixed(2)} ${progress.message}');
      },
    );
    final status = await installer.status(component);
    stdout.writeln('installed=${status.installedPath} version=${status.version}');
    if (status.installedPath == null) {
      throw StateError('安装后仍判定为未安装，probes 不匹配：${component.probes}');
    }
    await _verify(component, status.installedPath!);
    stdout.writeln('elapsed=${watch.elapsed.inSeconds}s');
  } catch (error) {
    stdout.writeln('FAILED: $error');
    exitCode = 1;
  }
}

Future<void> _verify(RuntimeComponent component, String dir) async {
  final exe = Platform.isWindows ? '${component.id}.exe' : component.id;
  final binary = File(p.join(dir, exe));
  stdout.writeln('$exe exists=${binary.existsSync()} size=${binary.lengthSync()}');

  final List<String> arguments;
  switch (component.id) {
    case 'jvm':
      arguments = ['-version'];
    case 'python':
      // 顺带验证 wheel 与 ._pth 生效：任何一步错了这里都会 ImportError。
      arguments = [
        '-c',
        'import sys,requests,lxml,numpy,Crypto;'
            'print(sys.version.split()[0], requests.__version__, lxml.__version__)',
      ];
    case 'php':
      arguments = [
        '-n',
        '-d',
        'extension_dir=ext',
        '-d',
        'extension=curl',
        '-d',
        'extension=openssl',
        '-d',
        'extension=mbstring',
        '-m',
      ];
    default:
      arguments = ['--version'];
  }

  final result = await Process.run(
    component.id == 'jvm' ? p.join(dir, 'bin', exe) : binary.path,
    arguments,
  );
  final output = '${result.stdout}${result.stderr}'.trim();
  stdout.writeln('exit=${result.exitCode}');
  stdout.writeln(output.length > 600 ? output.substring(0, 600) : output);
  if (result.exitCode != 0) {
    throw StateError('${component.id} 自检失败');
  }
}
