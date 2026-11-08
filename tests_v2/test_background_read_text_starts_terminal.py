#!/usr/bin/env python3
"""Regression (#1472): surface.read_text must start a background terminal that was never shown."""

from __future__ import annotations

import logging
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


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


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        baseline_workspace = c.current_workspace()
        created_workspace = ""
        try:
            payload = c._call("workspace.create", {}) or {}
            created_workspace = str(payload.get("workspace_id") or "")
            _must(bool(created_workspace), f"workspace.create returned no workspace_id: {payload}")

            surfaces_payload = c._call("surface.list", {"workspace_id": created_workspace}) or {}
            initial_surface = _first_terminal_surface_id(surfaces_payload)
            split_payload = c._call(
                "surface.split",
                {
                    "workspace_id": created_workspace,
                    "surface_id": initial_surface,
                    "direction": "right",
                    "focus": False,
                },
            ) or {}
            split_surface = str(split_payload.get("surface_id") or "")
            _must(bool(split_surface), f"surface.split returned no surface_id: {split_payload}")

            # The first read of a never-shown terminal used to fail with
            # "Failed to read terminal text" because nothing started its surface.
            for surface_id in (initial_surface, split_surface):
                read_payload = c._call(
                    "surface.read_text",
                    {"workspace_id": created_workspace, "surface_id": surface_id},
                ) or {}
                _must(
                    str(read_payload.get("surface_id") or "") == surface_id,
                    f"surface.read_text returned unexpected payload: {read_payload}",
                )
                _must("text" in read_payload, f"surface.read_text returned no text: {read_payload}")

            _must(
                c.current_workspace() == baseline_workspace,
                "surface.read_text should start the background terminal without selecting its workspace",
            )
        finally:
            if created_workspace:
                try:
                    c.close_workspace(created_workspace)
                except Exception:
                    logging.exception("Failed to clean up workspace %s", created_workspace)

    print("PASS: surface.read_text starts a background terminal without focus")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
