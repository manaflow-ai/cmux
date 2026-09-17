#!/usr/bin/env python3
"""Exercise incremental terminal drawing and compare kernel and parser sizes.

Run inside a disposable terminal. No packages or network access are required.
The default uses the primary screen, as Codex does. --alternate-screen provides
a control. Logs distinguish a mismatch with stable observations from a resize
that overlaps the measurement. Neither result alone proves pixel corruption.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import os
from pathlib import Path
import re
import select
import signal
import sys
import termios
import time
import tty


ESC = "\x1b["
QUERY = b"\x1b7\x1b[9999;9999H\x1b[6n\x1b8"
CPR = re.compile(rb"\x1b\[(\d+);(\d+)R")


@dataclasses.dataclass(frozen=True)
class Grid:
    columns: int
    rows: int

    @classmethod
    def read(cls, fd: int) -> Grid:
        size = os.get_terminal_size(fd)
        return cls(size.columns, size.lines)


class InputDecoder:
    """Keep fragmented cursor reports together; never treat escape keys as text."""

    def __init__(self) -> None:
        self.buffer = bytearray()

    def feed(self, data: bytes) -> tuple[list[Grid], bytes]:
        self.buffer.extend(data)
        reports, keys = [], bytearray()
        while self.buffer:
            if self.buffer[0] != 27:
                keys.append(self.buffer.pop(0))
                continue
            if len(self.buffer) == 1:
                break
            if self.buffer[1] != ord("["):
                del self.buffer[:2]
                continue
            end = next((i for i in range(2, len(self.buffer))
                        if 0x40 <= self.buffer[i] <= 0x7E), None)
            if end is None:
                if len(self.buffer) > 64:
                    self.buffer.clear()
                break
            sequence = bytes(self.buffer[:end + 1])
            del self.buffer[:end + 1]
            if match := CPR.fullmatch(sequence):
                reports.append(Grid(int(match[2]), int(match[1])))
        return reports, bytes(keys)


def classify(before: Grid, after: Grid, parser: Grid,
             winch_before: int, winch_after: int) -> str:
    if before != after or winch_before != winch_after:
        return "overlapping_resize"
    return "match" if parser == after else "grid_mismatch"


def write_all(fd: int, data: bytes) -> None:
    remaining = memoryview(data)
    while remaining:
        remaining = remaining[os.write(fd, remaining):]


class Probe:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.input_fd = sys.stdin.fileno()
        self.output_fd = sys.stdout.fileno()
        self.started = time.monotonic()
        self.winch = 0
        self.frame = 0
        self.running = True
        self.paused = False
        self.pending = None
        self.suspended = False
        self.next_query = self.started
        self.next_frame = self.started
        self.last_grid = None
        self.last_parser = None
        self.last_canvas = []
        self.counts = {"match": 0, "grid_mismatch": 0,
                       "overlapping_resize": 0, "timeout": 0}
        self.decoder = InputDecoder()
        self.output = args.output.expanduser().resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.log = (self.output / "events.jsonl").open("a", buffering=1)

    def record(self, event: str, **fields) -> None:
        self.log.write(json.dumps({
            "event": event,
            "time": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "elapsed": round(time.monotonic() - self.started, 6),
            "frame": self.frame,
            **fields,
        }, default=lambda value: dataclasses.asdict(value)) + "\n")

    def resized(self, _signum, _frame) -> None:
        self.winch += 1
        self.next_query = 0
        self.next_frame = 0

    def stopped(self, _signum, _frame) -> None:
        self.running = False

    def canvas(self, grid: Grid) -> list[list[tuple[str, str]]]:
        # Leave the final column untouched to avoid delayed-autowrap effects.
        # Rendering is bounded independently of the dimensions being measured.
        width = min(max(grid.columns - 1, 1), 240)
        height = min(max(grid.rows, 1), 70)
        parser = (f"{self.last_parser.columns}x{self.last_parser.rows}"
                  if self.last_parser else "waiting")
        state = "PAUSED" if self.paused else "STREAMING"
        heading = [
            "CMUX RESIZE PROBE | primary screen" if not self.args.alternate_screen
            else "CMUX RESIZE PROBE | alternate screen",
            f"Kernel {grid.columns}x{grid.rows} | Parser {parser} | {state}",
            f"Matches {self.counts['match']} | Mismatches {self.counts['grid_mismatch']} "
            f"| During resize {self.counts['overlapping_resize']}",
            "Resize, split, switch away/back. SPACE pause; s snapshot; q quit.",
            "A mismatch is evidence to inspect, not proof of this screenshot's cause.",
        ]
        canvas = []
        for row in range(height):
            style = "38;2;190;190;190;49"
            if row < len(heading):
                text = heading[row]
                if row == 0:
                    style = "38;2;80;190;220;49"
            elif row >= height - 5:
                style = "38;2;225;225;225;48;2;62;64;57"
                band = row - (height - 5)
                text = [
                    f"Working {self.frame:08d}   " + " ." * (self.frame % 15),
                    "",
                    "Ask a question: the gray background must stay continuous.",
                    f"Input revision {self.frame % 10000:04d} | abcdefghijklmnopqrstuvwxyz",
                    "Probe timed out; restart to measure again." if self.suspended
                    else "The text should remain complete at every width.",
                ][band]
            else:
                sequence = max(0, (self.frame + row) // 12)
                text = (f"{row:02d}  update {sequence:06d}  "
                        "The quick brown fox jumps over the lazy dog. "
                        "0123456789  terminal output remains readable. ") * 3
            text = text[:width].ljust(width)
            canvas.append([(char, style) for char in text])
        return canvas

    def draw(self, grid: Grid) -> None:
        current = self.canvas(grid)
        resized = grid != self.last_grid
        chunks = [ESC + "?2026h"]
        if resized:
            chunks.append(ESC + "2J")
            self.record("kernel_size", grid=grid, winch=self.winch)
        for row, cells in enumerate(current):
            old = self.last_canvas[row] if not resized and row < len(self.last_canvas) else []
            col = 0
            while col < len(cells):
                if col < len(old) and cells[col] == old[col]:
                    col += 1
                    continue
                start, style = col, cells[col][1]
                text = []
                while col < len(cells) and cells[col][1] == style:
                    if col > start and col < len(old) and cells[col] == old[col]:
                        break
                    text.append(cells[col][0])
                    col += 1
                chunks.append(f"{ESC}{row + 1};{start + 1}H{ESC}{style}m{''.join(text)}")
        chunks.append(ESC + "0m" + ESC + "?2026l")
        write_all(self.output_fd, "".join(chunks).encode())
        self.last_grid, self.last_canvas = grid, current

    def query(self, now: float) -> None:
        before = Grid.read(self.output_fd)
        self.pending = (before, self.winch, now)
        # CUP is clamped by the parser's real grid. DSR then reports that
        # clamped position, independently of the kernel TIOCGWINSZ value.
        # One outstanding request avoids attributing late replies to new probes.
        write_all(self.output_fd, QUERY)
        self.next_query = now + 0.1

    def report(self, parser: Grid) -> None:
        if self.pending is None:
            self.record("unsolicited_cursor_report", parser=parser)
            return
        before, winch, started = self.pending
        self.pending = None
        after = Grid.read(self.output_fd)
        result = classify(before, after, parser, winch, self.winch)
        self.counts[result] += 1
        self.last_parser = parser
        self.record("grid_sample", result=result, kernel_before=before,
                    kernel_after=after, parser=parser, winch_before=winch,
                    winch_after=self.winch,
                    round_trip_ms=round((time.monotonic() - started) * 1000, 3))
        if result == "grid_mismatch":
            self.snapshot("mismatch")

    def snapshot(self, reason: str) -> None:
        self.record("snapshot", reason=reason)
        (self.output / "expected-screen.txt").write_text(
            "\n".join("".join(cell[0] for cell in row) for row in self.last_canvas) + "\n")
        (self.output / "summary.json").write_text(json.dumps({
            "counts": self.counts, "frames": self.frame,
            "winch": self.winch, "reason": reason,
            "alternate_screen": self.args.alternate_screen,
            "measurement_suspended": self.suspended,
        }, indent=2) + "\n")

    def run(self) -> None:
        previous = termios.tcgetattr(self.input_fd)
        old_winch = signal.signal(signal.SIGWINCH, self.resized)
        old_term = signal.signal(signal.SIGTERM, self.stopped)
        self.record("start", pid=os.getpid(), tty=os.ttyname(self.input_fd),
                    workspace=os.environ.get("CMUX_WORKSPACE_ID"),
                    surface=os.environ.get("CMUX_SURFACE_ID"),
                    socket=os.environ.get("CMUX_SOCKET_PATH"),
                    alternate_screen=self.args.alternate_screen)
        try:
            tty.setraw(self.input_fd)
            if self.args.alternate_screen:
                write_all(self.output_fd, b"\x1b[?1049h")
            write_all(self.output_fd, b"\x1b[?25l\x1b[?6l\x1b[r")
            while self.running and (not self.args.duration
                                    or time.monotonic() - self.started < self.args.duration):
                now = time.monotonic()
                if now >= self.next_frame:
                    if not self.paused:
                        self.frame += 1
                    self.draw(Grid.read(self.output_fd))
                    self.next_frame = now + 1 / 20
                if self.pending and now - self.pending[2] >= 2:
                    self.record("probe_timeout", kernel_before=self.pending[0])
                    self.pending = None
                    self.counts["timeout"] += 1
                    # DSR has no request id. A late reply cannot safely be
                    # assigned to another request, so stop measuring on timeout.
                    self.suspended = True
                if not self.pending and not self.suspended and now >= self.next_query:
                    self.query(now)
                if not select.select([self.input_fd], [], [], 0.01)[0]:
                    continue
                data = os.read(self.input_fd, 4096)
                if not data:
                    break
                reports, keys = self.decoder.feed(data)
                for report in reports:
                    self.report(report)
                if b"q" in keys or b"\x03" in keys:
                    break
                if b" " in keys:
                    self.paused = not self.paused
                if b"s" in keys:
                    self.snapshot("user")
        finally:
            try:
                self.snapshot("exit")
                write_all(self.output_fd, b"\x1b[?2026l\x1b[0m\x1b[?25h")
                if self.args.alternate_screen:
                    write_all(self.output_fd, b"\x1b[?1049l")
                else:
                    write_all(self.output_fd, f"{ESC}{Grid.read(self.output_fd).rows};1H\r\n".encode())
            finally:
                termios.tcsetattr(self.input_fd, termios.TCSANOW, previous)
                signal.signal(signal.SIGWINCH, old_winch)
                signal.signal(signal.SIGTERM, old_term)
                self.log.close()
        print(f"Resize probe evidence: {self.output}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("/tmp") / (
        "cmux-resize-probe-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S")))
    parser.add_argument("--duration", type=float, default=0,
                        help="Seconds to run; zero runs until q.")
    parser.add_argument("--alternate-screen", action="store_true")
    args = parser.parse_args()
    if args.duration < 0:
        parser.error("--duration must be nonnegative")
    if not os.isatty(sys.stdin.fileno()) or not os.isatty(sys.stdout.fileno()):
        parser.error("Run this fixture inside a disposable terminal.")
    Probe(args).run()


if __name__ == "__main__":
    main()
