"""把修狗TV 窗口强制拉到前台（SetForegroundWindow 被系统拒绝时用 AttachThreadInput 兜底）。

用法：python tools/win_focus.py ["修狗TV"]
"""

import ctypes
import ctypes.wintypes as wt
import sys
import time

u = ctypes.windll.user32
u.SetProcessDPIAware()


def find_window(title, visible_only=False):
    found = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def cb(h, _):
        n = u.GetWindowTextLengthW(h)
        if n:
            b = ctypes.create_unicode_buffer(n + 1)
            u.GetWindowTextW(h, b, n + 1)
            if title in b.value and (not visible_only or u.IsWindowVisible(h)):
                found.append(h)
        return True

    u.EnumWindows(cb, 0)
    return found[0] if found else None


def force_foreground(hwnd):
    u.ShowWindow(hwnd, 9)  # SW_RESTORE
    fg = u.GetForegroundWindow()
    fg_tid = u.GetWindowThreadProcessId(fg, None) if fg else 0
    cur_tid = ctypes.windll.kernel32.GetCurrentThreadId()
    if fg_tid and fg_tid != cur_tid:
        u.AttachThreadInput(fg_tid, cur_tid, True)
    u.BringWindowToTop(hwnd)
    u.SetForegroundWindow(hwnd)
    if fg_tid and fg_tid != cur_tid:
        u.AttachThreadInput(fg_tid, cur_tid, False)
    time.sleep(0.4)
    return u.GetForegroundWindow() == hwnd


if __name__ == "__main__":
    title = sys.argv[1] if len(sys.argv) > 1 else "修狗TV"
    hwnd = find_window(title)
    if hwnd is None:
        print("no window")
        raise SystemExit(1)
    print("hwnd", hwnd, "foreground_ok", force_foreground(hwnd))
