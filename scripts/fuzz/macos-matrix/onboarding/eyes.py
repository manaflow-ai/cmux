"""See and act on a VM's screen the way a person does: read the text on it, click what a label says.

Every action goes in over VNC (rfb.RFB: real keyboard and pointer events in the guest), and every
look is a VNC frame read by vmeye's OCR on the host. Nothing runs in the guest to help. Each frame
is kept with its time, so the run ends with a video (vmeye video) and a still per step.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import time

from rfb import RFB

SHIFTED = set('~!@#$%^&*()_+{}|:"<>?')


class NotSeen(Exception):
    pass


class Eyes:
    def __init__(self, vnc: RFB, vmeye: str, out: str):
        self.vnc, self.vmeye, self.out = vnc, vmeye, out
        self.frames = os.path.join(out, "frames")
        os.makedirs(self.frames, exist_ok=True)
        self.t0 = time.monotonic()
        self.n = 0
        self.index = open(os.path.join(out, "frames.txt"), "w")
        self.actions = 0  # every click, drag, key press and typed string: the person's effort
        self.lines: list[dict] = []

    # --- looking ---

    def look(self) -> list[dict]:
        """Take a frame, keep it for the video and return its text lines."""
        png = self.vnc.screenshot_png()
        self.n += 1
        path = os.path.join(self.frames, "%05d.png" % self.n)
        with open(path, "wb") as f:
            f.write(png)
        self.index.write("%.2f %s\n" % (time.monotonic() - self.t0, path))
        self.index.flush()
        res = subprocess.run([self.vmeye, "ocr", path], capture_output=True, text=True, timeout=60)
        self.lines = [json.loads(l) for l in res.stdout.splitlines() if l.startswith("{")]
        self.last_frame = path
        return self.lines

    def find(self, pattern: str, lines: list[dict] | None = None) -> dict | None:
        """The first text line matching pattern (a regex, case-insensitive), top to bottom."""
        rx = re.compile(pattern, re.I)
        hits = [l for l in (self.lines if lines is None else lines) if rx.search(l["text"])]
        return min(hits, key=lambda l: (l["y"], l["x"])) if hits else None

    def wait(self, pattern: str, seconds: float = 30, gone: bool = False) -> dict | None:
        """Look until pattern shows (or, with gone, until it no longer shows)."""
        deadline = time.monotonic() + seconds
        while True:
            hit = self.find(pattern, self.look())
            if (hit is None) == gone:
                return hit
            if time.monotonic() > deadline:
                raise NotSeen(("still see %r" if gone else "never saw %r") % pattern)
            time.sleep(0.5)

    def shot(self, name: str) -> str:
        self.look()
        path = os.path.join(self.out, "shot-%s.png" % name)
        with open(self.last_frame, "rb") as src, open(path, "wb") as dst:
            dst.write(src.read())
        return path

    # --- acting (each one counts as one action of the person) ---

    @staticmethod
    def center(line: dict, word: str | None = None) -> tuple[int, int]:
        x, w = line["x"], line["w"]
        if word:  # a word inside the line: aim at it, not at the line's middle
            i = line["text"].lower().find(word.lower())
            if i >= 0 and line["text"]:
                per = w / len(line["text"])
                x, w = int(x + i * per), int(len(word) * per)
        return x + w // 2, line["y"] + line["h"] // 2

    def click(self, pattern: str, seconds: float = 30, word: str | None = None) -> dict:
        line = self.wait(pattern, seconds)
        x, y = self.center(line, word)
        self.vnc.click(x, y)
        self.actions += 1
        time.sleep(0.4)
        return line

    def click_at(self, x: int, y: int) -> None:
        self.vnc.click(x, y)
        self.actions += 1
        time.sleep(0.4)

    def drag(self, x0: int, y0: int, x1: int, y1: int) -> None:
        # A drag source on macOS wants a press that lingers before the pointer moves.
        vnc = self.vnc
        vnc.move(x0, y0)
        time.sleep(0.2)
        vnc.button(1, True)
        time.sleep(0.4)
        steps = 30
        for i in range(1, steps + 1):
            vnc.move(x0 + (x1 - x0) * i // steps, y0 + (y1 - y0) * i // steps)
            time.sleep(0.03)
        time.sleep(0.4)
        vnc.button(1, False)
        self.actions += 1
        time.sleep(0.5)

    def press(self, chord: str) -> None:
        self.vnc.chord(chord)
        self.actions += 1
        time.sleep(0.3)

    def type(self, text: str) -> None:
        """Type text; Shift is held for capitals and shifted symbols, as a keyboard needs."""
        vnc = self.vnc
        shift = 0xFFE1
        for ch in text:
            sym = 0xFF0D if ch == "\n" else ord(ch)
            shifted = ch.isupper() or ch in SHIFTED
            if shifted:
                vnc.key(shift, True)
            vnc.key(sym, True)
            vnc.key(sym, False)
            if shifted:
                vnc.key(shift, False)
            time.sleep(0.02)
        self.actions += 1
        time.sleep(0.2)

    def close(self) -> None:
        self.index.close()

    def video(self, path: str) -> bool:
        res = subprocess.run([self.vmeye, "video", os.path.join(self.out, "frames.txt"), path],
                             capture_output=True, text=True, timeout=900)
        return res.returncode == 0
