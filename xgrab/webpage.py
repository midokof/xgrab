from __future__ import annotations

import json
import re
from collections import defaultdict
from typing import Optional
from urllib.parse import urljoin, urlparse, urlunparse

import requests

from .variants import Variant

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

MEDIA_RE = re.compile(
    r"""(?:https?:)?//[^\s"'<>\\)]+?\.(?:m3u8|mp4|webm|mov|m4v)(?:[/\\?][^\s"'<>\\)]*)?""",
    re.IGNORECASE,
)
IMAGE_EXT_RE = re.compile(r"\.(?:jpe?g|png|gif|webp|svg|bmp)(?:$|\?)", re.IGNORECASE)
JUNK_RE = re.compile(r"preview|sample|trailer|teaser|thumb|screenshot|placeholder", re.IGNORECASE)
HEIGHT_RE = re.compile(r"(?<![0-9])(\d{3,4})p(?![0-9])", re.IGNORECASE)
DIMS_RE = re.compile(r"(?<![0-9])(\d{3,5})x(\d{3,5})(?![0-9])")
QUALITY_RE = re.compile(r"(?:res|resolution|height|qual|quality|h)[=/_-](\d{3,4})(?![0-9])", re.IGNORECASE)
ID_RE = re.compile(r"(?<![0-9])(\d{4,})[_.-]")
PLAYER_URL_RE = re.compile(
    r"""video_(?:alt_)?url(\d*)\s*:\s*['"](https?://[^'"]+)['"]""", re.IGNORECASE
)
JSON_URL_RE = re.compile(r'"(?:videoUrl|mediaUrl|url)"\s*:\s*"(https?://[^"]+)"', re.IGNORECASE)
PLAYER_LABEL_RE = re.compile(
    r"""video_(?:alt_)?url(\d*)_text\s*:\s*['"](\d{3,4})p['"]""", re.IGNORECASE
)
LOGIN_MARKERS = (
    'data-href="https://pimpbunny.com/v2/login/"',
    "includes-header-guest",
    'data-login-action',
)
ISO_DURATION_RE = re.compile(
    r"^P(?:(?P<days>\d+)D)?T?(?:(?P<hours>\d+)H)?(?:(?P<minutes>\d+)M)?(?:(?P<seconds>[\d.]+)S)?$",
    re.IGNORECASE,
)


def _player_qualities(html: str) -> dict[int, str]:
    """Associations qualite -> URL declarees par le lecteur de la page.

    Le lecteur expose `video_alt_url: .../clip.mp4` suivi de
    `video_alt_url_text: '480p'`. Le nom de fichier ne porte alors aucune
    resolution : seul le libelle fait foi. Plusieurs entrees partagent la meme
    cle (`video_url` et `video_alt_url` ont toutes deux une cle vide), donc
    l'URL retenue est la plus proche du libelle dans le document.
    """
    urls = [
        (match.start(), match.group(1), match.group(2).replace("\\/", "/"))
        for match in PLAYER_URL_RE.finditer(html)
    ]
    if not urls:
        return {}

    out: dict[int, str] = {}
    for match in PLAYER_LABEL_RE.finditer(html):
        key = match.group(1)
        position = match.start()
        before = [item for item in urls if item[1] == key and item[0] < position]
        if before:
            url = max(before, key=lambda item: item[0])[2]
        else:
            candidates = [item for item in urls if item[1] == key]
            if not candidates:
                continue
            url = min(candidates, key=lambda item: abs(item[0] - position))[2]

        height = int(match.group(2))
        if url not in out.values():
            out[height] = _normalize(url, "")
    return out


def _needs_login(html: str) -> bool:
    return any(marker in html for marker in LOGIN_MARKERS)


