"""从已保存的 BMP 里裁剪一块并可选放大（纯标准库，无 Pillow 依赖）。

用法：python tools/bmp_crop.py in.bmp x y w h out.bmp [scale]

坐标相对 BMP 左上角（BMP 存的是自下而上的行序，这里负责翻转）。
放大用最近邻，只为了看清小字，不追求画质。
"""

import struct
import sys


def read_bmp(path):
    data = open(path, 'rb').read()
    offset = struct.unpack_from('<I', data, 10)[0]
    width, height = struct.unpack_from('<ii', data, 18)
    bpp = struct.unpack_from('<H', data, 28)[0]
    if bpp not in (24, 32):
        raise SystemExit(f'unsupported bpp: {bpp}')

    stride = ((width * bpp + 31) // 32) * 4
    top_down = height < 0
    height = abs(height)
    step = bpp // 8
    rows = []
    for row in range(height):
        start = offset + row * stride
        rows.append(bytes(data[start:start + width * step]))
    if not top_down:
        rows.reverse()
    return width, height, step, rows


def crop(rows, step, x, y, w, h):
    out = []
    for row in rows[y:y + h]:
        out.append(row[x * step:(x + w) * step])
    return out


def write_bmp(path, rows, w, h, step):
    stride = ((w * step + 3) // 4) * 4
    pad = b'\x00' * (stride - w * step)
    body = b''.join(row + pad for row in reversed(rows))
    header = struct.pack('<2sIHHI', b'BM', 54 + len(body), 0, 0, 54)
    info = struct.pack('<IiiHHIIiiII', 40, w, h, 1, step * 8, 0, len(body), 0, 0, 0, 0)
    open(path, 'wb').write(header + info + body)


def scale_up(rows, step, factor):
    out = []
    for row in rows:
        big = bytearray()
        for i in range(0, len(row), step):
            big += row[i:i + step] * factor
        out.extend([bytes(big)] * factor)
    return out


if __name__ == '__main__':
    src, x, y, w, h, dst = sys.argv[1], *map(int, sys.argv[2:6]), sys.argv[6]
    factor = int(sys.argv[7]) if len(sys.argv) > 7 else 1
    width, height, step, rows = read_bmp(src)
    x = max(0, min(x, width - 1))
    y = max(0, min(y, height - 1))
    w = max(1, min(w, width - x))
    h = max(1, min(h, height - y))
    piece = crop(rows, step, x, y, w, h)
    if factor > 1:
        piece = scale_up(piece, step, factor)
        w, h = w * factor, h * factor
    write_bmp(dst, piece, w, h, step)
    print(f'{dst} {w}x{h}')
