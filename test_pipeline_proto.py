"""Prototype : ffmpeg rawvideo -> tk.PhotoImage, mesure de debit."""

from __future__ import annotations

import subprocess
import tempfile
import time
from pathlib import Path

import tkinter as tk

from xgrab.downloader import find_ffmpeg
from xgrab.utils import hidden_popen_kwargs

W, H, FPS = 640, 360, 25

video = Path(tempfile.gettempdir()) / "xgrab_framechk" / "test.mp4"
if not video.exists():
    raise SystemExit(f"video de test absent : {video}")

root = tk.Tk()
root.withdraw()
label = tk.Label(root, bg="#000000")
label.pack()

header = f"P6\n{W} {H}\n255\n".encode()
size = W * H * 3

cmd = [
    find_ffmpeg(), "-hide_banner", "-loglevel", "error", "-nostdin",
    "-i", str(video),
    "-vf", f"fps={FPS},scale={W}:{H}:force_original_aspect_ratio=decrease,pad={W}:{H}:-1:-1:black",
    "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
]

proc = subprocess.Popen(
    cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0, **hidden_popen_kwargs()
)

count = 0
bad = 0
start = time.monotonic()
while True:
    chunks = []
    remaining = size
    while remaining > 0:
        block = proc.stdout.read(remaining)
        if not block:
            break
        chunks.append(block)
        remaining -= len(block)
    if remaining > 0:
        break
    frame = b"".join(chunks)

    photo = tk.PhotoImage(data=header + frame, master=root)
    label.configure(image=photo)
    count += 1

    if count >= 120:
        break

proc.kill()
proc.wait()
elapsed = time.monotonic() - start

print(f"imagesdecodees : {count}")
print(f"duree          : {elapsed:.2f} s")
print(f"cadence        : {count / elapsed:.1f} images/s")
print(f"debit          : {count * size / elapsed / 1024 / 1024:.1f} Mo/s")
print(f"taille image   : {photo.width()}x{photo.height()}")
root.destroy()

if count < 30:
    raise SystemExit("ECHEC : trop peu d'images")
print("\nPIPELINE OK")
