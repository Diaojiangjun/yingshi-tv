import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../config/windows_config_storage.dart';
import '../storage/data_restore_guard.dart';
import 'drive_account.dart';
import 'drive_provider.dart';

/// 本机网盘凭据存储：单个 DPAPI 加密文件。
///
/// 与 WebDAV 连接记录（`webdav_connections.bin`）同一套做法：
///   · 明文只在内存里出现，落盘前交给系统 DPAPI（`yingshi/secrets` 通道）；
///   · 读写都带文件锁 + 临时文件 rename，避免半个文件；
///   · 数据恢复待重启时拒绝写入（[DataRestorePendingRestartException]）。
class DriveAccountStore {
  static const fileName = 'drive_accounts.bin';
  static const lockFileName = 'drive_accounts.lock';

  /// 一张网盘一个槽位，留出余量给以后扩展。
  static const maxAccounts = 12;

  static const _maxBytes = 1024 * 1024;
  static Future<void> _writes = Future<void>.value();
  static int _sequence = 0;

  final Future<Directory> Function() _directory;
  final MethodChannel _channel;

  DriveAccountStore({
    Future<Directory> Function()? directory,
    MethodChannel? channel,
  }) : _directory = directory ?? WindowsConfigStorage().getStorageDirectory,
       _channel = channel ?? const MethodChannel('yingshi/secrets');

  /// 读取全部已保存账号；文件不存在返回空表，文件损坏抛 [FormatException]。
  Future<List<DriveAccount>> read() async {
    try {
      await _writes;
      final dir = await _directory();
      if (!await dir.exists()) return const <DriveAccount>[];
      final lock = await File(
        p.join(dir.path, lockFileName),
      ).open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.blockingExclusive);
        return await _read(File(p.join(dir.path, fileName)));
      } finally {
        await lock.close();
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('已保存的网盘账号无法读取，可重新登录');
    }
  }

  Future<List<DriveAccount>> _read(File file) async {
    if (!await file.exists()) return const <DriveAccount>[];
    if (await file.length() > _maxBytes) throw const FormatException();
    final encrypted = await file.readAsBytes();
    final clear = await _channel.invokeMethod<Uint8List>(
      'unprotect',
      encrypted,
    );
    if (clear == null || clear.isEmpty || clear.length > _maxBytes) {
      throw const FormatException();
    }
    final Object? decoded = jsonDecode(utf8.decode(clear));
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['accounts'] is! List) {
      throw const FormatException();
    }
    final values = decoded['accounts'] as List;
    if (values.length > maxAccounts) throw const FormatException();
    final entries = <DriveAccount>[];
    final providers = <String>{};
    for (final value in values) {
      final account = DriveAccount.fromJson(value);
      if (account == null || driveProviderById(account.provider) == null) {
        throw const FormatException();
      }
      if (!providers.add(account.provider)) throw const FormatException();
      entries.add(account);
    }
    return List<DriveAccount>.unmodifiable(entries);
  }

  /// 保存（同 provider 覆盖）并返回最新全表。
  Future<List<DriveAccount>> save(DriveAccount account) => _change((entries) {
    final remaining = entries
        .where((entry) => entry.provider != account.provider)
        .toList();
    if (remaining.length >= maxAccounts) {
      throw const DriveAccountStoreException('最多保存 $maxAccounts 个网盘账号');
    }
    return <DriveAccount>[account, ...remaining];
  });

  /// 删除某个 provider 的账号并返回最新全表。
  Future<List<DriveAccount>> remove(String provider) => _change(
    (entries) => entries.where((entry) => entry.provider != provider).toList(),
  );

  Future<List<DriveAccount>> _change(
    List<DriveAccount> Function(List<DriveAccount>) update,
  ) {
    final operation = _writes.then((_) async {
      if (dataRestorePendingRestart) {
        throw const DataRestorePendingRestartException();
      }
      final dir = await _directory();
      await dir.create(recursive: true);
      final lock = await File(
        p.join(dir.path, lockFileName),
      ).open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.blockingExclusive);
        if (dataRestorePendingRestart) {
          throw const DataRestorePendingRestartException();
        }
        final file = File(p.join(dir.path, fileName));
        final entries = List<DriveAccount>.unmodifiable(
          update(await _read(file)),
        );
        final clear = Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'version': 1,
              'accounts': entries.map((entry) => entry.toJson()).toList(),
            }),
          ),
        );
        final Uint8List? encrypted;
        try {
          if (clear.length > _maxBytes) {
            throw const DriveAccountStoreException('账号记录过大');
          }
          encrypted = await _channel.invokeMethod<Uint8List>('protect', clear);
        } finally {
          clear.fillRange(0, clear.length, 0);
        }
        if (encrypted == null ||
            encrypted.isEmpty ||
            encrypted.length > _maxBytes) {
          throw const DriveAccountStoreException('系统未能安全保存账号');
        }
        final temporary = File('${file.path}.tmp-$pid-${++_sequence}');
        try {
          await temporary.writeAsBytes(encrypted, flush: true);
          if (dataRestorePendingRestart) {
            throw const DataRestorePendingRestartException();
          }
          await temporary.rename(file.path);
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
        return entries;
      } finally {
        await lock.close();
      }
    });
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation.onError((Object error, StackTrace stack) {
      if (error is DataRestorePendingRestartException) throw error;
      if (error is DriveAccountStoreException) throw error;
      throw const FormatException('网盘账号未保存，请检查数据目录权限或重试；原记录已保留');
    });
  }
}

/// 可直接展示给用户的保存条件错误。
class DriveAccountStoreException extends FormatException {
  const DriveAccountStoreException(super.message);
}
