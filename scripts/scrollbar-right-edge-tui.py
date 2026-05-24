#!/usr/bin/env python3
"""
Interactive right-edge scrollbar probe for Ghostty and cmux.

The default mode writes normal scrollback instead of using the alternate screen.
That keeps the native terminal scrollbar involved while drawing an exact-width
right-edge marker on every probe row.
"""

from __future__ import annotations

import argparse
import os
import select
import shutil
import signal
import sys
import termios
import tty
from dataclasses import dataclass
from typing import Any


EDGE_MARKERS = "|]>X"
PATTERN = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"


@dataclass
class ProbeConfig:
    lines: int
    width: int | None
    plain: bool
    no_clear: bool
    once: bool


def terminal_width(config: ProbeConfig) -> int:
    if config.width is not None:
        return max(8, config.width)
    return max(8, shutil.get_terminal_size((80, 24)).columns)


def styled_edge(marker: str, plain: bool) -> str:
    if plain:
        return marker
    return f"\x1b[1;30;47m{marker}\x1b[0m"


def exact_width_line(index: int, width: int, plain: bool) -> str:
    marker = EDGE_MARKERS[(index - 1) % len(EDGE_MARKERS)]
    body_width = max(0, width - 1)
    label = f"{index:04d} w={width:03d} "
    body = (label + (PATTERN * ((body_width // len(PATTERN)) + 2)))[:body_width]

    suffix = f"{index % 10}R"
    if body_width >= len(suffix):
        body = body[: body_width - len(suffix)] + suffix

    return body + styled_edge(marker, plain)


def write_probe(config: ProbeConfig, append: bool = False) -> None:
    width = terminal_width(config)
    rows = shutil.get_terminal_size((80, 24)).lines

    if not append and not config.no_clear:
        sys.stdout.write("\x1b[2J\x1b[H")

    sys.stdout.write(
        "scrollbar right-edge probe\n"
        f"terminal={os.environ.get('TERM', 'unknown')} cols={width} rows={rows}\n"
        "compare Ghostty and cmux while scrolling; "
        "the final bright cell should remain readable at the right edge\n"
        "\n"
    )

    for index in range(1, config.lines + 1):
        sys.stdout.write(exact_width_line(index, width, config.plain))
        sys.stdout.write("\n")

    sys.stdout.write(
        "\n"
        "keys: q quit, r repaint, s add scrollback, c clear+repaint\n"
        "resize the window, press r, then scroll with the mouse or trackpad\n"
    )
    sys.stdout.flush()


class RawMode:
    def __init__(self) -> None:
        self._old_attrs: list[Any] | None = None

    def __enter__(self) -> "RawMode":
        self._old_attrs = termios.tcgetattr(sys.stdin.fileno())
        tty.setcbreak(sys.stdin.fileno())
        return self

    def __exit__(self, *_exc: object) -> None:
        if self._old_attrs is not None:
            termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, self._old_attrs)


def run_interactive(config: ProbeConfig) -> int:
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print("scrollbar-right-edge-tui requires a TTY, or pass --once", file=sys.stderr)
        return 2

    pending_resize = False

    def handle_resize(_signum: int, _frame: object) -> None:
        nonlocal pending_resize
        pending_resize = True

    old_winch = signal.signal(signal.SIGWINCH, handle_resize)
    try:
        write_probe(config)
        with RawMode():
            while True:
                if pending_resize:
                    pending_resize = False
                    write_probe(config)

                ready, _, _ = select.select([sys.stdin], [], [], 0.25)
                if not ready:
                    continue

                key = sys.stdin.read(1)
                if key in ("q", "\x03", "\x04"):
                    sys.stdout.write("\n")
                    sys.stdout.flush()
                    return 0
                if key == "r":
                    write_probe(config)
                elif key == "s":
                    write_probe(config, append=True)
                elif key == "c":
                    write_probe(
                        ProbeConfig(
                            config.lines,
                            config.width,
                            config.plain,
                            False,
                            config.once,
                        )
                    )
    finally:
        signal.signal(signal.SIGWINCH, old_winch)


def parse_args() -> ProbeConfig:
    parser = argparse.ArgumentParser(
        description="Draw exact-width right-edge probe rows for scrollbar comparison."
    )
    parser.add_argument(
        "--lines",
        type=int,
        default=220,
        help="probe rows to print per repaint, default: 220",
    )
    parser.add_argument(
        "--width",
        type=int,
        default=None,
        help="override detected terminal width",
    )
    parser.add_argument(
        "--plain",
        action="store_true",
        help="disable ANSI styling on the final right-edge cell",
    )
    parser.add_argument(
        "--no-clear",
        action="store_true",
        help="do not clear the visible screen before the first paint",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="print one probe and exit, useful for captured output checks",
    )
    args = parser.parse_args()

    if args.lines < 1:
        parser.error("--lines must be at least 1")

    return ProbeConfig(
        lines=args.lines,
        width=args.width,
        plain=args.plain,
        no_clear=args.no_clear,
        once=args.once,
    )


def main() -> int:
    config = parse_args()
    if config.once:
        write_probe(config)
        return 0
    return run_interactive(config)


if __name__ == "__main__":
    raise SystemExit(main())
