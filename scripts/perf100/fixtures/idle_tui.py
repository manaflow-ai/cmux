#!/usr/bin/env python3
"""An idle agent TUI for perf100 S0: draws a full-screen chat layout once, asks the terminal
for a blinking bar cursor (DECSCUSR 5) in the composer, then waits on stdin and does nothing.
This is what an idle Claude Code or Codex TUI looks like to the terminal: alternate screen,
a static frame and a cursor that only blinks. Any input byte ends it (Ctrl-C or q).
"""
import os
import sys

seed = int(sys.argv[1]) if len(sys.argv) > 1 else 0
cols, rows = os.get_terminal_size() if sys.stdout.isatty() else (100, 30)
out = ["\x1b[?1049h\x1b[2J\x1b[H"]
out.append(f"\x1b[1;38;5;{110 + seed % 6}m perf100 idle agent {seed}\x1b[0m\r\n")
out.append("\x1b[2m" + "-" * (cols - 1) + "\x1b[0m\r\n")
for i in range(max(0, rows - 7)):
    out.append(f"\x1b[38;5;{240 + (i + seed) % 12}m  {'.' * ((i * 7 + seed) % (cols - 4))}\x1b[0m\r\n")
out.append("\x1b[2m" + "-" * (cols - 1) + "\x1b[0m\r\n")
out.append("\x1b[1m> \x1b[0m")
out.append("\x1b[5 q")  # blinking bar cursor, as agent composers ask for
sys.stdout.write("".join(out))
sys.stdout.flush()
try:
    import termios
    import tty
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    tty.setcbreak(fd)
    try:
        os.read(fd, 1)  # blocks: no timer, no poll
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
except (ImportError, OSError, ValueError):
    sys.stdin.read(1)
sys.stdout.write("\x1b[0 q\x1b[?1049l")
sys.stdout.flush()
