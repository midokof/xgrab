"""Flux reel : AJOUTER -> resolution -> vignette + liste, sans _on_select manuel."""

from __future__ import annotations

import tempfile
import time
from pathlib import Path

from xgrab.app import XGrabApp

app = XGrabApp()
app.auto_var.set(False)
app.out_var.set(str(Path(tempfile.gettempdir()) / "xgrab_thumbflow"))
app.update()

app.url_var.set("https://fr.pornhub.com/view_video.php?viewkey=6ac55a667d76f")
app._add()

iid = next(iter(app.jobs))
app.tree.selection_set(iid)
app._on_select()
print(f"avant resolution : variantes={len(app.jobs[iid].get('variants') or [])}")

deadline = time.monotonic() + 60
while time.monotonic() < deadline:
    app.update()
    while True:
        try:
            app._handle(app.queue.get_nowait())
        except Exception:
            break
    job = app.jobs[iid]
    if job.get("variants") and app._thumb_photo is not None:
        break
    time.sleep(0.1)

job = app.jobs[iid]
values = list(app.cmb_variant["values"])
print(f"statut            : {job['status']}")
print(f"titre affiche     : {app.lbl_title.cget('text')[:50]}")
print(f"liste resolutions : {len(values)} valeurs -> {values[0] if values else 'VIDE'}")
print(f"bouton Sonner     : {app.btn_variant.cget('state')}")
print(f"vignette          : {app._thumb_photo.width()}x{app._thumb_photo.height()} px" if app._thumb_photo else "vignette          : AUCUNE")
print(f"placeholder       : {app.lbl_thumb.cget('text')!r}")
app._on_close()

ok = bool(values) and app._thumb_photo is not None
if not ok:
    raise SystemExit("ECHEC")
print("\nFLOW THUMB OK")
