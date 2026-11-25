"""把一张 PNG 转成本项目需要的图标全套（纯 Python，不依赖 Pillow / GDI+）。

产出：
  · assets/icons/app_icon.png                  512x512（界面 / README / 关于页用）
  · windows/runner/resources/app_icon.ico      16/24/32/48/64/128/256（exe / 任务栏）

处理流程：
  1. 解码源图（8bit、非隔行、RGB 或 RGBA）；
  2. 去白底（chroma key）——白底图直接缩放会得到一个白方块，
     深色标题栏上非常明显；接近白的像素按距离白点的程度渐变透明，
     并按「白底合成」反解出真实颜色，避免边缘发白；
  3. 按内容包围盒裁剪 + 四周留 4% 内边距，保证图标在方框里居中且不贴边；
  4. 面积平均（box/area）精确重采样，缩小不糊、不锯齿；
  5. 输出 PNG 与 ICO（32bpp BMP，带 AND 掩码）。

用法：
  python tools/make_icons.py new_logo.png                # 去白底 + 裁剪 + 全套
  python tools/make_icons.py new_logo.png --keep-bg      # 保留原背景（已带底色的图）
  python tools/make_icons.py new_logo.png --pad 0.08     # 调整留白比例
  python tools/make_icons.py new_logo.png --dry-run      # 只写到 build/ 预览，不覆盖正式文件
"""
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UI_SIZES = [16, 24, 32, 48, 64, 128, 256]
UI_PNG_SIZE = 512


# --------------------------------------------------------------------------- PNG


def read_png(path):
    """返回 (width, height, rgba bytearray)。仅支持 8bit、非隔行、RGB/RGBA。"""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"不是 PNG：{path}")

    pos = 8
    idat = bytearray()
    width = height = depth = color_type = interlace = None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", body
            )
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        pos += 12 + length

    if depth != 8 or interlace != 0 or color_type not in (2, 6):
        raise SystemExit(
            f"只支持 8bit 非隔行 RGB/RGBA，当前 depth={depth} "
            f"colorType={color_type} interlace={interlace}；请先导出标准 PNG"
        )

    channels = 4 if color_type == 6 else 3
    stride = width * channels
    raw = zlib.decompress(bytes(idat))
    if len(raw) != (stride + 1) * height:
        raise SystemExit("PNG 数据长度异常（可能带隔行或 16bit）")

    out = bytearray(width * height * 4)
    prev = bytearray(stride)
    p = 0
    for y in range(height):
        filt = raw[p]
        line = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        if filt == 1:  # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filt == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif filt == 3:  # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif filt == 4:  # Paeth
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                pa = abs(b - c)
                pb = abs(a - c)
                pc = abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        elif filt != 0:
            raise SystemExit(f"未知 PNG 行过滤器 {filt}")

        row = y * width * 4
        if channels == 4:
            out[row:row + width * 4] = line
        else:
            for x in range(width):
                s = x * 3
                d = row + x * 4
                out[d] = line[s]
                out[d + 1] = line[s + 1]
                out[d + 2] = line[s + 2]
                out[d + 3] = 255
        prev = line
    return width, height, out


def encode_png(width, height, rgba):
    def chunk(kind, body):
        return (
            struct.pack(">I", len(body))
            + kind
            + body
            + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
        )

    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter None
        raw += rgba[y * stride:(y + 1) * stride]
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def write_png(path, width, height, rgba):
    with open(path, "wb") as f:
        f.write(encode_png(width, height, rgba))
    return path


# ------------------------------------------------------------------- 图像处理


def _estimate_bg(width, height, rgba):
    """取四角 6x6 的平均亮度当作背景色（这类素材基本是纯色浅底）。"""
    total = 0
    count = 0
    for ox in (0, width - 6):
        for oy in (0, height - 6):
            for y in range(oy, oy + 6):
                for x in range(ox, ox + 6):
                    o = (y * width + x) * 4
                    total += min(rgba[o], rgba[o + 1], rgba[o + 2])
                    count += 1
    if not count:
        return 252
    return max(200, min(255, total / count))


