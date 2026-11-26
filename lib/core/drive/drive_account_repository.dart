import 'dart:async';

import 'package:flutter/foundation.dart';

import 'drive_account.dart';
import 'drive_account_store.dart';
import 'drive_credential.dart';
import 'drive_probe.dart';
import 'drive_provider.dart';

/// 网盘账号的内存缓存 + 落盘 + 在线校验。
///
/// UI 只跟这个类打交道：`ensureLoaded()` 拉一次 → 监听通知 → 读写。
class DriveAccountRepository extends ChangeNotifier {
  DriveAccountRepository({DriveAccountStore? store, DriveProbe? probe})
    : _store = store ?? DriveAccountStore(),
      _probe = probe ?? DriveProbe();

  final DriveAccountStore _store;
  final DriveProbe _probe;

  Map<String, DriveAccount> _accounts = const <String, DriveAccount>{};
  bool _loaded = false;
  bool _loading = false;
  String? _error;
  Future<void>? _loadingFuture;

  Map<String, DriveAccount> get accounts => _accounts;
  bool get loaded => _loaded;
  bool get loading => _loading;

  /// 读取失败时的提示（文件损坏 / 权限）；`null` 表示正常。
  String? get error => _error;

  int get loggedInCount => _accounts.values
      .where((account) => account.credential.trim().isNotEmpty)
      .length;

  DriveAccount? accountOf(String provider) => _accounts[provider];

  String credentialOf(String provider) =>
      _accounts[provider]?.credential.trim() ?? '';

  /// 注入给解析层 / 蜘蛛的 `{provider: credential}` 表（未登录的不出现）。
  Map<String, String> credentialMap() => <String, String>{
    for (final entry in _accounts.entries)
      if (entry.value.credential.trim().isNotEmpty)
        entry.key: entry.value.credential.trim(),
  };

  /// 只加载一次；并发调用共享同一个 Future。
  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loadingFuture ??= _load();
  }

  Future<void> _load() async {
    _loading = true;
    notifyListeners();
    try {
      final entries = await _store.read();
      _accounts = <String, DriveAccount>{
        for (final entry in entries) entry.provider: entry,
      };
      _error = null;
      _loaded = true;
    } on FormatException catch (error) {
      _error = error.message;
      _loaded = true;
    } catch (_) {
      _error = '已保存的网盘账号无法读取，可重新登录';
      _loaded = true;
    } finally {
      _loading = false;
      _loadingFuture = null;
      notifyListeners();
    }
  }

  /// 清洗 + 校验 + 保存。
  ///
  /// 即使在线校验判定失效也会保存（并把 `state` 记成 expired），
  /// 这样用户能在面板上看到「已保存但需要重新登录」，而不是粘贴完直接消失。
  Future<DriveProbeResult> save(String providerId, String raw) async {
    final provider = driveProviderById(providerId);
    if (provider == null) {
      return DriveProbeResult(
        provider: providerId,
        valid: false,
        message: '未知网盘：$providerId',
      );
    }
    await ensureLoaded();
    final credential = normalizeDriveCredentialInput(
      raw,
      token: provider.usesToken,
    );
    if (credential.isEmpty) {
      return DriveProbeResult(
        provider: provider.id,
        valid: false,
        message: provider.usesToken ? 'Token 为空' : 'Cookie 为空',
      );
    }
    if (!driveCredentialHasAuth(
      token: provider.usesToken,
      authNames: provider.authNames,
      credential: credential,
    )) {
      return DriveProbeResult(
        provider: provider.id,
        valid: false,
        credential: credential,
        message: driveCredentialMissingHint(
          token: provider.usesToken,
          authNames: provider.authNames,
          readyNames: provider.readyNames,
          credential: credential,
        ),
      );
    }
    final result = await _probe.check(provider, credential);
    final stored = result.credential.isEmpty ? credential : result.credential;
    final extra = <String, String>{
      if (_accounts[provider.id] != null) ..._accounts[provider.id]!.extra,
      'state': switch (result.valid) {
        true => 'ok',
        false => 'expired',
        null => 'unknown',
      },
      'checkedAt': DateTime.now().millisecondsSinceEpoch.toString(),
    };
    final account = DriveAccount(
      provider: provider.id,
      credential: stored,
      username: result.username,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      extra: extra,
    );
    final entries = await _store.save(account);
    _apply(entries);
    return DriveProbeResult(
      provider: result.provider,
      valid: result.valid,
      username: result.username,
      credential: stored,
      message: result.message,
    );
  }

  /// 重新校验已保存的账号（面板上的「检测」）。
  Future<DriveProbeResult> revalidate(String providerId) async {
    final provider = driveProviderById(providerId);
    final account = _accounts[providerId];
    if (provider == null || account == null) {
      return DriveProbeResult(
        provider: providerId,
        valid: null,
        message: '该网盘还没有保存登录态',
      );
    }
    final credential = account.credential.trim();
    if (credential.isEmpty) {
      return DriveProbeResult(
        provider: providerId,
        valid: false,
        message: '登录态为空',
      );
    }
    final result = await _probe.check(provider, credential);
    final stored = result.credential.isEmpty ? credential : result.credential;
    final entries = await _store.save(
      account.copyWith(
        credential: stored,
        username: result.username.isEmpty ? account.username : result.username,
        extra: <String, String>{
          ...account.extra,
          'state': switch (result.valid) {
            true => 'ok',
            false => 'expired',
            null => 'unknown',
          },
          'checkedAt': DateTime.now().millisecondsSinceEpoch.toString(),
        },
      ),
    );
    _apply(entries);
    return result;
  }

  Future<void> remove(String providerId) async {
    await ensureLoaded();
    final entries = await _store.remove(providerId);
    _apply(entries);
  }

  void _apply(List<DriveAccount> entries) {
    _accounts = <String, DriveAccount>{
      for (final entry in entries) entry.provider: entry,
    };
    _error = null;
    notifyListeners();
  }
}
