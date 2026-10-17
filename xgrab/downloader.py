from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

import requests

from . import webpage
from .utils import hidden_popen_kwargs
from .variants import Variant

CHUNK = 262144
FFMPEG_TIME_RE = re.compile(r"\btime=(\d+):(\d{2}):(\d{2}(?:\.\d+)?)")
FFMPEG_OUT_TIME_RE = re.compile(r"\bout_time_(ms|us)=(\d+)")

# Types servis par un CDN pour un media. Tout le reste (json, html, manifeste
# PWA, sous-titres) signifie que l'URL obtenue n'est pas la video.
MEDIA_TYPES = ("video/", "audio/", "application/octet-stream", "binary/octet-stream")
MEDIA_SUFFIXES = ("mpegurl", "dash+xml", "mp4", "webm", "matroska", "quicktime")

# Sous cette taille, un "telechargement reussi" est presque toujours une page
# d'erreur ou un fragment de flux segmente.
MIN_PLAUSIBLE_BYTES = 16 * 1024


def _is_media_type(content_type: str) -> bool:
    if content_type.startswith(MEDIA_TYPES):
        return True
    return any(token in content_type for token in MEDIA_SUFFIXES)


def parse_ffmpeg_seconds(line: str) -> Optional[float]:
    match = FFMPEG_TIME_RE.search(line)
    if match:
        hours, minutes, seconds = match.groups()
        return int(hours) * 3600 + int(minutes) * 60 + float(seconds)
    fallback = FFMPEG_OUT_TIME_RE.search(line)
    if fallback:
        value = int(fallback.group(2))
        return value / 1_000_000 if fallback.group(1) == "us" else value / 1000
    return None


def as_number(value) -> float:
    """Convertit en flottant, 0.0 pour tout ce qui n'est pas numerique."""
    if isinstance(value, bool) or value is None:
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value).strip())
    except (TypeError, ValueError):
        return 0.0


class Cancelled(Exception):
    pass


class MissingFfmpeg(Exception):
    pass


class Interrupted(Exception):
    """Le flux s'est coupe en cours de route ; le .part reste reprenable.

    Distinct d'un refus de protection : ici rien n'a bloque le site, la
    connexion a simplement cesse. L'utilisateur doit pouvoir relancer et
    continuer, pas retrouver une traceback.
    """


class MediaRefused(requests.HTTPError):
    """Le serveur a repondu sans corps media : protection anti-robot.

    Distinct de HTTPError, car le code d'etat vaut souvent 200 et ne dit rien
    de l'echec. L'appelant doit pouvoir le traiter comme un blocage et
    escalader (re-analyse, puis capture navigateur) au lieu d'abandonner.
    """


def _app_dirs() -> list[Path]:
    dirs: list[Path] = []
    if getattr(sys, "frozen", False):
        dirs.append(Path(sys.executable).parent)
        dirs.append(getattr(sys, "_MEIPASS", Path(sys.executable).parent))
    dirs.append(Path(__file__).resolve().parent.parent)
    return dirs


def find_ffmpeg() -> Optional[str]:
    exe = shutil.which("ffmpeg") or shutil.which("ffmpeg.exe")
    if exe:
        return exe
    for folder in _app_dirs():
        for name in ("ffmpeg.exe", "ffmpeg"):
            candidate = folder / name
            if candidate.exists():
                return str(candidate)
    try:
        import imageio_ffmpeg
    except ImportError:
        return None
    try:
        return imageio_ffmpeg.get_ffmpeg_exe()
    except (RuntimeError, OSError):
        return None


@dataclass
class Progress:
    downloaded: int
    total: Optional[int]
    speed: float
    eta: Optional[float]
    percent: float
    status: str = "downloading"
    filename: str = ""


@dataclass
class DownloadResult:
    path: Path
    bytes_written: int
    duration: float
    variant: Variant
    status: str = "done"
    error: str = ""
    filename: str = ""


