#!/usr/bin/env python3
"""Verify that a 423-character Windows state path publishes a working socket."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid


STATE_PATH_LENGTH = 423
START_TIMEOUT_SECONDS = 20


def make_state_path(root: Path) -> Path:
    state = root / "state"
    while len(str(state)) + 121 < STATE_PATH_LENGTH - 1:
        state /= "界" * 120
    remaining = STATE_PATH_LENGTH - len(str(state)) - 1
    if not 1 <= remaining <= 255:
        raise AssertionError(f"invalid final path segment length: {remaining}")
    state /= "界" * remaining
    if len(str(state)) != STATE_PATH_LENGTH:
        raise AssertionError(f"state path length is {len(str(state))}, expected {STATE_PATH_LENGTH}")
    if len(str(state).encode("utf-8")) <= 1040:
        raise AssertionError("state path does not cross SQLite's win32 VFS byte limit")
    return state


def extended_path(path: Path) -> Path:
    return Path("\\\\?\\" + str(path.resolve()))


def run() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()

    binary = args.binary.resolve()
    root = Path(tempfile.gettempdir()) / f"cmux-long-state-{uuid.uuid4().hex[:8]}"
    socket_path = root / "server.sock"
    state_path = make_state_path(root)
    config_path = root / "config.json"
    extended_state_path = extended_path(state_path)
    env = os.environ.copy()
    env["CMUX_TUI_CONFIG"] = str(config_path)
    env["CMUX_TUI_STATE_DIR"] = str(state_path)
    session = f"long-state-{uuid.uuid4().hex[:8]}"
    process: subprocess.Popen[str] | None = None
    try:
        root.mkdir(parents=True)
        extended_state_path.mkdir(parents=True)
        (extended_state_path / "machine-id").write_bytes(
            f"machine_{uuid.uuid4().hex}\n".encode()
        )
        (extended_state_path / "resource-effect-pepper").write_bytes(os.urandom(32))
        config_path.write_text("{}\n", encoding="utf-8")
        process = subprocess.Popen(
            [
                str(binary),
                "--headless",
                "--session",
                session,
                "--socket",
                str(socket_path),
                "--state",
                str(state_path),
            ],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + START_TIMEOUT_SECONDS
        while not socket_path.exists():
            exit_code = process.poll()
            if exit_code is not None:
                stdout, stderr = process.communicate()
                raise AssertionError(
                    f"server exited with {exit_code} before socket publication\n"
                    f"stdout:\n{stdout}\nstderr:\n{stderr}"
                )
            if time.monotonic() >= deadline:
                raise AssertionError("server did not publish its socket within 20 seconds")
            time.sleep(0.05)

        listing = subprocess.run(
            [str(binary), "--socket", str(socket_path), "--json", "workspace", "list"],
            env=env,
            capture_output=True,
            text=True,
            timeout=START_TIMEOUT_SECONDS,
            check=False,
        )
        if listing.returncode != 0:
            raise AssertionError(
                f"workspace list failed with {listing.returncode}\n"
                f"stdout:\n{listing.stdout}\nstderr:\n{listing.stderr}"
            )
        payload = json.loads(listing.stdout)
        if not isinstance(payload, list):
            raise AssertionError(f"workspace list was not an array: {payload!r}")
        print(f"Windows state path length: {len(str(state_path))}")
        print(f"Windows state path UTF-8 length: {len(str(state_path).encode('utf-8'))}")
        print(f"Published socket: {socket_path}")
    finally:
        try:
            if process is not None and process.poll() is None:
                try:
                    subprocess.run(
                        [
                            str(binary),
                            "--socket",
                            str(socket_path),
                            "--json",
                            "session",
                            "current",
                            "shutdown",
                        ],
                        env=env,
                        capture_output=True,
                        timeout=START_TIMEOUT_SECONDS,
                        check=False,
                    )
                except subprocess.TimeoutExpired:
                    pass
                try:
                    process.wait(timeout=START_TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        finally:
            shutil.rmtree(extended_path(root), ignore_errors=True)


if __name__ == "__main__":
    run()
