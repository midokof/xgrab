"""Simule le protocole native messaging tel que le navigateur l'envoie."""

from __future__ import annotations

import json
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
HOST_MANIFEST = Path.home() / "AppData" / "Local" / "XGrab" / "native-host.json"


def call(message: dict, timeout: int = 90) -> dict:
    body = json.dumps(message).encode("utf-8")
    payload = struct.pack("=I", len(body)) + body
    proc = subprocess.Popen(
        [str(ROOT / "dist" / "XGrab" / "XGrab.exe"), str(HOST_MANIFEST)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    out, err = proc.communicate(payload, timeout=timeout)
    if not out:
        return {"ok": False, "error": f"aucune reponse (code {proc.returncode})", "stderr": err[:300].decode(errors="replace")}
    (length,) = struct.unpack("=I", out[:4])
    return json.loads(out[4 : 4 + length].decode("utf-8"))


if __name__ == "__main__":
    if not HOST_MANIFEST.exists():
        raise SystemExit(f"manifeste absent : {HOST_MANIFEST}\nLance install_extension.ps1")

    print(f"manifeste : {HOST_MANIFEST}")
    print(f"contenu   : {json.loads(HOST_MANIFEST.read_text(encoding='utf-8-sig'))}")

    print("\n--- message vide (doit refuser proprement) ---")
    print(" ", call({"urls": []}, timeout=30))

    print("\n--- lien reel ---")
    url = (
        "https://pimpbunny.com/get_file/49/7f5de0395cd86f5cf6a19e0957016163/613000/613544/"
        "613544_pb_1080p.mp4/?v-acctoken=MzMzMHwyNjYxOTF8MHxiMzA1ZTcxZjQ3Mjk2OWZiOTQ0MTE5NGFkODA1Y2RjOQ8a0f7633fa910311"
    )
    result = call(
        {
            "urls": [url],
            "referer": "https://pimpbunny.com/view/video/12345/title.html",
        },
        timeout=120,
    )
    print(" ", result)

    if not result.get("ok"):
        raise SystemExit("ECHEC")

    print(f"\nlance par l'hote natif : {result.get('started')}")
    print("NATIVE HOST OK")
