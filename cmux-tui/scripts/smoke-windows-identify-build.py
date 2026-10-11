#!/usr/bin/env python3
"""Verify that a Windows daemon reports its source revision in `identify`.

Starts the built daemon headless, sends `identify` through the CLI's raw
command, and checks `daemon-build-v1`, `build_id` (the source revision the
build was stamped with, cmux-build-identity) and an absolute `cli_path`
(cx-5oqm: a Windows daemon used to report no build, so version-skew checks
could not tell its build).
"""

from __future__ import annotations

import argparse
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


def identity(output: str) -> dict[str, object]:
    value = json.loads(output)
    if isinstance(value, dict) and isinstance(value.get("data"), dict):
        value = value["data"]
    if not isinstance(value, dict):
        raise RuntimeError(f"identify returned an unexpected result: {output}")
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument(
        "--expect-build", required=True, help="the source revision the build was stamped with"
    )
    args = parser.parse_args()
    binary = args.binary.resolve()

    with tempfile.TemporaryDirectory(prefix="cmux-identify-build-") as temporary:
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
                "windows-identify-build",
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
            result = run_cli(
                binary,
                socket_path,
                env,
                "raw",
                "command",
                "--request-json",
                json.dumps({"id": "identify-build", "cmd": "identify"}),
            )
            print(result.stdout.strip())
            found = identity(result.stdout)
            capabilities = found.get("capabilities")
            if not isinstance(capabilities, list) or "daemon-build-v1" not in capabilities:
                raise AssertionError(f"identify lacks daemon-build-v1: {found!r}")
            if found.get("build_id") != args.expect_build:
                raise AssertionError(
                    f"identify build_id {found.get('build_id')!r} is not the source revision "
                    f"{args.expect_build!r}"
                )
            cli_path = found.get("cli_path")
            if not isinstance(cli_path, str) or not Path(cli_path).is_absolute():
                raise AssertionError(f"identify cli_path is not absolute: {cli_path!r}")
            print(f"identify build_id {found['build_id']} cli_path {cli_path}")
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
