"""把窗口强拉到前台并截图（ctypes + GDI，无需第三方库）。"""
import ctypes
import ctypes.wintypes as wt
import struct
import sys
import time

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32
kernel32 = ctypes.windll.kernel32

user32.SetProcessDPIAware()
SW_RESTORE = 9
HWND_TOPMOST = -1
HWND_NOTOPMOST = -2
SWP_NOMOVE = 0x0002
SWP_NOSIZE = 0x0001
SWP_SHOWWINDOW = 0x0040


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", wt.DWORD), ("biWidth", ctypes.c_long), ("biHeight", ctypes.c_long),
        ("biPlanes", wt.WORD), ("biBitCount", wt.WORD), ("biCompression", wt.DWORD),
        ("biSizeImage", wt.DWORD), ("biXPelsPerMeter", ctypes.c_long),
        ("biYPelsPerMeter", ctypes.c_long), ("biClrUsed", wt.DWORD),
        ("biClrImportant", wt.DWORD),
    ]


def find_window(title_part):
    """优先返回标题完全相同的窗口。

    只按「包含」匹配会误伤：浏览器标签一旦标题里带上软件名（比如 GitHub 仓库页
    的描述写着「影视 —— …」），截到的就是浏览器而不是应用。
    """
    exact, fuzzy = [], []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def cb(hwnd, _):
        n = user32.GetWindowTextLengthW(hwnd)
        if n:
            b = ctypes.create_unicode_buffer(n + 1)
            user32.GetWindowTextW(hwnd, b, n + 1)
            if user32.IsWindowVisible(hwnd):
                if b.value == title_part:
                    exact.append((hwnd, b.value))
                elif title_part in b.value:
                    fuzzy.append((hwnd, b.value))
        return True

    user32.EnumWindows(cb, 0)
    return exact or fuzzy


def force_foreground(hwnd):
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, SW_RESTORE)
    user32.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW)
    user32.SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW)
    user32.SwitchToThisWindow(hwnd, True)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.6)


def save_rect(rect, path):
    w, h = rect.right - rect.left, rect.bottom - rect.top
    src = user32.GetDC(0)
    mem = gdi32.CreateCompatibleDC(src)
    bmp = gdi32.CreateCompatibleBitmap(src, w, h)
    gdi32.SelectObject(mem, bmp)
    gdi32.BitBlt(mem, 0, 0, w, h, src, rect.left, rect.top, 0x00CC0020)
    hdr = BITMAPINFOHEADER(ctypes.sizeof(BITMAPINFOHEADER), w, -h, 1, 32, 0, w * h * 4, 0, 0, 0, 0)
    buf = ctypes.create_string_buffer(w * h * 4)
    gdi32.GetDIBits(mem, bmp, 0, h, buf, ctypes.byref(hdr), 0)
    gdi32.DeleteObject(bmp)
    gdi32.DeleteDC(mem)
    user32.ReleaseDC(0, src)
    with open(path, "wb") as f:
        f.write(b"BM")
        f.write(struct.pack("<IHHI", 54 + w * h * 4, 0, 0, 54))
        f.write(struct.pack("<IiiHHIIiiII", 40, w, -h, 1, 32, 0, w * h * 4, 0, 0, 0, 0))
        f.write(buf.raw)
    return w, h


if __name__ == "__main__":
    title = sys.argv[1] if len(sys.argv) > 1 else "修狗TV"
    out = sys.argv[2] if len(sys.argv) > 2 else "build/_fg.bmp"
    wins = find_window(title)
    if not wins:
        print("no window")
        raise SystemExit(1)
    hwnd, name = wins[0]
    force_foreground(hwnd)
    fg = user32.GetForegroundWindow()
    rect = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    w, h = save_rect(rect, out)
    print(f"hwnd={hwnd} title={name} foreground={fg} ({'ok' if fg == hwnd else 'blocked'}) rect={rect.left},{rect.top},{w}x{h} -> {out}")
