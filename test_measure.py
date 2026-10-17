"""Mesure la hauteur naturelle de chaque bloc et la hauteur totale requise."""

from __future__ import annotations

import tkinter as tk

from xgrab.app import XGrabApp


def main() -> None:
    app = XGrabApp()
    app.update_idletasks()
    app.update()

    blocks = []
    for child in app.winfo_children():
        try:
            info = child.pack_info()
        except tk.TclError:
            continue
        blocks.append((child, info))
        print(f"classe={child.winfo_class():<12} pady={info.get('pady')!s:<12} "
              f"h={child.winfo_height():<5} y={child.winfo_rooty() - app.winfo_rooty()}")

    natural = sum(c.winfo_reqheight() for c, _ in blocks)
    win = app.winfo_height()
    print(f"\nfenetre       : {app.winfo_width()}x{win}")
    print(f"hauteur req.  : {natural}")
    print(f"largeur req.  : {max(c.winfo_reqwidth() for c, _ in blocks)}")

    screen_w = app.winfo_screenwidth()
    screen_h = app.winfo_screenheight()
    import ctypes
    pw = ctypes.windll.user32.GetSystemMetrics(0)
    ph = ctypes.windll.user32.GetSystemMetrics(1)
    print(f"tk  screen    : {screen_w}x{screen_h}")
    print(f"win32 screen  : {pw}x{ph}")
    print(f"exces         : {natural - win} px")

    app._on_close()


if __name__ == "__main__":
    main()
