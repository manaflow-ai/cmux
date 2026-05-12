#!/usr/bin/env python3
"""
E2E: ghostty `bell-features = title` indicator wiring.

Asserts:
  1. Bell rings on a surface in a non-visible workspace -> recorded for that
     surface (drives the sidebar workspace bell badge + bonsplit pane tab badge
     via the existing showsNotificationBadge reconciliation).
  2. Bell rings on the currently-focused surface while the app is active ->
     suppressed (no badge needed, the user has eyes on it).
  3. Selecting the workspace clears the bell for the focused surface, but
     leaves bells in non-focused surfaces (other bonsplit tabs) intact until
     the user switches to them.
  4. Direct interaction (focus_surface) on a bonsplit tab clears its bell.
  5. Closing a workspace clears all bells in that workspace.

Uses the bell.simulate socket command which routes through the same
GhosttyApp.recordBellForTitleIndicator path as a real ghostty BEL action,
so the suppression check and store mutation under test are the production
code path, not a test-only shortcut.
"""

import os
import sys
import time
from typing import List, Optional, Tuple, Type

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


def surface_id_for_index(client: cmux, index: int, workspace: Optional[str] = None) -> str:
    surfaces = client.list_surfaces(workspace=workspace) if workspace else client.list_surfaces()
    for entry in surfaces:
        if entry[0] == index:
            return entry[1]
    raise RuntimeError(f"Surface index {index} not found in workspace={workspace}")


def focused_surface_id(client: cmux, workspace: Optional[str] = None) -> str:
    """Return the focused surface id within `workspace` (or current if None).

    Uses the third tuple element from list_surfaces (focused flag) rather
    than assuming index 0 is focused — surface ordering is not guaranteed
    to match focus order.
    """
    surfaces = client.list_surfaces(workspace=workspace) if workspace else client.list_surfaces()
    for index, sid, focused in surfaces:
        if focused:
            return sid
    raise RuntimeError(f"No focused surface found in workspace={workspace}; surfaces={surfaces}")


def first_two_terminal_indices(client: cmux, workspace: Optional[str] = None) -> tuple[int, int]:
    health = client.surface_health(workspace=workspace) if workspace else client.surface_health()
    terms = [h["index"] for h in health if h.get("type") == "terminal"]
    if len(terms) < 2:
        raise RuntimeError(f"Expected >=2 terminal surfaces in workspace={workspace}, got {health}")
    return terms[0], terms[1]


