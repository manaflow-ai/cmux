#!/usr/bin/env python3
"""Regression tests: `cmux hooks enqueue` answers inside the agent's hook budget.

Claude Code kills a hook after its declared 5 s timeout and discards the
output. The queued-hook CLI must therefore return its neutral `{}` response in
bounded wall-clock time even when stdin is never closed or the app stalls
after accepting the connection.
"""

from __future__ import annotations

import glob
import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass


SOCKET_PASSWORD = "wall-clock-test-password"
HOOK_PAYLOAD = {"session_id": "wall-clock-session", "hook_event_name": "UserPromptSubmit"}


@dataclass(frozen=True)
class RunResult:
    returncode: int
    stdout: str
    stderr: str
    elapsed: float


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")))
    candidates.extend(glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux"))
    candidates = [path for path in candidates if os.path.exists(path) and os.access(path, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


class FakeAppSocket:
    """Answers socket auth and v2 requests; `enqueue_replies` controls admission."""

    def __init__(self, enqueue_replies: bool) -> None:
        self.enqueue_replies = enqueue_replies
        self.stop_event = threading.Event()
        self.ready_event = threading.Event()
        self.lock = threading.Lock()
        self.requests: list[dict] = []
        self.root = tempfile.TemporaryDirectory(prefix="cmuxhook-", dir="/tmp")
        self.path = os.path.join(self.root.name, f"s-{uuid.uuid4().hex[:8]}.sock")
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.server: socket.socket | None = None

    def __enter__(self) -> "FakeAppSocket":
        self.thread.start()
        if not self.ready_event.wait(timeout=2.0):
            raise RuntimeError("fake app socket did not become ready")
        return self

    def __exit__(self, _exc_type: object, _exc: object, _tb: object) -> None:
        self.stop_event.set()
        if self.server is not None:
            self.server.close()
        self.thread.join(timeout=2.0)
        self.root.cleanup()

    def methods(self) -> list[str]:
        with self.lock:
            return [str(request.get("method")) for request in self.requests]

    def enqueue_params(self) -> dict | None:
        with self.lock:
            for request in self.requests:
                if request.get("method") == "agent.hook.enqueue":
                    params = request.get("params")
                    return params if isinstance(params, dict) else None
        return None

    def _serve(self) -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            self.server = server
            server.bind(self.path)
            server.listen(8)
            server.settimeout(0.1)
            self.ready_event.set()
            while not self.stop_event.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn: socket.socket) -> None:
        with conn:
            conn.settimeout(0.1)
            buffered = b""
            while not self.stop_event.is_set():
                try:
                    chunk = conn.recv(65536)
                except socket.timeout:
                    continue
                except OSError:
                    return
                if not chunk:
                    return
                buffered += chunk
                while b"\n" in buffered:
                    line, buffered = buffered.split(b"\n", 1)
                    reply = self._reply(line)
                    if reply is None:
                        continue
                    try:
                        conn.sendall(reply)
                    except OSError:
                        return

    def _reply(self, line: bytes) -> bytes | None:
        if line.startswith(b"auth "):
            if line[len(b"auth "):].decode(errors="replace") == SOCKET_PASSWORD:
                return b"OK\n"
            return b"ERROR: Invalid password\n"
        try:
            request = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return b"ERROR: unexpected request\n"
        if not isinstance(request, dict):
            return b"ERROR: unexpected request\n"
        with self.lock:
            self.requests.append(request)
        method = request.get("method")
        request_id = request.get("id")
        if method == "agent.hook.enqueue" and not self.enqueue_replies:
            return None
        result: dict = {}
        if method == "agent.resolve_delivery_target":
            result = {"source": "none"}
        return json.dumps({"id": request_id, "ok": True, "result": result}).encode() + b"\n"


def hook_environment(socket_path: str, extra: dict[str, str] | None = None) -> dict[str, str]:
    env = dict(os.environ)
    env["CMUX_SOCKET_PATH"] = socket_path
    env.pop("CMUX_SOCKET", None)
    # An explicit password keeps the harness away from the user's keychain.
    env["CMUX_SOCKET_PASSWORD"] = SOCKET_PASSWORD
    env["CMUX_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
    env["CMUX_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
    env["CMUX_CLAUDE_PID"] = str(os.getpid())
    env["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.5"
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    if extra:
        env.update(extra)
    return env


def run_enqueue(
    cli_path: str,
    socket_path: str,
    close_stdin: bool,
    harness_timeout: float,
    extra_env: dict[str, str] | None = None,
) -> RunResult:
    started = time.monotonic()
    proc = subprocess.Popen(
        [cli_path, "--socket", socket_path, "hooks", "enqueue", "claude", "prompt-submit"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=hook_environment(socket_path, extra_env),
    )
    assert proc.stdin is not None and proc.stdout is not None and proc.stderr is not None
    collected: dict[str, bytes] = {}

    def drain(name: str, stream) -> None:
        collected[name] = stream.read()

    readers = [
        threading.Thread(target=drain, args=("stdout", proc.stdout), daemon=True),
        threading.Thread(target=drain, args=("stderr", proc.stderr), daemon=True),
    ]
    for reader in readers:
        reader.start()
    try:
        try:
            proc.stdin.write(json.dumps(HOOK_PAYLOAD).encode())
            proc.stdin.flush()
        except BrokenPipeError:
            pass
        if close_stdin:
            proc.stdin.close()
        # With close_stdin false the pipe stays open, as an agent that never
        # signals EOF would leave it, until the hook exits or is killed.
        try:
            proc.wait(timeout=harness_timeout)
            timed_out = False
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            timed_out = True
    finally:
        if not proc.stdin.closed:
            try:
                proc.stdin.close()
            except BrokenPipeError:
                pass
    elapsed = time.monotonic() - started
    for reader in readers:
        reader.join(timeout=2.0)
    stderr = collected.get("stderr", b"").decode(errors="replace")
    if timed_out:
        stderr = f"{stderr}\nHarness timeout expired after {harness_timeout:.1f}s".lstrip()
    return RunResult(
        returncode=124 if timed_out else proc.returncode,
        stdout=collected.get("stdout", b"").decode(errors="replace"),
        stderr=stderr,
        elapsed=elapsed,
    )


def check(
    failures: list[str],
    name: str,
    run: Callable[[], RunResult],
    max_elapsed: float,
) -> RunResult:
    result = run()
    if result.returncode != 0 or result.stdout != "{}\n":
        failures.append(
            f"{name}: expected exit 0 with '{{}}', got rc={result.returncode} "
            f"stdout={result.stdout!r} stderr={result.stderr!r} elapsed={result.elapsed:.3f}s"
        )
    elif result.elapsed > max_elapsed:
        failures.append(f"{name}: answered after {result.elapsed:.3f}s, budget {max_elapsed:.1f}s")
    return result


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    failures: list[str] = []
    try:
        # Baseline: a responsive app admits the event.
        with FakeAppSocket(enqueue_replies=True) as app:
            check(
                failures,
                "responsive app",
                lambda: run_enqueue(cli_path, app.path, close_stdin=True, harness_timeout=6.0),
                max_elapsed=2.5,
            )
            if "agent.hook.enqueue" not in app.methods():
                failures.append(f"responsive app: no enqueue request, saw {app.methods()!r}")

        # An agent that never closes stdin must not hold the hook open: the
        # payload that arrived is still admitted.
        with FakeAppSocket(enqueue_replies=True) as app:
            check(
                failures,
                "stdin left open",
                lambda: run_enqueue(cli_path, app.path, close_stdin=False, harness_timeout=6.0),
                max_elapsed=2.5,
            )
            params = app.enqueue_params()
            payload = params.get("payload") if params else None
            if not isinstance(payload, str) or HOOK_PAYLOAD["session_id"] not in payload:
                failures.append(f"stdin left open: enqueue did not carry the payload that arrived: {params!r}")

        # An app that accepts the request and never answers: the wall-clock
        # bound answers `{}` itself before the agent's 5 s kill. The budget is
        # lowered so the watchdog, not the admission timeout, decides.
        with FakeAppSocket(enqueue_replies=False) as app:
            check(
                failures,
                "stalled app",
                lambda: run_enqueue(
                    cli_path,
                    app.path,
                    close_stdin=True,
                    harness_timeout=6.0,
                    extra_env={"CMUX_AGENT_HOOK_ENQUEUE_BUDGET_SEC": "0.3"},
                ),
                max_elapsed=2.5,
            )
    except Exception as exc:
        failures.append(f"test harness raised {type(exc).__name__}: {exc}")

    if failures:
        print("FAIL: cmux hooks enqueue exceeded its wall-clock bound")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: cmux hooks enqueue answers inside the agent hook budget")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
