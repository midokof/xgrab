"""Chaine automatique : 403 au download declenche la capture puis relance."""

from __future__ import annotations

import sys
import tempfile
import time
from pathlib import Path

from xgrab.app import XGrabApp


def pump(app: XGrabApp, seconds: float) -> None:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        app.update()
        time.sleep(0.02)


def main(url: str, seconds: float = 150.0) -> None:
    app = XGrabApp()
    app.auto_var.set(False)
    app.out_var.set(str(Path(tempfile.gettempdir()) / "xgrab_auto"))
    pump(app, 0.5)

    app.url_var.set(url)
    app._add()

    deadline = time.monotonic() + 30
    iid = next(iter(app.jobs))
    while time.monotonic() < deadline:
        app.update()
        if app.jobs[iid].get("variants"):
            break
        time.sleep(0.05)

    print(f"analyse  : {len(app.jobs[iid]['variants'])} variante(s), "
          f"connexion={app.jobs[iid].get('login_required')}")

    app.tree.selection_set(iid)
    app._on_select()
    app._start()

    deadline = time.monotonic() + seconds
    saw_bytes = False
    while time.monotonic() < deadline:
        app.update()
        job = app.jobs[iid]
        if job.get("progress", 0) > 0 or job.get("bytes", 0) > 0:
            saw_bytes = True
            app._cancel()
        if job["status"] in ("done", "error", "cancelled"):
            break
        time.sleep(0.2)

    print("\n--- JOURNAL ---")
    print(app.log.get("1.0", "end").strip())
    print("---")
    job = app.jobs[iid]
    print(f"statut   : {job['status']}")
    print(f"capture  : {bool(job.get('captured'))}")
    print(f"retried  : {app.jobs[iid].get('retries', 0)}")
    print(f"progression vue : {saw_bytes}")

    folder = Path(app.out_var.get())
    stem = job.get("stem", "")
    part = folder / f"{stem}.mp4.part"
    final = next(iter(sorted(folder.glob(f"{stem}.mp4"))), None) if stem else None
    written = max(
        part.stat().st_size if part.exists() else 0,
        final.stat().st_size if final else 0,
    )
    print(f"fichier   : {final.name if final else '(partiel)'}")
    print(f"ecrit     : {written} octets")

    log = app.log.get("1.0", "end")
    blocked = "capture automatique" in log
    got_bytes = saw_bytes or written > 0

    print(f"bloquant  : {blocked}")

    problems = []
    if not got_bytes:
        problems.append("aucun octet reçu")
    if blocked and "Requête interceptée" not in log:
        problems.append("bloqué mais interception non confirmée")
    if not blocked and not got_bytes:
        problems.append("ni capture ni téléchargement direct")

    app._on_close()
    for line in problems:
        print("PROBLEME: " + line)
    if problems:
        raise SystemExit(1)
    print("\nAUTO CAPTURE OK")


if __name__ == "__main__":
    main(sys.argv[1])