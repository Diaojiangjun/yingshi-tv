import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'subtitle_models.dart';
import 'subtitle_pick_entry.dart';

/// 字幕压缩包解压（zip / gz）。
///
/// rar / 7z / bz2 需要额外的原生依赖，明确不支持并给出中文原因，
/// 而不是解出乱码再让播放器报错。
enum SubtitleArchiveKind { zip, gz, rar, sevenZip, bz2 }

extension SubtitleArchiveKindX on SubtitleArchiveKind {
  String get label => switch (this) {
        SubtitleArchiveKind.zip => 'ZIP',
        SubtitleArchiveKind.gz => 'GZ',
        SubtitleArchiveKind.rar => 'RAR',
        SubtitleArchiveKind.sevenZip => '7Z',
        SubtitleArchiveKind.bz2 => 'BZ2',
      };

  bool get supported =>
      this == SubtitleArchiveKind.zip || this == SubtitleArchiveKind.gz;
}

/// 归档类型识别（魔数；非归档返回 null）。允许短字节数组。
SubtitleArchiveKind? detectSubtitleArchive(List<int> bytes) {
  if (bytes.length < 2) return null;
  if (bytes.length >= 4 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x61 &&
      bytes[2] == 0x72 &&
      bytes[3] == 0x21) {
    return SubtitleArchiveKind.rar; // Rar!
  }
  if (bytes[0] == 0x50 && bytes[1] == 0x4b) return SubtitleArchiveKind.zip;
  if (bytes[0] == 0x1f && bytes[1] == 0x8b) return SubtitleArchiveKind.gz;
  if (bytes.length >= 6 &&
      bytes[0] == 0x37 &&
      bytes[1] == 0x7a &&
      bytes[2] == 0xbc &&
      bytes[3] == 0xaf &&
      bytes[4] == 0x27 &&
      bytes[5] == 0x1c) {
    return SubtitleArchiveKind.sevenZip;
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0x42 &&
      bytes[1] == 0x5a &&
      bytes[2] == 0x68) {
    return SubtitleArchiveKind.bz2;
  }
  return null;
}

/// 包内条目。
class SubtitleArchiveEntry extends PickableEntry {
  SubtitleArchiveEntry({required super.name, required super.bytes});
}

/// 解出归档内的全部文件条目（目录项剔除）。
///
/// zip / gz 解不出来返回空列表（调用方给可读原因）；不支持的格式直接抛。
List<SubtitleArchiveEntry> extractSubtitleArchive(List<int> bytes) {
  final kind = detectSubtitleArchive(bytes);
  if (kind == null) return const <SubtitleArchiveEntry>[];
  if (!kind.supported) {
    throw SubtitleException(
      '暂不支持解压 ${kind.label} 压缩包，请手动解压后选择字幕文件',
    );
  }
  try {
    if (kind == SubtitleArchiveKind.zip) return _zipEntries(bytes);
    return _gunzipEntry(bytes);
  } catch (_) {
    return const <SubtitleArchiveEntry>[];
  }
}

List<SubtitleArchiveEntry> _zipEntries(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(Uint8List.fromList(bytes));
  final out = <SubtitleArchiveEntry>[];
  for (final f in archive.files) {
    if (f.isDirectory || f.name.endsWith('/')) continue;
    final data = f.content;
    if (data.isEmpty) continue;
    out.add(SubtitleArchiveEntry(name: f.name, bytes: data));
  }
  return out;
}

/// gzip：单文件流；条目名优先取头里的 FNAME，缺失时用占位名。
List<SubtitleArchiveEntry> _gunzipEntry(List<int> bytes) {
  final data = const GZipDecoder().decodeBytes(Uint8List.fromList(bytes));
  return <SubtitleArchiveEntry>[
    SubtitleArchiveEntry(name: _gzName(bytes) ?? 'subtitle.srt', bytes: data),
  ];
}

/// gzip 头 FNAME 字段（FLG bit3；偏移 10 起，0 结尾）。
String? _gzName(List<int> buf) {
  if (buf.length < 11) return null;
  if ((buf[3] & 0x08) == 0) return null;
  var end = 10;
  while (end < buf.length && buf[end] != 0) {
    end++;
  }
  if (end <= 10) return null;
  final name =
      String.fromCharCodes(buf.sublist(10, end)).replaceAll('\\', '/').split('/').last;
  return name.isEmpty ? null : name;
}

/// 字节 → 可用字幕：非归档直接校验；归档解压后挑最匹配的条目。
///
/// 返回的是**原始字节**，由 mpv / libass 负责最终编码与格式识别；
/// 这里的解码只用于「是不是字幕」的粗判，避免把 HTML 登录页或说明文件
/// 当成字幕塞给播放器。
SubtitleFile subtitleFromBytes(
  List<int> bytes, {
  String fileName = '',
  String videoName = '',
  String ep = '',
}) {
  final kind = detectSubtitleArchive(bytes);
  if (kind == null) {
    if (bytes.length < 32) {
      throw const SubtitleException('字幕内容为空或过短');
    }
    if (!looksLikeSubtitleBytes(bytes)) {
      throw const SubtitleException('下载到的内容不是文本字幕（可能是网页或说明文件）');
    }
    return SubtitleFile(
      name: fileName,
      format: extOf(fileName),
      bytes: bytes,
    );
  }

  final entries = extractSubtitleArchive(bytes);
  if (entries.isEmpty) {
    throw SubtitleException('${kind.label} 压缩包解压失败或包内无文件');
  }
  final picked = pickSubtitleEntry<SubtitleArchiveEntry>(
    entries,
    opts: PickOptions(videoName: videoName, ep: ep),
  );
  if (picked == null) {
    throw SubtitleException('压缩包内未找到字幕文件（共 ${entries.length} 个条目）');
  }
  return SubtitleFile(
    name: picked.name,
    format: extOf(picked.name),
    bytes: picked.bytes,
  );
}

/// 宽松解码（BOM 优先，UTF-8 失败也继续）后判断是否像字幕。
bool looksLikeSubtitleBytes(List<int> bytes) {
  var data = bytes;
  if (bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf) {
    data = bytes.sublist(3);
  }
  final text = utf8.decode(data, allowMalformed: true);
  final head = text.length > 2000 ? text.substring(0, 2000) : text;
  return head.contains('-->') ||
      RegExp(r'Dialogue:', caseSensitive: false).hasMatch(head) ||
      RegExp(r'\[Script Info\]', caseSensitive: false).hasMatch(head) ||
      RegExp(r'WEBVTT', caseSensitive: false).hasMatch(head) ||
      RegExp(r'\{?\d+\}?\{?\d+\}').hasMatch(head); // MicroDVD
}
