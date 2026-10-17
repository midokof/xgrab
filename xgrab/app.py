from __future__ import annotations

import ctypes
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import traceback
from pathlib import Path
from tkinter import filedialog, messagebox as _tk_messagebox, ttk

from .i18n import translate_log as _translate_log


class _TranslatedMessageBox:
    """Traduit les textes des boites de dialogue avant l'affichage.

    Les appels existants contin��ent d'ecrire messagebox.showinfo(...) : ce
    mandataire se contente de traduire chaque argument textuel, ce qui evite
    de dupliquer 9 traductions a chaque site d'appel.
    """

    def __getattr__(self, name):
        cible = getattr(_tk_messagebox, name)
        if not callable(cible):
            return cible

        def proxy(*args, **kwargs):
            traduits = tuple(
                _translate_log(a) if isinstance(a, str) else a for a in args
            )
            return cible(*traduits, **kwargs)

        return proxy


messagebox = _TranslatedMessageBox()

from typing import Optional
from urllib.parse import urlparse

import requests
import tkinter as tk

from . import APP_NAME, __version__
from . import webpage
from .capture import CaptureError as _CaptureError
from .capture import capture as capture_capture
from .downloader import (
    DownloadResult,
    Downloader,
    Interrupted,
    MediaRefused,
    Progress,
)
from .i18n import detect_system_language, set_language, tr
from .resolver import MediaInfo, ResolutionError, Variant, resolve
from .server import BridgeServer, lan_address, write_bridge_config
from .utils import human_rate, human_size, human_time, parse_many_urls, parse_template, unique_path
from .widgets import RoundedButton

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(1)
except Exception:
    pass

BG = "#f7f8fa"
SURFACE = "#ffffff"
SURFACE_2 = "#f1f3f7"
SURFACE_3 = "#e9ecf2"
BORDER = "#e3e6ec"
TEXT = "#16181d"
MUTED = "#6b7280"
ACCENT = "#4d90fe"
ACCENT_HOVER = "#6aa2ff"
ACCENT_DARK = "#2f5bb7"
ACCENT_SOFT = "#eaf1fe"
GOOD = "#1e9e6a"
WARN = "#d97706"
BAD = "#dc3545"

FONT = "Segoe UI"
MONO = "Consolas"
SYMBOL_FONT = "Segoe UI Symbol"

THUMB_W = 168
THUMB_H = 95

CONFIG_DIR = Path(os.environ.get("APPDATA", Path.home())) / "XGrab"


BLOCK_STATUS = (401, 403, 405, 429, 451, 470, 503)

# Pause avant chaque palier d'escalade. Leger pour la re-analyse, plus long
# avant d'ouvrir un navigateur.
ESCALATION_DELAY_MS = 4000

MEDIA_URL_RE = re.compile(r"\.(m3u8|mp4|m4v|webm|mov|mkv)(?:[/?#]|$)", re.IGNORECASE)
HEIGHT_URL_RE = re.compile(r"(?:^|[/_-])(\d{3,4})p(?:[/_.-]|\?|$)", re.IGNORECASE)


def direct_variant(url: str) -> Variant:
    """Construit une variante unique depuis une URL de media directe."""
    match = HEIGHT_URL_RE.search(url)
    height = int(match.group(1)) if match else 0
    if not height:
        for token in re.findall(r"(\d{3,4})", url):
            candidate = int(token)
            if 144 <= candidate <= 4320:
                height = candidate
                break

    path = urlparse(url).path
    suffix = Path(path).suffix.lower()
    ext = {".m3u8": "mp4", ".webm": "webm", ".mov": "mov", ".mkv": "mkv"}.get(suffix, "mp4")
    kind = "hls" if suffix == ".m3u8" else "http"

    return Variant(
        label=f"{height}p" if height else "source",
        url=url,
        ext=ext,
        kind=kind,
        height=height,
        bitrate=0,
        size=None,
        size_known=False,
    )



def _block_label(detail: object) -> str:
    """Libelle court du blocage : code HTTP quand il existe, sinon le motif.

    Un refus arrive souvent avec un code 200 et un corps de protection : le
    code ne dit rien, et il ne faut jamais ecrire "HTTP <phrase entiere>".
    """
    if isinstance(detail, int):
        return f"HTTP {detail}"
    return "Refus du site"


def is_blocked(status: int) -> bool:
    """Codes renvoyes par les protections anti-robot (dont le 470 de Cloudflare)."""
    return status in BLOCK_STATUS


class XGrabApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title(f"{APP_NAME} {__version__}")
        self.configure(bg=BG)
        self.needed_height = 0

        self.config_path = CONFIG_DIR / "config.json"
        self.settings = self._load_config()

        self.out_var = tk.StringVar()
        self.tpl_var = tk.StringVar()
        self.auto_var = tk.BooleanVar()
        self.url_var = tk.StringVar()
        self.cookies_var = tk.StringVar()
        self.browser_var = tk.StringVar(value="aucun")
        # Ecoute sur le reseau local : uniquement si l'utilisateur l'active.
        self.lan_var = tk.BooleanVar(value=bool(self.settings.get("allow_lan")))
        self.lan_info = tk.StringVar()

        self.queue: queue.Queue = queue.Queue()
        self.jobs: dict[str, dict] = {}
        # Pause avant chaque palier d'escalade. Les tests la mettent a zero.
        self.escalation_delay_ms = ESCALATION_DELAY_MS
        self.current: str | None = None
        self.cancel_event: threading.Event | None = None
        self.busy = False
        self.paused: set[str] = set()
        self.bridge: Optional[BridgeServer] = None

        self._style()
        self._build()
        self._fit_to_screen()
        self._load_defaults()
        self._refresh_count()
        self._on_select()
        self._start_bridge()

        self._closing = False
        self._after_ids: list[str] = []

        self._after(60, self._poll)
        self._after(250, self._smart_clipboard)
        self.protocol("WM_DELETE_WINDOW", self._on_close)

    def _after(self, delay: int, func, *args) -> Optional[str]:
        """after() sururbille : ignore les appels posterieurs a la fermeture.

        Tk leve "invalid command name" si un callback planifie revient apres
        destroy(), ce qui se produit quand un thread termine pendant la sortie.
        """
        if self._closing:
            return None
        try:
            ident = self.after(delay, func, *args)
        except tk.TclError:
            return None
        if ident:
            self._after_ids.append(ident)
            if len(self._after_ids) > 200:
                self._after_ids.pop(0)
        return ident

    def _start_bridge(self) -> None:
        """Demarre le serveur local utilise par l'extension navigateur."""
        allow_lan = bool(self.lan_var.get())
        self.bridge = BridgeServer(
            on_add=lambda urls, referer: self.queue.put(("bridge_add", urls, referer)),
            on_status=lambda message: self.queue.put(("log", message, "hi")),
            allow_lan=allow_lan,
        )
        port = self.bridge.start()
        if not port:
            self._log("Port du navigateur indisponible", "warn")
            return

        written = write_bridge_config(port, self.bridge.token)
        where = written[0] if written else "nulle part"
        self._log(f"Extension navigateur : port {port} ({where})", "ok")
        self.settings["allow_lan"] = allow_lan
        self._save_config()
        self._refresh_lan_info(port)

    def _refresh_lan_info(self, port: int) -> None:
        """Affiche l'adresse et le jeton a recopier dans l'app iPhone."""
        if not self.lan_var.get():
            self.lan_info.set("Accès iPhone désactivé")
            return
        address = lan_address()
        if not address:
            self.lan_info.set("Access iPhone actif, mais aucune adresse réseau trouvée")
            return
        self.lan_info.set(f"iPhone : {address}:{port}   jeton : {self.bridge.token}")

    def _on_lan_toggle(self) -> None:
        """Le bind se fait au demarrage : on memorise et on invite a relancer."""
        self.settings["allow_lan"] = bool(self.lan_var.get())
        self._save_config()
        if self.lan_var.get():
            self.lan_info.set("Redémarre XGrab pour appliquer")
            self._log("Accès iPhone activé au prochain démarrage", "warn")
        else:
            self.lan_info.set("Accès iPhone désactivé")
            self._log("Accès iPhone désactivé au prochain démarrage", "warn")

    def _bridge_add(self, urls: list[str], referer: str = "") -> None:
        """Recoit des liens de l'extension et les ajoute a la file."""
        if self.busy:
            self._log("Téléchargement en cours, lien mis en attente", "warn")

        for url in urls:
            if MEDIA_URL_RE.search(url):
                self._add_direct(url, referer)
            else:
                before = set(self.jobs)
                self.url_var.set(url)
                self._add()
                for iid in set(self.jobs) - before:
                    self.jobs[iid]["from_bridge"] = True

        self._after(600, self._bridge_pump)

    def _add_direct(self, url: str, referer: str = "") -> None:
        """Ajoute un lien media deja resolu, sans passer par l'analyse."""
        variant = direct_variant(url)
        if referer:
            variant.referer = referer
        cookies = self.cookies_var.get().strip()
        if cookies and not variant.cookies:
            variant.cookies = cookies

        iid = self.tree.insert("", "end", values=("analyse...", "", "", "", ""), tags=("idle",))
        self.jobs[iid] = {
            "url": url,
            "status": "pending",
            "variants": [variant],
            "progress": 0.0,
            "auto": False,
            "cookies": cookies,
            "browser": "",
            "title": Path(urlparse(url).path).name or "media",
            "author": "",
            "tweet_id": "",
            "duration": "",
            "extractor": "extension",
            "status_label": tr("st.resolving"),
            "direct": True,
            "probed": False,
            "referer": referer,
        }
        self.tree.selection_set(iid)
        self._on_select()
        self._refresh_count()
        threading.Thread(target=self._probe_direct, args=(iid, variant), daemon=True).start()

    def _probe_direct(self, iid: str, variant: Variant) -> None:
        """Recupere la taille par HEAD, puis rend le job pret."""
        size = 0
        try:
            head = requests.head(
                variant.url,
                headers={
                    "User-Agent": webpage.USER_AGENT,
                    **variant.request_headers(),
                },
                allow_redirects=True,
                timeout=20,
            )
            length = head.headers.get("Content-Length")
            content_type = head.headers.get("Content-Type", "")
            if length and length.isdigit() and "video" in content_type:
                size = int(length)
            elif length and length.isdigit() and int(length) > 1024:
                size = int(length)
        except requests.RequestException:
            size = 0

        self.queue.put(("bridge_probed", iid, size))

    def _bridge_probed(self, iid: str, size: int) -> None:
        job = self.jobs.get(iid)
        if not job:
            return
        variant: Variant | None = (job.get("variants") or [None])[0]
        if variant:
            variant.size = size or None
            variant.size_known = bool(size)
        job["status"] = "pending"
        job["status_label"] = tr("st.ready")
        job["probed"] = True
        self.tree.item(
            iid,
            values=(
                job["title"][:48],
                variant.height_label if variant else "",
                human_size(size) if size else "?",
                "0 %",
                tr("st.ready"),
            ),
            tags=("idle",),
        )
        self._refresh_count()
        if iid == self.current:
            self._on_select()
        self._bridge_pump()

    def _bridge_pump(self) -> None:
        """Demarre le premier lien du navigateur pret, si rien ne tourne."""
        if self.busy:
            return
        for iid, job in self.jobs.items():
            if job.get("status") != "pending" or not job.get("variants"):
                continue
            if job.get("direct"):
                if not job.get("probed"):
                    continue
            elif not job.get("from_bridge"):
                continue
            self.tree.selection_set(iid)
            self.current = iid
            self._on_select()
            self._start()
            return

    def _fit_to_screen(self) -> None:
        self.update_idletasks()

        def pad(value) -> int:
            if isinstance(value, (tuple, list)):
                parts = list(value)
            elif isinstance(value, str):
                parts = value.replace("(", " ").replace(")", " ").replace(",", " ").split()
            elif value in ("", None):
                parts = []
            else:
                parts = [value]
            total = 0
            for part in parts:
                try:
                    total += int(part)
                except (TypeError, ValueError):
                    pass
            return total

        screen_w = ctypes.windll.user32.GetSystemMetrics(0)
        screen_h = ctypes.windll.user32.GetSystemMetrics(1)
        available = screen_h - 80

        def measure() -> int:
            self.update_idletasks()
            total = 0
            for child in self.winfo_children():
                try:
                    info = child.pack_info()
                except tk.TclError:
                    continue
                total += child.winfo_reqheight() + pad(info.get("pady")) + pad(info.get("padx"))
            return total

        needed = measure()
        if needed > available and self.log_body.winfo_ismapped():
            self._toggle_log()
            needed = measure()
        if needed > available and self.batch.winfo_ismapped():
            self._toggle_batch()
            needed = measure()

        width = max(880, min(1180, screen_w - 60))
        height = max(560, min(needed, available))

        for _ in range(4):
            x = max(0, (screen_w - width) // 2)
            y = max(0, (screen_h - height) // 2 - 20)
            self.geometry(f"{width}x{height}+{x}+{y}")
            self.update_idletasks()
            settled = min(measure(), available)
            if settled == height:
                break
            height = max(560, settled)

        self.minsize(880, 560)
        self.needed_height = min(needed, available)

    # ------------------------------------------------------------------ config

    def _load_config(self) -> dict:
        defaults = {
            "out_dir": str(Path.home() / "Downloads"),
            "template": "{title}_{quality}",
            "autostart": True,
        }
        try:
            if self.config_path.exists():
                defaults.update(json.loads(self.config_path.read_text("utf-8")))
        except (OSError, ValueError):
            pass
        return defaults

    def _save_config(self) -> None:
        try:
            CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            self.config_path.write_text(
                json.dumps(self.settings, indent=2, ensure_ascii=False), "utf-8"
            )
        except OSError:
            pass

    def _load_defaults(self) -> None:
        self.out_var.set(self.settings.get("out_dir", ""))
        self.tpl_var.set(self.settings.get("template", "{title}_{quality}"))
        self.auto_var.set(bool(self.settings.get("autostart", True)))
        self.cookies_var.set(self.settings.get("cookies", ""))
        self.browser_var.set(self.settings.get("browser", "aucun"))
        self._update_preview()

    # ------------------------------------------------------------------ theme

    def _style(self) -> None:
        style = ttk.Style(self)
        style.theme_use("clam")

        style.configure(".", background=BG, foreground=TEXT, font=(FONT, 10))
        style.configure("TFrame", background=BG)
        style.configure("Card.TFrame", background=SURFACE)
        style.configure("Card2.TFrame", background=SURFACE_2)
        style.configure("Header.TFrame", background=SURFACE)
        style.configure("TLabel", background=BG, foreground=TEXT)
        style.configure("Card.TLabel", background=SURFACE, foreground=TEXT)
        style.configure("Card2.TLabel", background=SURFACE_2, foreground=TEXT)
        style.configure("Muted.TLabel", background=BG, foreground=MUTED)
        style.configure("CardMuted.TLabel", background=SURFACE, foreground=MUTED)
        style.configure(
            "H1.TLabel", background=SURFACE, foreground=TEXT, font=(FONT, 19, "bold")
        )
        style.configure(
            "H2.TLabel", background=SURFACE, foreground=TEXT, font=(FONT, 11, "bold")
        )
        style.configure(
            "Tiny.TLabel", background=BG, foreground=MUTED, font=(FONT, 8)
        )
        style.configure(
            "CardTiny.TLabel", background=SURFACE, foreground=MUTED, font=(FONT, 8)
        )

        style.configure(
            "TEntry",
            fieldbackground=SURFACE,
            background=SURFACE,
            foreground=TEXT,
            insertcolor=TEXT,
            bordercolor=BORDER,
            lightcolor=BORDER,
            darkcolor=BORDER,
            padding=(12, 10),
            relief="flat",
        )
        style.map("TEntry", bordercolor=[("focus", ACCENT)])

        style.configure(
            "TCombobox",
            fieldbackground=SURFACE,
            background=SURFACE,
            foreground=TEXT,
            arrowcolor=MUTED,
            bordercolor=BORDER,
            lightcolor=BORDER,
            darkcolor=BORDER,
            padding=(12, 9),
            relief="flat",
        )
        style.map(
            "TCombobox",
            fieldbackground=[("readonly", SURFACE)],
            bordercolor=[("focus", ACCENT)],
            arrowcolor=[("active", ACCENT)],
        )
        self.option_add("*TCombobox*Listbox.background", SURFACE)
        self.option_add("*TCombobox*Listbox.foreground", TEXT)
        self.option_add("*TCombobox*Listbox.selectBackground", ACCENT)
        self.option_add("*TCombobox*Listbox.selectForeground", "#ffffff")
        self.option_add("*TCombobox*Listbox.font", (FONT, 10))

        style.configure(
            "TButton",
            background=SURFACE_2,
            foreground=TEXT,
            bordercolor=BORDER,
            lightcolor=BORDER,
            darkcolor=BORDER,
            padding=(14, 8),
            font=(FONT, 10),
            relief="flat",
        )
        style.map(
            "TButton",
            background=[("active", SURFACE_3)],
            bordercolor=[("active", ACCENT)],
        )

        style.configure(
            "Ghost.TButton",
            background=SURFACE,
            foreground=ACCENT,
            bordercolor=SURFACE,
            lightcolor=SURFACE,
            darkcolor=SURFACE,
            padding=(12, 7),
            font=(FONT, 9),
        )
        style.map("Ghost.TButton", background=[("active", ACCENT_SOFT)])

        style.configure(
            "Treeview",
            background=SURFACE,
            fieldbackground=SURFACE,
            foreground=TEXT,
            rowheight=34,
            bordercolor=BORDER,
            lightcolor=BORDER,
            darkcolor=BORDER,
            font=(FONT, 9),
        )
        style.map(
            "Treeview",
            background=[("selected", ACCENT_SOFT)],
            foreground=[("selected", ACCENT_DARK)],
        )
        style.configure(
            "Treeview.Heading",
            background=SURFACE_2,
            foreground=MUTED,
            bordercolor=BORDER,
            lightcolor=BORDER,
            darkcolor=BORDER,
            font=(FONT, 8, "bold"),
            relief="flat",
        )
        style.map("Treeview.Heading", background=[("active", SURFACE_3)])

        style.configure(
            "X.Horizontal.TProgressbar",
            background=ACCENT,
            troughcolor=SURFACE_3,
            bordercolor=SURFACE_3,
            lightcolor=ACCENT,
            darkcolor=ACCENT,
            thickness=6,
        )

        style.configure(
            "Vertical.TScrollbar",
            background=SURFACE_3,
            troughcolor=SURFACE,
            bordercolor=SURFACE,
            arrowcolor=MUTED,
            width=12,
        )
        style.map("Vertical.TScrollbar", background=[("active", "#d8dde7")])

        style.configure("TCheckbutton", background=SURFACE, foreground=MUTED, font=(FONT, 9))
        style.map("TCheckbutton", background=[("active", SURFACE)], foreground=[("active", TEXT)])

    def _card(self, parent, **kw) -> ttk.Frame:
        return ttk.Frame(parent, style="Card.TFrame", **kw)

    # ------------------------------------------------------------------ build

    def _build(self) -> None:
        self._build_header()
        self._build_input()
        self._build_queue()
        self._build_detail()
        self._build_log()

    def _build_header(self) -> None:
        header = ttk.Frame(self, style="Header.TFrame", padding=(22, 12))
        header.pack(fill="x", side="top")

        ttk.Label(header, text="▼  XGrab", style="H1.TLabel").pack(side="left")

        tk.Frame(self, bg=ACCENT, height=2).pack(fill="x")

    def _build_input(self) -> None:
        card = self._card(self, padding=(18, 12))
        card.pack(fill="x", padx=16, pady=(14, 10))

        head = ttk.Frame(card, style="Card.TFrame")
        head.pack(fill="x")

        ttk.Label(head, text=tr("ui.link"), style="Card.TLabel", font=(FONT, 8, "bold")).pack(side="left")

        bar = ttk.Frame(card, style="Card.TFrame")
        bar.pack(fill="x", pady=(8, 0))
        self.ent_url = ttk.Entry(bar, textvariable=self.url_var, font=(MONO, 10))
        self.ent_url.pack(side="left", fill="x", expand=True)
        self.ent_url.bind("<Return>", lambda _e: self._add())
        self.ent_url.bind("<KP_Enter>", lambda _e: self._add())

        self.btn_add = RoundedButton(
            bar,
            text=tr("ui.add"),
            command=self._add,
            fill=ACCENT,
            hover=ACCENT_HOVER,
            foreground="#ffffff",
            parent_bg=SURFACE,
        )
        self.btn_add.pack(side="left", padx=(10, 0))

        self.btn_batch = ttk.Button(
            card, text=tr("ui.more"), style="Ghost.TButton", command=self._toggle_batch
        )
        self.btn_batch.pack(anchor="w", pady=(8, 0))

        self.batch = ttk.Frame(card, style="Card.TFrame")

        bottom = ttk.Frame(self.batch, style="Card.TFrame")
        bottom.pack(fill="x", pady=(8, 0))

        ttk.Label(bottom, text=tr("ui.multiple"), style="CardMuted.TLabel", font=(FONT, 8, "bold")).pack(
            side="left", padx=(0, 10), pady=(4, 0)
        )
        ttk.Button(
            bottom, text=tr("ui.mix"), style="Ghost.TButton", command=self._add_all
        ).pack(side="right")
        ttk.Button(
            bottom, text=tr("ui.wipe"), style="Ghost.TButton", command=lambda: self.txt_links.delete("1.0", "end")
        ).pack(side="right", padx=(0, 8))

        wrap = tk.Frame(self.batch, bg=BORDER, height=54)
        wrap.pack(fill="x", pady=(6, 0))
        wrap.pack_propagate(False)

        self.txt_links = tk.Text(
            wrap,
            bg=SURFACE,
            fg=TEXT,
            insertbackground=TEXT,
            relief="flat",
            font=(MONO, 10),
            wrap="char",
            padx=12,
            pady=10,
            highlightthickness=1,
            highlightbackground=BORDER,
            highlightcolor=ACCENT,
        )
        self.txt_links.pack(fill="both", expand=True)
        self.txt_links.bind("<Control-Return>", lambda _e: self._add_all())

        opts = ttk.Frame(self.batch, style="Card.TFrame")
        opts.pack(fill="x", pady=(10, 0))
        ttk.Label(opts, text=tr("ui.cookies"), style="CardMuted.TLabel", font=(FONT, 8, "bold")).pack(
            side="left", padx=(0, 10), pady=(4, 0)
        )
        self.ent_cookies = ttk.Entry(opts, textvariable=self.cookies_var)
        self.ent_cookies.pack(side="left", fill="x", expand=True)
        self.btn_capture = ttk.Button(opts, text=tr("ui.capture"), style="Ghost.TButton", command=self._capture)
        self.btn_capture.pack(side="left", padx=(8, 0))
        self.btn_test = ttk.Button(opts, text=tr("ui.verify"), style="Ghost.TButton", command=self._test)
        self.btn_test.pack(side="left", padx=(6, 0))
        ttk.Button(opts, text=tr("ui.erase"), style="Ghost.TButton", command=self._clear_cookies).pack(
            side="left", padx=(6, 0)
        )

        row3 = ttk.Frame(self.batch, style="Card.TFrame")
        row3.pack(fill="x", pady=(8, 0))
        ttk.Label(
            row3,
            text="Capturer ouvre Edge/Chrome et intercepte la vraie requête vidéo (méthode IDM)",
            style="CardMuted.TLabel",
            font=(FONT, 8),
        ).pack(side="left")

        row4 = ttk.Frame(self.batch, style="Card.TFrame")
        row4.pack(fill="x", pady=(8, 0))
        ttk.Checkbutton(
            row4,
            text="Accès iPhone (écoute sur le réseau local)",
            variable=self.lan_var,
            command=self._on_lan_toggle,
        ).pack(side="left")
        ttk.Label(
            row4,
            textvariable=self.lan_info,
            style="CardMuted.TLabel",
            font=(FONT, 8),
        ).pack(side="left", padx=(10, 0))

        row2 = ttk.Frame(self.batch, style="Card.TFrame")
        row2.pack(fill="x", pady=(8, 0))
        ttk.Label(row2, text=tr("ui.browser"), style="CardMuted.TLabel", font=(FONT, 8, "bold")).pack(
            side="left", padx=(0, 10)
        )
        self.cmb_browser = ttk.Combobox(
            row2,
            state="readonly",
            width=14,
            values=["aucun", "chrome", "firefox", "edge", "brave", "opera", "vivaldi", "chromium"],
            textvariable=self.browser_var,
        )
        self.cmb_browser.pack(side="left")
        ttk.Label(
            row2,
            text="utilisé par yt-dlp pour les sites protégés par âge",
            style="CardMuted.TLabel",
            font=(FONT, 8),
        ).pack(side="left", padx=(10, 0))

    def _clear_cookies(self) -> None:
        self.cookies_var.set("")
        self._log("Cookies effacés", "warn")

    def _target_url(self) -> str:
        job = self.jobs.get(self.current or "")
        url = (job.get("url") or "").strip() if job else ""
        if not url:
            url = self.url_var.get().strip()
        if not url:
            for line in self.txt_links.get("1.0", "end").strip().splitlines():
                found = parse_many_urls(line)
                if found:
                    url = found[0]
                    break
        return url

    def _capture(self) -> None:
        url = self._target_url()
        if not url:
            messagebox.showinfo(APP_NAME, "Aucun lien à capturer.")
            return

        self.btn_capture.configure(state="disabled")
        self._log(f"Capture navigateur : {url}", "hi")
        threading.Thread(target=self._capture_worker, args=(url,), daemon=True).start()

    def _capture_worker(self, url: str, iid: str = "") -> None:
        try:
            variants = capture_capture(url, on_log=lambda m: self.queue.put(("log", m, "info")))
        except _CaptureError as exc:
            self.queue.put(("capture_failed", iid, str(exc)))
            return
        except Exception as exc:  # noqa: BLE001
            self.queue.put(("capture_failed", iid, f"capture impossible : {exc}"))
            return

        if not variants:
            self.queue.put(("capture_failed", iid, "aucune requête vidéo interceptée"))
            return

        if iid and iid in self.jobs:
            self.queue.put(("capture_variants", iid, variants, True))
        else:
            self.queue.put(("capture_variants", self.current or "", variants, False))

    def _test(self) -> None:
        url = self._target_url()
        if not url:
            messagebox.showinfo(APP_NAME, "Aucun lien à vérifier.")
            return

        cookies = self.cookies_var.get().strip()
        self.btn_test.configure(state="disabled")
        self._log(
            f"Vérification de {url}\n     cookies : {len(cookies)} caractère(s)",
            "hi",
        )
        threading.Thread(target=self._test_worker, args=(url, cookies), daemon=True).start()

    def _test_worker(self, url: str, cookies: str) -> None:
        try:
            info = resolve(url, with_sizes=False, cookies=cookies)
        except ResolutionError as exc:
            self.queue.put(("test_done", None, f"Analyse impossible : {exc}"))
            return

        self.queue.put(("test_info", info))

        variant = info.variants[0] if info.variants else None
        if not variant:
            self.queue.put(("test_done", None, "Aucune variante détectée."))
            return

        self.queue.put(
            ("log", f"     test sur {variant.height_label} {urlparse(variant.url).netloc}", "info")
        )
        try:
            response = requests.get(
                variant.url,
                headers={"User-Agent": webpage.USER_AGENT, **variant.request_headers()},
                stream=True,
                timeout=25,
                allow_redirects=True,
            )
            length = response.headers.get("Content-Length")
            response.close()
        except requests.RequestException as exc:
            self.queue.put(("test_done", None, f"Erreur réseau : {exc}"))
            return

        status = response.status_code
        if status == 200:
            self.queue.put(
                (
                    "test_done",
                    None,
                    f"OK — {status} · {human_size(int(length)) if length and length.isdigit() else '?'}"
                    f" · téléchargement possible",
                )
            )
        elif is_blocked(status):
            self.queue.put(
                (
                    "test_done",
                    None,
                    f"REFUSÉ — {status}. "
                    + (
                        "Les cookies sont présents mais invalides : reconnecte-toi "
                        "et recopie l'en-tête Cookie de la requête get_file."
                        if cookies
                        else "Aucun cookie fourni : colle l'en-tête Cookie de ton navigateur connecté."
                    ),
                )
            )
        else:
            self.queue.put(("test_done", None, f"HTTP {status}"))

    def _toggle_batch(self) -> None:
        if self.batch.winfo_ismapped():
            self.batch.pack_forget()
            self.btn_batch.configure(text=tr("ui.more_links"))
        else:
            self.batch.pack(fill="x")
            self.btn_batch.configure(text=tr("ui.hide_list"))
            self.txt_links.focus_set()

    def _build_queue(self) -> None:
        card = self._card(self, padding=(18, 12))
        card.pack(fill="both", expand=True, padx=16, pady=(0, 10))

        head = ttk.Frame(card, style="Card.TFrame")
        head.pack(fill="x", pady=(0, 10))
        ttk.Label(head, text=tr("ui.queue"), style="Card.TLabel", font=(FONT, 8, "bold")).pack(side="left")
        self.lbl_count = ttk.Label(head, text="0 élément", style="CardMuted.TLabel", font=(FONT, 9))
        self.lbl_count.pack(side="left", padx=(10, 0), pady=(3, 0))
        columns = ("source", "quality", "size", "progress", "status")
        widths = {"source": 300, "quality": 130, "size": 100, "progress": 150, "status": 130}

        holder = ttk.Frame(card, style="Card.TFrame")
        holder.pack(fill="both", expand=True)

        self.tree = ttk.Treeview(holder, columns=columns, show="headings", selectmode="browse", height=6)
        for col in columns:
            self.tree.heading(col, text=col.capitalize())
            self.tree.column(col, width=widths[col], anchor="w", stretch=(col == "source"))
        self.tree.tag_configure("working", foreground=ACCENT)
        self.tree.tag_configure("done", foreground=GOOD)
        self.tree.tag_configure("error", foreground=BAD)
        self.tree.tag_configure("idle", foreground=TEXT)
        self.tree.tag_configure("paused", foreground=WARN)

        vsb = ttk.Scrollbar(holder, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=vsb.set)
        self.tree.pack(side="left", fill="both", expand=True)
        vsb.pack(side="right", fill="y")

        self.tree.bind("<<TreeviewSelect>>", self._on_select)
        self.tree.bind("<Delete>", lambda _e: self._remove_selected())
        self.tree.bind("<Button-3>", self._show_menu)
        self.menu = tk.Menu(
            self,
            tearoff=False,
            bg=SURFACE_2,
            fg=TEXT,
            activebackground=ACCENT,
            activeforeground="#0b0d12",
            bd=0,
            font=(FONT, 9),
        )
        self.menu.add_command(label="Télécharger", command=lambda: self._start(manual=True))
        self.menu.add_command(label="Stop", command=self._cancel)
        self.menu.add_separator()
        self.menu.add_command(label="Ouvrir le fichier", command=self._open_file)
        self.menu.add_command(label="Ouvrir le dossier", command=self._open_folder)
        self.menu.add_separator()
        self.menu.add_command(label="Supprimer le fichier", command=self._delete_file)
        self.menu.add_command(label="Retirer de la file", command=self._remove_selected)

        self.empty_lbl = ttk.Label(
            holder, text="La file est vide - collez un lien puis cliquez sur Analyser",
            style="CardMuted.TLabel",
            font=(FONT, 10),
        )
        self.empty_lbl.place(relx=0.5, rely=0.5, anchor="center")

    def _build_detail(self) -> None:
        card = self._card(self, padding=(18, 12))
        card.pack(fill="x", padx=16, pady=(0, 10))

        body = ttk.Frame(card, style="Card.TFrame")
        body.pack(fill="x")

        self.thumb_holder = tk.Frame(
            body,
            bg=SURFACE_3,
            width=THUMB_W,
            height=THUMB_H,
            highlightthickness=1,
            highlightbackground=BORDER,
            highlightcolor=BORDER,
        )
        self.thumb_holder.pack(side="left", padx=(0, 14), anchor="n")
        self.thumb_holder.pack_propagate(False)
        self.lbl_thumb = tk.Label(
            self.thumb_holder,
            text="\u25b6",
            bg=SURFACE_3,
            fg="#c2c8d2",
            font=(SYMBOL_FONT, 16),
        )
        self.lbl_thumb.pack(expand=True, fill="both")
        self._thumb_photo: Optional[tk.PhotoImage] = None

        col = ttk.Frame(body, style="Card.TFrame")
        col.pack(side="left", fill="x", expand=True)

        row = ttk.Frame(col, style="Card.TFrame")
        row.pack(fill="x")

        self.lbl_title = ttk.Label(row, text=tr("ui.no_selection"), style="H2.TLabel")
        self.lbl_title.pack(side="left")
        self.lbl_meta = ttk.Label(row, text="", style="CardMuted.TLabel", font=(FONT, 9))
        self.lbl_meta.pack(side="left", padx=(12, 0), pady=(4, 0))

        grid = ttk.Frame(col, style="Card.TFrame")
        grid.pack(fill="x", pady=(12, 0))
        grid.columnconfigure(1, weight=1)
        grid.columnconfigure(4, weight=1)

        label_kw = {"font": (FONT, 9)}

        ttk.Label(grid, text=tr("ui.resolution"), style="CardMuted.TLabel", **label_kw).grid(
            row=0, column=0, sticky="w", padx=(0, 12), pady=(0, 6)
        )
        self.cmb_variant = ttk.Combobox(grid, state="readonly", values=[])
        self.cmb_variant.grid(row=0, column=1, columnspan=4, sticky="ew", pady=(0, 6))
        self.cmb_variant.bind("<<ComboboxSelected>>", lambda _e: self._update_preview())
        self.btn_variant = ttk.Button(grid, text=tr("ui.refresh"), style="Ghost.TButton", command=self._refresh_sizes)
        self.btn_variant.grid(row=0, column=5, sticky="e", padx=(8, 0), pady=(0, 6))

        ttk.Label(grid, text=tr("ui.folder"), style="CardMuted.TLabel", **label_kw).grid(
            row=1, column=0, sticky="w", padx=(0, 12)
        )
        self.ent_dir = ttk.Entry(grid, textvariable=self.out_var)
        self.ent_dir.grid(row=1, column=1, sticky="ew")

        browse_box = ttk.Frame(grid, style="Card.TFrame")
        browse_box.grid(row=1, column=2, sticky="e", padx=(8, 12))
        ttk.Button(browse_box, text=tr("ui.browse"), command=self._browse).pack(side="left")
        ttk.Button(
            browse_box, text=tr("ui.open_folder"), command=self._open_folder
        ).pack(side="left", padx=(6, 0))

        ttk.Label(grid, text=tr("ui.name"), style="CardMuted.TLabel", **label_kw).grid(
            row=1, column=3, sticky="w", padx=(0, 12)
        )
        self.ent_tpl = ttk.Entry(grid, textvariable=self.tpl_var)
        self.ent_tpl.grid(row=1, column=4, sticky="ew")
        self.ent_tpl.bind("<KeyRelease>", lambda _e: self._update_preview())

        self.chk_auto = ttk.Checkbutton(
            grid,
            text=tr("ui.chain"),
            variable=self.auto_var,
            command=self._update_preview,
        )
        self.chk_auto.grid(row=1, column=5, sticky="e", padx=(8, 0))

        prog = ttk.Frame(col, style="Card.TFrame")
        prog.pack(fill="x", pady=(10, 0))
        self.bar = ttk.Progressbar(prog, style="X.Horizontal.TProgressbar", maximum=100, value=0)
        self.bar.pack(fill="x")
        self.lbl_prog = ttk.Label(prog, text="", style="CardMuted.TLabel", font=(MONO, 9))
        self.lbl_prog.pack(side="left", pady=(7, 0))
        self.lbl_state = ttk.Label(prog, text="", style="CardMuted.TLabel", font=(FONT, 9))
        self.lbl_state.pack(side="right", pady=(7, 0))

        actions = ttk.Frame(col, style="Card.TFrame")
        actions.pack(fill="x", pady=(12, 0))

        self.btn_dl = RoundedButton(
            actions,
            text="▼  TELECHARGER",
            command=lambda: self._start(manual=True),
            fill=ACCENT,
            hover=ACCENT_HOVER,
            foreground="#ffffff",
            parent_bg=SURFACE,
        )
        self.btn_dl.pack(side="left")

        self.btn_stop = RoundedButton(
            actions,
            text="■  STOP",
            command=self._cancel,
            fill=BAD,
            hover="#e85a68",
            foreground="#ffffff",
            disabled_fill=SURFACE_3,
            disabled_text="#aeb4bf",
            parent_bg=SURFACE,
            state="disabled",
        )
        self.btn_stop.pack(side="left", padx=(8, 0))

        self.btn_pause = RoundedButton(
            actions,
            text="❚❚  PAUSE",
            command=self._toggle_pause,
            fill=WARN,
            hover="#e68c1b",
            foreground="#ffffff",
            disabled_fill=SURFACE_3,
            disabled_text="#aeb4bf",
            parent_bg=SURFACE,
            state="disabled",
        )
        self.btn_pause.pack(side="left", padx=(8, 0))

        self.btn_open_file = ttk.Button(
            actions, text=tr("ui.open"), command=self._open_file, state="disabled"
        )
        self.btn_open_file.pack(side="left", padx=(8, 0))

        self.btn_del = ttk.Button(
            actions, text=tr("ui.delete"), command=self._delete_file, state="disabled"
        )
        self.btn_del.pack(side="left", padx=(8, 0))

        self.btn_rm = ttk.Button(
            actions, text=tr("ui.remove"), command=self._remove_selected, state="disabled"
        )
        self.btn_rm.pack(side="left", padx=(8, 0))

    def _set_thumb(self, png_path: Optional[Path]) -> None:
        """Affiche une image PNG dans la vignette, ou le placeholder."""
        try:
            if png_path and png_path.exists():
                photo = tk.PhotoImage(master=self, file=str(png_path))
                self._thumb_photo = photo
                self.lbl_thumb.configure(image=photo, text="")
                return
        except tk.TclError:
            self._thumb_photo = None
        self.lbl_thumb.configure(image="", text="\u25b6")

    def _load_thumb(self, url: str, referer: str = "") -> None:
        """Charge la vignette en arriere-plan puis l'affiche."""
        def worker() -> None:
            from . import thumbs

            try:
                path = thumbs.load_thumbnail(
                    url, THUMB_W * 2, THUMB_H * 2, referer=referer
                )
            except Exception:
                path = None
            self.queue.put(("thumb", path))

        threading.Thread(target=worker, daemon=True).start()

    def _refresh_thumb_frame(self, iid: str) -> None:
        """Extrait une image reelle du fichier en cours de telechargement."""
        job = self.jobs.get(iid)
        if not job or self.current != iid:
            return

        target = job.get("thumb_file")
        if not target:
            return

        elapsed = time.monotonic() - job.get("_thumb_at", 0.0)
        if elapsed < 15.0:
            return
        job["_thumb_at"] = time.monotonic()

        progress = job.get("progress") or 0.0
        if progress <= 0.01:
            return

        def worker() -> None:
            from . import thumbs

            try:
                path = thumbs.load_frame(
                    Path(target),
                    (job.get("duration_seconds") or 0) * progress,
                    THUMB_W * 2,
                    THUMB_H * 2,
                )
            except Exception:
                path = None
            if path:
                self.queue.put(("thumb", path))

        threading.Thread(target=worker, daemon=True).start()

    def _build_log(self) -> None:
        self.log_card = self._card(self, padding=(18, 12))
        self.log_card.pack(fill="x", padx=16, pady=(0, 16))

        head = ttk.Frame(self.log_card, style="Card.TFrame")
        head.pack(fill="x")
        ttk.Label(head, text=tr("ui.journal"), style="Card.TLabel", font=(FONT, 8, "bold")).pack(side="left")
        ttk.Button(head, text=tr("ui.erase"), style="Ghost.TButton", command=self._clear_log).pack(side="right")
        self.btn_log = ttk.Button(
            head, text=tr("ui.hide"), style="Ghost.TButton", command=self._toggle_log
        )
        self.btn_log.pack(side="right", padx=(0, 8))

        self.log_body = ttk.Frame(self.log_card, style="Card.TFrame")
        self.log_body.pack(fill="x")

        self.log = tk.Text(
            self.log_body,
            height=3,
            bg=SURFACE_2,
            fg="#4b5563",
            relief="flat",
            font=(MONO, 9),
            wrap="none",
            padx=12,
            pady=10,
            highlightthickness=1,
            highlightbackground=BORDER,
            highlightcolor=ACCENT,
        )
        self.log.pack(fill="x", pady=(8, 0))
        self.log.tag_configure("ok", foreground=GOOD)
        self.log.tag_configure("warn", foreground=WARN)
        self.log.tag_configure("err", foreground=BAD)
        self.log.tag_configure("hi", foreground=ACCENT_DARK)
        self.log.configure(state="disabled")

    def _toggle_log(self) -> None:
        if self.log_body.winfo_ismapped():
            self.log_body.pack_forget()
            self.btn_log.configure(text=tr("ui.show"))
        else:
            self.log_body.pack(fill="x")
            self.btn_log.configure(text=tr("ui.hide"))

    # ------------------------------------------------------------------ helpers

    def _log(self, message: str, level: str = "info") -> None:
        import datetime

        from .i18n import translate_log

        stamp = datetime.datetime.now().strftime("%H:%M:%S")
        self.log.configure(state="normal")
        self.log.insert("end", f"[{stamp}] {translate_log(message)}\n", level)
        self.log.see("end")
        self.log.configure(state="disabled")

    def _clear_log(self) -> None:
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")

    def _smart_clipboard(self) -> None:
        try:
            text = self.clipboard_get()
        except tk.TclError:
            return
        urls = parse_many_urls(text)
        if urls and not self.url_var.get():
            self.url_var.set(urls[0])
            self._log(f"Lien détecté dans le presse-papiers, Entrée pour l'ajouter", "hi")

    def _clear_done(self) -> None:
        if self.busy:
            messagebox.showwarning(APP_NAME, "Un téléchargement est en cours.")
            return
        for iid in [i for i in self.jobs if self.jobs[i]["status"] != "working"]:
            self.tree.delete(iid)
            self.jobs.pop(iid, None)
        if self.current and self.current not in self.jobs:
            self.current = None
        self._refresh_count()
        self._on_select()

    def _remove_selected(self) -> None:
        if not self.current:
            return
        if self.jobs.get(self.current, {}).get("status") == "working":
            return
        self.tree.delete(self.current)
        self.jobs.pop(self.current, None)
        self.current = None
        self._refresh_count()
        self._on_select()

    def _refresh_count(self) -> None:
        total = len(self.jobs)
        pending = sum(1 for j in self.jobs.values() if j["status"] == "pending")
        self.lbl_count.configure(text=f"{total} élément(s), {pending} en attente")
        if total:
            self.empty_lbl.place_forget()
        else:
            self.empty_lbl.place(relx=0.5, rely=0.5, anchor="center")

    def _open_folder(self) -> None:
        target = Path(self.out_var.get() or str(Path.home()))
        target.mkdir(parents=True, exist_ok=True)
        try:
            if sys.platform == "win32":
                os.startfile(target)  # noqa: S606
            elif sys.platform == "darwin":
                subprocess.Popen(["open", str(target)])
            else:
                subprocess.Popen(["xdg-open", str(target)])
        except OSError as exc:
            self._log(f"Impossible d'ouvrir le dossier : {exc}", "err")

    def _browse(self) -> None:
        chosen = filedialog.askdirectory(initialdir=self.out_var.get() or str(Path.home()))
        if chosen:
            self.out_var.set(chosen)
            self._update_preview()

    def _job_values(self, job: dict, variant: Optional[Variant]) -> dict:
        return {
            "title": job.get("title", "video"),
            "author": job.get("author") or job.get("title", "auteur"),
            "id": job.get("tweet_id", ""),
            "quality": variant.height_label if variant else "",
            "ext": variant.ext if variant else "mp4",
            "url": job.get("url", ""),
        }

    def _stem_for(self, job: dict, variant: Optional[Variant]) -> str:
        template = self.tpl_var.get().strip() or "{title}_{quality}"
        values = self._job_values(job, variant)
        if not values["id"]:
            template = template.replace("{author}_{id}_", "").replace("{author}_{id}", "")
            template = template.replace("{id}_", "").replace("{id}", "")
        return parse_template(template, values)

    def _update_preview(self) -> None:
        job = self.jobs.get(self.current or "", {})
        variant: Variant | None = self._selected_variant()
        if not job or not variant:
            self.lbl_prog.configure(text="")
            return

        name = self._stem_for(job, variant)
        suffix = "mp4" if variant.ext in ("mp4", "m4v") else variant.ext
        size = human_size(variant.size) if variant.size_known and variant.size else "?"
        bitrate = variant.bitrate if isinstance(variant.bitrate, (int, float)) else 0
        eta = ""
        if bitrate > 0 and isinstance(variant.size, (int, float)) and variant.size:
            eta = f"  ~{human_time(variant.size * 8 / bitrate)}"
        folder = Path(self.out_var.get() or ".").name or "."
        self.lbl_prog.configure(text=f"→ {folder} / {name}.{suffix}   ({size}{eta})")

    def _selected_variant(self) -> Variant | None:
        job = self.jobs.get(self.current or "")
        if not job:
            return None
        index = self.cmb_variant.current()
        variants: list[Variant] = job.get("variants") or []
        if 0 <= index < len(variants):
            return variants[index]
        return None

    # ------------------------------------------------------------------ actions

    def _collect(self) -> list[str]:
        raw = "\n".join([self.url_var.get(), self.txt_links.get("1.0", "end")])
        seen: set[str] = set()
        urls: list[str] = []
        for url in parse_many_urls(raw):
            if url not in seen:
                seen.add(url)
                urls.append(url)
        return urls

    def _add(self) -> None:
        urls = self._collect()
        if not urls:
            messagebox.showinfo(APP_NAME, "Collez au moins un lien X / Twitter.")
            return

        auto = bool(self.auto_var.get())
        cookies = self.cookies_var.get().strip()
        browser = self.browser_var.get().strip().lower()
        browser = "" if browser in ("", "aucun", "none") else browser

        for url in urls:
            iid = self.tree.insert("", "end", values=("analyse...", "", "", "", ""), tags=("idle",))
            self.jobs[iid] = {
                "url": url,
                "status": "pending",
                "variants": [],
                "progress": 0.0,
                "auto": auto,
                "cookies": cookies,
                "browser": browser,
            }
            threading.Thread(target=self._resolve_worker, args=(iid, url), daemon=True).start()

        self.url_var.set("")
        self.txt_links.delete("1.0", "end")
        self._refresh_count()
        if not self.tree.selection():
            first = next(iter(self.jobs), None)
            if first:
                self.tree.selection_set(first)
                self._on_select()

    def _add_all(self) -> None:
        if not self.txt_links.get("1.0", "end").strip():
            messagebox.showinfo(APP_NAME, "La zone multiple est vide.")
            return
        self._add()

    def _resolve_worker(self, iid: str, url: str) -> None:
        self.queue.put(("log", f"Analyse de {url}", "info"))
        job = self.jobs.get(iid, {})
        if job.get("cookies"):
            self.queue.put(("log", f"     cookies appliqués : {len(job['cookies'])} caractère(s)", "info"))
        try:
            info: MediaInfo = resolve(
                url,
                cookies=job.get("cookies", ""),
                cookies_from_browser=job.get("browser", ""),
            )
        except ResolutionError as exc:
            self.queue.put(("resolve_error", iid, str(exc)))
            return
        except Exception as exc:  # noqa: BLE001
            self.queue.put(("resolve_error", iid, f"erreur inattendue : {exc}"))
            return

        self.queue.put(("resolve_ok", iid, info))
        if self.jobs.get(iid, {}).get("auto") and not self.busy:
            self.queue.put(("auto_start", iid))

    def _refresh_sizes(self) -> None:
        job = self.jobs.get(self.current or "")
        if not job:
            return
        threading.Thread(
            target=self._size_worker, args=(job["url"], job.get("cookies", ""), job.get("browser", "")),
            daemon=True,
        ).start()
        self._log("Actualisation des tailles...", "info")

    def _size_worker(self, url: str, cookies: str = "", browser: str = "") -> None:
        try:
            info = resolve(url, cookies=cookies, cookies_from_browser=browser)
        except ResolutionError:
            return
        for iid, data in self.jobs.items():
            if data.get("url") == url:
                self.queue.put(("variants_update", iid, info.variants))

    def _on_select(self, _event=None) -> None:
        selection = self.tree.selection()
        self.current = selection[0] if selection else None
        job = self.jobs.get(self.current or "")

        self.cmb_variant.set("")
        self.cmb_variant["values"] = []
        self.btn_variant.configure(state="disabled")
        self.btn_dl.configure(state="disabled")
        self.btn_rm.configure(state="disabled")
        self.btn_open_file.configure(state="disabled")
        self.btn_del.configure(state="disabled")
        self._sync_pause_button()
        self._sync_stop_button()

        if not job:
            self.lbl_title.configure(text=tr("ui.no_selection"))
            self.lbl_meta.configure(text="")
            self.lbl_prog.configure(text="")
            self._set_thumb(None)
            return

        self.btn_rm.configure(state="normal")
        if self._job_path(job) or self._partial_path(job):
            self.btn_del.configure(state="normal")
        if self._job_path(job):
            self.btn_open_file.configure(state="normal")
        self.lbl_title.configure(text=job.get("title", "média"))

        thumb_url = job.get("thumb_url") or ""
        if thumb_url and job.get("_thumb_url") != thumb_url:
            job["_thumb_url"] = thumb_url
            job["_thumb_at"] = 0.0
            self._set_thumb(None)
            self._load_thumb(thumb_url, referer=job.get("url", ""))
        elif not thumb_url:
            self._set_thumb(None)

        meta = [f"durée {job['duration']}" if job.get("duration") else "", job.get("extractor", ""), job.get("status_label", "")]
        self.lbl_meta.configure(text="   ".join(p for p in meta if p))

        variants: list[Variant] = job.get("variants") or []
        if variants:
            self.cmb_variant["values"] = [v.describe() for v in variants]
            self.cmb_variant.current(0)
            self.btn_variant.configure(state="normal")
            self.btn_dl.configure(
                state="normal" if job["status"] in ("pending", "cancelled", "error") else "disabled"
            )
        self._update_preview()

    def _show_menu(self, event) -> None:
        row = self.tree.identify_row(event.y)
        if row:
            self.tree.selection_set(row)
        self.menu.tk_popup(event.x_root, event.y_root)

    def _job_path(self, job: dict) -> Optional[Path]:
        stored = job.get("path")
        if stored and Path(stored).exists():
            return Path(stored)
        return None

    def _job_folder(self, job: dict) -> Path:
        """Dossier reellement utilise par le job, pas celui affiche dans le champ."""
        stored = job.get("path")
        if stored:
            return Path(stored).parent
        return Path(self.out_var.get() or ".")

    def _partial_path(self, job: dict) -> Optional[Path]:
        """Fichier .part du job, quelle que soit l'extension du media.

        Le downloader ecrit "{stem}.{ext}.part" : chercher seulement
        ".mp4.part" faisait echouer la reprise des variantes webm, mov ou mkv.
        """
        stem = job.get("stem")
        if not stem:
            return None

        stored = job.get("path")
        if stored:
            exact = Path(stored)
            if exact.name.endswith(".part") and exact.exists():
                return exact

        folder = self._job_folder(job)
        if not folder.is_dir():
            return None

        try:
            entries = sorted(folder.iterdir())
        except OSError:
            return None
        for candidate in entries:
            if candidate.name.endswith(".part") and candidate.name.startswith(stem):
                return candidate
        return None

    def _open_file(self) -> None:
        job = self.jobs.get(self.current or "")
        if not job:
            return
        path = self._job_path(job)
        if not path:
            messagebox.showinfo(APP_NAME, "Aucun fichier téléchargé pour cet élément.")
            return
        try:
            os.startfile(path)  # noqa: S606
        except OSError as exc:
            self._log(f"Impossible d'ouvrir le fichier : {exc}", "err")

    def _delete_file(self) -> None:
        job = self.jobs.get(self.current or "")
        if not job:
            return

        targets = [p for p in (self._job_path(job), self._partial_path(job)) if p]
        if not targets:
            messagebox.showinfo(APP_NAME, "Rien à supprimer pour cet élément.")
            return

        listing = "\n".join(f"- {p.name}  ({human_size(p.stat().st_size)})" for p in targets)
        if not messagebox.askyesno(APP_NAME, f"Supprimer définitivement ?\n\n{listing}"):
            return

        freed = 0
        for path in targets:
            try:
                freed += path.stat().st_size
                path.unlink()
            except OSError as exc:
                self._log(f"Suppression impossible : {exc}", "err")

        job.pop("path", None)
        job.pop("stem", None)
        job["status"] = "cancelled"
        job["status_label"] = "supprimé"
        job["progress"] = 0.0
        self.tree.item(
            self.current,
            values=(job.get("title", "")[:48], "", "0 o", "—", "supprimé"),
            tags=("idle",),
        )
        self.bar["value"] = 0
        self.lbl_prog.configure(text="")
        self.lbl_state.configure(text="Fichier supprimé")
        self._log(f"Supprimé : {human_size(freed)} libérés", "warn")
        self._on_select()

    def _cancel(self, iid: str | None = None) -> None:
        target = iid or self.current
        job = self.jobs.get(target or "")
        if not job:
            return

        if self.busy:
            self.cancel_event.set()
            self._log("Stop demandé...", "warn")
            self.btn_stop.configure(state="disabled")
            self.btn_pause.configure(state="disabled")
            self.lbl_state.configure(text="Arrêt en cours...")
            return

        if job["status"] not in ("paused", "pending", "error", "interrupted"):
            return

        self.paused.discard(target)
        job["status"] = "cancelled"
        job["status_label"] = "arrêté"
        partial = self._partial_path(job)
        chosen: Variant | None = job.get("variant")
        self.tree.item(
            target,
            values=(
                job.get("title", job.get("url", ""))[:48],
                chosen.height_label if chosen else "",
                human_size(partial.stat().st_size) if partial else "—",
                "—",
                "arrêté",
            ),
            tags=("idle",),
        )
        self.btn_stop.configure(state="disabled")
        self.lbl_state.configure(text="Arrêté")
        self._log("Téléchargement arrêté - reprise possible (.part conservé)", "warn")
        self._on_select()

    def _toggle_pause(self) -> None:
        job = self.jobs.get(self.current or "")
        if not job:
            return

        if self.busy:
            self.paused.add(self.current)
            self.cancel_event.set()
            self.btn_pause.configure(state="disabled")
            self.lbl_state.configure(text="Pause...")
            self._log("Pause demandée...", "warn")
            return

        variant = job.get("variant") or self._selected_variant()
        if not variant:
            return
        if job["status"] in ("done",):
            return
        if not self._partial_path(job):
            self._log("Rien à reprendre", "warn")
            return

        stem = job.get("stem")
        folder = Path(job["path"]).parent if job.get("path") else Path(self.out_var.get())
        if not stem:
            stem = parse_template(
                self.tpl_var.get().strip() or "{title}_{quality}",
                self._job_values(job, variant),
            )

        job["status"] = "pending"
        job["status_label"] = "reprend"
        self.paused.discard(self.current)
        self._launch(self.current, variant, folder, stem)

    def _sync_pause_button(self) -> None:
        job = self.jobs.get(self.current or "", {})
        status = job.get("status")

        if self.busy and self.current:
            self.btn_pause.configure(text="❚❚  PAUSE", state="normal")
            return

        if status == "paused" or (status == "cancelled" and self._partial_path(job)):
            self.btn_pause.configure(text="▶  REPRENDRE", state="normal")
            return

        self.btn_pause.configure(text="❚❚  PAUSE", state="disabled")

    def _sync_stop_button(self) -> None:
        """STOP reste actif tant qu'il y a un telechargement a interrompre."""
        job = self.jobs.get(self.current or "", {})
        stoppable = bool(self.busy and self.current) or job.get("status") in ("paused", "working")
        self.btn_stop.configure(state="normal" if stoppable else "disabled")


    def _start(self, manual: bool = False) -> None:
        if self.busy or not self.current:
            return
        job = self.jobs[self.current]
        variant = self._selected_variant()
        if not variant:
            messagebox.showwarning(APP_NAME, "Choisissez une résolution.")
            return

        # Un demarrage manuel explicite repart de zero : les tentatives de
        # contournement (jeton frais, capture navigateur) sont rejouees si besoin.
        # Les relances automatiques (bridge, file auto, capture navigateur)
        # conservent le compteur, sinon le palier "capture automatique" est saute.
        current = self.current
        if current and manual:
            self.jobs.get(current, {}).pop("retries", None)

        dest = self.out_var.get().strip() or str(Path.home() / "Downloads")
        if not dest:
            messagebox.showwarning(APP_NAME, "Choisissez un dossier de destination.")
            return

        name = self._stem_for(job, variant)
        target = unique_path(Path(dest) / f"{name}.{'mp4' if variant.ext in ('mp4', 'm4v') else variant.ext}")

        self.settings["out_dir"] = str(dest)
        self.settings["template"] = self.tpl_var.get()
        self.settings["autostart"] = bool(self.auto_var.get())
        self.settings["cookies"] = self.cookies_var.get()
        self.settings["browser"] = self.browser_var.get()
        self._save_config()

        self._launch(self.current, variant, target.parent, target.stem)
        if self.auto_var.get():
            self._kick_next()

    def _launch(self, iid: str, variant: Variant, folder: Path, stem: str) -> None:
        self.busy = True
        self.cancel_event = threading.Event()
        job = self.jobs[iid]
        job["status"] = "working"
        job["status_label"] = "téléchargement"
        job["progress"] = 0.0
        job["variant"] = variant
        job["stem"] = stem
        job["path"] = str(folder / f"{stem}.mp4.part")
        job["thumb_file"] = job["path"]
        job["_thumb_at"] = 0.0

        self.tree.item(iid, tags=("working",))
        self.btn_dl.configure(state="disabled")
        self.btn_stop.configure(state="normal")
        self._sync_pause_button()
        self.lbl_state.configure(text="Téléchargement en cours")

        self._log(f"Début : {stem}.{variant.ext} ({variant.describe()})", "hi")

        downloader = Downloader(
            dest_dir=folder,
            filename_stem=stem,
            on_progress=lambda p: self.queue.put(("progress", iid, p)),
            cancel_event=self.cancel_event,
        )
        threading.Thread(
            target=self._download_worker, args=(iid, downloader, variant), daemon=True
        ).start()

    def _download_worker(self, iid: str, downloader: Downloader, variant: Variant) -> None:
        try:
            result: DownloadResult = downloader.run(variant)
            self.queue.put(("download_done", iid, result))
        except Interrupted as exc:
            # Le .part est conserve : c'est une coupure reseau, pas un refus.
            # On laisse le telechargement reprenable au lieu d'afficher une
            # erreur qui ferait croire a un echec definitif.
            self.queue.put(("download_interrupted", iid, str(exc)))
        except MediaRefused as exc:
            # 200 + page de protection : aucun code d'etat ne le signale, c'est
            # le corps de la reponse qui doit faire le tri.
            self.queue.put(("download_error", iid, str(exc)))
            self._escalate(iid, exc)
        except requests.HTTPError as exc:
            status = exc.response.status_code if exc.response is not None else 0
            if status and is_blocked(status):
                self._escalate(iid, status)
            elif status:
                self.queue.put(
                    (
                        "download_error",
                        iid,
                        f"HTTP {status} - accès refusé par la protection du site. "
                        "Ouvre + Plus de liens / options et clique sur Capturer.",
                    )
                )
            else:
                self.queue.put(
                    ("download_error", iid, f"HTTP {status} - lien expiré ou accès refusé")
                )
        except Exception as exc:  # noqa: BLE001
            self.queue.put(
                ("download_error", iid, f"{exc}\n{traceback.format_exc(limit=6)}")
            )

    def _escalate(self, iid: str, detail: object) -> None:
        """Signale un blocage. Le choix du palier se fait dans _poll.

        Le compteur n'est incremente que sur le thread principal, donc deux
        echecs simultanes ne peuvent pas se voler un palier.
        """
        if iid in self.jobs:
            self.queue.put(("escalate", iid, detail))

    def _retry_worker(self, iid: str, status: int) -> None:
        job = self.jobs.get(iid, {})

        try:
            info = resolve(
                job.get("url", ""),
                with_sizes=False,
                cookies=job.get("cookies", ""),
                cookies_from_browser=job.get("browser", ""),
            )
        except ResolutionError as exc:
            self.queue.put(("download_error", iid, f"ré-analyse impossible : {exc}"))
            return

        height = getattr(job.get("variant"), "height", None)
        fresh = next((v for v in info.variants if v.height == height), None) or (
            info.variants[0] if info.variants else None
        )
        if fresh is None:
            self.queue.put(("download_error", iid, "plus aucune variante après ré-analyse"))
            return

        job["variants"] = info.variants
        job["variant"] = fresh
        self.queue.put(("variants_update", iid, info.variants))
        self.queue.put(("launch_retry", iid))

    def _kick_next(self) -> None:
        for iid, job in self.jobs.items():
            if job["status"] in ("pending", "cancelled", "error") and job.get("variants"):
                self.tree.selection_set(iid)
                self.tree.see(iid)
                self._on_select()
                self._start()
                return

    def _on_close(self) -> None:
        self._closing = True
        if self.cancel_event:
            self.cancel_event.set()
        if self.bridge:
            self.bridge.stop()
            self.bridge = None
        for ident in self._after_ids:
            try:
                self.after_cancel(ident)
            except (tk.TclError, Exception):
                pass
        self._after_ids.clear()
        self._save_config()
        self.destroy()

    # ------------------------------------------------------------------ events

    def _poll(self) -> None:
        if self._closing:
            return
        try:
            while True:
                event = self.queue.get_nowait()
                self._handle(event)
        except queue.Empty:
            pass
        except tk.TclError:
            return
        self._after(60, self._poll)

    def _handle(self, event) -> None:
        kind = event[0]

        if kind == "log":
            self._log(event[1], event[2])

        elif kind == "thumb":
            self._set_thumb(event[1])

        elif kind == "bridge_add":
            self._bridge_add(event[1], event[2])

        elif kind == "bridge_probed":
            self._bridge_probed(event[1], event[2])

        elif kind == "resolve_ok":
            _, iid, info = event
            job = self.jobs.get(iid)
            if not job:
                return
            job.update(
                variants=info.variants,
                author=info.author,
                tweet_id=info.tweet_id,
                title=info.title,
                duration=info.duration_label,
                extractor=info.extractor,
                status="pending",
                status_label="prêt",
                login_required=info.login_required,
                thumb_url=info.thumbnail,
                duration_seconds=info.duration,
                _thumb_at=0.0,
            )
            sizes = ", ".join(v.height_label for v in info.variants[:6])
            self.tree.item(
                iid,
                values=(
                    info.title[:48],
                    f"{len(info.variants)} qual. ({sizes})",
                    human_size(info.variants[0].size) if info.variants[0].size_known else "?",
                    "0 %",
                    "prêt",
                ),
                tags=("idle",),
            )
            self._log(f"{info.variants[0].height_label} max via {info.extractor} - {info.title}", "ok")
            self._refresh_count()
            if not self.tree.selection():
                self.tree.selection_set(iid)
                self.tree.see(iid)
            if iid == self.current:
                self._on_select()
            if job.get("from_bridge") and not self.busy:
                self._after(300, self._bridge_pump)

        elif kind == "resolve_error":
            _, iid, message = event
            job = self.jobs.get(iid)
            if job:
                job["status"] = "error"
                job["status_label"] = "échec"
                self.tree.item(iid, values=(job["url"][:48], "", "", "", "échec"), tags=("error",))
            self._log(f"Échec : {message}", "err")

        elif kind == "variants_update":
            _, iid, variants = event
            job = self.jobs.get(iid)
            if job and iid == self.current:
                job["variants"] = variants
                self.cmb_variant["values"] = [v.describe() for v in variants]
                self.cmb_variant.current(0)
                self._update_preview()

        elif kind == "progress":
            _, iid, progress = event
            self._on_progress(iid, progress)

        elif kind == "download_done":
            _, iid, result = event
            self._on_finished(iid, result)

        elif kind == "escalate":
            # Trois paliers : jeton frais, capture navigateur, puis abandon.
            _, iid, detail = event
            job = self.jobs.get(iid)
            if not job:
                return
            attempts = job.get("retries", 0)
            job["retries"] = attempts + 1
            if attempts == 0:
                # Un jeton fraichement signe echoue aussi vite que l'ancien.
                # Sans pause, on martele le CDN et on se fait bloquer plus
                # vite encore.
                self.busy = True
                self.lbl_state.configure(text="Attente avant ré-analyse...")
                self.after(
                    self.escalation_delay_ms,
                    lambda d=detail: self.queue.put(("retry", iid, d)),
                )
            elif attempts == 1:
                self.busy = True
                self.lbl_state.configure(text="Lancement de la capture...")
                self.after(
                    self.escalation_delay_ms,
                    lambda d=detail: self.queue.put(("auto_capture", iid, d)),
                )
            else:
                job["status"] = "error"
                job["status_label"] = "échec"
                self.tree.item(iid, tags=("error",))
                self.busy = False
                self.btn_stop.configure(state="disabled")
                self.lbl_state.configure(text="")
                self._log(f"{_block_label(detail)} - accès refusé même après ré-analyse et capture", "err")

        elif kind == "retry":
            _, iid, status = event
            self._log(f"{_block_label(status)} - nouvelle analyse du lien pour un jeton frais...", "warn")
            threading.Thread(target=self._retry_worker, args=(iid, status), daemon=True).start()

        elif kind == "auto_capture":
            _, iid, status = event
            job = self.jobs.get(iid, {})
            self._log(
                f"{_block_label(status)} - capture automatique dans le navigateur (méthode IDM), "
                "laisse l'onglet s'ouvrir...",
                "hi",
            )
            self.lbl_state.configure(text="Capture navigateur...")
            threading.Thread(
                target=self._capture_worker, args=(job.get("url", ""), iid), daemon=True
            ).start()

        elif kind == "capture_failed":
            _, iid, message = event
            self.btn_capture.configure(state="normal")
            if iid and iid in self.jobs:
                self.busy = False
                self.btn_stop.configure(state="disabled")
                self.lbl_state.configure(text="")
                self._log(f"Capture automatique échouée : {message}", "err")
                self._on_select()
            else:
                self._log(message, "err")

        elif kind == "capture_variants":
            _, iid, variants, auto = event
            job = self.jobs.get(iid)
            if not job:
                self.btn_capture.configure(state="normal")
                return
            job["variants"] = variants
            job["variant"] = None
            job["captured"] = True
            job["status"] = "pending"
            job["status_label"] = "capturé"
            self.cmb_variant["values"] = [v.describe() for v in variants]
            self.cmb_variant.current(0)
            self.btn_dl.configure(state="normal")
            sizes = ", ".join(v.height_label for v in variants[:5])
            self.tree.item(
                iid,
                values=(
                    job.get("title", job["url"])[:48],
                    f"{len(variants)} ({sizes})",
                    "?",
                    "0 %",
                    "capturé",
                ),
                tags=("idle",),
            )
            self._on_select()
            self._update_preview()

            if auto:
                fresh = variants[0]
                job["variant"] = fresh
                self._log(
                    f"Requête interceptée : {len(fresh.headers)} en-têtes, "
                    f"{len(fresh.cookies)} car. de cookie → relance",
                    "ok",
                )
                if job.get("stem"):
                    self.busy = False
                    self._launch(iid, fresh, Path(job["path"]).parent, job["stem"])
                else:
                    self.tree.selection_set(iid)
                    self._on_select()
                    self._start()
            else:
                self.btn_capture.configure(state="normal")
                self._log("Capture terminée, choisis une résolution puis TELECHARGER", "ok")

        elif kind == "test_info":
            _, info = event
            self._log(
                f"     analyse : {info.extractor}, {len(info.variants)} variante(s), "
                f"durée {info.duration_label}"
                + (", page réservée aux membres" if info.login_required else ""),
                "info",
            )

        elif kind == "test_done":
            _, _, message = event
            self.btn_test.configure(state="normal")
            level = "ok" if message.startswith("OK") else "err"
            self._log(message, level)

        elif kind == "launch_retry":
            _, iid = event
            job = self.jobs.get(iid, {})
            fresh = job.get("variant")
            if fresh and job.get("stem"):
                folder = Path(job["path"]).parent
                self.busy = False
                self._launch(iid, fresh, folder, job["stem"])

        elif kind == "download_interrupted":
            _, iid, message = event
            job = self.jobs.get(iid)
            if job:
                job["status"] = "interrupted"
                job["status_label"] = tr("st.interrupted")
                self.tree.item(iid, tags=("paused",))
            self.busy = False
            self.btn_stop.configure(state="disabled")
            self.lbl_state.configure(text="")
            self._log(f"{message} - .part conservé, relance pour reprendre", "warn")

        elif kind == "download_error":
            _, iid, message = event
            job = self.jobs.get(iid)
            if job:
                job["status"] = "error"
                job["status_label"] = "échec"
                self.tree.item(iid, tags=("error",))
            self.busy = False
            self.btn_stop.configure(state="disabled")
            self.lbl_state.configure(text="")
            self._log(f"Erreur : {message}", "err")
            self._on_select()

        elif kind == "auto_start":
            if not self.busy and self.jobs.get(event[1], {}).get("status") == "pending":
                self.tree.selection_set(event[1])
                self._on_select()
                self._start()

    def _on_progress(self, iid: str, progress: Progress) -> None:
        job = self.jobs.get(iid)
        if not job:
            return

        if iid == self.current:
            self.bar["value"] = progress.percent
            total = human_size(progress.total) if progress.total else "?"
            self.lbl_prog.configure(
                text=(
                    f"{progress.percent:5.1f} %   {human_size(progress.downloaded)} / {total}"
                    f"   {human_rate(progress.speed)}   reste {human_time(progress.eta)}"
                )
            )
            self._refresh_thumb_frame(iid)

        if progress.status != "downloading" or not progress.downloaded:
            return

        shown = int(job.get("progress", -1))
        if int(progress.percent) == shown and int(job.get("bytes", -1)) == progress.downloaded:
            return

        job["progress"] = progress.percent
        job["bytes"] = progress.downloaded
        chosen: Variant | None = job.get("variant")
        if chosen is None and job.get("variants"):
            chosen = job["variants"][0]

        size = human_size(progress.total) if progress.total else human_size(progress.downloaded)
        if progress.total:
            label = f"{progress.percent:.0f} %  {human_rate(progress.speed)}"
        else:
            label = f"{human_size(progress.downloaded)}  {human_rate(progress.speed)}"
        self.tree.item(
            iid,
            values=(
                job.get("title", job["url"])[:48],
                chosen.describe().split("  -  ")[0] if chosen else "",
                size,
                label,
                "en cours",
            ),
            tags=("working",),
        )

    def _on_finished(self, iid: str, result: DownloadResult) -> None:
        self.busy = False
        job = self.jobs.get(iid, {})
        self.btn_stop.configure(state="disabled")

        if result.status == "cancelled":
            was_paused = iid in self.paused
            self.paused.discard(iid)
            job["status"] = "paused" if was_paused else "cancelled"
            job["status_label"] = "en pause" if was_paused else "arrêté"
            partial = self._partial_path(job)
            self.tree.item(
                iid,
                values=(
                    job.get("title", "")[:48],
                    result.variant.height_label,
                    human_size(partial.stat().st_size) if partial else "0 o",
                    "—" if was_paused else "—",
                    job["status_label"],
                ),
                tags=("idle",),
            )
            if was_paused:
                self._log(
                    f"En pause : {human_size(partial.stat().st_size) if partial else '0 o'} conservés, "
                    "reprend au même octet",
                    "warn",
                )
            else:
                self._log("Téléchargement arrêté - reprise possible (.part conservé)", "warn")
            self.lbl_state.configure(text="En pause" if was_paused else "Arrêté")
            self._on_select()
            return

        speed = result.bytes_written / result.duration if result.duration else 0
        job["status"] = "done"
        job["status_label"] = "terminé"
        job["path"] = str(result.path)
        self.tree.item(
            iid,
            values=(
                job.get("title", "")[:48],
                result.variant.height_label,
                human_size(result.bytes_written),
                "100 %",
                "terminé",
            ),
            tags=("done",),
        )
        if iid == self.current:
            self.bar["value"] = 100
            self.lbl_prog.configure(text=f"100 %   {human_size(result.bytes_written)}   terminé")
        self.lbl_state.configure(text="Terminé")
        self._log(
            f"OK  {result.filename}  ({human_size(result.bytes_written)} en {human_time(result.duration)}, "
            f"{human_rate(speed)})",
            "ok",
        )
        self._on_select()

        if self.auto_var.get():
            self._after(400, self._kick_next)

    def _on_close_guard(self) -> None:
        self._on_close()


def main(argv: list[str] | None = None) -> None:
    argv = list(sys.argv[1:] if argv is None else argv)
    app = XGrabApp()
    if argv and not argv[0].startswith("-"):
        app.txt_links.insert("1.0", " ".join(argv))
        app.after(900, app._add)
    app.mainloop()


if __name__ == "__main__":
    main()
