#!/usr/bin/env python3
"""The oracle's TUI driver: `tui.key` steps into a `cmux-tui attach` frontend in a PTY the driver owns.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, sections 3B and 3D and task 234. Stdlib plus the sibling
drivers, Python 3.9+, safe under `python3 -I`. It implements the driver protocol of oracle.py (`open_session`,
`session.run_case`, `session.close`) for `--product tui`, on the Linux VM (`--binary`: the cmux-tui that
linux_run.sh built at the run SHA).

Every case is driver_daemon.py's case (p15-oracle-023): its own state root, hermetic environment, headless
daemon, subreaper worker and I6 proof. A case that requires `tui` also gets the frontend: `cmux-tui attach
--session <case session> --socket <case socket>` with the case's environment and a config file of its own
(gen_tui.TUI_CONFIG: viewport animation off, as spec 3B runs motion off, and chords for the actions with no
default one), on a PTY of COLS x ROWS whose master only this driver holds. A `tui.key` step writes each
keystroke to that master as a terminal writes a key press: printable keys and Ctrl letters as their legacy
bytes, cursor and function keys as their xterm sequences, and every key a legacy terminal cannot send
unambiguously (Escape, Cmd, Ctrl with Shift) as a CSI u key report, which the TUI's crossterm reader parses with
or without the kitty protocol (Escape as `CSI 27 u` never merges with the next key into an Alt chord). The
driver answers none of the TUI's startup queries (colors, DA1, keyboard protocol, cell size), so every run
negotiates the same terminal.

The screen is a cell grid the driver keeps from the PTY output (Screen: the cursor, erase, scroll, SGR and
alternate-screen controls ratatui and crossterm write; OSC, DCS and APC strings draw no cell and are dropped).
Each cell keeps its text and canonical SGR style, since the TUI draws focus and selection in color only. The
`tui` facet of a checkpoint (snapshot-v1 facets.tui) is the grid size, the sha256 of the rows' text (the case's
own session name and state root written as the fixture's) and style runs, the cursor, and the TUI's exit
status. Private text is never recorded: only the hash.

Settling (spec 3B). The daemon facet settles as in driver_daemon.py. The frontend has no settle method of its
own, so a checkpoint waits for three things, none of them by sleeping:
1. the daemon: every running terminal's viewport shows the fixed shell prompt (`terminal.wait`, which the
   daemon wakes on viewport output, never by polling), so a shell that has not printed yet cannot race a hash;
2. the frontend's input queue: a barrier through the same queue the step's keys took. The driver presses the
   prefix (Ctrl-b), waits until the prefix help bar is on screen, presses Escape and waits until it is gone:
   the TUI reads input in order, so every earlier key has been handled and drawn. Chrome's browser tests
   settle a renderer the same way, with a message through the main thread's own queue
   (content/public/test/browser_test_utils.h MainThreadFrameObserver, RenderFrameSubmissionObserver);
3. a fixed point: barrier rounds repeat until two in a row give the same screen hash, daemon revision and
   terminal output revisions, so a daemon event the frontend applies after the first round is in the hash. A
   round that ends while the TUI re-reads the daemon's tree (its remote-tree-refresh thread is alive) does not
   count: the result of that read is not drawn yet.
A frontend that exited (a detach) is settled once the daemon has dropped its connections (`client-detached`
events, as driver_cli.py waits for a `cmux` call's connection). The barrier needs the frontend in pane input
mode: a step that leaves a prompt, menu, overlay or the sidebar focused records only its `before` checkpoint,
and may prove that it drew with a waitFor on `/tui/...` (`changed`), which wakes on PTY output; the next step
closes it, records no `before` checkpoint, and settles.
A step that ends with the prefix armed is refused: the barrier's own prefix would complete it.

Teardown: the frontend's PTY hangs up, as when a terminal window closes, and the frontend must exit on its
own; one still running after the bound is killed and fails the case (I6). Then the daemon case's teardown.

The corpus (tests/oracle/corpus/tui/, one case per inventory action the default key map reaches) is gen_tui.py's.

Usage:
  driver_tui.py run-case --binary CMUX_TUI CASE.json [--isolation none]   one case, its result JSON
"""

from __future__ import annotations

import argparse
import codecs
import fcntl
import hashlib
import json
import os
import pty
import re
import selectors
import struct
import subprocess
import sys
import termios
import threading
import time
import unicodedata
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Set, Tuple

HERE = Path(__file__).resolve().parent

if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import normalize  # noqa: E402 - sibling of this file (p15-oracle-013)
from gen_tui import TUI_CONFIG  # noqa: E402 - the frontend's config, shared with the corpus that presses its keys
import driver_daemon  # noqa: E402 - the daemon driver's case runner (p15-oracle-023)
from driver_cli import ClientEvents  # noqa: E402 - client-detached events of the case daemon (p15-oracle-048)
from driver_daemon import (  # noqa: E402
    DEFAULT_STATE_BASE,
    REQUEST_S,
    SELECTORS,
    SESSION_NAME,
    CaseError,
    CaseRun,
    CmuxError,
    DaemonSession,
    decode_pointer,
    not_comparable,
    predicate_holds,
    remove_empty_dir,
    resolve_pointer,
    short_token,
)

