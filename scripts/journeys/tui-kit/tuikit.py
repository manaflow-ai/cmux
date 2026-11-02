#!/usr/bin/env python3
"""Seeded terminal load for layout-animation videos (RESIZE VIDEOS, STATUS 4263).

One file, standard library only, Python 3.9 (the fleet minis' /usr/bin/python3). Each program takes
--seed N (the same seed gives the same output, frame for frame), --duration S (0: until a signal)
and ends cleanly: alternate screen left, cursor shown, mouse reporting and autowrap put back,
exit 0 on its deadline, SIGINT, SIGTERM or SIGHUP.

  tuikit.py gradient    full-screen truecolor gradient at --fps 120, box-drawing art, CJK and emoji
                        at known columns, a frame counter + timestamp + 20-bit barcode in a corner
  tuikit.py sigwinch    reflows a grid of numbered cards on every size change; logs every SIGWINCH
                        and every reflow with its time (--log)
  tuikit.py mouse       curses on the alternate screen, SGR 1006 mouse reporting, a mark where each
                        press lands, the cursor at a known cell, an inverted selection-like block
  tuikit.py flood       numbered, self-checking log lines as fast as the terminal takes them
  tuikit.py verify      reads flood lines (a screen read) and reports torn, stale or missing ones
  tuikit.py vim-scroll  vim on a generated large C file, scrolled steadily by a vim timer
  tuikit.py top         an htop look-alike (the minis have no htop or btop): meters, sorted table
  tuikit.py agent-stream  a coding agent's streamed answer (paragraphs, tool calls, diffs)
  tuikit.py html        writes the browser pane's page: CSS animations and a rAF frame counter
  tuikit.py serve       serves that page on 127.0.0.1 for --duration
  tuikit.py scenario    the seeded manifest: which program runs in which of N panes (4..12)
  tuikit.py describe    where gradient puts each element for a size (for the frame analyzer)

--fake-clock makes every shown time a function of the frame index (tests compare bytes); --frames N
stops after N frames. A program's --log is JSON lines with wall (time.time()) and mono
(time.monotonic()) stamps, so a video frame maps to a program frame.
"""
import argparse
import colorsys
import json
import os
import random
import re
import select
import shlex
import shutil
import signal
import subprocess
import sys
import time
import zlib

BSU = "\x1b[?2026h"  # begin synchronized update: the terminal shows the frame whole
ESU = "\x1b[?2026l"
RESET = "\x1b[0m"
ALT_ON = "\x1b[?1049h"
ALT_OFF = "\x1b[?1049l"
HIDE = "\x1b[?25l"
SHOW = "\x1b[?25h"
WRAP_OFF = "\x1b[?7l"
WRAP_ON = "\x1b[?7h"
MOUSE_ON = "\x1b[?1000h\x1b[?1002h\x1b[?1006h"
MOUSE_OFF = "\x1b[?1006l\x1b[?1002l\x1b[?1000l"

WORDS = ("anchor", "column", "divider", "frame", "glyph", "layout", "margin", "pixel", "reflow", "ribbon",
         "scroll", "shadow", "spring", "stripe", "surface", "tab", "tile", "vector", "viewport", "window",
         "budget", "cursor", "damage", "gutter", "kernel", "matrix", "packet", "render", "signal", "socket")
CJK = ("漢", "字", "か", "な", "カ", "ナ", "한", "글", "中", "文", "表", "示", "幕", "電", "脳", "端")
EMOJI = ("🚀", "🌈", "🔥", "🎉", "🐙", "💡", "🧪", "🍀", "🎯", "🛰", "🧭", "🪐", "🦀", "🐍", "🍣", "🎈")
# Every EMOJI entry is a single code point with Emoji_Presentation (2 columns, no VS16 or ZWJ),
# except U+1F6F0 (satellite), which needs VS16: it is replaced here so every one is wide alone.
EMOJI = tuple(e if e != "🛰" else "🌍" for e in EMOJI)


class Quit(Exception):
    pass


def _quit(signum, _frame):
    raise Quit(signum)


def install_quit():
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, _quit)


def calm():
    """First thing in a clean-up: a second signal (SIGHUP after SIGTERM when the pane closes) must not
    cut the restore sequence short."""
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, signal.SIG_IGN)


class Out:
    """Whole writes to a file descriptor (a frame never goes out half because of a short write)."""

    def __init__(self, fd=1):
        self.fd = fd

    def write(self, text):
        data = text.encode("utf-8") if isinstance(text, str) else text
        view = memoryview(data)
        while view:
            try:
                n = os.write(self.fd, view)
            except BlockingIOError:
                select.select([], [self.fd], [], 1.0)
                continue
            view = view[n:]


class Log:
    """JSON lines with wall and monotonic stamps; `flush_each` for rare events (SIGWINCH)."""

    def __init__(self, path, flush_each=False):
        self.f = open(path, "a", encoding="utf-8") if path else None
        self.flush_each = flush_each

    def event(self, ev, wall=None, mono=None, **fields):
        if not self.f:
            return
        fields["ev"] = ev
        fields["wall"] = round(time.time() if wall is None else wall, 6)
        fields["mono"] = round(time.monotonic() if mono is None else mono, 6)
        self.f.write(json.dumps(fields, sort_keys=True, ensure_ascii=False) + "\n")
        if self.flush_each:
            self.f.flush()

    def close(self):
        if self.f:
            self.f.close()
            self.f = None


def nonnegative(kind):
    def parse(text):
        value = kind(text)
        if value < 0:
            raise argparse.ArgumentTypeError("must be 0 or more")
        return value
    return parse


def parse_size(text):
    m = re.fullmatch(r"(\d+)x(\d+)", text or "")
    if not m or int(m.group(1)) < 1 or int(m.group(2)) < 1:
        raise argparse.ArgumentTypeError("size is COLSxROWS, for example 120x40")
    return int(m.group(1)), int(m.group(2))


def term_size(fd, fixed):
    if fixed:
        return fixed
    try:
        size = os.get_terminal_size(fd)
        return max(1, size.columns), max(1, size.lines)
    except OSError:
        return 80, 24


PACE_MODES = ("sleep", "hybrid", "spin", "rt")  # rt: the compiled programs' real-time thread; Python sleeps


class Pacer:
    """Frame k is due at start + k/fps. A late frame is drawn at once (never skipped: its index is the
    program frame the analyzer reads); more than 0.25 s behind, the schedule restarts from now.

    mode: how the wait ends. `sleep`: one time.sleep to the due time (a timer the OS may coalesce:
    on a fleet mini 266 of 601 frames came more than a frame late). `hybrid`: sleep to `spin_ms` before
    the due time, then poll the clock (costs about spin_ms per frame of CPU). `spin`: poll only (a
    whole core). The late time returned is measured after the wait, so it shows what the mode got."""

    def __init__(self, fps, mode="sleep", spin_ms=2.0, clock=time.monotonic, sleep=time.sleep):
        if mode not in PACE_MODES:
            raise ValueError("pace mode %r" % mode)
        self.period = 1.0 / fps if fps > 0 else 0.0
        self.mode = mode
        self.spin = spin_ms / 1000.0
        self.clock = clock
        self.sleep = sleep
        self.start = clock()
        self.base = 0
        self.before = 0.0  # how late the frame was before its wait (0 when it waited)

    def wait(self, k):
        """Waits for frame k; returns how late the frame starts after the wait (seconds)."""
        if not self.period:
            return 0.0
        due = self.start + (k - self.base) * self.period
        now = self.clock()
        if now < due:
            self.before = 0.0
            if self.mode in ("sleep", "rt"):  # Python has no real-time thread: rt sleeps
                self.sleep(due - now)
            else:
                if self.mode == "hybrid" and due - now > self.spin:
                    self.sleep(due - now - self.spin)
                while self.clock() < due:
                    pass  # pace: poll the clock to the due time (a sleep's wake-up may be coalesced late)
            return max(0.0, self.clock() - due)
        late = now - due
        self.before = late
        if late > 0.25:
            self.start, self.base = now, k
        return late


class Run:
    """Deadline and frame-count limits shared by every program."""

    def __init__(self, a):
        self.t0 = time.monotonic()
        self.duration = a.duration
        self.frames = a.frames

    def done(self, k):
        if self.frames and k >= self.frames:
            return True
        return bool(self.duration) and time.monotonic() - self.t0 >= self.duration


def shown_time(a, k, fps, t0):
    return k / fps if a.fake_clock else time.monotonic() - t0


