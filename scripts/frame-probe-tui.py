#!/usr/bin/env python3
"""
Interactive terminal cadence probe for cmux notification lag.

This is a terminal-side proxy, not a compositor frame counter. It measures how
regularly this process can wake up and repaint a small TUI while other work,
such as `cmux notify`, runs. Gaps over two 120 Hz intervals are the useful
"likely missed frame interval" signal.
"""

from __future__ import annotations

import argparse
import curses
import os
import shlex
import shutil
import statistics
import subprocess
import sys
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Deque, Iterable


DEFAULT_HZ = 120.0
DEFAULT_HISTORY = 480


@dataclass
class NotifyState:
    running: bool = False
    started_at: float | None = None
    completed: int = 0
    failed: int = 0
    last_ms: float = 0.0
    max_ms: float = 0.0
    last_error: str = ""
    thread: threading.Thread | None = None


@dataclass
class FrameStats:
    hz: float
    history_limit: int
    started_ns: int = field(default_factory=time.monotonic_ns)
    last_ns: int | None = None
    frames: int = 0
    late_frames: int = 0
    hiccups: int = 0
    estimated_missed_intervals: int = 0
    max_gap_ms: float = 0.0
    gaps_ms: Deque[float] = field(default_factory=deque)

    @property
    def budget_ms(self) -> float:
        return 1000.0 / self.hz

    @property
    def hiccup_ms(self) -> float:
        return self.budget_ms * 2.0

    def reset(self) -> None:
        self.started_ns = time.monotonic_ns()
        self.last_ns = None
        self.frames = 0
        self.late_frames = 0
        self.hiccups = 0
        self.estimated_missed_intervals = 0
        self.max_gap_ms = 0.0
        self.gaps_ms.clear()

    def record_frame(self, now_ns: int) -> None:
        if self.last_ns is not None:
            gap_ms = (now_ns - self.last_ns) / 1_000_000.0
            self.gaps_ms.append(gap_ms)
            if len(self.gaps_ms) > self.history_limit:
                self.gaps_ms.popleft()
            self.max_gap_ms = max(self.max_gap_ms, gap_ms)
            if gap_ms > self.budget_ms:
                self.late_frames += 1
            if gap_ms >= self.hiccup_ms:
                self.hiccups += 1
            self.estimated_missed_intervals += max(
                0, int(gap_ms / self.budget_ms) - 1
            )
        self.last_ns = now_ns
        self.frames += 1

    def summary(self) -> dict[str, float | int]:
        gaps = list(self.gaps_ms)
        elapsed_ms = (time.monotonic_ns() - self.started_ns) / 1_000_000.0
        return {
            "frames": self.frames,
            "elapsed_ms": elapsed_ms,
            "late_frames": self.late_frames,
            "hiccups": self.hiccups,
            "estimated_missed_intervals": self.estimated_missed_intervals,
            "last_gap_ms": gaps[-1] if gaps else 0.0,
            "avg_gap_ms": statistics.fmean(gaps) if gaps else 0.0,
            "p95_gap_ms": percentile(gaps, 95),
            "p99_gap_ms": percentile(gaps, 99),
            "max_gap_ms": self.max_gap_ms,
        }