PRODUCT = "tui"
TUI_FACET = "tui"
TUI_CAPABILITY = "tui"
TASK = "p15-oracle-234"
COLS, ROWS = 120, 36
# hermetic_env.FIXED_PS1 as a terminal.wait regex: every running shell has printed its prompt.
PROMPT_PATTERN = r"(?m)^\$"
# The default prefix (cmux-tui config/keys.rs Keys::default), and the prefix help bar the TUI draws while it is
# armed (ui/mod.rs draw_prefix_help_bar; English: hermetic_env sets LANG=C.UTF-8).
PREFIX_KEY = "ctrl+b"
PREFIX_BAR = re.compile(r" Ctrl-b  › ")
# Seconds: the frontend's first frame, one settle, and the frontend's exit after its terminal hangs up.
ATTACH_S = 30.0
SETTLE_S = 20.0
HANG_UP_S = 10.0
# Barrier rounds before a checkpoint gives up: the fixed point needs two equal rounds in a row.
MAX_ROUNDS = 20
# The TUI thread that re-reads the daemon's tree after an event (its 15-byte Linux comm prefix).
REFRESH_THREAD = "remote-tree-ref"
# session.snapshot's client_kind of the frontend's connections.
TUI_CLIENT_KIND = "tui"
TUI_LOG = "tui.log"
TUI_CONFIG_FILE = "tui-config.json"


# ---------------------------------------------------------------------------------------------------------
# Keystrokes (case-v1 $defs.keystroke) as the bytes a terminal sends


class KeystrokeError(ValueError):
    """A keystroke the driver cannot send."""


SHIFTED = {"1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
           "-": "_", "=": "+", "[": "{", "]": "}", ";": ":", "'": '"', ",": "<", ".": ">", "/": "?", "`": "~",
           "\\": "|"}
CSI_U_ESCAPE = b"\x1b[27u"
# Named keys: (legacy bytes, xterm CSI letter or tilde number for a modified form, CSI u code point).
NAMED: Dict[str, Tuple[bytes, Optional[str], Optional[int]]] = {
    "return": (b"\r", None, 13),
    "tab": (b"\t", None, 9),
    "space": (b" ", None, 32),
    "backspace": (b"\x7f", None, 127),
    "escape": (CSI_U_ESCAPE, None, 27),
    "delete": (b"\x1b[3~", "3~", None),
    "left": (b"\x1b[D", "D", None),
    "right": (b"\x1b[C", "C", None),
    "up": (b"\x1b[A", "A", None),
    "down": (b"\x1b[B", "B", None),
    "home": (b"\x1b[H", "H", None),
    "end": (b"\x1b[F", "F", None),
    "pageup": (b"\x1b[5~", "5~", None),
    "pagedown": (b"\x1b[6~", "6~", None),
    "f1": (b"\x1bOP", "P", None), "f2": (b"\x1bOQ", "Q", None), "f3": (b"\x1bOR", "R", None),
    "f4": (b"\x1bOS", "S", None),
    "f5": (b"\x1b[15~", "15~", None), "f6": (b"\x1b[17~", "17~", None), "f7": (b"\x1b[18~", "18~", None),
    "f8": (b"\x1b[19~", "19~", None), "f9": (b"\x1b[20~", "20~", None), "f10": (b"\x1b[21~", "21~", None),
    "f11": (b"\x1b[23~", "23~", None), "f12": (b"\x1b[24~", "24~", None),
}
# Kitty and xterm modifier bits: the parameter is 1 + the sum.
MOD_BITS = {"shift": 1, "alt": 2, "opt": 2, "ctrl": 4, "cmd": 8}


def parse_stroke(stroke: str) -> Tuple[Set[str], str]:
    *mods, key = stroke.split("+")
    if "fn" in mods:
        raise KeystrokeError(f"{stroke}: fn is a hardware modifier no terminal reports")
    unknown = [m for m in mods if m not in MOD_BITS]
    if unknown or not key:
        raise KeystrokeError(f"{stroke} is not a case-v1 keystroke")
    return {("alt" if m == "opt" else m) for m in mods}, ("+" if key == "plus" else key)


def csi_modifier(mods: Set[str]) -> int:
    return 1 + sum(MOD_BITS[m] for m in mods)


def key_bytes(stroke: str) -> bytes:
    """What a terminal writes for `stroke`: the legacy bytes when they are unambiguous, else CSI u or the xterm
    modified form (crossterm parses both without the kitty protocol)."""
    mods, key = parse_stroke(stroke)
    if key in NAMED:
        legacy, xterm, codepoint = NAMED[key]
        if not mods:
            return legacy
        if key == "tab" and mods == {"shift"}:
            return b"\x1b[Z"
        if mods == {"alt"} and key not in ("escape",):
            return b"\x1b" + legacy
        if xterm is not None:
            if xterm.endswith("~"):
                return f"\x1b[{xterm[:-1]};{csi_modifier(mods)}~".encode()
            return f"\x1b[1;{csi_modifier(mods)}{xterm}".encode()
        return f"\x1b[{codepoint};{csi_modifier(mods)}u".encode()
    if len(key) != 1:
        raise KeystrokeError(f"{stroke}: unknown key {key!r}")
    char = key
    if "shift" in mods:
        if char.isalpha():
            char = char.upper()
        elif char in SHIFTED:
            char = SHIFTED[char]
    rest = mods - {"shift"} if char != key else mods
    if not rest:
        return char.encode()
    if rest == {"ctrl"} and char.isalpha() and char.islower():
        return bytes([ord(char) - 96])
    if rest == {"alt"}:
        return b"\x1b" + char.encode()
    if rest == {"ctrl", "alt"} and char.isalpha() and char.islower():
        return b"\x1b" + bytes([ord(char) - 96])
    return f"\x1b[{ord(key)};{csi_modifier(mods)}u".encode()


