#!/usr/bin/env python3
"""Regression: ssh workspace keeps large pre-resize scrollback across split resize churn."""

from __future__ import annotations

import glob
import json
import os
import re
import secrets
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux.sock")
SSH_HOST = os.environ.get("CMUX_SSH_TEST_HOST", "").strip()
SSH_PORT = os.environ.get("CMUX_SSH_TEST_PORT", "").strip()
SSH_IDENTITY = os.environ.get("CMUX_SSH_TEST_IDENTITY", "").strip()
SSH_OPTIONS_RAW = os.environ.get("CMUX_SSH_TEST_OPTIONS", "").strip()
LS_ENTRY_COUNT = int(os.environ.get("CMUX_SSH_TEST_LS_COUNT", "320"))
RESIZE_ITERATIONS = int(os.environ.get("CMUX_SSH_TEST_RESIZE_ITERATIONS", "48"))

ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
OSC_ESCAPE_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _run(cmd: list[str], *, env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env, check=False)
    if check and proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"Command failed ({' '.join(cmd)}): {merged}")
    return proc


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


def _run_cli_json(cli: str, args: list[str]) -> dict:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    proc = _run([cli, "--socket", SOCKET_PATH, "--json", *args], env=env)
    try:
        return json.loads(proc.stdout or "{}")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output for {' '.join(args)}: {proc.stdout!r} ({exc})")


def _wait_for(pred, timeout_s: float = 8.0, step_s: float = 0.1) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if pred():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


def _wait_remote_connected(client: cmux, workspace_id: str, timeout_s: float = 45.0) -> None:
    deadline = time.time() + timeout_s
    last = {}
    while time.time() < deadline:
        last = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = last.get("remote") or {}
        daemon = remote.get("daemon") or {}
        if str(remote.get("state") or "") == "connected" and str(daemon.get("state") or "") == "ready":
            return
        time.sleep(0.25)
    raise cmuxError(f"Remote did not reach connected+ready state: {last}")


def _resolve_workspace_id(client: cmux, payload: dict, *, before_workspace_ids: set[str]) -> str:
    workspace_id = str(payload.get("workspace_id") or "")
    if workspace_id:
        return workspace_id

    workspace_ref = str(payload.get("workspace_ref") or "")
    if workspace_ref.startswith("workspace:"):
        listed = client._call("workspace.list", {}) or {}
        for row in listed.get("workspaces") or []:
            if str(row.get("ref") or "") == workspace_ref:
                resolved = str(row.get("id") or "")
                if resolved:
                    return resolved

    current = {wid for _index, wid, _title, _focused in client.list_workspaces()}
    new_ids = sorted(current - before_workspace_ids)
    if len(new_ids) == 1:
        return new_ids[0]

    raise cmuxError(f"Unable to resolve workspace_id from payload: {payload}")


def _clean_line(raw: str) -> str:
    line = OSC_ESCAPE_RE.sub("", raw)
    line = ANSI_ESCAPE_RE.sub("", line)
    line = line.replace("\r", "")
    return line.strip()


def _surface_scrollback_text(client: cmux, workspace_id: str, surface_id: str) -> str:
    payload = client._call(
        "surface.read_text",
        {"workspace_id": workspace_id, "surface_id": surface_id, "scrollback": True},
    ) or {}
    return str(payload.get("text") or "")


def _surface_scrollback_lines(client: cmux, workspace_id: str, surface_id: str) -> list[str]:
    return [_clean_line(raw) for raw in _surface_scrollback_text(client, workspace_id, surface_id).splitlines()]


def _wait_surface_contains(
    client: cmux,
    workspace_id: str,
    surface_id: str,
    token: str,
    *,
    exact_line: bool = False,
    timeout_s: float = 25.0,
) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if exact_line:
            if token in _surface_scrollback_lines(client, workspace_id, surface_id):
                return
        elif token in _surface_scrollback_text(client, workspace_id, surface_id):
            return
        time.sleep(0.2)
    raise cmuxError(f"Timed out waiting for terminal token: {token}")


def _pane_for_surface(client: cmux, surface_id: str) -> str:
    target_id = str(client._resolve_surface_id(surface_id))
    for _idx, pane_id, _count, _focused in client.list_panes():
        rows = client.list_pane_surfaces(pane_id)
        for _row_idx, sid, _title, _selected in rows:
            try:
                candidate_id = str(client._resolve_surface_id(sid))
            except cmuxError:
                continue
            if candidate_id == target_id:
                return pane_id
    raise cmuxError(f"Surface {surface_id} is not present in current workspace panes")


def _valid_resize_directions(client: cmux, workspace_id: str, pane_id: str) -> list[str]:
    valid: list[str] = []
    for direction in ("left", "right", "up", "down"):
        try:
            client._call(
                "pane.resize",
                {
                    "workspace_id": workspace_id,
                    "pane_id": pane_id,
                    "direction": direction,
                    "amount": 10,
                },
            )
            valid.append(direction)
        except cmuxError:
            pass
    return valid


def _choose_resize_pair(client: cmux, workspace_id: str, pane_ids: list[str]) -> list[tuple[str, str]]:
    by_pane: dict[str, list[str]] = {}
    for pane_id in pane_ids:
        by_pane[pane_id] = _valid_resize_directions(client, workspace_id, pane_id)

    for pane_a, directions_a in by_pane.items():
        if "right" not in directions_a:
            continue
        for pane_b, directions_b in by_pane.items():
            if pane_b == pane_a:
                continue
            if "left" in directions_b:
                return [(pane_a, "right"), (pane_b, "left")]

    for pane_a, directions_a in by_pane.items():
        if "down" not in directions_a:
            continue
        for pane_b, directions_b in by_pane.items():
            if pane_b == pane_a:
                continue
            if "up" in directions_b:
                return [(pane_a, "down"), (pane_b, "up")]

    raise cmuxError(f"Could not find oscillating resize pair across panes: {by_pane}")


