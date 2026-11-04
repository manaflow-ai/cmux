#!/usr/bin/env python3
"""Regression: `tab.action set_badge` puts text in front of the live tab title.

A badge must prefix the title the terminal reports (and a custom name), not
replace it, and `clear_badge` must restore the plain title. The CLI accepts the
badge as `--badge <text>` or trailing text and targets `CMUX_TAB_ID`.
"""

import glob
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")
TARGET_ENV_KEYS = {"CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID"}


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


def _run_cli(cli: str, args: List[str], env: Optional[Dict[str, str]] = None, check: bool = True) -> subprocess.CompletedProcess:
    merged_env = {k: v for k, v in os.environ.items() if k not in TARGET_ENV_KEYS}
    if env:
        merged_env.update(env)
    cmd = [cli, "--socket", SOCKET_PATH] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=merged_env)
    if check and proc.returncode != 0:
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {proc.stdout}\n{proc.stderr}".strip())
    return proc


def _tab_title(c: cmux, ws_id: str, surface_id: str) -> str:
    payload = c._call("pane.surfaces", {"workspace_id": ws_id}) or {}
    for row in payload.get("surfaces") or []:
        if str(row.get("id")) == surface_id:
            return str(row.get("title") or "")
    raise cmuxError(f"pane.surfaces has no row for {surface_id}: {payload}")


def _wait_for_title(c: cmux, ws_id: str, surface_id: str, expected: str) -> None:
    deadline = time.time() + 5.0
    title = ""
    while time.time() < deadline:
        title = _tab_title(c, ws_id, surface_id)
        if title == expected:
            return
        time.sleep(0.05)
    raise cmuxError(f"Expected tab title {expected!r}, got {title!r}")


def main() -> int:
    cli = _find_cli_binary()
    stamp = int(time.time() * 1000)

    with cmux(SOCKET_PATH) as c:
        created = c._call("workspace.create") or {}
        ws_id = str(created.get("workspace_id") or "")
        _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")
        c._call("workspace.select", {"workspace_id": ws_id})
        current = c._call("surface.current", {"workspace_id": ws_id}) or {}
        surface_id = str(current.get("surface_id") or "")
        _must(bool(surface_id), f"surface.current returned no surface_id: {current}")
        target = {"workspace_id": ws_id, "surface_id": surface_id}

        # A custom name gives a deterministic base title to compose with.
        base = f"badge base {stamp}"
        c._call("tab.action", {**target, "action": "rename", "title": base})
        _wait_for_title(c, ws_id, surface_id, base)

        payload = c._call("tab.action", {**target, "action": "set_badge", "badge": " 🦀 "}) or {}
        _must(payload.get("badge") == "🦀", f"set_badge should echo the trimmed badge: {payload}")
        _wait_for_title(c, ws_id, surface_id, f"🦀 {base}")

        # Renaming keeps the badge in front of the new name.
        renamed = f"badge renamed {stamp}"
        c._call("tab.action", {**target, "action": "rename", "title": renamed})
        _wait_for_title(c, ws_id, surface_id, f"🦀 {renamed}")

        # One past PanelBadgeText.maximumCharacters (16).
        rejected: Optional[cmuxError] = None
        try:
            c._call("tab.action", {**target, "action": "set_badge", "badge": "x" * 17})
        except cmuxError as err:
            rejected = err
        _must(rejected is not None, "set_badge with 17 characters should fail")
        _must("invalid badge" in str(rejected).lower(), f"Unexpected set_badge error: {rejected}")
        _wait_for_title(c, ws_id, surface_id, f"🦀 {renamed}")

        colored = c._call("tab.action", {**target, "action": "set_badge", "badge": "🦀", "color": "#bb9af7"}) or {}
        _must(colored.get("badge_color") == "#BB9AF7", f"set_badge should echo the normalized color: {colored}")
        bad_color: Optional[cmuxError] = None
        try:
            c._call("tab.action", {**target, "action": "set_badge", "badge": "🦀", "color": "not-a-color"})
        except cmuxError as err:
            bad_color = err
        _must(bad_color is not None and "color" in str(bad_color).lower(), f"An unknown color should fail: {bad_color}")

        payload = c._call("tab.action", {**target, "action": "clear_badge"}) or {}
        _must("badge" in payload and payload["badge"] is None, f"clear_badge should report a null badge: {payload}")
        _wait_for_title(c, ws_id, surface_id, renamed)

        # CLI: trailing text, routed through CMUX_TAB_ID.
        out = _run_cli(cli, ["tab-action", "set-badge", "💼"], env={"CMUX_WORKSPACE_ID": ws_id, "CMUX_TAB_ID": surface_id}).stdout
        _must("action=set_badge" in out and "badge=💼" in out, f"Unexpected set-badge summary: {out!r}")
        _wait_for_title(c, ws_id, surface_id, f"💼 {renamed}")

        # CLI: explicit --badge flag and clear-badge.
        tinted = _run_cli(cli, ["tab-action", "--workspace", ws_id, "--tab", surface_id, "--action", "set-badge", "--badge", "🤝", "--color", "Blue"]).stdout
        _must("badge_color=#" in tinted, f"set-badge --color should report the resolved color: {tinted!r}")
        _wait_for_title(c, ws_id, surface_id, f"🤝 {renamed}")
        cleared = _run_cli(cli, ["tab-action", "--workspace", ws_id, "--tab", surface_id, "clear-badge"]).stdout
        _must("badge=none" in cleared, f"Unexpected clear-badge summary: {cleared!r}")
        _wait_for_title(c, ws_id, surface_id, renamed)

        both = _run_cli(cli, ["tab-action", "--workspace", ws_id, "--tab", surface_id, "set-badge", "--badge", "🦀", "💼"], check=False)
        _must(both.returncode != 0 and "not both" in both.stderr, f"set-badge with --badge and trailing text should fail: {both.stderr!r}")
        stray = _run_cli(cli, ["tab-action", "--workspace", ws_id, "--tab", surface_id, "pin", "--badge", "🦀"], check=False)
        _must(stray.returncode != 0 and "only applies to set-badge" in stray.stderr, f"--badge on another action should fail: {stray.stderr!r}")
        _wait_for_title(c, ws_id, surface_id, renamed)

        missing = _run_cli(cli, ["tab-action", "--workspace", ws_id, "--tab", surface_id, "set-badge"], check=False)
        _must(missing.returncode != 0, "set-badge without text should fail")
        _must("set-badge requires --badge" in f"{missing.stdout}\n{missing.stderr}", f"Unexpected error: {missing.stderr!r}")

        # The test workspace's shell is still running, so the close needs force.
        c._call("workspace.close", {"workspace_id": ws_id, "force": True})

    print("PASS: tab badges prefix the live title via socket and CLI")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