def key_out_white(width, height, rgba):
    """把浅色背景变成透明，并按「叠在背景色上」反解出真实颜色。

    用最小通道算 alpha：纯色 logo 的最小通道接近 0，
    合成到浅底后满足  obs_min = (1-a)*bg + a*color_min，
    所以 1 - obs_min/bg 与 a 成正比，边缘反解出来的颜色不会发白。

    不能用饱和度判定：饱和度和 alpha 是非线性关系，边缘会算出虚高的
    alpha，缩放后就变成一圈白边。
    """
    bg = _estimate_bg(width, height, rgba)
    for i in range(0, len(rgba), 4):
        r = rgba[i]
        g = rgba[i + 1]
        b = rgba[i + 2]
        mx = r if r > g else g
        if b > mx:
            mx = b
        mn = r if r < g else g
        if b < mn:
            mn = b

        if mx < 40:  # 深色像素：实色保留
            continue

        alpha = (bg - mn) / bg
        if alpha <= 0.06:  # 背景本身有 249~255 的渐变，低于阈值一律清空
            rgba[i + 3] = 0
            continue
        if alpha >= 0.85:
            # 实色区域（含最小通道略高于 0 的绿/黄）：直接当不透明，
            # 否则整块色面会带 5~10% 的通透感，深色底上看得出来。
            continue
        rgba[i + 3] = int(round(alpha * 255))
        # obs = a*C + (1-a)*bg  =>  C = bg + (obs-bg)/a
        for k in range(3):
            v = bg + (rgba[i + k] - bg) / alpha
            rgba[i + k] = 0 if v < 0 else (255 if v > 255 else int(round(v)))


def content_box(width, height, rgba, threshold=24):
    left, top, right, bottom = width, height, -1, -1
    for y in range(height):
        row = y * width * 4
        for x in range(width):
            if rgba[row + x * 4 + 3] > threshold:
                if x < left:
                    left = x
                if x > right:
                    right = x
                if y < top:
                    top = y
                if y > bottom:
                    bottom = y
    if right < 0:
        raise SystemExit("图中找不到不透明内容（全白？）")
    return left, top, right + 1, bottom + 1


def crop_square(width, height, rgba, box, pad_ratio):
    """裁到内容框，居中放进正方形画布，四周留 pad_ratio 的内边距。"""
    left, top, right, bottom = box
    cw = right - left
    ch = bottom - top
    side = int(round(max(cw, ch) * (1 + 2 * pad_ratio)))
    out = bytearray(side * side * 4)
    ox = (side - cw) // 2
    oy = (side - ch) // 2
    for y in range(ch):
        src_row = (top + y) * width * 4 + left * 4
        dst_row = (oy + y) * side * 4 + ox * 4
        out[dst_row:dst_row + cw * 4] = rgba[src_row:src_row + cw * 4]
    return side, side, out


def _weights(src_len, dst_len):
    """面积平均的采样表：每格目标像素覆盖的源像素区间与权重（0~1）。"""
    scale = src_len / dst_len
    table = []
    for i in range(dst_len):
        start = i * scale
        end = start + scale
        i0 = int(start)
        i1 = min(int(end - 1e-9) + 1, src_len)
        ws = []
        total = 0.0
        for j in range(i0, i1):
            cover = min(end, j + 1) - max(start, j)
            if cover <= 0:
                continue
            ws.append((j, cover))
            total += cover
        table.append([(j, w / total) for j, w in ws])
    return table


def resize_area(src_w, src_h, src, dst_w, dst_h):
    """在预乘 alpha 空间做面积平均，避免透明边缘产生白边。"""
    tmp = [0.0] * (dst_w * src_h * 4)
    wx = _weights(src_w, dst_w)
    for y in range(src_h):
        srow = y * src_w * 4
        drow = y * dst_w * 4
        for x in range(dst_w):
            r = g = b = a = 0.0
            for sx, w in wx[x]:
                o = srow + sx * 4
                sa = src[o + 3] / 255.0
                r += src[o] * sa * w
                g += src[o + 1] * sa * w
                b += src[o + 2] * sa * w
                a += src[o + 3] * w
            o = drow + x * 4
            tmp[o] = r
            tmp[o + 1] = g
            tmp[o + 2] = b
            tmp[o + 3] = a

    acc = [0.0] * (dst_w * dst_h * 4)
    wy = _weights(src_h, dst_h)
    for y in range(dst_h):
        drow = y * dst_w * 4
        for sy, w in wy[y]:
            srow = sy * dst_w * 4
            for x in range(dst_w):
                o = drow + x * 4
                s = srow + x * 4
                acc[o] += tmp[s] * w
                acc[o + 1] += tmp[s + 1] * w
                acc[o + 2] += tmp[s + 2] * w
                acc[o + 3] += tmp[s + 3] * w

    out = bytearray(len(acc))
    for i in range(0, len(acc), 4):
        a = acc[i + 3]
        if a <= 0.5:
            continue  # 已经是全 0（全透明）
        inv = 255.0 / a
        for k in range(3):
            v = acc[i + k] * inv
            out[i + k] = 0 if v < 0 else (255 if v > 255 else int(round(v)))
        out[i + 3] = 255 if a > 255 else int(round(a))
    return out


# --------------------------------------------------------------------------- ICO


