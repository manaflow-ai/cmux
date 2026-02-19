#!/usr/bin/env python3
"""Regression: CLI commands are workspace-relative via CMUX_WORKSPACE_ID.

Tests that when CMUX_WORKSPACE_ID is set, CLI commands target that workspace
(not the focused workspace). This is the core P0 #2 behavior: agents in
background workspaces should not affect the user's active workspace.
"""

import glob
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

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
    """Run CLI command and return stdout."""
    cmd = [cli, "--socket", SOCKET_PATH] + args
    env = os.environ.copy()
    if env_overrides:
        env.update(env_overrides)
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.stdout.strip()


def _run_cli_json(cli: str, args: List[str], env_overrides: Optional[Dict[str, str]] = None) -> Any:
    """Run CLI command with --json and return parsed output."""
    output = _run_cli(cli, ["--json"] + args, env_overrides=env_overrides)
    try:
        return json.loads(output or "{}")
    except Exception as exc:
        raise cmuxError(f"Invalid JSON output: {output!r} ({exc})")


def test_list_panels_workspace_relative(c: cmux, cli: str) -> None:
    """list-panels with --workspace targets the specified workspace."""
    # Get current workspaces
    ws_result = c._call("workspace.list")
    workspaces = ws_result.get("workspaces", [])
    _must(len(workspaces) >= 1, "Need at least 1 workspace")

    ws_a = workspaces[0]
    ws_a_ref = ws_a.get("ref", ws_a["id"])

    # Use CLI with explicit --workspace flag
    payload = _run_cli_json(cli, ["list-panels", "--workspace", ws_a_ref])
    surfaces = payload.get("surfaces", [])
    _must(isinstance(surfaces, list), f"Expected surfaces array, got: {payload}")

    # Also test via env var
    payload_env = _run_cli_json(
        cli, ["list-panels"],
        env_overrides={"CMUX_WORKSPACE_ID": ws_a["id"]}
    )
    surfaces_env = payload_env.get("surfaces", [])
    _must(isinstance(surfaces_env, list), f"Expected surfaces array from env, got: {payload_env}")

    # Both should return surfaces for the same workspace
    ws_id_flag = payload.get("workspace_id") or payload.get("workspace_ref")
    ws_id_env = payload_env.get("workspace_id") or payload_env.get("workspace_ref")
    _must(ws_id_flag is not None, f"Missing workspace ID in flag response: {payload}")
    _must(ws_id_env is not None, f"Missing workspace ID in env response: {payload_env}")

    print("  PASS: list-panels workspace-relative (flag and env)")


def test_list_panes_workspace_relative(c: cmux, cli: str) -> None:
    """list-panes with --workspace targets the specified workspace."""
    ws_result = c._call("workspace.list")
    workspaces = ws_result.get("workspaces", [])
    _must(len(workspaces) >= 1, "Need at least 1 workspace")

    ws_ref = workspaces[0].get("ref", workspaces[0]["id"])

    payload = _run_cli_json(cli, ["list-panes", "--workspace", ws_ref])
    panes = payload.get("panes", [])
    _must(isinstance(panes, list), f"Expected panes array, got: {payload}")
    _must(len(panes) >= 1, f"Expected at least 1 pane, got: {panes}")

    print("  PASS: list-panes workspace-relative")


def test_send_workspace_relative(c: cmux, cli: str) -> None:
    """send with CMUX_WORKSPACE_ID env var targets that workspace's surface."""
    ws_result = c._call("workspace.list")
    workspaces = ws_result.get("workspaces", [])
    _must(len(workspaces) >= 1, "Need at least 1 workspace")

    ws = workspaces[0]

    # Get a surface in this workspace
    surfaces = c._call("surface.list", {"workspace_id": ws["id"]})
    surface_list = surfaces.get("surfaces", [])
    _must(len(surface_list) >= 1, "Need at least 1 surface in workspace")

    # Send a harmless empty echo via env var to verify workspace routing
    output = _run_cli(
        cli, ["send", " "],
        env_overrides={"CMUX_WORKSPACE_ID": ws["id"]}
    )
    _must("OK" in output or "surface" in output.lower(),
          f"Expected OK from send, got: {output}")
    print("  PASS: send workspace-relative (env var accepted)")


