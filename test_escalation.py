"""Verifie l'escalade sur un vrai blocage : 200 + page de protection.

Avant le correctif, is_blocked(200) renvoyait False : l'echec etait terminal
des la premiere tentative. Ce test impose le palier 0 (re-analyse), puis 1
(capture navigateur), puis abandon.
"""

from __future__ import annotations

import sys
import tempfile
import time
from pathlib import Path

from xgrab.app import XGrabApp
from xgrab.downloader import MediaRefused
from xgrab.resolver import MediaInfo, Variant

URL = (
    "https://pimpbunny.com/videos/my-stepsister-wants-to-play-cs-right-now"
    "-and-is-offering-sex-in-exchange-for-me-letting-her-play/"
)


class FakeResponse:
    def __init__(self, status: int = 200) -> None:
        self.status_code = status
        self.headers = {"Content-Type": "text/html; charset=utf-8"}
        self.url = "https://cdn.example/video.mp4"

    def close(self) -> None:
        pass


def main(url: str) -> None:
    calls = {"n": 0}

    def refuse(*_args, **_kwargs):
        calls["n"] += 1
        # Un CDN protege repond 200 avec une page HTML : c'est ce cas-la qui
        # doit declencher la montee en puissance, pas un 403.
        raise MediaRefused(
            "la reponse n'est pas un media (Content-Type: text/html)",
            response=FakeResponse(200),
        )

    import xgrab.app as app_mod
    import xgrab.downloader as dl

    dl.Downloader.run = refuse

    variant = Variant(
        label="2160p",
        url="https://cdn.example/video.mp4",
        ext="mp4",
        kind="http",
        width=3840,
        height=2160,
        size=None,
        size_known=False,
    )
    info = MediaInfo(source_url=url, title="blocage", variants=[variant])
    app_mod.resolve = lambda *a, **k: info

    app = XGrabApp()
    app.auto_var.set(False)
    app.out_var.set(str(Path(tempfile.mkdtemp(prefix="xgrab_escalade_"))))

    iid = app.tree.insert("", "end", values=("blocage", "", "", "", ""), tags=("idle",))
    app.jobs[iid] = {
        "url": url,
        "variants": [variant],
        "info": info,
        "variant": variant,
        "status": "ready",
        "status_label": "pret",
        "title": "blocage",
        "page_url": url,
        "size": 0,
        "bytes": 0,
        "progress": 0.0,
        "retries": 0,
        "cookies": "",
        "browser": "",
        "from_bridge": False,
    }

    app.tree.selection_set(iid)
    app._on_select()
    app._start()

    stages: list[str] = []
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        app.update()
        text = app.log.get("1.0", "end")
        for marker in ("nouvelle analyse", "capture automatique", "meme apres"):
            if marker in text and marker not in stages:
                stages.append(marker)
        if app.jobs[iid]["status"] == "error" and len(stages) >= 2:
            break
        time.sleep(0.15)

    print(f"tentatives de telechargement : {calls['n']}")
    print(f"paliers declenches           : {stages}")

    assert calls["n"] >= 2, "l'escalade n'a pas relance le telechargement"
    assert "nouvelle analyse" in stages, "palier 1 (re-analyse) manquant"
    assert "capture automatique" in stages, "palier 2 (capture) manquant"

    print()
    print(app.log.get("1.0", "end").strip())
    print("\nESCALADE OK")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else URL)
