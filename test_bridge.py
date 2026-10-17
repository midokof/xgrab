"""Test complet : serveur local -> application -> telechargement."""

from __future__ import annotations

import json
import tempfile
import time
from pathlib import Path

import requests

from xgrab.app import XGrabApp
from xgrab.server import write_bridge_config

app = XGrabApp()
app.auto_var.set(False)
app.out_var.set(str(Path(tempfile.gettempdir()) / "xgrab_bridge"))
app.update()

bridge = app.bridge
assert bridge and bridge.port, "le serveur n'a pas demarre"

print(f"port            : {bridge.port}")
print(f"config extension : {write_bridge_config(bridge.port, bridge.token)}")

cfg = Path("extension/config.json")
print(f"config.json     : {'ecrit' if cfg.exists() else 'ABSENT'} -> {cfg.read_text(encoding='utf-8') if cfg.exists() else ''}")

BASE = f"http://127.0.0.1:{bridge.port}"


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


print("\n--- ping ---")
print(" ", requests.get(f"{BASE}/ping", timeout=5).json())

print("\n--- refus sans jeton ---")
r = requests.post(
    f"{BASE}/add", json={"urls": ["https://cdn.test/a.mp4"]}, timeout=5
)
print(f"  HTTP {r.status_code} {r.json()}")

print("\n--- refus origine inconnue ---")
r = requests.post(
    f"{BASE}/add",
    json={"urls": ["https://cdn.test/a.mp4"]},
    headers={"X-XGrab-Token": bridge.token, "Origin": "https://malveillant.example"},
    timeout=5,
)
print(f"  HTTP {r.status_code} {r.json()}")

print("\n--- refus blob et non-http ---")
r = requests.post(
    f"{BASE}/add",
    json={"urls": ["blob:https://x.test/abc", "file:///etc/passwd", ""]},
    headers={"X-XGrab-Token": bridge.token},
    timeout=5,
)
print(f"  HTTP {r.status_code} {r.json()}")

print("\n--- ajout reel (lien X) ---")
url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
r = requests.post(
    f"{BASE}/add",
    json={"urls": [url]},
    headers={"X-XGrab-Token": bridge.token, "Origin": "chrome-extension://abc"},
    timeout=5,
)
print(f"  HTTP {r.status_code} {r.json()}")

pump(3)
print(f"  elements en file : {len(app.jobs)}")
iid = next(iter(app.jobs))
print(f"  url du job       : {app.jobs[iid]['url'][:60]}")

pump(30)
job = app.jobs[iid]
print(f"  statut           : {job['status']} / {job.get('status_label')}")
print(f"  variantes        : {len(job.get('variants') or [])}")
app._on_close()

if r.status_code != 200 or not job.get("variants"):
    raise SystemExit("ECHEC")
print("\nBRIDGE OK")
