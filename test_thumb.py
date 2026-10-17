"""Verifie l'affichage de la vignette dans la carte detail."""

from __future__ import annotations

import tempfile
import time
from pathlib import Path

from xgrab.app import XGrabApp
from xgrab.resolver import resolve
from xgrab import thumbs

app = XGrabApp()
app.auto_var.set(False)
app.out_var.set(str(Path(tempfile.gettempdir()) / "xgrab_thumb"))
app.update()

print(f"vignette     : {app.thumb_holder.winfo_width()} x {app.thumb_holder.winfo_height()} px")
print(f"attendu      : 168 x 95 px")

info = resolve("https://fr.pornhub.com/view_video.php?viewkey=6ac55a667d76f")
print(f"thumbnail    : {info.thumbnail[:80]}")

app.tree.insert("", "end", iid="t1", values=("t", "", "", "", ""))
app.jobs["t1"] = {
    "url": info.source_url, "status": "pending", "variants": info.variants,
    "progress": 0.0, "auto": False, "cookies": "", "browser": "",
    "title": info.title, "author": info.author, "tweet_id": "",
    "duration": info.duration_label, "extractor": info.extractor,
    "status_label": "prêt", "thumb_url": info.thumbnail,
    "duration_seconds": info.duration, "_thumb_at": 0.0,
}
app.tree.selection_set("t1")
app._on_select()

deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    app.update()
    while True:
        try:
            app._handle(app.queue.get_nowait())
        except Exception:
            break
    if app._thumb_photo is not None:
        break
    time.sleep(0.1)

photo = app._thumb_photo
print(f"photo       : {photo.width()} x {photo.height()} px" if photo else "photo       : AUCUNE")
print(f"texte       : {app.lbl_thumb.cget('text')!r}")
app._on_close()

if photo is None:
    raise SystemExit("ECHEC: aucune vignette affichee")
print("\nTHUMB OK")
