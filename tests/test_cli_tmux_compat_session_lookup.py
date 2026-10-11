#!/usr/bin/env python3
"""`new-session -A` must not create a workspace when lookup fails, and
`kill-session -a` must not close the caller."""

from __future__ import annotations

import json
import socketserver
import subprocess
import tempfile
import threading
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli, socket_request_method
from fake_socket_env import cli_environment, unwrap_capability

CALLER_WORKSPACE_ID = "11111111-1111-4111-8111-111111111111"
CREATED_WORKSPACE_ID = "99999999-9999-4999-8999-999999999999"


class FakeCmuxState:
    def __init__(self, *, list_error: bool, titles: list[str]) -> None:
        self.methods: list[str] = []
        self.list_error = list_error
        self.titles = titles

    def handle(self, method: str, params: dict[str, object]) -> dict[str, object]:
        self.methods.append(method)
        if method == "workspace.list":
            if self.list_error:
                raise RuntimeError("lookup failed")
            return {
                "workspaces": [
                    {
                        "id": CALLER_WORKSPACE_ID,
                        "ref": "workspace:1",
                        "index": 1,
                        "title": title,
                    }
                    for title in self.titles
                ]
            }
        if method == "workspace.create":
            return {"workspace_id": CREATED_WORKSPACE_ID}
        if method in {"workspace.rename", "workspace.close", "workspace.select"}:
            return {"ok": True}
        raise RuntimeError(f"unexpected method {method}")


class FakeCmuxHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        while True:
            line = self.rfile.readline()
            if not line:
                return
            request = json.loads(unwrap_capability(line.decode("utf-8")))
            method = socket_request_method(request)
            if method is None:
                self.wfile.write(b"ERROR: malformed request\n")
                self.wfile.flush()
                continue
            try:
                result = self.server.state.handle(method, request.get("params") or {})  # type: ignore[attr-defined]
                response = {"ok": True, "result": result, "id": request.get("id")}
            except RuntimeError as exc:
                response = {
                    "ok": False,
                    "error": {"code": "internal_error", "message": str(exc)},
                    "id": request.get("id"),
                }
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


class FakeCmuxUnixServer(socketserver.ThreadingUnixStreamServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, socket_path: str, state: FakeCmuxState) -> None:
        self.state = state
        super().__init__(socket_path, FakeCmuxHandler)


def run_compat(cli_path: str, args: list[str], state: FakeCmuxState) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="cmux-tmux-session-") as td:
        tmp = Path(td)
        home = tmp / "home"
        home.mkdir()
        socket_path = tmp / "fake.sock"
        server = FakeCmuxUnixServer(str(socket_path), state)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = cli_environment(
            socket_path,
            home=home,
            CMUX_WORKSPACE_ID=CALLER_WORKSPACE_ID,
        )
        try:
            return subprocess.run(
                [cli_path, "--socket", str(socket_path), "__tmux-compat", *args],
                capture_output=True,
                text=True,
                check=False,
                env=env,
                timeout=30,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


def fail(message: str, proc: subprocess.CompletedProcess[str], state: FakeCmuxState) -> int:
    print(f"FAIL: {message}")
    print(f"exit={proc.returncode}")
    print(f"stdout={proc.stdout.strip()}")
    print(f"stderr={proc.stderr.strip()}")
    print(f"methods={state.methods}")
    return 1


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    lookup_failure = FakeCmuxState(list_error=True, titles=[])
    failed_lookup = run_compat(
        cli_path,
        ["new-session", "-A", "-d", "-s", "demo-team"],
        lookup_failure,
    )
    if failed_lookup.returncode == 0 or "workspace.create" in lookup_failure.methods:
        return fail(
            "new-session -A created a workspace after workspace.list failed",
            failed_lookup,
            lookup_failure,
        )
    if "lookup failed" not in failed_lookup.stderr:
        return fail("new-session -A did not report the lookup error", failed_lookup, lookup_failure)

    missing = FakeCmuxState(list_error=False, titles=["other-team"])
    created = run_compat(
        cli_path,
        ["new-session", "-A", "-d", "-s", "demo-team"],
        missing,
    )
    if created.returncode != 0 or "workspace.create" not in missing.methods:
        return fail("new-session -A did not create a missing session", created, missing)

    kill_all_others = FakeCmuxState(list_error=False, titles=["demo-team"])
    rejected = run_compat(cli_path, ["kill-session", "-a"], kill_all_others)
    if rejected.returncode == 0 or "workspace.close" in kill_all_others.methods:
        return fail("kill-session -a closed the caller", rejected, kill_all_others)
    if "Unsupported tmux compatibility command: kill-session -a" not in rejected.stderr:
        return fail("kill-session -a did not reject the flag", rejected, kill_all_others)

    print("PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
