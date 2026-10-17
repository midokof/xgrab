"""Verifie que les cookies saisis sont reellement transmis au media."""

from __future__ import annotations

import shutil
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from xgrab.downloader import Downloader
from xgrab.resolver import resolve

SECRET = "ma_session_valide"
MEDIA = b"\x00\x00\x00\x18ftypmp42" + b"X" * 400_000

PAGE = """<html><head>
<script type="application/ld+json">
{"@type":"VideoObject","name":"Protege","duration":"PT1M0S"}
</script></head><body>
<script>
var cfg = {
  video_url: 'MEDIA_URL?s=1',
  video_url_text: '720p',
  video_alt_url: 'MEDIA_URL?s=2',
  video_alt_url_text: '360p'
};
</script></body></html>
"""

seen: list[tuple[str, str]] = []


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        cookie = self.headers.get("Cookie", "")
        seen.append((self.path, cookie))

        if self.path.startswith("/page"):
            body = PAGE.replace("MEDIA_URL", "http://127.0.0.1:PORT/clip.mp4").replace("PORT", str(PORT)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if SECRET not in cookie:
            body = b"denied"
            self.send_response(403)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(len(MEDIA)))
        self.end_headers()
        self.wfile.write(MEDIA)

    def log_message(self, *args) -> None:
        pass


def main() -> None:
    global PORT
    server = HTTPServer(("127.0.0.1", 0), Handler)
    PORT = server.server_port
    threading.Thread(target=server.serve_forever, daemon=True).start()
    page = f"http://127.0.0.1:{PORT}/page"

    try:
        print(f"--- sans cookies ---")
        info = resolve(page)
        heights = sorted((v.height for v in info.variants), reverse=True)
        print(f"  variantes : {heights}")
        assert heights == [720, 360], heights
        assert all("ma_session_valide" not in v.cookies for v in info.variants)

        target = Path(tempfile.mkdtemp(prefix="xgrab_cookie_"))
        downloader = Downloader(target, "sans")
        try:
            downloader.run(info.variants[0])
            raise AssertionError("aurait du echouer sans cookie")
        except Exception as exc:
            status = getattr(getattr(exc, "response", None), "status_code", None)
            print(f"  telechargement : {status} attendu")

        print(f"\n--- avec cookies ---")
        info2 = resolve(page, cookies=f"sessid={SECRET}; autre=1")
        assert all(SECRET in v.cookies for v in info2.variants), "cookies non transmis"
        print(f"  cookies portes : {info2.variants[0].cookies}")

        downloader2 = Downloader(target, "avec")
        result = downloader2.run(info2.variants[0])
        print(f"  telechargement : {result.status}  {result.bytes_written} octets")
        assert result.status == "done"
        assert result.path.read_bytes() == MEDIA
        print("  contenu        : identique a la source")

        sent = [c for _, c in seen if SECRET in c]
        print(f"  requetes avec cookie : {len(sent)}")
        assert sent

        shutil.rmtree(target, ignore_errors=True)
    finally:
        server.shutdown()

    print("\nCOOKIES OK")


if __name__ == "__main__":
    main()