def wait_for_bell(client: cmux, surface_id: str, present: bool, timeout: float = 2.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        bells = client.list_bell_surfaces()
        if (surface_id in bells) == present:
            return True
        time.sleep(0.05)
    return False


def wait_until(
    predicate,
    timeout: float = 2.0,
    interval: float = 0.05,
    allowed_exceptions: Tuple[Type[BaseException], ...] = (cmuxError, RuntimeError),
) -> bool:
    """Poll `predicate()` until it returns truthy or `timeout` seconds elapse.

    Used in place of fixed sleeps for async UI transitions
    (workspace selection, split creation, focus changes) so the test
    advances as soon as cmux's state has settled rather than after a
    pessimistic delay. Avoids the flakiness CI runners would see on
    slower hardware where 0.2-0.5s waits are not always enough.

    Only `allowed_exceptions` are swallowed (defaults cover the transient
    socket/lookup errors that happen mid-transition); anything else
    propagates so genuine test defects fail fast instead of disguising
    themselves as opaque timeouts.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if predicate():
                return True
        except allowed_exceptions:
            pass
        time.sleep(interval)
    return False


def wait_current_workspace(client: cmux, workspace_id: str, timeout: float = 2.0) -> bool:
    return wait_until(lambda: client.current_workspace() == workspace_id, timeout=timeout)


def wait_surface_count(client: cmux, workspace_id: str, count: int, timeout: float = 2.0) -> bool:
    return wait_until(
        lambda: len(client.list_surfaces(workspace=workspace_id)) >= count, timeout=timeout
    )


def wait_focused_surface(client: cmux, workspace_id: str, surface_id: str, timeout: float = 2.0) -> bool:
    def check() -> bool:
        for _, sid, focused in client.list_surfaces(workspace=workspace_id):
            if sid == surface_id and focused:
                return True
        return False
    return wait_until(check, timeout=timeout)


def main() -> int:
    rc = 1
    ws_a: Optional[str] = None
    ws_b: Optional[str] = None
    client: Optional[cmux] = None
    try:
        client = cmux().__enter__()
        try:
            # Make app focus deterministic for the visibility-suppression check.
            client.set_app_focus(True)

            # --- Scenario 1: bell on a non-visible workspace -> recorded.
            ws_a = client.new_workspace()
            ws_b = client.new_workspace()
            client.select_workspace(ws_a)
            if not wait_current_workspace(client, ws_a):
                print(f"FAIL: Workspace A not selected; current={client.current_workspace()}")
                return 1

            ws_a_surfaces: List[tuple[int, str, bool]] = client.list_surfaces(workspace=ws_a)
            ws_b_surfaces: List[tuple[int, str, bool]] = client.list_surfaces(workspace=ws_b)
            if not ws_a_surfaces or not ws_b_surfaces:
                print(f"FAIL: Expected at least one surface per workspace; A={ws_a_surfaces} B={ws_b_surfaces}")
                return 1

            ws_b_surface_id = ws_b_surfaces[0][1]
            ws_a_focused_surface_id = focused_surface_id(client, workspace=ws_a)

            client.simulate_bell(ws_b_surface_id, workspace=ws_b)
            if not wait_for_bell(client, ws_b_surface_id, present=True):
                print(f"FAIL: Bell on workspace B's surface ({ws_b_surface_id}) was not recorded; bells={client.list_bell_surfaces()}")
                return 1

            # --- Scenario 2: bell on the currently-focused surface is suppressed.
            res = client.simulate_bell(ws_a_focused_surface_id, workspace=ws_a)
            if not res.get("suppressed"):
                print(f"FAIL: Expected bell on focused visible surface to be suppressed; got {res}")
                return 1
            if ws_a_focused_surface_id in client.list_bell_surfaces():
                print(f"FAIL: Bell on focused visible surface should not be recorded; bells={client.list_bell_surfaces()}")
                return 1

            # --- Scenario 3: selecting a workspace with a ringing surface
            # clears that surface's bell; other surfaces in the same workspace
            # keep theirs. Set up by adding a second surface to B and ringing
            # both before we switch.
            client.select_workspace(ws_b)
            if not wait_current_workspace(client, ws_b):
                print(f"FAIL: Workspace B not selected; current={client.current_workspace()}")
                return 1
            client.new_split("right")
            if not wait_surface_count(client, ws_b, count=2):
                print(f"FAIL: Workspace B did not gain a second surface; got {client.list_surfaces(workspace=ws_b)}")
                return 1
            ws_b_surfaces = client.list_surfaces(workspace=ws_b)
            term1_idx, term2_idx = first_two_terminal_indices(client, workspace=ws_b)
            ws_b_surface_focused = surface_id_for_index(client, term1_idx, workspace=ws_b)
            ws_b_surface_other = surface_id_for_index(client, term2_idx, workspace=ws_b)
            client.focus_surface(ws_b_surface_focused)
            if not wait_focused_surface(client, ws_b, ws_b_surface_focused):
                print(f"FAIL: Surface {ws_b_surface_focused} did not become focused in B")
                return 1

            # Move back to A so neither surface in B is visible. Ring both.
            client.select_workspace(ws_a)
            if not wait_current_workspace(client, ws_a):
                print(f"FAIL: Could not switch back to workspace A; current={client.current_workspace()}")
                return 1
            client.simulate_bell(ws_b_surface_focused, workspace=ws_b)
            client.simulate_bell(ws_b_surface_other, workspace=ws_b)
            if not wait_for_bell(client, ws_b_surface_focused, present=True):
                print("FAIL: Pre-condition - bell on B's focused surface not recorded")
                return 1
            if not wait_for_bell(client, ws_b_surface_other, present=True):
                print("FAIL: Pre-condition - bell on B's other surface not recorded")
                return 1

            # Now select B - the focused surface bell should clear, the other should remain.
            client.select_workspace(ws_b)
            if not wait_for_bell(client, ws_b_surface_focused, present=False):
                print(f"FAIL: Focused surface bell should clear on workspace selection; bells={client.list_bell_surfaces()}")
                return 1
            if not wait_for_bell(client, ws_b_surface_other, present=True):
                print(f"FAIL: Non-focused surface bell should persist on workspace selection; bells={client.list_bell_surfaces()}")
                return 1

            # --- Scenario 4: direct focus on the other surface clears its bell.
            client.focus_surface(ws_b_surface_other)
            if not wait_for_bell(client, ws_b_surface_other, present=False):
                print(f"FAIL: Bell did not clear after focus_surface on the bonsplit tab; bells={client.list_bell_surfaces()}")
                return 1

            # --- Scenario 5: closing a workspace clears all of its bells.
            # Move back to A, ring B's surface, close B, assert bell map is purged.
            client.select_workspace(ws_a)
            if not wait_current_workspace(client, ws_a):
                print(f"FAIL: Could not switch back to workspace A before close; current={client.current_workspace()}")
                return 1
            ws_b_surface_focused = client.list_surfaces(workspace=ws_b)[0][1]
            client.simulate_bell(ws_b_surface_focused, workspace=ws_b)
            if not wait_for_bell(client, ws_b_surface_focused, present=True):
                print("FAIL: Pre-condition - bell before workspace close not recorded")
                return 1
            client.close_workspace(ws_b)
            ws_b = None
            if not wait_for_bell(client, ws_b_surface_focused, present=False, timeout=3.0):
                print(f"FAIL: Closing workspace did not clear its bells; bells={client.list_bell_surfaces()}")
                return 1

            print("PASS: bell-features = title indicator records, suppresses, and clears as expected")
            rc = 0
            return 0
        finally:
            # Cleanup runs on every exit path so a mid-scenario failure does
            # not leak workspaces or app-focus override into subsequent runs.
            if client is not None:
                if ws_b is not None:
                    try:
                        client.close_workspace(ws_b)
                    except Exception:
                        pass
                if ws_a is not None:
                    try:
                        client.close_workspace(ws_a)
                    except Exception:
                        pass
                try:
                    client.set_app_focus(None)
                except Exception:
                    pass
                try:
                    client.__exit__(None, None, None)
                except Exception:
                    pass
    except (cmuxError, RuntimeError) as exc:
        print(f"FAIL: {exc}")
        return 1
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