def darwin_bg():
    """Whether this process is in the Darwin background class ("yes"/"no"; "n/a" off macOS)."""
    if sys.platform != "darwin":
        return "n/a"
    try:
        import ctypes
        libc = ctypes.CDLL(None, use_errno=True)
        value = libc.getpriority(4, 0)  # PRIO_DARWIN_PROCESS
        if value == -1:
            return "err%d" % ctypes.get_errno()
        return "yes" if value & 0x1000 else "no"
    except (OSError, AttributeError):
        return "?"


def rgb_hex(r, g, b):
    return "#%02x%02x%02x" % (r, g, b)


def hsv(h, s, v):
    r, g, b = colorsys.hsv_to_rgb(h % 1.0, s, v)
    return int(r * 255 + 0.5), int(g * 255 + 0.5), int(b * 255 + 0.5)


def bg(r, g, b):
    return "\x1b[48;2;%d;%d;%dm" % (r, g, b)


def fg(r, g, b):
    return "\x1b[38;2;%d;%d;%dm" % (r, g, b)


def clip_cells(cells, col, cols):
    """cells: [(text, width)]; keep those that fit whole between col and the right edge."""
    out, x = [], col
    for text, width in cells:
        if x + width > cols:
            break
        out.append(text)
        x += width
    return "".join(out)


# ---- gradient ------------------------------------------------------------------------------------

BIG = {
    "0": ("███", "█ █", "█ █", "█ █", "███"), "1": (" █ ", "██ ", " █ ", " █ ", "███"),
    "2": ("███", "  █", "███", "█  ", "███"), "3": ("███", "  █", "███", "  █", "███"),
    "4": ("█ █", "█ █", "███", "  █", "  █"), "5": ("███", "█  ", "███", "  █", "███"),
    "6": ("███", "█  ", "███", "█ █", "███"), "7": ("███", "  █", "  █", "  █", "  █"),
    "8": ("███", "█ █", "███", "█ █", "███"), "9": ("███", "█ █", "███", "  █", "███"),
}
BARCODE_BITS = 20
GUARD_START = (255, 0, 255)
GUARD_END = (0, 255, 255)
SPIN = "◐◓◑◒"
BOX_W = 28


def gradient_style(seed):
    rng = random.Random(seed)
    return {
        "hue": rng.random(), "sat": 0.55 + 0.4 * rng.random(), "val": 0.80 + 0.15 * rng.random(),
        "speed": rng.choice((1, 2, 3)), "diag": rng.choice((1, 2, 3)), "period": 240,
        "word": rng.choice(WORDS), "cjk": rng.sample(CJK, 8), "emoji": rng.sample(EMOJI, 8),
    }


def gradient_layout(cols, rows, style):
    """Where every overlay sits: one source for the drawing and for `describe`."""
    lay = {"size": [cols, rows],
           "hud": {"row": 0, "col": 0, "text": "F<7-digit frame> t=<seconds>s seed=<seed> <cols>x<rows>"},
           "barcode": {"row": 1, "col": 0, "cells": BARCODE_BITS + 2, "bits": BARCODE_BITS,
                       "start_guard": rgb_hex(*GUARD_START), "end_guard": rgb_hex(*GUARD_END),
                       "one": "#ffffff", "zero": "#000000",
                       "read": "cell 0 start guard, cells 1..20 the frame index modulo 2^20 MSB first "
                               "(white 1, black 0), cell 21 end guard"},
           "box": {"row": 3, "col": 2, "width": BOX_W, "height": 7},
           "wide": [], "emoji": [], "ruler": {"row": 13, "col": 2, "text": ("0123456789" * 3)[:24]}}
    for i in range(8):
        lay["wide"].append({"row": 11, "col": 2 + 3 * i, "char": chr(65 + i), "width": 1})
        lay["wide"].append({"row": 11, "col": 3 + 3 * i, "char": style["cjk"][i], "width": 2})
        lay["emoji"].append({"row": 12, "col": 2 + 3 * i, "char": str(i), "width": 1})
        lay["emoji"].append({"row": 12, "col": 3 + 3 * i, "char": style["emoji"][i], "width": 2})
    if cols >= 50 and rows >= 18:
        lay["big_counter"] = {"row": rows - 6, "col": cols - 24, "digits": 6, "height": 5,
                              "read": "the frame index modulo 10^6 in 3x5 block digits, one blank column apart"}
    return lay


def cmd_build_bins(a):
    """cargo build --release of rust/ (std only, no network); prints where the programs are."""
    cargo = shutil.which("cargo") or os.path.expanduser("~/.cargo/bin/cargo")
    if not os.access(cargo, os.X_OK):
        sys.stderr.write("build-bins: no cargo on PATH or in ~/.cargo/bin\n")
        return 69
    # --target-dir: a CARGO_TARGET_DIR or build.target elsewhere would put the programs where rust_bin()
    # does not look
    done = subprocess.run([cargo, "build", "--release", "--offline", "--manifest-path",
                           os.path.join(RUST_DIR, "Cargo.toml"), "--target-dir", os.path.join(RUST_DIR, "target")])
    if done.returncode != 0:
        return done.returncode
    built = {name: rust_bin(name) for name in RUST_PROGRAMS}
    print(json.dumps(dict(bin_dir=os.path.join(RUST_DIR, "target", "release"), **built)))
    return 0 if all(built.values()) else 1


def cmd_beacon(a):
    """The SWITCH FRAMES beacon, compiled (tk-beacon; there is no Python engine)."""
    path = rust_bin("tk-beacon")
    if not path:
        sys.stderr.write("beacon: no tk-beacon (run `tuikit.py build-bins` on this Mac)\n")
        return 2
    argv = [path, "--ws", str(a.ws), "--pane", str(a.pane), "--hz", repr(float(a.hz)), "--cell-cols",
            str(a.cell_cols), "--pace", a.pace, "--spin-ms", repr(float(a.spin_ms)), "--duration", repr(float(a.duration))]
    if a.fill:
        argv.append("--fill")
    if a.label:
        argv += ["--label", a.label]
    if a.log:
        argv += ["--log", a.log]
    sys.stdout.flush()
    os.execv(path, argv)


def cmd_describe(a):
    style = gradient_style(a.seed)
    cols, rows = a.size or (120, 40)
    print(json.dumps(gradient_layout(cols, rows, style), ensure_ascii=False, indent=2))
    return 0


class Gradient:
    def __init__(self, a):
        self.a = a
        self.style = gradient_style(a.seed)
        st = self.style
        self.strip = []
        for i in range(st["period"]):
            self.strip.append(bg(*hsv(st["hue"] + i / st["period"], st["sat"], st["val"])) + " " * a.cell)
        self.size = None
        self.white = bg(255, 255, 255) + " "
        self.black = bg(0, 0, 0) + " "
        self.ink = "\x1b[0;97;40m"

    def resize(self, cols, rows):
        self.size = (cols, rows)
        self.items = (cols + self.a.cell - 1) // self.a.cell
        reps = (self.items + self.style["period"]) // self.style["period"] + 1
        self.strip2 = self.strip * reps
        self.layout = gradient_layout(cols, rows, self.style)

    def frame(self, k, t):
        cols, rows = self.size
        st, lay = self.style, self.layout
        period = st["period"]
        parts = [BSU] if self.a.sync else []
        tail = cols - (self.items - 1) * self.a.cell  # the last item's width (cell 2, odd cols: 1)
        last = self.items - 1
        for y in range(rows):
            off = (y * st["diag"] + k * st["speed"]) % period
            row = self.strip2[off:off + self.items]
            if tail != self.a.cell:
                row = row[:last] + [row[last][:-(self.a.cell - tail)]]
            parts.append("\x1b[%d;1H" % (y + 1))
            parts.append("".join(row))
        parts.append(self.ink)
        hud = " F%07d t=%9.3fs seed=%d %dx%d " % (k, t, self.a.seed, cols, rows)
        parts.append("\x1b[1;1H" + hud[:cols])
        if cols >= BARCODE_BITS + 2 and rows >= 2:
            code = k % (1 << BARCODE_BITS)
            bits = [self.white if (code >> i) & 1 else self.black for i in range(BARCODE_BITS - 1, -1, -1)]
            parts.append("\x1b[2;1H" + bg(*GUARD_START) + " " + "".join(bits) + bg(*GUARD_END) + " " + self.ink)
        box = lay["box"]
        inner = BOX_W - 2
        spin = SPIN[k % 4]
        lines = ["╔" + "═" * inner + "╗",
                 "║" + (" tui-gradient %s" % st["word"]).ljust(inner)[:inner] + "║",
                 "║ ┌────────┐ ┌────────┐ " + spin + "  ║",
                 "║ │F%07d│ │s%7d│    ║" % (k % 10000000, self.a.seed % 10000000),
                 "║ └────────┘ └────────┘    ║",
                 "║ ░▒▓█ ▏▎▍▌▋▊▉█ ━┃┏┓┗┛╋    ║",
                 "╚" + "═" * inner + "╝"]
        for i, line in enumerate(lines):
            y = box["row"] + i
            if y < rows:
                parts.append("\x1b[%d;%dH" % (y + 1, box["col"] + 1) + clip_cells([(c, 1) for c in line], box["col"], cols))
        for key in ("wide", "emoji"):
            row = lay[key][0]["row"]
            if row < rows:
                cells = [(e["char"], e["width"]) for e in lay[key]]
                parts.append("\x1b[%d;%dH" % (row + 1, 3) + clip_cells(cells, 2, cols))
        ruler = lay["ruler"]
        if ruler["row"] < rows:
            parts.append("\x1b[%d;%dH" % (ruler["row"] + 1, ruler["col"] + 1)
                         + clip_cells([(c, 1) for c in ruler["text"]], ruler["col"], cols))
        big = lay.get("big_counter")
        if big:
            digits = "%06d" % (k % 1000000)
            for r in range(5):
                parts.append("\x1b[%d;%dH" % (big["row"] + r + 1, big["col"] + 1)
                             + " ".join(BIG[d][r] for d in digits))
        parts.append(RESET)
        if self.a.sync:
            parts.append(ESU)
        return "".join(parts)


