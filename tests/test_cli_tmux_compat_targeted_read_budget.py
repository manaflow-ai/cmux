#!/usr/bin/env python3
"""Run real tmux-compatible CLI commands against the production polling limiter."""
from __future__ import annotations

from contextlib import contextmanager
import json
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import tempfile
import threading
import time

from claude_teams_test_utils import resolve_cmux_cli, stable_tmux_numeric_id
from tmux_compat_polling_fixture import (
    FakeCmuxState, WORKSPACE_ID, PANE_ID, SURFACE_ID, NEW_PANE_ID,
)

ROOT = Path(__file__).resolve().parent.parent
PANE = "%" + stable_tmux_numeric_id(PANE_ID)
NEW_PANE = "%" + stable_tmux_numeric_id(NEW_PANE_ID)
WINDOW = "@" + stable_tmux_numeric_id(WORKSPACE_ID)


class ProductionLimiter:
    """Compile and execute Swift admission decisions, never parse Swift source."""

    def __init__(self, directory: Path):
        executable = directory / "limiter"
        sources = ROOT / "Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-warnings-as-errors",
            str(sources / "Server/ControlClientRateLimiter.swift"),
            str(sources / "Wire/ControlCommandExecutionPolicy.swift"),
            str(sources / "Wire/ControlCommandExecutionPolicy+ReadPlane.swift"),
            str(sources / "Wire/ControlCommandExecutionPolicy+Simulator.swift"),
            str(ROOT / "tests/control_client_rate_limiter_probe.swift"),
            "-o", str(executable),
        ], check=True, timeout=120)
        self.process = subprocess.Popen(
            [str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        )
        self.connection = 0
        self.lock = threading.Lock()

    def new_connection(self):
        with self.lock:
            self.connection += 1
            return self.connection

    def admit(self, connection, method, now):
        with self.lock:
            self.process.stdin.write(json.dumps({"connection": connection, "method": method, "now": now}) + "\n")
            self.process.stdin.flush()
            return json.loads(self.process.stdout.readline())

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)
        assert self.process.returncode == 0
        self.process.stdout.close()


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, path, limiter, fault=None, wire_reply=None):
        self.limiter = limiter
        self.state = FakeCmuxState()
        self.fault = fault
        self.wire_reply = wire_reply
        self.requests = []
        self.limited = []
        self.early_retries = []
        super().__init__(str(path), Handler)


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        connection = self.server.limiter.new_connection()
        retry_at = 0.0
        virtual_ns = 0
        refill_ns = 0
        previous_request = None
        for raw in self.rfile:
            line = raw.decode().strip()
            if line.startswith("_cmux_capability_v1 "):
                line = line.split(" ", 2)[2]
            if line.startswith("auth "):
                self.wfile.write(b"OK\n")
                continue
            request = json.loads(line)
            method = request["method"]
            self.server.requests.append((connection, request))
            if request == previous_request and time.monotonic() < retry_at:
                self.server.early_retries.append(request)
            if refill_ns and time.monotonic() >= retry_at:
                virtual_ns += refill_ns
                refill_ns = 0
            decision = self.server.limiter.admit(connection, method, virtual_ns)
            error = self.server.fault(request) if self.server.fault else None
            if error is None and not decision["allowed"]:
                error = {
                    "code": "rate_limited", "message": "Polling rate limited for this connection",
                    "data": {"retry_after_ms": decision["retry_after_ms"]},
                }
            if error:
                self.server.limited.append((connection, request, error))
                response = {"id": request["id"], "ok": False, "error": error}
                hint = error.get("data", {}).get("retry_after_ms")
                valid_hint = type(hint) is int and hint > 0
                retry_at = time.monotonic() + (hint / 1000 if valid_hint else 0)
                refill_ns = hint * 1_000_000 if valid_hint else 0
                previous_request = request
            else:
                previous_request = None
                if method in {"system.ping", "system.top"}:
                    result = {"pong": True}
                else:
                    result = self.server.state.handle(method, request.get("params", {}))
                response = {"id": request["id"], "ok": True, "result": result}
            try:
                if self.server.wire_reply:
                    response = self.server.wire_reply(request, response)
                    if response is None:
                        return
                text = response if isinstance(response, str) else json.dumps(response)
                self.wfile.write((text + "\n").encode())
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return


