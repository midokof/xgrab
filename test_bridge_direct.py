"""Test du chemin direct : lien media pousse par l'extension -> telechargement."""

from __future__ import annotations

import tempfile
import time
from pathlib import Path

import requests

from xgrab.app import XGrabApp

app = XGrabApp()
app.auto_var.set(False)
app.out_var.set(str(Path(tempfile.gettempdir()) / "xgrab_bridge2"))
app.update()

base = f"http://127.0.0.1:{app.bridge.port}"
url = "https://fr.pornhub.com/view_video.php?viewkey=6ac55a667d76f"


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


print("envoi d'un lien page (doit passer par l'analyse) + d'un lien media direct")
r = requests.post(
    f"{base}/add",
    json={"urls": [url]},
    headers={"X-XGrab-Token": app.bridge.token, "Origin": "moz-extension://x"},
    timeout=5,
)
print(f"  HTTP {r.status_code} {r.json()}")

pump(20)
print(f"  jobs        : {len(app.jobs)}")

# trouve un vrai lien media direct en resolvant le lien page
from xgrab.resolver import resolve

info = resolve(url)
direct = next(v.url for v in info.variants)
print(f"\nmedia direct : {direct[:78]}")

r = requests.post(
    f"{base}/add",
    json={"urls": [direct], "referer": url},
    headers={"X-XGrab-Token": app.bridge.token, "Origin": "chrome-extension://x"},
    timeout=5,
)
print(f"  HTTP {r.status_code} {r.json()}")

pump(6)
direct_job = None
for iid, job in app.jobs.items():
    if job.get("direct"):
        direct_job = job
        break

if not direct_job:
    raise SystemExit("ECHEC : le lien direct n'a pas cree de job")

print(f"  extractor   : {direct_job['extractor']}")
print(f"  statut      : {direct_job['status']} / {direct_job['status_label']}")
print(f"  variantes   : {len(direct_job['variants'])} -> {direct_job['variants'][0].describe()}")
print(f"  taille      : {direct_job['variants'][0].size}")

pump(20)
print(f"  apres 20 s  : statut={direct_job['status']} octets={direct_job.get('bytes', 0)}")
app._on_close()

if direct_job["status"] not in ("working", "done", "pending"):
    raise SystemExit("ECHEC")
if direct_job.get("bytes", 0) <= 0 and direct_job["status"] != "pending":
    raise SystemExit("ECHEC : aucun octet")
print("\nBRIDGE DIRECT OK")
