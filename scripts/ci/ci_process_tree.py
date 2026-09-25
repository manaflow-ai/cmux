#!/usr/bin/env python3
"""Find and stop a command's whole process tree, not just its process group.

SwiftPM starts `swiftpm-testing-helper` in its own process group, so
`os.killpg` on the command a CI script launched leaves the helper, which is the
process actually running the tests, alive after a timeout. These helpers walk
parent links instead.
"""

from __future__ import annotations

import os
import signal
import subprocess
from pathlib import Path
from typing import Optional


def process_tree(root: int) -> list[tuple[int, str]]:
    """The root's descendants (and itself), by parent link.

    SwiftPM starts `swiftpm-testing-helper` in its own process group, so a
    process-group lookup or `killpg` misses the process that actually hangs.
    """
    try:
        listing = subprocess.run(
            ["ps", "-A", "-o", "pid=", "-o", "ppid=", "-o", "comm="],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    children: dict[int, list[int]] = {}
    names: dict[int, str] = {}
    for row in listing.splitlines():
        fields = row.split(None, 2)
        if len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit():
            pid, parent = int(fields[0]), int(fields[1])
            children.setdefault(parent, []).append(pid)
            names[pid] = Path(fields[2].strip()).name
    tree, pending = [], [root]
    while pending:
        pid = pending.pop()
        if pid in names:
            tree.append((pid, names[pid]))
        pending.extend(child for child in children.get(pid, ()) if child != pid)
    return tree


def signal_pid(pid: int, signum: int) -> None:
    try:
        os.kill(pid, signum)
    except (ProcessLookupError, PermissionError):
        pass


def terminate(
    process: subprocess.Popen,
    first_signal: int = signal.SIGTERM,
    tree: Optional[list[tuple[int, str]]] = None,
) -> None:
    """Stop the command's process group and every descendant that left it."""
    # Capture the tree first: once the leader dies its children are reparented
    # and can no longer be found from it.
    strays = [pid for pid, _ in (tree if tree is not None else process_tree(process.pid))]
    try:
        os.killpg(process.pid, first_signal)
    except ProcessLookupError:
        pass
    for pid in strays:
        signal_pid(pid, first_signal)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    for pid in strays:
        signal_pid(pid, signal.SIGKILL)
    process.wait()
