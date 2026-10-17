"""Detecte l'apparition d'une fenetre console pendant un telechargement."""

from __future__ import annotations

import ctypes
import sys
import threading
import time
from ctypes import wintypes
from pathlib import Path

from xgrab.app import XGrabApp

user32 = ctypes.windll.user32

EnumWindowsProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)


def visible_windows() -> list[tuple[int, str]]:
    found: list[tuple[int, str]] = []

    def callback(hwnd, _lparam):
        if not user32.IsWindowVisible(hwnd):
            return True
        length = user32.GetWindowTextLengthW(hwnd)
        if length == 0:
            return True
        buffer = ctypes.create_unicode_buffer(length + 1)
        user32.GetWindowTextW(hwnd, buffer, length + 1)
        found.append((int(hwnd), buffer.value))
        return True

    user32.EnumWindows(EnumWindowsProc(callback), 0)
    return found


def main(url: str) -> None:
    console_windows: list[str] = []
    seen: set[tuple[int, str]] = set()
    stop = threading.Event()

    def watcher() -> None:
        while not stop.is_set():
            for hwnd, title in visible_windows():
                if (hwnd, title) in seen:
                    continue
                seen.add((hwnd, title))
                low = title.lower()
                if "powershell" in low or "cmd" in low or "console" in low:
                    console_windows.append(title)
            time.sleep(0.08)

    app = XGrabApp()
    app.auto_var.set(False)
    app.out_var.set(str(Path(__import__("tempfile").gettempdir()) / "xgrab_noconsole"))
    app.update()
    seen.update(visible_windows())

    threading.Thread(target=watcher, daemon=True).start()

    app.url_var.set(url)
    app._add()
    iid = next(iter(app.jobs))

    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        app.update()
        job = app.jobs[iid]
        if job["status"] == "error" or job.get("variants"):
            break
        time.sleep(0.05)

    app.tree.selection_set(iid)
    app._on_select()
    app._start()

    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        app.update()
        job = app.jobs[iid]
        if job.get("bytes", 0) > 300_000 or job["status"] in ("error", "done"):
            break
        time.sleep(0.05)

    stop.set()
    status = app.jobs[iid]["status"]
    received = app.jobs[iid].get("bytes", 0)
    app._cancel()
    time.sleep(1.5)
    app._on_close()

    print(f"statut   : {status}")
    print(f"recu     : {received} octets")
    print(f"fenetres console detectees : {len(console_windows)}")
    for title in console_windows:
        print(f"   {title}")

    if console_windows:
        raise SystemExit(1)
    if received <= 0:
        raise SystemExit("aucun octet recu")
    print("\nNO CONSOLE OK")


if __name__ == "__main__":
    main(sys.argv[1])