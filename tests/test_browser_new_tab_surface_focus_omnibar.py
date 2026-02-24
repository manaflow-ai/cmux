#!/usr/bin/env python3
"""
Regression test:
1. Focusing a blank browser surface should focus the omnibar.
2. If command palette is open, focusing that blank browser surface must not steal input.
"""

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
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise cmuxError(f"Invalid v2 JSON response for {method}: {raw}") from exc

    if not parsed.get("ok"):
        raise cmuxError(f"v2 {method} failed: {parsed.get('error')}")

    result = parsed.get("result")
    return result if isinstance(result, dict) else {}


def wait_for(predicate, timeout_s: float, interval_s: float = 0.1) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def browser_address_bar_focus_state(client: cmux, surface_id: str | None = None, request_id: str = "browser-focus") -> dict[str, Any]:
    params: dict[str, Any] = {}
    if surface_id:
        params["surface_id"] = surface_id
    return v2_call(client, "debug.browser.address_bar_focused", params, request_id=request_id)


def set_command_palette_visible(client: cmux, window_id: str, target_visible: bool) -> bool:
    for idx in range(5):
        state = v2_call(
            client,
            "debug.command_palette.visible",
            {"window_id": window_id},
            request_id=f"palette-visible-{idx}",
        )
        is_visible = bool(state.get("visible"))
        if is_visible == target_visible:
            return True
        v2_call(
            client,
            "debug.command_palette.toggle",
            {"window_id": window_id},
            request_id=f"palette-toggle-{idx}",
        )
        time.sleep(0.15)
    return False


def main() -> int:
    client = cmux()
    workspace_id: str | None = None
    window_id: str | None = None

    try:
        client.connect()
        client.activate_app()

        workspace_id = client.new_workspace()
        client.select_workspace(workspace_id)
        time.sleep(0.4)

        browser_id = client.new_surface(panel_type="browser")
        time.sleep(0.3)

        surfaces = client.list_surfaces()
        terminal_id = next((surface_id for _, surface_id, _ in surfaces if surface_id != browser_id), None)
        if not terminal_id:
            raise cmuxError("Missing terminal surface for focus setup")

        client.focus_surface_by_panel(terminal_id)
        time.sleep(0.2)

        # Primary behavior: focusing a blank browser tab should focus the omnibar.
        client.focus_surface_by_panel(browser_id)
        did_focus_address_bar = wait_for(
            lambda: bool(
                browser_address_bar_focus_state(
                    client,
                    surface_id=browser_id,
                    request_id="browser-focus-primary"
                ).get("focused")
            ),
            timeout_s=3.0,
            interval_s=0.1
        )
        if not did_focus_address_bar:
            raise cmuxError("Blank browser surface did not focus omnibar after focus_surface")

        # Edge behavior: command palette should keep input focus even when switching to a blank browser surface.
        blank_browser_id = client.new_surface(panel_type="browser")
        time.sleep(0.3)

        client.focus_surface_by_panel(terminal_id)
        wait_for(
            lambda: not bool(
                browser_address_bar_focus_state(
                    client,
                    request_id="browser-focus-cleared"
                ).get("focused")
            ),
            timeout_s=2.0,
            interval_s=0.1
        )

        window_current = v2_call(client, "window.current", request_id="window-current")
        window_id_value = window_current.get("window_id")
        if not isinstance(window_id_value, str) or not window_id_value:
            raise cmuxError(f"Invalid window.current payload: {window_current}")
        window_id = window_id_value

        if not set_command_palette_visible(client, window_id, True):
            raise cmuxError("Failed to open command palette")

        client.focus_surface_by_panel(blank_browser_id)
        time.sleep(0.2)

        palette_visible_after_focus = bool(
            v2_call(
                client,
                "debug.command_palette.visible",
                {"window_id": window_id},
                request_id="palette-visible-after-focus"
            ).get("visible")
        )
        if not palette_visible_after_focus:
            raise cmuxError("Command palette closed unexpectedly after focus_surface")

        blank_focus_state = browser_address_bar_focus_state(
            client,
            surface_id=blank_browser_id,
            request_id="browser-focus-palette"
        )
        if bool(blank_focus_state.get("focused")):
            raise cmuxError("Blank browser tab stole omnibar focus while command palette was visible")

        print("PASS: blank-browser surface focus drives omnibar, and command palette visibility blocks focus stealing")
        return 0

    except cmuxError as exc:
        print(f"FAIL: {exc}")
        return 1

    finally:
        if window_id:
            try:
                _ = set_command_palette_visible(client, window_id, False)
            except Exception:
                pass
        if workspace_id:
            try:
                client.close_workspace(workspace_id)
            except Exception:
                pass
        try:
            client.close()
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