@contextmanager
def serve(directory, limiter, fault=None, wire_reply=None):
    path = directory / "socket"
    server = Server(path, limiter, fault, wire_reply)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server, path
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        path.unlink(missing_ok=True)


def run(cli, path, directory, arguments, timeout=15, extra_env=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CMUX", "TMUX"))}
    env.update({
        "CMUX_SOCKET_PATH": str(path), "CMUX_WORKSPACE_ID": WORKSPACE_ID,
        "CMUX_SURFACE_ID": SURFACE_ID, "CMUX_PANE_ID": PANE_ID, "TMUX_PANE": PANE,
        "CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC": str(timeout), "HOME": str(directory),
    })
    env.update(extra_env or {})
    return subprocess.run(
        [cli, "--socket", str(path), *arguments], env=env,
        text=True, capture_output=True, timeout=30,
    )


def success(result, expected):
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert result.stdout.strip() == expected, (result.stdout, expected)
    assert not result.stderr.strip(), result.stderr


def tmux_flow(cli, directory, limiter):
    with serve(directory, limiter) as (server, path):
        commands = [
            (["display-message", "-p", "#{pane_id}"], PANE),
            (["display-message", "-p", "#{window_id}"], WINDOW),
            (["display-message", "-t", PANE, "-p", "#{window_id}"], WINDOW),
            (["list-panes", "-t", PANE, "-F", "#{pane_id}"], PANE),
            (["display-message", "-t", WINDOW, "-p", "#{window_id}"], WINDOW),
        ]
        for arguments, expected in commands:
            success(run(cli, path, directory, ["__tmux-compat", *arguments]), expected)
        success(run(cli, path, directory, [
            "__tmux-compat", "split-window", "-d", "-t", PANE, "-h", "-l", "70%",
            "-P", "-F", "#{pane_id} #{pane_index} #{pane_active}", "--", "sleep", "20",
        ]), NEW_PANE + " 1 0")
        assert server.state.split_count == 1
        assert server.state.sent_text == ["sleep 20\r"]
        success(run(cli, path, directory, [
            "__tmux-compat", "list-panes", "-t", PANE, "-F", "#{pane_id}",
        ]), PANE + "\n" + NEW_PANE)
        assert server.limited, "the real limiter must actually apply backpressure"
        assert not server.early_retries, "CLI retried before the server's retry hint"
        # Every retry must reuse the connection and the rejected request verbatim.
        for connection, request, _ in server.limited:
            assert server.requests.count((connection, request)) >= 2
        print("PASS: targeted display, detached split, command delivery, and multi-pane list under real rate limits")


def managed_teammate_flow(cli, directory, limiter):
    """Exercise the real-session launcher, not its --version fallback.

    Claude Code 2.1.280 reads TMUX_PANE, looks up #{window_id} with -t,
    counts that window's panes, then splits the leader with -d -h -l 70%.
    The stand-in runs that sequence through the launcher's managed tmux shim.
    """
    managed = directory / "cmux-cli-shims" / SURFACE_ID
    managed.mkdir(parents=True, mode=0o700)
    real_bin = directory / "real-bin"
    real_bin.mkdir()
    wrapper = managed / "claude"
    wrapper.write_text(
        '#!/bin/sh\nset -eu\n'
        '[ "${CMUX_CLAUDE_TEAMS_WRAPPER_LAUNCH:-}" = 1 ]\n'
        'exec "$CMUX_TEST_REAL_CLAUDE" "$@"\n'
    )
    wrapper.chmod(0o700)
    agent = real_bin / "claude"
    agent.write_text(r'''#!/bin/sh
set -eu
[ "$1" = --teammate-mode ] && [ "$2" = auto ]
[ "$CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" = 1 ]
[ "$TMUX_PANE" = "$CMUX_TEST_PANE" ]
# Restore a shell snapshot containing only the app's managed wrapper root.
# This must still reach cmux's tmux shim, without a launcher-only PATH entry.
export PATH="$CMUX_TEST_SNAPSHOT_PATH"
[ "$(command -v tmux)" = "$CMUX_CLAUDE_WRAPPER_SHIM_ROOT/tmux" ]
window="$(tmux display-message -t "$TMUX_PANE" -p '#{window_id}')"
[ "$window" = "$CMUX_TEST_WINDOW" ]
[ "$(tmux list-panes -t "$window" -F '#{pane_id}')" = "$TMUX_PANE" ]
teammate="$(tmux split-window -d -t "$TMUX_PANE" -h -l 70% -P -F '#{pane_id}' -- sleep 20)"
[ "$teammate" = "$CMUX_TEST_NEW_PANE" ]
[ "$(tmux display-message -t "$TMUX_PANE" -p '#S:#I.#P')" = cmux:0.0 ]
[ "$(tmux display-message -t "$teammate" -p '#P')" = 1 ]
tmux list-panes -t "$window" -F '#{pane_id}'
''')
    agent.chmod(0o700)
    extra_env = {
        "PATH": f"{managed}:{real_bin}:/usr/bin:/bin",
        "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": str(managed),
        "CMUX_CLAUDE_WRAPPER_SHIM": str(wrapper),
        "CMUX_CUSTOM_CLAUDE_PATH": str(agent),
        "CMUX_TEST_REAL_CLAUDE": str(agent),
        "CMUX_TEST_SNAPSHOT_PATH": f"{managed}:/usr/bin:/bin",
        "CMUX_TEST_PANE": PANE,
        "CMUX_TEST_WINDOW": WINDOW,
        "CMUX_TEST_NEW_PANE": NEW_PANE,
    }
    # Each fresh launch gets fresh socket state and a fresh polling budget.
    for _ in range(2):
        with serve(directory, limiter) as (server, path):
            success(run(cli, path, directory, [
                "claude-teams", "--teammate-mode", "auto",
            ], extra_env=extra_env), PANE + "\n" + NEW_PANE)
            assert server.state.split_count == 1
            assert not server.state.focus_new, "a detached teammate must not steal leader focus"
            assert server.state.sent_text == ["sleep 20\r"]
            assert server.limited, "the real launcher flow must exercise polling backpressure"
            assert not server.early_retries
            for connection, request, _ in server.limited:
                assert server.requests.count((connection, request)) >= 2
    print("PASS: fresh managed Claude Teams launches discover and split teammates under real rate limits")


def error_contract(cli, directory, limiter):
    for method in ("pane.list", "surface.split"):
        for code, hint in [
            ("not_found", 1), ("rate_limited", None), ("rate_limited", -1),
            ("rate_limited", 0), ("rate_limited", True), ("rate_limited", "5"),
            ("rate_limited", 1.5), ("rate_limited", 10**30),
        ]:
            error = {"code": code, "message": "sentinel", "data": {"retry_after_ms": hint}}
            with serve(directory, limiter, lambda _: error) as (server, path):
                result = run(cli, path, directory, ["rpc", method], timeout=5)
                assert result.returncode != 0, result.stdout
                assert code in result.stderr and "sentinel" in result.stderr, result.stderr
                assert len(server.requests) == 1, server.requests
    # Even a well-formed rate limit must never cause a mutation to be replayed.
    error = {"code": "rate_limited", "message": "mutation sentinel", "data": {"retry_after_ms": 1}}
    with serve(directory, limiter, lambda _: error) as (server, path):
        result = run(cli, path, directory, ["rpc", "surface.split"])
        assert result.returncode != 0 and "mutation sentinel" in result.stderr
        assert len(server.requests) == 1
    # Deadlines below bound only the failure path, so load can slow a pass but never fail it.
    # One rejection then success: the read is replayed verbatim, once, on the same connection.
    error = {"code": "rate_limited", "message": "retry sentinel", "data": {"retry_after_ms": 20}}
    rejected = []
    def limited_once(request):
        rejected.append(request)
        return error if len(rejected) == 1 else None
    with serve(directory, limiter, limited_once) as (server, path):
        result = run(cli, path, directory, ["rpc", "pane.list", json.dumps({"workspace_id": WORKSPACE_ID})])
        assert result.returncode == 0 and not result.stderr.strip(), result.stderr
        assert len(server.requests) == 2, server.requests
        assert server.requests[0] == server.requests[1], server.requests
        assert not server.early_retries
    # A hint longer than the whole deadline fails at once instead of waiting it out.
    error = {"code": "rate_limited", "message": "deadline sentinel", "data": {"retry_after_ms": 5_000}}
    with serve(directory, limiter, lambda _: error) as (server, path):
        result = run(cli, path, directory, ["rpc", "pane.list"], timeout=2)
        assert result.returncode != 0 and "deadline sentinel" in result.stderr, result.stderr
        assert len(server.requests) == 1, server.requests
    # A permanently limited peer gets one total deadline, not a fresh timeout per attempt:
    # every retry follows a 400 ms wait, so at most three requests fit in one second.
    error = {"code": "rate_limited", "message": "deadline sentinel", "data": {"retry_after_ms": 400}}
    with serve(directory, limiter, lambda _: error) as (server, path):
        result = run(cli, path, directory, ["rpc", "pane.list"], timeout=1)
        assert result.returncode != 0 and result.stderr.strip(), result.stderr
        assert len(server.requests) <= 3, server.requests
        assert all(entry == server.requests[0] for entry in server.requests), server.requests
        assert not server.early_retries
    for wire_reply in (
        lambda _, response: {**response, "id": "unrelated"},
        lambda _, response: {k: v for k, v in response.items() if k != "id"},
        lambda *_: "ERROR: access denied",
        lambda *_: "not json",
        lambda *_: None,
    ):
        with serve(directory, limiter, lambda _: error, wire_reply) as (server, path):
            result = run(cli, path, directory, ["rpc", "pane.list"])
            assert result.returncode != 0 and result.stderr
            assert len(server.requests) == 1, "invalid/uncorrelated replies and lost responses must not retry"
    with serve(directory, limiter, lambda request: error if request["method"] == "surface.split" else None) as (server, path):
        result = run(cli, path, directory, ["__tmux-compat", "split-window", "-d", "-t", PANE, "-P"])
        assert result.returncode != 0 and "rate_limited" in result.stderr
        assert not result.stdout.strip()
        assert server.state.split_count == 0
        assert sum(request["method"] == "surface.split" for _, request in server.requests) == 1
    print("PASS: permanent errors, invalid hints/replies, mutation failure reporting, and bounded backpressure")


def limiter_isolation(directory, limiter):
    with serve(directory, limiter) as (server, path):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.connect(str(path)); stream = connection.makefile("rwb", buffering=0)
            replies = []
            for index in range(100):
                stream.write((json.dumps({"id": index, "method": "system.top", "params": {}}) + "\n").encode())
                reply = json.loads(stream.readline()); replies.append(reply)
                if not reply["ok"]:
                    break
            assert any(not reply["ok"] for reply in replies)
            stream.write(b'{"id":1000,"method":"system.ping","params":{}}\n')
            assert json.loads(stream.readline())["ok"]
            with socket.socket(socket.AF_UNIX) as fresh:
                fresh.connect(str(path)); new_stream = fresh.makefile("rwb", buffering=0)
                new_stream.write(b'{"id":1,"method":"system.top","params":{}}\n')
                assert json.loads(new_stream.readline())["ok"]
                new_stream.close()
            stream.close()
    print("PASS: abusive raw polling is limited, one-shot probes and fresh connections remain usable")


def main():
    cli = resolve_cmux_cli()
    with tempfile.TemporaryDirectory(prefix="cmux-polling-", dir="/tmp") as root:
        directory = Path(root)
        limiter = ProductionLimiter(directory)
        try:
            tmux_flow(cli, directory, limiter)
            managed_teammate_flow(cli, directory, limiter)
            error_contract(cli, directory, limiter)
            limiter_isolation(directory, limiter)
        finally:
            limiter.close()


if __name__ == "__main__":
    main()