def bmp_entry(size, rgba):
    """ICO 里的 32bpp BMP：BITMAPINFOHEADER + 自下而上的 BGRA + AND 掩码。"""
    header = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    xor = bytearray()
    for y in range(size - 1, -1, -1):
        row = y * size * 4
        for x in range(size):
            o = row + x * 4
            xor += bytes((rgba[o + 2], rgba[o + 1], rgba[o], rgba[o + 3]))
    mask_stride = ((size + 31) // 32) * 4
    mask = bytearray()
    for y in range(size - 1, -1, -1):
        bits = bytearray(mask_stride)
        row = y * size * 4
        for x in range(size):
            if rgba[row + x * 4 + 3] == 0:
                bits[x >> 3] |= 0x80 >> (x & 7)
        mask += bits
    return header + bytes(xor) + bytes(mask)


def build_ico(entries, out_path):
    """entries: [(size, payload)]，260 以上用 PNG 压缩，其余 32bpp BMP。"""
    header = struct.pack("<HHH", 0, 1, len(entries))
    offset = 6 + 16 * len(entries)
    dirs = b""
    blobs = b""
    for size, blob in entries:
        dirs += struct.pack(
            "<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(blob), offset
        )
        offset += len(blob)
        blobs += blob
    with open(out_path, "wb") as f:
        f.write(header + dirs + blobs)
    return out_path


# --------------------------------------------------------------------------- 预览


def preview_sheet(sizes, out_path):
    """把各尺寸贴在深/浅两种背景上，便于肉眼确认边缘与对比度。"""
    cell = 64
    gap = 16
    cols = len(sizes)
    width = gap + cols * (cell + gap)
    height = gap + 2 * (cell + gap)
    canvas = bytearray([0] * (width * height * 4))
    backgrounds = [(28, 30, 34), (246, 246, 248)]  # 深色 / 浅色
    for row, bg in enumerate(backgrounds):
        y0 = gap + row * (cell + gap)
        for i in range(width):
            for y in range(y0, y0 + cell):
                o = (y * width + i) * 4
                canvas[o:o + 4] = bytes((bg[0], bg[1], bg[2], 255))
    for i, (size, rgba) in enumerate(sizes):
        px = rgba
        s = size
        if size > cell:  # 大尺寸先缩到格子里，预览板保持可读的宽度
            s = cell
            px = resize_area(size, size, rgba, cell, cell)
        x0 = gap + i * (cell + gap) + (cell - s) // 2
        for row in range(2):
            y0 = gap + row * (cell + gap) + (cell - s) // 2
            for y in range(s):
                for x in range(s):
                    o = (y * s + x) * 4
                    a = px[o + 3]
                    if not a:
                        continue
                    da = (y0 + y) * width * 4 + (x0 + x) * 4
                    if a == 255:
                        canvas[da:da + 3] = px[o:o + 3]
                    else:
                        t = a / 255
                        for k in range(3):
                            canvas[da + k] = int(
                                px[o + k] * t + canvas[da + k] * (1 - t)
                            )
    return write_png(out_path, width, height, canvas)


# --------------------------------------------------------------------------- 主流程

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        raise SystemExit(__doc__)
    src = os.path.abspath(args[0])
    dry = "--dry-run" in sys.argv
    keep_bg = "--keep-bg" in sys.argv

    pad = 0.04
    if "--pad" in sys.argv:
        pad = float(sys.argv[sys.argv.index("--pad") + 1])

    width, height, rgba = read_png(src)
    print(f"源图 {width}x{height}")

    if not keep_bg:
        key_out_white(width, height, rgba)
    box = content_box(width, height, rgba)
    side, _, canvas = crop_square(width, height, rgba, box, pad)
    print(f"内容框 {box[2] - box[0]}x{box[3] - box[1]} → 画布 {side}px")

    out_dir = os.path.join(ROOT, "build") if dry else None
    if dry:
        os.makedirs(out_dir, exist_ok=True)

    rendered = []
    for size in UI_SIZES:
        pixels = resize_area(side, side, canvas, size, size)
        rendered.append((size, pixels))
        if dry:
            write_png(os.path.join(out_dir, f"icon_{size}.png"), size, size, pixels)

    ico = (
        os.path.join(out_dir, "app_icon.ico")
        if dry
        else os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico")
    )
    build_ico(
        [
            (s, encode_png(s, s, px) if s >= 128 else bmp_entry(s, px))
            for s, px in rendered
        ],
        ico,
    )
    print(f"  {ico} ({os.path.getsize(ico)} bytes)")

    big = resize_area(side, side, canvas, UI_PNG_SIZE, UI_PNG_SIZE)
    big_path = (
        os.path.join(out_dir, "app_icon.png")
        if dry
        else os.path.join(ROOT, "assets", "icons", "app_icon.png")
    )
    write_png(big_path, UI_PNG_SIZE, UI_PNG_SIZE, big)
    print(f"  {big_path} ({os.path.getsize(big_path)} bytes)")

    sheet = preview_sheet(rendered, os.path.join(out_dir or os.path.join(ROOT, "build"),
                                                 "_icon_preview.png"))
    print(f"  预览板 {sheet}")


if __name__ == "__main__":
    main()
