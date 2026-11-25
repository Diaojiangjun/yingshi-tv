"""先聚焦应用窗口，再点击（支持像素或相对比例）。

用法：
  python tools/app_tap.py 185 82            # 屏幕物理像素
  python tools/app_tap.py 0.75 0.22         # 相对窗口宽高的比例（推荐，窗口尺寸变化时仍准确）

说明：
  · 比例坐标按点击瞬间的窗口矩形换算，全屏 / 窗口模式来回切换也不会错位；
  · 点击用 mouse_event：SendInput 在本机会把光标带走、落点漂移，不要用；
  · 窗口标题默认「影视」，可用环境变量 APP_TITLE 覆盖（改名后不用改脚本）。
"""
import ctypes
import os
import sys
import time

u = ctypes.windll.user32
u.SetProcessDPIAware()

SW_RESTORE = 9
TITLE = os.environ.get("APP_TITLE", "影视")


class RECT(ctypes.Structure):
    _fields_ = [
        ("left", ctypes.c_long),
        ("top", ctypes.c_long),
        ("right", ctypes.c_long),
        ("bottom", ctypes.c_long),
    ]


def focus_app():
    """优先取标题完全相同的窗口：浏览器标签里带上软件名时不该被误聚焦。"""
    exact, fuzzy = [], []

    EnumProc = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)

    def cb(h, _):
        if not u.IsWindowVisible(h):
            return True
        n = u.GetWindowTextLengthW(h)
        if n:
            buf = ctypes.create_unicode_buffer(n + 1)
            u.GetWindowTextW(h, buf, n + 1)
            if buf.value == TITLE:
                exact.append(h)
            elif TITLE in buf.value:
                fuzzy.append(h)
        return True

    u.EnumWindows(EnumProc(cb), 0)
    found = exact or fuzzy
    if not found:
        raise SystemExit("no window")
    hwnd = found[0]
    u.ShowWindow(hwnd, SW_RESTORE)
    u.SwitchToThisWindow(hwnd, True)
    u.SetForegroundWindow(hwnd)
    time.sleep(0.5)
    return hwnd


def rect_of(hwnd):
    r = RECT()
    u.GetWindowRect(hwnd, ctypes.byref(r))
    return r


def tap(x, y):
    u.SetCursorPos(int(round(x)), int(round(y)))
    time.sleep(0.15)
    u.mouse_event(0x0002, 0, 0, 0, 0)
    time.sleep(0.06)
    u.mouse_event(0x0004, 0, 0, 0, 0)


if __name__ == "__main__":
    vals = [float(v) for v in sys.argv[1:]]
    if len(vals) % 2:
        raise SystemExit("坐标要成对")
    hwnd = focus_app()
    for i in range(0, len(vals), 2):
        r = rect_of(hwnd)
        w, h = r.right - r.left, r.bottom - r.top
        ax, ay = vals[i], vals[i + 1]
        if ax < 1.0 and ay < 1.0:
            x, y = r.left + ax * w, r.top + ay * h
            kind = f"rel({ax},{ay})"
        else:
            x, y = ax, ay
            kind = "abs"
        tap(x, y)
        print(f"tap {kind} -> {int(x)},{int(y)} rect={r.left},{r.top},{w}x{h}")
        time.sleep(0.9)
