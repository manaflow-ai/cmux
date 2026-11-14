#!/usr/bin/env python3
"""claude_account.switch: discoverable, and refuses safely on a pane that is not running Claude.

A real switch needs a signed-in Claude Code session, so this covers the refusals a plain
terminal can reach deterministically. Every refusal must leave the caller's workspace selected.
"""

from __future__ import annotations

import logging
import os
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")
METHOD = "claude_account.switch"


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _first_terminal_surface_id(payload: dict) -> str:
    for row in payload.get("surfaces") or []:
        if row.get("type") == "terminal":
            surface_id = str(row.get("id") or "")
            if surface_id:
                return surface_id
    raise cmuxError(f"surface.list returned no terminal surface: {payload}")


def _error_code(c: cmux, params: dict) -> str:
    """Calls the method expecting a refusal and returns its error code."""
    try:
        result = c._call(METHOD, params)
    except cmuxError as exc:
        return str(exc).split(":", 1)[0].strip()
    raise cmuxError(f"{METHOD} {params} unexpectedly succeeded: {result}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        advertised = set(c.capabilities().get("methods") or [])
        _must(METHOD in advertised, f"system.capabilities does not advertise {METHOD}")

        baseline_workspace = c.current_workspace()
        created_workspace = ""
        try:
            payload = c._call("workspace.create", {"focus": False}) or {}
            created_workspace = str(payload.get("workspace_id") or "")
            _must(bool(created_workspace), f"workspace.create returned no workspace_id: {payload}")
            surfaces = c._call("surface.list", {"workspace_id": created_workspace}) or {}
            surface_id = _first_terminal_surface_id(surfaces)
            target = {"workspace_id": created_workspace, "surface_id": surface_id}

            unknown = f"no-such-account-{uuid.uuid4().hex[:12]}"
            code = _error_code(c, {**target, "account": unknown})
            _must(code == "unknown_account", f"unknown account: expected unknown_account, got {code}")

            # The default account always exists, so this reaches the shared switch, which finds
            # no Claude session in a plain shell.
            code = _error_code(c, {**target, "account": "default"})
            _must(
                code in {"no_claude_session", "not_claude"},
                f"surface without Claude: expected no_claude_session or not_claude, got {code}",
            )
            code = _error_code(c, {**target, "account": "default", "force": True})
            _must(
                code in {"no_claude_session", "not_claude"},
                f"forced switch of a surface without Claude: expected no_claude_session or not_claude, got {code}",
            )

            code = _error_code(c, target)
            _must(code == "invalid_params", f"missing account: expected invalid_params, got {code}")
            code = _error_code(c, {**target, "account": "default", "force": "yes"})
            _must(code == "invalid_params", f"non-boolean force: expected invalid_params, got {code}")
            code = _error_code(
                c,
                {"workspace_id": created_workspace, "surface_id": str(uuid.uuid4()), "account": "default"},
            )
            _must(code == "not_found", f"unknown surface: expected not_found, got {code}")

            # A destructive method never falls back to whichever pane is focused.
            code = _error_code(c, {"workspace_id": created_workspace, "account": unknown})
            _must(code == "invalid_params", f"missing surface_id: expected invalid_params, got {code}")
            code = _error_code(c, {"account": unknown, "workspace_id": "garbage"})
            _must(code == "invalid_params", f"no surface_id, bad workspace_id: expected invalid_params, got {code}")
            code = _error_code(c, {"workspace_id": "garbage", "surface_id": surface_id, "account": unknown})
            _must(code == "not_found", f"malformed workspace_id: expected not_found, got {code}")
            code = _error_code(c, {"workspace_id": created_workspace, "surface_id": "garbage", "account": unknown})
            _must(code == "not_found", f"malformed surface_id: expected not_found, got {code}")

            _must(
                c.current_workspace() == baseline_workspace,
                f"{METHOD} refusals must not change the selected workspace",
            )
        finally:
            if created_workspace:
                try:
                    c.close_workspace(created_workspace)
                except Exception:
                    logging.exception("Failed to clean up workspace %s", created_workspace)

    print(f"PASS: {METHOD} is advertised and refuses non-Claude panes without moving focus")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