def check_keys(step: Mapping[str, Any]) -> List[bytes]:
    """The step's keystrokes as bytes, refusing a sequence the TUI would read as other keys."""
    strokes = list((step.get("args") or {}).get("keys") or ())
    try:
        encoded = [key_bytes(stroke) for stroke in strokes]
    except KeystrokeError as error:
        raise CaseError("Crash", str(error), step["id"]) from None
    prefix = key_bytes(PREFIX_KEY)
    trailing = 0
    for key in reversed(encoded):
        if key != prefix:
            break
        trailing += 1
    # A doubled prefix sends the prefix to the pane (send-prefix); an odd run leaves it armed.
    if trailing % 2:
        raise CaseError("Crash", "the step ends with the prefix armed (a prefix with no key after it): the next "
                                 "key would complete it; end the step with the prefixed key", step["id"])
    return encoded


# ---------------------------------------------------------------------------------------------------------
# The screen: a character grid from the PTY output


def char_width(char: str) -> int:
    if unicodedata.combining(char):
        return 0
    return 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1


Cell = Tuple[str, str]
# SGR codes that set or clear one attribute of the pen.
SGR_ON = {1: "bold", 2: "dim", 3: "italic", 4: "underline", 5: "blink", 7: "reverse", 8: "hidden", 9: "strike",
          53: "overline"}
SGR_OFF = {22: ("bold", "dim"), 23: ("italic",), 24: ("underline",), 25: ("blink",), 27: ("reverse",),
           28: ("hidden",), 29: ("strike",), 55: ("overline",), 39: ("fg",), 49: ("bg",), 59: ("uc",)}
SGR_COLOR = {38: "fg", 48: "bg", 58: "uc"}


def sgr_color(values: Sequence[str], colon: bool) -> Tuple[Optional[str], int]:
    """An extended color, `5;N` or `2;R;G;B` (the colon form may carry a colorspace before R), and how many
    values it took."""
    if values[:1] == ["5"] and len(values) >= 2:
        return f"5:{values[1]}", 2
    if values[:1] == ["2"] and len(values) >= 4:
        rgb = values[-3:] if colon else values[1:4]
        return "2:" + ",".join(rgb), len(values) if colon else 4
    return None, len(values) if colon else 0


