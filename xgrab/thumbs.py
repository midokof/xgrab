"""Miniatures : telecharge l'image de couverture et la convertit en PNG."""

from __future__ import annotations

import hashlib
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Optional

import requests

from .downloader import find_ffmpeg
from .utils import hidden_popen_kwargs
from .webpage import USER_AGENT

CACHE_DIR = Path(tempfile.gettempdir()) / "xgrab-thumbs"
MAX_AGE_SECONDS = 6 * 3600

_LOCK_LOCK = __import__("threading").Lock()


def cache_path(url: str, width: int, height: int) -> Path:
    digest = hashlib.sha1(f"{url}|{width}x{height}".encode()).hexdigest()[:16]
    return CACHE_DIR / f"{digest}.png"


def is_fresh(path: Path) -> bool:
    if not path.exists():
        return False
    import time

    return (time.time() - path.stat().st_mtime) < MAX_AGE_SECONDS


def load_thumbnail(
    url: str,
    width: int = 280,
    height: int = 158,
    referer: str = "",
    timeout: int = 25,
) -> Optional[Path]:
    """Retourne un PNG local, ou None si la miniature est indisponible."""
    if not url or not url.startswith("http"):
        return None

    target = cache_path(url, width, height)
    with _LOCK_LOCK:
        if is_fresh(target):
            return target

        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        raw = CACHE_DIR / f"{target.stem}.raw"
        try:
            headers = {"User-Agent": USER_AGENT}
            if referer:
                headers["Referer"] = referer
            response = requests.get(url, headers=headers, timeout=timeout, stream=True)
            response.raise_for_status()
            with open(raw, "wb") as handle:
                for chunk in response.iter_content(65536):
                    handle.write(chunk)
            response.close()

            if raw.stat().st_size == 0:
                raw.unlink(missing_ok=True)
                return None

            if _convert(raw, target, width, height):
                return target

            shutil.copyfile(raw, target)
            raw.unlink(missing_ok=True)
            return target
        except (requests.RequestException, OSError):
            raw.unlink(missing_ok=True)
            return None


def _convert(source: Path, target: Path, width: int, height: int) -> bool:
    """Convertit n'importe quel format en PNG echelle via ffmpeg."""
    ffmpeg = find_ffmpeg()
    if not ffmpeg:
        return False

    cmd = [
        ffmpeg, "-y", "-nostdin", "-loglevel", "error",
        "-i", str(source),
        "-vf", f"scale={width}:{height}:force_original_aspect_ratio=decrease,pad={width}:{height}:-1:-1:color=white",
        "-frames:v", "1",
        "-f", "image2",
        str(target),
    ]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            timeout=30,
            **hidden_popen_kwargs(),
        )
    except (OSError, subprocess.TimeoutExpired):
        return False

    if proc.returncode != 0 or not target.exists() or target.stat().st_size == 0:
        target.unlink(missing_ok=True)
        return False
    return True


def load_frame(video: Path, seconds: float, width: int = 280, height: int = 158) -> Optional[Path]:
    """Extrait une image du fichier video local (miniature de progression)."""
    if not video.exists() or video.stat().st_size == 0:
        return None

    ffmpeg = find_ffmpeg()
    if not ffmpeg:
        return None

    target = CACHE_DIR / f"frame_{video.name}_{int(seconds)}.png"
    if is_fresh(target):
        return target
    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    cmd = [
        ffmpeg, "-y", "-nostdin", "-loglevel", "error",
        "-ss", f"{seconds:.1f}", "-i", str(video),
        "-frames:v", "1",
        "-vf", f"scale={width}:{height}:force_original_aspect_ratio=decrease,pad={width}:{height}:-1:-1:color=white",
        "-f", "image2",
        str(target),
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=30, **hidden_popen_kwargs())
    except (OSError, subprocess.TimeoutExpired):
        target.unlink(missing_ok=True)
        return None

    if proc.returncode != 0 or not target.exists() or target.stat().st_size == 0:
        target.unlink(missing_ok=True)
        return None
    return target


def clear_cache() -> None:
    shutil.rmtree(CACHE_DIR, ignore_errors=True)