"""Test hors interface du téléchargement."""

from __future__ import annotations

import shutil
import sys
import tempfile
import threading
import time
from pathlib import Path

from xgrab.downloader import Downloader, find_ffmpeg
from xgrab.resolver import resolve


def test_http(url: str) -> None:
    info = resolve(url)
    variant = next(v for v in info.variants if v.kind == "http" and v.height and v.height <= 360)
    target = Path(tempfile.mkdtemp(prefix="xgrab_test_"))

    print(f"ffmpeg     : {find_ffmpeg() or 'ABSENT'}")
    print(f"variante   : {variant.describe()}")
    print(f"dossier    : {target}")

    ticks: list[float] = []

    def on_progress(progress) -> None:
        ticks.append(progress.percent)

    downloader = Downloader(target, "test_video", on_progress=on_progress)
    result = downloader.run(variant)

    size = result.path.stat().st_size
    header = result.path.read_bytes()[:12]
    assert result.status == "done", result.status
    assert size > 0
    assert b"ftyp" in header, header
    assert ticks, "aucun callback de progression"
    print(f"résultat   : {result.filename}  {size} octets  {result.duration:.1f}s")
    print(f"progression: {len(ticks)} callbacks, dernier {ticks[-1]:.1f} %")
    print("http       OK")

    resumed = result.path.with_suffix(".mp4.part")
    resumed.write_bytes(result.path.read_bytes()[: size // 2])

    # Les URL signees Pornhub sont a usage unique : reanalyser avant de tester
    # la reprise. On reprend la meme hauteur, sinon le fichier final n'a plus
    # la taille attendue.
    fresh_info = resolve(url)
    fresh = next(
        (v for v in fresh_info.variants if v.kind == "http" and v.height == variant.height),
        None,
    )
    assert fresh, "variante de meme hauteur introuvable apres re-analyse"
    variant.url = fresh.url

    second = Downloader(target, "test_video", on_progress=lambda _p: None).run(variant)
    assert second.status == "done"
    assert second.path.stat().st_size == size, (
        f"reprise incomplète : {second.path.stat().st_size} au lieu de {size}"
    )
    print(f"reprise    : {second.bytes_written} octets  OK")

    shutil.rmtree(target, ignore_errors=True)


def test_cancel(url: str) -> None:
    info = resolve(url)
    # Une qualite mediane : assez gros pour etre annule, assez petit pour que
    # le test ne telecharge pas 300 Mo.
    variant = next(
        v for v in info.variants if v.kind == "http" and v.height and 360 <= v.height <= 720
    )
    target = Path(tempfile.mkdtemp(prefix="xgrab_cancel_"))
    event = threading.Event()

    downloader = Downloader(target, "cancel_test", cancel_event=event)
    threading.Timer(2.5, event.set).start()
    started = time.monotonic()
    result = downloader.run(variant)

    assert result.status == "cancelled", result.status
    assert result.path.exists() and result.path.stat().st_size > 0
    print(f"annulation : {result.status}, {result.bytes_written} octets conservés  OK")
    shutil.rmtree(target, ignore_errors=True)


if __name__ == "__main__":
    test_http(sys.argv[1])
    test_cancel(sys.argv[1])
    print("\nTOUT EST PASSE")
