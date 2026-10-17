"""Verifie la re-analyse automatique sur HTTP 403/401."""

from __future__ import annotations

import tempfile
import time
from pathlib import Path

import requests

import xgrab.app as appmod
from xgrab.app import XGrabApp
from xgrab.resolver import MediaInfo, Variant
from xgrab.variants import Variant as V


def pump(app: XGrabApp, seconds: float) -> None:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        app.update()
        time.sleep(0.02)


def main() -> None:
    app = XGrabApp()
    app.auto_var.set(False)
    # Ce test valide l'enchainement des paliers, pas la temporisation :
    # la pause anti-martelement est desactivee ici.
    app.escalation_delay_ms = 0
    app.out_var.set(str(Path(tempfile.gettempdir()) / "xgrab_retry_test"))

    app.tree.insert("", "end", iid="j1", values=("t", "", "", "", "prêt"))
    app.jobs["j1"] = {
        "url": "https://ex.test/v",
        "status": "pending",
        "variants": [],
        "progress": 0.0,
        "auto": False,
        "cookies": "",
        "browser": "",
        "title": "t",
        "author": "a",
        "tweet_id": "1",
        "duration": "1:00",
        "extractor": "page",
        "status_label": "prêt",
        "stem": "retry_test",
        "path": str(Path(app.out_var.get()) / "retry_test.mp4.part"),
    }
    app.current = "j1"

    calls = {"n": 0}

    class Boom(Exception):
        pass

    def fake_resolve(url, with_sizes=True, cookies="", cookies_from_browser=""):
        calls["n"] += 1
        variant = V(label="720p", url="https://ex.test/fresh.mp4", height=720)
        return MediaInfo(
            source_url=url,
            title="t",
            author="a",
            tweet_id="1",
            duration=60.0,
            variants=[variant],
            extractor="page",
        )

    appmod.resolve = fake_resolve

    def fake_run(self, variant):
        calls["n"] += 100
        response = requests.Response()
        response.status_code = 403
        response.url = variant.url
        raise requests.HTTPError("403 Client Error", response=response)

    appmod.Downloader.run = fake_run

    # Palier 2 : on note l'appel sans ouvrir un vrai navigateur.
    captured: list[str] = []

    def fake_capture(url: str, iid: str) -> None:
        captured.append(url)

    app._capture_worker = fake_capture  # type: ignore[method-assign]

    app._launch("j1", V("720p", "https://ex.test/old.mp4"), Path(app.out_var.get()), "retry_test")

    # On attend l'etat, pas une duree fixe : le nombre de paliers peut
    # evoluer sans que ce test devienne faux.
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        app.update()
        if calls["n"] // 100 >= 2 and captured:
            break
        time.sleep(0.02)
    pump(app, 0.5)

    log = app.log.get("1.0", "end")
    print(log.strip())
    print(f"\nresolutions : {calls['n'] % 100}")
    print(f"tentatives  : {calls['n'] // 100}")
    print(f"capture     : {len(captured)}")

    problems = []
    if "nouvelle analyse" not in log:
        problems.append("le journal ne mentionne pas la re-analyse")
    if calls["n"] % 100 < 1:
        problems.append("aucune re-analyse du lien")
    if calls["n"] // 100 < 2:
        problems.append(f"2 tentatives attendues, {calls['n'] // 100} effectuees")
    if not captured:
        problems.append("la capture navigateur n'a pas ete atteinte")
    if "HTTP 403" not in log:
        problems.append("le journal ne signale pas le blocage")

    if problems:
        for line in problems:
            print("PROBLEME: " + line)
        raise SystemExit(1)

    print("\nRETRY OK")
    app._on_close()


if __name__ == "__main__":
    main()
