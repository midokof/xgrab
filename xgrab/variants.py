from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

from .utils import human_size


@dataclass
class Variant:
    label: str
    url: str
    ext: str = "mp4"
    kind: str = "http"
    width: int = 0
    height: int = 0
    bitrate: int = 0
    size: Optional[int] = None
    size_known: bool = False
    headers: dict = field(default_factory=dict)
    cookies: str = ""
    referer: str = ""
    origin: str = ""

    def request_headers(self) -> dict:
        merged = dict(self.headers)
        merged.pop("host", None)
        merged.pop("content-length", None)
        merged.pop(":authority", None)
        merged.pop(":method", None)
        merged.pop(":path", None)
        merged.pop(":scheme", None)
        if self.referer and "Referer" not in merged:
            merged["Referer"] = self.referer
        if self.origin and "Origin" not in merged:
            merged["Origin"] = self.origin
        if self.cookies and "Cookie" not in merged:
            merged["Cookie"] = self.cookies
        return merged

    @property
    def height_label(self) -> str:
        return f"{self.height}p" if self.height else self.label

    @property
    def container(self) -> str:
        return "HLS" if self.kind == "hls" else "MP4"

    def describe(self) -> str:
        parts = [f"{self.height_label} {self.container}"]
        if self.size_known and self.size:
            parts.append(human_size(self.size))
        else:
            parts.append("taille inconnue")
        bitrate = self.bitrate if isinstance(self.bitrate, (int, float)) else 0
        if bitrate > 0:
            parts.append(f"{bitrate / 1_000_000:.1f} Mb/s".replace(".", ","))
        return "  -  ".join(parts)
