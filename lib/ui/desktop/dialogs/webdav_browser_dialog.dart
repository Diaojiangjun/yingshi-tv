import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../../core/player/models/player_state.dart';
import '../../../core/push/push_input_resolver.dart';
import '../../../core/push/webdav_browse_origin.dart';
import '../../../core/push/webdav_profile_store.dart';
import '../../../core/push/webdav_repository.dart';
import '../../../core/storage/data_restore_guard.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_tokens.dart';
import 'app_dialog.dart';
import 'escape_closable.dart';

/// 当前目录的排序依据。
enum _WebDavSort { name, size, modified }

class WebDavBrowserDialog extends StatefulWidget {
  final WebDavRepository? repository;
  final WebDavProfileStore? profileStore;

  /// 退出播放器后重开时用来恢复连接与所在目录；为 null 时按常规进入。
  final WebDavBrowseOrigin? restoreOrigin;

  /// 选中媒体起播时上报浏览快照，退出播放器后据此回到原目录。
  final ValueChanged<WebDavBrowseOrigin>? onPlaybackOrigin;

  const WebDavBrowserDialog({
    super.key,
    this.repository,
    this.profileStore,
    this.restoreOrigin,
    this.onPlaybackOrigin,
  });

  @override
  State<WebDavBrowserDialog> createState() => _WebDavBrowserDialogState();
}

