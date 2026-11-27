#!/usr/bin/env python3
"""A full-screen program that reads the mouse, for the terminal selection tours
(tours/terminal-selection-*.json, packed in by make_tours.py). It turns on button-drag mouse reporting with
SGR encoding (DECSET 1002, 1006) and bracketed paste, fills the screen with one
marker line, sets the clipboard to CLEARED, and counts the mouse reports it gets.
Keys typed into it (the tour's `write --text`): `c` prints the clipboard and
whether it is a piece of the marker line; `q` quits and turns reporting off. A
paste (Cmd-V, bracketed) is printed back with the same check.
"""
import os
import re
import subprocess
import sys
import termios
import tty

LINE = "".join(f"SEL{n:03d}-" for n in range(40))
CLEARED = "CLEARED"
REPORT = re.compile(rb"\x1b\[<(\d+);(\d+);(\d+)([Mm])")
PASTE = re.compile(rb"\x1b\[200~(.*?)\x1b\[201~", re.S)


def clipboard():
    return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout


def status(row, text):
    sys.stdout.write(f"\x1b[{row};1H\x1b[2K{text}")
    sys.stdout.flush()


def verdict(text):
    if not text or text == CLEARED:
        return "none"
    pieces = [piece for piece in text.splitlines() if piece]
    return "exact" if pieces and all(piece in LINE for piece in pieces) else "MISMATCH"


def main():
    subprocess.run(["pbcopy"], input=CLEARED, text=True)
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    tty.setraw(fd)
    sys.stdout.write("\x1b[?1049h\x1b[2J\x1b[?1002h\x1b[?1006h\x1b[?2004h")
    rows = os.get_terminal_size().lines
    for row in range(4, rows + 1):
        status(row, LINE)
    reports = {"press": 0, "drag": 0, "release": 0}
    status(1, "mouse reporting ON (1002, SGR); reports: 0")
    buffer = b""
    try:
        while True:
            buffer += os.read(fd, 4096)
            for match in PASTE.finditer(buffer):
                pasted = match.group(1).decode(errors="replace")
                status(3, f"pasted [{verdict(pasted)}]: {pasted[:120]!r}")
            buffer = PASTE.sub(b"", buffer)
            for match in REPORT.finditer(buffer):
                button, kind = int(match.group(1)), match.group(4)
                key = "release" if kind == b"m" else "drag" if button & 32 else "press"
                reports[key] += 1
            buffer = REPORT.sub(b"", buffer)
            status(1, f"mouse reporting ON (1002, SGR); reports: {reports}")
            for byte in buffer.decode(errors="replace"):
                if byte == "c":
                    text = clipboard()
                    status(2, f"clipboard [{verdict(text)}]: {text[:120]!r}")
                elif byte == "q":
                    return
            buffer = b""
    finally:
        sys.stdout.write("\x1b[?2004l\x1b[?1006l\x1b[?1002l\x1b[?1049l")
        sys.stdout.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


if __name__ == "__main__":
    main()
