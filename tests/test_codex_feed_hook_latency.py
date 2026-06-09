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
            pending = b""
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
                pending += chunk

                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    if not line:
                        continue
                    if line.startswith(b"auth "):
                        try:
                            conn.sendall(b"OK: Authenticated\n")
                        except OSError:
                            return
                        continue

                    try:
                        frame = json.loads(line.decode("utf-8"))
                    except (UnicodeDecodeError, json.JSONDecodeError):
                        frame = {"raw": line.decode("utf-8", errors="replace")}
                    with self._frames_lock:
                        self.frames.append(frame)

                    self._stop.wait(timeout=self.response_delay)
                    return

    def frames_snapshot(self) -> list[dict]:
        with self._frames_lock:
            return list(self.frames)


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
    state_dir = socket_path.parent / "hook-state" / str(index)
    home_dir = socket_path.parent / "home" / str(index)
    state_dir.mkdir(parents=True, exist_ok=True)
    home_dir.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    env["CMUX_SURFACE_ID"] = FAKE_SURFACE_ID
    env["CMUX_WORKSPACE_ID"] = FAKE_WORKSPACE_ID
    env["CMUX_SOCKET_PATH"] = str(socket_path)
    env["CMUX_SOCKET"] = str(socket_path)
    env["CMUX_AGENT_HOOK_STATE_DIR"] = str(state_dir)
    env["HOME"] = str(home_dir)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    env.pop("CMUX_SOCKET_PASSWORD", None)
    env.pop("CMUX_TAG", None)
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


class WedgedSocket:
    """A cmux socket that accepts connections and reads forever, never replying.

    Models a wedged app: the socket layer is alive but the main loop never
    answers. Status-chain hooks (prompt-submit and friends) must fail fast
    against this instead of paying the default response timeout per call.
    """

    def __init__(self, path: Path) -> None:
        self.path = path
        self._ready = threading.Event()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._server: socket.socket | None = None

    def __enter__(self) -> "WedgedSocket":
        self.path.unlink(missing_ok=True)
        self._thread.start()
        if not self._ready.wait(timeout=3):
            raise RuntimeError("wedged fake socket did not start")
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self._stop.set()
        if self._server is not None:
            self._server.close()
        self._thread.join(timeout=3)
        self.path.unlink(missing_ok=True)

    def _run(self) -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            self._server = server
            server.bind(str(self.path))
            server.listen(16)
            server.settimeout(0.1)
            self._ready.set()
            while not self._stop.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                threading.Thread(target=self._drain, args=(conn,), daemon=True).start()

    def _drain(self, conn: socket.socket) -> None:
        with conn:
            conn.settimeout(0.1)
            while not self._stop.is_set():
                try:
                    if not conn.recv(65536):
                        return
                except socket.timeout:
                    continue
                except OSError:
                    return


def prompt_submit_payload() -> str:
    return json.dumps(
        {
            "session_id": "codex-prompt-submit-latency-session",
            "turn_id": "turn-prompt-submit",
            "cwd": "/tmp/project",
            "hook_event_name": "UserPromptSubmit",
            "prompt": "hello",
        }
    )


