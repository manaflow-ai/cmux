#!/usr/bin/env python3
"""Measure and assert Codex PreToolUse hook latency against a slow cmux socket."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


FAKE_WORKSPACE_ID = "11111111-1111-1111-1111-111111111111"
FAKE_SURFACE_ID = "22222222-2222-2222-2222-222222222222"


@dataclass(frozen=True)
class HookRun:
    index: int
    elapsed_ms: float
    returncode: int
    stdout: str
    stderr: str


class SlowFeedPushSocket:
    def __init__(self, path: Path, *, response_delay: float, backlog: int) -> None:
        self.path = path
        self.response_delay = response_delay
        self.backlog = backlog
        self.frames: list[dict] = []
        self._frames_lock = threading.Lock()
        self._ready = threading.Event()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._server: socket.socket | None = None

    def __enter__(self) -> "SlowFeedPushSocket":
        self.path.unlink(missing_ok=True)
        self._thread.start()
        if not self._ready.wait(timeout=3):
            raise RuntimeError("slow fake socket did not start")
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self._stop.set()
        if self._server is not None:
            self._server.close()
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.connect(str(self.path))
        except OSError:
            pass
        self._thread.join(timeout=3)
        self.path.unlink(missing_ok=True)

    def _run(self) -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            self._server = server
            server.bind(str(self.path))
            server.listen(self.backlog)
            server.settimeout(0.1)
            self._ready.set()
            while not self._stop.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                threading.Thread(target=self._handle_conn, args=(conn,), daemon=True).start()

    def _handle_conn(self, conn: socket.socket) -> None:
        with conn:
            data = b""
            conn.settimeout(0.1)
            while not self._stop.is_set():
                try:
                    chunk = conn.recv(65536)
                except socket.timeout:
                    continue
                except OSError:
                    return
                if not chunk:
                    return
                data += chunk
                if b"\n" in data:
                    break

            line = data.split(b"\n", 1)[0]
            if line:
                try:
                    frame = json.loads(line.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    frame = {"raw": line.decode("utf-8", errors="replace")}
                with self._frames_lock:
                    self.frames.append(frame)

            self._stop.wait(timeout=self.response_delay)


def percentile(samples: list[float], pct: float) -> float:
    if not samples:
        return 0.0
    ordered = sorted(samples)
    index = max(0, min(len(ordered) - 1, int((pct / 100.0) * len(ordered) + 0.999999) - 1))
    return ordered[index]


def hook_payload(index: int) -> str:
    payload = {
        "session_id": "codex-latency-session",
        "turn_id": f"turn-{index}",
        "cwd": "/tmp/project",
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": "printf hi"},
    }
    return json.dumps(payload)


def run_hook(cli_path: str, socket_path: Path, index: int, timeout: float) -> HookRun:
    env = os.environ.copy()
    env["CMUX_SURFACE_ID"] = FAKE_SURFACE_ID
    env["CMUX_WORKSPACE_ID"] = FAKE_WORKSPACE_ID
    env["CMUX_SOCKET_PATH"] = str(socket_path)
    env["CMUX_SOCKET"] = str(socket_path)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    env.pop("CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC", None)

    started = time.perf_counter()
    try:
        proc = subprocess.run(
            [
                cli_path,
                "--socket",
                str(socket_path),
                "hooks",
                "feed",
                "--source",
                "codex",
                "--event",
                "PreToolUse",
            ],
            input=hook_payload(index),
            text=True,
            capture_output=True,
            check=False,
            timeout=timeout,
            env=env,
        )
        return HookRun(
            index=index,
            elapsed_ms=(time.perf_counter() - started) * 1000,
            returncode=proc.returncode,
            stdout=proc.stdout,
            stderr=proc.stderr,
        )
    except subprocess.TimeoutExpired as exc:
        return HookRun(
            index=index,
            elapsed_ms=(time.perf_counter() - started) * 1000,
            returncode=124,
            stdout=(exc.stdout or ""),
            stderr=(exc.stderr or "") + f"\nharness subprocess timeout after {timeout:.1f}s",
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=int, default=100)
    parser.add_argument("--workers", type=int, default=0, help="0 uses min(iterations, cpu_count * 4)")
    parser.add_argument("--threshold-p95-ms", type=float, default=500.0)
    parser.add_argument("--response-delay", type=float, default=30.0)
    parser.add_argument("--subprocess-timeout", type=float, default=20.0)
    parser.add_argument("--measure-only", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.iterations <= 0:
        raise SystemExit("--iterations must be positive")
    cpu_count = os.cpu_count() or 1
    worker_count = args.workers if args.workers > 0 else min(args.iterations, max(1, cpu_count * 4))
    worker_count = max(1, min(args.iterations, worker_count))

    cli_path = resolve_cmux_cli()
    with tempfile.TemporaryDirectory(prefix="cmux-codex-hook-latency-", dir="/tmp") as td:
        socket_path = Path(td) / f"s-{uuid.uuid4().hex[:8]}.sock"
        with SlowFeedPushSocket(socket_path, response_delay=args.response_delay, backlog=max(128, args.iterations)) as fake:
            with concurrent.futures.ThreadPoolExecutor(max_workers=worker_count) as executor:
                futures = [
                    executor.submit(run_hook, cli_path, socket_path, index, args.subprocess_timeout)
                    for index in range(args.iterations)
                ]
                runs = [future.result() for future in concurrent.futures.as_completed(futures)]

            failures: list[str] = []
            for run in sorted(runs, key=lambda item: item.index):
                if run.returncode != 0:
                    failures.append(
                        f"run {run.index} failed rc={run.returncode} stdout={run.stdout!r} stderr={run.stderr!r}"
                    )
                if (run.stdout.strip() or "{}") != "{}":
                    failures.append(f"run {run.index} emitted unexpected stdout {run.stdout!r}")

            if len(fake.frames) != args.iterations:
                failures.append(f"slow socket saw {len(fake.frames)} feed.push frames, expected {args.iterations}")

            for frame in fake.frames[:5]:
                params = frame.get("params") if isinstance(frame, dict) else None
                event = params.get("event") if isinstance(params, dict) else None
                if frame.get("method") != "feed.push":
                    failures.append(f"unexpected method in frame: {frame!r}")
                    break
                if params.get("wait_timeout_seconds") != 0:
                    failures.append(f"PreToolUse frame should not wait for a Feed decision: {frame!r}")
                    break
                if not isinstance(event, dict) or event.get("hook_event_name") != "PreToolUse":
                    failures.append(f"unexpected event in frame: {frame!r}")
                    break

            elapsed = [run.elapsed_ms for run in runs]
            p50 = percentile(elapsed, 50)
            p95 = percentile(elapsed, 95)
            p99 = percentile(elapsed, 99)
            print(
                "RESULT codex_pretool_latency "
                f"iterations={args.iterations} workers={worker_count} "
                f"p50_ms={p50:.1f} p95_ms={p95:.1f} p99_ms={p99:.1f} "
                f"threshold_p95_ms={args.threshold_p95_ms:.1f}"
            )

            if not args.measure_only and p95 > args.threshold_p95_ms:
                failures.append(
                    f"Codex PreToolUse hook p95 {p95:.1f}ms exceeded {args.threshold_p95_ms:.1f}ms"
                )

            if failures:
                print("FAIL: Codex PreToolUse hook latency regression failed")
                for failure in failures:
                    print(f"- {failure}")
                return 1

    print("PASS: Codex PreToolUse telemetry hook latency is bounded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
