#!/usr/bin/env python3
"""Pixel-border terminal fixture for real-app resize films (PIXEL PERFECT kit, video-cases/gen_pixel.py).

One file, standard library only, Python 3.9 (the fleet minis' /usr/bin/python3). gen_pixel.py writes it to the
mini with the driver's `file` step (/tmp/jr-tui-border.py) and types `python3 /tmp/jr-tui-border.py --fill ...`
into each terminal pane, as the TUI kit's load is started.

On the alternate screen, every cell gets an explicit 24-bit background (SGR 48;2), so no cell shows the terminal
theme's background; only Ghostty's padding (the strip outside the whole cells) does, and the cases set that theme
color to a different loud color (#00FFFF). The picture, 0-based rows and columns:

  ring 1   the outermost row and column on each side (row 0, row R-1, column 0, column C-1): --ring1 (#FF0000)
  ring 2   the next ones (row 1, row R-2, column 1, column C-2): --ring2 (#FFFFFF)
  ring 3   the third ones (row 2, row R-3, column 2, column C-3): --ring3 (#000000)
  fill     every other cell: --fill (one loud color per pane, e.g. #FFFF00, #00FF00, #0000FF)
  ruler    column index mod 10 on row --ruler-at (default 3) and row index mod 10 on column --ruler-at, from
           --ruler-at to the last cell inside ring 3; a multiple of 10 is drawn inverted. Default 3, the first
           row and column inside the rings, so every ring cell stays one solid color for the scan judge;
           --ruler-at 2 draws the ruler on ring 3 itself, 0 turns it off.
  centre   --label, COLSxROWS, the frame counter and the SIGWINCH count, in the middle rows

Ring cells hold no glyph: along any scan line a ring is one run of one color, exactly one cell wide.

It redraws the whole screen inside a synchronized update (mode 2026: the terminal shows each frame whole) at once
on every SIGWINCH (the self-pipe wakes it) and every 1/--fps s (default 60; a late frame is drawn at once, never
skipped). Echo and canonical input are off while it runs (a stray key never paints the screen); Ctrl-C (SIGINT),
SIGTERM and SIGHUP end it: the alternate screen is left, autowrap, the cursor and the tty modes are put back, exit 0.

  tui_border.py --fill '#FFFF00' --label p0 [--fps 60] [--duration 0] [--frames 0] [--log PATH]
  tui_border.py --size 40x12 --frames 1 --fill '#00FF00'    # one frame for a size, for tests (no tty needed)

--log writes JSON lines (wall time.time(), mono time.monotonic()) for the start, each SIGWINCH and the end.
"""
import argparse
import json
import os
import re
import select
import signal
import sys
import time

BSU = "\x1b[?2026h"  # begin synchronized update: the terminal shows the frame whole
ESU = "\x1b[?2026l"
RESET = "\x1b[0m"
ALT_ON = "\x1b[?1049h"
ALT_OFF = "\x1b[?1049l"
HIDE = "\x1b[?25l"
SHOW = "\x1b[?25h"
WRAP_OFF = "\x1b[?7l"
WRAP_ON = "\x1b[?7h"
RINGS = 3


class Quit(Exception):
    pass


def _quit(signum, _frame):
    raise Quit(signum)


def calm():
    """First thing in a clean-up: a second signal (SIGHUP after SIGTERM when the pane closes) must not cut the
    restore sequence short."""
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, signal.SIG_IGN)


def color(text):
    m = re.fullmatch(r"#?([0-9a-fA-F]{6})", text or "")
    if not m:
        raise argparse.ArgumentTypeError("a color is #RRGGBB, for example #FFFF00")
    v = m.group(1)
    return int(v[0:2], 16), int(v[2:4], 16), int(v[4:6], 16)


def parse_size(text):
    m = re.fullmatch(r"(\d+)x(\d+)", text or "")
    if not m:
        raise argparse.ArgumentTypeError("size is COLSxROWS, for example 120x40")
    return int(m.group(1)), int(m.group(2))


def bg(rgb):
    return "\x1b[48;2;%d;%d;%dm" % rgb


def fg(rgb):
    return "\x1b[38;2;%d;%d;%dm" % rgb


INK_DARK, INK_LIGHT = (104, 104, 104), (152, 152, 152)


def ink_on(rgb):
    """A text color that reads on RGB and is none of the fixture's loud colors: every channel strictly between the
    judge's 96 and 160 ("other": never a ring, a fill, the shell or the ground). The darker gray on a light fill."""
    luma = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
    return INK_DARK if luma > 110 else INK_LIGHT


