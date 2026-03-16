#!/usr/bin/env python3
"""Regression: public CLI exposes rich sidebar metadata and markdown blocks."""

from __future__ import annotations

import glob
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional

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

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"), recursive=True)
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli(cli: str, args: List[str], env_overrides: Optional[Dict[str, str]] = None) -> str:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)
    if env_overrides:
        env.update(env_overrides)

    cmd = [cli, "--socket", SOCKET_PATH] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return (proc.stdout or "").strip()


def _parse_sidebar_state(text: str) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        parsed[key.strip()] = value.strip()
    return parsed


def _wait_for_state_field(
    cli: str,
    workspace: str,
    key: str,
    expected: str,
    timeout: float = 8.0,
    interval: float = 0.1,
) -> dict[str, str]:
    deadline = time.time() + timeout
    last_state = ""
    while time.time() < deadline:
        last_state = _run_cli(cli, ["sidebar-state", "--workspace", workspace])
        parsed = _parse_sidebar_state(last_state)
        if parsed.get(key) == expected:
            return parsed
        time.sleep(interval)
    raise cmuxError(f"Timed out waiting for {key}={expected!r}. Last sidebar-state: {last_state!r}")


def _current_workspace(c: cmux) -> str:
    payload = c._call("workspace.current") or {}
    workspace_id = str(payload.get("workspace_id") or "")
    if not workspace_id:
        raise cmuxError(f"workspace.current returned no workspace_id: {payload}")
    return workspace_id


