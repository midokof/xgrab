"""Verifie le repli automatique sur un ecran bas (864 px)."""

from __future__ import annotations

import ctypes
import time

FAKE_H = 864
FAKE_W = 1536

_real = ctypes.windll.user32.GetSystemMetrics


def fake(metric: int) -> int:
    if metric == 0:
        return FAKE_W
    if metric == 1:
        return FAKE_H
    return _real(metric)


def main() -> None:
    ctypes.windll.user32.GetSystemMetrics = fake
    try:
        from xgrab.app import XGrabApp

        app = XGrabApp()
        app.update_idletasks()
        app.update()
        for _ in range(30):
            app.update()
            time.sleep(0.02)

        print(f"ecran simule : {FAKE_W}x{FAKE_H}")
        print(f"fenetre      : {app.winfo_width()}x{app.winfo_height()}")
        print(f"requis       : {app.needed_height}px")
        print(f"journal      : {'replie' if not app.log_body.winfo_ismapped() else 'ouvert'}")
        print(f"multi-liens  : {'deploye' if self_ismapped(app) else 'replie'}")

        problems = []
        if app.winfo_height() > FAKE_H - 40:
            problems.append(f"fenetre {app.winfo_height()} trop haute pour {FAKE_H}")
        if app.needed_height > app.winfo_height() + 1:
            problems.append(f"requis {app.needed_height} > fenetre {app.winfo_height()}")

        for name in ("btn_dl", "btn_stop", "btn_del", "btn_add", "ent_url", "tree", "cmb_variant"):
            widget = getattr(app, name)
            widget.update_idletasks()
            if not widget.winfo_ismapped():
                continue
            bottom = widget.winfo_rooty() - app.winfo_rooty() + widget.winfo_height()
            if bottom > app.winfo_height() + 1:
                problems.append(f"{name}: bas y={bottom} > {app.winfo_height()}")

        app._on_close()

        if problems:
            print("\nPROBLEMES :")
            for line in problems:
                print("  " + line)
            raise SystemExit(1)
        print("\nPETIT ECRAN OK")
    finally:
        ctypes.windll.user32.GetSystemMetrics = _real


def self_ismapped(app) -> bool:
    return app.batch.winfo_ismapped()


if __name__ == "__main__":
    main()
