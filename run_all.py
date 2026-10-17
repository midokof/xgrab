"""Lance toute la suite de tests et resume les resultats."""

from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent

# Tests qui exigent une URL en argument.
NEEDS_URL = {"test_download.py", "test_no_console.py", "test_autocapture.py",
             "test_capture.py", "test_no_console_hls.py"}

# Tests qui pilotent une instance XGrab : ils ne doivent pas tourner en
# parallele avec un autre test d'interface.
PORNHUB = "https://fr.pornhub.com/view_video.php?viewkey=6ac55a667d76f"
YOUTUBE = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
# La capture CDP se teste sur une adresse MP4 directe : le lecteur de
# Pornhub ne demarre pas en headless et rendrait le test instable.
SAMPLE_MP4 = "https://download.samplelib.com/mp4/sample-5s.mp4"

URLS = {
    "test_download.py": PORNHUB,
    "test_no_console.py": PORNHUB,
    "test_no_console_hls.py": YOUTUBE,
    "test_autocapture.py": PORNHUB,
    "test_capture.py": SAMPLE_MP4,
}

SKIP = {"test_pipeline_proto.py"}

# Navigateurs lances par la capture CDP : s'ils survivent a un test, le
# suivant trouve le port de debug deja occupe et echoue.
BROWSERS = ("msedge", "chrome", "brave", "firefox")


def kill_browsers() -> None:
    for name in BROWSERS:
        subprocess.run(
            ["taskkill", "/F", "/IM", f"{name}.exe", "/T"],
            capture_output=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )


def run(name: str) -> tuple[str, int, float, str]:
    path = ROOT / name
    args = [sys.executable, name]
    if name in NEEDS_URL:
        args.append(URLS[name])

    # test_download telecharge un fichier reel puis le reprend : il lui faut
    # plus de temps que les autres.
    budget = 900 if name == "test_download.py" else 420

    if name in ("test_capture.py", "test_autocapture.py", "test_retry.py", "test_no_console.py"):
        kill_browsers()
        time.sleep(2)

    started = time.monotonic()
    try:
        proc = subprocess.run(
            args,
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=budget,
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        code = proc.returncode
    except subprocess.TimeoutExpired:
        out = f"DELAI DEPASS ({budget} s)"
        code = -1
    finally:
        kill_browsers()
    return name, code, time.monotonic() - started, out


if __name__ == "__main__":
    tests = sorted(p.name for p in ROOT.glob("test_*.py") if p.name not in SKIP)

    results = []
    for name in tests:
        results.append(run(name))

    ok = [r for r in results if r[1] == 0]
    ko = [r for r in results if r[1] != 0]

    print("=" * 66)
    print(f"{len(ok)}/{len(results)} tests reussis")
    print("=" * 66)
    for name, code, elapsed, _out in results:
        flag = "OK  " if code == 0 else "ECHEC"
        print(f"{flag}  {elapsed:6.1f}s  {name}")

    if ko:
        print("\n" + "=" * 66)
        print("DETAIL DES ECHECS")
        print("=" * 66)
        for name, code, _elapsed, out in ko:
            print(f"\n--- {name} (code {code}) ---")
            lines = [line for line in out.splitlines() if line.strip()]
            for line in lines[-16:]:
                print("   " + line)

    sys.exit(1 if ko else 0)
