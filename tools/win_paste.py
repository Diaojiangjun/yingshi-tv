"""把一段文本粘贴到当前焦点控件（先写剪贴板，再按 Ctrl+V）。

用法：
  python tools/win_paste.py "https://example.com/dav/"
  python tools/win_paste.py --clip-only "文本"      # 只写剪贴板不粘贴

说明：
  · 走剪贴板而不是逐字发键码：中文、斜杠、冒号都不用查虚拟键，Flutter 的
    TextField 也能正常收到；
  · 粘贴前请先用 tools/app_tap.py 点中输入框，否则会粘到当前焦点窗口；
  · 剪贴板内容保持到下次覆盖，脚本不改回来。
"""
import ctypes
import sys
import time

u = ctypes.windll.user32
k = ctypes.windll.kernel32

CF_UNICODETEXT = 13
GMEM_MOVEABLE = 0x0002
VK_CONTROL = 0x11
VK_V = 0x56
KEYEVENTF_KEYUP = 0x0002


def set_clipboard(text):
    data = text.encode("utf-16-le") + b"\x00\x00"
    if not u.OpenClipboard(0):
        raise OSError("OpenClipboard failed")
    try:
        u.EmptyClipboard()
        handle = k.GlobalAlloc(GMEM_MOVEABLE, len(data))
        if not handle:
            raise OSError("GlobalAlloc failed")
        ptr = k.GlobalLock(handle)
        ctypes.memmove(ptr, data, len(data))
        k.GlobalUnlock(handle)
        u.SetClipboardData(CF_UNICODETEXT, handle)
    finally:
        u.CloseClipboard()


def paste():
    u.keybd_event(VK_CONTROL, 0, 0, 0)
    u.keybd_event(VK_V, 0, 0, 0)
    time.sleep(0.05)
    u.keybd_event(VK_V, 0, KEYEVENTF_KEYUP, 0)
    u.keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, 0)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    clip_only = argv[1] == "--clip-only"
    text = argv[2] if clip_only else argv[1]
    set_clipboard(text)
    if clip_only:
        print("clipboard updated")
        return 0
    paste()
    print(f"pasted {len(text)} chars")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
