from __future__ import annotations

import re
import subprocess
import unicodedata
from pathlib import Path

IS_WINDOWS = hasattr(subprocess, "CREATE_NO_WINDOW")
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def hidden_popen_kwargs() -> dict:
    """Empêche l'ouverture d'une fenêtre console pour les sous-processus."""
    return {"creationflags": NO_WINDOW} if IS_WINDOWS else {}

_UNSAFE = re.compile(r'[<>:"/\\|?*\x00-\x1f\x7f]')
_RESERVED = {"CON", "PRN", "AUX", "NUL"}
_RESERVED |= {f"COM{i}" for i in range(1, 10)}
_RESERVED |= {f"LPT{i}" for i in range(1, 10)}


def sanitize_filename(name: str, fallback: str = "video", max_len: int = 120) -> str:
    name = unicodedata.normalize("NFKC", name)
    name = _UNSAFE.sub("_", name).strip()
    name = re.sub(r"\s+", " ", name).rstrip(". ")
    if len(name) > max_len:
        name = name[:max_len].rstrip(". ")
    if not name or name.upper() in _RESERVED:
        name = f"{fallback}_{name}".strip("_ ") or fallback
    return name


def human_size(num: Optional[float]) -> str:
    if not num or num <= 0:
        return "?"
    units = ("o", "Ko", "Mo", "Go", "To")
    value = float(num)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            if unit == "o":
                return f"{int(value)} o"
            return f"{value:.2f} {unit}".replace(".", ",")
        value /= 1024
    return "?"


def human_rate(bps: Optional[float]) -> str:
    if not bps or bps <= 0:
        return "?"
    return f"{human_size(bps)}/s"


def human_time(seconds: Optional[float]) -> str:
    if seconds is None or seconds < 0 or seconds != seconds or seconds == float("inf"):
        return "--:--"
    seconds = int(seconds)
    hours, rem = divmod(seconds, 3600)
    minutes, secs = divmod(rem, 60)
    if hours:
        return f"{hours}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


def unique_path(path: Path) -> Path:
    if not path.exists():
        return path
    stem, suffix = path.stem, path.suffix
    for index in range(1, 10000):
        candidate = path.with_name(f"{stem} ({index}){suffix}")
        if not candidate.exists():
            return candidate
    return path.with_name(f"{stem}-{index}{suffix}")


def parse_template(template: str, values: dict) -> str:
    out = template
    for key, value in values.items():
        out = out.replace("{" + key + "}", str(value))
    return sanitize_filename(out.strip() or "video")


def parse_many_urls(text: str) -> list[str]:
    urls = re.findall(r"https?://[^\s<>\"']+", text)
    seen: set[str] = set()
    ordered: list[str] = []
    for url in urls:
        cleaned = url.rstrip(".,);]")
        if cleaned not in seen:
            seen.add(cleaned)
            ordered.append(cleaned)
    return ordered