class _WebDavBrowserDialogState extends State<WebDavBrowserDialog> {
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _filter = TextEditingController();
  late final WebDavRepository _repository;
  late final WebDavProfileStore _store;
  WebDavConnection? _connection;
  List<Uri> _trail = const [];
  List<WebDavEntry> _entries = const [];
  List<WebDavProfile> _profiles = const [];
  bool _busy = false;
  bool _closing = false;
  bool _readingProfiles = true;
  bool _remember = true;
  bool _profilesReadable = true;
  bool _showForm = false;
  String? _editingId;
  String? _selectedProfileId;
  String? _error;
  String? _recordError;
  String? _notice;
  String _filterText = '';
  _WebDavSort _sort = _WebDavSort.name;
  bool _ascending = true;
  bool _foldersFirst = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? WebDavRepository();
    _store = widget.profileStore ?? WebDavProfileStore();
    final restore = widget.restoreOrigin;
    if (restore != null) {
      _url.text = restore.url;
      _username.text = restore.username;
      _password.text = restore.password;
    }
    _readProfiles();
  }

  Future<void> _readProfiles() async {
    try {
      final profiles = await _store.read();
      if (mounted) {
        setState(() {
          _profiles = profiles;
          if (_selectedProfileId == null && profiles.isNotEmpty) {
            _selectedProfileId = profiles.first.id;
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _profilesReadable = false;
          _remember = false;
          _recordError = '已保存的连接无法读取，可继续临时连接';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _readingProfiles = false;
          if (_profiles.isEmpty) {
            _showForm = true;
          }
        });
      }
    }
    final restore = widget.restoreOrigin;
    if (restore != null && mounted) await _restoreBrowse(restore);
  }

  /// 按快照重新连接并进入起播时所在目录；失败时保留在表单让用户重试。
  Future<void> _restoreBrowse(WebDavBrowseOrigin origin) async {
    if (_closing) return;
    try {
      final profile = WebDavProfile.create(
        origin.url,
        username: origin.username,
        password: origin.password,
      );
      final connection = profile.connect();
      final trail = origin.trail.isEmpty ? [connection.root] : origin.trail;
      await _load(connection, trail, collapseForm: true);
    } catch (_) {
      // 恢复失败不弹错：连接表单已回填，用户可直接点「连接并浏览」。
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _filter.dispose();
    if (widget.repository == null) _repository.dispose();
    super.dispose();
  }

  void _didClose() {
    _closing = true;
    _generation++;
  }

  void _invalidate(String _) => setState(() {
    _connection = null;
    _trail = const [];
    _entries = const [];
    _error = null;
    _notice = null;
  });

  void _edit(WebDavProfile? profile) {
    if (_busy) return;
    _url.text = profile?.url ?? '';
    _username.text = profile?.username ?? '';
    _password.text = profile?.password ?? '';
    _invalidate('');
    setState(() {
      _editingId = profile?.id;
      _remember = _profilesReadable;
      _showForm = true;
      if (profile != null) _selectedProfileId = profile.id;
    });
  }

  WebDavProfile? _profileById(String? id) {
    if (id == null) return null;
    for (final profile in _profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  Future<void> _connectSaved(WebDavProfile profile) async {
    _edit(profile);
    await _connect(save: false);
  }

  Future<void> _connect({bool save = true}) async {
    if (_busy || _readingProfiles || _closing) return;
    try {
      final profile = WebDavProfile.create(
        _url.text,
        username: _username.text,
        password: _password.text,
      );
      final connection = profile.connect();
      _connection = null;
      _trail = const [];
      _entries = const [];
      await _load(
        connection,
        [connection.root],
        saveProfile: save && _remember ? profile : null,
        replacingId: _editingId,
        collapseForm: true,
      );
    } catch (error) {
      if (mounted) setState(() => _error = pushErrorMessage(error));
    }
  }

  Future<void> _load(
    WebDavConnection connection,
    List<Uri> trail, {
    WebDavProfile? saveProfile,
    String? replacingId,
    bool collapseForm = false,
  }) async {
    final generation = ++_generation;
    final previousDirectory = _trail.isNotEmpty ? _trail.last : null;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _recordError = null;
    });
    try {
      final entries = await _repository.list(connection, directory: trail.last);
      if (!mounted || generation != _generation) return;
      final directoryChanged = previousDirectory != trail.last;
      setState(() {
        _connection = connection;
        _trail = List.unmodifiable(trail);
        _entries = entries;
        if (directoryChanged) {
          _filterText = '';
          _filter.clear();
        }
        if (collapseForm || saveProfile != null) _showForm = false;
      });
      if (saveProfile != null) {
        try {
          final profiles = await _store.save(
            saveProfile,
            replacingId: replacingId,
          );
          if (!mounted || generation != _generation) return;
          setState(() {
            _profiles = profiles;
            _editingId = saveProfile.id;
            _selectedProfileId = saveProfile.id;
            _recordError = null;
            _notice = '连接已保存，下次可直接点击连接';
          });
        } on DataRestorePendingRestartException catch (error) {
          if (mounted && generation == _generation) {
            setState(() => _recordError = error.message);
          }
        } on WebDavProfileStoreException catch (error) {
          if (mounted && generation == _generation) {
            setState(() => _recordError = '已连接，但记录未保存：${error.message}');
          }
        } catch (_) {
          if (mounted && generation == _generation) {
            setState(() => _recordError = '已连接，但记录未保存；请检查数据目录权限或重试');
          }
        }
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = pushErrorMessage(error));
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _remove(WebDavProfile profile) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除已保存的连接？'),
        content: const Text('只删除本机连接记录，不会删除服务器上的文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.palette.danger,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || _closing || confirmed != true || _busy) return;
    setState(() => _busy = true);
    try {
      final profiles = await _store.remove(profile.id);
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        _recordError = null;
        _notice = '连接记录已删除';
        if (_editingId == profile.id) {
          _editingId = null;
          _remember = false;
          _showForm = profiles.isEmpty;
        }
        if (_selectedProfileId == profile.id) {
          _selectedProfileId = profiles.isEmpty ? null : profiles.first.id;
        }
      });
    } on DataRestorePendingRestartException catch (error) {
      if (mounted) setState(() => _recordError = error.message);
    } catch (_) {
      if (mounted) setState(() => _recordError = '连接记录未删除，请检查数据目录权限或重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _select(WebDavEntry entry) async {
    final connection = _connection;
    if (_busy || _closing || connection == null) return;
    if (entry.isDirectory) {
      await _load(connection, [..._trail, entry.uri]);
      return;
    }
    final generation = _generation;
    setState(() => _busy = true);
    try {
      final spec = await _repository.resolvePlaySpec(connection, entry);
      if (!mounted || _closing || generation != _generation) return;
      widget.onPlaybackOrigin?.call(
        WebDavBrowseOrigin(
          url: _url.text.trim(),
          username: _username.text.trim(),
          password: _password.text,
          trail: List<Uri>.from(_trail),
          playUrl: spec.url,
        ),
      );
      Navigator.of(context).pop<MediaPlaySpec>(spec);
    } catch (error) {
      if (mounted && !_closing && generation == _generation) {
        setState(() => _error = pushErrorMessage(error));
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final media = MediaQuery.sizeOf(context);
    final width = math.min(980.0, math.max(360.0, media.width - 48));
    final height = math.min(760.0, math.max(420.0, media.height - 48));
    final wideHeader = media.width >= 620;

    return EscapeClosable(
      child: PopScope<MediaPlaySpec>(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) _didClose();
        },
        child: Dialog(
          backgroundColor: palette.panel,
          insetPadding: const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.lg),
            side: BorderSide(color: palette.borderStrong),
          ),
          child: SizedBox(
            width: width,
            height: height,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 10, 12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.cloud_queue_rounded,
                        size: 22,
                        color: palette.accentInk,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '浏览 WebDAV 媒体库',
                              style: TextStyle(
                                fontSize: AppType.h2,
                                fontWeight: FontWeight.bold,
                                color: palette.textTitle,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '只读浏览 · 凭据仅保存在本机',
                              style: TextStyle(
                                fontSize: AppType.caption,
                                color: palette.textSub,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_connection != null && wideHeader)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 180),
                          child: _connectionChip(palette),
                        ),
                      IconButton(
                        tooltip: '关闭 WebDAV',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: palette.divider),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildSavedConnections(palette),
                        const SizedBox(height: 8),
                        _buildFormSection(palette),
                        const SizedBox(height: 8),
                        _buildBrowserToolbar(palette),
                        _buildMessages(palette),
                        if (_busy)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: LinearProgressIndicator(minHeight: 2),
                          ),
                        const SizedBox(height: 4),
                        Expanded(child: _buildEntryList(palette)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _connectionChip(AppPalette palette) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: palette.accentWash,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: palette.accentInk.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.link_rounded, size: 13, color: palette.accentInk),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              _connection!.root.host,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.micro,
                color: palette.accentInk,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSavedConnections(AppPalette palette) {
    if (_readingProfiles) {
      return const LinearProgressIndicator(minHeight: 2);
    }
    final selected = _profileById(_selectedProfileId);
    final selector = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: palette.raised,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: palette.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: selected?.id,
          isExpanded: true,
          hint: Text(
            _profilesReadable ? '选择已保存的连接' : '已保存的连接不可读',
            style: TextStyle(fontSize: AppType.caption, color: palette.textDim),
          ),
          items: [
            for (final profile in _profiles)
              DropdownMenuItem<String>(
                value: profile.id,
                child: Text(
                  '${profile.url}${profile.username.isEmpty ? '' : ' · ${profile.username}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    color: palette.textMain,
                  ),
                ),
              ),
          ],
          onChanged: _busy
              ? null
              : (value) => setState(() => _selectedProfileId = value),
        ),
      ),
    );
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.tonalIcon(
          onPressed: _busy || selected == null
              ? null
              : () => _connectSaved(selected),
          icon: const Icon(Icons.link_rounded, size: 17),
          label: const Text('连接'),
        ),
        if (selected != null)
          PopupMenuButton<String>(
            enabled: !_busy,
            tooltip: '管理连接',
            onSelected: (action) {
              if (action == 'edit') {
                _edit(selected);
              } else {
                _remove(selected);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('编辑连接')),
              PopupMenuItem(
                value: 'delete',
                child: Text('删除连接', style: TextStyle(color: palette.danger)),
              ),
            ],
          ),
        TextButton.icon(
          onPressed: _busy ? null : () => _edit(null),
          icon: const Icon(Icons.add_rounded, size: 17),
          label: const Text('新建连接'),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = _profiles.isEmpty
            ? Text(
                _profilesReadable ? '尚无保存的连接，填写下方地址即可临时浏览。' : '已保存的连接无法读取',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: palette.textSub,
                ),
              )
            : selector;
        if (constraints.maxWidth < 680) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              content,
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerLeft, child: actions),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: content),
            const SizedBox(width: 8),
            actions,
          ],
        );
      },
    );
  }

  Widget _buildFormSection(AppPalette palette) {
    final title = _showForm ? (_editingId == null ? '新建连接' : '编辑连接') : '连接设置';
    return Container(
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: _busy ? null : () => setState(() => _showForm = !_showForm),
            borderRadius: BorderRadius.circular(AppRadii.md),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.settings_ethernet_rounded,
                    size: 16,
                    color: palette.textSub,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: AppType.caption,
                      fontWeight: FontWeight.w600,
                      color: palette.textMain,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _showForm ? '收起' : '展开',
                    style: TextStyle(
                      fontSize: AppType.micro,
                      color: palette.textDim,
                    ),
                  ),
                  Icon(
                    _showForm
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: palette.textDim,
                  ),
                ],
              ),
            ),
          ),
          if (_showForm) ...[
            Divider(height: 1, color: palette.divider),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const ValueKey('webdav-url'),
                    controller: _url,
                    enabled: !_busy,
                    onChanged: _invalidate,
                    keyboardType: TextInputType.url,
                    decoration: _decoration(
                      'WebDAV 根地址',
                      hint: 'https://nas.example.com/dav/',
                    ),
                  ),
                  const SizedBox(height: 10),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final fields = [
                        TextField(
                          controller: _username,
                          enabled: !_busy,
                          onChanged: _invalidate,
                          decoration: _decoration('用户名（可选）'),
                        ),
                        TextField(
                          controller: _password,
                          enabled: !_busy,
                          obscureText: true,
                          enableSuggestions: false,
                          autocorrect: false,
                          onChanged: _invalidate,
                          onSubmitted: (_) => _connect(),
                          decoration: _decoration('密码'),
                        ),
                      ];
                      if (constraints.maxWidth < 440) {
                        return Column(
                          children: [
                            fields[0],
                            const SizedBox(height: 10),
                            fields[1],
                          ],
                        );
                      }
                      return Row(
                        children: [
                          Expanded(child: fields[0]),
                          const SizedBox(width: 10),
                          Expanded(child: fields[1]),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 2),
                  Material(
                    type: MaterialType.transparency,
                    child: CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _remember,
                      onChanged: _busy || _readingProfiles || !_profilesReadable
                          ? null
                          : (value) =>
                                setState(() => _remember = value ?? false),
                      title: const Text('保存此连接（含密码）'),
                      subtitle: const Text('账号与密码加密保存在本机，不随备份导出'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: _busy || _readingProfiles
                          ? null
                          : () => _connect(),
                      icon: const Icon(Icons.cloud_rounded, size: 18),
                      label: const Text('连接并浏览'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBrowserToolbar(AppPalette palette) {
    final filterField = _buildFilterField(palette);
    final sortButton = _buildSortButton(palette);
    final itemCount = _buildItemCount(palette);
    return LayoutBuilder(
      builder: (context, constraints) {
        final nav = <Widget>[
          IconButton(
            tooltip: '返回上级',
            onPressed: _busy || _trail.length < 2
                ? null
                : () =>
                      _load(_connection!, _trail.sublist(0, _trail.length - 1)),
            icon: const Icon(Icons.arrow_upward_rounded),
          ),
          IconButton(
            tooltip: '刷新 WebDAV',
            onPressed: _busy || _connection == null
                ? null
                : () => _load(_connection!, _trail),
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 4),
        ];
        if (constraints.maxWidth < 680) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  ...nav,
                  Expanded(child: _buildBreadcrumbs(palette)),
                  sortButton,
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(child: filterField),
                  const SizedBox(width: 8),
                  itemCount,
                ],
              ),
            ],
          );
        }
        return Row(
          children: [
            ...nav,
            Expanded(child: _buildBreadcrumbs(palette)),
            const SizedBox(width: 10),
            itemCount,
            const SizedBox(width: 12),
            SizedBox(width: 220, child: filterField),
            const SizedBox(width: 6),
            sortButton,
          ],
        );
      },
    );
  }

  Widget _buildItemCount(AppPalette palette) {
    if (_connection == null || _entries.isEmpty) return const SizedBox.shrink();
    final visible = _visibleCount();
    final filtering = _filterText.isNotEmpty;
    return Text(
      filtering ? '$visible / ${_entries.length} 项' : '${_entries.length} 项',
      key: const ValueKey('webdav-item-count'),
      style: TextStyle(
        fontSize: AppType.micro,
        color: filtering ? palette.accentInk : palette.textDim,
      ),
    );
  }

  Widget _buildFilterField(AppPalette palette) {
    return SizedBox(
      height: 36,
      child: TextField(
        key: const ValueKey('webdav-filter'),
        controller: _filter,
        onChanged: (value) =>
            setState(() => _filterText = value.trim().toLowerCase()),
        style: TextStyle(fontSize: AppType.caption, color: palette.textMain),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: palette.raised,
          hintText: '筛选当前目录',
          hintStyle: TextStyle(
            fontSize: AppType.caption,
            color: palette.textDim,
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 16,
            color: palette.textSub,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
          suffixIcon: _filterText.isEmpty
              ? null
              : IconButton(
                  key: const ValueKey('webdav-filter-clear'),
                  tooltip: '清除筛选',
                  onPressed: _clearFilter,
                  icon: Icon(
                    Icons.close_rounded,
                    size: 15,
                    color: palette.textSub,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 30,
            minHeight: 30,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 8,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadii.sm),
            borderSide: BorderSide(color: palette.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadii.sm),
            borderSide: BorderSide(color: palette.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadii.sm),
            borderSide: BorderSide(color: palette.accentInk),
          ),
        ),
      ),
    );
  }

  Widget _buildSortButton(AppPalette palette) {
    final label = switch (_sort) {
      _WebDavSort.name => '名称',
      _WebDavSort.size => '大小',
      _WebDavSort.modified => '时间',
    };
    return PopupMenuButton<String>(
      key: const ValueKey('webdav-sort'),
      tooltip: '排序与文件夹优先',
      onSelected: (value) {
        switch (value) {
          case 'name':
            setState(() => _sort = _WebDavSort.name);
            break;
          case 'size':
            setState(() => _sort = _WebDavSort.size);
            break;
          case 'modified':
            setState(() => _sort = _WebDavSort.modified);
            break;
          case 'direction':
            setState(() => _ascending = !_ascending);
            break;
          case 'folders':
            setState(() => _foldersFirst = !_foldersFirst);
            break;
        }
      },
      itemBuilder: (_) => [
        _sortItem(palette, 'name', '按名称', _sort == _WebDavSort.name),
        _sortItem(palette, 'size', '按大小', _sort == _WebDavSort.size),
        _sortItem(palette, 'modified', '按修改时间', _sort == _WebDavSort.modified),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'direction',
          key: const ValueKey('webdav-sort-direction'),
          child: Row(
            children: [
              Icon(
                _ascending
                    ? Icons.arrow_upward_rounded
                    : Icons.arrow_downward_rounded,
                size: 16,
                color: palette.textSub,
              ),
              const SizedBox(width: 10),
              Text(_ascending ? '升序（点击切换）' : '降序（点击切换）'),
            ],
          ),
        ),
        CheckedPopupMenuItem(
          value: 'folders',
          key: const ValueKey('webdav-sort-folders'),
          checked: _foldersFirst,
          child: const Text('文件夹优先'),
        ),
      ],
      child: Tooltip(
        message: '排序：$label · ${_ascending ? '升序' : '降序'}',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: palette.raised,
            borderRadius: BorderRadius.circular(AppRadii.sm),
            border: Border.all(color: palette.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.sort_rounded, size: 16, color: palette.textSub),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: palette.textSub,
                ),
              ),
              Icon(
                _ascending
                    ? Icons.arrow_upward_rounded
                    : Icons.arrow_downward_rounded,
                size: 13,
                color: palette.textDim,
              ),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<String> _sortItem(
    AppPalette palette,
    String value,
    String label,
    bool selected,
  ) {
    return PopupMenuItem<String>(
      value: value,
      key: ValueKey('webdav-sort-$value'),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          if (selected)
            Icon(Icons.check_rounded, size: 16, color: palette.accentInk),
        ],
      ),
    );
  }

  void _clearFilter() {
    _filter.clear();
    if (mounted) setState(() => _filterText = '');
  }

  Widget _buildBreadcrumbs(AppPalette palette) {
    if (_trail.isEmpty) {
      return Text(
        _connection == null ? '未连接' : '/',
        style: TextStyle(fontSize: AppType.caption, color: palette.textSub),
      );
    }
    final items = <Widget>[];
    for (var i = 0; i < _trail.length; i++) {
      if (i > 0) {
        items.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Icon(
              Icons.chevron_right_rounded,
              size: 14,
              color: palette.textDim,
            ),
          ),
        );
      }
      final isLast = i == _trail.length - 1;
      final label = i == 0 ? _rootLabel() : _segmentLabel(_trail[i]);
      items.add(
        Tooltip(
          message: _trail[i].toString(),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadii.xs),
            onTap: _busy || _connection == null || isLast
                ? null
                : () => _load(_connection!, _trail.sublist(0, i + 1)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.caption,
                  fontWeight: isLast ? FontWeight.w600 : FontWeight.w400,
                  color: isLast ? palette.textMain : palette.accentInk,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: items),
    );
  }

  String _rootLabel() {
    final connection = _connection;
    if (connection == null) return '/';
    final root = connection.root;
    final authority = root.hasPort ? '${root.host}:${root.port}' : root.host;
    final segments = root.pathSegments
        .where((segment) => segment.isNotEmpty)
        .map(_decodeSegment)
        .toList();
    if (segments.isEmpty) return authority;
    return '$authority / ${segments.join(' / ')}';
  }

  Widget _buildMessages(AppPalette palette) {
    final messages = <Widget>[];
    void add(String text, Color color, IconData icon) {
      messages.add(
        Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppRadii.sm),
            border: Border.all(color: color.withValues(alpha: 0.30)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    color: color,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      add(_error!, palette.danger, Icons.error_outline_rounded);
    }
    if (_recordError != null) {
      add(_recordError!, palette.warning, Icons.warning_amber_rounded);
    }
    if (_notice != null) {
      add(_notice!, palette.accentInk, Icons.info_outline_rounded);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: messages,
    );
  }

  Widget _buildEntryList(AppPalette palette) {
    if (_connection == null) {
      return _emptyState(
        palette,
        icon: Icons.cloud_off_rounded,
        text: '填写服务地址后连接，账号为空时匿名访问',
      );
    }
    final entries = _visibleEntries();
    if (entries.isEmpty) {
      final filtering = _filterText.isNotEmpty;
      return _emptyState(
        palette,
        icon: filtering ? Icons.search_off_rounded : Icons.folder_open_rounded,
        text: filtering ? '没有匹配「${_filter.text.trim()}」的条目' : '此目录为空',
        onRefresh: filtering
            ? _clearFilter
            : (_busy ? null : () => _load(_connection!, _trail)),
        refreshLabel: filtering ? '清除筛选' : '刷新',
        refreshIcon: filtering ? Icons.close_rounded : Icons.refresh_rounded,
      );
    }
    return Stack(
      children: [
        ListView.separated(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          itemCount: entries.length,
          separatorBuilder: (_, __) =>
              Divider(height: 1, color: palette.divider),
          itemBuilder: (_, index) => _entryRow(palette, entries[index]),
        ),
        if (_busy)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                color: palette.background.withValues(alpha: 0.25),
                alignment: Alignment.center,
                child: const CircularProgressIndicator(),
              ),
            ),
          ),
      ],
    );
  }

  List<WebDavEntry> _visibleEntries() {
    final query = _filterText.trim();
    final list = query.isEmpty
        ? List<WebDavEntry>.of(_entries)
        : _entries
              .where((entry) => entry.name.toLowerCase().contains(query))
              .toList();
    list.sort(_compareEntries);
    return list;
  }

  int _visibleCount() {
    if (_filterText.isEmpty) return _entries.length;
    return _entries
        .where((entry) => entry.name.toLowerCase().contains(_filterText))
        .length;
  }

  int _compareEntries(WebDavEntry a, WebDavEntry b) {
    if (_foldersFirst && a.isDirectory != b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    if (_sort == _WebDavSort.size) {
      if (a.size == null && b.size == null) return _compareNames(a, b);
      if (a.size == null) return 1;
      if (b.size == null) return -1;
      final cmp = a.size!.compareTo(b.size!);
      return cmp == 0 ? _compareNames(a, b) : (_ascending ? cmp : -cmp);
    }
    if (_sort == _WebDavSort.modified) {
      if (a.modifiedAt == null && b.modifiedAt == null) {
        return _compareNames(a, b);
      }
      if (a.modifiedAt == null) return 1;
      if (b.modifiedAt == null) return -1;
      final cmp = a.modifiedAt!.compareTo(b.modifiedAt!);
      return cmp == 0 ? _compareNames(a, b) : (_ascending ? cmp : -cmp);
    }
    final cmp = _compareNames(a, b);
    return _ascending ? cmp : -cmp;
  }

  int _compareNames(WebDavEntry a, WebDavEntry b) {
    final cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (cmp != 0) return cmp;
    return a.uri.toString().compareTo(b.uri.toString());
  }

  Widget _entryRow(AppPalette palette, WebDavEntry entry) {
    final enabled = entry.isDirectory || entry.isMedia;
    final fullParts = <String>[
      if (entry.isDirectory)
        '文件夹'
      else if (!entry.isMedia)
        '非媒体文件'
      else
        _formatBytes(entry.size),
      if (entry.modifiedAt != null) _formatModified(entry.modifiedAt!),
      if (entry.isMedia) '点击播放',
    ];
    final displayParts = <String>[
      if (entry.isDirectory)
        '文件夹'
      else if (!entry.isMedia)
        '非媒体文件'
      else
        _formatBytes(entry.size),
      if (entry.modifiedAt != null) _formatModifiedRelative(entry.modifiedAt!),
    ];
    final subtitle = displayParts.join(' · ');
    final fullSubtitle = fullParts.join(' · ');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: !enabled ? null : () => _select(entry),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          child: Row(
            children: [
              Icon(
                entry.isDirectory
                    ? Icons.folder_rounded
                    : entry.isMedia
                    ? Icons.play_circle_outline_rounded
                    : Icons.insert_drive_file_outlined,
                size: 22,
                color: entry.isDirectory
                    ? palette.accentInk
                    : entry.isMedia
                    ? palette.textMain
                    : palette.textDim,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.label,
                        color: enabled ? palette.textMain : palette.textDim,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Tooltip(
                      message: fullSubtitle,
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.micro,
                          color: palette.textSub,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (entry.isMedia)
                IconButton(
                  tooltip: '播放',
                  onPressed: _busy ? null : () => _select(entry),
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                ),
              if (entry.isDirectory)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: palette.textDim,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyState(
    AppPalette palette, {
    required IconData icon,
    required String text,
    VoidCallback? onRefresh,
    String refreshLabel = '刷新',
    IconData refreshIcon = Icons.refresh_rounded,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 36, color: palette.textDim),
                  const SizedBox(height: 10),
                  Text(
                    text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: AppType.caption,
                      color: palette.textSub,
                    ),
                  ),
                  if (onRefresh != null) ...[
                    const SizedBox(height: 6),
                    TextButton.icon(
                      onPressed: onRefresh,
                      icon: Icon(refreshIcon, size: 16),
                      label: Text(refreshLabel),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _segmentLabel(Uri uri) {
    final segments = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.isEmpty) return uri.host;
    return _decodeSegment(segments.last);
  }

  String _decodeSegment(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  String _formatBytes(int? size) {
    if (size == null || size < 0) return '大小未知';
    if (size < 1024) return '$size B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = size / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final text = value >= 100
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$text ${units[unit]}';
  }

  String _formatModified(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  String _formatModifiedRelative(DateTime time) {
    final local = time.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final diff = today.difference(day).inDays;
    String two(int value) => value.toString().padLeft(2, '0');
    final hm = '${two(local.hour)}:${two(local.minute)}';
    if (diff == 0) return '今天 $hm';
    if (diff == 1) return '昨天 $hm';
    if (diff > 1 && diff < 30) return '$diff 天前';
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  InputDecoration _decoration(String label, {String? hint}) {
    final palette = AppPalette.of(context);
    return InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      filled: true,
      fillColor: palette.raised,
      labelStyle: TextStyle(color: palette.textSub, fontSize: AppType.body),
      hintStyle: TextStyle(color: palette.textDim, fontSize: AppType.body),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
    );
  }
}
