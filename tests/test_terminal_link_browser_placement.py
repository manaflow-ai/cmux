#!/usr/bin/env python3
"""
Regression test for terminal link browser placement.

The DEBUG socket command exercises the same Workspace placement path as a
terminal hyperlink click, without relying on terminal text hit-testing.
"""

from __future__ import annotations

import json
import os
import sys
import time
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


def v2_call(client: cmux, method: str, params: dict[str, Any] | None = None, request_id: str = "1") -> dict[str, Any]:
    payload = {
        "id": request_id,
        "method": method,
        "params": params or {},
    }
    raw = client._send_command(json.dumps(payload))
    parsed = json.loads(raw)
    if not parsed.get("ok"):
        raise cmuxError(f"v2 {method} failed: {parsed.get('error')}")
    result = parsed.get("result")
    return result if isinstance(result, dict) else {}


def pane_for_surface(client: cmux, surface_id: str) -> str:
    for _, pane_id, _, _ in client.list_panes():
        surface_ids = {surface for _, surface, _, _ in client.list_pane_surfaces(pane_id)}
        if surface_id in surface_ids:
            return pane_id
    raise cmuxError(f"surface {surface_id} was not found in any pane")


def surface_ids_in_pane(client: cmux, pane_id: str) -> set[str]:
    return {surface for _, surface, _, _ in client.list_pane_surfaces(pane_id)}


def test_same_pane_terminal_link_placement(client: cmux) -> tuple[bool, str]:
    workspace_id = client.new_workspace()
    client.select_workspace(workspace_id)
    time.sleep(0.4)

    try:
        initial_surfaces = client.list_surfaces()
        source_surface_id = next((surface for _, surface, _ in initial_surfaces), None)
        if not source_surface_id:
            return False, "Missing initial terminal surface"

        source_pane_id = pane_for_surface(client, source_surface_id)
        right_browser_id = client.new_pane(direction="right", panel_type="browser", url="https://example.com")
        time.sleep(0.5)
        right_pane_id = pane_for_surface(client, right_browser_id)

        if right_pane_id == source_pane_id:
            return False, "Setup did not create a distinct right browser pane"

        panes_before = client.list_panes()
        source_surfaces_before = surface_ids_in_pane(client, source_pane_id)
        right_surfaces_before = surface_ids_in_pane(client, right_pane_id)

        placement_state = v2_call(
            client,
            "debug.browser.terminal_link_placement",
            {"placement": "samePane"},
            request_id="set-placement",
        )
        if placement_state.get("placement") != "samePane":
            return False, f"Expected samePane setting, got {placement_state}"

        client.focus_pane(source_pane_id)
        opened = v2_call(
            client,
            "debug.browser.open_terminal_link",
            {
                "workspace_id": workspace_id,
                "surface_id": source_surface_id,
                "url": "https://example.org/same-pane",
                "focus": True,
            },
            request_id="open-terminal-link",
        )

        target_surface_id = opened.get("surface_id")
        if not isinstance(target_surface_id, str) or not target_surface_id:
            return False, f"Missing created browser surface in response: {opened}"

        panes_after = client.list_panes()
        source_surfaces_after = surface_ids_in_pane(client, source_pane_id)
        right_surfaces_after = surface_ids_in_pane(client, right_pane_id)

        if len(panes_after) != len(panes_before):
            return False, f"samePane should not create a split: before={panes_before} after={panes_after}"
        if opened.get("placement") != "samePane":
            return False, f"Expected response placement samePane, got {opened}"
        if opened.get("created_split"):
            return False, f"samePane reported created_split=true: {opened}"
        if opened.get("target_pane_id") != source_pane_id:
            return False, f"Expected target pane {source_pane_id}, got {opened.get('target_pane_id')}"
        if target_surface_id not in source_surfaces_after - source_surfaces_before:
            return False, (
                "Created browser surface was not added to the source pane: "
                f"target={target_surface_id} before={source_surfaces_before} after={source_surfaces_after}"
            )
        if right_surfaces_after != right_surfaces_before:
            return False, (
                "samePane should not reuse the existing right browser pane: "
                f"before={right_surfaces_before} after={right_surfaces_after}"
            )

        return True, "samePane opened the terminal link as a browser surface in the source pane"
    finally:
        try:
            v2_call(client, "debug.browser.terminal_link_placement", {"reset": True}, request_id="reset-placement")
        except Exception:
            pass
        try:
            client.close_workspace(workspace_id)
        except Exception:
            pass


def run_tests() -> int:
    probe = cmux()
    socket_path = probe.socket_path
    if not os.path.exists(socket_path):
        print(f"Error: Socket not found at {socket_path}")
        print("Please make sure cmux is running.")
        return 1

    tests = [
        ("terminal link same-pane browser placement", test_same_pane_terminal_link_placement),
    ]

    passed = 0
    failed = 0

    try:
        with cmux(socket_path=socket_path) as client:
            client.activate_app()
            for name, fn in tests:
                print(f"  Running: {name} ... ", end="", flush=True)
                try:
                    ok, msg = fn(client)
                except Exception as exc:
                    ok, msg = False, str(exc)
                print(f"{'PASS' if ok else 'FAIL'}: {msg}")
                if ok:
                    passed += 1
                else:
                    failed += 1
    except cmuxError as exc:
        print(f"Error: {exc}")
        return 1

    print(f"Results: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(run_tests())
