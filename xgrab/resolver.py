from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Optional
from urllib.parse import urljoin

import requests

from . import webpage
from .utils import hidden_popen_kwargs, human_size, human_time
from .variants import Variant


@dataclass
class MediaInfo:
    source_url: str
    title: str
    author: str = ""
    tweet_id: str = ""
    duration: Optional[float] = None
    thumbnail: str = ""
    variants: list[Variant] = field(default_factory=list)
    extractor: str = ""
    page_title: str = ""
    login_required: bool = False

    @property
    def duration_label(self) -> str:
        return human_time(self.duration) if self.duration else "durée inconnue"

STATUS_RE = re.compile(r"/status(?:es)?/(\d+)", re.IGNORECASE)
USER_RE = re.compile(r"(?:x|twitter)\.com/([^/]+)/status", re.IGNORECASE)
DIMS_RE = re.compile(r"/(\d{2,5})x(\d{2,5})/")
SUPPORTED_HOSTS = ("x.com", "twitter.com", "t.co")


class ResolutionError(Exception):
    pass


def _app_dirs() -> list[Path]:
    dirs: list[Path] = []
    frozen = getattr(sys, "frozen", False)
    if frozen:
        dirs.append(Path(sys.executable).parent)
        dirs.append(getattr(sys, "_MEIPASS", Path(sys.executable).parent))
    dirs.append(Path(__file__).resolve().parent.parent)
    return dirs


def find_ytdlp() -> list[str]:
    exe = shutil.which("yt-dlp") or shutil.which("yt-dlp.exe")
    if exe:
        return [exe]
    for folder in _app_dirs():
        for name in ("yt-dlp.exe", "yt-dlp"):
            candidate = folder / name
            if candidate.exists():
                return [str(candidate)]
    return [sys.executable, "-m", "yt_dlp"]


def _ytdlp_probe(url: str, cookies_from_browser: str = "", timeout: int = 45) -> dict:
    cmd = find_ytdlp() + [
        "-J",
        "--no-playlist",
        "--no-warnings",
        "--skip-download",
        "--socket-timeout",
        "15",
        "--retries",
        "1",
    ]
    if cookies_from_browser:
        cmd += ["--cookies-from-browser", cookies_from_browser]
    cmd.append(url)
    proc = subprocess.run(
        cmd,
        capture_output=True,
        timeout=timeout,
        encoding="utf-8",
        errors="replace",
        **hidden_popen_kwargs(),
    )
    if proc.returncode != 0:
        message = (proc.stderr or proc.stdout or "").strip().splitlines()
        raise ResolutionError(message[-1] if message else "yt-dlp a échoué")
    return json.loads(proc.stdout or "{}")


def _variants_from_ytdlp(data: dict) -> list[Variant]:
    raw = data.get("formats") or []
    seen: dict[tuple, Variant] = {}

    for item in raw:
        url = item.get("url")
        if not url or not url.startswith("http"):
            continue
        if item.get("vcodec") == "none":
            continue
        protocol = item.get("protocol", "https")
        kind = "hls" if protocol in ("m3u8", "m3u8_native") else "http"
        if kind == "hls" and item.get("acodec") == "none":
            continue

        height = int(item.get("height") or 0)
        width = int(item.get("width") or 0)
        bitrate = int(item.get("tbr") or item.get("vbr") or 0)
        filesize = item.get("filesize") or item.get("filesize_approx")
        ext = item.get("ext") or ("mp4" if kind == "http" else "ts")

        if not height and not bitrate:
            continue

        key = (height, kind)
        existing = seen.get(key)
        if existing and existing.bitrate >= bitrate:
            continue

        headers = item.get("http_headers") or {}
        cookie_blob = str(item.get("cookies") or "")
        cookie_header = cookie_blob.split(";")[0].strip() if cookie_blob else ""

        seen[key] = Variant(
            label=f"{height}p" if height else f"{bitrate // 1000}kbps",
            url=url,
            ext=ext,
            kind=kind,
            width=width,
            height=height,
            bitrate=bitrate,
            size=int(filesize) if filesize else None,
            size_known=bool(filesize),
            headers={k: str(v) for k, v in headers.items()},
            cookies=cookie_header,
            referer=str(headers.get("Referer", "")),
            origin=str(headers.get("Origin", "")),
        )

    return sorted(seen.values(), key=_variant_sort_key, reverse=True)


def _fxtwitter_probe(tweet_id: str, timeout: int = 40) -> dict:
    response = requests.get(
        f"https://api.fxtwitter.com/status/{tweet_id}",
        timeout=timeout,
        headers={"User-Agent": "Mozilla/5.0"},
    )
    if response.status_code != 200:
        raise ResolutionError(f"API fxtwitter a renvoyé {response.status_code}")
    return response.json()


def _dims_from_url(url: str) -> tuple[int, int]:
    match = DIMS_RE.search(url)
    if not match:
        return 0, 0
    return int(match.group(1)), int(match.group(2))


