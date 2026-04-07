#!/usr/bin/env python3
import os
import select
import signal
import sys
import termios
import tty


input_text = ""
needs_render = True
running = True


def render() -> None:
    size = os.get_terminal_size(sys.stdin.fileno())
    sys.stdout.write("\x1b[H\x1b[2J")
    sys.stdout.write(f"FAKE-TUI {size.lines} {size.columns}\n")
    sys.stdout.write(f"INPUT {input_text}\n")
    sys.stdout.write("Press q to quit\n")
    sys.stdout.flush()


def on_winch(_signum, _frame) -> None:
    global needs_render
    needs_render = True


def on_exit() -> None:
    sys.stdout.write("\x1b[?1049l\x1b[?25h")
    sys.stdout.flush()


signal.signal(signal.SIGWINCH, on_winch)
sys.stdout.write("\x1b[?1049h\x1b[?25l")
sys.stdout.flush()
stdin_fd = sys.stdin.fileno()
saved_termios = termios.tcgetattr(stdin_fd)
tty.setraw(stdin_fd)

try:
    while running:
        if needs_render:
            needs_render = False
            render()

        readable, _, _ = select.select([sys.stdin], [], [], 0.1)
        if not readable:
            continue

        chunk = os.read(sys.stdin.fileno(), 1)
        if not chunk:
            break
        ch = chunk.decode("utf-8", errors="ignore")
        if ch == "q":
            break
        if ch not in ("\r", "\n"):
            input_text += ch
        needs_render = True
finally:
    termios.tcsetattr(stdin_fd, termios.TCSADRAIN, saved_termios)
    on_exit()
