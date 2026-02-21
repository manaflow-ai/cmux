#!/usr/bin/env python3
"""Regression: cmux shell integration enables ssh niceties by default."""

import os
import shlex
import tempfile
import time
from pathlib import Path

import sys
sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for_surface(client: cmux, workspace_id: str, timeout_s: float = 8.0) -> str:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        surfaces = client.list_surfaces(workspace_id)
        if surfaces:
            return str(surfaces[0][1])
        time.sleep(0.1)
    raise cmuxError(f"workspace {workspace_id} did not create a terminal surface in time")


def main() -> int:
    output_path = Path(tempfile.gettempdir()) / f"cmux_ssh_shell_features_{os.getpid()}_{int(time.time() * 1000)}.txt"
    workspace_id = ""

    with cmux(SOCKET_PATH) as client:
        try:
            workspace_id = client.new_workspace()
            surface_id = _wait_for_surface(client, workspace_id)

            probe = f"echo \"$GHOSTTY_SHELL_FEATURES\" > {shlex.quote(str(output_path))}\n"
            deadline = time.time() + 8.0
            last_send = 0.0
            while time.time() < deadline and not output_path.exists():
                now = time.time()
                # Surface creation can race the first shell prompt; retry until one sticks.
                if now - last_send >= 0.5:
                    client.send_surface(surface_id, probe)
                    last_send = now
                time.sleep(0.05)
            _must(output_path.exists(), "Timed out waiting for shell feature probe output")

            raw = output_path.read_text(encoding="utf-8", errors="replace").strip()
            features = {token.strip() for token in raw.split(",") if token.strip()}
            _must("ssh-env" in features, f"GHOSTTY_SHELL_FEATURES missing ssh-env: {raw!r}")
            _must("ssh-terminfo" in features, f"GHOSTTY_SHELL_FEATURES missing ssh-terminfo: {raw!r}")
        finally:
            if workspace_id:
                try:
                    client.close_workspace(workspace_id)
                except Exception:
                    pass
            try:
                output_path.unlink()
            except FileNotFoundError:
                pass

    print("PASS: shell integration defaults include ssh-env and ssh-terminfo")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
