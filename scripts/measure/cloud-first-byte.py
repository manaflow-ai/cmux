#!/usr/bin/env python3
"""Measure Cloud chat's first response byte while Cloud Git is active.

The default chat command is the supported headless Cloud route::

    cmux chat --on vm --harness codex --prompt 'Reply with exactly: ok' --wait --json

Each sample starts that command and a public ``git ls-remote`` at the same time. The
chat's first byte is timed from its process start with a monotonic clock; the complete
output is drained afterwards so a successful sample also proves the flow completed.
Commands are parsed with :func:`shlex.split`, never through a shell. This keeps the
harness safe to run on a fleet worker and makes the exact commands visible in its JSON
receipt.

Output is one ``CLOUD-FIRST-BYTE`` JSON line. ``median_ms`` and ``p95_ms`` are null
when no first byte was observed. The process exits non-zero when any sample fails or
when the flow does not complete, so a CI receipt cannot look green with missing data.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import select
import shlex
import socket
import statistics
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Sequence


DEFAULT_CHAT = "cmux chat --on vm --harness codex --prompt 'Reply with exactly: ok' --wait --json"
DEFAULT_GIT = "git ls-remote https://github.com/manaflow-ai/cmux.git HEAD"
REPORT_MARK = "CLOUD-FIRST-BYTE "


@dataclass
class Sample:
    index: int
    first_byte_ms: float | None
    chat_exit: int | None
    git_exit: int | None
    timeout: bool
    flow_completed: bool
    git_concurrent: bool
    chat_bytes: int
    error: str | None = None


def command(value: str) -> list[str]:
    try:
        argv = shlex.split(value)
    except ValueError as exc:
        raise ValueError(f"invalid command {value!r}: {exc}") from exc
    if not argv:
        raise ValueError("command cannot be empty")
    return argv


def _stop(proc: subprocess.Popen[bytes]) -> None:
    """Stop a process this harness started, retaining a bounded cleanup path."""
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=0.5)


def run_sample(index: int, chat_argv: Sequence[str], git_argv: Sequence[str], timeout_s: float,
               completion_marker: str | None) -> Sample:
    started = time.perf_counter()
    chat = subprocess.Popen(list(chat_argv), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    git_started = time.perf_counter()
    git = subprocess.Popen(list(git_argv), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    first_byte_at: float | None = None
    first = b""
    timeout_hit = False

    try:
        assert chat.stdout is not None
        deadline = started + timeout_s
        while chat.poll() is None:
            remaining = deadline - time.perf_counter()
            if remaining <= 0:
                timeout_hit = True
                break
            readable, _, _ = select.select([chat.stdout], [], [], min(0.05, remaining))
            if readable:
                chunk = os.read(chat.stdout.fileno(), 4096)
                if chunk:
                    if first_byte_at is None:
                        first_byte_at = time.perf_counter()
                    first += chunk
                else:
                    break

        # A very short command may exit between the loop condition and select().
        # Take one non-blocking read before communicate() so its buffered first byte
        # still receives the closest possible timestamp.
        if not timeout_hit and first_byte_at is None and chat.poll() is not None:
            readable, _, _ = select.select([chat.stdout], [], [], 0)
            if readable:
                chunk = os.read(chat.stdout.fileno(), 4096)
                if chunk:
                    first_byte_at = time.perf_counter()
                    first += chunk

        if timeout_hit:
            _stop(chat)
            _stop(git)
            rest, _ = chat.communicate()
            return Sample(index, None, chat.returncode, git.returncode, True, False,
                          False, len(first) + len(rest), "timeout")

        rest, _ = chat.communicate(timeout=max(0.1, deadline - time.perf_counter()))
        output = first + rest
        git_timed_out = False
        try:
            git.wait(timeout=max(0.1, deadline - time.perf_counter()))
        except subprocess.TimeoutExpired:
            git_timed_out = True
            _stop(git)
        if first_byte_at is None and output:
            # The process exited with output that became readable only at EOF.
            # This is still a real first byte; the timestamp is bounded at exit.
            first_byte_at = time.perf_counter()

        marker_ok = completion_marker is None or completion_marker.encode() in output
        timeout_hit = git_timed_out
        flow = (not timeout_hit and first_byte_at is not None and chat.returncode == 0
                and git.returncode == 0 and marker_ok)
        error = None
        if timeout_hit:
            error = "timeout"
        elif first_byte_at is None:
            error = "chat produced no output"
        elif chat.returncode != 0:
            error = f"chat exited {chat.returncode}"
        elif git.returncode != 0:
            error = f"git exited {git.returncode}"
        elif not marker_ok:
            error = f"completion marker {completion_marker!r} was absent"
        return Sample(index, round((first_byte_at - started) * 1000, 3) if first_byte_at else None,
                      chat.returncode, git.returncode, timeout_hit, flow,
                      git_started <= (first_byte_at or time.perf_counter()), len(output), error)
    finally:
        # The normal path has already reaped both children. This is for an unexpected
        # read/communicate error, and only touches our own processes.
        _stop(chat)
        _stop(git)


def percentile(values: Sequence[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(len(ordered) * fraction))
    return ordered[rank - 1]


def git_commit() -> str | None:
    try:
        got = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True,
                             timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return got.stdout.strip() if got.returncode == 0 and got.stdout.strip() else None


def measure(samples: int, parallel: int, timeout_s: float, chat_argv: Sequence[str],
            git_argv: Sequence[str], completion_marker: str | None) -> dict:
    rows: list[Sample] = []
    with ThreadPoolExecutor(max_workers=parallel, thread_name_prefix="cloud-first-byte") as pool:
        futures = [pool.submit(run_sample, i + 1, chat_argv, git_argv, timeout_s, completion_marker)
                   for i in range(samples)]
        for future in as_completed(futures):
            rows.append(future.result())
    rows.sort(key=lambda row: row.index)
    timings = [row.first_byte_ms for row in rows if row.first_byte_ms is not None]
    errors = sum(row.error is not None for row in rows)
    timeouts = sum(row.timeout for row in rows)
    completed = sum(row.first_byte_ms is not None for row in rows)
    flow_completed = len(rows) == samples and all(row.flow_completed for row in rows)
    return {
        "schema": "cloud-first-byte/v1",
        "samples": samples,
        "completed": completed,
        "errors": errors,
        "timeouts": timeouts,
        "median_ms": round(statistics.median(timings), 3) if timings else None,
        "p95_ms": round(percentile(timings, 0.95), 3) if timings else None,
        "flow_completed": flow_completed,
        "rows": [asdict(row) for row in rows],
        "chat_command": shlex.join(chat_argv),
        "git_command": shlex.join(git_argv),
        "parallel": parallel,
        "timeout_s": timeout_s,
        "host": socket.gethostname(),
        "commit": git_commit(),
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-n", "--samples", type=int, default=5)
    parser.add_argument("--parallel", type=int, default=1,
                        help="number of samples in flight; each starts Cloud Git with its chat")
    parser.add_argument("--timeout", type=float, default=300.0, metavar="SECONDS")
    parser.add_argument("--chat-command", default=DEFAULT_CHAT)
    parser.add_argument("--git-command", default=DEFAULT_GIT)
    parser.add_argument("--completion-marker", default=None,
                        help="optional text that must occur in each chat response")
    parser.add_argument("--json", type=Path, metavar="PATH", help="also write the complete JSON receipt")
    args = parser.parse_args(argv)
    if args.samples <= 0 or args.parallel <= 0 or args.timeout <= 0:
        parser.error("samples, parallel and timeout must be positive")
    if args.parallel > args.samples:
        parser.error("parallel cannot exceed samples")
    try:
        chat_argv = command(args.chat_command)
        git_argv = command(args.git_command)
    except ValueError as exc:
        parser.error(str(exc))

    report = measure(args.samples, args.parallel, args.timeout, chat_argv, git_argv, args.completion_marker)
    encoded = json.dumps(report, sort_keys=True)
    print(REPORT_MARK + encoded, flush=True)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(encoded + "\n", encoding="utf-8")
    return 0 if report["flow_completed"] else 1


if __name__ == "__main__":
    sys.exit(main())
