#!/usr/bin/env python3
"""Measure an explicitly selected stream's first stdout byte during a Git operation.

Pass --chat-command as an unbuffered streaming command (for example curl --no-buffer
--fail), --completion-marker as its terminal stream event, and --git-command as the
cloud Git workload. Commands are argv strings, never evaluated by a shell. The receipt
includes their exact spelling: do not put credentials in arguments. Use the worker's
existing authenticated route or environment instead.

This measures command stdout, not model-token latency. Buffered commands such as
cmux chat --wait --json measure completed replies and must not be used for stream
latency. Stderr never supplies a first byte. Git must still be running at that byte,
both commands must succeed, and the stream's completion marker must arrive.

Fleet invocation (supply the quoted argv strings and exact pushed SHA)::

    cmux-ci run --class exclusive --measurement --script scripts/measure/cloud-first-byte.sh \
      --ref SHA --arg=--chat-command=STREAM --arg=--git-command=GIT \
      --arg=--completion-marker=END --arg=--json=artifacts/cloud-first-byte.json \
      --artifact artifacts/cloud-first-byte.json --timeout 600 --key UNIQUE

A CLOUD-FIRST-BYTE JSON receipt is emitted even for launch failure or timeout. Invalid
samples retain diagnostic timings but do not enter the successful median/p95.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import select
import signal
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


def _stop(proc: subprocess.Popen[bytes] | None) -> None:
    """Reap only the private process group started for this sample."""
    if proc is None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait(timeout=0.5)


def run_sample(index: int, chat_argv: Sequence[str], git_argv: Sequence[str], timeout_s: float,
               completion_marker: str | None) -> Sample:
    chat = git = None
    first_byte_at = None
    concurrent = False
    count = 0
    marker = (completion_marker or "").encode()
    marker_ok = False
    tail = b""
    timed_out = False
    error = None
    started = time.perf_counter()
    deadline = started + timeout_s
    try:
        # Git starts first; the measured interval starts at the chat launch.
        git = subprocess.Popen(list(git_argv), stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, start_new_session=True)
        started = time.perf_counter()
        chat = subprocess.Popen(list(chat_argv), stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, start_new_session=True)
        assert chat.stdout is not None
        eof = False
        while not eof:
            remaining = deadline - time.perf_counter()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(chat_argv, timeout_s)
            readable, _, _ = select.select([chat.stdout], [], [], min(0.05, remaining))
            if not readable:
                continue
            chunk = os.read(chat.stdout.fileno(), 65536)
            if not chunk:
                eof = True
                continue
            if first_byte_at is None:
                first_byte_at = time.perf_counter()
                concurrent = git.poll() is None
            count += len(chunk)
            # Keep only a marker-sized suffix, never an unbounded long-session transcript.
            block = tail + chunk
            marker_ok = marker_ok or bool(marker and marker in block)
            tail = block[-max(0, len(marker) - 1):] if len(marker) > 1 else b""
        chat.wait(timeout=max(0.001, deadline - time.perf_counter()))
        git.wait(timeout=max(0.001, deadline - time.perf_counter()))
        if chat.returncode != 0:
            error = f"chat exited {chat.returncode}"
        elif git.returncode != 0:
            error = f"git exited {git.returncode}"
        elif first_byte_at is None:
            error = "stream produced no stdout"
        elif not concurrent:
            error = "Git was not active at the first stdout byte"
        elif not marker_ok:
            error = "stream completion marker was absent"
    except subprocess.TimeoutExpired:
        timed_out = True
        error = "timeout"
    except OSError as exc:
        error = f"command launch/read failed: {exc.strerror}"
    finally:
        _stop(chat)
        _stop(git)
        if chat is not None and chat.stdout is not None:
            chat.stdout.close()
    first_ms = round((first_byte_at - started) * 1000, 3) if first_byte_at is not None else None
    return Sample(index, first_ms, chat.returncode if chat else None,
                  git.returncode if git else None, timed_out, error is None,
                  concurrent, count, error)


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
    timings = [row.first_byte_ms for row in rows if row.flow_completed and row.first_byte_ms is not None]
    errors = sum(row.error is not None for row in rows)
    timeouts = sum(row.timeout for row in rows)
    completed = sum(row.flow_completed for row in rows)
    flow_completed = len(rows) == samples and all(row.flow_completed for row in rows)
    return {
        "schema": "cloud-first-byte/v2",
        "measurement": "command_stdout_first_byte",
        "timing_population": "successful_overlapping_samples",
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
    parser.add_argument("--chat-command", required=True, help="unbuffered response stream; credentials must not be in argv")
    parser.add_argument("--git-command", required=True, help="cloud Git operation that must overlap the response")
    parser.add_argument("--completion-marker", required=True,
                        help="terminal event that proves the stream completed")
    parser.add_argument("--json", type=Path, metavar="PATH", help="also write the complete JSON receipt")
    args = parser.parse_args(argv)
    if args.samples <= 0 or args.parallel <= 0 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("samples, parallel and timeout must be positive")
    if not args.completion_marker:
        parser.error("completion-marker must not be empty")
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
