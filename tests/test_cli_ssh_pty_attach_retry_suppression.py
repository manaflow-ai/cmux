#!/usr/bin/env python3
"""Gates that a persistent attach wrapper's retry noise stays silent under the
ArgumentParser facade, exactly as it does under the legacy parser.

A managed reconnect wrapper exports `CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY=1`
for each attempt that still has a retry budget, and it owns the user-facing
retry notice. `cmux ssh-pty-attach` must therefore *not* print its own
diagnostic for a wrapper-retryable status (251/254/255 and the managed
transport phases): a healthy reconnect would otherwise look like a fatal SSH
failure to the person watching the pane.

The legacy `main()` consults that suppression rule before writing to stderr.
`ssh-pty-attach` is facade-declared, so the facade's own error path has to
consult it too; when it did not, every managed retry printed
`Error: ssh-pty-attach: ...` where the legacy parser printed nothing.

Unlike `test_cli_facade_behavior_parity.py`, this repro needs a control socket
that answers, because a wrapper-retryable status is only produced once the
runner reaches bridge establishment. The mock below fails
`workspace.remote.pty_bridge`, which classifies as `retryableTransient` (255).
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading

WORKSPACE_ID = "22222222-2222-2222-2222-222222222222"
SURFACE_ID = "33333333-3333-3333-3333-333333333333"
LIFECYCLE_ID = "44444444-4444-4444-4444-444444444444"
SESSION_ID = f"ssh-{WORKSPACE_ID}-{SURFACE_ID}"

# `SSHPTYAttachExitCode.retryableTransient`, the status a refused bridge
# establishment classifies to and one the wrapper retries.
RETRYABLE_TRANSIENT = 255


def respond(line: str) -> str:
    """Answers the control-socket methods a bridge attach reaches, refusing the
    bridge itself so the runner fails with a wrapper-retryable status."""
    try:
        payload = json.loads(line)
    except json.JSONDecodeError:
        return "{}"
    request_id = payload.get("id")
    method = payload.get("method")
    if method == "workspace.remote.pty_bridge":
        return json.dumps({
            "id": request_id,
            "ok": False,
            "error": {"code": "remote_pty_failed", "message": "remote connection is not active"},
        })
    if method == "workspace.remote.pty_sessions":
        return json.dumps({"id": request_id, "ok": True, "result": {"sessions": []}})
    if method in ("workspace.remote.pty_attach_end", "workspace.remote.pty_detach",
                  "workspace.remote.pty_resize"):
        return json.dumps({"id": request_id, "ok": True, "result": {}})
    return json.dumps({
        "id": request_id,
        "ok": False,
        "error": {"code": "unexpected_method", "message": f"unexpected method {method}"},
    })


def serve_connection(connection: socket.socket) -> None:
    pending = b""
    with connection:
        while True:
            try:
                chunk = connection.recv(4096)
            except OSError:
                return
            if not chunk:
                return
            pending += chunk
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                try:
                    connection.sendall(respond(line.decode("utf-8")).encode("utf-8") + b"\n")
                except (OSError, UnicodeDecodeError):
                    return


def accept_loop(listener: socket.socket) -> None:
    while True:
        try:
            connection, _ = listener.accept()
        except OSError:
            return
        threading.Thread(target=serve_connection, args=(connection,), daemon=True).start()


def run(cli: str, legacy: bool, can_retry: bool, socket_path: str,
        home: str) -> subprocess.CompletedProcess:
    # Every cmux-owned variable is dropped rather than allowlisted: an ambient
    # CMUX_SOCKET_PATH points the child at the developer's running app, and an
    # ambient CMUX_SSH_PTY_ATTACH_MANAGED_RECONNECT would make the runner exit
    # through its own managed-presentation path instead of the one under test.
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("CMUX_", "CMUXD_"))
    }
    env.update({
        "CMUX_CLI_SENTRY_DISABLED": "1",
        "CMUX_SOCKET_PATH": socket_path,
        "HOME": home,
        "CFFIXED_USER_HOME": home,
        "CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY": "1" if can_retry else "0",
    })
    if legacy:
        env["CMUX_CLI_LEGACY_PARSER"] = "1"
    return subprocess.run(
        [
            cli, "ssh-pty-attach", "--require-existing",
            "--workspace", WORKSPACE_ID,
            "--session-id", SESSION_ID,
            "--lifecycle-id", LIFECYCLE_ID,
            "--attachment-id", SURFACE_ID,
        ],
        text=True, capture_output=True, check=False, timeout=30.0, env=env,
    )


def main() -> int:
    cli = os.environ.get("CMUX_CLI_BIN")
    if not cli or not os.access(cli, os.X_OK):
        print("FAIL: set CMUX_CLI_BIN to the built cmux binary")
        return 1

    failures: list[str] = []
    with tempfile.TemporaryDirectory() as tmpdir:
        socket_path = os.path.join(tmpdir, "control.sock")
        home = os.path.join(tmpdir, "home")
        os.mkdir(home)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(socket_path)
            listener.listen(8)
            threading.Thread(target=accept_loop, args=(listener,), daemon=True).start()

            for can_retry in (False, True):
                facade = run(cli, legacy=False, can_retry=can_retry,
                             socket_path=socket_path, home=home)
                legacy = run(cli, legacy=True, can_retry=can_retry,
                             socket_path=socket_path, home=home)
                label = f"CMUX_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY={'1' if can_retry else '0'}"

                # The status itself is the precondition for the whole test: if a
                # refused bridge stops classifying as wrapper-retryable, the
                # suppression rule below is never consulted and a green run
                # would prove nothing.
                for parser, result in (("facade", facade), ("legacy", legacy)):
                    if result.returncode != RETRYABLE_TRANSIENT:
                        failures.append(
                            f"{label} ({parser}): a refused bridge must exit "
                            f"{RETRYABLE_TRANSIENT}, got {result.returncode}\n"
                            f"  stderr: {result.stderr.strip()!r}"
                        )

                if facade.stderr != legacy.stderr:
                    failures.append(
                        f"{label}: facade stderr must match legacy\n"
                        f"  facade stderr: {facade.stderr.strip()!r}\n"
                        f"  legacy stderr: {legacy.stderr.strip()!r}"
                    )

                # Parity alone would also be satisfied by suppressing (or
                # printing) in both parsers, so pin which side of the rule each
                # environment lands on.
                for parser, result in (("facade", facade), ("legacy", legacy)):
                    if can_retry and result.stderr.strip():
                        failures.append(
                            f"{label} ({parser}): the wrapper owns the retry notice, "
                            f"so the runner must print nothing\n"
                            f"  stderr: {result.stderr.strip()!r}"
                        )
                    if not can_retry and not result.stderr.strip():
                        failures.append(
                            f"{label} ({parser}): no retry is pending, so the runner "
                            f"must report the failure"
                        )
        finally:
            listener.close()

    if failures:
        print("FAIL: ssh-pty-attach retry-noise suppression diverged:")
        for failure in failures:
            print(f"  {failure}")
        return 1

    print("PASS: ssh-pty-attach suppresses wrapper retry noise identically in both parsers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
