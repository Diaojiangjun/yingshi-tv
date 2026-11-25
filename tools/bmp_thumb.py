"""把 bmp 缩放成小尺寸 bmp（GDI StretchBlt，无第三方库）。

用法：python tools/bmp_thumb.py in.bmp out.bmp 480 270
"""
import ctypes
import struct
import sys

gdi32 = ctypes.windll.gdi32
user32 = ctypes.windll.user32
user32.SetProcessDPIAware()


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", ctypes.c_uint32),
        ("biWidth", ctypes.c_int32),
        ("biHeight", ctypes.c_int32),
        ("biPlanes", ctypes.c_uint16),
        ("biBitCount", ctypes.c_uint16),
        ("biCompression", ctypes.c_uint32),
        ("biSizeImage", ctypes.c_uint32),
        ("biXPelsPerMeter", ctypes.c_int32),
        ("biYPelsPerMeter", ctypes.c_int32),
        ("biClrUsed", ctypes.c_uint32),
        ("biClrImportant", ctypes.c_uint32),
    ]


def read_bmp(path):
    with open(path, "rb") as f:
        data = f.read()
    offset = struct.unpack_from("<I", data, 10)[0]
    w, h = struct.unpack_from("<ii", data, 18)
    bits = struct.unpack_from("<H", data, 28)[0]
    if bits != 32:
        raise SystemExit(f"only 32bpp bmp supported, got {bits}")
    return data, offset, w, abs(h)


def make_dib(w, h, pixels):
    hdr = BITMAPINFOHEADER(
        ctypes.sizeof(BITMAPINFOHEADER), w, -h, 1, 32, 0, w * h * 4, 0, 0, 0, 0
    )
    return hdr, pixels


def main():
    src, dst, tw, th = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    data, offset, w, h = read_bmp(src)
    pixels = data[offset:]
    hdr, pix = make_dib(w, h, pixels)
    src_dc = gdi32.CreateCompatibleDC(0)
    src_bmp = gdi32.CreateDIBSection(0, ctypes.byref(hdr), 0, ctypes.byref(pix_ref := ctypes.c_void_p()), 0, 0)
    ctypes.memmove(pix_ref.value, pixels, w * h * 4)
    gdi32.SelectObject(src_dc, src_bmp)

    dhdr, _ = make_dib(tw, th, b"")
    dst_dc = gdi32.CreateCompatibleDC(0)
    dbmp = gdi32.CreateDIBSection(0, ctypes.byref(dhdr), 0, ctypes.byref(dst_ref := ctypes.c_void_p()), 0, 0)
    gdi32.SelectObject(dst_dc, dbmp)
    gdi32.SetStretchBltMode(dst_dc, 4)  # HALFTONE
    gdi32.StretchBlt(dst_dc, 0, 0, tw, th, src_dc, 0, 0, w, h, 0x00CC0020)

    buf = ctypes.string_at(dst_ref.value, tw * th * 4)
    with open(dst, "wb") as f:
        f.write(b"BM")
        f.write(struct.pack("<IHHI", 54 + len(buf), 0, 0, 54))
        f.write(struct.pack("<IiiHHIIiiII", 40, tw, -th, 1, 32, 0, len(buf), 0, 0, 0, 0))
        f.write(buf)
    print(f"{src} {w}x{h} -> {dst} {tw}x{th}")


if __name__ == "__main__":
    main()
