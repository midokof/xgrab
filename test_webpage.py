"""Test de l'extracteur HTML : filtrage, groupement, resolutions."""

from __future__ import annotations

import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Thread

from xgrab import webpage
from xgrab.webpage import (
    _best_group,
    _collect,
    _clean,
    _group_key,
    _height_of,
    _normalize,
    _parse_iso_duration,
)

PAGE = """<!doctype html><html><head>
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"VideoObject",
 "name":"Video de test","duration":"PT1H2M3S",
 "thumbnailUrl":"https://ex.test/thumb.jpg",
 "uploadDate":"2026-01-02"}
</script>
</head><body>
<script>
var cfg = {
  video_url: 'https://cdn.ex.test/get/9/aaaa/900/900901/900901_pb_1080p.mp4/?v-token=SECRET1080',
  video_url_text: '1080p',
  video_alt_url: 'https://cdn.ex.test/get/9/bbbb/900/900901/900901.mp4/?v-token=SECRET720',
  video_alt_url_text: '720p',
  video_alt_url2: 'https://cdn.ex.test/get/9/cccc/900/900901/900901_480p.mp4/?v-token=SECRET480',
  video_alt_url2_text: '480p'
};
var junk = [
  'https://cdn.ex.test/get/1/111/111/111222/111222_preview.mp4/',
  'https://cdn.ex.test/get/2/222/222/222333/222333_preview.mp4/',
  'https://cdn.ex.test/get/3/333/333/222333/222333_preview.mp4/',
  'https://cdn.ex.test/contents/shot/900901/preview_pb_1080p.mp4.jpg'
];
var other = [
  'https://cdn.ex.test/hls/900901/master.m3u8',
  'https://cdn.ex.test/hls/900901/1920x1080/seg/index.m3u8',
  'https://cdn.ex.test/dims/1280x720/movie.mp4',
  'https://cdn.ex.test/quality/res=360/movie.mp4',
  'https://cdn.ex.test/plain/movie.webm'
];
</script>
<iframe src="https://ads.ex.test/iframe?x=1"></iframe>
<div data-href="https://pimpbunny.com/v2/login/" data-login-action>Sign in</div>
</body></html>
"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        body = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args) -> None:
        pass


def serve() -> tuple[str, HTTPServer]:
    server = HTTPServer(("127.0.0.1", 0), Handler)
    Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_port}/video", server


def check(label: str, got, expected) -> None:
    if got != expected:
        print(f"ECHEC {label}\n   attendu: {expected!r}\n   obtenu : {got!r}")
        raise SystemExit(1)
    print(f"ok  {label:<46} {got!r}")


def main() -> None:
    check("duree ISO", _parse_iso_duration("PT1H2M3S"), 3723.0)
    check("duree ISO minutes", _parse_iso_duration("PT18M38S"), 1118.0)
    check("duree ISO jours", _parse_iso_duration("P1DT2H"), 93600.0)

    check("hauteur _1080p", _height_of("https://a/b/x_pb_1080p.mp4/?t=1"), 1080)
    check("hauteur 1920x1080", _height_of("https://a/b/1920x1080/i.m3u8"), 1080)
    check("hauteur res=720", _height_of("https://a/b/res=720/m.mp4"), 720)
    check("hauteur absente", _height_of("https://a/b/movie.mp4"), 0)

    raw = "https://cdn.ex.test/get/9/aaaa/900/900901/900901_pb_1080p.mp4/?v-token=ABC"
    check("normalisation supprime /", _normalize(raw, "https://x/"), raw.replace(".mp4/", ".mp4"))
    check("groupage par id", _group_key(_normalize(raw, "https://x/")), "900901")

    check("prefet preview rejete", _clean("https://a/b/111_preview.mp4/", "https://x/"), None)
    check("prefet jpg rejete", _clean("https://a/b/p_1080p.mp4.jpg", "https://x/"), None)
    check("racine relative acceptee", _clean("/media/x_720p.mp4", "https://a.test/p/"), "https://a.test/media/x_720p.mp4")

    url, server = serve()
    try:
        variants, info = webpage.extract(url)
    finally:
        server.shutdown()

    heights = sorted((v.height for v in variants), reverse=True)
    check("token 1080p conserve", any("v-token=SECRET1080" in v.url for v in variants), True)
    check("token 720p conserve", any("v-token=SECRET720" in v.url for v in variants), True)
    check("token 480p conserve", any("v-token=SECRET480" in v.url for v in variants), True)
    check("aucune variante preview", [h for h in heights if h in (0,)], [])
    check("resolutions du lecteur", heights, [1080, 720, 480])
    check("pas de doublon", len({v.url for v in variants}), 3)
    check("toutes hauteurs connues", all(v.height for v in variants), True)
    check("url sans double barre", all(".mp4//" not in v.url for v in variants), True)
    check("titre ld+json", info["title"], "Video de test")
    check("duree ld+json", info["duration"], 3723.0)
    check("taille non sondee", info["sizes_known"], False)
    check("cookies/vide", any(v.cookies == "" for v in variants), True)
    check("referer pose", variants[0].referer, url)
    check("page invite detectee", info["login_required"], True)

    test_ytdlp_headers()

    print("\n" + "\n".join(f"   {v.describe():<46} {v.url[-58:]}" for v in variants))
    print("\nWEBPAGE OK")


def test_ytdlp_headers() -> None:
    """Les http_headers et cookies de yt-dlp doivent atteindre la variante."""
    from xgrab.resolver import _variants_from_ytdlp

    data = {
        "formats": [
            {
                "url": "https://cdn.test/720P_2000K_1.mp4?h=abc",
                "height": 720,
                "protocol": "https",
                "ext": "mp4",
                "vcodec": None,
                "tbr": None,
                "http_headers": {"User-Agent": "UA", "Referer": "https://site/", "Origin": "https://site"},
                "cookies": "cf=xyz; Domain=.test; Path=/",
            },
            {
                "url": "https://cdn.test/index.m3u8",
                "height": 1080,
                "protocol": "m3u8",
                "ext": "mp4",
                "vcodec": "h264",
                "acodec": "aac",
                "http_headers": {"User-Agent": "UA2"},
                "cookies": "cf=zzz; Domain=.test",
            },
            {"url": "https://cdn.test/audio.m4a", "height": 0, "vcodec": "none", "protocol": "https"},
        ]
    }
    variants = _variants_from_ytdlp(data)
    check("format audio seul ecarte", len(variants), 2)

    http = next(v for v in variants if v.kind == "http")
    check("vcodec absent accepte", http.height, 720)
    check("cookie yt-dlp extrait", http.cookies, "cf=xyz")
    check("headers yt-dlp", sorted(http.headers), ["Origin", "Referer", "User-Agent"])
    check("referer", http.referer, "https://site/")

    hls = next(v for v in variants if v.kind == "hls")
    check("hls classe", hls.kind, "hls")
    check("tri par hauteur", variants[0].height, 1080)


if __name__ == "__main__":
    main()
