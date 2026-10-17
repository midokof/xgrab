"""Verifie qu'aucun widget ne deborde de la fenetre."""

from __future__ import annotations

import tempfile
import time
from pathlib import Path

from xgrab.app import XGrabApp

URL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

CHECKED = [
    "btn_add",
    "btn_pause",
    "ent_url",
    "txt_links",
    "tree",
    "cmb_variant",
    "btn_variant",
    "ent_dir",
    "ent_tpl",
    "chk_auto",
    "bar",
    "lbl_prog",
    "btn_dl",
    "btn_stop",
    "btn_open_file",
    "btn_del",
    "btn_rm",
    "log",
]


def audit_windows(app: XGrabApp, label: str) -> list[str]:
    app.update_idletasks()
    win_w, win_h = app.winfo_width(), app.winfo_height()
    bad = []
    print(f"  fenetre {win_w}x{win_h}  requis {app.needed_height}px")
    if app.needed_height > win_h + 1:
        bad.append(f"{label}: requis {app.needed_height} > fenetre {win_h}")
    for name in CHECKED:
        widget = getattr(app, name, None)
        if widget is None:
            bad.append(f"{label}/{name}: ABSENT")
            continue
        widget.update_idletasks()
        if not widget.winfo_ismapped():
            continue
        x = widget.winfo_rootx() - app.winfo_rootx()
        y = widget.winfo_rooty() - app.winfo_rooty()
        w, h = widget.winfo_width(), widget.winfo_height()
        if y + h > win_h + 1:
            bad.append(f"{label}/{name}: bas y={y + h} > {win_h}")
        if x + w > win_w + 1:
            bad.append(f"{label}/{name}: droite x={x + w} > {win_w}")
    return bad


def main() -> None:
    app = XGrabApp()
    app.auto_var.set(False)
    app.out_var.set(str(Path(tempfile.gettempdir()) / "xgrab_layout_test"))
    app.update_idletasks()
    app.update()

    end = time.monotonic() + 0.5
    while time.monotonic() < end:
        app.update()
        time.sleep(0.02)

    print(f"--- ecran {app.winfo_screenwidth()}x{app.winfo_screenheight()} ---")

    app.url_var.set(URL)
    app._add()
    iid = next(iter(app.jobs))
    app.tree.selection_set(iid)

    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        app.update()
        job = app.jobs[iid]
        if job["status"] == "error" or job.get("variants"):
            break
        time.sleep(0.05)

    app._on_select()
    app.update_idletasks()

    overflow = audit_windows(app, "replie")

    print("--- mode multi-liens deploye ---")
    app._toggle_batch()
    for _ in range(12):
        app.update()
        time.sleep(0.02)
    overflow += audit_windows(app, "multi")

    tw = app.txt_links
    tw.update_idletasks()
    print(f"txt_links : {tw.winfo_width()}x{tw.winfo_height()}")
    if tw.winfo_height() < 20:
        overflow.append(f"txt_links: hauteur {tw.winfo_height()} px, zone multiple inutilisable")

    app._toggle_batch()
    for _ in range(8):
        app.update()
        time.sleep(0.02)

    print("--- journal replie ---")
    app._toggle_log()
    for _ in range(8):
        app.update()
        time.sleep(0.02)
    overflow += audit_windows(app, "sans-journal")
    app._toggle_log()
    for _ in range(8):
        app.update()
        time.sleep(0.02)

    if overflow:
        print("\nDEBORDEMENTS :")
        for line in overflow:
            print("  " + line)
        raise SystemExit(1)

    assert app.jobs[iid]["status"] == "pending", app.jobs[iid]["status"]
    print(f"\nvariantes : {len(app.jobs[iid]['variants'])}")
    print("LAYOUT OK - aucun debordement")
    app._on_close()


if __name__ == "__main__":
    main()