class Downloader:
    def __init__(
        self,
        dest_dir: Path,
        filename_stem: str,
        on_progress: Optional[Callable[[Progress], None]] = None,
        cancel_event: Optional[threading.Event] = None,
    ):
        self.dest_dir = Path(dest_dir)
        self.filename_stem = filename_stem
        self.on_progress = on_progress
        self.cancel_event = cancel_event or threading.Event()
        self._speed_samples: list[tuple[float, int]] = []

    def cancel(self) -> None:
        self.cancel_event.set()

    def _check_cancel(self) -> None:
        if self.cancel_event.is_set():
            raise Cancelled()

    def _emit(
        self,
        downloaded: int,
        total: Optional[int],
        filename: str,
        status: str = "downloading",
        percent: Optional[float] = None,
    ) -> None:
        if self.on_progress is None:
            return

        now = time.monotonic()
        self._speed_samples.append((now, downloaded))
        window = now - 5.0
        self._speed_samples = [s for s in self._speed_samples if s[0] >= window]

        if len(self._speed_samples) >= 2:
            first_t, first_b = self._speed_samples[0]
            elapsed = now - first_t
            speed = (downloaded - first_b) / elapsed if elapsed > 0.05 else 0.0
        else:
            speed = 0.0

        if total:
            remaining = total - downloaded
            eta = remaining / speed if speed > 512 and remaining > 0 else None
            computed = max(0.0, min(100.0, downloaded / total * 100))
        else:
            eta = None
            computed = 0.0

        self.on_progress(
            Progress(
                downloaded=downloaded,
                total=total,
                speed=max(0.0, speed),
                eta=eta,
                percent=percent if percent is not None else computed,
                status=status,
                filename=filename,
            )
        )

    def run(self, variant: Variant) -> DownloadResult:
        if variant.kind == "hls":
            return self._run_hls(variant)
        return self._run_http(variant)

    def _run_hls(self, variant: Variant) -> DownloadResult:
        ffmpeg = find_ffmpeg()
        if not ffmpeg:
            raise MissingFfmpeg(
                "ffmpeg introuvable pour le flux HLS. Installez ffmpeg ou "
                "choisissez une variante MP4."
            )

        self.dest_dir.mkdir(parents=True, exist_ok=True)
        started = time.monotonic()
        part_file = self.dest_dir / f"{self.filename_stem}.mp4.part"
        filename = f"{self.filename_stem}.mp4"

        header_lines = ["User-Agent: " + webpage.USER_AGENT]
        for name in ("Referer", "Origin", "Accept", "Cookie", "Authorization"):
            value = variant.request_headers().get(name)
            if value:
                header_lines.append(f"{name}: {value}")
        header_block = "\r\n".join(header_lines) + "\r\n"

        cmd = [
            ffmpeg, "-y", "-nostdin", "-loglevel", "info",
            "-headers", header_block,
            "-i", variant.url,
            "-c", "copy", "-movflags", "+faststart",
            "-f", "mp4",
            str(part_file),
        ]

        self._speed_samples.clear()
        total_seconds = self._probe_hls_seconds(variant)
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            **hidden_popen_kwargs(),
        )

        downloaded = 0

        def pump() -> None:
            for line in proc.stdout:
                if total_seconds <= 0:
                    continue
                seconds = parse_ffmpeg_seconds(line)
                if seconds is None:
                    continue
                percent = min(100.0, seconds / total_seconds * 100)
                bitrate = as_number(variant.bitrate)
                approximate = int(bitrate / 8 * seconds) if bitrate > 0 else 0
                self._emit(approximate, None, filename, percent=percent)

        pump_thread = threading.Thread(target=pump, daemon=True)
        pump_thread.start()

        last_emit = 0.0
        try:
            while proc.poll() is None:
                if self.cancel_event.is_set():
                    proc.terminate()
                    proc.wait(timeout=10)
                    raise Cancelled()
                if part_file.exists():
                    downloaded = part_file.stat().st_size
                    if total_seconds <= 0 and time.monotonic() - last_emit >= 1.0:
                        last_emit = time.monotonic()
                        self._emit(downloaded, variant.size or None, filename, percent=0.0)
                time.sleep(0.2)
        except Cancelled:
            self._emit(downloaded, None, filename, status="cancelled")
            return DownloadResult(
                path=part_file,
                bytes_written=downloaded,
                duration=time.monotonic() - started,
                variant=variant,
                status="cancelled",
                filename=filename,
            )

        pump_thread.join(timeout=2)

        if proc.returncode != 0 or not part_file.exists():
            raise RuntimeError(f"ffmpeg a échoué (code {proc.returncode})")

        downloaded = part_file.stat().st_size
        target = self.dest_dir / filename
        part_file.replace(target)
        self._emit(downloaded, downloaded, filename, status="done")

        return DownloadResult(
            path=target,
            bytes_written=downloaded,
            duration=time.monotonic() - started,
            variant=variant,
            filename=filename,
        )

    def _probe_hls_seconds(self, variant: Variant) -> float:
        size = as_number(variant.size)
        bitrate = as_number(variant.bitrate)
        if size > 0 and bitrate > 0:
            return size * 8 / bitrate
        return 0.0

    def _run_http(self, variant: Variant) -> DownloadResult:
        self.dest_dir.mkdir(parents=True, exist_ok=True)

        ext = "mp4" if variant.ext in ("mp4", "m4v", "mov") else variant.ext
        filename = f"{self.filename_stem}.{ext}"
        target = self.dest_dir / filename
        part_file = self.dest_dir / f"{filename}.part"

        existing = part_file.stat().st_size if part_file.exists() else 0
        headers = {"User-Agent": webpage.USER_AGENT, **variant.request_headers()}
        if existing:
            headers["Range"] = f"bytes={existing}-"

        started = time.monotonic()
        try:
            response = requests.get(
                variant.url,
                stream=True,
                timeout=(30, 60),
                headers=headers,
                allow_redirects=True,
            )
        except requests.RequestException as exc:
            # Echec de connexion ou de DNS avant meme le debut du flux : ce n'est
            # pas un refus du site, et le .part existant reste reprenable.
            raise Interrupted(
                f"connexion impossible ({exc.__class__.__name__})"
            ) from exc

        if response.status_code == 416 and existing:
            part_file.replace(target)
            return DownloadResult(
                path=target,
                bytes_written=existing,
                duration=time.monotonic() - started,
                variant=variant,
                filename=filename,
            )

        response.raise_for_status()
        resumed = response.status_code == 206

        # Un CDN peut repondre 200 avec une page d'erreur, un JSON de manifeste
        # ou un bout de flux segmente : dans le cas le fichier telecharge n'est
        # pas une video. On refuse plutot que d'annoncer un faux succes.
        # MediaRefused distingue ce cas d'une simple erreur HTTP : le code
        # d'etat peut valoir 200, et c'est la protection du site qui refuse.
        content_type = (response.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if content_type and not _is_media_type(content_type):
            raise MediaRefused(
                f"la reponse n'est pas un media (Content-Type: {content_type})",
                response=response,
            )

        content_length = response.headers.get("Content-Length")
        if content_length and content_length.isdigit():
            total: Optional[int] = int(content_length) + (existing if resumed else 0)
        else:
            total = variant.size if variant.size else None

        mode = "ab" if resumed else "wb"
        downloaded = existing if resumed else 0

        if not resumed and existing and part_file.exists():
            part_file.unlink()

        self._emit(downloaded, total, filename, status="starting")

        try:
            with open(part_file, mode) as handle:
                for chunk in response.iter_content(chunk_size=CHUNK):
                    self._check_cancel()
                    if not chunk:
                        continue
                    handle.write(chunk)
                    downloaded += len(chunk)
                    self._emit(downloaded, total, filename)
                handle.flush()
                os.fsync(handle.fileno())
        except Cancelled:
            self._emit(downloaded, total, filename, status="cancelled")
            return DownloadResult(
                path=part_file,
                bytes_written=downloaded,
                duration=time.monotonic() - started,
                variant=variant,
                status="cancelled",
                filename=filename,
            )
        except requests.RequestException as exc:
            # Connexion coupee en plein flux (le CDN ferme, le reseau tombe).
            # Ce n'est ni un blocage ni une annulation : le .part reste valable
            # et le telechargement peut reprendre exactement au bon octet.
            self._emit(downloaded, total, filename, status="interrupted")
            raise Interrupted(
                f"connexion interrompue apres {downloaded} octets ({exc.__class__.__name__})"
            ) from exc
        finally:
            response.close()

        self._check_cancel()

        # Un fichier de quelques kilo-octets n'est pas une video : c'est une
        # page d'erreur ou un segment. On le signale au lieu de renommer.
        if downloaded < MIN_PLAUSIBLE_BYTES:
            part_file.unlink(missing_ok=True)
            raise MediaRefused(
                f"reponse trop courte pour etre une video ({downloaded} octets)",
                response=response,
            )

        part_file.replace(target)
        self._emit(downloaded, total, filename, status="done")

        return DownloadResult(
            path=target,
            bytes_written=downloaded,
            duration=time.monotonic() - started,
            variant=variant,
            filename=filename,
        )
