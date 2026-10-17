"""Serveur local qui recoit les liens pousses par l'extension navigateur.

Ecoute uniquement sur 127.0.0.1 (jamais sur le reseau) et exige un jeton
partage avec l'extension. Le navigateur traite http://127.0.0.1 comme une
origine securisee, donc une page https peut l'appeler sans probleme de
contenu mixte.
"""

from __future__ import annotations

import json
import os
import secrets
import socket
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable, Optional

BASE_PORT = 38471
PORT_RANGE = 40
MAX_BODY = 512 * 1024
LOG_PATH = Path(tempfile.gettempdir()) / "xgrab-bridge.log"
EXTENSION_ORIGINS = (
    "chrome-extension://",
    "moz-extension://",
    "ms-browser-extension://",
    # Safari iOS/macOS identifie ses extensions ainsi.
    "safari-web-extension://",
)


class QuietServer(ThreadingHTTPServer):
    """Ignore les connexions abandonnees par le navigateur."""

    daemon_threads = True

    def handle_error(self, request, client_address) -> None:
        import sys as _sys

        exc = _sys.exc_info()[1]
        if isinstance(exc, (ConnectionAbortedError, ConnectionResetError, BrokenPipeError)):
            return
        super().handle_error(request, client_address)


class BridgeServer:
    """Petit serveur HTTP local utilise par l'extension navigateur."""

    def __init__(
        self,
        on_add: Callable[[list[str], str], None],
        on_status: Optional[Callable[[str], None]] = None,
        allow_lan: bool = False,
    ) -> None:
        self.token = secrets.token_urlsafe(24)
        self.on_add = on_add
        self.on_status = on_status
        # L'ecoute sur le reseau n'est jamais active par defaut : elle expose
        # le point d'injection de liens a tout le segment. Le jeton reste la
        # seule barriere, l'utilisateur l'assume explicitement.
        self.allow_lan = allow_lan
        self.port = 0
        self._server: Optional[ThreadingHTTPServer] = None
        self._thread: Optional[threading.Thread] = None

    @property
    def bind_host(self) -> str:
        return "0.0.0.0" if self.allow_lan else "127.0.0.1"

    # ------------------------------------------------------------- cycle de vie

    def start(self) -> int:
        """Demarre le serveur et retourne le port, ou 0 si echec."""
        for port in range(BASE_PORT, BASE_PORT + PORT_RANGE):
            if not _port_free(port):
                continue
            try:
                server = QuietServer((self.bind_host, port), self._make_handler())
            except OSError:
                continue
            server.daemon_threads = True
            self._server = server
            self.port = port
            self._thread = threading.Thread(target=server.serve_forever, daemon=True)
            self._thread.start()
            return port
        return 0

    def stop(self) -> None:
        if self._server:
            self._server.shutdown()
            self._server.server_close()
            self._server = None
        self._thread = None

    # ---------------------------------------------------------------- requetes

    def _make_handler(self):
        bridge = self

        class Handler(BaseHTTPRequestHandler):
            server_version = "XGrabBridge/1.0"
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args) -> None:
                """Journalise chaque requete pour diagnostiquer l'extension."""
                line = "%s %s\n" % (self.command, self.path)
                try:
                    with open(LOG_PATH, "a", encoding="utf-8") as handle:
                        handle.write(line)
                        for name in ("Origin", "Access-Control-Request-Method",
                                     "Access-Control-Request-Headers",
                                     "Access-Control-Request-Private-Network",
                                     "X-XGrab-Token"):
                            value = self.headers.get(name)
                            if value:
                                handle.write(f"    {name}: {value[:80]}\n")
                except OSError:
                    pass

            def _cors(self) -> None:
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
                self.send_header("Access-Control-Allow-Headers", "Content-Type, X-XGrab-Token")
                self.send_header("Access-Control-Max-Age", "600")

            def _reply(self, code: int, payload: dict) -> None:
                body = json.dumps(payload).encode("utf-8")
                self.send_response(code)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self._cors()
                self.end_headers()
                self.wfile.write(body)

            def _authorised(self) -> bool:
                origin = self.headers.get("Origin", "")
                if origin and not origin.startswith(EXTENSION_ORIGINS):
                    return False
                return secrets.compare_digest(
                    self.headers.get("X-XGrab-Token", ""), bridge.token
                )

            def do_OPTIONS(self) -> None:
                self.send_response(204)
                self._cors()
                self.send_header("Content-Length", "0")
                self.end_headers()

            def do_GET(self) -> None:
                if self.path == "/ping":
                    # Le jeton est facultatif pour un simple "l'app vit-elle ?",
                    # mais s'il est fourni il doit etre valide : c'est ainsi que
                    # le hote natif detecte un config.json perime.
                    supplied = self.headers.get("X-XGrab-Token", "")
                    if supplied and not secrets.compare_digest(supplied, bridge.token):
                        self._reply(403, {"ok": False, "error": "jeton périmé"})
                        return
                    self._reply(
                        200,
                        {
                            "ok": True,
                            "app": "XGrab",
                            "version": _version(),
                            "pid": os.getpid(),
                        },
                    )
                    return
                self._reply(404, {"ok": False, "error": "unknown endpoint"})

            def do_POST(self) -> None:
                if self.path != "/add":
                    self._reply(404, {"ok": False, "error": "unknown endpoint"})
                    return
                if not self._authorised():
                    self._reply(403, {"ok": False, "error": "refusé"})
                    return

                try:
                    length = int(self.headers.get("Content-Length", "0"))
                except ValueError:
                    length = 0
                if length <= 0 or length > MAX_BODY:
                    self._reply(400, {"ok": False, "error": "corps invalide"})
                    return

                try:
                    data = json.loads(self.rfile.read(length).decode("utf-8"))
                except (ValueError, UnicodeDecodeError):
                    self._reply(400, {"ok": False, "error": "json invalide"})
                    return

                urls = _clean_urls(data.get("urls"))
                if not urls:
                    self._reply(400, {"ok": False, "error": "aucun lien"})
                    return

                referer = data.get("referer")
                referer = referer if isinstance(referer, str) and referer.startswith("http") else ""
                bridge.on_add(urls, referer)
                bridge.on_status and bridge.on_status(f"Reçu du navigateur : {len(urls)} lien(s)")
                self._reply(200, {"ok": True, "added": len(urls)})

        return Handler


