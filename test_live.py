"""Observe le flux reel : analyse + 403 + re-analyse."""

from __future__ import annotations

import sys
import tempfile
import time
from pathlib import Path

from xgrab.app import XGrabApp

URL = "https://pimpbunny.com/videos/virtual-sex-fuck-after-the-first-date/"


def pump(app: XGrabApp, seconds: float) -> None:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        app.update()
        time.sleep(0.02)


def main() -> None:
    app = XGrabApp()
    app.auto_var.set(False)
    app.out_var.set(str(Path(tempfile.gettempdir()) / "xgrab_live"))
    pump(app, 0.5)

    app.url_var.set(URL)
    app._add()

    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        app.update()
        job = next(iter(app.jobs.values()))
        if job.get("variants"):
            break
        time.sleep(0.05)

    iid = next(iter(app.jobs))
    job = app.jobs[iid]
    print(f"extractor  : {job.get('extractor')}")
    print(f"titre      : {job.get('title')}")
    print(f"variantes  : {[v.height_label for v in job.get('variants', [])]}")

    app.tree.selection_set(iid)
    app._on_select()
    app.cmb_variant.current(0)
    pump(app, 0.3)
    app._start()

    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        app.update()
        if app.jobs[iid]["status"] in ("error", "done", "cancelled"):
            break
        time.sleep(0.1)

    print("\n--- JOURNAL ---")
    print(app.log.get("1.0", "end").strip())
    print("---")
    print(f"statut     : {app.jobs[iid]['status']}")
    print(f"retried    : {[k for k, v in app.jobs.items() if v.get('retries')]}")
    print(f"nom vise   : {app.jobs[iid].get('stem')}")
    app._on_close()


if __name__ == "__main__":
    main()
    sys.exit(0)