def _json_qualities(html: str) -> dict[int, str]:
    """URLs de media declarees en JSON (`"videoUrl": "https://...1080P...m3u8"`).

    Regroupe par chemin sans le nom de fichier, pour ne garder que la piste
    principale et ecarter les recommandations.
    """
    best: dict[str, tuple[int, str]] = {}

    for match in JSON_URL_RE.finditer(html):
        url = _normalize(match.group(1).replace("\\/", "/"), "")
        path = urlparse(url).path
        if not path or not any(ext in path.lower() for ext in (".mp4", ".m3u8", ".webm")):
            continue
        height = _height_of(url)
        folder = path.rsplit("/", 2)[0] if height else path
        current = best.get(folder)
        if current is None or height > current[0]:
            best[folder] = (height, url)

    return {height: url for height, url in best.values() if height}


class WebPageError(Exception):
    pass


def _parse_iso_duration(value: str) -> float:
    match = ISO_DURATION_RE.match(value.strip())
    if not match:
        return 0.0
    parts = {k: float(v) for k, v in match.groupdict(default="0").items() if v}
    return parts.get("days", 0) * 86400 + parts.get("hours", 0) * 3600 + parts.get("minutes", 0) * 60 + parts.get("seconds", 0)


def _headers(cookies: Optional[str]) -> dict:
    headers = {
        "User-Agent": USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
    }
    if cookies:
        headers["Cookie"] = cookies
    return headers


def fetch(url: str, cookies: Optional[str] = None, timeout: int = 30, session: Optional[requests.Session] = None):
    if session is not None:
        response = session.get(url, timeout=timeout, allow_redirects=True)
    else:
        response = requests.get(url, headers=_headers(cookies), timeout=timeout, allow_redirects=True)
    if response.status_code >= 400:
        raise WebPageError(f"HTTP {response.status_code} sur {url}")
    return response.text


def _parse_cookie_header(raw: str) -> dict:
    jar: dict[str, str] = {}
    for chunk in (raw or "").split(";"):
        if "=" not in chunk:
            continue
        name, _, value = chunk.partition("=")
        name = name.strip()
        if name:
            jar[name] = value.strip()
    return jar


def _cookie_header(session: requests.Session, extra: str = "") -> str:
    jar = _parse_cookie_header(extra)
    for name, value in session.cookies.get_dict().items():
        jar.setdefault(name, value)
    return "; ".join(f"{name}={value}" for name, value in jar.items())


def _json_ld(html: str) -> dict:
    for match in re.finditer(r"application/ld\+json", html, re.IGNORECASE):
        start = html.find(">", match.start()) + 1
        end = html.find("</script>", start)
        if end == -1:
            continue
        try:
            data = json.loads(html[start:end].strip())
        except ValueError:
            continue
        nodes = data if isinstance(data, list) else [data]
        for node in nodes:
            if not isinstance(node, dict):
                continue
            if node.get("@type") == "VideoObject" or "duration" in node or "contentUrl" in node:
                return node
    return {}


def _height_of(url: str) -> int:
    path = urlparse(url).path
    match = HEIGHT_RE.search(path)
    if match:
        return int(match.group(1))
    dims = DIMS_RE.search(path)
    if dims:
        return int(dims.group(2))
    quality = QUALITY_RE.search(path)
    if quality:
        return int(quality.group(1))
    return 0


def _normalize(url: str, base: str) -> str:
    if not url.lower().startswith("http"):
        url = urljoin(base, url)
    parsed = urlparse(url)
    path = parsed.path.rstrip("/")
    if path != parsed.path:
        url = urlunparse(parsed._replace(path=path))
    return url


def _group_key(url: str) -> str:
    path = urlparse(url).path.rstrip("/")
    name = path.rsplit("/", 1)[-1]
    match = ID_RE.search(name)
    if match:
        return match.group(1)
    parts = [p for p in path.split("/") if p and not p.isdigit()]
    return parts[-1] if parts else path


