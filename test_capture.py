"""Capture navigateur puis telechargement reel (methode IDM, de bout en bout).

On utilise une adresse MP4 directe et stable : elle ne depend ni d'un lecteur
ni d'un garde anti-robot, donc le test valide vraiment le mecanisme de capture
CDP (type MIME confirme, en-tetes interceptes) et non la page du site.
"""

from __future__ import annotations

import shutil
import sys
import tempfile
import threading
import time
from pathlib import Path
from urllib.parse import urlparse

from xgrab.capture import capture
from xgrab.downloader import Downloader
from xgrab.utils import human_size

STABLE = "https://download.samplelib.com/mp4/sample-5s.mp4"


def main(url: str, limit: int = 8_000_000) -> None:
    variants = capture(url, on_log=lambda m: print("   ", m), headless=True, seconds=25)
    print()

    real = [
        v
        for v in variants
        if any(part in urlparse(v.url).path.lower() for part in (".mp4", ".m3u8", ".webm"))
    ]
    if not real:
        raise SystemExit("aucune requete video reelle capturee")

    print(f"capturees : {[v.height_label for v in real]}")
    target = max(real, key=lambda v: v.height)
    print(f"cible     : {target.url[:92]}")
    print(f"cookie    : {len(target.cookies)} car., {len(target.headers)} en-tetes")

    # Les en-tetes sont ce qui permet au CDN de reaffirmed la requete ; le
    # cookie n'est present que sur les sites qui en posent.
    assert target.headers, "aucun en-tete intercepte"
    assert "Sec-Fetch-Mode" in target.headers or "Referer" in target.headers, (
        f"en-tetes inattendus : {sorted(target.headers)[:8]}"
    )

    folder = Path(tempfile.mkdtemp(prefix="xgrab_capture_"))
    done = threading.Event()

    def on_progress(progress) -> None:
        if progress.downloaded >= limit and not done.is_set():
            done.set()
            downloader.cancel()

    downloader = Downloader(folder, "capture_test", on_progress=on_progress)
    started = time.monotonic()
    result = downloader.run(target)
    elapsed = time.monotonic() - started

    print(f"\nstatut    : {result.status}")
    print(f"ecrit     : {human_size(result.bytes_written)} en {elapsed:.1f}s")

    if result.status == "done":
        head = result.path.read_bytes()[:12]
        assert b"ftyp" in head, head
        print(f"entete    : {head[:11]}")
    else:
        part = folder / "capture_test.mp4.part"
        assert part.exists() and part.stat().st_size > 0, "aucune donnee recue"
        print(f"partiel   : {human_size(part.stat().st_size)} conserve pour reprise")

    shutil.rmtree(folder, ignore_errors=True)
    print("\nCAPTURE DOWNLOAD OK")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else STABLE)