RUST_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rust")
RATE_FLOOR = 0.95  # cmux-ad 03:40Z: a run below 95 % of its target rate is NOT RUN
RUST_PROGRAMS = ("tk-gradient", "tk-storm", "tk-beacon")


def rust_bin(name):
    """The compiled program `name` (tuikit.py build-bins), or None: $CMUX_TUIKIT_BIN_DIR, else rust/target/release."""
    folder = os.environ.get("CMUX_TUIKIT_BIN_DIR") or os.path.join(RUST_DIR, "target", "release")
    path = os.path.join(folder, name)
    return path if os.access(path, os.X_OK) else None


def gradient_rust_argv(a, path):
    """tk-gradient's command line for these options: the seeded style from gradient_style(seed)."""
    st = gradient_style(a.seed)
    argv = [path, "--seed", str(a.seed), "--hue", repr(st["hue"]), "--sat", repr(st["sat"]), "--val", repr(st["val"]),
            "--speed", str(st["speed"]), "--diag", str(st["diag"]), "--word", st["word"], "--cjk", "".join(st["cjk"]),
            "--emoji", "".join(st["emoji"]), "--fps", repr(float(a.fps)), "--cell", str(a.cell), "--frames",
            str(a.frames), "--duration", repr(float(a.duration)), "--pace", a.pace, "--spin-ms", repr(float(a.spin_ms))]
    if not a.sync:
        argv.append("--no-sync")
    if a.size:
        argv += ["--size", "%dx%d" % a.size]
    if a.fake_clock:
        argv.append("--fake-clock")
    if a.log:
        argv += ["--log", a.log]
    return argv


def cmd_gradient(a):
    if a.engine != "python":
        path = rust_bin("tk-gradient")
        if path:
            sys.stdout.flush()
            os.execv(path, gradient_rust_argv(a, path))  # the pane runs the compiled program itself
        if a.engine == "rust":
            sys.stderr.write("gradient: no tk-gradient (run `tuikit.py build-bins` on this Mac)\n")
            return 2
    out = Out()
    log = Log(a.log)
    winch = [True]
    if not a.size:
        signal.signal(signal.SIGWINCH, lambda *_: winch.__setitem__(0, True))
    install_quit()
    g = Gradient(a)
    run, pacer = Run(a), Pacer(a.fps, a.pace, a.spin_ms)
    k = 0
    first = last = None
    try:
        out.write(ALT_ON + HIDE + WRAP_OFF + "\x1b[2J")
        log.event("start", program="gradient", seed=a.seed, fps=a.fps, pace=a.pace, spin_ms=a.spin_ms,
                  darwin_bg=darwin_bg(), pid=os.getpid(), engine="python")
        while not run.done(k):
            if winch[0]:
                winch[0] = False
                cols, rows = term_size(1, a.size)
                if (cols, rows) != g.size:
                    g.resize(cols, rows)
                    log.event("size", cols=cols, rows=rows, frame=k)
            late = pacer.wait(k)
            drawn, drawn_wall = time.monotonic(), time.time()
            first = drawn if first is None else first
            last = drawn
            text = g.frame(k, shown_time(a, k, a.fps, run.t0))
            out.write(text)
            # late_ms: how late the frame starts after its wait (a sleep that woke late counts);
            # before_ms: how late it already was before the wait (the frame before took too long).
            log.event("frame", frame=k, late_ms=round(late * 1000, 3), before_ms=round(pacer.before * 1000, 3),
                      bytes=len(text.encode()), draw_ms=round((time.monotonic() - drawn) * 1000, 3), mono=drawn,
                      wall=drawn_wall)
            k += 1
    except Quit:
        pass
    finally:
        calm()
        out.write(ESU + RESET + WRAP_ON + SHOW + ALT_OFF)
        achieved = (k - 1) / (last - first) if k > 1 and last > first else 0.0
        verdict = "n/a" if a.fake_clock or k < 2 else ("NOT RUN" if achieved < RATE_FLOOR * a.fps else "ok")
        log.event("end", frames=k, darwin_bg=darwin_bg(), achieved_fps=round(achieved, 3), target_fps=a.fps,
                  verdict=verdict, engine="python")
        log.close()
    return 0


# ---- sigwinch ------------------------------------------------------------------------------------