def _clean(url: str, base: str) -> Optional[str]:
    url = _normalize(url, base)
    if IMAGE_EXT_RE.search(url) or urlparse(url).path.lower().endswith(
        (".jpg", ".jpeg", ".png", ".gif", ".webp")
    ):
        return None
    if JUNK_RE.search(urlparse(url).path):
        return None
    return url


def _collect(html: str, base: str) -> dict[str, dict[int, str]]:
    found: dict[str, dict[int, str]] = defaultdict(dict)

    text = html.replace("\\/", "/")
    for match in MEDIA_RE.finditer(text):
        raw = match.group(0)
        url = _clean(raw, base)
        if not url:
            continue

        height = _height_of(url)
        if height and (height < 120 or height > 4320):
            continue

        key = _group_key(url)
        current = found[key].get(height)
        if current is None or len(url) > len(current):
            found[key][height] = url

    return found


def _best_group(groups: dict[str, dict[int, str]]) -> dict[int, str]:
    if not groups:
        return {}

    def score(item: tuple[str, dict[int, str]]) -> tuple:
        _, mapping = item
        heights = [h for h in mapping if h]
        return (len(heights), max(heights) if heights else 0)

    return max(groups.items(), key=score)[1]


def _embed_candidates(html: str, base: str) -> list[str]:
    out: list[str] = []
    for match in re.finditer(r"<iframe[^>]+src=[\"']([^\"']+)[\"']", html, re.IGNORECASE):
        url = urljoin(base, match.group(1))
        host = urlparse(url).netloc.lower()
        if any(bad in host for bad in ("dreamserve", "ads", "doubleclick", "googlesyndication")):
            continue
        if url not in out:
            out.append(url)
    return out


def extract(url: str, cookies: Optional[str] = None, follow_embeds: bool = True) -> tuple[list[Variant], dict]:
    session = requests.Session()
    session.headers.update(
        {
            "User-Agent": USER_AGENT,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        }
    )
    if cookies:
        session.headers["Cookie"] = cookies

    html = fetch(url, session=session)
    groups = _collect(html, url)
    meta = _json_ld(html)

    if not groups and follow_embeds:
        for embed in _embed_candidates(html, url)[:3]:
            try:
                sub_html = fetch(embed, session=session)
            except (requests.RequestException, WebPageError):
                continue
            sub = _collect(sub_html, embed)
            if len(_best_group(sub)) > len(_best_group(groups)):
                groups = sub
                if not meta:
                    meta = _json_ld(sub_html)
                if sub:
                    break

    mapping = _best_group(groups)
    declared = _player_qualities(html)
    if declared:
        claimed = set(declared.values())
        mapping = {
            height: url
            for height, url in mapping.items()
            if _normalize(url.replace("\\/", "/"), "") not in claimed
        }
        mapping.update(declared)

    from_json = _json_qualities(html)
    if len(from_json) > len(mapping):
        mapping = dict(from_json)

    if not mapping:
        raise WebPageError("aucune URL de média trouvée dans la page")

    known = {urlparse(u).path for h, u in mapping.items() if h}
    mapping = {
        h: u for h, u in mapping.items() if h or urlparse(u).path not in known
    }

    cookie_header = _cookie_header(session, cookies or "")

    variants: list[Variant] = []
    for height, media_url in sorted(mapping.items(), reverse=True):
        is_hls = ".m3u8" in media_url.lower()
        variants.append(
            Variant(
                label=f"{height}p" if height else "source",
                url=media_url,
                ext="mp4",
                kind="hls" if is_hls else "http",
                height=height,
                width=round(height * 16 / 9) if height else 0,
                cookies=cookie_header,
                referer=url,
            )
        )

    info = {
        "title": meta.get("name") or "",
        "duration": _parse_iso_duration(str(meta.get("duration", ""))),
        "thumbnail": meta.get("thumbnailUrl") or "",
        "upload_date": str(meta.get("uploadDate", "")),
        "sizes_known": False,
        "login_required": _needs_login(html),
    }
    return variants, info
