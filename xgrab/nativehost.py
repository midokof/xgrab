"""Hote de Native Messaging : permet a l'extension de lancer XGrab.

Le navigateur demarre ce processus avec le chemin du manifeste JSON en
argument. Si l'application tourne deja, on lui transmet le lien ; sinon on
la lance en arriere-plan puis on attend qu'elle reponde.
"""

from __future__ import annotations

import json
import os
import struct
import subprocess
import sys
import time
from pathlib import Path

from .server import installed_extension_dir

HOST_NAME = "com.xgrab.app"
START_TIMEOUT = 45.0
PING_EVERY = 0.35


# --------------------------------------------------------------- protocole


def read_message(stream) -> dict:
    """Lit un message : 4 octets de longueur (natif) puis du JSON."""
    header = _read_exact(stream, 4)
    if len(header) < 4:
        return {}
    (length,) = struct.unpack("=I", header)
    if length <= 0 or length > 8 * 1024 * 1024:
        return {}
    payload = _read_exact(stream, length)
    if len(payload) < length:
        return {}
    try:
        return json.loads(payload.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return {}


def write_message(stream, payload: dict) -> None:
    """Ecrit un message : longueur puis JSON."""
    body = json.dumps(payload).encode("utf-8")
    stream.write(struct.pack("=I", len(body)))
    stream.write(body)
    stream.flush()


def _read_exact(stream, count: int) -> bytes:
    chunks: list[bytes] = []
    remaining = count
    while remaining > 0:
        chunk = stream.read(remaining)
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


# -------------------------------------------------------------- lancement


def executable_path() -> list[str]:
    """Commande qui lance l'interface graphique."""
    if getattr(sys, "frozen", False):
        return [sys.executable]
    import shutil

    python = shutil.which("pythonw") or shutil.which("python")
    if not python:
        raise RuntimeError("python introuvable")
    root = Path(__file__).resolve().parent.parent
    return [python, str(root / "main.py")]


def working_dir() -> str:
    if getattr(sys, "frozen", False):
        return str(Path(sys.executable).parent)
    return str(Path(__file__).resolve().parent.parent)


def is_running(port: int, token: str) -> bool:
    """L'app repond-elle avec CE jeton ?

    Le ping porte le jeton : sans cette verification, un config.json laisse
    par une session precedente passerait pour valide et chaque envoi serait
    refuse en 403.
    """
    import requests

    try:
        response = requests.get(
            f"http://127.0.0.1:{port}/ping",
            headers={"X-XGrab-Token": token},
            timeout=1.5,
        )
        if response.status_code != 200:
            return False
        return bool(response.json().get("ok"))
    except Exception:
        return False


def read_config() -> tuple[int, str]:
    path = installed_extension_dir() / "config.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return int(data.get("port") or 0), str(data.get("token") or "")
    except (OSError, ValueError):
        return 0, ""


def launch_gui() -> None:
    """Demarre l'interface en arriere-plan, sans fenetre console."""
    flags = 0
    if sys.platform == "win32":
        flags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0) | getattr(
            subprocess, "DETACHED_PROCESS", 0
        )
    subprocess.Popen(
        executable_path(),
        cwd=working_dir(),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=flags,
        close_fds=True,
    )


def wait_for_gui(timeout: float = START_TIMEOUT) -> tuple[int, str]:
    """Attend que l'interface ecrive un port et un jeton valides."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        port, token = read_config()
        if port and token and is_running(port, token):
            return port, token
        time.sleep(PING_EVERY)
    return 0, ""


# ------------------------------------------------------------------ main


def serve(manifest_path: str | None = None) -> None:
    """Boucle de native messaging (lance par le navigateur)."""
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer

    message = read_message(stdin)
    urls = [u for u in message.get("urls", []) if isinstance(u, str) and u.startswith("http")]
    referer = message.get("referer") or ""

    if not urls:
        write_message(stdout, {"ok": False, "error": "aucun lien"})
        return

    try:
        port, token = read_config()
        started = False

        if not (port and token and is_running(port, token)):
            launch_gui()
            started = True
            port, token = wait_for_gui()

        if not (port and token):
            write_message(
                stdout, {"ok": False, "error": "XGrab n'a pas demarre", "started": started}
            )
            return

        import requests

        response = requests.post(
            f"http://127.0.0.1:{port}/add",
            headers={"X-XGrab-Token": token, "Origin": "chrome-extension://native-host"},
            json={"urls": urls, "referer": referer},
            timeout=10,
        )
        data = response.json()
        write_message(
            stdout,
            {
                "ok": bool(response.ok and data.get("ok")),
                "added": data.get("added", 0),
                "started": started,
                "error": data.get("error", ""),
            },
        )
    except Exception as exc:  # noqa: BLE001
        write_message(stdout, {"ok": False, "error": str(exc)})


def is_host_invocation(argv: list[str]) -> bool:
    return len(argv) >= 1 and argv[0].lower().endswith(".json")
