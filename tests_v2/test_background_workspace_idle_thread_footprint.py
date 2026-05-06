#!/usr/bin/env python3
"""Regression: background workspace priming must not load every hidden terminal tab."""

from __future__ import annotations

import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
WORKSPACE_COUNT = 10
SURFACES_PER_WORKSPACE = 4
SETTLE_SECONDS = 2.0
IDLE_SECONDS = 8.0
THREAD_BUDGET_PER_WORKSPACE = 6
THREAD_BUDGET_OVERHEAD = 12
IDLE_THREAD_GROWTH_BUDGET = 6
FOOTPRINT_BUDGET_PER_WORKSPACE_MB = 24
IDLE_FOOTPRINT_GROWTH_BUDGET_MB = 64


@dataclass(frozen=True)
class ProcessMetrics:
    thread_count: int
    physical_footprint_bytes: int


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _run(cmd: list[str]) -> str:
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"Command failed ({' '.join(cmd)}): {merged}")
    return proc.stdout


def _socket_owner_pid(socket_path: str) -> int:
    output = _run(["lsof", "-t", socket_path])
    for raw in output.splitlines():
        line = raw.strip()
        if not line:
            continue
        pid = int(line)
        if pid != os.getpid():
            return pid
    raise cmuxError(f"Could not resolve cmux PID from socket owner list: {output!r}")


def _thread_count(pid: int) -> int:
    output = _run(["ps", "-M", "-p", str(pid)])
    lines = [line for line in output.splitlines() if line.strip()]
    if len(lines) < 2:
        raise cmuxError(f"Unexpected ps -M output for PID {pid}: {output!r}")
    return len(lines) - 1


def _unit_multiplier(unit: str) -> int:
    return {
        "K": 1024,
        "M": 1024 ** 2,
        "G": 1024 ** 3,
        "T": 1024 ** 4,
    }[unit]


def _physical_footprint_bytes(pid: int) -> int:
    output = _run(["vmmap", "--summary", str(pid)])
    match = re.search(r"Physical footprint:\s*([0-9.]+)([KMGT])", output)
    if not match:
        raise cmuxError(f"Could not parse physical footprint from vmmap output: {output[:400]!r}")
    value = float(match.group(1))
    unit = match.group(2)
    return int(value * _unit_multiplier(unit))


def _capture_metrics(pid: int) -> ProcessMetrics:
    return ProcessMetrics(
        thread_count=_thread_count(pid),
        physical_footprint_bytes=_physical_footprint_bytes(pid),
    )


def _layout_payload() -> dict:
    return {
        "pane": {
            "surfaces": [
                {
                    "type": "terminal",
                    "name": f"bg-tab-{index + 1}",
                }
                for index in range(SURFACES_PER_WORKSPACE)
            ],
        },
    }


def _mb(value: int) -> float:
    return value / (1024.0 * 1024.0)


def main() -> int:
    created_workspaces: list[str] = []

    with cmux(SOCKET_PATH) as client:
        baseline_workspace = client.current_workspace()
        pid = _socket_owner_pid(client.socket_path)
        before = _capture_metrics(pid)

        try:
            for index in range(WORKSPACE_COUNT):
                payload = client._call(
                    "workspace.create",
                    {
                        "title": f"idle-bg-regression-{index + 1}",
                        "layout": _layout_payload(),
                    },
                ) or {}
                workspace_id = str(payload.get("workspace_id") or "")
                _must(bool(workspace_id), f"workspace.create returned no workspace_id: {payload}")
                created_workspaces.append(workspace_id)
                _must(
                    client.current_workspace() == baseline_workspace,
                    "workspace.create should preserve the selected workspace during background priming",
                )

            time.sleep(SETTLE_SECONDS)
            after_settle = _capture_metrics(pid)

            time.sleep(IDLE_SECONDS)
            after_idle = _capture_metrics(pid)

            absolute_thread_growth = after_idle.thread_count - before.thread_count
            idle_thread_growth = after_idle.thread_count - after_settle.thread_count
            absolute_footprint_growth = (
                after_idle.physical_footprint_bytes - before.physical_footprint_bytes
            )
            idle_footprint_growth = (
                after_idle.physical_footprint_bytes - after_settle.physical_footprint_bytes
            )

            thread_budget = (
                WORKSPACE_COUNT * THREAD_BUDGET_PER_WORKSPACE + THREAD_BUDGET_OVERHEAD
            )
            footprint_budget_bytes = (
                WORKSPACE_COUNT
                * FOOTPRINT_BUDGET_PER_WORKSPACE_MB
                * 1024
                * 1024
            )
            idle_footprint_budget_bytes = IDLE_FOOTPRINT_GROWTH_BUDGET_MB * 1024 * 1024

            _must(
                absolute_thread_growth <= thread_budget,
                "Background workspace priming spawned too many threads while idle: "
                f"before={before.thread_count} after={after_idle.thread_count} "
                f"delta={absolute_thread_growth} budget={thread_budget}",
            )
            _must(
                idle_thread_growth <= IDLE_THREAD_GROWTH_BUDGET,
                "Thread count kept growing after background workspace creation settled: "
                f"settled={after_settle.thread_count} after_idle={after_idle.thread_count} "
                f"delta={idle_thread_growth} budget={IDLE_THREAD_GROWTH_BUDGET}",
            )
            _must(
                absolute_footprint_growth <= footprint_budget_bytes,
                "Background workspace priming grew physical footprint too much: "
                f"before={_mb(before.physical_footprint_bytes):.1f}MB "
                f"after={_mb(after_idle.physical_footprint_bytes):.1f}MB "
                f"delta={_mb(absolute_footprint_growth):.1f}MB "
                f"budget={FOOTPRINT_BUDGET_PER_WORKSPACE_MB * WORKSPACE_COUNT}MB",
            )
            _must(
                idle_footprint_growth <= idle_footprint_budget_bytes,
                "Physical footprint kept growing while the app was idle: "
                f"settled={_mb(after_settle.physical_footprint_bytes):.1f}MB "
                f"after_idle={_mb(after_idle.physical_footprint_bytes):.1f}MB "
                f"delta={_mb(idle_footprint_growth):.1f}MB "
                f"budget={IDLE_FOOTPRINT_GROWTH_BUDGET_MB}MB",
            )
            _must(
                client.current_workspace() == baseline_workspace,
                "background workspace priming should not switch the selected workspace",
            )
        finally:
            for workspace_id in reversed(created_workspaces):
                try:
                    client.close_workspace(workspace_id)
                except Exception:
                    pass

    print("PASS: background workspace priming keeps idle thread and footprint growth bounded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
