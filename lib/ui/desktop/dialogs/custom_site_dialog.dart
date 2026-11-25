import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../core/companion/companion_spider_api.dart';
import '../../../core/companion/jar_scan_result.dart';
import '../../../core/config/models/custom_site.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import 'escape_closable.dart';

/// 新建 / 编辑自建站源（重点：本地或远程 JAR 蜘蛛）。
///
/// 类名优先自动扫描：JAR 的下载、加固壳解密、dex→JVM 转换都在伴随服务里完成，
/// 扫到的就是真正会运行的那份类名；扫描不可用时仍可手填 `csp_类名`。
class CustomSiteDialog extends StatefulWidget {
  const CustomSiteDialog({
    super.key,
    this.initial,
    this.spiderApi,
    this.pickJarPath,
    this.scanJar,
  });

  /// 为 null 表示新建。
  final CustomSite? initial;
  final CompanionSpiderApi? spiderApi;

  /// 测试注入用；默认弹系统文件选择器。
  final Future<String?> Function()? pickJarPath;

  /// 测试注入用；默认 [CompanionSpiderApi.scanJar]。
  final Future<JarScanResult> Function(String jar)? scanJar;

  @override
  State<CustomSiteDialog> createState() => _CustomSiteDialogState();
}

class _CustomSiteDialogState extends State<CustomSiteDialog> {
  static const _typeOptions = <(int, String)>[
    (3, '蜘蛛（JAR / JS / PY）'),
    (1, 'CMS JSON 接口'),
    (0, 'CMS XML 接口'),
    (4, 'HTTP 接口'),
  ];

  late final _name =
      TextEditingController(text: widget.initial?.name ?? '');
  late final _jar = TextEditingController(text: widget.initial?.jar ?? '');
  late final _api = TextEditingController(text: widget.initial?.api ?? '');
  late final _ext = TextEditingController(text: widget.initial?.ext ?? '');
  late int _type = widget.initial?.type ?? 3;
  late bool _searchable = widget.initial?.searchable ?? true;
  late bool _filterable = widget.initial?.filterable ?? true;

  bool _scanning = false;
  JarScanResult? _scanResult;
  String? _selectedClass;
  String? _scanError;
  String? _error;

  bool get _editing => widget.initial != null;

  @override
  void dispose() {
    _name.dispose();
    _jar.dispose();
    _api.dispose();
    _ext.dispose();
    super.dispose();
  }

  Future<JarScanResult> _runScan(String jar) {
    final override = widget.scanJar;
    if (override != null) return override(jar);
    final api = widget.spiderApi;
    if (api == null) {
      throw StateError('站点服务不可用，可手动填写 csp_ 类名');
    }
    return api.scanJar(jar);
  }

  Future<void> _pickJar() async {
    try {
      final path = await (widget.pickJarPath ?? _defaultPickJar)();
      if (path == null || path.isEmpty || !mounted) return;
      setState(() {
        _jar.text = path;
        _scanError = null;
      });
      // 选中本地包后直接扫描：用户下一个动作一定是「填类名」。
      await _scan();
    } catch (error) {
      if (!mounted) return;
      setState(() => _scanError = '选择 JAR 失败：$error');
    }
  }