def main() -> int:
    cli = _find_cli_binary()
    stamp = int(time.time() * 1000)
    created_workspace: str | None = None

    try:
        with cmux(SOCKET_PATH) as c:
            baseline_workspace = _current_workspace(c)

            created = c._call("workspace.create") or {}
            created_workspace = str(created.get("workspace_id") or "")
            _must(bool(created_workspace), f"workspace.create returned no workspace_id: {created}")

            meta_url = f"https://example.com/tasks/{stamp}"
            meta_value = f"**Review** --workspace {stamp}"
            _run_cli(
                cli,
                [
                    "set-meta",
                    "task",
                    "--icon",
                    "sf:doc.text.magnifyingglass",
                    "--color",
                    "#ff9500",
                    "--url",
                    meta_url,
                    "--priority",
                    "50",
                    "--format",
                    "markdown",
                    "--workspace",
                    created_workspace,
                    "--",
                    "**Review**",
                    "--workspace",
                    str(stamp),
                ],
            )
            _must(_current_workspace(c) == baseline_workspace, "set-meta should not switch selected workspace")
            _wait_for_state_field(cli, created_workspace, "status_count", "1")

            listed_meta = _run_cli(cli, ["list-meta", "--workspace", created_workspace]).splitlines()
            _must(len(listed_meta) == 1, f"Expected 1 metadata entry, got {listed_meta}")
            _must(listed_meta[0].startswith(f"task={meta_value}"), f"Unexpected metadata line: {listed_meta[0]!r}")
            _must("icon=sf:doc.text.magnifyingglass" in listed_meta[0], f"Missing icon in metadata line: {listed_meta[0]!r}")
            _must("color=#ff9500" in listed_meta[0], f"Missing color in metadata line: {listed_meta[0]!r}")
            _must(f"url={meta_url}" in listed_meta[0], f"Missing URL in metadata line: {listed_meta[0]!r}")
            _must("priority=50" in listed_meta[0], f"Missing priority in metadata line: {listed_meta[0]!r}")
            _must("format=markdown" in listed_meta[0], f"Missing format in metadata line: {listed_meta[0]!r}")

            status_url = f"https://example.com/agents/{stamp}"
            _run_cli(
                cli,
                [
                    "set-status",
                    "agent",
                    "--icon",
                    "text:AI",
                    "--url",
                    status_url,
                    "--priority",
                    "80",
                    "--format",
                    "markdown",
                    "--workspace",
                    created_workspace,
                    "--",
                    "**busy**",
                ],
            )
            _must(_current_workspace(c) == baseline_workspace, "set-status should not switch selected workspace")
            _wait_for_state_field(cli, created_workspace, "status_count", "2")

            listed_status = _run_cli(cli, ["list-status", "--workspace", created_workspace]).splitlines()
            _must(len(listed_status) == 2, f"Expected 2 status entries, got {listed_status}")
            _must(listed_status[0].startswith("agent=**busy**"), f"Expected agent entry first, got {listed_status[0]!r}")
            _must(f"url={status_url}" in listed_status[0], f"Missing URL in status line: {listed_status[0]!r}")
            _must("priority=80" in listed_status[0], f"Missing priority in status line: {listed_status[0]!r}")
            _must("format=markdown" in listed_status[0], f"Missing format in status line: {listed_status[0]!r}")

            _run_cli(cli, ["clear-meta", "task", "--workspace", created_workspace])
            _must(_current_workspace(c) == baseline_workspace, "clear-meta should not switch selected workspace")
            _wait_for_state_field(cli, created_workspace, "status_count", "1")
            listed_meta = _run_cli(cli, ["list-meta", "--workspace", created_workspace]).splitlines()
            _must(all(not line.startswith("task=") for line in listed_meta), f"task metadata should be cleared: {listed_meta}")

            env_value = f"env default {stamp}"
            _run_cli(
                cli,
                ["set-meta", "context", "--", env_value],
                env_overrides={"CMUX_WORKSPACE_ID": created_workspace},
            )
            _wait_for_state_field(cli, created_workspace, "status_count", "2")
            listed_meta = _run_cli(
                cli,
                ["list-meta"],
                env_overrides={"CMUX_WORKSPACE_ID": created_workspace},
            ).splitlines()
            _must(any(line.startswith(f"context={env_value}") for line in listed_meta), f"Expected env-targeted metadata entry: {listed_meta}")
            _run_cli(
                cli,
                ["clear-meta", "context"],
                env_overrides={"CMUX_WORKSPACE_ID": created_workspace},
            )
            _wait_for_state_field(cli, created_workspace, "status_count", "1")

            summary_markdown = f"### Agent\n- status: busy\n- note: --priority literal {stamp}"
            footer_markdown = "_last update: now_"
            _run_cli(
                cli,
                ["set-meta-block", "summary", "--priority", "50", "--workspace", created_workspace, "--", summary_markdown],
            )
            _run_cli(
                cli,
                ["set-meta-block", "footer", "--priority", "10", "--workspace", created_workspace, "--", footer_markdown],
            )
            _must(_current_workspace(c) == baseline_workspace, "set-meta-block should not switch selected workspace")
            _wait_for_state_field(cli, created_workspace, "meta_block_count", "2")

            listed_blocks = _run_cli(cli, ["list-meta-blocks", "--workspace", created_workspace]).splitlines()
            _must(len(listed_blocks) == 2, f"Expected 2 metadata blocks, got {listed_blocks}")
            _must(listed_blocks[0].startswith("summary="), f"Expected highest-priority block first, got {listed_blocks[0]!r}")
            _must("priority=50" in listed_blocks[0], f"Missing priority in block listing: {listed_blocks[0]!r}")
            _must("\\n- note: --priority literal" in listed_blocks[0], f"Expected escaped newline content in block listing: {listed_blocks[0]!r}")

            _run_cli(cli, ["clear-meta-block", "summary", "--workspace", created_workspace])
            _must(_current_workspace(c) == baseline_workspace, "clear-meta-block should not switch selected workspace")
            _wait_for_state_field(cli, created_workspace, "meta_block_count", "1")
            listed_blocks = _run_cli(cli, ["list-meta-blocks", "--workspace", created_workspace]).splitlines()
            _must(all(not line.startswith("summary=") for line in listed_blocks), f"summary block should be cleared: {listed_blocks}")

            c.close_workspace(created_workspace)
            created_workspace = None

        print("PASS: CLI sidebar metadata parity works for rich entries, blocks, and env targeting")
        return 0
    except (cmuxError, AssertionError) as exc:
        print(f"CLI sidebar metadata parity test failed: {exc}")
        return 1
    finally:
        if created_workspace:
            try:
                with cmux(SOCKET_PATH) as c:
                    c.close_workspace(created_workspace)
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
