#!/usr/bin/env python3
"""
Regression test:
1. Focusing a blank browser surface should focus the omnibar.
2. Focusing a pane that contains a blank browser should focus the omnibar.
3. If command palette is open, focusing that blank browser surface must not steal input.
4. Cmd+P switcher focusing an existing blank browser surface should focus the omnibar.
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


def command_palette_results(client: cmux, window_id: str, limit: int = 20) -> list[dict[str, Any]]:
    payload = v2_call(
        client,
        "debug.command_palette.results",
        {"window_id": window_id, "limit": limit},
        request_id="palette-results"
    )
    rows = payload.get("results")
    if isinstance(rows, list):
        return [row for row in rows if isinstance(row, dict)]
    return []


def command_palette_selected_index(client: cmux, window_id: str) -> int:
    payload = v2_call(
        client,
        "debug.command_palette.selection",
        {"window_id": window_id},
        request_id="palette-selection"
    )
    selected_index = payload.get("selected_index")
    if isinstance(selected_index, int):
        return max(0, selected_index)
    return 0


def move_command_palette_selection_to_index(client: cmux, window_id: str, target_index: int) -> bool:
    target = max(0, target_index)
    for _ in range(40):
        current = command_palette_selected_index(client, window_id)
        if current == target:
            return True
        if current < target:
            client.simulate_shortcut("down")
        else:
            client.simulate_shortcut("up")
        time.sleep(0.05)
    return False


def current_window_id(client: cmux) -> str:
    window_current = v2_call(client, "window.current", request_id="window-current")
    window_id = window_current.get("window_id")
    if not isinstance(window_id, str) or not window_id:
        raise cmuxError(f"Invalid window.current payload: {window_current}")
    return window_id


def main() -> int:
    client = cmux()
    workspace_ids: list[str] = []
    window_id: str | None = None

    try:
        client.connect()
        client.activate_app()

        # Scenario 1: focus_surface on a blank browser should focus omnibar.
        workspace_id = client.new_workspace()
        workspace_ids.append(workspace_id)
        client.select_workspace(workspace_id)
        time.sleep(0.4)
        window_id = current_window_id(client)
        if not set_command_palette_visible(client, window_id, False):
            raise cmuxError("Failed to ensure command palette is hidden for scenario 1")

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

        client.close_workspace(workspace_id)
        workspace_ids.remove(workspace_id)
        time.sleep(0.3)

        # Scenario 2: focusing a pane that contains a blank browser should focus omnibar.
        workspace_id = client.new_workspace()
        workspace_ids.append(workspace_id)
        client.select_workspace(workspace_id)
        time.sleep(0.4)
        window_id = current_window_id(client)
        if not set_command_palette_visible(client, window_id, False):
            raise cmuxError("Failed to ensure command palette is hidden for scenario 2")

        initial_surfaces = client.list_surfaces()
        left_terminal_id = next((surface_id for _, surface_id, _ in initial_surfaces), None)
        if not left_terminal_id:
            raise cmuxError("Missing initial terminal surface for split setup")

        split_browser_id = client.new_pane(direction="right", panel_type="browser")
        time.sleep(0.3)

        pane_rows = client.list_panes()
        left_pane: str | None = None
        browser_pane: str | None = None
        for _, pane_id, _, _ in pane_rows:
            pane_surface_ids = {surface_id for _, surface_id, _, _ in client.list_pane_surfaces(pane_id)}
            if left_terminal_id in pane_surface_ids:
                left_pane = pane_id
            if split_browser_id in pane_surface_ids:
                browser_pane = pane_id

        if not left_pane or not browser_pane:
            raise cmuxError("Failed to locate split panes for pane-focus scenario")

        client.focus_pane(left_pane)
        time.sleep(0.2)
        client.focus_pane(browser_pane)

        did_focus_split_browser = wait_for(
            lambda: bool(
                browser_address_bar_focus_state(
                    client,
                    surface_id=split_browser_id,
                    request_id="browser-focus-pane"
                ).get("focused")
            ),
            timeout_s=3.0,
            interval_s=0.1
        )
        if not did_focus_split_browser:
            raise cmuxError("Blank browser pane did not focus omnibar after focus_pane")

        client.close_workspace(workspace_id)
        workspace_ids.remove(workspace_id)
        time.sleep(0.3)

        # Scenario 3: command palette should keep input focus when switching to a blank browser surface.
        workspace_id = client.new_workspace()
        workspace_ids.append(workspace_id)
        client.select_workspace(workspace_id)
        time.sleep(0.4)
        window_id = current_window_id(client)
        if not set_command_palette_visible(client, window_id, False):
            raise cmuxError("Failed to reset command palette before scenario 3")

        blank_browser_id = client.new_surface(panel_type="browser")
        time.sleep(0.3)

        surfaces = client.list_surfaces()
        terminal_id = next((surface_id for _, surface_id, _ in surfaces if surface_id != blank_browser_id), None)
        if not terminal_id:
            raise cmuxError("Missing terminal surface for command palette scenario")

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

        client.close_workspace(workspace_id)
        workspace_ids.remove(workspace_id)
        time.sleep(0.3)

        # Scenario 4: Cmd+P switcher selecting an existing blank browser surface should focus omnibar.
        workspace_id = client.new_workspace()
        workspace_ids.append(workspace_id)
        client.select_workspace(workspace_id)
        time.sleep(0.4)
        window_id = current_window_id(client)
        if not set_command_palette_visible(client, window_id, False):
            raise cmuxError("Failed to reset command palette before scenario 4")

        switcher_browser_id = client.new_surface(panel_type="browser")
        time.sleep(0.3)

        switcher_surfaces = client.list_surfaces()
        switcher_terminal_id = next((surface_id for _, surface_id, _ in switcher_surfaces if surface_id != switcher_browser_id), None)
        if not switcher_terminal_id:
            raise cmuxError("Missing terminal surface for Cmd+P switcher scenario")

        client.focus_surface_by_panel(switcher_terminal_id)
        time.sleep(0.2)

        client.simulate_shortcut("cmd+p")
        if not wait_for(
            lambda: bool(
                v2_call(
                    client,
                    "debug.command_palette.visible",
                    {"window_id": window_id},
                    request_id="palette-visible-switcher-open"
                ).get("visible")
            ),
            timeout_s=2.0,
            interval_s=0.1
        ):
            raise cmuxError("Cmd+P did not open command palette switcher")

        client.simulate_type("new tab")
        time.sleep(0.2)

        target_command_id = f"switcher.surface.{workspace_id.lower()}.{switcher_browser_id.lower()}"
        switcher_results = command_palette_results(client, window_id, limit=50)
        target_index = next(
            (
                idx for idx, row in enumerate(switcher_results)
                if isinstance(row.get("command_id"), str) and row.get("command_id") == target_command_id
            ),
            None
        )
        if target_index is None:
            raise cmuxError(f"Cmd+P switcher did not list target surface command {target_command_id}")

        if not move_command_palette_selection_to_index(client, window_id, target_index):
            raise cmuxError(f"Failed to move Cmd+P selection to result index {target_index}")

        client.simulate_shortcut("enter")

        did_focus_switcher_target = wait_for(
            lambda: (
                not bool(
                    v2_call(
                        client,
                        "debug.command_palette.visible",
                        {"window_id": window_id},
                        request_id="palette-visible-switcher-after-enter"
                    ).get("visible")
                )
                and bool(
                    browser_address_bar_focus_state(
                        client,
                        surface_id=switcher_browser_id,
                        request_id="browser-focus-switcher"
                    ).get("focused")
                )
            ),
            timeout_s=3.0,
            interval_s=0.1
        )
        if not did_focus_switcher_target:
            raise cmuxError("Cmd+P switcher focus to blank browser did not focus omnibar")

        print("PASS: blank-browser focus paths (surface, pane, and Cmd+P switcher) drive omnibar, while command palette visibility blocks focus stealing")
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
        for workspace_id in list(workspace_ids):
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
