"""Test de fumee : barre de lien, bouton STOP, suppression de fichier."""

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


def main() -> None:
    out = Path(tempfile.gettempdir()) / "xgrab_ui2_test"
    out.mkdir(parents=True, exist_ok=True)

    app = XGrabApp()
    app.auto_var.set(False)
    app.out_var.set(str(out))
    pump(app, 0.6)

    assert app.ent_url.winfo_exists(), "barre de lien absente"
    print("barre de lien      : presente")

    app.url_var.set(URL)
    app._add()
    pump(app, 1.0)
    assert app.url_var.get() == "", "la barre ne s'est pas videe"
    print("barre vide apres   : oui")

    iid = next(iter(app.jobs))

    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        app.update()
        job = app.jobs[iid]
        if job["status"] == "error" or job.get("variants"):
            break
        time.sleep(0.05)

    assert app.jobs[iid]["status"] == "pending", app.jobs[iid]["status"]
    print(f"analyse            : {len(app.jobs[iid]['variants'])} variantes")

    app.tree.selection_set(iid)
    app._on_select()
    pump(app, 0.3)
    assert str(app.btn_stop["state"]) == "disabled", "STOP actif hors download"
    assert str(app.btn_del["state"]) == "disabled", "Supprimer actif sans fichier"
    print("etats au repos     : STOP off, Supprimer off")

    # Qualite mediane : la plus petite peut finir avant la premiere mesure.
    app.cmb_variant.current(min(2, len(app.jobs[iid]["variants"]) - 1))
    app._start()
    pump(app, 5.0)

    if app.jobs[iid]["status"] == "error":
        print("JOURNAL:")
        print(app.log.get("1.0", "end"))
        raise AssertionError("telechargement en erreur")

    assert app.jobs[iid]["status"] == "working", app.jobs[iid]["status"]
    assert str(app.btn_stop["state"]) == "normal", "STOP inactif pendant le download"
    assert app.bar["value"] > 0, "pas de progression"
    part = app._partial_path(app.jobs[iid])
    assert part and part.exists(), "fichier .part absent"
    print(f"STOP pendant       : actif, {app.bar['value']:.0f} %, .part {part.stat().st_size} o")

    app._cancel()
    pump(app, 4.0)

    assert app.jobs[iid]["status"] == "cancelled", app.jobs[iid]["status"]
    assert str(app.btn_stop["state"]) == "disabled", "STOP toujours actif apres arret"
    assert str(app.btn_del["state"]) == "normal", "Supprimer inactif apres arret"
    print(f"arret              : {app.jobs[iid]['status']}, STOP off, Supprimer on")

    part = app._partial_path(app.jobs[iid])
    size_before = part.stat().st_size
    assert size_before > 0

    app._delete_file.__wrapped__ if False else None
    import xgrab.app as appmod

    original = appmod.messagebox.askyesno
    appmod.messagebox.askyesno = lambda *a, **k: True
    app._delete_file()
    pump(app, 0.3)
    appmod.messagebox.askyesno = original

    assert not part.exists(), "le .part n'a pas ete supprime"
    assert str(app.btn_del["state"]) == "disabled", "Supprimer toujours actif"
    print(f"suppression        : {size_before} o effaces, bouton remis off")

    app.tree.selection_set(iid)
    app._on_select()
    assert str(app.btn_rm["state"]) == "normal"
    app._remove_selected()
    pump(app, 0.2)
    assert not app.jobs, "la file n'est pas videe"
    print("retrait de la file : ok")

    app._on_close()
    print("\nUI2 OK")


if __name__ == "__main__":
    main()
