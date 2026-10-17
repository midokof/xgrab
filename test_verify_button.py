"""Verifie le bouton Verifier : OK, refus sans cookie, refus cookie invalide."""

from __future__ import annotations

import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from xgrab.app import XGrabApp

SECRET = "session_valide_1234"
MEDIA = b"\x00\x00\x00\x18ftypmp42" + b"Z" * 200_000

PAGE = """<html><head>
<script type="application/ld+json">{{"@type":"VideoObject","name":"Verif","duration":"PT2M0S"}}</script>
</head><body><script>
var cfg = {{ video_url: 'http://127.0.0.1:{port}/clip.mp4?s=1', video_url_text: '720p' }};
</script></body></html>
"""

PORT = 0


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path.startswith("/page"):
            body = PAGE.format(port=PORT).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if SECRET not in self.headers.get("Cookie", ""):
            self.send_response(403)
            self.send_header("Content-Length", "6")
            self.end_headers()
            self.wfile.write(b"denied")
            return

        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(len(MEDIA)))
        self.end_headers()
        self.wfile.write(MEDIA)

    def log_message(self, *args) -> None:
        pass


def pump(app: XGrabApp, seconds: float) -> None:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        app.update()
        time.sleep(0.02)


def check_log(app: XGrabApp, needle: str) -> str:
    log = app.log.get("1.0", "end")
    if needle not in log:
        raise AssertionError(f"journal sans '{needle}'\n{log}")
    return log


def main() -> None:
    global PORT
    server = HTTPServer(("127.0.0.1", 0), Handler)
    PORT = server.server_port
    threading.Thread(target=server.serve_forever, daemon=True).start()
    page = f"http://127.0.0.1:{PORT}/page"

    app = XGrabApp()
    app.auto_var.set(False)
    app.out_var.set(str(Path(tempfile.gettempdir()) / "xgrab_verify"))
    pump(app, 0.4)

    try:
        app.url_var.set(page)

        app._test()
        pump(app, 8.0)
        log = check_log(app, "REFUSÉ — 403")
        assert "Aucun cookie fourni" in log, log
        print("ok  sans cookie -> REFUSÉ 403 + explication")

        app._clear_log()
        app.cookies_var.set("sessid=mauvais_valeur")
        app._test()
        pump(app, 8.0)
        log = check_log(app, "REFUSÉ — 403")
        assert "présents mais invalides" in log, log
        assert "180 Ko" in log or "taille" not in log
        print("ok  cookie invalide -> REFUSÉ 403 + explication")

        app._clear_log()
        app.cookies_var.set(f"sessid={SECRET}")
        app._test()
        pump(app, 8.0)
        log = check_log(app, "OK — 200")
        assert "téléchargement possible" in log, log
        assert "Ko" in log or "o" in log
        print("ok  cookie valide -> OK 200 + taille")

        print("\nVERIFY OK")
    finally:
        app._on_close()
        server.shutdown()


if __name__ == "__main__":
    main()