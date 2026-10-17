"""Bouton arrondi dessine sur un Canvas (ttk ne sait pas faire les coins ronds)."""

from __future__ import annotations

import tkinter as tk
import tkinter.font as tkfont
from typing import Callable, Optional

PAD_X = 18
PAD_Y = 9
RADIUS = 8
FONT = "Segoe UI"
MIN_WIDTH = 64
HEIGHT = 38


class RoundedButton(tk.Canvas):
    """Compatible avec l'usage ttk : configure(state=...), cget("text"), ["state"]."""

    def __init__(
        self,
        master,
        text: str = "",
        command: Optional[Callable[[], None]] = None,
        fill: str = "#4d90fe",
        hover: str = "#6aa2ff",
        foreground: str = "#ffffff",
        disabled_fill: str = "#e9ecf2",
        disabled_text: str = "#9aa1ad",
        font: tuple = (FONT, 10, "bold"),
        radius: int = RADIUS,
        padx: int = PAD_X,
        pady: int = PAD_Y,
        **kwargs,
    ):
        initial_state = kwargs.pop("state", "normal")

        super().__init__(
            master,
            highlightthickness=0,
            borderwidth=0,
            bg=kwargs.pop("parent_bg", "#ffffff"),
            cursor="hand2",
            **kwargs,
        )
        self._text = text
        self._command = command
        self._fill = fill
        self._hover = hover
        self._fg = foreground
        self._disabled_fill = disabled_fill
        self._disabled_text = disabled_text
        self._font = font
        self._radius = radius
        self._padx = padx
        self._pady = pady
        self._state = "disabled" if str(initial_state) in ("disabled", "false", "0") else "normal"
        self._pressed = False
        self._measure()

        self.bind("<Configure>", lambda _e: self._redraw())
        self.bind("<Enter>", self._on_enter)
        self.bind("<Leave>", self._on_leave)
        self.bind("<ButtonPress-1>", self._on_press)
        self.bind("<ButtonRelease-1>", self._on_release)

    def _measure(self) -> None:
        font = tkfont.Font(root=self, font=self._font)
        text_w = font.measure(self._text) if self._text else 0
        text_h = font.metrics("linespace")
        width = max(MIN_WIDTH, text_w + self._padx * 2)
        height = max(HEIGHT, text_h + self._pady * 2)
        self.configure(width=width, height=height)

    def _paint(self) -> None:
        enabled = self._state == "normal"
        fill = self._fill if enabled else self._disabled_fill
        if enabled and self._pressed:
            fill = self._hover

        width = self.winfo_width()
        height = self.winfo_height()
        if width <= 1:
            width = int(self.cget("width"))
        if height <= 1:
            height = int(self.cget("height"))
        self.delete("all")

        radius = min(self._radius, height // 2, width // 2)
        self.create_arc(
            0, 0, radius * 2, radius * 2,
            start=90, extent=90, style="pieslice", fill=fill, outline="",
        )
        self.create_arc(
            width - radius * 2, 0, width, radius * 2,
            start=0, extent=90, style="pieslice", fill=fill, outline="",
        )
        self.create_arc(
            0, height - radius * 2, radius * 2, height,
            start=180, extent=90, style="pieslice", fill=fill, outline="",
        )
        self.create_arc(
            width - radius * 2, height - radius * 2, width, height,
            start=270, extent=90, style="pieslice", fill=fill, outline="",
        )
        self.create_rectangle(radius, 0, width - radius, height, fill=fill, outline="")
        self.create_rectangle(0, radius, width, height - radius, fill=fill, outline="")

        color = self._fg if enabled else self._disabled_text
        self.create_text(
            width / 2, height / 2, text=self._text, fill=color, font=self._font
        )

    def _redraw(self) -> None:
        self._paint()

    def _on_enter(self, _event=None) -> None:
        if self._state == "normal":
            self.configure(cursor="hand2")
            self._paint()

    def _on_leave(self, _event=None) -> None:
        self._pressed = False
        self._paint()

    def _on_press(self, _event=None) -> None:
        if self._state == "normal":
            self._pressed = True
            self._paint()

    def _on_release(self, event=None) -> None:
        was = self._pressed
        self._pressed = False
        self._paint()
        if was and self._state == "normal" and self._command:
            inside = (
                0 <= event.x <= self.winfo_width() and 0 <= event.y <= self.winfo_height()
            )
            if inside:
                self._command()

    def invoke(self) -> None:
        if self._state == "normal" and self._command:
            self._command()

    # ------------------------------------------------------------------ API ttk

    def configure(self, cnf=None, **kwargs):
        if cnf:
            kwargs.update(cnf)
        needs_measure = False
        if "text" in kwargs:
            self._text = str(kwargs.pop("text"))
            needs_measure = True
        if "state" in kwargs:
            value = str(kwargs.pop("state"))
            self._state = "disabled" if value in ("disabled", "false", "0") else "normal"
            self.configure(cursor="hand2" if self._state == "normal" else "arrow")
        if "font" in kwargs:
            self._font = kwargs.pop("font")
            needs_measure = True
        if needs_measure:
            self._measure()
        if kwargs:
            super().configure(**kwargs)
        self._paint()
        return None

    config = configure

    def cget(self, key: str):
        if key == "text":
            return self._text
        if key == "state":
            return self._state
        return super().cget(key)

    def __setitem__(self, key: str, value) -> None:
        self.configure(**{key: value})

    def __getitem__(self, key: str):
        if key == "state":
            return self._state
        return super().__getitem__(key)

    def __contains__(self, key: str) -> bool:
        return key in ("text", "state")