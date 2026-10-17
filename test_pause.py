"""Pause puis reprise : verifie que le .part est conserve et repris au bon octet."""

from __future__ import annotations

import tempfile
import time
from pathlib import Path

from xgrab.app import XGrabApp

URL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"


def pump(app: XGrabApp, seconds: float) -> None:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        app.update()
        time.sleep(0.02)


def wait_resolved(app: XGrabApp, iid: str, limit: float = 60.0) -> None:
    deadline = time.monotonic() + limit
    while time.monotonic() < deadline:
        app.update()
        job = app.jobs[iid]
        if job["status"] == "error" or job.get("variants"):
            return
        time.sleep(0.05)


def wait_bytes(app: XGrabApp, job: dict, minimum: int, limit: float = 60.0) -> int:
    deadline = time.monotonic() + limit
    seen = 0
    while time.monotonic() < deadline:
        app.update()
        seen = job.get("bytes", 0)
        if seen >= minimum:
            return seen
        time.sleep(0.05)
    return seen


def main() -> None:
    out = Path(tempfile.gettempdir()) / "xgrab_pause"
    out.mkdir(parents=True, exist_ok=True)

    app = XGrabApp()
    app.auto_var.set(False)
    app.out_var.set(str(out))
    pump(app, 0.5)

    assert app.btn_pause.cget("text").endswith("PAUSE"), "libelle pause incorrect"
    assert str(app.btn_pause["state"]) == "disabled", "pause active au repos"
    print(f"bouton    : {app.btn_pause.cget('text').strip()} / {app.btn_pause['state']}")

    app.url_var.set(URL)
    app._add()
    iid = next(iter(app.jobs))
    wait_resolved(app, iid)
    job = app.jobs[iid]
    assert job.get("variants"), "analyse vide"
    print(f"variantes : {len(job['variantes'] if 'variantes' in job else job['variants'])}")

    app.tree.selection_set(iid)
    app._on_select()
    # On prend une qualite mediane : la plus petite finit trop vite pour que
    # la pause soit testable de facon fiable.
    app.cmb_variant.current(min(2, len(job["variants"]) - 1))
    app._start()

    seen = wait_bytes(app, job, 1_500_000)
    assert seen > 0, "aucun octet avant la pause"
    print(f"recu      : {seen} octets")

    app._toggle_pause()
    pump(app, 4.0)

    part = app._partial_path(job)
    paused_size = part.stat().st_size if part else 0
    print(f"statut    : {job['status']}")
    print(f"bouton    : {app.btn_pause.cget('text').strip()} / {app.btn_pause['state']}")
    print(f"part      : {paused_size} octets")

    problems = []
    if job["status"] != "paused":
        problems.append(f"statut attendu 'paused', obtenu '{job['status']}'")
    if paused_size <= 0:
        problems.append(".part vide apres pause")
    if "REPRENDRE" not in app.btn_pause.cget("text"):
        problems.append("le bouton ne propose pas la reprise")
    if str(app.btn_pause["state"]) != "normal":
        problems.append("bouton reprise inactif")

    app._toggle_pause()
    pump(app, 1.5)

    assert app.busy, "la reprise n'a pas relance le telechargement"
    resumed_from = app.jobs[iid]["bytes"]
    pump(app, 6.0)
    after = app.jobs[iid].get("bytes", 0)
    print(f"repris    : {resumed_from} -> {after} octets")
    if after <= resumed_from:
        problems.append("la reprise n'a pas progresse")

    app._cancel()
    pump(app, 3.0)
    app._on_close()

    if problems:
        for line in problems:
            print("PROBLEME: " + line)
        raise SystemExit(1)
    print("\nPAUSE OK")


if __name__ == "__main__":
    main()