#!/usr/bin/env python3
"""
Regression test: after creating multiple splits, creating a new terminal surface (nested tab)
must become focused and process input/output immediately, without requiring a pane switch
or app focus toggle.

This targets an intermittent freeze where the newly-created tab would display stale initial
output (e.g. "Last login") and ignore input until focus changed away and back.

We avoid screenshots here because some capture paths can indirectly force a redraw, masking
the bug. Instead, we:
  1) Ensure the new surface becomes first responder.
  2) Type `echo <TOKEN>` and assert the token appears in the terminal text readout.
"""

import os
import sys
import time
import uuid
import json
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmuxterm-debug.sock")

def _wait_for(pred, timeout_s: float, step_s: float = 0.05) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if pred():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


def _wait_for_terminal_focus(c: cmux, panel_id: str, timeout_s: float = 6.0) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if c.is_terminal_focused(panel_id):
            return
        time.sleep(0.05)

    dbg: dict = {"panel_id": panel_id}
    try:
        dbg["identify"] = c.identify()
    except Exception as e:
        dbg["identify_error"] = repr(e)
    try:
        dbg["workspaces"] = c.list_workspaces()
    except Exception as e:
        dbg["workspaces_error"] = repr(e)
    try:
        dbg["current_workspace"] = c.current_workspace()
    except Exception as e:
        dbg["current_workspace_error"] = repr(e)
    try:
        dbg["panes"] = c.list_panes()
    except Exception as e:
        dbg["panes_error"] = repr(e)
    try:
        panes = c.list_panes()
        per_pane = {}
        for _idx, pid, _n, _focused in panes:
            try:
                per_pane[pid] = c.list_pane_surfaces(pid)
            except Exception as e:
                per_pane[pid] = {"error": repr(e)}
        dbg["pane_surfaces"] = per_pane
    except Exception as e:
        dbg["pane_surfaces_error"] = repr(e)
    try:
        dbg["surface_health"] = c.surface_health()
    except Exception as e:
        dbg["surface_health_error"] = repr(e)
    try:
        dbg["render_stats"] = c.render_stats(panel_id)
    except Exception as e:
        dbg["render_stats_error"] = repr(e)
    try:
        dbg["layout_debug"] = c.layout_debug()
    except Exception as e:
        dbg["layout_debug_error"] = repr(e)

    raise cmuxError(
        "Timed out waiting for terminal focus: "
        f"{panel_id}\nDEBUG:\n{json.dumps(dbg, indent=2, sort_keys=True)}"
    )


def _wait_for_text(c: cmux, panel_id: str, needle: str, timeout_s: float = 2.5) -> None:
    start = time.time()
    last = ""
    while time.time() - start < timeout_s:
        last = c.read_terminal_text(panel_id)
        if needle in last:
            return
        time.sleep(0.05)
    tail = last[-600:].replace("\r", "\\r")
    raise cmuxError(f"Timed out waiting for token in terminal text: {needle}\nLast tail:\n{tail}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        time.sleep(0.2)

        c.new_workspace()
        time.sleep(0.35)

        # Create a multi-pane layout to exercise bonsplit/SwiftUI focus races.
        for _ in range(4):
            c.new_split("right")
            time.sleep(0.25)

        panes = c.list_panes()
        if len(panes) < 2:
            raise cmuxError(f"expected multiple panes, got: {panes}")

        mid = len(panes) // 2
        c.focus_pane(mid)
        time.sleep(0.25)

        # Add some extra nested tabs to increase churn and make the race more likely.
        for pane_idx in range(min(4, len(panes))):
            c.focus_pane(pane_idx)
            time.sleep(0.15)
            for _ in range(2):
                _ = c.new_surface(panel_type="terminal")
                time.sleep(0.25)

        c.focus_pane(mid)
        time.sleep(0.25)

        # Repeat: create new surface -> it must focus and accept input immediately.
        for i in range(6):
            new_id = c.new_surface(panel_type="terminal")
            time.sleep(0.35)

            _wait_for_terminal_focus(c, new_id, timeout_s=6.0)

            baseline_present = int(c.render_stats(new_id).get("presentCount", 0) or 0)

            token = f"CMUX_NEW_TAB_OK_{i}_{uuid.uuid4().hex[:10]}"
            tmp = f"/tmp/cmux_new_tab_{token}.txt"
            cmd = f"echo {token} > {tmp}"
            c.simulate_type(cmd)

            # Regression: typed text must show up before Enter.
            _wait_for_text(c, new_id, cmd, timeout_s=2.0)

            # And the view must actually present a new frame while typing.
            def did_present() -> bool:
                stats = c.render_stats(new_id)
                return int(stats.get("presentCount", 0) or 0) > baseline_present

            _wait_for(lambda: did_present(), timeout_s=2.0)

            # Use insertText for newline instead of a synthetic keyDown "enter" event.
            # This avoids flakiness when the key window/responder chain is in flux.
            c.simulate_type("\n")
            start = time.time()
            while time.time() - start < 3.0:
                try:
                    if Path(tmp).read_text().strip() == token:
                        break
                except Exception:
                    pass
                time.sleep(0.05)
            else:
                raise cmuxError(f"Timed out waiting for tmp file write: {tmp}")

        print("PASS: new tab is interactive after many splits")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
