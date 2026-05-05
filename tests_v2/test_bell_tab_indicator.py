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
from typing import List

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


def surface_id_for_index(client: cmux, index: int) -> str:
    surfaces = client.list_surfaces()
    for entry in surfaces:
        if entry[0] == index:
            return entry[1]
    raise RuntimeError(f"Surface index {index} not found")


def first_two_terminal_indices(client: cmux) -> tuple[int, int]:
    health = client.surface_health()
    terms = [h["index"] for h in health if h.get("type") == "terminal"]
    if len(terms) < 2:
        raise RuntimeError(f"Expected >=2 terminal surfaces, got {health}")
    return terms[0], terms[1]


def wait_for_bell(client: cmux, surface_id: str, present: bool, timeout: float = 2.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        bells = client.list_bell_surfaces()
        if (surface_id in bells) == present:
            return True
        time.sleep(0.05)
    return False


def main() -> int:
    try:
        with cmux() as client:
            # Make app focus deterministic for the visibility-suppression check.
            client.set_app_focus(True)

            # --- Scenario 1: bell on a non-visible workspace -> recorded.
            ws_a = client.new_workspace()
            ws_b = client.new_workspace()
            client.select_workspace(ws_a)
            time.sleep(0.5)

            ws_a_surfaces: List[tuple[int, str, bool]] = client.list_surfaces(workspace=ws_a)
            ws_b_surfaces: List[tuple[int, str, bool]] = client.list_surfaces(workspace=ws_b)
            if not ws_a_surfaces or not ws_b_surfaces:
                print(f"FAIL: Expected at least one surface per workspace; A={ws_a_surfaces} B={ws_b_surfaces}")
                return 1

            ws_b_surface_id = ws_b_surfaces[0][1]
            ws_a_focused_surface_id = ws_a_surfaces[0][1]

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
            time.sleep(0.3)
            client.new_split("right")
            time.sleep(0.3)
            ws_b_surfaces = client.list_surfaces(workspace=ws_b)
            if len(ws_b_surfaces) < 2:
                print(f"FAIL: Expected workspace B to have 2 surfaces after split; got {ws_b_surfaces}")
                return 1
            term1_idx, term2_idx = first_two_terminal_indices(client)
            ws_b_surface_focused = surface_id_for_index(client, term1_idx)
            ws_b_surface_other = surface_id_for_index(client, term2_idx)
            client.focus_surface(term1_idx)
            time.sleep(0.2)

            # Move back to A so neither surface in B is visible. Ring both.
            client.select_workspace(ws_a)
            time.sleep(0.3)
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
            client.focus_surface(term2_idx)
            if not wait_for_bell(client, ws_b_surface_other, present=False):
                print(f"FAIL: Bell did not clear after focus_surface on the bonsplit tab; bells={client.list_bell_surfaces()}")
                return 1

            # --- Scenario 5: closing a workspace clears all of its bells.
            # Move back to A, ring B's surface, close B, assert bell map is purged.
            client.select_workspace(ws_a)
            time.sleep(0.2)
            ws_b_surface_focused = client.list_surfaces(workspace=ws_b)[0][1]
            client.simulate_bell(ws_b_surface_focused, workspace=ws_b)
            if not wait_for_bell(client, ws_b_surface_focused, present=True):
                print("FAIL: Pre-condition - bell before workspace close not recorded")
                return 1
            client.close_workspace(ws_b)
            if not wait_for_bell(client, ws_b_surface_focused, present=False, timeout=3.0):
                print(f"FAIL: Closing workspace did not clear its bells; bells={client.list_bell_surfaces()}")
                return 1

            # Cleanup
            try:
                client.close_workspace(ws_a)
            except Exception:
                pass
            try:
                client.set_app_focus(None)
            except Exception:
                pass

            print("PASS: bell-features = title indicator records, suppresses, and clears as expected")
            return 0
    except (cmuxError, RuntimeError) as exc:
        print(f"FAIL: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
