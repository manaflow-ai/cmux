#!/usr/bin/env python3
"""Verify that Windows reports a terminal's nonzero process exit."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid


TIMEOUT_SECONDS = 20.0
CREATE_NEW_PROCESS_GROUP = 0x00000200


def run_cli(
    binary: Path, socket_path: Path, env: dict[str, str], *args: str
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [str(binary), "--socket", str(socket_path), "--json", *args],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=TIMEOUT_SECONDS,
        check=False,
        creationflags=CREATE_NEW_PROCESS_GROUP,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"cmux-tui command failed ({result.returncode}): {result.args!r}\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
    return result


def result_value(result: subprocess.CompletedProcess[str]) -> dict[str, object]:
    value = json.loads(result.stdout)
    if isinstance(value, dict) and isinstance(value.get("value"), dict):
        value = value["value"]
    if not isinstance(value, dict):
        raise RuntimeError(f"cmux-tui returned an unexpected result: {result.stdout}")
    return value


def wait_for_socket(server: subprocess.Popen[bytes], socket_path: Path) -> None:
    deadline = time.monotonic() + TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if socket_path.exists():
            return
        code = server.poll()
        if code is not None:
            stdout, stderr = server.communicate()
            raise RuntimeError(
                f"server exited before socket publication with code {code}\n"
                f"stdout:\n{stdout.decode('utf-8', errors='replace')}\n"
                f"stderr:\n{stderr.decode('utf-8', errors='replace')}"
            )
        time.sleep(0.01)
    raise TimeoutError(f"server did not publish {socket_path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()

    with tempfile.TemporaryDirectory(prefix="cmux-process-wait-") as temporary:
        root = Path(temporary)
        state = root / "state"
        state.mkdir()
        (state / "machine-id").write_bytes(f"machine_{uuid.uuid4().hex}\n".encode())
        (state / "resource-effect-pepper").write_bytes(os.urandom(32))
        socket_path = root / "server.sock"
        config = root / "config.json"
        config.write_text("{}\n", encoding="utf-8")
        env = os.environ.copy()
        env["CMUX_TUI_CONFIG"] = str(config)
        server = subprocess.Popen(
            [
                str(binary),
                "--headless",
                "--session",
                "windows-process-wait",
                "--socket",
                str(socket_path),
                "--state",
                str(state),
            ],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            creationflags=CREATE_NEW_PROCESS_GROUP,
        )
        try:
            wait_for_socket(server, socket_path)
            created = result_value(
                run_cli(binary, socket_path, env, "workspace", "create", "--name", "wait-check")
            )
            terminal = created.get("terminal_id")
            if not isinstance(terminal, str):
                raise RuntimeError(f"workspace creation had no terminal id: {created!r}")

            command = "Write-Output PROCESS_EXIT_READY; exit 7\r"
            encoded = base64.b64encode(command.encode("utf-8")).decode("ascii")
            run_cli(binary, socket_path, env, "terminal", terminal, "write", "--bytes-base64", encoded)
            run_cli(
                binary,
                socket_path,
                env,
                "terminal",
                terminal,
                "screen",
                "wait",
                "--pattern",
                "PROCESS_EXIT_READY",
                "--timeout-ms",
                "10000",
            )
            waited = result_value(
                run_cli(
                    binary,
                    socket_path,
                    env,
                    "terminal",
                    terminal,
                    "process",
                    "wait",
                    "--timeout-ms",
                    "10000",
                )
            )
            if waited.get("state") != "exited" or waited.get("lifecycle") != "exited":
                raise AssertionError(f"terminal process remained active: {waited!r}")
            outcome = waited.get("outcome")
            if not isinstance(outcome, dict) or outcome != {"kind": "exit", "code": 7}:
                raise AssertionError(f"terminal process lost exit code 7: {waited!r}")
        finally:
            if server.poll() is None:
                try:
                    run_cli(binary, socket_path, env, "session", "current", "shutdown")
                    server.wait(timeout=TIMEOUT_SECONDS)
                except Exception:
                    server.kill()
                    server.wait()


if __name__ == "__main__":
    main()