def _hls_master(url: str, timeout: int = 20) -> list[dict]:
    response = requests.get(url, timeout=timeout, headers={"User-Agent": "Mozilla/5.0"})
    response.raise_for_status()

    children: list[dict] = []
    pending: dict | None = None

    for raw in response.text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#EXT-X-STREAM-INF:"):
            attrs = dict(re.findall(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)', line))
            pending = attrs
            continue
        if line.startswith("#") or pending is None:
            continue

        resolution = pending.get("RESOLUTION", "").strip('"')
        bandwidth = pending.get("AVERAGE-BANDWIDTH") or pending.get("BANDWIDTH") or "0"
        dims = re.match(r"(\d+)x(\d+)", resolution)
        children.append(
            {
                "url": urljoin(url, line),
                "width": int(dims.group(1)) if dims else 0,
                "height": int(dims.group(2)) if dims else 0,
                "bandwidth": int(bandwidth) if bandwidth.isdigit() else 0,
            }
        )
        pending = None

    return children


def _expand_hls(url: str, duration: float, timeout: int = 20) -> list[Variant]:
    try:
        children = _hls_master(url, timeout)
    except (requests.RequestException, ValueError):
        children = []

    variants = [
        Variant(
            label=f"{child['height']}p" if child["height"] else "source",
            url=child["url"],
            ext="mp4",
            kind="hls",
            width=child["width"],
            height=child["height"],
            bitrate=child["bandwidth"],
            size=int(child["bandwidth"] / 8 * duration) if child["bandwidth"] and duration else None,
            size_known=bool(child["bandwidth"] and duration),
        )
        for child in children
    ]

    if variants:
        return variants

    return [
        Variant(
            label="source",
            url=url,
            ext="mp4",
            kind="hls",
            bitrate=0,
        )
    ]


def _variant_sort_key(variant: Variant) -> tuple:
    bitrate = variant.bitrate if isinstance(variant.bitrate, (int, float)) else 0
    return (variant.height, 1 if bitrate > 0 else 0, 1 if variant.kind == "http" else 0, bitrate)


def _variants_from_tweet(payload: dict) -> tuple[list[Variant], dict]:
    tweet = payload.get("tweet") or {}
    media = ((tweet.get("media") or {}).get("all")) or []
    variants: list[Variant] = []
    meta: dict = {
        "title": "",
        "author": (tweet.get("author") or {}).get("screen_name", ""),
        "duration": None,
        "thumbnail": "",
    }

    for item in media:
        if item.get("type") not in ("video", "animated_gif"):
            continue

        if not meta["duration"] and item.get("duration"):
            meta["duration"] = float(item["duration"])
        if not meta["thumbnail"]:
            meta["thumbnail"] = item.get("thumbnail_url") or ""

        seen: dict[tuple, Variant] = {}
        for fmt in item.get("formats") or []:
            url = fmt.get("url")
            if not url:
                continue

            if str(fmt.get("container", "")).endswith("m3u8"):
                for child in _expand_hls(url, float(item.get("duration") or 0)):
                    key = (child.width, child.height, "hls")
                    if key not in seen:
                        seen[key] = child
                continue

            width, height = _dims_from_url(url)
            if not height:
                width = int(item.get("width") or 0)
                height = int(item.get("height") or 0)

            key = (width, height, "http")
            if key in seen:
                continue

            seen[key] = Variant(
                label=f"{height}p" if height else "source",
                url=url,
                ext="mp4",
                kind="http",
                width=width,
                height=height,
                bitrate=int(fmt.get("bitrate") or 0),
            )

        variants.extend(sorted(seen.values(), key=_variant_sort_key, reverse=True))

    meta["title"] = f"post-{tweet.get('id', '')}"
    return variants, meta


SLUG_RE = re.compile(r"[^a-z0-9]+")
COMBINING_RE = re.compile(r"[\u0300-\u036f\u1ab0-\u1aff\u1dc0-\u1dff\u20d0-\u20ff\ufe20-\ufe2f]")


def _slug(text: str, limit: int = 60) -> str:
    decomposed = unicodedata.normalize("NFKD", text)
    stripped = COMBINING_RE.sub("", decomposed)
    plain = stripped.encode("ascii", "ignore").decode("ascii")
    cleaned = SLUG_RE.sub("_", plain.lower()).strip("_")
    return cleaned[:limit].rstrip("_") or "video"


CONTENT_RANGE_RE = re.compile(r"bytes\s+\d+-\d+/(\d+)", re.IGNORECASE)


def probe_size(variant: Variant, timeout: int = 20) -> Variant:
    if variant.kind == "hls":
        return variant
    if variant.size_known and variant.size:
        return variant

    headers = {"User-Agent": webpage.USER_AGENT, **variant.request_headers()}

    try:
        response = requests.head(
            variant.url, allow_redirects=True, timeout=timeout, headers=headers
        )
        length = response.headers.get("Content-Length")
        if length and length.isdigit() and int(length) > 0:
            variant.size = int(length)
            variant.size_known = True
            return variant
    except requests.RequestException:
        pass

    try:
        probe_headers = {**headers, "Range": "bytes=0-0"}
        with requests.get(
            variant.url,
            allow_redirects=True,
            timeout=timeout,
            headers=probe_headers,
            stream=True,
        ) as response:
            content_range = response.headers.get("Content-Range", "")
            match = CONTENT_RANGE_RE.search(content_range)
            if match:
                variant.size = int(match.group(1))
                variant.size_known = True
                return variant
            length = response.headers.get("Content-Length")
            if response.status_code == 200 and length and length.isdigit():
                variant.size = int(length)
                variant.size_known = True
    except requests.RequestException:
        pass

    return variant


def probe_sizes(variants: list[Variant]) -> list[Variant]:
    if not variants:
        return variants
    pending = [v for v in variants if v.kind != "hls" and not v.size_known]
    if pending:
        with ThreadPoolExecutor(max_workers=min(8, len(pending))) as pool:
            list(pool.map(probe_size, pending))
    return variants


def resolve(
    url: str,
    with_sizes: bool = True,
    cookies: str = "",
    cookies_from_browser: str = "",
) -> MediaInfo:
    url = url.strip()
    if not url:
        raise ResolutionError("URL vide")

    errors: list[str] = []
    data: dict = {}
    meta = {
        "author": "",
        "duration": None,
        "thumbnail": "",
        "login_required": False,
        "title": "",
    }

    match = STATUS_RE.search(url)
    tweet_id = match.group(1) if match else ""
    is_x = bool(tweet_id)

    def probe_ytdlp() -> None:
        nonlocal data
        data = _ytdlp_probe(url, cookies_from_browser)

    def probe_tweet() -> list[Variant]:
        payload = _fxtwitter_probe(tweet_id)
        variants, extra = _variants_from_tweet(payload)
        meta["author"] = meta["author"] or extra["author"]
        meta["duration"] = meta["duration"] or extra["duration"]
        meta["thumbnail"] = meta["thumbnail"] or extra["thumbnail"]
        return variants

    variants: list[Variant] = []
    extractor = ""

    if is_x:
        try:
            variants = probe_tweet()
            extractor = "fxtwitter"
        except (requests.RequestException, ResolutionError) as exc:
            errors.append(f"fxtwitter: {exc}")

    if not variants:
        try:
            probe_ytdlp()
        except (ResolutionError, subprocess.TimeoutExpired, json.JSONDecodeError, OSError) as exc:
            errors.append(f"yt-dlp: {exc}")

    if data and not variants:
        variants = _variants_from_ytdlp(data)
        extractor = "yt-dlp"
        meta["author"] = data.get("uploader") or data.get("channel") or ""
        meta["duration"] = data.get("duration")
        meta["thumbnail"] = data.get("thumbnail") or ""
        meta["title"] = str(data.get("title") or "")

    if not variants and is_x and not data:
        try:
            variants, page_meta = webpage.extract(url, cookies=cookies or None)
            extractor = "page"
            meta["title"] = page_meta.get("title") or ""
            meta["duration"] = meta["duration"] or page_meta.get("duration") or None
            meta["thumbnail"] = meta["thumbnail"] or page_meta.get("thumbnail") or ""
            meta["login_required"] = bool(page_meta.get("login_required"))
        except (requests.RequestException, webpage.WebPageError, ValueError) as exc:
            errors.append(f"page: {exc}")

    if not variants:
        try:
            variants, page_meta = webpage.extract(url, cookies=cookies or None)
            extractor = extractor or "page"
            meta["title"] = meta["title"] or page_meta.get("title") or ""
            meta["duration"] = meta["duration"] or page_meta.get("duration") or None
            meta["thumbnail"] = meta["thumbnail"] or page_meta.get("thumbnail") or ""
            meta["login_required"] = meta["login_required"] or bool(
                page_meta.get("login_required")
            )
        except (requests.RequestException, webpage.WebPageError, ValueError) as exc:
            errors.append(f"page: {exc}")

    if not variants:
        detail = " | ".join(errors) if errors else "aucun média vidéo trouvé"
        raise ResolutionError(detail)

    if with_sizes and extractor != "page":
        variants = probe_sizes(variants)

    author = meta.get("author") or ""
    page_title = meta.get("title", "")

    if tweet_id:
        stem = f"{author or 'inconnu'}_{tweet_id}"
    elif page_title:
        stem = _slug(page_title)
    elif author:
        stem = f"{_slug(author)}_video"
    else:
        stem = "video"

    return MediaInfo(
        source_url=url,
        title=stem,
        author=author or "inconnu",
        tweet_id=tweet_id,
        duration=meta.get("duration"),
        thumbnail=meta.get("thumbnail") or "",
        variants=variants,
        extractor=extractor,
        page_title=page_title,
        login_required=bool(meta.get("login_required")),
    )


def is_supported_host(url: str) -> bool:
    lowered = url.lower()
    if any(host in lowered for host in SUPPORTED_HOSTS):
        return True
    return bool(STATUS_RE.search(lowered))
