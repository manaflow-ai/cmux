#!/usr/bin/env python3
"""
Regression test for issue #464:

Scenario:
  - One workspace with exactly two panes:
      left: terminal
      right: browser (cnn.com)
  - Focus the terminal and press Cmd+W.

Expected:
  - Terminal closes.
  - Browser remains and fills the workspace (no stale terminal content/pane).

This test uses debug socket commands (`simulate_shortcut`, `layout_debug`,
`surface_health`, `drag_hit_chain`).
Run against a Debug app socket (typically with CMUX_SOCKET_MODE=allowAll).
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _wait_until(predicate, timeout_s: float = 5.0, interval_s: float = 0.05) -> bool:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def _wait_url_contains(client: cmux, panel_id: str, needle: str, timeout_s: float = 20.0) -> None:
    def _matches() -> bool:
        response = client._send_command(f"get_url {panel_id}").strip().lower()
        return not response.startswith("error") and needle.lower() in response

    if not _wait_until(_matches, timeout_s=timeout_s, interval_s=0.1):
        current = client._send_command(f"get_url {panel_id}")
        raise cmuxError(f"Timed out waiting for browser URL containing '{needle}', got: {current}")


def _capture_screenshot(client: cmux, label: str) -> str:
    response = client._send_command(f"screenshot {label}").strip()
    if not response.startswith("OK "):
        return f"<unavailable: {response}>"
    parts = response.split(" ", 2)
    if len(parts) < 3:
        return f"<unavailable: malformed response {response}>"
    return parts[2]


def _focused_terminal_ready(client: cmux, panel_id: str) -> bool:
    try:
        return client.is_terminal_focused(panel_id)
    except Exception:
        return False


def _drag_hit_chain(client: cmux, nx: float, ny: float) -> str:
    return client._send_command(f"drag_hit_chain {nx:.3f} {ny:.3f}").strip()


def _top_hit_view_class(hit_chain: str) -> str:
    if not hit_chain or hit_chain == "none" or hit_chain.startswith("ERROR"):
        return hit_chain
    first = hit_chain.split("->", 1)[0]
    return first.split("@", 1)[0]


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        # Quick sanity check: fail early with actionable info if socket is not in allow mode.
        ping_ok = client.ping()
        if not ping_ok:
            raise cmuxError(
                f"Socket ping failed on {SOCKET_PATH}. "
                "Launch Debug app with CMUX_SOCKET_MODE=allowAll for this test."
            )

        workspace_id = client.new_workspace()
        try:
            client.select_workspace(workspace_id)
            time.sleep(0.25)
            client.activate_app()
            time.sleep(0.15)

            browser_id = client.new_pane(
                direction="right",
                panel_type="browser",
                url="https://cnn.com",
            )
            _wait_url_contains(client, browser_id, "cnn", timeout_s=20.0)

            health_before = client.surface_health()
            terminal_rows = [row for row in health_before if row.get("type") == "terminal"]
            browser_rows = [row for row in health_before if row.get("type") == "browser"]
            if len(terminal_rows) != 1 or len(browser_rows) != 1:
                raise cmuxError(
                    f"Expected exactly one terminal and one browser before close; "
                    f"health={health_before}"
                )

            terminal_id = terminal_rows[0]["id"]
            client.focus_surface(terminal_id)
            if not _wait_until(lambda: _focused_terminal_ready(client, terminal_id), timeout_s=4.0):
                raise cmuxError(f"Terminal did not become first responder before Cmd+W: {terminal_id}")

            before_surfaces = client.list_surfaces()
            before_panes = client.list_panes()
            before_layout = client.layout_debug()
            before_shot = _capture_screenshot(client, "issue464_cmdw_before")

            client.simulate_shortcut("cmd+w")

            # Give close animations/routing time to settle.
            _wait_until(lambda: len(client.list_surfaces()) == 1, timeout_s=4.0, interval_s=0.05)
            time.sleep(0.25)

            after_surfaces = client.list_surfaces()
            after_panes = client.list_panes()
            after_health = client.surface_health()
            after_layout = client.layout_debug()
            after_shot = _capture_screenshot(client, "issue464_cmdw_after")
            after_hit_chain = _drag_hit_chain(client, 0.42, 0.50)
            after_top_hit_class = _top_hit_view_class(after_hit_chain)

            failures: list[str] = []

            if len(after_surfaces) != 1:
                failures.append(f"Expected 1 surface after Cmd+W, got {len(after_surfaces)}: {after_surfaces}")

            if len(after_panes) != 1:
                failures.append(f"Expected 1 pane after Cmd+W, got {len(after_panes)}: {after_panes}")

            visible_terminals = [
                row for row in after_health
                if row.get("type") == "terminal" and row.get("in_window") is True
            ]
            if visible_terminals:
                failures.append(f"Terminal still visible in_window after Cmd+W: {visible_terminals}")

            remaining_browsers = [row for row in after_health if row.get("type") == "browser"]
            if len(remaining_browsers) != 1:
                failures.append(f"Expected one remaining browser in health, got: {remaining_browsers}")
            else:
                rb = remaining_browsers[0]
                if str(rb.get("id", "")).lower() != browser_id.lower():
                    failures.append(
                        f"Remaining browser id mismatch: expected {browser_id}, got {rb.get('id')}"
                    )
                if rb.get("in_window") is not True:
                    failures.append(f"Remaining browser not in window: {rb}")

            selected_panels = after_layout.get("selectedPanels") or []
            if len(selected_panels) != 1:
                failures.append(f"Expected one selected panel after close, got {selected_panels}")
            else:
                selected_id = str(selected_panels[0].get("panelId", "")).lower()
                if selected_id != browser_id.lower():
                    failures.append(
                        f"Selected panel mismatch after close: expected browser {browser_id}, got {selected_id}"
                    )

            if after_top_hit_class == "GhosttyNSView":
                failures.append(
                    "Stale terminal overlay still hit-testable after close "
                    f"(top_hit={after_top_hit_class}, chain={after_hit_chain})"
                )

            if failures:
                details = [
                    "Cmd+W close regression reproduced (issue #464).",
                    f"workspace={workspace_id}",
                    f"browser={browser_id}",
                    f"terminal={terminal_id}",
                    f"before_screenshot={before_shot}",
                    f"after_screenshot={after_shot}",
                    f"before_surfaces={before_surfaces}",
                    f"before_panes={before_panes}",
                    f"before_layout={before_layout}",
                    f"after_surfaces={after_surfaces}",
                    f"after_panes={after_panes}",
                    f"after_health={after_health}",
                    f"after_layout={after_layout}",
                    f"after_hit_chain={after_hit_chain}",
                    f"after_top_hit_class={after_top_hit_class}",
                ]
                details.extend(f"failure={msg}" for msg in failures)
                raise cmuxError("\n".join(details))

            print(
                "PASS: Cmd+W closed terminal in terminal+browser split and left browser as sole visible pane."
            )
            print(f"before_screenshot={before_shot}")
            print(f"after_screenshot={after_shot}")
            return 0
        finally:
            try:
                client.close_workspace(workspace_id)
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
