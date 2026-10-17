"""Verifie qu'une fausse reponse (JSON, HTML) est refusee au telechargement."""

from __future__ import annotations

import json
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from xgrab.downloader import Downloader, _is_media_type
from xgrab.variants import Variant


class Handler(BaseHTTPRequestHandler):
    payload = b""
    ctype = "application/json"

    def log_message(self, *_a):
        pass

    def do_GET(self):
        body = Handler.payload
        self.send_response(200)
        self.send_header("Content-Type", Handler.ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def serve(payload: bytes, ctype: str):
    Handler.payload = payload
    Handler.ctype = ctype
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, httpd.server_address[1]


def attempt(name: str, payload: bytes, ctype: str, expect_ok: bool) -> bool:
    httpd, port = serve(payload, ctype)
    try:
        url = f"http://127.0.0.1:{port}/video.mp4"
        variant = Variant(label="720p", url=url, ext="mp4", kind="http", height=720, bitrate=0)
        folder = Path(tempfile.gettempdir()) / "xgrab_faux"
        folder.mkdir(exist_ok=True)
        try:
            result = Downloader(folder, f"essai_{name}").run(variant)
            ok = result.status == "done"
            taille = result.bytes_written
        except Exception as exc:
            ok = False
            taille = f"{type(exc).__name__}"
        finally:
            for leftover in folder.glob(f"essai_{name}*"):
                leftover.unlink(missing_ok=True)
    finally:
        httpd.shutdown()

    verdict = "OK " if ok == expect_ok else "RAT"
    print(f"  {verdict} {name:26} {str(taille):22} attendu={'accepte' if expect_ok else 'refuse'}")
    return ok == expect_ok


if __name__ == "__main__":
    print("=== filtre de type MIME ===")
    for mime, attendu in [
        ("video/mp4", True),
        ("audio/mp4", True),
        ("application/octet-stream", True),
        ("application/vnd.apple.mpegurl", True),
        ("application/dash+xml", True),
        ("application/json", False),
        ("application/manifest+json", False),
        ("text/html; charset=utf-8", False),
        ("application/x-subrip", False),
    ]:
        got = _is_media_type(mime)
        print(f"  {'OK ' if got == attendu else 'RAT'} {mime:34} -> {'media' if got else 'rejete'}")

    print("\n=== telechargement ===")
    manifest = json.dumps({"name": "YouTube", "short_name": "YouTube"}).encode()
    results = [
        attempt("manifeste PWA", manifest, "application/manifest+json", False),
        attempt("erreur JSON", manifest, "application/json", False),
        attempt("page HTML", b"<html>error</html>" * 4, "text/html", False),
        attempt("vrai petit media", b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 40000, "video/mp4", True),
    ]

    print()
    print("GARDE-FOUS OK" if all(results) else "ECHEC")
