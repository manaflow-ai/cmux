#!/usr/bin/env python3
"""Regression: workspace list text output teaches refs vs legacy bare indices."""

from __future__ import annotations

import glob
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(
        os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"),
        recursive=True,
    )
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli(cli: str, args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [cli, "--socket", SOCKET_PATH] + args,
        capture_output=True,
        text=True,
        check=False,
    )


def _run_cli_json(cli: str, args: list[str]) -> dict[str, Any]:
    proc = _run_cli(cli, ["--json"] + args)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(args)}): {merged}")
    try:
        return json.loads(proc.stdout or "{}")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output for {' '.join(args)}: {proc.stdout!r} ({exc})")


def _find_workspace_line(output: str, title: str) -> str:
    for line in output.splitlines():
        if title in line:
            return line
    raise cmuxError(f"Could not find workspace line for {title!r} in output: {output!r}")


def main() -> int:
    cli = _find_cli_binary()
    client = cmux(SOCKET_PATH)
    client.connect()

    created_workspace_ids: list[str] = []
    try:
        seed = str(int(time.time()))
        titles = [
            f"cli list refs {seed} a",
            f"cli list refs {seed} b",
        ]

        for title in titles:
            workspace_id = client.new_workspace()
            created_workspace_ids.append(workspace_id)
            client.rename_workspace(title, workspace_id)

        payload = _run_cli_json(cli, ["list-workspaces"])
        workspace_rows = payload.get("workspaces") or []

        expected_rows: list[tuple[str, dict[str, Any]]] = []
        for title in titles:
            row = next((item for item in workspace_rows if item.get("title") == title), None)
            _must(row is not None, f"Missing workspace row for {title!r}: {payload}")
            expected_rows.append((title, row))

        text_proc = _run_cli(cli, ["list-workspaces"])
        text_output = f"{text_proc.stdout}\n{text_proc.stderr}".strip()
        _must(text_proc.returncode == 0, f"list-workspaces failed: {text_output!r}")

        for title, row in expected_rows:
            ref = str(row.get("ref") or "")
            index = row.get("index")
            _must(ref.startswith("workspace:"), f"Expected workspace ref for {title!r}: {row}")
            _must(index is not None, f"Expected workspace index for {title!r}: {row}")

            line = _find_workspace_line(text_output, title)
            _must(ref in line, f"Workspace line missing ref {ref!r}: {line!r}")
            _must(
                f"index={index}" in line,
                f"Workspace line should expose legacy bare index {index!r}: {line!r}",
            )

        help_proc = _run_cli(cli, ["select-workspace", "--help"])
        help_output = f"{help_proc.stdout}\n{help_proc.stderr}".strip().lower()
        _must(help_proc.returncode == 0, f"select-workspace --help failed: {help_output!r}")
        _must("zero-based" in help_output, f"Help should explain legacy zero-based indices: {help_output!r}")
        _must("list-workspaces" in help_output, f"Help should point users back to list-workspaces: {help_output!r}")
        _must("workspace:2" in help_output, f"Help should prefer workspace refs in examples: {help_output!r}")

    finally:
        for workspace_id in reversed(created_workspace_ids):
            try:
                client.close_workspace(workspace_id)
            except Exception:
                pass
        try:
            client.close()
        except Exception:
            pass

    print("PASS: list-workspaces text output and help teach refs vs legacy bare indices")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