  Future<String?> _defaultPickJar() async {
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'JAR 蜘蛛包', extensions: ['jar', 'zip', 'dex']),
    ]);
    return file?.path;
  }

  Future<void> _scan() async {
    if (_scanning) return;
    final jar = _jar.text.trim();
    if (jar.isEmpty) {
      setState(() => _scanError = '先填写 JAR 地址或选择本地文件');
      return;
    }
    setState(() {
      _scanning = true;
      _scanError = null;
      _scanResult = null;
    });
    try {
      final result = await _runScan(jar);
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanResult = result;
        if (result.isEmpty) {
          _scanError =
              result.failureText ?? 'JAR 内没有找到 Spider 类，请确认是蜘蛛包后重试';
          return;
        }
        // 只有一个候选才直接填：多候选时自动选第一个很容易绑定错的蜘蛛，
        // 让用户在手边的候选里点一下更稳（见下方 ChoiceChip）。
        if (result.classes.length == 1) {
          final only = result.classes.first;
          _selectedClass = only;
          _api.text = JarScanResult.apiFor(only);
          if (_name.text.trim().isEmpty) {
            _name.text = JarScanResult.simpleName(only);
          }
        } else {
          _selectedClass = null;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanError = '扫描失败：${_errorText(error)}';
      });
    }
  }

  void _selectClass(String className) {
    setState(() {
      _selectedClass = className;
      _api.text = JarScanResult.apiFor(className);
      if (_name.text.trim().isEmpty) {
        _name.text = JarScanResult.simpleName(className);
      }
    });
  }

  String? _extError() {
    final text = _ext.text.trim();
    if (text.isEmpty || (!text.startsWith('{') && !text.startsWith('['))) {
      return null;
    }
    try {
      jsonDecode(text);
      return null;
    } catch (_) {
      return 'ext 不是合法 JSON';
    }
  }

  void _save() {
    final name = _name.text.trim();
    final api = _api.text.trim();
    final extError = _extError();
    if (name.isEmpty) {
      setState(() => _error = '请填写站点名称');
      return;
    }
    if (api.isEmpty) {
      setState(() => _error = '请填写接口地址，或扫描 JAR 后选择 spider 类');
      return;
    }
    if (extError != null) {
      setState(() => _error = extError);
      return;
    }
    final jar = _jar.text.trim();
    if (_type == 3 && api.startsWith('csp_') && jar.isEmpty) {
      setState(() => _error = 'csp_ 站源必须指定 JAR 地址');
      return;
    }
    // 本地 JAR 先确认存在：存一个坏路径，用户下次点开站点只会看到「站点暂不可用」。
    final isRemote = jar.startsWith('http://') || jar.startsWith('https://');
    if (jar.isNotEmpty && !isRemote) {
      final path = jar.split(';md5;').first.trim();
      if (!File(path).existsSync()) {
        setState(() => _error = '本地 JAR 不存在：$path');
        return;
      }
    }
    Navigator.of(context).pop(CustomSite(
      id: widget.initial?.id ?? '',
      name: name,
      api: api,
      jar: jar,
      ext: _ext.text.trim(),
      type: _type,
      searchable: _searchable,
      filterable: _filterable,
    ));
  }

  static String _errorText(Object error) =>
      error is StateError ? error.message : error.toString();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final classes = _scanResult?.classes ?? const <String>[];
    return EscapeClosable(
      autofocus: false,
      child: PopScope(
        canPop: !_scanning,
        child: AlertDialog(
          backgroundColor: palette.raised,
          title: Text(
            _editing ? '编辑站点' : '新建站点',
            style: TextStyle(fontSize: AppType.heading, color: palette.textTitle),
          ),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label(context, '站点名称'),
                  TextField(
                    key: const ValueKey('custom-site-name'),
                    controller: _name,
                    enabled: !_scanning,
                    style: TextStyle(
                        fontSize: AppType.label, color: palette.textMain),
                    decoration: const InputDecoration(
                      hintText: '例如：某某影视',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _label(context, '站源类型'),
                  DropdownButtonFormField<int>(
                    initialValue: _type,
                    isDense: true,
                    items: [
                      for (final (value, text) in _typeOptions)
                        DropdownMenuItem(value: value, child: Text(text)),
                    ],
                    onChanged: _scanning
                        ? null
                        : (value) => setState(() => _type = value ?? 3),
                  ),
                  const SizedBox(height: 12),
                  _label(context, 'JAR 地址'),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('custom-site-jar'),
                          controller: _jar,
                          enabled: !_scanning,
                          style: TextStyle(
                              fontSize: AppType.label, color: palette.textMain),
                          decoration: const InputDecoration(
                            hintText: 'https://…/spider.jar 或 C:\\…\\spider.jar',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _scanning ? null : _pickJar,
                        icon: const Icon(Icons.folder_open_rounded, size: 16),
                        label: const Text('选择本地 JAR…'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _scanning ? null : _scan,
                        icon: _scanning
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.manage_search_rounded, size: 16),
                        label: Text(_scanning ? '扫描中…' : '扫描类名'),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _scanning
                              ? '正在下载 / 解密 / 转换 JAR，首次可能要几分钟'
                              : '扫描后可自动填出 csp_ 类名，不必手抄',
                          style: TextStyle(
                              fontSize: AppType.body, color: palette.textSub),
                        ),
                      ),
                    ],
                  ),
                  if (_scanError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _scanError!,
                      key: const ValueKey('custom-site-scan-error'),
                      style: TextStyle(
                          fontSize: AppType.body, color: palette.danger),
                    ),
                  ],
                  if (classes.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      '扫描到 ${classes.length} 个 Spider 类，选择一个：',
                      style: TextStyle(
                          fontSize: AppType.body, color: palette.textSub),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final className in classes.take(24))
                          ChoiceChip(
                            label: Text(
                              JarScanResult.simpleName(className),
                              style: const TextStyle(fontSize: AppType.body),
                            ),
                            selected: _selectedClass == className,
                            onSelected: _scanning
                                ? null
                                : (_) => _selectClass(className),
                          ),
                      ],
                    ),
                    if (classes.length > 24)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '仅展示前 24 个；需要其它的可直接在下面手填。',
                          style: TextStyle(
                              fontSize: AppType.caption,
                              color: palette.textDim),
                        ),
                      ),
                  ],
                  const SizedBox(height: 12),
                  _label(context, '接口 / 类名'),
                  TextField(
                    key: const ValueKey('custom-site-api'),
                    controller: _api,
                    enabled: !_scanning,
                    style: TextStyle(
                        fontSize: AppType.label, color: palette.textMain),
                    decoration: InputDecoration(
                      hintText: _type == 3 ? 'csp_Xxx' : '接口地址',
                      helperText: _type == 3
                          ? '蜘蛛站源填 csp_类名；JS / PY 脚本填脚本地址'
                          : '普通站源填接口地址',
                      helperMaxLines: 2,
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _label(context, 'ext（蜘蛛参数，可空）'),
                  TextField(
                    key: const ValueKey('custom-site-ext'),
                    controller: _ext,
                    enabled: !_scanning,
                    minLines: 2,
                    maxLines: 4,
                    style: TextStyle(
                        fontSize: AppType.label, color: palette.textMain),
                    decoration: const InputDecoration(
                      hintText: '{"siteUrl": "https://资源站根地址"}',
                      helperText: '对象 / 数组形态会校验 JSON；其它内容原样传给蜘蛛',
                      helperMaxLines: 2,
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _searchable,
                    onChanged: _scanning
                        ? null
                        : (value) => setState(() => _searchable = value),
                    title: Text('参与聚合搜索',
                        style: TextStyle(
                            fontSize: AppType.label, color: palette.textMain)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _filterable,
                    onChanged: _scanning
                        ? null
                        : (value) => setState(() => _filterable = value),
                    title: Text('显示筛选器',
                        style: TextStyle(
                            fontSize: AppType.label, color: palette.textMain)),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        key: const ValueKey('custom-site-error'),
                        style:
                            TextStyle(fontSize: AppType.body, color: palette.danger),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: _scanning ? null : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: _scanning ? null : _save,
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: AppType.body,
            fontWeight: FontWeight.w600,
            color: context.palette.textBody,
          ),
        ),
      );
}
