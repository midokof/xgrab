"""Verifie que le bouton 'Ouvrir le dossier' ouvre le bon dossier."""

from __future__ import annotations

import os
import tempfile
import time
from pathlib import Path

from xgrab.app import XGrabApp

target = Path(tempfile.gettempdir()) / "xgrab_dossier_test"
target.mkdir(parents=True, exist_ok=True)

opened: list[str] = []
os.startfile = lambda path: opened.append(str(path))  # type: ignore[assignment]

app = XGrabApp()
app.auto_var.set(False)
app.out_var.set(str(target))
app.update()

buttons = []
for child in app.winfo_children():
    buttons.extend(child.winfo_children())


def walk(widget):
    yield widget
    for child in widget.winfo_children():
        yield from walk(child)


all_widgets = list(walk(app))
labels = [
    w.cget("text")
    for w in all_widgets
    if isinstance(w, type(app.ent_dir)) or w.winfo_class() in ("TButton", "Button")
]
print(f"boutons trouves : {[x for x in labels if x]}")

target_btn = None
for w in all_widgets:
    try:
        if w.cget("text") == "Ouvrir le dossier":
            target_btn = w
            break
    except Exception:
        continue

if target_btn is None:
    raise SystemExit("ECHEC : bouton 'Ouvrir le dossier' absent")

print(f"bouton          : {target_btn.cget('text')}  state={target_btn.cget('state')}")
print(f"dossier configured : {app.out_var.get()}")

target_btn.invoke()
time.sleep(0.4)

print(f"dossier ouvert  : {opened}")
app._on_close()

if not opened:
    raise SystemExit("ECHEC : aucun dossier ouvert")
if Path(opened[0]) != target:
    raise SystemExit(f"ECHEC : mauvais dossier -> {opened[0]}")

print("\nDOSSIER OK")
