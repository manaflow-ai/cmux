#!/usr/bin/env python3
"""Beacon: a terminal program whose every frame says, in colors a video judge reads, WHICH pane it is and WHEN it drew.

SWITCH FRAMES (Lawrence 2026-11-02: "changing workspaces + tabs and make sure the things change frame perfect,
even when there's a ton of stuff"). The switch judge (judge_switch.py) reads from each frame of a 120 Hz screen
video which workspace and pane each terminal shows and how old the shown content is, so it finds:
  - a frame of the OLD workspace after the switch frame (its beacon ids),
  - a half-drawn frame (some panes of the target, some of the old workspace, some blank),
  - a stale snapshot (the target's beacon clock is older than the live clock: the terminal showed a cached
    frame and updated it later).

Layout (top-left of the terminal, one block = CELL_COLS columns x 1 row, truecolor background):
  row 0:  Y  ws[6 bits]  pane[4 bits]  parity  R
  row 1:  Y  clock gray-code bits 17..9         parity  R
  row 2:  Y  clock gray-code bits  8..0         parity  R
Y = yellow start block, R = red end block, bit 1 = magenta, bit 0 = cyan. The clock is time.time_ns() in
CLOCK_UNIT_MS units, 18 bits (wraps every 524 s; the judge compares modulo 2**18). Each frame is one
synchronized-output update (DEC mode 2026), so the three rows always come from one clock read.

Usage (run in a cmux terminal pane):  beacon.py --ws 3 --pane 1 [--hz 240] [--cell-cols 2] [--fill]
  --fill  also redraws a moving line pattern below the beacon (a light load that changes every frame).
Library: `rows(ws, pane, clock_units)` returns the three rows as lists of bits; `ansi(...)` the escape text.
"""
from __future__ import annotations

import argparse
import os
import signal
import sys
import time

CLOCK_UNIT_MS = 2
CLOCK_BITS = 18
WS_BITS = 6
PANE_BITS = 4
COLORS = {
    "Y": (255, 255, 0),
    "R": (255, 0, 0),
    1: (255, 0, 255),
    0: (0, 255, 255),
}


def gray(n: int) -> int:
    return n ^ (n >> 1)


def ungray(g: int) -> int:
    n = g
    shift = 1
    while (g >> shift) > 0:
        n ^= g >> shift
        shift += 1
    return n


def bits(value: int, width: int) -> list[int]:
    return [(value >> (width - 1 - i)) & 1 for i in range(width)]


def parity(values: list[int]) -> int:
    return sum(values) & 1


def clock_units(now_ns: int | None = None) -> int:
    now_ns = time.time_ns() if now_ns is None else now_ns
    return (now_ns // (CLOCK_UNIT_MS * 1_000_000)) % (1 << CLOCK_BITS)


def rows(ws: int, pane: int, clock: int) -> list[list[int]]:
    """The data bits of the three rows (no markers, parity last)."""
    ids = bits(ws % (1 << WS_BITS), WS_BITS) + bits(pane % (1 << PANE_BITS), PANE_BITS)
    g = bits(gray(clock), CLOCK_BITS)
    hi, lo = g[:9], g[9:]
    return [ids + [parity(ids)], hi + [parity(hi)], lo + [parity(lo)]]


def _block(color, cols: int) -> str:
    r, g, b = COLORS[color]
    return f"\x1b[48;2;{r};{g};{b}m" + " " * cols


def ansi(ws: int, pane: int, clock: int, cell_cols: int = 2, row0: int = 1, col0: int = 1) -> str:
    out = []
    for i, data in enumerate(rows(ws, pane, clock)):
        out.append(f"\x1b[{row0 + i};{col0}H")
        out.append(_block("Y", cell_cols))
        out.extend(_block(bit, cell_cols) for bit in data)
        out.append(_block("R", cell_cols))
        out.append("\x1b[0m")
    return "".join(out)


def _fill(frame: int, width: int, height: int, top: int) -> str:
    """A cheap moving pattern below the beacon: one changed row band per frame."""
    out = []
    for y in range(top, height + 1):
        shade = (frame * 3 + y * 7) % 64 + 32
        out.append(f"\x1b[{y};1H\x1b[48;2;{shade};{shade // 2};{96 - shade // 2}m" + " " * width)
    out.append("\x1b[0m")
    return "".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ws", type=int, required=True, help="workspace number (0-63)")
    ap.add_argument("--pane", type=int, default=0, help="pane number in the workspace (0-15)")
    ap.add_argument("--hz", type=float, default=240.0, help="redraws per second (default 240: two per 120 Hz refresh)")
    ap.add_argument("--cell-cols", type=int, default=2, help="terminal columns per block (default 2)")
    ap.add_argument("--fill", action="store_true", help="also draw a moving pattern below the beacon")
    ap.add_argument("--label", default=None, help="text under the beacon (default 'WS n PANE m')")
    args = ap.parse_args()

    out = sys.stdout
    label = args.label or f"WS {args.ws}  PANE {args.pane}"
    size = [80, 24]

    def resize(*_):
        try:
            size[0], size[1] = os.get_terminal_size()
        except OSError:
            pass
        out.write("\x1b[2J")

    def stop(*_):
        out.write("\x1b[0m\x1b[?25h\x1b[?1049l")
        out.flush()
        sys.exit(0)

    signal.signal(signal.SIGWINCH, resize)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    resize()
    out.write("\x1b[?1049h\x1b[?25l\x1b[2J")
    period = 1.0 / args.hz
    next_at = time.monotonic()
    frame = 0
    while True:
        text = ["\x1b[?2026h", ansi(args.ws, args.pane, clock_units(), args.cell_cols)]
        text.append(f"\x1b[5;1H\x1b[1m{label}\x1b[0m  frame {frame:>9}")
        if args.fill:
            text.append(_fill(frame, size[0], size[1], 7))
        text.append("\x1b[?2026l")
        out.write("".join(text))
        out.flush()
        frame += 1
        next_at += period
        delay = next_at - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        else:
            next_at = time.monotonic()


if __name__ == "__main__":
    raise SystemExit(main())