def percentile(values: Iterable[float], pct: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return 0.0
    index = (len(ordered) - 1) * pct / 100.0
    lower = int(index)
    upper = min(lower + 1, len(ordered) - 1)
    weight = index - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def cmux_bin_from_args(value: str | None) -> str:
    if value:
        return value
    env_value = os.environ.get("CMUX_FRAME_PROBE_CMUX")
    if env_value:
        return env_value
    tmp_cli = "/tmp/cmux-cli"
    if os.access(tmp_cli, os.X_OK):
        return tmp_cli
    for candidate in ("cmux-dev", "cmux"):
        resolved = shutil.which(candidate)
        if resolved:
            return resolved
    return "cmux"


def notify_command(cmux_bin: str, index: int) -> list[str]:
    return [
        cmux_bin,
        "notify",
        "--title",
        "cmux frame probe",
        "--body",
        f"notify burst {index}",
    ]


def clear_command(cmux_bin: str) -> list[str]:
    return [cmux_bin, "clear-notifications"]


def socket_env(socket_path: str | None) -> dict[str, str]:
    env = os.environ.copy()
    if socket_path:
        env["CMUX_SOCKET_PATH"] = socket_path
        env["CMUX_SOCKET"] = socket_path
    elif env.get("CMUX_SOCKET_PATH"):
        env["CMUX_SOCKET"] = env["CMUX_SOCKET_PATH"]
    elif env.get("CMUX_SOCKET"):
        env["CMUX_SOCKET_PATH"] = env["CMUX_SOCKET"]
    return env


def run_notify_burst(
    cmux_bin: str,
    socket_path: str | None,
    count: int,
    interval_ms: float,
    state: NotifyState,
) -> None:
    state.running = True
    state.started_at = time.monotonic()
    state.completed = 0
    state.failed = 0
    state.last_error = ""
    state.last_ms = 0.0
    state.max_ms = 0.0
    try:
        for index in range(1, count + 1):
            start = time.perf_counter()
            try:
                subprocess.run(
                    notify_command(cmux_bin, index),
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE,
                    env=socket_env(socket_path),
                    text=True,
                    timeout=5,
                    check=True,
                )
                state.completed += 1
            except (OSError, subprocess.SubprocessError) as error:
                state.failed += 1
                state.last_error = str(error).splitlines()[0][:100]
            elapsed_ms = (time.perf_counter() - start) * 1000.0
            state.last_ms = elapsed_ms
            state.max_ms = max(state.max_ms, elapsed_ms)
            if interval_ms > 0 and index != count:
                time.sleep(interval_ms / 1000.0)
    finally:
        state.running = False


def start_notify_burst(
    cmux_bin: str,
    socket_path: str | None,
    count: int,
    interval_ms: float,
    state: NotifyState,
) -> None:
    if state.running:
        return
    thread = threading.Thread(
        target=run_notify_burst,
        args=(cmux_bin, socket_path, count, interval_ms, state),
        daemon=True,
    )
    state.thread = thread
    thread.start()


def run_clear(cmux_bin: str, socket_path: str | None, state: NotifyState) -> None:
    start = time.perf_counter()
    try:
        subprocess.run(
            clear_command(cmux_bin),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            env=socket_env(socket_path),
            text=True,
            timeout=5,
            check=True,
        )
        state.last_error = ""
    except (OSError, subprocess.SubprocessError) as error:
        state.last_error = str(error).splitlines()[0][:100]
    finally:
        state.last_ms = (time.perf_counter() - start) * 1000.0
        state.max_ms = max(state.max_ms, state.last_ms)


def classify_gap(gap_ms: float, budget_ms: float) -> str:
    if gap_ms >= budget_ms * 4.0:
        return "X"
    if gap_ms >= budget_ms * 2.0:
        return "!"
    if gap_ms > budget_ms:
        return "+"
    return "."


def draw(stdscr: curses.window, stats: FrameStats, notify: NotifyState, args: argparse.Namespace) -> None:
    stdscr.erase()
    height, width = stdscr.getmaxyx()
    summary = stats.summary()
    budget = stats.budget_ms
    rows = [
        "cmux frame probe TUI",
        "terminal cadence proxy, not a Core Animation compositor counter",
        f"target={stats.hz:.1f}Hz budget={budget:.2f}ms hiccup>={stats.hiccup_ms:.2f}ms cmux={args.cmux_bin}",
        f"socket={args.socket_path or os.environ.get('CMUX_SOCKET_PATH') or os.environ.get('CMUX_SOCKET') or '(auto)'}",
        "",
        (
            f"frames={summary['frames']} elapsed={summary['elapsed_ms'] / 1000.0:.1f}s "
            f"late>{budget:.2f}ms={summary['late_frames']} "
            f"hiccups={summary['hiccups']} missed_intervals~={summary['estimated_missed_intervals']}"
        ),
        (
            f"gap ms  last={summary['last_gap_ms']:.3f} avg={summary['avg_gap_ms']:.3f} "
            f"p95={summary['p95_gap_ms']:.3f} p99={summary['p99_gap_ms']:.3f} "
            f"max={summary['max_gap_ms']:.3f}"
        ),
        "",
        notify_line(notify, args),
        "keys: q quit | r reset | n notify burst | c clear notifications",
        "legend: . within budget | + late | ! >=2 frame intervals | X >=4 intervals",
        "",
    ]

    for row, text in enumerate(rows[: max(0, height - 1)]):
        add_line(stdscr, row, 0, text[: max(0, width - 1)])

    if height > len(rows):
        graph_width = max(0, width - 1)
        samples = list(stats.gaps_ms)[-graph_width:]
        graph = "".join(classify_gap(gap, budget) for gap in samples)
        add_line(stdscr, len(rows), 0, graph)

    stdscr.refresh()


def notify_line(state: NotifyState, args: argparse.Namespace) -> str:
    status = "running" if state.running else "idle"
    started = ""
    if state.started_at is not None and state.running:
        started = f" running_for={time.monotonic() - state.started_at:.1f}s"
    error = f" error={state.last_error}" if state.last_error else ""
    return (
        f"notify={status}{started} count={args.notify_count} interval={args.notify_interval_ms:.1f}ms "
        f"ok={state.completed} failed={state.failed} last={state.last_ms:.1f}ms "
        f"max={state.max_ms:.1f}ms{error}"
    )


def add_line(stdscr: curses.window, y: int, x: int, text: str) -> None:
    try:
        stdscr.addstr(y, x, text)
    except curses.error:
        pass


def run_tui(args: argparse.Namespace) -> int:
    notify = NotifyState()
    stats = FrameStats(hz=args.hz, history_limit=args.history)
    if args.auto_notify:
        start_notify_burst(
            args.cmux_bin,
            args.socket_path,
            args.notify_count,
            args.notify_interval_ms,
            notify,
        )

    def wrapped(stdscr: curses.window) -> int:
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        stdscr.nodelay(True)
        stdscr.timeout(0)
        next_deadline = time.monotonic()
        interval = 1.0 / args.hz

        while True:
            now_ns = time.monotonic_ns()
            stats.record_frame(now_ns)
            draw(stdscr, stats, notify, args)

            key = stdscr.getch()
            if key in (ord("q"), ord("Q")):
                return 0
            if key in (ord("r"), ord("R")):
                stats.reset()
            if key in (ord("n"), ord("N")):
                start_notify_burst(
                    args.cmux_bin,
                    args.socket_path,
                    args.notify_count,
                    args.notify_interval_ms,
                    notify,
                )
            if key in (ord("c"), ord("C")):
                threading.Thread(
                    target=run_clear, args=(args.cmux_bin, args.socket_path, notify), daemon=True
                ).start()

            next_deadline += interval
            sleep_for = next_deadline - time.monotonic()
            if sleep_for < -interval:
                next_deadline = time.monotonic() + interval
                sleep_for = interval
            if sleep_for > 0:
                time.sleep(sleep_for)

    return curses.wrapper(wrapped)


def run_headless(args: argparse.Namespace) -> int:
    notify = NotifyState()
    stats = FrameStats(hz=args.hz, history_limit=args.history)
    if args.auto_notify:
        start_notify_burst(
            args.cmux_bin,
            args.socket_path,
            args.notify_count,
            args.notify_interval_ms,
            notify,
        )

    interval = 1.0 / args.hz
    end_at = time.monotonic() + args.headless
    next_deadline = time.monotonic()
    while time.monotonic() < end_at or notify.running:
        stats.record_frame(time.monotonic_ns())
        next_deadline += interval
        sleep_for = next_deadline - time.monotonic()
        if sleep_for < -interval:
            next_deadline = time.monotonic() + interval
            sleep_for = interval
        if sleep_for > 0:
            time.sleep(sleep_for)

    summary = stats.summary()
    print(
        "CMUX_FRAME_PROBE_TUI_RESULT "
        f"frames={summary['frames']} "
        f"duration_ms={summary['elapsed_ms']:.3f} "
        f"late_frames={summary['late_frames']} "
        f"hiccups={summary['hiccups']} "
        f"missed_intervals={summary['estimated_missed_intervals']} "
        f"p95_gap_ms={summary['p95_gap_ms']:.3f} "
        f"p99_gap_ms={summary['p99_gap_ms']:.3f} "
        f"max_gap_ms={summary['max_gap_ms']:.3f} "
        f"notify_ok={notify.completed} "
        f"notify_failed={notify.failed} "
        f"notify_max_ms={notify.max_ms:.3f}"
    )
    if notify.last_error:
        print(f"CMUX_FRAME_PROBE_NOTIFY_ERROR {notify.last_error}", file=sys.stderr)
        return 2
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Show a live terminal cadence meter and optionally trigger cmux notify bursts."
        )
    )
    parser.add_argument("--hz", type=float, default=DEFAULT_HZ, help="target repaint rate")
    parser.add_argument(
        "--history",
        type=int,
        default=DEFAULT_HISTORY,
        help="number of frame gaps to keep for percentiles and graph",
    )
    parser.add_argument(
        "--notify-count",
        type=int,
        default=250,
        help="number of cmux notify commands to run per burst",
    )
    parser.add_argument(
        "--notify-interval-ms",
        type=float,
        default=0.0,
        help="delay between notify commands in a burst",
    )
    parser.add_argument(
        "--cmux-bin",
        default=None,
        help="cmux binary path, defaults to CMUX_FRAME_PROBE_CMUX, /tmp/cmux-cli, cmux-dev, then cmux",
    )
    parser.add_argument(
        "--socket-path",
        default=os.environ.get("CMUX_FRAME_PROBE_SOCKET"),
        help="cmux Unix socket path, also accepted from CMUX_FRAME_PROBE_SOCKET",
    )
    parser.add_argument(
        "--auto-notify",
        action="store_true",
        help="start one notify burst immediately",
    )
    parser.add_argument(
        "--headless",
        type=float,
        default=0.0,
        metavar="SECONDS",
        help="run without curses for the given number of seconds and print one summary line",
    )
    parser.add_argument(
        "--print-notify-command",
        action="store_true",
        help="print the default notify command and exit",
    )
    args = parser.parse_args(argv)
    if args.hz <= 0:
        parser.error("--hz must be positive")
    if args.history < 2:
        parser.error("--history must be at least 2")
    if args.notify_count < 0:
        parser.error("--notify-count must be non-negative")
    if args.notify_interval_ms < 0:
        parser.error("--notify-interval-ms must be non-negative")
    args.cmux_bin = cmux_bin_from_args(args.cmux_bin)
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.print_notify_command:
        print(shlex.join(notify_command(args.cmux_bin, 1)))
        return 0
    if args.headless > 0:
        return run_headless(args)
    if not sys.stdout.isatty():
        print("frame-probe-tui requires a TTY, or pass --headless SECONDS", file=sys.stderr)
        return 2
    return run_tui(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
