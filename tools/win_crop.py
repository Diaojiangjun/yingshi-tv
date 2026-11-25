"""裁剪当前窗口的一块区域并保存为 BMP（纯 ctypes + GDI，无需 Pillow）。

用法：python tools/win_crop.py x y w h out.bmp [--window "修狗TV"]
坐标是相对窗口左上角的像素。
"""

import ctypes
import ctypes.wintypes as wt
import struct
import sys
import time

u = ctypes.windll.user32
g = ctypes.windll.gdi32
u.SetProcessDPIAware()


class BIH(ctypes.Structure):
    _fields_ = [
        ("biSize", wt.DWORD),
        ("biWidth", ctypes.c_long),
        ("biHeight", ctypes.c_long),
        ("biPlanes", wt.WORD),
        ("biBitCount", wt.WORD),
        ("biCompression", wt.DWORD),
        ("biSizeImage", wt.DWORD),
        ("biXPelsPerMeter", ctypes.c_long),
        ("biYPelsPerMeter", ctypes.c_long),
        ("biClrUsed", wt.DWORD),
        ("biClrImportant", wt.DWORD),
    ]


def find_window(title):
    found = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def cb(h, _):
        n = u.GetWindowTextLengthW(h)
        if n:
            b = ctypes.create_unicode_buffer(n + 1)
            u.GetWindowTextW(h, b, n + 1)
            if title in b.value and u.IsWindowVisible(h):
                found.append(h)
        return True

    u.EnumWindows(cb, 0)
    return found[0] if found else None


def crop(hwnd, x, y, w, h, out):
    u.SetForegroundWindow(hwnd)
    time.sleep(0.35)
    r = wt.RECT()
    u.GetWindowRect(hwnd, ctypes.byref(r))
    src = u.GetDC(0)
    mem = g.CreateCompatibleDC(src)
    bmp = g.CreateCompatibleBitmap(src, w, h)
    g.SelectObject(mem, bmp)
    g.BitBlt(mem, 0, 0, w, h, src, r.left + x, r.top + y, 0x00CC0020)
    hdr = BIH(ctypes.sizeof(BIH), w, -h, 1, 32, 0, w * h * 4, 0, 0, 0, 0)
    buf = ctypes.create_string_buffer(w * h * 4)
    g.GetDIBits(mem, bmp, 0, h, buf, ctypes.byref(hdr), 0)
    g.DeleteObject(bmp)
    g.DeleteDC(mem)
    u.ReleaseDC(0, src)
    pixel_bytes = w * h * 4
    file_header = struct.pack("<2sIHHI", b"BM", 14 + 40 + pixel_bytes, 0, 0, 54)
    dib = ctypes.string_at(ctypes.byref(hdr), ctypes.sizeof(BIH))
    with open(out, "wb") as f:
        f.write(file_header)
        f.write(dib)
        f.write(buf.raw)
    print(f"{out} {w}x{h}")


if __name__ == "__main__":
    title = "修狗TV"
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--window" in sys.argv:
        title = sys.argv[sys.argv.index("--window") + 1]
        args = [a for i, a in enumerate(sys.argv[1:], start=1)
                if a != "--window" and sys.argv[i - 1] != "--window" and not a.startswith("--")]
    x, y, w, h = (int(v) for v in args[:4])
    out = args[4]
    hwnd = find_window(title)
    if hwnd is None:
        print("no window")
        raise SystemExit(1)
    crop(hwnd, x, y, w, h, out)