class Reflow:
    def __init__(self, a):
        self.a = a
        rng = random.Random(a.seed)
        self.card_w = 10 + rng.randrange(7)
        self.hue = rng.random()
        self.words = [rng.choice(WORDS) for _ in range(512)]

    def header(self, cols, n_winch, n_reflow, t):
        text = " SIGWINCH %dx%d winch=%d reflow=%d seed=%d t=%.2fs " % (cols, self.rows, n_winch, n_reflow, self.a.seed, t)
        return "\x1b[1;1H\x1b[0;30;47m" + text[:cols].ljust(cols) + RESET

    def draw(self, cols, rows, n_winch, n_reflow, t):
        self.rows = rows
        tint = bg(*hsv(self.hue + n_reflow * 0.29, 0.6, 0.30))
        parts = [BSU, RESET, "\x1b[2J", self.header(cols, n_winch, n_reflow, t)]
        if rows >= 2:
            ruler = []
            for x in range(cols):
                ruler.append("\x1b[1;33m%d\x1b[0;37m" % ((x // 10) % 10) if x % 10 == 0 else str(x % 10))
            parts.append("\x1b[2;1H\x1b[0;37m" + "".join(ruler) + RESET)
        w = self.card_w
        per_row = max(1, (cols - 1) // w)
        avail = max(0, rows - 3)
        card = 0
        for band in range(avail // 3):
            y = 2 + band * 3
            top, mid, bot = [], [], []
            for c in range(per_row):
                if (c + 1) * w > cols - 1:
                    break
                label = "#%03d %s" % (card, self.words[card % len(self.words)])
                top.append("┌" + "─" * (w - 2) + "┐")
                mid.append("│" + label.ljust(w - 2)[:w - 2] + "│")
                bot.append("└" + "─" * (w - 2) + "┘")
                card += 1
            for i, line in enumerate((top, mid, bot)):
                parts.append("\x1b[%d;1H" % (y + i + 1) + tint + "\x1b[97m" + "".join(line)
                             + " " * max(0, cols - 1 - len(line) * w) + RESET)
        for y in range(1, rows - 1):
            parts.append("\x1b[%d;%dH\x1b[0;91m▐" % (y + 1, cols))
        if rows >= 3:
            label = "└ bottom row %d of %d, %d cards " % (rows, rows, card)
            line = (label + "─" * cols)[:max(0, cols - 1)] + "┘"
            parts.append("\x1b[%d;1H\x1b[0;95m" % rows + line[:cols])
        parts.append(RESET + ESU)
        return "".join(parts)


def cmd_sigwinch(a):
    out = Out()
    log = Log(a.log, flush_each=True)
    pending = []
    rfd, wfd = os.pipe()
    os.set_blocking(wfd, False)
    signal.set_wakeup_fd(wfd)

    def on_winch(_sig, _frame):
        cols, rows = term_size(1, a.size)
        pending.append((time.time(), time.monotonic(), cols, rows))

    signal.signal(signal.SIGWINCH, on_winch)
    install_quit()
    r = Reflow(a)
    run = Run(a)
    n_winch = n_reflow = ticks = 0
    cols, rows = term_size(1, a.size)
    try:
        out.write(ALT_ON + HIDE + WRAP_OFF)
        log.event("start", program="sigwinch", seed=a.seed, cols=cols, rows=rows)
        out.write(r.draw(cols, rows, 0, 0, 0.0))
        tick_period = 1.0 / a.tick if a.tick > 0 else None
        next_tick = time.monotonic() + (tick_period or 0)
        while not run.done(ticks):
            timeout = 0.25
            if tick_period:
                timeout = max(0.0, min(timeout, next_tick - time.monotonic()))
            if run.duration:
                timeout = max(0.0, min(timeout, run.t0 + run.duration - time.monotonic()))
            ready, _, _ = select.select([rfd], [], [], timeout)
            if ready:
                os.read(rfd, 4096)
            while pending:
                wall, mono, wc, wr = pending.pop(0)
                n_winch += 1
                log.event("sigwinch", wall=wall, mono=mono, n=n_winch, cols=wc, rows=wr)
            now_size = term_size(1, a.size)
            if now_size != (cols, rows):
                cols, rows = now_size
                n_reflow += 1
                out.write(r.draw(cols, rows, n_winch, n_reflow, shown_time(a, ticks, a.tick or 1, run.t0)))
                log.event("reflow", n=n_reflow, cols=cols, rows=rows, winch=n_winch)
            if tick_period and time.monotonic() >= next_tick:
                ticks += 1
                next_tick += tick_period
                if next_tick < time.monotonic():
                    next_tick = time.monotonic() + tick_period
                out.write(BSU + r.header(cols, n_winch, n_reflow, shown_time(a, ticks, a.tick, run.t0)) + ESU)
    except Quit:
        pass
    finally:
        calm()
        signal.set_wakeup_fd(-1)
        out.write(ESU + RESET + WRAP_ON + SHOW + ALT_OFF)
        log.event("end", winch=n_winch, reflow=n_reflow, ticks=ticks)
        log.close()
    return 0


# ---- mouse (curses) ------------------------------------------------------------------------------

SGR_MOUSE = re.compile(rb"\x1b\[<(\d+);(\d+);(\d+)([Mm])")


def mouse_known_cell(cols, rows):
    """The cell the cursor rests on: (row, col), 0-based."""
    return rows // 2, cols // 2


def mouse_selection(cols, rows):
    """The inverted block: rows 3..5 (0-based), from column 4, up to 32 columns."""
    if rows < 9 or cols < 12:
        return None
    return {"row": 3, "col": 4, "rows": 3, "cols": min(32, cols - 8)}


def cmd_mouse(a):
    import curses

    log = Log(a.log, flush_each=True)
    rfd, wfd = os.pipe()
    os.set_blocking(wfd, False)
    signal.set_wakeup_fd(wfd)
    signal.signal(signal.SIGWINCH, lambda *_: None)  # set before initscr: ncurses keeps it; we poll the size
    install_quit()
    os.environ.setdefault("ESCDELAY", "25")
    rng = random.Random(a.seed)
    sel_lines = [" ".join(rng.choice(WORDS) for _ in range(6)) for _ in range(3)]
    marks = {}
    clicks = 0
    last = None
    held = False
    run = Run(a)
    ticks = 0
    out = Out()
    stdscr = None
    try:
        stdscr = curses.initscr()
        curses.noecho()
        curses.cbreak()
        stdscr.keypad(False)
        stdscr.nodelay(True)
        try:
            curses.start_color()
            curses.use_default_colors()
            for i, color in enumerate((curses.COLOR_RED, curses.COLOR_GREEN, curses.COLOR_BLUE, curses.COLOR_YELLOW)):
                curses.init_pair(i + 1, color, -1)
        except curses.error:
            pass
        try:
            curses.curs_set(1)
        except curses.error:
            pass
        out.write(MOUSE_ON)
        cols, rows = term_size(1, None)
        log.event("start", program="mouse", seed=a.seed, cols=cols, rows=rows,
                  cursor=list(mouse_known_cell(cols, rows)), selection=mouse_selection(cols, rows))

        def put(y, x, text, attr=0):
            if 0 <= y < rows and 0 <= x < cols:
                try:
                    stdscr.addstr(y, x, text[:max(0, cols - x - (1 if y == rows - 1 else 0))], attr)
                except curses.error:
                    pass

        def draw(t):
            stdscr.erase()
            put(0, 0, (" tui-mouse seed=%d %dx%d clicks=%d last=%s t=%.2fs" %
                       (a.seed, cols, rows, clicks, last or "-", t)).ljust(cols), curses.A_BOLD | curses.A_REVERSE)
            put(1, 0, " press anywhere: a digit marks each press (button color); drag marks dots; q quits")
            sel = mouse_selection(cols, rows)
            if sel:
                for i in range(sel["rows"]):
                    put(sel["row"] + i, sel["col"], sel_lines[i].ljust(sel["cols"])[:sel["cols"]], curses.A_REVERSE)
            for (y, x), (ch, pair) in marks.items():
                put(y, x, ch, curses.color_pair(pair) | curses.A_BOLD)
            cy, cx = mouse_known_cell(cols, rows)
            put(cy, max(0, cx - 1), "[")
            put(cy, cx + 1, "]")
            try:
                stdscr.move(cy, cx)
            except curses.error:
                pass
            out.write(BSU)
            stdscr.refresh()
            out.write(ESU)

        tick_period = 1.0 / a.tick if a.tick > 0 else None
        next_tick = time.monotonic() + (tick_period or 0)
        draw(0.0)
        buf = b""
        while not run.done(ticks):
            timeout = 0.25
            if tick_period:
                timeout = max(0.0, min(timeout, next_tick - time.monotonic()))
            if run.duration:
                timeout = max(0.0, min(timeout, run.t0 + run.duration - time.monotonic()))
            ready, _, _ = select.select([0, rfd], [], [], timeout)
            dirty = False
            if rfd in ready:
                os.read(rfd, 4096)
            while True:
                ch = stdscr.getch()
                if ch == -1:
                    break
                if 0 <= ch < 256:
                    buf += bytes([ch])
            while buf:
                m = SGR_MOUSE.search(buf)
                if b"q" in buf[:m.start() if m else len(buf)]:
                    raise Quit(0)
                if not m:
                    if b"\x1b" not in buf:
                        buf = b""
                    else:
                        buf = buf[buf.index(b"\x1b"):]
                        if len(buf) > 64:
                            buf = b""
                    break
                b, x, y, kind = int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4)
                buf = buf[m.end():]
                button = b & 3
                motion = bool(b & 32)
                if b & 64:
                    log.event("wheel", b=b, x=x, y=y)
                elif kind == b"M" and not motion:
                    clicks += 1
                    held = True
                    last = "(%d,%d,b%d)" % (x, y, button)
                    marks[(y - 1, x - 1)] = (str(clicks % 10), button % 4 + 1)
                    log.event("press", n=clicks, b=button, x=x, y=y)
                elif kind == b"M" and motion and held:
                    marks.setdefault((y - 1, x - 1), ("·", button % 4 + 1))
                    log.event("drag", b=button, x=x, y=y)
                elif kind == b"m":
                    held = False
                    log.event("release", b=button, x=x, y=y)
                dirty = True
                if len(marks) > 4096:
                    marks.clear()
            size = term_size(1, None)
            if size != (cols, rows):
                cols, rows = size
                curses.resizeterm(rows, cols)
                log.event("resize", cols=cols, rows=rows, cursor=list(mouse_known_cell(cols, rows)))
                dirty = True
            if tick_period and time.monotonic() >= next_tick:
                ticks += 1
                next_tick += tick_period
                if next_tick < time.monotonic():
                    next_tick = time.monotonic() + tick_period
                dirty = True
            if dirty:
                draw(shown_time(a, ticks, a.tick or 1, run.t0))
    except Quit:
        pass
    finally:
        calm()
        signal.set_wakeup_fd(-1)
        out.write(MOUSE_OFF)
        if stdscr is not None:
            curses.endwin()
        log.event("end", clicks=clicks, ticks=ticks)
        log.close()
    return 0


# ---- flood ---------------------------------------------------------------------------------------

FLOOD_LINE = re.compile(r"(\d{10}) s(\d+) (.*) #([0-9a-f]{8})")


def flood_payloads(seed, width):
    rng = random.Random(seed)
    out = []
    for _ in range(509):
        text = ""
        while len(text) < width:
            text += rng.choice(WORDS) + rng.choice((" ", "-", "_", "/", ".", ":"))
        out.append(text)
    return out


def flood_line(seed, n, width, payloads):
    """Line n: its number, the seed, a seeded payload and a CRC-32 of everything before ' #'."""
    core = ("%010d s%d %s" % (n, seed, payloads[(n * 7919 + seed) % len(payloads)]))[:width - 10].rstrip()
    return "%s #%08x" % (core, zlib.crc32(core.encode()) & 0xffffffff)


def cmd_flood(a):
    need = len("%010d s%d " % (0, a.seed)) + 12
    if a.width < max(32, need):
        sys.exit("flood: --width is at least %d for seed %d" % (max(32, need), a.seed))
    stop = []
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):  # a batch is never cut: stop between batches
        signal.signal(sig, lambda signum, _frame: stop.append(signum))
    out = Out()
    log = Log(a.log)
    payloads = flood_payloads(a.seed, a.width)
    colors = ("\x1b[0m", "\x1b[32m", "\x1b[33m", "\x1b[36m", "\x1b[35m", "\x1b[34m")
    run = Run(a)
    n = 0
    batch = max(1, a.rate // 120) if a.rate else 512
    log.event("start", program="flood", seed=a.seed, rate=a.rate, width=a.width)
    try:
        while not stop:
            if a.lines and n >= a.lines:
                break
            if run.duration and time.monotonic() - run.t0 >= run.duration:
                break
            count = batch if not a.lines else min(batch, a.lines - n)
            if a.color:
                text = "".join(colors[(n + i) % 6] + flood_line(a.seed, n + i, a.width, payloads) + "\n"
                               for i in range(count))
            else:
                text = "".join(flood_line(a.seed, n + i, a.width, payloads) + "\n" for i in range(count))
            out.write(text)
            n += count
            if a.rate:
                due = run.t0 + n / a.rate
                now = time.monotonic()
                if due > now:
                    time.sleep(due - now)
    finally:
        calm()
        out.write(RESET + "tuikit flood end lines=%d\n" % n)
        log.event("end", lines=n)
        log.close()
    return 0


def verify_lines(lines):
    """What a screen read of flood output shows: valid lines, torn ones (a line number with a bad CRC),
    and jumps between consecutive valid lines (a gap or a line out of order: stale or lost rows)."""
    report = {"lines": 0, "valid": 0, "torn": [], "jumps": [], "other": 0, "first": None, "last": None}
    prev = None
    for raw in lines:
        line = raw.rstrip("\r\n").rstrip()
        if not line:
            continue
        report["lines"] += 1
        m = FLOOD_LINE.fullmatch(line)
        if not m:
            if re.match(r"\d{10} s\d+ ", line):
                report["torn"].append({"line": line[:120], "why": "no checksum"})
            else:
                report["other"] += 1
            continue
        core = line[:line.rindex(" #")]
        if "%08x" % (zlib.crc32(core.encode()) & 0xffffffff) != m.group(4):
            report["torn"].append({"line": line[:120], "why": "checksum"})
            continue
        n = int(m.group(1))
        report["valid"] += 1
        if report["first"] is None:
            report["first"] = n
        report["last"] = n
        if prev is not None and n != prev + 1:
            report["jumps"].append({"after": prev, "next": n})
        prev = n
    report["ok"] = not report["torn"] and not report["jumps"] and report["valid"] > 0
    return report


def cmd_verify(a):
    with (open(a.file, encoding="utf-8", errors="replace") if a.file else sys.stdin) as f:
        report = verify_lines(f.readlines())
    print(json.dumps(report, indent=2))
    return 0 if report["ok"] else 1


# ---- vim-scroll ----------------------------------------------------------------------------------

def vim_file_lines(seed, count):
    rng = random.Random(seed)
    lines = ["/* tuikit vim-scroll seed=%d lines=%d */" % (seed, count), "#include <stdio.h>", ""]
    n = len(lines)
    while n < count:
        w1, w2, w3 = rng.choice(WORDS), rng.choice(WORDS), rng.choice(WORDS)
        kind = rng.randrange(6)
        if kind == 0:
            line = "/* L%06d */ // %s %s %s: \"%s\" %d" % (n + 1, w1, w2, w3, w1.upper(), rng.randrange(10 ** 6))
        elif kind == 1:
            line = "/* L%06d */ static int %s_%d(int %s) { return %s * %d + %d; }" % (
                n + 1, w1, n, w2, w2, rng.randrange(97), rng.randrange(1000))
        elif kind == 2:
            line = "/* L%06d */ #define %s_%s_%d 0x%08x" % (n + 1, w1.upper(), w2.upper(), n, rng.getrandbits(32))
        elif kind == 3:
            line = "/* L%06d */     if (%s > %d && %s != NULL) { printf(\"%%s\\n\", \"%s\"); }" % (
                n + 1, w1, rng.randrange(100), w2, w3)
        elif kind == 4:
            line = "/* L%06d */ struct %s { double %s; char %s[%d]; };" % (n + 1, w1, w2, w3, rng.randrange(8, 64))
        else:
            line = "/* L%06d */     for (int i = 0; i < %d; i++) %s[i] = %s(i) ^ 0x%x;" % (
                n + 1, rng.randrange(1000), w1, w2, rng.getrandbits(16))
        lines.append(line)
        n += 1
    return lines


def vim_script(seed, interval_ms, step, duration, log):
    out = ["set nocompatible", "set number", "set laststatus=2", "set noshowmode", "set nomore",
           "set shortmess+=I", "syntax on", "let g:tk_tick = 0", "let g:tk_t0 = reltime()",
           "let g:tk_log = %s" % json.dumps(log or ""),
           "set statusline=tuikit-vim\\ seed=%d\\ line\\ %%l/%%L\\ top\\ %%{line('w0')}\\ tick\\ %%{g:tk_tick}" % seed,
           "func! TkScroll(t)",
           "  let g:tk_tick += 1",
           "  if line('w$') >= line('$')",
           "    normal! gg",
           "  else",
           "    exe \"normal! %d\\<C-e>\"" % step,
           "  endif",
           "  if g:tk_log != ''",
           "    call writefile([printf('{\"ev\":\"tick\",\"tick\":%d,\"t\":%.6f,\"top\":%d}', g:tk_tick,"
           " reltimefloat(reltime(g:tk_t0)), line('w0'))], g:tk_log, 'a')",
           "  endif",
           "  redraw",
           "endfunc",
           "func! TkQuit(t)",
           "  qa!",
           "endfunc",
           "call timer_start(%d, 'TkScroll', {'repeat': -1})" % interval_ms]
    if duration:
        out.append("call timer_start(%d, 'TkQuit')" % int(duration * 1000))
    out.append("call delete(expand('<sfile>:p'))")  # the script is read whole by now: leave no file behind
    return "\n".join(out) + "\n"


def write_atomic(path, text):
    tmp = "%s.tmp-%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def cmd_vim_scroll(a):
    tmp = os.environ.get("TMPDIR") or "/tmp"
    path = a.file or os.path.join(tmp, "tuikit-vim-%d.c" % a.seed)
    script = os.path.join(os.path.dirname(path) or ".", "tuikit-vim-%d-%d.vim" % (a.seed, os.getpid()))
    write_atomic(path, "\n".join(vim_file_lines(a.seed, a.lines)) + "\n")
    write_atomic(script, vim_script(a.seed, a.interval_ms, a.step, a.duration, a.log))
    if a.print_only:
        print(json.dumps({"file": path, "script": script}))
        return 0
    vim = a.vim or "vim"
    argv = [vim, "-N", "-u", "NONE", "-i", "NONE", "-n", "-S", script, path]
    try:
        os.execvp(vim, argv)
    except OSError as error:
        sys.stderr.write("vim-scroll: cannot run %s: %s\n" % (vim, error))
        return 69


# ---- top -----------------------------------------------------------------------------------------

PROC_NAMES = ("kernel_task", "WindowServer", "cmux", "cmux-tui", "acpmux", "zsh", "vim", "python3", "node",
              "cargo", "rustc", "swift-frontend", "clang", "mds_stores", "Safari", "launchd", "syslogd",
              "coreaudiod", "bun", "git", "ssh", "tailscaled", "Finder", "Dock", "ghostty", "ld64", "make")


class Top:
    def __init__(self, a):
        self.a = a
        self.rng = random.Random(a.seed)
        rng = self.rng
        self.cores = [rng.random() * 60 for _ in range(a.cores)]
        self.procs = []
        for i in range(160):
            self.procs.append({"pid": 100 + rng.randrange(90000), "user": rng.choice(("lawrence", "root", "_windowserver")),
                               "name": rng.choice(PROC_NAMES), "cpu": rng.random() * 40 * rng.random(),
                               "mem": rng.random() * 4, "time": rng.randrange(36000)})
        self.mem = 0.4 + rng.random() * 0.4

    def step(self):
        rng = self.rng
        self.cores = [min(100.0, max(0.0, c + rng.uniform(-12, 12))) for c in self.cores]
        for p in self.procs:
            p["cpu"] = min(400.0, max(0.0, p["cpu"] + rng.uniform(-3, 3) * (1 + p["cpu"] / 20)))
            p["time"] += int(p["cpu"])
        self.mem = min(0.97, max(0.2, self.mem + rng.uniform(-0.01, 0.01)))

    def frame(self, k, t, cols, rows):
        parts = [BSU, "\x1b[H"]
        line = []

        def emit(text):
            line.append(text + "\x1b[0m\x1b[K")

        half = max(1, (len(self.cores) + 1) // 2)
        bar_w = max(4, cols // 2 - 12)
        for i in range(half):
            seg = []
            for j in (i, i + half):
                if j >= len(self.cores):
                    continue
                v = self.cores[j]
                fill = int(round(bar_w * v / 100))
                seg.append("%3d\x1b[1m[\x1b[0;32m%s\x1b[31m%s\x1b[0m%s%5.1f%%\x1b[1m]\x1b[0m " % (
                    j + 1, "|" * (fill * 2 // 3), "|" * (fill - fill * 2 // 3), " " * (bar_w - fill), v))
            emit(" ".join(seg))
        fill = int(round(bar_w * self.mem))
        emit("  Mem\x1b[1m[\x1b[0;32m%s\x1b[0m%s%4.1fG/16G\x1b[1m]\x1b[0m" % ("|" * fill, " " * (bar_w - fill), 16 * self.mem))
        emit("  Tasks: %d  Load: %.2f  F%07d t=%.2fs seed=%d" % (len(self.procs), sum(self.cores) / 100, k, t, self.a.seed))
        emit("\x1b[30;42m%7s %-10s %6s %5s %9s  %s" % ("PID", "USER", "CPU%", "MEM%", "TIME+", "Command") + " " * cols)
        procs = sorted(self.procs, key=lambda p: (-p["cpu"], p["pid"]))
        for p in procs[:max(0, rows - len(line) - 1)]:
            hot = "\x1b[1;31m" if p["cpu"] > 50 else ""
            emit("%7d %-10s %s%6.1f\x1b[0m %5.1f %3d:%02d.%02d  %s" % (
                p["pid"], p["user"][:10], hot, p["cpu"], p["mem"], p["time"] // 6000, (p["time"] // 100) % 60,
                p["time"] % 100, p["name"]))
        for i, text in enumerate(line[:rows]):
            parts.append("\x1b[%d;1H" % (i + 1) + text)
        parts.append("\x1b[J" + ESU)
        return "".join(parts)


def cmd_top(a):
    out = Out()
    log = Log(a.log)
    install_quit()
    top = Top(a)
    run, pacer = Run(a), Pacer(a.fps, a.pace, a.spin_ms)
    k = 0
    try:
        out.write(ALT_ON + HIDE + WRAP_OFF + "\x1b[2J")
        while not run.done(k):
            cols, rows = term_size(1, a.size)
            late = pacer.wait(k)
            top.step()
            text = top.frame(k, shown_time(a, k, a.fps, run.t0), cols, rows)
            out.write(text)
            log.event("frame", frame=k, late_ms=round(late * 1000, 3))
            k += 1
    except Quit:
        pass
    finally:
        calm()
        out.write(ESU + RESET + WRAP_ON + SHOW + ALT_OFF)
        log.event("end", frames=k)
        log.close()
    return 0


# ---- agent-stream --------------------------------------------------------------------------------

def agent_blocks(seed):
    """An endless, seeded coding-agent answer: ("heading"|"para"|"tool"|"diff", ...). Shared with
    agent_stream_acp.py, the agent pane's stand-in harness."""
    rng = random.Random(seed)
    p = 0
    while True:
        p += 1
        yield ("heading", "Step %d [p%04d]" % (p, p))
        for _ in range(rng.randrange(1, 3)):
            words = [rng.choice(WORDS) for _ in range(rng.randrange(30, 70))]
            yield ("para", "[p%04d] " % p + " ".join(words).capitalize() + ".")
        kind = rng.randrange(3)
        if kind == 0:
            cmd = "rg -n '%s' src --glob '*.%s' | head -n 8" % (rng.choice(WORDS), rng.choice(("ts", "swift", "rs")))
            out = ["src/%s/%s.ts:%d: const %s = %s(%d)" % (rng.choice(WORDS), rng.choice(WORDS), rng.randrange(900),
                                                            rng.choice(WORDS), rng.choice(WORDS), rng.randrange(99))
                   for _ in range(rng.randrange(3, 8))]
            yield ("tool", cmd, out)
        elif kind == 1:
            name = rng.choice(WORDS)
            lines = []
            for _ in range(rng.randrange(4, 10)):
                sign = rng.choice((" ", "+", "-"))
                lines.append("%s    let %s = %s.%s(%d)" % (sign, rng.choice(WORDS), name, rng.choice(WORDS), rng.randrange(64)))
            yield ("diff", "Sources/%s.swift" % name.capitalize(), lines)
        else:
            yield ("tool", "bun test test/%s.test.ts" % rng.choice(WORDS),
                   ["bun test v1.3", "", " %d pass" % rng.randrange(5, 60), " 0 fail",
                    "Ran tests across 1 file. [%d.00ms]" % rng.randrange(80, 900)])


def agent_terminal_text(block, width):
    import textwrap
    kind = block[0]
    if kind == "heading":
        return "\n\x1b[1;35m⏺\x1b[0;1m %s\x1b[0m\n" % block[1]
    if kind == "para":
        return "\n".join(textwrap.wrap(block[1], width)) + "\n"
    if kind == "tool":
        body = "".join("  \x1b[2m⎿\x1b[0m  %s\n" % line if i == 0 else "     %s\n" % line for i, line in enumerate(block[2]))
        return "\x1b[1;32m⏺\x1b[0m Bash(%s)\n%s" % (block[1], body)
    colors = {"+": "\x1b[32m", "-": "\x1b[31m", " ": "\x1b[0m"}
    body = "".join("%s%s\x1b[0m\n" % (colors[line[0]], line) for line in block[2])
    return "\x1b[1;36m⏺\x1b[0m Update(%s)\n%s" % (block[1], body)


def tokens(text, rng):
    i = 0
    while i < len(text):
        n = rng.randrange(1, 7)
        if text[i] == "\x1b":  # never split an escape sequence
            end = text.find("m", i)
            n = max(n, end - i + 1)
        yield text[i:i + n]
        i += n


def cmd_agent_stream(a):
    install_quit()
    out = Out()
    log = Log(a.log)
    rng = random.Random(a.seed ^ 0x5EED)
    run = Run(a)
    sent = 0
    log.event("start", program="agent-stream", seed=a.seed, cps=a.cps)
    try:
        for block in agent_blocks(a.seed):
            text = agent_terminal_text(block, a.width)
            for tok in tokens(text, rng):
                if (a.chars and sent >= a.chars) or (run.duration and time.monotonic() - run.t0 >= run.duration):
                    raise Quit(0)
                out.write(tok)
                sent += len(tok)
                if a.cps and not a.fake_clock:
                    due = run.t0 + sent / a.cps
                    now = time.monotonic()
                    if due > now:
                        time.sleep(due - now)
    except Quit:
        pass
    finally:
        calm()
        out.write(RESET + "\n")
        log.event("end", chars=sent)
        log.close()
    return 0


# ---- browser page --------------------------------------------------------------------------------

def page_html(seed):
    rng = random.Random(seed)
    c1 = rgb_hex(*hsv(rng.random(), 0.8, 0.95))
    c2 = rgb_hex(*hsv(rng.random(), 0.8, 0.95))
    c3 = rgb_hex(*hsv(rng.random(), 0.7, 0.9))
    word = rng.choice(WORDS)
    return """<!doctype html>
<html><head><meta charset="utf-8"><title>tuikit anim seed=%(seed)d</title>
<style>
html,body{margin:0;height:100%%;background:#101014;color:#eee;overflow:hidden;font:16px/1.25 Menlo,monospace}
#count{position:absolute;left:2vw;top:2vh;font-size:10vh;font-weight:700;letter-spacing:.05em}
#bits{position:absolute;left:2vw;top:15vh;display:flex;gap:.4vh}
#bits i{display:block;width:3vh;height:3vh;background:#000;outline:1px solid #555}
#bits i.on{background:#fff}
#bits i.g0{background:#f0f}#bits i.g1{background:#0ff}
#stats{position:absolute;left:2vw;top:20vh;font-size:2.4vh;white-space:pre}
#label{position:absolute;right:2vw;top:2vh;font-size:3vh}
#track{position:absolute;left:0;right:0;top:34vh;height:14vh;border-top:1px solid #333;border-bottom:1px solid #333}
#bar{position:absolute;left:0;top:1vh;width:12vw;height:12vh;background:linear-gradient(90deg,%(c1)s,%(c2)s);
 animation:slide 1s linear infinite;will-change:transform}
@keyframes slide{from{transform:translateX(0)}to{transform:translateX(88vw)}}
#spin{position:absolute;left:10vw;top:56vh;width:16vh;height:16vh;background:%(c3)s;animation:spin .5s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
#pulse{position:absolute;left:40vw;top:56vh;width:16vh;height:16vh;border-radius:50%%;background:%(c2)s;
 animation:pulse .75s ease-in-out infinite alternate}
@keyframes pulse{from{transform:scale(.4);opacity:.3}to{transform:scale(1);opacity:1}}
#hue{position:absolute;left:0;right:0;bottom:0;height:14vh;background:linear-gradient(90deg,%(c1)s,%(c2)s,%(c3)s);
 animation:hue 2s linear infinite}
@keyframes hue{to{filter:hue-rotate(360deg)}}
</style></head><body>
<div id="count">F 000000</div><div id="bits"></div><div id="stats">waiting for frames</div>
<div id="label">tuikit seed=%(seed)d %(word)s</div>
<div id="track"><div id="bar"></div></div><div id="spin"></div><div id="pulse"></div><div id="hue"></div>
<script>
// One requestAnimationFrame callback per display frame: F is the page frame index, the boxes are
// F modulo 2^16 MSB first (white 1, black 0) between a magenta and a cyan guard, as the TUI barcode.
const BITS = 16, count = document.getElementById('count'), stats = document.getElementById('stats');
const bits = document.getElementById('bits'), cells = [];
const g0 = document.createElement('i'); g0.className = 'g0'; bits.appendChild(g0);
for (let i = 0; i < BITS; i++) { const c = document.createElement('i'); bits.appendChild(c); cells.push(c); }
const g1 = document.createElement('i'); g1.className = 'g1'; bits.appendChild(g1);
const deltas = []; let frame = 0, last = 0, long = 0;
window.tuikit = {seed: %(seed)d, frames: 0, longFrames: 0, deltas};
function tick(ts) {
  frame++;
  count.textContent = 'F ' + String(frame).padStart(6, '0');
  const code = frame %% 65536;
  for (let i = 0; i < BITS; i++) cells[i].className = (code >> (BITS - 1 - i)) & 1 ? 'on' : '';
  if (last) {
    const d = ts - last; deltas.push(d); if (deltas.length > 240) deltas.shift();
    const sorted = deltas.slice().sort((a, b) => a - b), median = sorted[sorted.length >> 1];
    if (d > median * 1.5) long++;
    if (frame %% 30 === 0) {
      stats.textContent = 'fps ' + (1000 / median).toFixed(1) + '  median ' + median.toFixed(2) + ' ms  max ' +
        sorted[sorted.length - 1].toFixed(2) + ' ms\\nlong frames (>1.5x median) ' + long;
    }
  }
  last = ts; window.tuikit.frames = frame; window.tuikit.longFrames = long;
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
</script></body></html>
""" % {"seed": seed, "c1": c1, "c2": c2, "c3": c3, "word": word}


def cmd_html(a):
    text = page_html(a.seed)
    if a.out in (None, "-"):
        sys.stdout.write(text)
    else:
        write_atomic(a.out, text)
        print(json.dumps({"html": os.path.abspath(a.out), "url": "file://" + os.path.abspath(a.out)}))
    return 0


def cmd_serve(a):
    import functools
    import http.server
    import threading

    os.makedirs(a.dir, exist_ok=True)
    name = "anim-%d.html" % a.seed
    write_atomic(os.path.join(a.dir, name), page_html(a.seed))
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

    handler = functools.partial(Quiet, directory=a.dir)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", a.port), handler)
    print(json.dumps({"url": "http://127.0.0.1:%d/%s" % (server.server_address[1], name)}), flush=True)
    install_quit()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        deadline = time.monotonic() + a.duration if a.duration else None
        while deadline is None or time.monotonic() < deadline:
            time.sleep(0.2)
    except Quit:
        pass
    finally:
        calm()
        server.shutdown()
    return 0


# ---- scenario ------------------------------------------------------------------------------------

KINDS = ("gradient", "sigwinch", "mouse", "flood", "vim-scroll", "top")
EXTRA = ("gradient", "gradient", "flood", "sigwinch", "vim-scroll", "top", "mouse")


def pane_programs(panes, seed):
    """N terminal programs: gradient and sigwinch always; every kind once from 6 panes; the rest
    seeded (gradient twice as likely); then a seeded order."""
    rng = random.Random(seed * 7 + panes)
    rest = list(KINDS[2:])
    rng.shuffle(rest)
    chosen = ["gradient", "sigwinch"] + rest
    chosen = chosen[:panes]
    while len(chosen) < panes:
        chosen.append(rng.choice(EXTRA))
    rng.shuffle(chosen)
    return chosen


def grid_layout(panes):
    """Columns and rows per column for N panes: ceil(sqrt(N)) columns, rows spread evenly."""
    cols = 1
    while cols * cols < panes:
        cols += 1
    per = [panes // cols + (1 if i < panes % cols else 0) for i in range(cols)]
    return {"columns": cols, "rows_per_column": per,
            "order": "pane i fills column 0 top to bottom, then column 1, ..."}


def program_argv(python, kit, program, seed, duration, log, extra=()):
    argv = [python, kit, program, "--seed", str(seed), "--duration", str(duration)]
    if log:
        argv += ["--log", log]
    return argv + list(extra)


def build_manifest(a):
    if not 1 <= a.panes <= 32:
        sys.exit("scenario: --panes is 1..32 (the kit is made for 4..12)")
    kit = a.kit or os.path.abspath(__file__)
    kit_dir = os.path.dirname(kit)
    out = a.out or os.path.join(os.environ.get("TMPDIR") or "/tmp", "tuikit-%d" % a.seed)
    programs = pane_programs(a.panes, a.seed)
    expect = {
        "gradient": "every frame changes; the corner barcode and F counter give the program frame",
        "sigwinch": "one reflow (new tint, new size in the header) at the end of a resize; log counts SIGWINCH",
        "mouse": "cursor at (rows//2, cols//2) between [ ] and the inverted block stay still",
        "flood": "numbered lines; `tuikit.py verify` on a screen read finds no torn or out-of-order line",
        "vim-scroll": "steady scroll; the status line shows the top line and tick",
        "top": "meters and a sorted table redrawn at --fps",
    }
    panes = []
    for i, program in enumerate(programs):
        pseed = a.seed * 100 + i + 1
        log = os.path.join(out, "p%02d-%s.jsonl" % (i, program))
        extra = []
        if program == "flood" and a.flood_rate:
            extra = ["--rate", str(a.flood_rate)]
        argv = program_argv(a.python, kit, program, pseed, a.duration, log, extra)
        panes.append({"pane": i, "program": program, "seed": pseed, "argv": argv, "command": shlex.join(argv),
                      "log": log, "expect": expect[program]})
    manifest = {"version": 1, "seed": a.seed, "panes_count": a.panes, "duration": a.duration, "kit": kit, "out": out,
                "setup": [["mkdir", "-p", out]], "layout": grid_layout(a.panes), "panes": panes}
    if a.browser:
        html = os.path.join(out, "anim-%d.html" % a.seed)
        write = [a.python, kit, "html", "--seed", str(a.seed), "--out", html]
        manifest["setup"].append(write)
        manifest["browser"] = {"html": html, "url": "file://" + html, "write": write,
                               "serve": [a.python, kit, "serve", "--seed", str(a.seed), "--dir", out,
                                         "--port", "0", "--duration", str(a.duration)],
                               "expect": "rAF counter F and 16-bit boxes advance one per display frame; "
                                         "window.tuikit.longFrames counts frames > 1.5x the median"}
    if a.agent != "none":
        aseed = a.seed * 100 + 99
        terminal = program_argv(a.python, kit, "agent-stream", aseed, a.duration, os.path.join(out, "agent.jsonl"))
        manifest["agent"] = {
            "mode": a.agent, "seed": aseed,
            "acp": {"harness": "tuikit-stream", "argv": [a.python, os.path.join(kit_dir, "agent_stream_acp.py")],
                    "prompt": "stream: %d %s 400" % (aseed, a.duration),
                    "how": "write ACPMUX_HOME/harnesses/tuikit-stream.toml (see agent_stream_acp.py), open an "
                           "agent chat on it and send the prompt; fake_agent.py must sit beside "
                           "agent_stream_acp.py or be named by CMUX_TUIKIT_FAKE_AGENT"},
            "terminal": {"argv": terminal, "command": shlex.join(terminal)}}
    return manifest


def cmd_scenario(a):
    manifest = build_manifest(a)
    text = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    if a.write:
        os.makedirs(manifest["out"], exist_ok=True)
        if "browser" in manifest:
            write_atomic(manifest["browser"]["html"], page_html(a.seed))
        write_atomic(os.path.join(manifest["out"], "manifest.json"), text)
    sys.stdout.write(text)
    return 0


# ---- command line --------------------------------------------------------------------------------

def positive(text):
    value = float(text)
    if not value > 0:
        raise argparse.ArgumentTypeError("must be above 0")
    return value


def pace_args(p, default):
    # gradient defaults to spin: on a fleet mini (job 0a364ec0ef40, cmux21, 30 s each) sleep and hybrid
    # woke in bursts (frame interval p50 0.4 ms, p95 47 / 43 ms, about 1100-1300 wake-ups for 3600
    # frames; taskpolicy -t0 -l0, taskpolicy -B and caffeinate -i did not change it), while spin held
    # p50 8.33 / p95 8.33 / max 8.34 ms at one core. A load that is meant to draw at 120 fps spins.
    p.add_argument("--pace", choices=PACE_MODES, default=default,
                   help="how a frame wait ends: sleep, hybrid (sleep, then poll the last --spin-ms), spin "
                        "(default %s)" % default)
    p.add_argument("--spin-ms", type=float, default=2.0, help="hybrid: milliseconds polled before each frame")


def common(p, duration=30.0, size=False):
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--duration", type=nonnegative(float), default=duration, help="seconds; 0 runs until a signal")
    p.add_argument("--frames", type=nonnegative(int), default=0, help="stop after N frames (ticks); 0: no limit")
    p.add_argument("--fake-clock", action="store_true", help="shown times come from the frame index (tests)")
    p.add_argument("--log", help="JSON lines of events with wall and mono stamps")
    if size:
        p.add_argument("--size", type=parse_size, help="COLSxROWS instead of the terminal's (tests, describe)")


def build_parser():
    ap = argparse.ArgumentParser(prog="tuikit.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("gradient", help="120 fps truecolor gradient, art, CJK, emoji, frame counter")
    common(p, size=True)
    p.add_argument("--fps", type=positive, default=120.0)
    pace_args(p, "spin")
    p.add_argument("--cell", type=int, choices=(1, 2), default=1, help="columns per gradient color step")
    p.add_argument("--no-sync", dest="sync", action="store_false", help="no synchronized-update brackets")
    p.add_argument("--engine", choices=("auto", "rust", "python"), default="auto",
                   help="auto (default): the compiled tk-gradient when built (build-bins), else Python")
    p.set_defaults(fn=cmd_gradient)
    p = sub.add_parser("beacon", help="SWITCH FRAMES beacon (compiled tk-beacon): pane id and uptime clock in colors")
    p.add_argument("--ws", type=nonnegative(int), required=True)
    p.add_argument("--pane", type=nonnegative(int), default=0)
    p.add_argument("--hz", type=positive, default=240.0)
    p.add_argument("--cell-cols", type=int, choices=(1, 2, 3, 4), default=2)
    p.add_argument("--fill", action="store_true")
    p.add_argument("--label")
    p.add_argument("--duration", type=nonnegative(float), default=0.0)
    p.add_argument("--log")
    # rt, not spin: a SWITCH profile runs 18 beacons at 240 Hz, and 18 spinning cores would be the load
    # under test; rt is a real-time thread that waits with mach_wait_until (pace_probe's rust-rt row
    # says whether it holds the rate; the end event's verdict says it per run)
    pace_args(p, "rt")
    p.set_defaults(fn=cmd_beacon)
    p = sub.add_parser("build-bins", help="build the compiled programs (cargo, on this Mac)")
    p.set_defaults(fn=cmd_build_bins)
    p = sub.add_parser("describe", help="gradient's element positions for --size")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--size", type=parse_size)
    p.set_defaults(fn=cmd_describe)
    p = sub.add_parser("sigwinch", help="reflow on every size change; log every SIGWINCH")
    common(p, size=True)
    p.add_argument("--tick", type=float, default=10.0, help="header clock updates a second (0: none)")
    p.set_defaults(fn=cmd_sigwinch)
    p = sub.add_parser("mouse", help="curses, SGR 1006 mouse, known cursor cell, inverted block")
    common(p)
    p.add_argument("--tick", type=float, default=4.0, help="header clock updates a second (0: none)")
    p.set_defaults(fn=cmd_mouse)
    p = sub.add_parser("flood", help="numbered, checksummed log lines, yes-fast")
    common(p)
    p.add_argument("--rate", type=int, default=0, help="lines a second; 0: as fast as the terminal reads")
    p.add_argument("--width", type=int, default=48, help="characters a line (keep under the pane's columns)")
    p.add_argument("--lines", type=int, default=0, help="stop after N lines")
    p.add_argument("--color", action="store_true", help="an SGR color per line")
    p.set_defaults(fn=cmd_flood)
    p = sub.add_parser("verify", help="check flood lines from a screen read (stdin or --file)")
    p.add_argument("--file")
    p.set_defaults(fn=cmd_verify)
    p = sub.add_parser("vim-scroll", help="vim scrolling a generated file")
    common(p)
    p.add_argument("--lines", type=int, default=100000)
    p.add_argument("--interval-ms", type=int, default=8, help="one scroll every N ms (8: about 120 a second)")
    p.add_argument("--step", type=int, default=1, help="lines per scroll")
    p.add_argument("--file", help="where the generated file goes (default $TMPDIR/tuikit-vim-SEED.c)")
    p.add_argument("--vim", help="the vim binary (default vim on PATH)")
    p.add_argument("--print-only", action="store_true", help="write the file and script, print them, no vim")
    p.set_defaults(fn=cmd_vim_scroll)
    p = sub.add_parser("top", help="htop look-alike (seeded, synthetic)")
    common(p, size=True)
    p.add_argument("--fps", type=positive, default=30.0)
    pace_args(p, "sleep")
    p.add_argument("--cores", type=int, default=10)
    p.set_defaults(fn=cmd_top)
    p = sub.add_parser("agent-stream", help="a coding agent's streamed answer in a terminal")
    common(p)
    p.add_argument("--cps", type=float, default=400.0, help="characters a second")
    p.add_argument("--chars", type=int, default=0, help="stop after N characters")
    p.add_argument("--width", type=int, default=72)
    p.set_defaults(fn=cmd_agent_stream)
    p = sub.add_parser("html", help="write the browser pane's CSS-animation page")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--out", help="file to write (default stdout)")
    p.set_defaults(fn=cmd_html)
    p = sub.add_parser("serve", help="serve the page on 127.0.0.1")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--dir", default=os.path.join(os.environ.get("TMPDIR") or "/tmp", "tuikit-www"))
    p.add_argument("--port", type=int, default=0, help="0 picks a free port (printed)")
    p.add_argument("--duration", type=float, default=600.0)
    p.set_defaults(fn=cmd_serve)
    p = sub.add_parser("scenario", help="seeded manifest: which program runs in which pane")
    p.add_argument("--panes", type=int, required=True, help="terminal panes, 4..12")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--duration", type=float, default=120.0)
    p.add_argument("--kit", help="tuikit.py path on the Mac that runs the panes (default this file)")
    p.add_argument("--out", help="logs and page folder (default $TMPDIR/tuikit-SEED)")
    p.add_argument("--python", default="/usr/bin/python3")
    p.add_argument("--flood-rate", type=int, default=0)
    p.add_argument("--no-browser", dest="browser", action="store_false")
    p.add_argument("--agent", choices=("acp", "terminal", "none"), default="acp")
    p.add_argument("--write", action="store_true", help="also write OUT/manifest.json and the page")
    p.set_defaults(fn=cmd_scenario)
    return ap


def main(argv=None):
    a = build_parser().parse_args(argv)
    try:
        return a.fn(a) or 0
    except BrokenPipeError:  # the reader went away (`| head`): end quietly
        try:
            os.dup2(os.open(os.devnull, os.O_WRONLY), 1)
        except OSError:
            pass
        return 0


if __name__ == "__main__":
    sys.exit(main())
