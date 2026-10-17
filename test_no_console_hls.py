"""Verifie l'absence de fenetre console sur le chemin ffmpeg (HLS)."""

from __future__ import annotations

import ctypes
import sys
import tempfile
import threading
import time
from ctypes import wintypes
from pathlib import Path

from xgrab.app import XGrabApp
from xgrab.resolver import resolve

user32 = ctypes.windll.user32
EnumWindowsProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)


def visible_windows():
    found = []

    def callback(hwnd, _lparam):
        if user32.IsWindowVisible(hwnd):
            length = user32.GetWindowTextLengthW(hwnd)
            if length:
                buffer = ctypes.create_unicode_buffer(length + 1)
                user32.GetWindowTextW(hwnd, buffer, length + 1)
                found.append((int(hwnd), buffer.value))
        return True

    user32.EnumWindows(EnumWindowsProc(callback), 0)
    return found


def main(url: str) -> None:
    info = resolve(url)
    variant = info.variants[0]
    print(f"variante : {variant.height_label} {variant.container}")

    app = XGrabApp()
    app.auto_var.set(False)
    app.out_var.set(str(Path(tempfile.gettempdir()) / "xgrab_hlsconsole"))
    app.update()
    seen = set(visible_windows())

    consoles = []
    stop = threading.Event()

    def watcher():
        while not stop.is_set():
            for hwnd, title in visible_windows():
                if (hwnd, title) in seen:
                    continue
                seen.add((hwnd, title))
                low = title.lower()
                if any(word in low for word in ("powershell", "cmd", "console", "ffmpeg")):
                    consoles.append(title)
            time.sleep(0.06)

    threading.Thread(target=watcher, daemon=True).start()

    app.tree.insert("", "end", iid="j1", values=("t", "", "", "", ""))
    app.jobs["j1"] = {
        "url": info.source_url, "status": "pending", "variants": [variant],
        "progress": 0.0, "auto": False, "cookies": "", "browser": "",
        "title": info.title, "author": "a", "tweet_id": "",
        "duration": info.duration_label, "extractor": info.extractor, "status_label": "pret",
    }
    app.current = "j1"
    app.cmb_variant["values"] = [variant.describe()]
    app.cmb_variant.current(0)
    app._start()

    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        app.update()
        job = app.jobs["j1"]
        if job.get("bytes", 0) > 0 or job["status"] == "error":
            break
        time.sleep(0.05)

    stop.set()
    time.sleep(1.0)
    job = app.jobs["j1"]
    print(f"statut   : {job['status']}")
    print(f"recu     : {job.get('bytes', 0)} octets")
    print(f"fenetres console : {len(consoles)}")
    for title in consoles:
        print(f"   {title}")
    app._on_close()

    if consoles:
        raise SystemExit(1)
    print("\nNO CONSOLE HLS OK")


if __name__ == "__main__":
    main(sys.argv[1])