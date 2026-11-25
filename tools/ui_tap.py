"""按屏幕坐标点一下（SendInput，Flutter 桌面下比 mouse_event 可靠）。

用法：python tools/ui_tap.py 1224 169
"""

import ctypes
import ctypes.wintypes as wt
import sys
import time

u = ctypes.windll.user32
u.SetProcessDPIAware()


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", ctypes.c_long),
        ("dy", ctypes.c_long),
        ("mouseData", wt.DWORD),
        ("dwFlags", wt.DWORD),
        ("time", wt.DWORD),
        ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
    ]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wt.DWORD), ("mi", MOUSEINPUT)]


def tap(x, y):
    u.SetCursorPos(x, y)
    time.sleep(0.12)
    for flag in (0x0002, 0x0004):  # LEFTDOWN, LEFTUP
        inp = INPUT(type=0, mi=MOUSEINPUT(0, 0, 0, flag, 0, None))
        u.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))
        time.sleep(0.06)


if __name__ == "__main__":
    tap(int(sys.argv[1]), int(sys.argv[2]))
    print("tap", sys.argv[1], sys.argv[2])
