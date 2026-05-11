#!/usr/bin/env python3
"""Regression: restoring many terminal tabs must not materialize every hidden surface."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")
PANEL_COUNT = int(os.environ.get("CMUX_RESTORE_FOOTPRINT_PANELS", "300"))
PANE_COUNT = int(os.environ.get("CMUX_RESTORE_FOOTPRINT_PANES", "12"))
SETTLE_SECONDS = float(os.environ.get("CMUX_RESTORE_FOOTPRINT_SETTLE_SECONDS", "25"))
FOOTPRINT_GROWTH_BUDGET_MB = int(os.environ.get("CMUX_RESTORE_FOOTPRINT_BUDGET_MB", "1536"))
DESCENDANT_RSS_BUDGET_MB = int(os.environ.get("CMUX_RESTORE_DESCENDANT_RSS_BUDGET_MB", "768"))
RESTORE_TIMEOUT_SECONDS = float(os.environ.get("CMUX_RESTORE_TIMEOUT_SECONDS", "180"))


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _run(cmd: list[str], *, timeout: float = 20.0, env: dict[str, str] | None = None) -> str:
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
            env=env,
        )
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")
        merged = f"{stdout}\n{stderr}".strip()
        detail = f": {merged}" if merged else ""
        raise cmuxError(f"Command timed out after {timeout:.0f}s ({' '.join(cmd)}){detail}") from exc

    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"Command failed ({' '.join(cmd)}): {merged}")
    return proc.stdout


def _cmux_pid() -> int:
    output = _run(["lsof", "-t", SOCKET_PATH], timeout=10)
    candidates = [int(line) for line in output.splitlines() if line.strip().isdigit()]
    for pid in candidates:
        command = _run(["ps", "-p", str(pid), "-o", "command="], timeout=5).strip()
        if ".app/Contents/MacOS/" in command:
            return pid
    raise cmuxError(f"Could not resolve cmux app PID from socket {SOCKET_PATH}: {output!r}")


def _bundle_path_for_pid(pid: int) -> Path:
    command = _run(["ps", "-p", str(pid), "-o", "command="], timeout=5).strip()
    marker = ".app/Contents/MacOS/"
    index = command.find(marker)
    if index < 0:
        raise cmuxError(f"Could not resolve app bundle from command: {command!r}")
    return Path(command[: index + len(".app")])


def _bundle_identifier(app_bundle: Path) -> str:
    info_plist = app_bundle / "Contents" / "Info.plist"
    bundle_id = _run(
        ["plutil", "-extract", "CFBundleIdentifier", "raw", "-o", "-", str(info_plist)],
        timeout=5,
    ).strip()
    _must(bool(bundle_id), f"Could not read CFBundleIdentifier from {info_plist}")
    return bundle_id


def _unit_multiplier(unit: str) -> int:
    return {"K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}[unit]


def _physical_footprint_bytes(pid: int) -> int:
    output = _run(["footprint", "-p", str(pid), "-summary"], timeout=30)
    match = re.search(r"phys_footprint:\s*([0-9.]+)\s*([KMGT]B?)", output)
    if not match:
        raise cmuxError(f"Could not parse phys_footprint from footprint output: {output[:800]!r}")
    return int(float(match.group(1)) * _unit_multiplier(match.group(2)[0]))


def _descendant_rss_bytes(root_pid: int) -> int:
    output = _run(["ps", "axww", "-o", "pid=,ppid=,rss=,command="], timeout=10)
    children: dict[str, list[tuple[str, int]]] = {}
    for line in output.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 3:
            continue
        pid, ppid, rss = parts[:3]
        try:
            rss_kb = int(rss)
        except ValueError:
            continue
        children.setdefault(ppid, []).append((pid, rss_kb))

    stack = [str(root_pid)]
    total_kb = 0
    while stack:
        parent = stack.pop()
        for child_pid, rss_kb in children.get(parent, []):
            total_kb += rss_kb
            stack.append(child_pid)
    return total_kb * 1024


def _mb(value: int) -> float:
    return value / (1024.0 * 1024.0)


def _new_id() -> str:
    return str(uuid.uuid4()).upper()


def _panel(panel_id: str, index: int, home: str) -> dict[str, Any]:
    return {
        "id": panel_id,
        "type": "terminal",
        "title": f"restore-footprint-{index:04d}",
        "customTitle": None,
        "directory": home,
        "isPinned": False,
        "isManuallyUnread": False,
        "gitBranch": None,
        "listeningPorts": [],
        "ttyName": None,
        "terminal": {
            "workingDirectory": home,
            "scrollback": None,
            "agent": None,
            "tmuxStartCommand": None,
        },
        "browser": None,
        "markdown": None,
        "filePreview": None,
    }


def _pane_node(panel_ids: list[str]) -> dict[str, Any]:
    return {
        "type": "pane",
        "pane": {
            "panelIds": panel_ids,
            "selectedPanelId": panel_ids[0] if panel_ids else None,
        },
    }


def _split_nodes(nodes: list[dict[str, Any]], depth: int = 0) -> dict[str, Any]:
    if len(nodes) == 1:
        return nodes[0]
    midpoint = len(nodes) // 2
    return {
        "type": "split",
        "split": {
            "orientation": "vertical" if depth % 2 == 0 else "horizontal",
            "dividerPosition": 0.5,
            "first": _split_nodes(nodes[:midpoint], depth + 1),
            "second": _split_nodes(nodes[midpoint:], depth + 1),
        },
    }


def _session_snapshot(panel_count: int, pane_count: int, title: str) -> dict[str, Any]:
    home = str(Path.home())
    panel_ids = [_new_id() for _ in range(panel_count)]
    panels = [_panel(panel_id, index + 1, home) for index, panel_id in enumerate(panel_ids)]

    bounded_pane_count = max(1, min(pane_count, panel_count))
    base = panel_count // bounded_pane_count
    remainder = panel_count % bounded_pane_count
    chunks: list[list[str]] = []
    offset = 0
    for pane_index in range(bounded_pane_count):
        size = base + (1 if pane_index < remainder else 0)
        chunks.append(panel_ids[offset : offset + size])
        offset += size

    workspace = {
        "processTitle": title,
        "customTitle": title,
        "customDescription": "generated terminal restore memory regression",
        "customColor": None,
        "isPinned": False,
        "terminalScrollBarHidden": False,
        "currentDirectory": home,
        "focusedPanelId": panel_ids[0],
        "layout": _split_nodes([_pane_node(chunk) for chunk in chunks if chunk]),
        "panels": panels,
        "statusEntries": [],
        "logEntries": [],
        "progress": None,
        "gitBranch": None,
        "remote": None,
    }

    return {
        "createdAt": time.time(),
        "version": 1,
        "windows": [
            {
                "frame": {"x": 20, "y": 80, "width": 1200, "height": 800},
                "display": None,
                "sidebar": {"isVisible": True, "selection": "tabs", "width": 280},
                "tabManager": {"selectedWorkspaceIndex": 0, "workspaces": [workspace]},
            }
        ],
    }


def _session_paths(bundle_id: str) -> tuple[Path, Path]:
    app_support = Path.home() / "Library" / "Application Support" / "cmux"
    safe_bundle_id = re.sub(r"[^A-Za-z0-9._-]", "_", bundle_id)
    return (
        app_support / f"session-{safe_bundle_id}.json",
        app_support / f"session-{safe_bundle_id}-previous.json",
    )


def _write_restore_snapshot(bundle_id: str, snapshot: dict[str, Any]) -> None:
    default_path, previous_path = _session_paths(bundle_id)
    default_path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(snapshot, separators=(",", ":"), sort_keys=True)
    default_path.write_text(payload, encoding="utf-8")
    previous_path.write_text(payload, encoding="utf-8")


def _restore_snapshot(bundle_id: str, snapshot: dict[str, Any]) -> None:
    _write_restore_snapshot(bundle_id, snapshot)
    with cmux(SOCKET_PATH) as client:
        client._call("session.restore_previous", timeout_s=RESTORE_TIMEOUT_SECONDS)


def _wait_for_surface_count(expected: int, timeout_s: float = 20.0) -> None:
    deadline = time.time() + timeout_s
    last_count = -1
    while time.time() < deadline:
        try:
            with cmux(SOCKET_PATH) as client:
                total = 0
                for _index, pane_id, _surface_count, _focused in client.list_panes():
                    total += len(client.list_pane_surfaces(pane_id))
                if total == expected:
                    return
                last_count = total
        except Exception:
            pass
        time.sleep(0.2)
    raise cmuxError(f"Timed out waiting for {expected} restored surfaces, last_count={last_count}")


def main() -> int:
    started_at = time.monotonic()
    _must(PANEL_COUNT >= 1, "CMUX_RESTORE_FOOTPRINT_PANELS must be >= 1")
    _must(PANE_COUNT >= 1, "CMUX_RESTORE_FOOTPRINT_PANES must be >= 1")

    pid = _cmux_pid()
    bundle_id = _bundle_identifier(_bundle_path_for_pid(pid))
    cleanup_snapshot = _session_snapshot(1, 1, "restore-footprint-cleanup")
    stress_snapshot = _session_snapshot(PANEL_COUNT, PANE_COUNT, f"restore-footprint-{PANEL_COUNT}")

    try:
        _restore_snapshot(bundle_id, cleanup_snapshot)
        _wait_for_surface_count(1, timeout_s=10)
        time.sleep(3)

        pid = _cmux_pid()
        baseline_footprint = _physical_footprint_bytes(pid)
        baseline_descendants = _descendant_rss_bytes(pid)

        _restore_snapshot(bundle_id, stress_snapshot)
        _wait_for_surface_count(PANEL_COUNT, timeout_s=30)
        time.sleep(SETTLE_SECONDS)

        pid = _cmux_pid()
        restored_footprint = _physical_footprint_bytes(pid)
        restored_descendants = _descendant_rss_bytes(pid)

        footprint_growth = restored_footprint - baseline_footprint
        descendant_growth = restored_descendants - baseline_descendants
        budget_bytes = FOOTPRINT_GROWTH_BUDGET_MB * 1024 * 1024
        descendant_budget_bytes = DESCENDANT_RSS_BUDGET_MB * 1024 * 1024

        _must(
            footprint_growth <= budget_bytes,
            "Restoring many terminal tabs grew cmux app physical footprint too much: "
            f"panels={PANEL_COUNT} panes={PANE_COUNT} "
            f"baseline={_mb(baseline_footprint):.1f}MB "
            f"restored={_mb(restored_footprint):.1f}MB "
            f"delta={_mb(footprint_growth):.1f}MB "
            f"budget={FOOTPRINT_GROWTH_BUDGET_MB}MB",
        )
        _must(
            descendant_growth <= descendant_budget_bytes,
            "Restoring many hidden terminal tabs spawned too much descendant RSS: "
            f"panels={PANEL_COUNT} panes={PANE_COUNT} "
            f"baseline={_mb(baseline_descendants):.1f}MB "
            f"restored={_mb(restored_descendants):.1f}MB "
            f"delta={_mb(descendant_growth):.1f}MB "
            f"budget={DESCENDANT_RSS_BUDGET_MB}MB",
        )
    finally:
        try:
            _restore_snapshot(bundle_id, cleanup_snapshot)
        except Exception:
            pass

    elapsed = time.monotonic() - started_at
    print(
        "PASS: terminal session restore keeps hidden surface footprint bounded "
        f"(panels={PANEL_COUNT} panes={PANE_COUNT} "
        f"app_delta={_mb(footprint_growth):.1f}MB "
        f"descendant_delta={_mb(descendant_growth):.1f}MB "
        f"elapsed={elapsed:.1f}s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
