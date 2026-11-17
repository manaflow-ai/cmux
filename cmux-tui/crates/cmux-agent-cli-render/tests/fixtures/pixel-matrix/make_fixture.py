#!/usr/bin/env python3
"""Writes the pixel matrix session (`pty.jsonl`, `moments.json`) beside this file.

Not a recording: terminal bytes chosen to put every edge case the phone's pixel matrix
(cmux-next-ios `AgentCLIHybridPixelMatrixUITests`) checks on a 100x32 screen, one step at a
time, with a moment after each. `parity.rs` exports it for the phone's bench like the
recorded sessions: the reference stays ghostty-vt fed these bytes.

Run: python3 make_fixture.py (deterministic; rerun after changing it, then export again).
"""

import base64
import json
import pathlib

COLS, ROWS = 100, 32
T0 = 1_800_000_000_000
ESC = "\x1b"


def cup(row, col):
    return f"{ESC}[{row};{col}H"


def edges():
    """30 rows with a colored glyph in column 1 and column 100 (its pending wrap included)."""
    out = []
    for i in range(30):
        middle = f" row {i:02d} " + "." * (COLS - 2 - 8)
        out.append(f"{ESC}[1;31m{chr(ord('A') + i % 26)}{ESC}[0m{middle}{ESC}[1;32m{i % 10}{ESC}[0m\r\n")
    return "".join(out)


def wrapped():
    """A 260-column line (three rows), a line of exactly 100 then more, styled runs across the wrap."""
    alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
    long = "".join(alphabet[i % len(alphabet)] for i in range(260))
    exact = "x" * COLS + "y" * 7
    styled = f"{ESC}[44m" + "s" * 95 + f"{ESC}[0;7m" + "inverse-run" + f"{ESC}[0m"
    return f"{ESC}[H{ESC}[2J$ echo long\r\n{long}\r\n{exact}\r\n{styled}\r\n$ "


def wide():
    """Wide glyphs at the right edge: one that cannot fit wraps, one that fits ends the row."""
    rows = [
        "日本語のテキスト 한국어 中文 — ｆｕｌｌｗｉｄｔｈ",
        "emoji 🚀 ✅ ⚡ 👍🏽 flag 🇯🇵 combined café naïve",
        "a" * 99 + "漢字が折り返す",  # 漢 cannot fit in column 100: it wraps
        "b" * 98 + "字",  # ends exactly at column 100
        "c" * 97 + "🚀🚀",  # the second rocket wraps
    ]
    return f"{ESC}[H{ESC}[2J" + "".join(r + "\r\n" for r in rows) + "$ "


def box():
    """A full-screen app on the alternate screen: header bar, box borders on every edge, a table."""
    out = [f"{ESC}[?1049h{ESC}[?25l{ESC}[H{ESC}[2J"]
    header = " top - 12:00:00 up 3 days, load average: 0.42 0.37 0.31 "
    out.append(cup(1, 1) + f"{ESC}[7m" + header.ljust(COLS) + f"{ESC}[0m")
    out.append(cup(2, 1) + "┌" + "─" * 48 + "┬" + "─" * 49 + "┐")
    for r in range(3, ROWS - 1):
        left = f" PID {1000 + r:5d}  proc-{r:02d} " .ljust(48)
        right = f" {'█' * (r % 20)}{'░' * (20 - r % 20)} {r * 3 % 100:3d}% ".ljust(49)
        sep = "├" + "─" * 48 + "┼" + "─" * 49 + "┤" if r == 6 else "│" + left + "│" + right + "│"
        out.append(cup(r, 1) + sep)
    out.append(cup(ROWS - 1, 1) + "└" + "─" * 48 + "┴" + "─" * 49 + "┘")
    footer = "F1 Help  F2 Setup  F3 Search  F9 Kill  F10 Quit"
    # The last row's last cell written too: the cursor sits in its pending wrap, nothing scrolls.
    out.append(cup(ROWS, 1) + f"{ESC}[30;46m" + footer.ljust(COLS) + f"{ESC}[0m")
    out.append(cup(10, 60) + "╔══════╗" + cup(11, 60) + "║ 宽字 ║" + cup(12, 60) + "╚══════╝")
    return "".join(out)


STEPS = [
    # (ms after T0, bytes, moment name after it, or None)
    (0, "$ ", "start"),
    (300, "", "working"),
    (1000, "seq edges\r\n" + edges() + "$ ", "edges"),
    (2000, wrapped(), "wrapped"),
    (3000, wide(), "wide"),
    (4000, box(), "box"),
    (5000, f"{ESC}[?25h" + cup(16, 50), "cursor_mid"),
    (6000, cup(ROWS - 1, COLS), "cursor_edge"),
    (7000, f"{ESC}[?1049l", "left_alt"),
    (8000, "echo done\r\ndone\r\n$ ", "done"),
]


def main():
    here = pathlib.Path(__file__).resolve().parent
    pty, moments = [], []
    for at, text, moment in STEPS:
        if text:
            data = base64.b64encode(text.encode()).decode()
            pty.append(json.dumps({"t_ms": T0 + at, "b64": data}))
        if moment:
            moments.append({"name": moment, "t_ms": T0 + at + 500})
    (here / "pty.jsonl").write_text("\n".join(pty) + "\n")
    (here / "moments.json").write_text(json.dumps(moments) + "\n")


if __name__ == "__main__":
    main()