class Out:
    """Whole writes to a file descriptor (a frame never goes out half because of a short write)."""

    def __init__(self, fd=1):
        self.fd = fd

    def write(self, text):
        view = memoryview(text.encode("utf-8"))
        while view:
            try:
                n = os.write(self.fd, view)
            except BlockingIOError:
                select.select([], [self.fd], [], 1.0)
                continue
            view = view[n:]


class Log:
    def __init__(self, path):
        self.f = open(path, "a", encoding="utf-8") if path else None

    def event(self, ev, **fields):
        if self.f:
            fields.update(ev=ev, wall=round(time.time(), 6), mono=round(time.monotonic(), 6))
            self.f.write(json.dumps(fields, sort_keys=True) + "\n")
            self.f.flush()

    def close(self):
        if self.f:
            self.f.close()
            self.f = None


def ring_of(r, c, rows, cols):
    """0, 1, 2 for the rings (0 outermost), RINGS for a fill cell."""
    return min(r, c, rows - 1 - r, cols - 1 - c, RINGS)


class Picture:
    """The frame for one size. The rings, the fill and the ruler only change with the size, so they are built
    once per size (`static`); each frame adds the centre lines (`frame`)."""

    def __init__(self, a, cols, rows):
        self.a, self.cols, self.rows = a, cols, rows
        self.colors = [a.ring1, a.ring2, a.ring3, a.fill]
        self.tens = {}  # row -> the ruler columns of that row whose index is a multiple of 10
        self.static = self._static()

    def _row(self, r, cells=None):
        """Row R as SGR runs; `cells` {column: char} puts a glyph in those cells (the cell keeps its ring or fill
        background; the glyph is gray, never a fixture color; a ruler multiple of 10 takes the other gray)."""
        cols, rows = self.cols, self.rows
        cells = cells or {}
        parts, last = [], None
        for c in range(cols):
            k = ring_of(r, c, rows, cols)
            ch = cells.get(c, " ")
            ink = None
            if ch != " ":
                ink = ink_on(self.colors[k])
                if ch.isdigit() and c in self.tens.get(r, ()):
                    ink = INK_LIGHT if ink == INK_DARK else INK_DARK
            style = (k, ink)
            if style != last:
                parts.append(RESET + bg(self.colors[k]) + (fg(ink) if ink else ""))
                last = style
            parts.append(ch)
        return "\x1b[%d;1H" % (r + 1) + "".join(parts)

    def _ruler_cells(self, r):
        """The ruler's glyphs on row R: column index mod 10 along row `at` (columns at..C-1-at) and row index mod
        10 down column `at` (rows at+1..R-1-at)."""
        at, cols, rows = self.a.ruler_at, self.cols, self.rows
        cells, tens = {}, set()
        if at <= 0 or at > min(cols, rows) // 2 - 1:
            return cells
        if r == at:
            for c in range(at, cols - at):
                cells[c] = str(c % 10)
                if c % 10 == 0:
                    tens.add(c)
        elif at < r < rows - at:
            cells[at] = str(r % 10)
            if r % 10 == 0:
                tens.add(at)
        self.tens[r] = tens
        return cells

    def _static(self):
        lines = [self._row(r, self._ruler_cells(r)) for r in range(self.rows)]
        return lines

    def centre(self, frame, winch):
        a = self.a
        texts = [("%s  %dx%d" % (a.label, self.cols, self.rows)).strip(), "frame %06d" % frame, "winch %d  fps %g" % (winch, a.fps)]
        top = self.rows // 2 - len(texts) // 2
        out = {}
        inner = self.cols - 2 * (RINGS + 2)  # never over a ring, the ruler column or the cell next to it
        for i, text in enumerate(texts):
            r = top + i
            if r <= RINGS or r >= self.rows - 1 - RINGS or inner <= 0:
                continue
            text = text[:inner]
            start = (self.cols - len(text)) // 2
            cells = self._ruler_cells(r)
            cells.update({start + j: ch for j, ch in enumerate(text)})
            out[r] = self._row(r, cells)
        return out

    def frame(self, frame, winch):
        lines = list(self.static)
        for r, line in self.centre(frame, winch).items():
            lines[r] = line
        return BSU + "".join(lines) + RESET + ESU


def term_size(fd, fixed):
    if fixed:
        return fixed
    try:
        size = os.get_terminal_size(fd)
        return max(1, size.columns), max(1, size.lines)
    except OSError:
        return 80, 24