def run_prompt_submit_phase(cli_path: str, *, threshold_ms: float, iterations: int) -> list[str]:
    """Codex blocks on `hooks codex prompt-submit` with a 5s installed hook
    timeout. Against a wedged app the whole CLI run must stay within the
    hook-run deadline budget; before the budget existed, a single target
    lookup paid the 15s default response timeout (#4405). The gate leaves
    CI scheduling headroom above the 3.5s budget while still failing the
    15s default-timeout class by a wide margin.
    """
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cmux-codex-prompt-submit-", dir="/tmp") as td:
        socket_path = Path(td) / f"w-{uuid.uuid4().hex[:8]}.sock"
        with WedgedSocket(socket_path):
            for index in range(iterations):
                state_dir = Path(td) / "hook-state" / str(index)
                home_dir = Path(td) / "home" / str(index)
                state_dir.mkdir(parents=True, exist_ok=True)
                home_dir.mkdir(parents=True, exist_ok=True)
                env = os.environ.copy()
                env["CMUX_SURFACE_ID"] = FAKE_SURFACE_ID
                env["CMUX_WORKSPACE_ID"] = FAKE_WORKSPACE_ID
                env["CMUX_SOCKET_PATH"] = str(socket_path)
                env["CMUX_SOCKET"] = str(socket_path)
                env["CMUX_AGENT_HOOK_STATE_DIR"] = str(state_dir)
                env["HOME"] = str(home_dir)
                env["CMUX_CLI_SENTRY_DISABLED"] = "1"
                env.pop("CMUX_SOCKET_PASSWORD", None)
                env.pop("CMUX_TAG", None)
                env.pop("CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC", None)

                started = time.perf_counter()
                try:
                    subprocess.run(
                        [cli_path, "--socket", str(socket_path), "hooks", "codex", "prompt-submit"],
                        input=prompt_submit_payload(),
                        text=True,
                        capture_output=True,
                        check=False,
                        timeout=60,
                        env=env,
                    )
                except subprocess.TimeoutExpired:
                    pass
                elapsed_ms = (time.perf_counter() - started) * 1000
                print(
                    f"RESULT codex_prompt_submit_wedged run={index} "
                    f"elapsed_ms={elapsed_ms:.1f} threshold_ms={threshold_ms:.1f}"
                )
                if elapsed_ms > threshold_ms:
                    failures.append(
                        f"prompt-submit run {index} took {elapsed_ms:.1f}ms against a wedged "
                        f"socket, exceeding {threshold_ms:.1f}ms — the hook-run deadline is "
                        "not bounding the status chain"
                    )
    return failures


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=int, default=100)
    parser.add_argument("--workers", type=int, default=0, help="0 uses min(iterations, cpu_count * 4)")
    parser.add_argument("--threshold-p95-ms", type=float, default=500.0)
    parser.add_argument("--response-delay", type=float, default=30.0)
    parser.add_argument("--subprocess-timeout", type=float, default=20.0)
    parser.add_argument("--prompt-submit-iterations", type=int, default=2)
    parser.add_argument("--prompt-submit-threshold-ms", type=float, default=6000.0)
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

            frame_deadline = time.monotonic() + 5.0
            frames = fake.frames_snapshot()
            while len(frames) < args.iterations and time.monotonic() < frame_deadline:
                time.sleep(0.01)
                frames = fake.frames_snapshot()

            if len(frames) != args.iterations:
                failures.append(f"slow socket saw {len(frames)} feed.push frames, expected {args.iterations}")

            for frame_index, frame in enumerate(frames):
                if not isinstance(frame, dict):
                    failures.append(f"frame {frame_index} was not an object: {frame!r}")
                    continue
                params = frame.get("params")
                if not isinstance(params, dict):
                    failures.append(f"frame {frame_index} had unexpected params: {frame!r}")
                    continue
                event = params.get("event")
                if frame.get("method") != "feed.push":
                    failures.append(f"frame {frame_index} had unexpected method: {frame!r}")
                    continue
                if params.get("wait_timeout_seconds") != 0:
                    failures.append(f"frame {frame_index} waited for a Feed decision: {frame!r}")
                    continue
                if not isinstance(event, dict) or event.get("hook_event_name") != "PreToolUse":
                    failures.append(f"frame {frame_index} had unexpected event: {frame!r}")
                    continue

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

            if not args.measure_only:
                failures.extend(
                    run_prompt_submit_phase(
                        cli_path,
                        threshold_ms=args.prompt_submit_threshold_ms,
                        iterations=args.prompt_submit_iterations,
                    )
                )

            if failures:
                print("FAIL: Codex hook latency regression failed")
                for failure in failures:
                    print(f"- {failure}")
                return 1

    print("PASS: Codex hook latency is bounded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