def main() -> int:
    if not SSH_HOST:
        print("SKIP: set CMUX_SSH_TEST_HOST to run remote resize scrollback regression")
        return 0
    if LS_ENTRY_COUNT < 64:
        print("SKIP: CMUX_SSH_TEST_LS_COUNT must be >= 64 for meaningful scrollback coverage")
        return 0

    cli = _find_cli_binary()
    workspace_id = ""

    try:
        with cmux(SOCKET_PATH) as client:
            before_workspace_ids = {wid for _index, wid, _title, _focused in client.list_workspaces()}

            ssh_args = ["ssh", SSH_HOST, "--name", f"ssh-resize-regression-{secrets.token_hex(4)}"]
            if SSH_PORT:
                ssh_args.extend(["--port", SSH_PORT])
            if SSH_IDENTITY:
                ssh_args.extend(["--identity", SSH_IDENTITY])
            if SSH_OPTIONS_RAW:
                for option in SSH_OPTIONS_RAW.split(","):
                    trimmed = option.strip()
                    if trimmed:
                        ssh_args.extend(["--ssh-option", trimmed])

            payload = _run_cli_json(cli, ssh_args)
            workspace_id = _resolve_workspace_id(client, payload, before_workspace_ids=before_workspace_ids)
            _wait_remote_connected(client, workspace_id, timeout_s=50.0)

            surfaces = client.list_surfaces(workspace_id)
            _must(bool(surfaces), f"workspace should have at least one surface: {workspace_id}")
            surface_id = surfaces[0][1]

            stamp = secrets.token_hex(4)
            ls_entries = [f"CMUX_REMOTE_RESIZE_LS_{stamp}_{index:04d}.txt" for index in range(1, LS_ENTRY_COUNT + 1)]
            ls_start = f"CMUX_REMOTE_RESIZE_LS_START_{stamp}"
            ls_end = f"CMUX_REMOTE_RESIZE_LS_END_{stamp}"

            ls_prefix = f"CMUX_REMOTE_RESIZE_LS_{stamp}_"
            ls_script = (
                "tmpdir=$(mktemp -d); "
                f"echo {ls_start}; "
                f"for i in $(seq 1 {LS_ENTRY_COUNT}); do "
                "n=$(printf '%04d' \"$i\"); "
                f"touch \"$tmpdir/{ls_prefix}$n.txt\"; "
                "done; "
                "LC_ALL=C CLICOLOR=0 ls -1 \"$tmpdir\"; "
                f"echo {ls_end}; "
                "rm -rf \"$tmpdir\""
            )
            client.send_surface(surface_id, f"{ls_script}\n")
            _wait_surface_contains(
                client,
                workspace_id,
                surface_id,
                ls_end,
                exact_line=True,
                timeout_s=45.0,
            )

            pre_resize_lines = _surface_scrollback_lines(client, workspace_id, surface_id)
            _must(
                all(entry in pre_resize_lines for entry in ls_entries),
                "pre-resize scrollback missing ls fixture lines in ssh workspace",
            )
            pre_resize_anchors = [ls_entries[0], ls_entries[len(ls_entries) // 2], ls_entries[-1]]

            client.select_workspace(workspace_id)
            client.activate_app()
            pane_count_before_split = len(client.list_panes())
            client.simulate_shortcut("cmd+d")
            _wait_for(lambda: len(client.list_panes()) >= pane_count_before_split + 1, timeout_s=10.0)

            # Ensure the original surface remains selected before resize churn.
            client.focus_surface(surface_id)
            pane_ids = [pid for _idx, pid, _count, _focused in client.list_panes()]
            _must(len(pane_ids) >= 2, f"expected split workspace with >=2 panes: {pane_ids}")
            _ = _pane_for_surface(client, surface_id)
            resize_pair = _choose_resize_pair(client, workspace_id, pane_ids)

            for iteration in range(1, RESIZE_ITERATIONS + 1):
                pane_id, direction = resize_pair[(iteration - 1) % len(resize_pair)]
                _ = client._call(
                    "pane.resize",
                    {
                        "workspace_id": workspace_id,
                        "pane_id": pane_id,
                        "direction": direction,
                        "amount": 80,
                    },
                )
                if iteration % 8 == 0:
                    sampled_lines = _surface_scrollback_lines(client, workspace_id, surface_id)
                    _must(
                        all(anchor in sampled_lines for anchor in pre_resize_anchors),
                        f"resize iteration {iteration} lost pre-resize anchor lines in ssh workspace",
                    )

            post_token = f"CMUX_REMOTE_RESIZE_POST_{secrets.token_hex(6)}"
            client.send_surface(surface_id, f"echo {post_token}\n")
            _wait_surface_contains(
                client,
                workspace_id,
                surface_id,
                post_token,
                exact_line=True,
                timeout_s=25.0,
            )

            post_resize_lines = _surface_scrollback_lines(client, workspace_id, surface_id)
            _must(
                all(entry in post_resize_lines for entry in ls_entries),
                "post-resize scrollback lost ls fixture lines in ssh workspace",
            )
            _must(
                post_token in post_resize_lines,
                f"post-resize scrollback missing post token: {post_token}",
            )

            client.close_workspace(workspace_id)
            workspace_id = ""

        print(
            "PASS: cmux ssh split+resize churn preserved large pre-resize scrollback "
            f"(entries={LS_ENTRY_COUNT}, iterations={RESIZE_ITERATIONS})"
        )
        return 0

    finally:
        if workspace_id:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
