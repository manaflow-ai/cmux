#!/usr/bin/env python3
"""Regression: tmux pane process formats reflect the live terminal process."""

from __future__ import annotations

import glob
import os
import shlex
import subprocess
import tempfile
import time
from pathlib import Path

from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")
PROCESS_FORMAT = "#{pane_current_command}|#{pane_pid}|#{pane_tty}"


def find_cli_binary() -> str:
    explicit = os.environ.get("CMUXTERM_CLI") or os.environ.get("CMUX_CLI_BIN")
    if explicit and os.path.isfile(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates = glob.glob(
        os.path.expanduser(
            "~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"
        ),
        recursive=True,
    )
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [
        path
        for path in candidates
        if os.path.isfile(path) and os.access(path, os.X_OK)
    ]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    return max(candidates, key=os.path.getmtime)


def run_tmux_format_query(
    cli: str,
    pane_id: str,
) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    for key in (
        "CMUX_WORKSPACE_ID",
        "CMUX_SURFACE_ID",
        "CMUX_PANEL_ID",
        "CMUX_TAB_ID",
        "CMUX_PANE_ID",
        "TMUX",
        "TMUX_PANE",
    ):
        env.pop(key, None)
    return subprocess.run(
        [
            cli,
            "--socket",
            SOCKET_PATH,
            "__tmux-compat",
            "display-message",
            "-p",
            "-t",
            f"%{pane_id}",
            PROCESS_FORMAT,
        ],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=30,
    )


def wait_for_process_identity(path: Path, timeout: float = 10.0) -> tuple[int, str]:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            lines = []
        if len(lines) >= 2 and lines[0].isdigit() and lines[1].startswith("/dev/"):
            return int(lines[0]), lines[1]
        time.sleep(0.05)
    raise cmuxError(f"Pane process did not report pid and tty at {path}")


def wait_for_command(pid: int, expected: str, timeout: float = 5.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        proc = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "comm="],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0 and Path(proc.stdout.strip()).name == expected:
            return
        time.sleep(0.05)
    raise cmuxError(f"Process {pid} did not become {expected!r}")


def main() -> int:
    cli = find_cli_binary()
    workspace_id: str | None = None
    surface_id: str | None = None

    with tempfile.TemporaryDirectory(prefix="cmux-tmux-process-formats-") as td:
        identity_path = Path(td) / "process-identity.txt"
        with cmux(SOCKET_PATH) as client:
            try:
                workspace_id = client.new_workspace()
                client.select_workspace(workspace_id)

                payload = client._call(
                    "surface.list",
                    {"workspace_id": workspace_id},
                ) or {}
                surfaces = payload.get("surfaces") or []
                terminal = next(
                    (row for row in surfaces if row.get("type") == "terminal"),
                    surfaces[0] if surfaces else None,
                )
                if not terminal:
                    raise cmuxError("New workspace has no terminal surface")
                surface_id = str(terminal.get("id") or "")
                pane_id = str(terminal.get("pane_id") or "")
                if not surface_id or not pane_id:
                    raise cmuxError(f"Terminal surface is missing ids: {terminal!r}")

                quoted_identity_path = shlex.quote(str(identity_path))
                command = (
                    f"echo \"$$\" > {quoted_identity_path}; "
                    f"tty >> {quoted_identity_path}; "
                    "exec sleep 60\n"
                )
                client.send_surface(surface_id, command)

                expected_pid, expected_tty = wait_for_process_identity(identity_path)
                wait_for_command(expected_pid, "sleep")

                result = run_tmux_format_query(cli, pane_id)
                if result.returncode != 0:
                    raise cmuxError(
                        "tmux process format query failed: "
                        f"stdout={result.stdout!r} stderr={result.stderr!r}"
                    )

                expected = f"sleep|{expected_pid}|{expected_tty}"
                actual = result.stdout.strip()
                if actual != expected:
                    raise cmuxError(
                        f"Expected live pane process formats {expected!r}, got {actual!r}"
                    )
            finally:
                if surface_id:
                    try:
                        client._call(
                            "surface.send_key",
                            {
                                "workspace_id": workspace_id,
                                "surface_id": surface_id,
                                "key": "ctrl-c",
                            },
                        )
                    except Exception:
                        pass
                if workspace_id:
                    try:
                        client.close_workspace(workspace_id)
                    except Exception:
                        pass

    print("PASS: tmux pane process formats reflect the live terminal process")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