def quiet_tty(fd):
    """Echo and canonical input off, signals kept (Ctrl-C is SIGINT); the old modes, or None without a tty."""
    try:
        import termios
        old = termios.tcgetattr(fd)
        new = list(old)
        new[3] &= ~(termios.ECHO | termios.ICANON)
        termios.tcsetattr(fd, termios.TCSADRAIN, new)
        return old
    except (ImportError, OSError, ValueError):
        return None


def restore_tty(fd, old):
    """The tty's modes back, with TCSAFLUSH: input typed while the fixture ended is dropped, so the shell never reads
    keys that arrived with its echo off."""
    if old is None:
        return
    try:
        import termios
        termios.tcsetattr(fd, termios.TCSAFLUSH, old)
    except (ImportError, OSError, ValueError):
        pass


def run(a):
    out = Out()
    if a.size and a.frames == 1 and not os.isatty(1):
        # One frame for a fixed size (tests): no screen modes, no signals.
        cols, rows = a.size
        out.write(Picture(a, cols, rows).frame(1, 0))
        return 0
    log = Log(a.log)
    rfd, wfd = os.pipe()
    os.set_blocking(rfd, False)
    os.set_blocking(wfd, False)
    winches = []

    def on_winch(_sig, _frame):
        winches.append(time.monotonic())

    signal.set_wakeup_fd(wfd)
    signal.signal(signal.SIGWINCH, on_winch)
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, _quit)
    old_tty = quiet_tty(0)
    cols, rows = term_size(1, a.size)
    picture = Picture(a, cols, rows)
    period = 1.0 / a.fps if a.fps > 0 else None
    start = time.monotonic()
    frame = n_winch = 0
    due = start
    try:
        out.write(ALT_ON + HIDE + WRAP_OFF)
        log.event("start", program="tui_border", cols=cols, rows=rows, fill="#%02X%02X%02X" % a.fill, label=a.label)
        while True:
            now = time.monotonic()
            if a.duration and now - start >= a.duration:
                break
            if winches:
                n_winch += len(winches)
                log.event("sigwinch", n=n_winch, at=[round(t, 6) for t in winches])
                del winches[:]
                size = term_size(1, a.size)
                if size != (cols, rows):
                    cols, rows = size
                    picture = Picture(a, cols, rows)
                due = now  # redraw at once
            if now >= due:
                frame += 1
                out.write(picture.frame(frame, n_winch))
                if a.frames and frame >= a.frames:
                    break
                if period:
                    due += period
                    if due < time.monotonic():  # late: the next frame is due one period from now
                        due = time.monotonic() + period
                else:
                    due = float("inf")
            timeout = max(0.0, due - time.monotonic()) if due != float("inf") else 0.25
            if a.duration:
                timeout = min(timeout, max(0.0, start + a.duration - time.monotonic()))
            ready, _, _ = select.select([rfd], [], [], min(timeout, 0.25))
            if ready:
                try:
                    os.read(rfd, 4096)
                except BlockingIOError:
                    pass
    except Quit:
        pass
    finally:
        calm()
        signal.set_wakeup_fd(-1)
        out.write(ESU + RESET + WRAP_ON + SHOW + ALT_OFF)
        restore_tty(0, old_tty)
        log.event("end", frames=frame, winch=n_winch)
        log.close()
    return 0


def parser():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n\n", 1)[1])
    ap.add_argument("--fill", type=color, default=color("#FFFF00"), help="every cell inside the rings (default #FFFF00)")
    ap.add_argument("--ring1", type=color, default=color("#FF0000"), help="the outermost row and column (default #FF0000)")
    ap.add_argument("--ring2", type=color, default=color("#FFFFFF"), help="the second ring (default #FFFFFF)")
    ap.add_argument("--ring3", type=color, default=color("#000000"), help="the third ring (default #000000)")
    ap.add_argument("--label", default="", help="the pane's name, shown in the centre")
    ap.add_argument("--fps", type=float, default=60.0, help="full redraws a second (default 60; 0: only on SIGWINCH)")
    ap.add_argument("--ruler-at", type=int, default=3, help="the ruler's row and column, 0-based (default 3; 0: none)")
    ap.add_argument("--duration", type=float, default=0.0, help="seconds to run (0: until a signal)")
    ap.add_argument("--frames", type=int, default=0, help="stop after N frames (0: no limit)")
    ap.add_argument("--size", type=parse_size, help="COLSxROWS instead of the terminal's size (tests)")
    ap.add_argument("--log", help="JSON lines: start, every SIGWINCH, end")
    return ap


def main(argv=None):
    return run(parser().parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
