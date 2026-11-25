import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/windows_config_storage.dart';

/// 用户协议与免责声明的接受状态。
///
/// 单独一份文件、不塞进 `settings_*`：它记录的是「同意」这件事本身，
/// 不是用户可以随手改的偏好，也不该被设置页的保存失败横幅牵连。
/// 放在同一个数据目录下，「重置所有设置」自然也会一并清掉，重新确认一次。
class AgreementStore {
  AgreementStore({Future<Directory> Function()? directory})
      : _directory = directory ?? WindowsConfigStorage().getStorageDirectory;

  static const String fileName = 'agreement.json';

  /// 条款版本。文案有实质改动时 +1，老用户会重新看到一次确认。
  static const int currentVersion = 1;

  final Future<Directory> Function() _directory;

  Future<File> _file() async =>
      File(p.join((await _directory()).path, fileName));

  /// 是否已同意**当前版本**的条款。
  ///
  /// 读不到 / 文件损坏 / 版本不符一律当作未同意：宁可多确认一次，
  /// 也不要让一个坏文件冒充「用户已同意」。
  Future<bool> isAccepted() async {
    try {
      final file = await _file();
      if (!await file.exists()) return false;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return false;
      return (decoded['version'] as num?)?.toInt() == currentVersion;
    } catch (_) {
      return false;
    }
  }

  /// 记录同意。先写临时文件再改名，避免断电留下半截 JSON。
  Future<void> accept() async {
    final file = await _file();
    final payload = jsonEncode({
      'version': currentVersion,
      'acceptedAt': DateTime.now().toUtc().toIso8601String(),
    });
    final temp = File('${file.path}.tmp-$pid');
    try {
      await temp.writeAsString(payload, flush: true);
      await temp.rename(file.path);
    } finally {
      try {
        if (await temp.exists()) await temp.delete();
      } on FileSystemException {
        // 清理失败不影响已写入的目标文件
      }
    }
  }
}