def _clean_urls(raw) -> list[str]:
    if not isinstance(raw, list):
        return []
    seen: list[str] = []
    for item in raw:
        if not isinstance(item, str):
            continue
        url = item.strip()
        if not url.lower().startswith(("http://", "https://")):
            continue
        if url.lower().startswith("blob:"):
            continue
        if url not in seen:
            seen.append(url)
    return seen


def _port_free(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


def _version() -> str:
    from . import __version__

    return __version__


def lan_address() -> str:
    """Adresse IPv4 du PC sur le reseau local, telle qu'elle doit etre
    saisie dans l'app iPhone. Retourne une chaine vide si introuvable."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # Aucune donnee n'est envoye : cela selectionne simplement l'interface
        # de sortie vers Internet, ce qui donne l'IP locale utile au LAN.
        sock.connect(("192.0.2.1", 9))
        address = sock.getsockname()[0]
    except OSError:
        return ""
    finally:
        sock.close()
    return address if not address.startswith("127.") else ""


def extension_dir() -> Path:
    """Dossier de l'extension, en dev comme dans l'exe."""
    base = getattr(sys, "_MEIPASS", None)
    if base:
        candidate = Path(base) / "extension"
        if candidate.is_dir():
            return candidate
    return Path(__file__).resolve().parent.parent / "extension"


def installed_extension_dir() -> Path:
    """Dossier stable ou l'installateur depose l'extension."""
    import os

    local = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
    return Path(local) / "XGrab" / "extension"


def write_bridge_config(port: int, token: str) -> list[str]:
    """Ecrit la configuration lue par l'extension dans tous les dossiers connus."""
    payload = json.dumps({"port": port, "token": token}, ensure_ascii=False, indent=2)
    written: list[str] = []

    targets = [extension_dir(), installed_extension_dir()]
    if getattr(sys, "frozen", False):
        exe_dir = Path(sys.executable).parent / "extension"
        if exe_dir.is_dir():
            targets.append(exe_dir)

    seen: set[str] = set()
    for target in targets:
        key = str(target)
        if key in seen:
            continue
        seen.add(key)
        try:
            target.mkdir(parents=True, exist_ok=True)
            (target / "config.json").write_text(payload, encoding="utf-8")
            written.append(key)
        except OSError:
            continue
    return written