class Screen:
    """The cells a terminal shows for the TUI's output: each cell's text and the canonical SGR style it was
    written with (the pen), so a focus or selection drawn only in color still changes the screen."""

    def __init__(self, cols: int, rows: int):
        self.cols, self.rows = cols, rows
        self.pen: Dict[str, Any] = {}
        self.style = ""
        self.main = self.blank()
        self.alt: Optional[List[List[Cell]]] = None
        self.row = self.col = 0
        self.saved = (0, 0)
        self.wrap_pending = False
        self.cursor_visible = True
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.state = "ground"
        self.seq = ""

    def blank_row(self) -> List[Cell]:
        """An erased row: blanks with the pen's background (xterm erases with the current background)."""
        bg = self.pen.get("bg")
        return [(" ", f"bg={bg}" if bg else "")] * self.cols

    def blank(self) -> List[List[Cell]]:
        return [self.blank_row() for _ in range(self.rows)]

    @property
    def grid(self) -> List[List[Cell]]:
        return self.alt if self.alt is not None else self.main

    def lines(self) -> List[str]:
        return ["".join(char for char, _ in row).rstrip() for row in self.grid]

    def styles(self) -> List[str]:
        """Each row's style runs, `count*style` joined by `|` (the default style is empty)."""
        out = []
        for row in self.grid:
            runs: List[List[Any]] = []
            for _, style in row:
                if runs and runs[-1][1] == style:
                    runs[-1][0] += 1
                else:
                    runs.append([1, style])
            out.append("|".join(f"{count}*{style}" for count, style in runs))
        return out

    def feed(self, data: bytes) -> None:
        for char in self.decoder.decode(data):
            self.step(char)

    def step(self, char: str) -> None:
        state = self.state
        if state == "ground":
            if char == "\x1b":
                self.state = "esc"
            elif char < " " or char == "\x7f":
                self.control(char)
            else:
                self.put(char)
        elif state == "esc":
            if char == "[":
                self.state, self.seq = "csi", ""
            elif char in "]P_^X":
                self.state = "string"
            elif char in "()*+#%":
                self.state = "charset"
            else:
                self.state = "ground"
                self.escape(char)
        elif state == "charset":
            self.state = "ground"
        elif state == "csi":
            if "\x40" <= char <= "\x7e":
                self.state = "ground"
                self.csi(self.seq, char)
            elif char == "\x1b":
                self.state = "esc"
            else:
                self.seq += char
        elif state == "string":
            if char == "\x07":
                self.state = "ground"
            elif char == "\x1b":
                self.state = "string_esc"
        elif state == "string_esc":
            self.state = "ground" if char == "\\" else "string"

    def control(self, char: str) -> None:
        if char == "\r":
            self.col, self.wrap_pending = 0, False
        elif char in "\n\x0b\x0c":
            self.line_feed()
        elif char == "\b":
            self.col, self.wrap_pending = max(0, self.col - 1), False
        elif char == "\t":
            self.col = min(self.cols - 1, (self.col // 8 + 1) * 8)

    def escape(self, char: str) -> None:
        if char == "7":
            self.saved = (self.row, self.col)
        elif char == "8":
            self.row, self.col = self.saved
        elif char == "D":
            self.line_feed()
        elif char == "E":
            self.col = 0
            self.line_feed()
        elif char == "M":
            if self.row == 0:
                self.grid.pop()
                self.grid.insert(0, self.blank_row())
            else:
                self.row -= 1
        elif char == "c":
            self.__init__(self.cols, self.rows)

    def line_feed(self) -> None:
        self.wrap_pending = False
        if self.row == self.rows - 1:
            self.grid.pop(0)
            self.grid.append(self.blank_row())
        else:
            self.row += 1

    def put(self, char: str) -> None:
        width = char_width(char)
        if width == 0:
            return
        if self.wrap_pending:
            self.col = 0
            self.line_feed()
        if width == 2 and self.col == self.cols - 1:
            self.grid[self.row][self.col] = (" ", self.style)
            self.col = 0
            self.line_feed()
        row = self.grid[self.row]
        row[self.col] = (char, self.style)
        if width == 2:
            row[self.col + 1] = ("", self.style)
        if self.col + width >= self.cols:
            self.col = self.cols - 1
            self.wrap_pending = True
        else:
            self.col += width

    def sgr(self, body: str) -> None:
        pen = dict(self.pen)
        values = body.split(";") if body else ["0"]
        index = 0
        while index < len(values):
            head, *subs = values[index].split(":")
            code = int(head) if head.isdigit() else 0
            index += 1
            if code in SGR_COLOR:
                color, used = sgr_color(subs if subs else values[index:], bool(subs))
                if not subs:
                    index += used
                if color is not None:
                    pen[SGR_COLOR[code]] = color
            elif code == 0:
                pen = {}
            elif code == 4 and subs:
                if subs[0] in ("", "0"):
                    pen.pop("underline", None)
                else:
                    pen["underline"] = subs[0]
            elif code in SGR_ON:
                pen[SGR_ON[code]] = True
            elif code in SGR_OFF:
                for name in SGR_OFF[code]:
                    pen.pop(name, None)
            elif 30 <= code <= 37 or 90 <= code <= 97:
                pen["fg"] = str(code - 30 if code < 90 else code - 82)
            elif 40 <= code <= 47 or 100 <= code <= 107:
                pen["bg"] = str(code - 40 if code < 100 else code - 92)
        self.pen = pen
        self.style = ",".join(name if value is True else f"{name}={value}" for name, value in sorted(pen.items()))

    def csi(self, seq: str, final: str) -> None:
        private = seq[:1] in ("?", ">", "<", "=")
        body = seq[1:] if private else seq
        if any(c in body for c in " !\"$'"):
            return  # DECSCUSR, DECSTR and other intermediates: no cell or cursor position
        if final == "m":
            if not private:
                self.sgr(body)
            return
        params = [int(p) if p.isdigit() else 0 for p in body.split(";")] if body else []

        def arg(index: int, default: int = 1) -> int:
            value = params[index] if index < len(params) else 0
            return value or default

        if private:
            if seq[0] == "?" and final in "hl":
                on = final == "h"
                for mode in params:
                    if mode == 25:
                        self.cursor_visible = on
                    elif mode in (47, 1047, 1049):
                        self.alternate(on, mode == 1049)
            return
        self.wrap_pending = False
        if final in "Hf":
            self.row = min(self.rows - 1, arg(0) - 1)
            self.col = min(self.cols - 1, arg(1) - 1)
        elif final == "A":
            self.row = max(0, self.row - arg(0))
        elif final in "Be":
            self.row = min(self.rows - 1, self.row + arg(0))
        elif final in "Ca":
            self.col = min(self.cols - 1, self.col + arg(0))
        elif final == "D":
            self.col = max(0, self.col - arg(0))
        elif final == "E":
            self.row, self.col = min(self.rows - 1, self.row + arg(0)), 0
        elif final == "F":
            self.row, self.col = max(0, self.row - arg(0)), 0
        elif final in "G`":
            self.col = min(self.cols - 1, arg(0) - 1)
        elif final == "d":
            self.row = min(self.rows - 1, arg(0) - 1)
        elif final == "J":
            self.erase_display(arg(0, 0))
        elif final == "K":
            self.erase_line(arg(0, 0))
        elif final == "X":
            count = min(arg(0), self.cols - self.col)
            self.grid[self.row][self.col:self.col + count] = self.blank_row()[:count]
        elif final == "P":
            row = self.grid[self.row]
            count = min(arg(0), self.cols - self.col)
            del row[self.col:self.col + count]
            row.extend(self.blank_row()[:count])
        elif final == "@":
            row = self.grid[self.row]
            count = min(arg(0), self.cols - self.col)
            row[self.col:self.col] = self.blank_row()[:count]
            del row[self.cols:]
        elif final in "LM":
            grid = self.grid
            for _ in range(min(arg(0), self.rows - self.row)):
                if final == "L":
                    grid.pop()
                    grid.insert(self.row, self.blank_row())
                else:
                    grid.pop(self.row)
                    grid.append(self.blank_row())
        elif final in "ST":
            grid = self.grid
            for _ in range(min(arg(0), self.rows)):
                if final == "S":
                    grid.pop(0)
                    grid.append(self.blank_row())
                else:
                    grid.pop()
                    grid.insert(0, self.blank_row())
        elif final == "s":
            self.saved = (self.row, self.col)
        elif final == "u":
            self.row, self.col = self.saved

    def erase_display(self, mode: int) -> None:
        grid = self.grid
        if mode == 0:
            self.erase_line(0)
            for index in range(self.row + 1, self.rows):
                grid[index] = self.blank_row()
        elif mode == 1:
            self.erase_line(1)
            for index in range(self.row):
                grid[index] = self.blank_row()
        elif mode in (2, 3):
            for index in range(self.rows):
                grid[index] = self.blank_row()

    def erase_line(self, mode: int) -> None:
        row = self.grid[self.row]
        blank = self.blank_row()
        if mode == 0:
            row[self.col:] = blank[self.col:]
        elif mode == 1:
            row[:self.col + 1] = blank[:self.col + 1]
        else:
            row[:] = blank

    def alternate(self, on: bool, save_cursor: bool) -> None:
        if on and self.alt is None:
            if save_cursor:
                self.saved = (self.row, self.col)
            self.alt = self.blank()
        elif not on and self.alt is not None:
            self.alt = None
            if save_cursor:
                self.row, self.col = self.saved


ELLIPSIS = "..."


class Renames:
    """The case's own names on screen, written as the fixture's at the same width, so no cell after them moves:
    each (name, replacement) in order, and each name's middle-truncated forms (`head...tail`, cmux-tui
    ui/mod.rs middle_truncate, which the files view uses for a long path) as the replacement cut to that width."""

    def __init__(self, pairs: Sequence[Tuple[str, str]] = ()):
        self.pairs = [(name, same_width(new, len(name))) for name, new in pairs if name]

    def apply(self, text: str) -> str:
        for name, new in self.pairs:
            text = untruncate(text.replace(name, new), name, new)
        return text


def untruncate(text: str, name: str, new: str) -> str:
    """`text` with each `head...tail` of `name` (a non-empty prefix and suffix around the ellipsis) replaced by
    `new` cut to the same width."""
    out, start = [], 0
    at = text.find(ELLIPSIS)
    while at != -1:
        head = next((n for n in range(min(at - start, len(name) - 1), 0, -1)
                     if text[at - n:at] == name[:n]), 0)
        after = at + len(ELLIPSIS)
        tail = next((n for n in range(min(len(text) - after, len(name) - 1), 0, -1)
                     if text[after:after + n] == name[-n:]), 0)
        if head and tail and head + tail < len(name):
            width = head + len(ELLIPSIS) + tail
            out.append(text[start:at - head] + same_width(new, width))
            start = after + tail
        else:
            out.append(text[start:after])
            start = after
        at = text.find(ELLIPSIS, start)
    out.append(text[start:])
    return "".join(out)


def screen_digest(screen: Screen, renames: Renames) -> str:
    """sha256 of the rows' text (trailing blanks dropped, the case's names renamed) and of their style runs."""
    text = renames.apply("\n".join(screen.lines()).rstrip("\n"))
    styles = "\n".join(screen.styles())
    return hashlib.sha256(f"{text}\n\n{styles}".encode("utf-8")).hexdigest()


def facet_value(screen: Screen, renames: Renames, exit_code: Optional[int]) -> Dict[str, Any]:
    """The tui facet (snapshot-v1 facets.tui) of `screen`."""
    return {
        "cols": screen.cols,
        "rows": screen.rows,
        "screenSha256": screen_digest(screen, renames),
        "cursor": {"row": screen.row, "col": screen.col, "visible": screen.cursor_visible},
        "exit": exit_code,
    }


def same_width(name: str, width: int) -> str:
    """`name` padded or cut to `width` columns, so a rename never moves the cells after it."""
    return (name + "_" * width)[:width]


# ---------------------------------------------------------------------------------------------------------
# The TUI process on the driver's PTY


class TuiExited(Exception):
    """The TUI exited (or hung up its PTY) while the driver waited on its screen."""


class TuiProcess:
    """`cmux-tui attach` on a PTY: a reader thread keeps the Screen and wakes waiters on each chunk.

    The reader owns the master: it closes it when the TUI hangs up or when `hang_up` wakes it through a pipe.
    Closing the master from another thread would not hang the terminal up while the reader sits in read(2) on it
    (the kernel keeps the file open for that call), so the TUI would never see the hang-up."""

    def __init__(self, argv: Sequence[str], env: Mapping[str, str], cwd: str, log_path: Path, cols: int = COLS,
                 rows: int = ROWS, spawn: Callable[..., subprocess.Popen] = subprocess.Popen):
        self.screen = Screen(cols, rows)
        self.changed = threading.Condition()
        # Held to write a key and to close the master; never while the reader feeds the screen, so a TUI that
        # blocks on its output cannot stall the reader behind a key write.
        self.writing = threading.Lock()
        self.chunks = 0
        self.eof = False
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        try:
            with open(log_path, "ab") as log:
                self.proc = spawn(list(argv), stdin=slave, stdout=slave, stderr=log, env=dict(env), cwd=cwd,
                                  preexec_fn=take_terminal, close_fds=True)
        except BaseException:
            os.close(master)
            raise
        finally:
            os.close(slave)
        self.master: Optional[int] = master
        wake_read, wake_write = os.pipe()
        self.wake_read: int = wake_read
        self.wake_write: Optional[int] = wake_write
        self.reader = threading.Thread(target=self.read_loop, name="tui-pty-reader", daemon=True)
        self.reader.start()

    @property
    def running(self) -> bool:
        return self.proc.poll() is None

    def read_loop(self) -> None:
        master = self.master
        assert master is not None
        with selectors.DefaultSelector() as selector:
            selector.register(master, selectors.EVENT_READ)
            selector.register(self.wake_read, selectors.EVENT_READ)
            while True:
                ready = {key.fd for key, _ in selector.select()}
                data = b""
                if self.wake_read not in ready:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        pass
                if not data:
                    with self.writing:
                        self.master = None
                        os.close(master)
                with self.changed:
                    if data:
                        self.screen.feed(data)
                        self.chunks += 1
                    else:
                        self.eof = True
                    self.changed.notify_all()
                if not data:
                    return

    def write(self, data: bytes) -> None:
        with self.writing:
            if self.master is None:
                raise TuiExited("the TUI's terminal is closed")
            os.write(self.master, data)

    def wait_screen(self, holds: Callable[[Screen], bool], deadline: float) -> bool:
        """True once `holds(screen)` is true; False at the deadline. TuiExited when the PTY hangs up first."""
        with self.changed:
            while True:
                if holds(self.screen):
                    return True
                if self.eof:
                    raise TuiExited("the TUI exited")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self.changed.wait(remaining)

    def refreshing(self) -> bool:
        """True while the TUI re-reads the daemon's tree after an event: a `remote-tree-refresh` thread
        (cmux-tui app/ordered_session/mutations.rs) is alive, so its result is not on screen yet. Linux reads the
        thread names from /proc; elsewhere there is no such reader and the fixed point alone decides."""
        tasks = Path(f"/proc/{self.proc.pid}/task")
        try:
            names = [(task / "comm").read_text(encoding="utf-8") for task in tasks.iterdir()]
        except OSError:
            return False
        return any(name.startswith(REFRESH_THREAD) for name in names)

    def read(self, view: Callable[[Screen], Any]) -> Any:
        """`view(screen)` under the reader's lock: one consistent screen."""
        with self.changed:
            return view(self.screen)

    def hang_up(self, timeout: float) -> Optional[int]:
        """The TUI's terminal hangs up, as when a terminal window closes: the reader closes the master. Then the
        exit; SIGKILL after `timeout`. The exit code, or None when it had to be killed."""
        if self.wake_write is not None:
            os.write(self.wake_write, b"x")
            self.reader.join(timeout)
            os.close(self.wake_write)
            os.close(self.wake_read)
            self.wake_write = None
        try:
            return self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
            return None


def take_terminal() -> None:
    """In the child: a session of its own with the PTY as its controlling terminal (SIGWINCH, hangup)."""
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


# ---------------------------------------------------------------------------------------------------------
# The case: driver_daemon.py's case plus the frontend and tui.key steps


def wants_tui(case: Mapping[str, Any]) -> bool:
    return TUI_CAPABILITY in (case.get("requires") or ())


def facet_pointer(step: Mapping[str, Any]) -> Optional[str]:
    wait = step.get("waitFor")
    return decode_pointer(wait["pointer"])[0] if wait else None


class TuiCaseRun(CaseRun):
    """A daemon case with `cmux-tui attach` on a PTY. Every checkpoint of such a case has the tui facet."""

    def __init__(self, binary: str, sha: str, schema: normalize.Schema, case: Mapping[str, Any],
                 ctx: Mapping[str, Any], session_ctx: Mapping[str, Any], isolation: Any):
        super().__init__(binary, sha, schema, case, ctx, session_ctx, isolation)
        self.ops["tui.key"] = self.op_tui_key
        self.tui: Optional[TuiProcess] = None
        self.tui_exit: Optional[int] = None
        self.tui_wait: Optional[Mapping[str, Any]] = None
        self.client_events: Optional[ClientEvents] = None

    # -- the frontend

    def attach(self, step: str) -> None:
        """`cmux-tui attach` with the case's environment, but its own config file (gen_tui.TUI_CONFIG), so the
        daemon's settings facet is the one every other product sees."""
        config = self.paths.root / TUI_CONFIG_FILE
        argv = self.case_env.command([self.daemon.binary, "attach", "--session", self.paths.session,
                                      "--socket", str(self.paths.socket)])
        try:
            config.write_text(json.dumps(TUI_CONFIG, indent=1, sort_keys=True), encoding="utf-8")
            env = {**self.case_env.env, "CMUX_TUI_CONFIG": str(config)}
            self.tui = TuiProcess(argv, env, str(self.case_env.cwd), self.paths.root / TUI_LOG)
        except OSError as error:
            raise CaseError("Crash", f"cannot start the TUI: {error}", step) from None
        status = f"[{self.paths.session}]"
        deadline = time.monotonic() + ATTACH_S * self.scale
        try:
            drawn = self.tui.wait_screen(lambda screen: any(status in line for line in screen.lines()), deadline)
        except TuiExited:
            raise CaseError("Crash", f"the TUI exited before its first frame: {self.tui_log_tail()}", step) from None
        if not drawn:
            raise CaseError("Timeout", f"the TUI drew no status bar in {ATTACH_S * self.scale:.0f} s", step)

    def tui_log_tail(self) -> str:
        return driver_daemon.log_tail(self.paths.root / TUI_LOG)

    def renames(self) -> Renames:
        """The case's own state root and session name as the fixture's ($ROOT, `oracle`)."""
        return Renames([(str(self.paths.root), "$ROOT"), (self.paths.session, SESSION_NAME)])

    def tui_facet(self) -> Dict[str, Any]:
        tui = self.tui
        if tui is None:
            return not_comparable("the case does not require tui, so no frontend is attached", TASK)
        if self.tui_exit is None and tui.eof:
            # Its terminal is closed: the exit follows, within the hang-up bound.
            try:
                self.tui_exit = tui.proc.wait(HANG_UP_S * self.scale)
            except subprocess.TimeoutExpired:
                pass
        renames = self.renames()
        return tui.read(lambda screen: facet_value(screen, renames, self.tui_exit))

    # -- settling

    def settle_frontend(self, step: str, bound_ms: Optional[int]) -> None:
        tui = self.tui
        if tui is None or not self.daemon.running:
            return
        bound = (bound_ms / 1000 if bound_ms else SETTLE_S) * self.scale
        deadline = time.monotonic() + bound
        if tui.eof:
            self.await_frontend_gone(step, deadline)
            return
        self.settle_terminals(step, deadline)
        last = None
        for _ in range(MAX_ROUNDS):
            self.barrier(step, deadline)
            state = None
            if not tui.refreshing():
                state = (tui.read(lambda screen: facet_value(screen, Renames(), None)), self.daemon_progress(step))
            if state is not None and state == last:
                return
            last = state
        raise CaseError("Timeout", f"the TUI's screen did not reach a fixed point in {MAX_ROUNDS} barrier rounds",
                        step)

    def await_frontend_gone(self, step: str, deadline: float) -> None:
        """A frontend that exited is settled once the daemon has dropped its connections from session.clients:
        woken by `client-detached` events on one subscription that then lives for the case (as
        driver_cli.CliCaseRun waits for a `cmux` call's connection), never by a sleep."""
        if self.client_events is None:
            try:
                self.client_events = ClientEvents(str(self.paths.socket), REQUEST_S * self.scale)
            except CmuxError as error:
                raise self.sdk_failure(error, step, "subscribe") from None
        while self.frontend_clients(step):
            try:
                woke = self.client_events.next_detach(deadline)
            except CmuxError as error:
                raise self.sdk_failure(error, step, "client-detached events") from None
            if not woke:
                raise CaseError("Timeout", "the exited TUI's connections stayed in session.clients", step)

    def frontend_clients(self, step: str) -> List[str]:
        clients = self.session_snapshot(step).get("clients") or ()
        return [c.get("id") for c in clients if isinstance(c, dict) and c.get("client_kind") == TUI_CLIENT_KIND]

    def settle_terminals(self, step: str, deadline: float) -> None:
        for terminal in self.running_terminals(step):
            remaining_ms = max(1, int((deadline - time.monotonic()) * 1000))
            params = {**SELECTORS, "terminal": terminal, "pattern": PROMPT_PATTERN, "timeout_ms": str(remaining_ms)}
            try:
                reply = self.daemon.request("terminal.wait", params, None, remaining_ms / 1000 + REQUEST_S)
            except CmuxError as error:
                raise self.sdk_failure(error, step, f"terminal.wait {terminal}") from None
            if not (isinstance(reply, dict) and reply.get("matched") is True):
                raise CaseError("Timeout", f"terminal {terminal} showed no shell prompt before the settle bound", step)

    def session_snapshot(self, step: str) -> Mapping[str, Any]:
        try:
            reply = self.daemon.request("session.snapshot", SELECTORS, None, REQUEST_S * self.scale)
        except CmuxError as error:
            raise self.sdk_failure(error, step, "session.snapshot") from None
        return reply if isinstance(reply, dict) else {}

    def running_terminals(self, step: str) -> List[str]:
        terminals = self.session_snapshot(step).get("terminals") or ()
        return sorted(t["id"] for t in terminals if isinstance(t, dict) and t.get("running") is True)

    def daemon_progress(self, step: str) -> Tuple[Any, ...]:
        """The daemon's revision and every terminal's output revision: what the frontend may still be drawing."""
        snapshot = self.session_snapshot(step)
        cursor = snapshot.get("cursor") or {}
        streams = tuple(sorted((t.get("id"), t.get("stream_revision")) for t in snapshot.get("terminals") or ()
                               if isinstance(t, dict)))
        return (cursor.get("generation"), cursor.get("revision"), streams)

    def barrier(self, step: str, deadline: float) -> None:
        """Ctrl-b, the prefix help bar, Escape, the bar gone: every key written before is handled and drawn."""
        tui = self.tui
        assert tui is not None
        for key, want, what in ((key_bytes(PREFIX_KEY), True, "show"), (CSI_U_ESCAPE, False, "hide")):
            try:
                tui.write(key)
                shown = tui.wait_screen(lambda screen, want=want: prefix_bar_shown(screen) is want, deadline)
            except (TuiExited, OSError):
                raise CaseError("Crash", f"the TUI exited during the settle barrier: {self.tui_log_tail()}",
                                step) from None
            if not shown:
                raise CaseError("Timeout", f"the settle barrier's prefix help bar did not {what}: the TUI is not in "
                                           "pane input mode (a step that leaves a prompt, menu or overlay open "
                                           "records only its before checkpoint)", step)

    # -- steps

    def run_step(self, index: int, step: Mapping[str, Any]) -> None:
        step_id = step["id"]
        if self.tui is None and wants_tui(self.case):
            self.attach(step_id)
        self.tui_wait = None
        if facet_pointer(step) == TUI_FACET:
            if step["op"] != "tui.key":
                raise CaseError("Crash", "a waitFor on /tui reads the screen a tui.key step changed", step_id)
            self.tui_wait = step["waitFor"]
            step = {key: value for key, value in step.items() if key != "waitFor"}
        super().run_step(index, step)

    def op_tui_key(self, index: int, step: Mapping[str, Any]) -> Tuple[str, Any]:
        step_id = step["id"]
        keys = check_keys(step)
        tui = self.tui
        if tui is None:
            raise CaseError("Crash", "a tui.key step needs a case that requires tui", step_id)
        wait = self.tui_wait
        baseline = resolve_pointer({TUI_FACET: self.tui_facet()}, wait["pointer"]) if wait else None
        try:
            for key in keys:
                tui.write(key)
        except (TuiExited, OSError):
            raise CaseError("Crash", f"the TUI exited before the step's keys: {self.tui_log_tail()}", step_id) from None
        if wait:
            self.wait_tui(step_id, wait, baseline)
        reply = {"keys": len(keys)}
        self.state.replies[step_id] = reply
        return ("ok", reply)

    def wait_tui(self, step: str, wait: Mapping[str, Any], baseline: Any) -> None:
        tui = self.tui
        assert tui is not None
        bound = wait["maxMs"] / 1000 * self.scale
        renames = self.renames()

        def holds(screen: Screen) -> bool:
            value = facet_value(screen, renames, self.tui_exit)
            return predicate_holds(wait, resolve_pointer({TUI_FACET: value}, wait["pointer"]), baseline)

        try:
            held = tui.wait_screen(holds, time.monotonic() + bound)
        except TuiExited:
            held = predicate_holds(wait, resolve_pointer({TUI_FACET: self.tui_facet()}, wait["pointer"]), baseline)
        if not held:
            raise CaseError("Timeout", f"waitFor {wait['pointer']} did not hold within {bound * 1000:.0f} ms", step)

    def check_expect(self, step: Mapping[str, Any], outcome: Tuple[str, Any]) -> None:
        if step["op"] != "tui.key":
            super().check_expect(step, outcome)

    # -- snapshots

    def capture(self, index: int, step: str, checkpoint: str, names: Sequence[str]) -> None:
        if self.tui is not None:
            spec = next((s for s in self.case.get("steps") or () if s.get("id") == step), {})
            self.settle_frontend(step, spec.get("settleMaxMs"))
            if TUI_FACET not in names:
                names = (*names, TUI_FACET)
        super().capture(index, step, checkpoint, names)

    def daemon_facet(self, step: str) -> Any:
        """The daemon facet with the panic log's file name, which holds the case's own session name, written with
        the fixture's (as CaseReads writes session.name), so two runs of a case hash equal."""
        facet = super().daemon_facet(step)
        panic_log = ((facet.get("oracle") or {}).get("panicLog") or {}) if isinstance(facet, dict) else {}
        if isinstance(panic_log.get("path"), str):
            name = Path(panic_log["path"])
            panic_log["path"] = str(name.with_name(name.name.replace(self.paths.session, SESSION_NAME)))
        return facet

    def facets(self, names: Sequence[str], step: str) -> Dict[str, Any]:
        out = super().facets([name for name in names if name != TUI_FACET], step)
        if TUI_FACET in names:
            out[TUI_FACET] = self.tui_facet()
        return out

    def snapshot(self, index: int, checkpoint: str, facets: Dict[str, Any]) -> Dict[str, Any]:
        value = super().snapshot(index, checkpoint, facets)
        value["meta"]["product"] = PRODUCT
        return value

    def shutdown(self) -> List[str]:
        """The frontend's terminal hangs up first (it must exit on its own: cmux-tui tests/tty_hangup_exit.rs),
        then the daemon case's teardown; a frontend still running after the bound is killed and fails the case."""
        problems: List[str] = []
        if self.client_events is not None:
            self.client_events.close()
        if self.tui is not None:
            bound = HANG_UP_S * self.scale
            if self.tui.hang_up(bound) is None:
                problems.append(f"the TUI did not exit {bound:.0f} s after its terminal hung up; it was killed")
        return problems + super().shutdown()


class TuiSession(DaemonSession):
    """driver_daemon.py's session whose case workers run TuiCaseRun (this file's case-worker)."""

    worker_script = Path(__file__).resolve()


def prefix_bar_shown(screen: Screen) -> bool:
    return any(PREFIX_BAR.search(line) for line in screen.lines())


def case_worker() -> int:
    return driver_daemon.case_worker(TuiCaseRun)


def open_session(session_ctx: Dict[str, Any]) -> TuiSession:
    if session_ctx.get("tag"):
        raise ValueError("the tui product runs on the Linux VM only (--binary): the TUI is cmux-tui's own frontend")
    return TuiSession(session_ctx)


# ---------------------------------------------------------------------------------------------------------
# CLI


def cmd_run_case(args: argparse.Namespace) -> int:
    case = json.loads(Path(args.case).read_text(encoding="utf-8"))
    run_id = args.run_id or f"tui-{os.getpid()}-{time.time_ns()}"
    session = open_session({"binary": args.binary, "run_id": run_id, "ref": args.ref, "isolation": args.isolation})
    base = args.state_base / short_token(run_id)
    ctx = {"case_id": f"{case['suite']}/{case['id']}", "key": "0", "state_root": str(base / short_token(case["id"]))}
    try:
        result = session.run_case(case, ctx)
    finally:
        session.close()
        remove_empty_dir(base)
    print(json.dumps(result, indent=1, sort_keys=True))
    return 0 if result["status"] == "Pass" else 1


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("case-worker", help="internal: one case from a JSON payload on stdin (TuiSession)")
    run_case = sub.add_parser("run-case", help="one case; its result JSON")
    run_case.add_argument("case", help="a case-v1 JSON file")
    run_case.add_argument("--binary", required=True, help="the cmux-tui built at the run SHA")
    run_case.add_argument("--ref", help="the run SHA; the binary's build receipt must name it")
    run_case.add_argument("--state-base", type=Path, default=DEFAULT_STATE_BASE)
    run_case.add_argument("--run-id")
    run_case.add_argument("--isolation", default="netns", help="netns (default), auto or none")
    args = parser.parse_args(argv)
    if args.command == "case-worker":
        return case_worker()
    try:
        return cmd_run_case(args)
    except ValueError as error:
        print(f"driver_tui.py: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
