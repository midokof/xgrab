"""Reproduit des clics REELS sur TELECHARGER / PAUSE / STOP."""

from __future__ import annotations

import tempfile
import time
from pathlib import Path

from xgrab.app import XGrabApp

app = XGrabApp()
app.auto_var.set(False)
app.out_var.set(str(Path(tempfile.gettempdir()) / "xgrab_click"))
app.update()


def click(widget) -> str:
    """Simule un clic reel (Button-1 + Release) sur un widget Canvas."""
    widget.update_idletasks()
    x = widget.winfo_width() // 2
    y = widget.winfo_height() // 2
    out = []
    widget.event_generate("<Enter>", x=x, y=y)
    widget.event_generate("<Button-1>", x=x, y=y)
    widget.update()
    out.append(widget.cget("state") if hasattr(widget, "cget") else "?")
    widget.event_generate("<ButtonRelease-1>", x=x, y=y)
    app.update()
    return out[0]


def pump(seconds: float) -> None:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        app.update()
        while True:
            try:
                app._handle(app.queue.get_nowait())
            except Exception:
                break
        time.sleep(0.03)


app.url_var.set("https://fr.pornhub.com/view_video.php?viewkey=6ac55a667d76f")
app._add()
iid = next(iter(app.jobs))
app.tree.selection_set(iid)
app._on_select()

print(f"TELECHARGER state  : {app.btn_dl.cget('state')}")
print(f"PAUSE state        : {app.btn_pause.cget('state')}")
print(f"STOP state         : {app.btn_stop.cget('state')}")

pump(40)
print(f"\napres resolution ({app.jobs[iid]['status']}):")
print(f"  variantes        : {len(app.jobs[iid].get('variants') or [])}")
print(f"  TELECHARGER state: {app.btn_dl.cget('state')}")
print(f"  STOP state       : {app.btn_stop.cget('state')}")

print("\n--- clic TELECHARGER ---")
click(app.btn_dl)
pump(6)
job = app.jobs[iid]
print(f"  statut           : {job['status']}")
print(f"  octets           : {job.get('bytes', 0)}")
print(f"  TELECHARGER      : {app.btn_dl.cget('state')}")
print(f"  STOP             : {app.btn_stop.cget('state')}")
print(f"  PAUSE            : {app.btn_pause.cget('state')}")

if job.get("bytes", 0) <= 0:
    print("\nECHEC : TELECHARGER ne demarre rien")
    app._on_close()
    raise SystemExit(1)

print("\n--- clic PAUSE ---")
click(app.btn_pause)
pump(3)
job = app.jobs[iid]
print(f"  statut           : {job['status']}")
print(f"  texte bouton     : {app.btn_pause.cget('text')}")
print(f"  PAUSE state      : {app.btn_pause.cget('state')}")

print("\n--- clic STOP ---")
click(app.btn_stop)
pump(3)
job = app.jobs[iid]
print(f"  statut           : {job['status']}")
print(f"  STOP state       : {app.btn_stop.cget('state')}")
print(f"  TELECHARGER      : {app.btn_dl.cget('state')}")
print(f"  PAUSE/REPRENDRE  : {app.btn_pause.cget('text')}")

if job["status"] not in ("cancelled", "error"):
    raise SystemExit("ECHEC : STOP inactif")

print("\n--- clic REPRENDRE ---")
click(app.btn_pause)
pump(8)
job = app.jobs[iid]
print(f"  statut           : {job['status']}")
print(f"  octets           : {job.get('bytes', 0)}")
print(f"  texte bouton     : {app.btn_pause.cget('text')}")
print(f"  STOP state       : {app.btn_stop.cget('state')}")

if job["status"] != "working":
    raise SystemExit("ECHEC : REPRENDRE ne relance pas")

print("\n--- clic STOP en cours de telechargement ---")
click(app.btn_stop)
pump(4)
job = app.jobs[iid]
print(f"  statut           : {job['status']}")
print(f"  STOP state       : {app.btn_stop.cget('state')}")
app._on_close()

if job["status"] != "cancelled":
    raise SystemExit("ECHEC : STOP en cours ne marche pas")
print("\nCLIC OK")
