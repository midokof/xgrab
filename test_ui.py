"""Test de fumee de l'interface, sans interaction humaine."""

from __future__ import annotations

import sys
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


def main() -> None:
    app = XGrabApp()
    app.auto_var.set(False)
    app.out_var.set(str(Path(tempfile.gettempdir()) / "xgrab_ui_test"))
    pump(app, 0.6)

    app.url_var.set("")
    app.txt_links.insert("1.0", URL)
    app._add()
    pump(app, 1.0)

    iid = next(iter(app.jobs), None)
    assert iid, "aucun élément ajouté à la file"
    assert len(app.jobs) == 1, f"un seul lien attendu, {len(app.jobs)} trouvés"
    pump(app, 0.4)

    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        app.update()
        job = app.jobs[iid]
        if job["status"] == "error" or job.get("variants"):
            break
        time.sleep(0.05)

    job = app.jobs[iid]
    if job["status"] != "pending":
        print("JOURNAL:")
        print(app.log.get("1.0", "end"))
    print("JOURNAL:", app.log.get("1.0", "end").strip()[-600:])
    print("retry  :", [k for k, v in app.jobs.items() if v.get("retries")])
    assert job["status"] == "pending", f"statut inattendu : {job['status']}"
    assert len(job["variants"]) >= 4, f"variantes : {len(job['variants'])}"

    app.tree.selection_set(iid)
    app._on_select()
    pump(app, 0.3)

    labels = list(app.cmb_variant["values"])
    assert labels, "liste de résolutions vide"
    assert app.tree.selection() == (iid,), "la ligne analysée n'est pas sélectionnée automatiquement"

    app.cmb_variant.current(2)
    app._update_preview()
    pump(app, 0.2)
    preview = app.lbl_prog.cget("text")

    app.bar["value"] = 42
    app.lbl_prog.configure(text="42.0 %   test")

    from xgrab.downloader import Progress

    app._on_progress(
        iid,
        Progress(downloaded=500, total=1000, speed=1024, eta=0.5, percent=50.0, status="downloading"),
    )
    pump(app, 0.2)

    geometry = app.winfo_geometry()
    height = int(geometry.split("x")[1].split("+")[0])
    assert height >= 620, f"fenêtre trop petite : {height}"

    print(f"variantes  : {len(job['variants'])}")
    print(f"extracteur : {job['extractor']}")
    print(f"durée      : {job['duration']}")
    for label in labels:
        print(f"   menu    : {label}")
    print(f"aperçu     : {preview[:110]}")
    print(f"fenêtre    : {geometry}")
    print(f"barre      : {app.bar['value']}")
    print(f"ligne file : {app.tree.item(iid, 'values')[4]}")
    print(f"journal    : {len(app.log.get('1.0', 'end').strip().splitlines())} lignes")

    app._on_close()
    print("\nUI OK")


if __name__ == "__main__":
    main()
    sys.exit(0)
