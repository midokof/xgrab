"""Capture la requete media reelle du navigateur, methode IDM.

Le navigateur ouvre la page, joue la video, et l'on intercepte la requete HTTP
exacte qu'il emet (URL signee + en-tetes + cookies). Le telechargement rejoue
ensuite cette requete. C'est le principe d'IDM : rien n'est devine.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.request
from pathlib import Path
from urllib.parse import urlparse
from typing import Callable, Optional

from .utils import hidden_popen_kwargs
from .variants import Variant

BROWSERS = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe",
]

MEDIA_TYPES = {"Media", "Video", "XHR", "Fetch", "Other"}
MEDIA_EXT = (".mp4", ".m3u8", ".webm", ".mov", ".m4v", ".ts")

PLAY_SCRIPT = """
(async () => {
  const wait = ms => new Promise(r => setTimeout(r, ms));
  for (let i = 0; i < 40; i++) {
    const video = document.querySelector('video');
    if (video) {
      video.muted = true;
      try { await video.play(); } catch (e) {}
      if (!video.src && video.querySelector('source')) {
        video.src = video.querySelector('source').src;
        try { await video.play(); } catch (e) {}
      }
      if (video.currentSrc) return video.currentSrc;
    }
    const button = document.querySelector(
      '.kt_player button, .player button, [class*="play"] button, button[aria-label*="play" i]'
    );
    if (button) { try { button.click(); } catch (e) {} }
    await wait(500);
  }
  return '';
})()
"""


class CaptureError(Exception):
    pass


def find_browser() -> Optional[str]:
    for path in BROWSERS:
        if Path(path).exists():
            return path
    for name in ("chrome.exe", "chrome", "msedge.exe", "msedge", "brave.exe"):
        found = shutil.which(name)
        if found:
            return found
    return None


def profile_path() -> Path:
    base = Path(os.environ.get("APPDATA", Path.home())) / "XGrab" / "browser-profile"
    base.mkdir(parents=True, exist_ok=True)
    return base


def _pick_port() -> int:
    import socket

    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _launch(browser: str, port: int, profile: Path, headless: bool) -> subprocess.Popen:
    args = [
        browser,
        f"--remote-debugging-port={port}",
        f"--user-data-dir={profile}",
        "--remote-allow-origins=*",
        "--no-first-run",
        "--no-default-browser-check",
        "--no-startup-window",
        "--autoplay-policy=no-user-gesture-required",
        "--disable-features=Translate,MediaRouter,OptimizationHints",
        "about:blank",
    ]
    if headless:
        args.insert(1, "--headless=new")
    return subprocess.Popen(
        args,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        **hidden_popen_kwargs(),
    )


class _CDP:
    def __init__(self, ws_url: str, timeout: float = 30.0):
        import websocket

        self.ws = websocket.create_connection(ws_url, timeout=timeout)
        self.counter = 0
        self.session: Optional[str] = None

    def send(self, method: str, params: Optional[dict] = None, want_id: bool = True):
        self.counter += 1
        message = {"id": self.counter, "method": method, "params": params or {}}
        if self.session:
            message["sessionId"] = self.session
        self.ws.send(json.dumps(message))
        return self.counter if want_id else None

    def pump(self, seconds: float, on_event: Callable[[dict], None]) -> None:
        self.ws.settimeout(0.4)
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            for message in self._drain():
                if "method" in message:
                    on_event(message)

    def _drain(self) -> list[dict]:
        try:
            raw = self.ws.recv()
        except Exception:
            return []
        if not raw:
            return []
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8", "replace")
        out: list[dict] = []
        for line in raw.split("\n"):
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
        return out

    def wait_response(self, message_id: int, seconds: float = 20.0) -> dict:
        self.ws.settimeout(0.4)
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            for message in self._drain():
                if message.get("id") == message_id and "result" in message:
                    return message["result"]
        return {}

    def wait_event(self, method: str, seconds: float = 20.0) -> dict:
        found: dict = {}
        self.pump(seconds, lambda d: found.update(d) if d.get("method") == method else None)
        return found

    def close(self) -> None:
        try:
            self.ws.close()
        except Exception:
            pass


def _headers_from_event(params: dict) -> dict:
    request = params.get("request", {})
    headers = dict(request.get("headers", {}))
    return {k: str(v) for k, v in headers.items()}


def _height_of(url: str) -> int:
    match = re.search(r"(?<![0-9])(\d{3,4})p(?![0-9])", url) or re.search(
        r"(?<![0-9])(\d{3,5})x(\d{3,5})(?![0-9])", url
    )
    if not match:
        return 0
    return int(match.group(1)) if match.lastindex == 1 else int(match.group(2))


def capture(
    url: str,
    on_log: Optional[Callable[[str], None]] = None,
    headless: bool = True,
    seconds: float = 45.0,
) -> list[Variant]:
    browser = find_browser()
    if not browser:
        raise CaptureError("aucun navigateur Chromium trouvé")

    port = _pick_port()
    profile = profile_path()
    process = _launch(browser, port, profile, headless)

    log = on_log or (lambda _m: None)
    log(f"navigateur : {Path(browser).name}")

    cdp: Optional[_CDP] = None
    try:
        ws_url = None
        end = time.monotonic() + 30
        while time.monotonic() < end:
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/json/version", timeout=2
                ) as response:
                    ws_url = json.load(response).get("webSocketDebuggerUrl")
                break
            except Exception:
                time.sleep(0.3)
        if not ws_url:
            raise CaptureError("le navigateur ne répond pas au port de débogage")

        cdp = _CDP(ws_url)
        created = cdp.wait_response(cdp.send("Target.createTarget", {"url": "about:blank"}))
        target_id = created.get("targetId")
        if not target_id:
            raise CaptureError("impossible de créer l'onglet")

        attached = cdp.wait_response(
            cdp.send("Target.attachToTarget", {"targetId": target_id, "flatten": True})
        )
        cdp.session = attached.get("sessionId")
        if not cdp.session:
            raise CaptureError("connexion à l'onglet impossible")

        cdp.send("Network.enable")
        cdp.send("Page.enable")
        cdp.send("Runtime.enable")
        log("onglet prêt, chargement de la page...")
        cdp.send("Page.navigate", {"url": url})

        requests: dict[str, dict] = {}
        extras: dict[str, dict] = {}
        order: list[str] = []
        played = False

        def watch(event: dict) -> None:
            nonlocal played
            method = event.get("method", "")
            params = event.get("params", {})

            if method == "Page.loadEventFired" and not played:
                played = True
                cdp.send(
                    "Runtime.evaluate",
                    {
                        "expression": PLAY_SCRIPT,
                        "awaitPromise": False,
                        "userGesture": True,
                    },
                )

            elif method == "Network.requestWillBeSentExtraInfo":
                rid = params.get("requestId", "")
                headers = params.get("headers", {})
                if rid:
                    extras[rid] = {k: str(v) for k, v in headers.items()}

            elif method == "Network.requestWillBeSent":
                request = params.get("request", {})
                target = request.get("url", "")
                lowered = target.lower()
                if ".php" in lowered:
                    return
                if any(ext in lowered for ext in MEDIA_EXT):
                    rid = params.get("requestId", "")
                    requests[rid] = {"url": target, "headers": _headers_from_event(params)}
                    if rid not in order:
                        order.append(rid)

            elif method == "Network.responseReceived":
                response = params.get("response", {})
                if str(response.get("status", "")) not in ("200", "206"):
                    return
                mime = response.get("mimeType", "")
                if not (mime.startswith("video/") or "mpegurl" in mime):
                    return
                rid = params.get("requestId", "")
                entry = requests.get(rid)
                if not entry:
                    return
                entry["mime"] = mime
                entry["ok"] = True
                if rid not in order:
                    order.append(rid)
                hits["done"] = True

        hits = {"done": False}

        def on_event(event: dict) -> None:
            watch(event)

        def run_window() -> None:
            end = time.monotonic() + seconds
            while time.monotonic() < end and not hits["done"]:
                cdp.pump(0.5, on_event)

        run_window()
        cdp.close()
        cdp = None

        found = [requests[rid] for rid in order if rid in requests]
        if not found:
            raise CaptureError(
                "aucune requête vidéo interceptée — connecte-toi une fois dans la "
                "fenêtre du navigateur, puis réessaie"
            )
        variants: list[Variant] = []
        seen: set[str] = set()
        for rid in order:
            item = requests.get(rid)
            if not item:
                continue
            target = item["url"]
            path = urlparse(target).path.lower()
            if target in seen:
                continue
            if not any(ext in path for ext in MEDIA_EXT):
                continue
            # Le nom du fichier ne suffit pas : YouTube sert par exemple son
            # manifeste d'application depuis une URL qui finit en .webm. Seule
            # une reponse dont le type MIME a ete confirme comme media compte.
            if not item.get("ok"):
                continue
            seen.add(target)

            headers = dict(item.get("headers", {}))
            extra = extras.get(rid, {})
            for name, value in extra.items():
                headers.setdefault(name, value)
            headers = {k: v for k, v in headers.items() if not k.startswith(":")}
            dropped = {"range", "host", "content-length", "accept-encoding", "connection"}
            headers = {k: v for k, v in headers.items() if k.lower() not in dropped}

            height = _height_of(target)
            is_hls = ".m3u8" in target.lower()
            variants.append(
                Variant(
                    label=f"{height}p" if height else "source",
                    url=target,
                    ext="mp4",
                    kind="hls" if is_hls else "http",
                    height=height,
                    headers=headers,
                    cookies=headers.get("cookie") or headers.get("Cookie", ""),
                    referer=headers.get("Referer") or headers.get("referer", url),
                    origin=headers.get("Origin") or headers.get("origin", ""),
                )
            )

        variants.sort(key=lambda v: (v.height, 1 if v.kind == "http" else 0), reverse=True)
        if not variants:
            raise CaptureError(
                "les requetes capturees n'etaient pas des flux video "
                "(le site a renvoye du JSON ou du HTML)"
            )
        with_cookies = sum(1 for v in variants if v.cookies)
        log(f"{len(variants)} requête(s) vidéo interceptée(s), {with_cookies} avec cookie")
        return variants
    finally:
        if cdp:
            cdp.close()
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()