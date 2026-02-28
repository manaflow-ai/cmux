#!/usr/bin/env python3
"""
Regression test: closing a workspace must tear down terminal processes.

Scenario:
1. Create a workspace with two terminal surfaces.
2. Start a long-running process in each surface and capture its PID.
3. Close that workspace.

Expected:
- The workspace is removed.
- All captured PIDs are no longer alive shortly after close.
"""

import os
import signal
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


def _wait_until(predicate, timeout_s: float = 5.0, interval_s: float = 0.05) -> bool:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return True
        time.sleep(interval_s)
    return predicate()


def _process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # Treat as alive if we can see the PID but cannot signal it.
        return True
    return True


def _wait_file(path: Path, timeout_s: float = 5.0) -> bool:
    return _wait_until(lambda: path.exists() and path.read_text(encoding="utf-8").strip() != "", timeout_s=timeout_s)


def _start_probe_process(client: cmux, surface_id: str, pid_file: Path) -> int:
    pid_file.unlink(missing_ok=True)
    command = f"sh -lc 'echo $$ > {pid_file}; exec sleep 600'\n"
    client.send_surface(surface_id, command)
    if not _wait_file(pid_file, timeout_s=6.0):
        raise cmuxError(f"Timed out waiting for PID file: {pid_file}")
    return int(pid_file.read_text(encoding="utf-8").strip())


def main() -> int:
    pid_files: list[Path] = []
    tracked_pids: list[int] = []
    workspace_id: str | None = None

    try:
        with cmux() as client:
            if not client.ping():
                raise cmuxError("Socket ping failed")

            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)
            time.sleep(0.25)

            client.new_split("right")
            time.sleep(0.35)

            surfaces = client.list_surfaces()
            if len(surfaces) < 2:
                raise cmuxError(f"Expected >=2 surfaces, got {len(surfaces)} ({surfaces})")

            for index, (_, surface_id, _) in enumerate(surfaces[:2]):
                fd, name = tempfile.mkstemp(prefix="cmux_wsclose_pid_", suffix=".txt")
                os.close(fd)
                pid_file = Path(name)
                pid_files.append(pid_file)
                pid = _start_probe_process(client, surface_id, pid_file)
                tracked_pids.append(pid)

            client.close_workspace(workspace_id)
            workspace_closed = _wait_until(
                lambda: all(ws[1] != workspace_id for ws in client.list_workspaces()),
                timeout_s=3.0,
                interval_s=0.05,
            )
            if not workspace_closed:
                raise cmuxError(f"Expected workspace to be removed after close: {workspace_id}")

            not_alive = _wait_until(
                lambda: all(not _process_alive(pid) for pid in tracked_pids),
                timeout_s=6.0,
                interval_s=0.1,
            )
            if not not_alive:
                alive = [pid for pid in tracked_pids if _process_alive(pid)]
                raise cmuxError(f"Expected terminal processes to exit after workspace close, still alive: {alive}")
    finally:
        for pid in tracked_pids:
            if _process_alive(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
        for path in pid_files:
            path.unlink(missing_ok=True)

    print("PASS: workspace close tears down terminal processes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