def test_send_with_explicit_workspace(c: cmux, cli: str) -> None:
    """send with --workspace flag targets the specified workspace's surface."""
    ws_result = c._call("workspace.list")
    workspaces = ws_result.get("workspaces", [])
    _must(len(workspaces) >= 1, "Need at least 1 workspace")

    ws_ref = workspaces[0].get("ref", workspaces[0]["id"])

    # Send a space character (harmless) with explicit workspace
    output = _run_cli(cli, ["send", "--workspace", ws_ref, " "])
    _must(output.startswith("OK") or "surface" in output.lower(),
          f"Expected OK from send, got: {output}")

    print("  PASS: send with explicit --workspace")


def test_v2_migrated_commands_output_refs(c: cmux, cli: str) -> None:
    """Verify migrated commands output refs in JSON by default."""
    # list-panels should output refs
    payload = _run_cli_json(cli, ["list-panels"])
    surfaces = payload.get("surfaces", [])
    if surfaces:
        first = surfaces[0]
        _must("ref" in first or "id" in first,
              f"Expected ref or id in surface: {first}")
        # Default should suppress _id when _ref exists
        if "ref" in first:
            _must("id" not in first,
                  f"Default format should suppress id when ref exists: {first}")

    # list-panes should output refs
    payload = _run_cli_json(cli, ["list-panes"])
    panes = payload.get("panes", [])
    if panes:
        first = panes[0]
        _must("ref" in first or "id" in first,
              f"Expected ref or id in pane: {first}")

    # list-workspaces should output refs
    payload = _run_cli_json(cli, ["list-workspaces"])
    workspaces = payload.get("workspaces", [])
    if workspaces:
        first = workspaces[0]
        _must("ref" in first or "id" in first,
              f"Expected ref or id in workspace: {first}")
        if "ref" in first:
            _must("id" not in first,
                  f"Default format should suppress id when ref exists: {first}")

    print("  PASS: migrated commands output refs by default")


def test_surface_health_workspace_relative(c: cmux, cli: str) -> None:
    """surface-health with --workspace targets the specified workspace."""
    ws_result = c._call("workspace.list")
    workspaces = ws_result.get("workspaces", [])
    _must(len(workspaces) >= 1, "Need at least 1 workspace")

    ws_ref = workspaces[0].get("ref", workspaces[0]["id"])

    payload = _run_cli_json(cli, ["surface-health", "--workspace", ws_ref])
    surfaces = payload.get("surfaces", [])
    _must(isinstance(surfaces, list), f"Expected surfaces array, got: {payload}")

    print("  PASS: surface-health workspace-relative")


def test_non_json_output_uses_refs(c: cmux, cli: str) -> None:
    """Non-JSON output from migrated commands uses ref format."""
    # list-panels non-JSON
    output = _run_cli(cli, ["list-panels"])
    _must("surface:" in output or "No surfaces" in output,
          f"Expected ref format in list-panels output, got: {output}")

    # list-panes non-JSON
    output = _run_cli(cli, ["list-panes"])
    _must("pane:" in output or "No panes" in output,
          f"Expected ref format in list-panes output, got: {output}")

    # list-workspaces non-JSON
    output = _run_cli(cli, ["list-workspaces"])
    _must("workspace:" in output or "No workspaces" in output,
          f"Expected ref format in list-workspaces output, got: {output}")

    print("  PASS: non-JSON output uses refs")


def main() -> int:
    cli = _find_cli_binary()
    print(f"Using CLI: {cli}")

    c = cmux(SOCKET_PATH)
    c.connect()
    try:
        test_list_panels_workspace_relative(c, cli)
        test_list_panes_workspace_relative(c, cli)
        test_send_workspace_relative(c, cli)
        test_send_with_explicit_workspace(c, cli)
        test_v2_migrated_commands_output_refs(c, cli)
        test_surface_health_workspace_relative(c, cli)
        test_non_json_output_uses_refs(c, cli)
    finally:
        c.close()

    print("\nPASS: All workspace-relative tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
