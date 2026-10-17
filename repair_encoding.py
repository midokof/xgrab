"""Repare un double encodage UTF-8 -> CP1252 -> UTF-8 sur des sources Python.

PowerShell 5.1 (Get-Content -Raw | Set-Content -Encoding UTF8) lit un fichier
UTF-8 avec la page ANSI locale puis le reecrit en UTF-8. Chaque caractere non
ASCII est alors encode deux fois. On inverse exactement cette transformation.

Les 5 crans non definis de CP1252 (0x81, 0x8D, 0x8F, 0x90, 0x9D) sont traites
a part, sinon l'encode echoue la ou PowerShell avait insere un caractere C1.
"""

from __future__ import annotations

import sys
from pathlib import Path

INDEFINIS = {"\x81", "\x8d", "\x8f", "\x90", "\x9d"}


def _vers_cp1252(texte: str) -> bytes:
    """Encode en CP1252 en renvoyant les crans non definis tels quels."""
    out = bytearray()
    for ch in texte:
        if ch in INDEFINIS:
            out.append(ord(ch))
            continue
        out.extend(ch.encode("cp1252"))
    return bytes(out)


def reparer(chemin: Path) -> tuple[bool, bool]:
    brut = chemin.read_bytes()
    avait_bom = brut[:3] == b"\xef\xbb\xbf"
    texte = brut.decode("utf-8-sig")
    casse = "\u00c3" in texte or "\u00e2\u20ac" in texte

    if casse:
        texte = _vers_cp1252(texte).decode("utf-8")  # leve si un bout n'etait pas double

    # Une source Python ne porte pas de BOM.
    chemin.write_bytes(texte.encode("utf-8"))

    reste = texte.count("\u00c3") + texte.count("\u00e2\u20ac")
    return casse, reste == 0 and not avait_bom or reste == 0


def main(cibles: list[str]) -> int:
    echecs = 0
    for nom in cibles:
        chemin = Path(nom)
        try:
            casse, propre = reparer(chemin)
        except (UnicodeEncodeError, UnicodeDecodeError) as exc:
            print(f"  {nom:24} IMPOSSIBLE : {exc}")
            echecs += 1
            continue
        etat = "double-encodage corrige" if casse else "BOM retire"
        print(f"  {nom:24} {etat:26} propre={propre}")
        if not propre:
            echecs += 1
    return 1 if echecs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
