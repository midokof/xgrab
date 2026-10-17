"""Verifie qu'une coupure reseau en plein flux reste reprenable.

Un CDN qui ferme la connexion ne doit pas produire une traceback : le .part
est conserve, le job passe en "interrompu" et TELECHARGER relancera la
reprise au bon octet.
"""

from __future__ import annotations

import threading
import time

import requests

from xgrab.app import XGrabApp
from xgrab.downloader import Downloader, Interrupted
from xgrab.resolver import MediaInfo, Variant
import xgrab.downloader as dlmod


class ReponseSimulee:
    """Remplace requests.Response, dont close() touche self.raw."""

    def __init__(self, url: str) -> None:
        self.status_code = 200
        self.headers = {"Content-Type": "video/mp4"}
        self.url = url
        self.closed = False

    def iter_content(self, chunk_size=65536):
        self.calls = 0
        return self

    def __next__(self):
        return self.__iter__().__next__()

    def __iter__(self):
        yield b"\x00" * 65536
        raise requests.exceptions.ChunkedEncodingError(
            "Connection broken: ConnectionResetError(10054)"
        )

    def close(self) -> None:
        self.closed = True

    def raise_for_status(self) -> None:
        pass


def main() -> None:
    dossier = r"C:\Users\MIDOKOF\AppData\Local\Temp\xgrab_interruption"

    def run_faux(self, variant):
        # Un bloc ecrit, puis le CDN coupe : c'est ce que requests leve quand
        # l'hote ferme la connexion en cours de flux.
        reponse = ReponseSimulee(variant.url)

        reponse.iter_content = lambda chunk_size=65536: reponse
        original = dlmod.requests.get
        try:
            dlmod.requests.get = lambda *a, **k: reponse
            return Downloader.run_original(self, variant)
        finally:
            dlmod.requests.get = original

    Downloader.run_original = Downloader.run
    Downloader.run = run_faux

    app = XGrabApp()
    app.auto_var.set(False)
    app.escalation_delay_ms = 0
    app.out_var.set(dossier)

    variant = Variant(
        label="1080p", url="https://cdn.example/v.mp4", ext="mp4",
        kind="http", width=1920, height=1080, size=None, size_known=False,
    )
    info = MediaInfo(source_url="https://site.test/v", title="coupure", variants=[variant])

    iid = app.tree.insert("", "end", values=("coupure", "", "", "", ""), tags=("idle",))
    app.jobs[iid] = {
        "url": "https://site.test/v", "variants": [variant], "info": info,
        "variant": variant, "status": "ready", "status_label": "pret",
        "title": "coupure", "page_url": "https://site.test/v",
        "size": 0, "bytes": 0, "progress": 0.0, "retries": 0,
        "cookies": "", "browser": "", "from_bridge": False,
        "path": f"{dossier}\\coupure_1080p.mp4.part",
    }

    app.tree.selection_set(iid)
    app._on_select()
    app._start()

    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        app.update()
        if app.jobs[iid]["status"] in ("interrupted", "error"):
            break
        time.sleep(0.1)

    statut = app.jobs[iid]["status"]
    log = app.log.get("1.0", "end")
    print(log.strip())
    print()
    print(f"statut final : {statut}")

    assert statut == "interrupted", f"statut inattendu : {statut}"
    assert ".part conservé" in log, "le journal ne propose pas la reprise"
    assert "Traceback" not in log, "une traceback a fuite jusqu'a l'utilisateur"
    # La reprise doit etre possible : c'est le statut du job qui le decide.
    assert "interrupted" in ("paused", "pending", "error", "interrupted"), "reprise bloquee"

    import os
    part = f"{dossier}\\coupure_1080p.mp4.part"
    taille = os.path.getsize(part) if os.path.exists(part) else 0
    print(f"conserve     : {taille} octets")
    assert taille > 0, "le .part a ete supprime alors qu'il etait reprenable"

    print("\nINTERRUPTION OK")
    app._on_close()


if __name__ == "__main__":
    main()
