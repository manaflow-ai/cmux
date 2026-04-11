"""Focus-resize: focused pane gets ~75% of parent split space.

When focus-resize is enabled, switching focus between split panes
should animate the dividers so the focused pane occupies the
configured ratio (default 75%) of each ancestor split's space.
"""

from __future__ import annotations

import os
import subprocess
import time

from cmux import cmux, cmuxError
from pane_resize_test_support import (
    layout_panes,
    must,
    pane_extent,
    wait_for,
    wait_for_surface_command_roundtrip,
    workspace_panes,
    focused_pane_id,
)


BUNDLE_ID = os.environ.get("CMUX_BUNDLE_ID", "com.cmuxterm.app.debug")
# Use CMUX_SOCKET env to target a tagged socket (e.g., /tmp/cmux-debug-<tag>.sock).
# No untagged fallbacks — this test writes UserDefaults and must not hit the wrong instance.
DEFAULT_SOCKET_PATHS = [
    os.environ.get("CMUX_SOCKET", ""),
]
DEFAULT_SOCKET_PATHS = [p for p in DEFAULT_SOCKET_PATHS if p]

ENABLED_KEY = "focusResize.enabled"
RATIO_KEY = "focusResize.ratio"


def _defaults_write(key: str, value_type: str, value: str) -> None:
    """Write a single key to the app's UserDefaults via the ``defaults`` CLI."""
    subprocess.run(
        ["defaults", "write", BUNDLE_ID, key, f"-{value_type}", value],
        check=True,
        capture_output=True,
    )


def _defaults_delete(key: str) -> None:
    """Delete a single key from the app's UserDefaults. No-op if absent."""
    subprocess.run(
        ["defaults", "delete", BUNDLE_ID, key],
        check=False,
        capture_output=True,
    )


# Saved prior values for restore on cleanup (None = key was originally absent)
PREV_DEFAULTS: dict[str, str | None] = {}


def _defaults_read(key: str) -> str | None:
    """Read a single key from the app's defaults domain. Returns None if absent."""
    proc = subprocess.run(
        ["defaults", "read", BUNDLE_ID, key],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout.strip()


def _enable_focus_resize(ratio: float = 0.75) -> None:
    """Save existing UserDefaults values, then enable focus-resize with the given ratio."""
    PREV_DEFAULTS[ENABLED_KEY] = _defaults_read(ENABLED_KEY)
    PREV_DEFAULTS[RATIO_KEY] = _defaults_read(RATIO_KEY)
    _defaults_write(ENABLED_KEY, "bool", "true")
    _defaults_write(RATIO_KEY, "float", str(ratio))


def _disable_focus_resize() -> None:
    """Restore previous UserDefaults values, or delete keys if originally absent."""
    for key in (ENABLED_KEY, RATIO_KEY):
        prev = PREV_DEFAULTS.get(key)
        if prev is None:
            _defaults_delete(key)
        else:
            # `defaults read` returns "1"/"0" for bools, floats as strings
            _defaults_write(key, "string", prev)
    PREV_DEFAULTS.clear()


def _pane_ratio(client: cmux, pane_id: str, other_pane_id: str, axis: str) -> float:
    """Compute the ratio of pane's extent vs total of pane + other_pane along axis."""
    pane_val = pane_extent(client, pane_id, axis)
    other_val = pane_extent(client, other_pane_id, axis)
    total = pane_val + other_val
    if total <= 0:
        return 0.0
    return pane_val / total


def _wait_for_ratio(
    client: cmux, pane_id: str, other_pane_id: str, axis: str,
    min_ratio: float = 0.65, max_ratio: float = 0.85, timeout_s: float = 5.0,
) -> float:
    """Poll until the pane's ratio is within the expected range. Returns the final ratio."""
    deadline = time.time() + timeout_s
    ratio = 0.0
    while time.time() < deadline:
        ratio = _pane_ratio(client, pane_id, other_pane_id, axis)
        if min_ratio < ratio < max_ratio:
            return ratio
        time.sleep(0.1)
    return ratio


def _run_once(socket_path: str) -> int:
    """Run the full focus-resize test suite against a single cmux socket."""
    workspace_id = ""
    try:
        # Note: defaults write from outside the process may not propagate to the
        # app's in-memory UserDefaults reliably. If this test fails with 50/50
        # ratios, enable "Resize Focused Pane" manually in Settings before running.
        _enable_focus_resize(0.75)
        time.sleep(2.0)

        with cmux(socket_path) as client:
            # --- Setup: create workspace with a horizontal split (A | B) ---
            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)
            surfaces = client.list_surfaces(workspace_id)
            must(bool(surfaces), "workspace should have at least one surface")
            surface_a = surfaces[0][1]

            wait_for_surface_command_roundtrip(client, workspace_id, surface_a)

            surface_b = client.new_split("right")
            wait_for(
                lambda: len(workspace_panes(client, workspace_id)) >= 2,
                timeout_s=4.0,
            )
            time.sleep(0.5)

            panes = workspace_panes(client, workspace_id)
            must(len(panes) >= 2, f"expected 2 panes, got {len(panes)}")

            # Identify pane IDs — after split, B is auto-focused
            pane_b_id = focused_pane_id(client, workspace_id)
            pane_a_id = next(pid for pid, _, _ in panes if pid != pane_b_id)

            # Focus A first to establish a baseline, so the next focus_surface(B)
            # is a real focus change that triggers didFocusPane.
            client.focus_surface(surface_a)
            time.sleep(0.5)

            # --- Test 1: Focus pane B, verify it gets ~75% width ---
            client.focus_surface(surface_b)
            b_ratio = _wait_for_ratio(client, pane_b_id, pane_a_id, "width")
            must(
                0.65 < b_ratio < 0.85,
                f"Test 1 FAIL: focused pane B should be ~75% width, got {b_ratio:.2%} "
                f"(B={pane_extent(client, pane_b_id, 'width'):.0f}, "
                f"A={pane_extent(client, pane_a_id, 'width'):.0f})",
            )
            print(f"  Test 1 PASS: pane B is {b_ratio:.1%} of width after focus")

            # --- Test 2: Focus pane A, verify it gets ~75% width ---
            client.focus_surface(surface_a)
            a_ratio = _wait_for_ratio(client, pane_a_id, pane_b_id, "width")
            must(
                0.65 < a_ratio < 0.85,
                f"Test 2 FAIL: focused pane A should be ~75% width, got {a_ratio:.2%} "
                f"(A={pane_extent(client, pane_a_id, 'width'):.0f}, "
                f"B={pane_extent(client, pane_b_id, 'width'):.0f})",
            )
            print(f"  Test 2 PASS: pane A is {a_ratio:.1%} of width after focus")

            # --- Test 3: 3-pane layout with full tree propagation ---
            # Create a third pane by splitting B downward: A | (B top / C bottom)
            client.focus_surface(surface_b)
            time.sleep(0.5)
            surface_c = client.new_split("down")
            wait_for(
                lambda: len(workspace_panes(client, workspace_id)) >= 3,
                timeout_s=4.0,
            )
            time.sleep(0.5)

            # After split, C is auto-focused. Focus B first so the next
            # focus_surface(C) is a real change that triggers didFocusPane.
            client.focus_surface(surface_b)
            time.sleep(0.5)

            # Focus C — should get ~75% in both dimensions
            client.focus_surface(surface_c)
            time.sleep(0.3)
            pane_c_id = focused_pane_id(client, workspace_id)

            # Wait for width ratio (C column vs A)
            c_width_ratio = _wait_for_ratio(client, pane_c_id, pane_a_id, "width", min_ratio=0.60, max_ratio=0.90)
            must(
                0.60 < c_width_ratio < 0.90,
                f"Test 3a FAIL: pane C column should be ~75% width, got {c_width_ratio:.2%} "
                f"(C_width={pane_extent(client, pane_c_id, 'width'):.0f}, "
                f"A_width={pane_extent(client, pane_a_id, 'width'):.0f})",
            )
            print(f"  Test 3a PASS: pane C column is {c_width_ratio:.1%} of width")

            # Wait for height ratio (C vs B in same column)
            pane_b_id_3 = [pid for pid, _, _ in workspace_panes(client, workspace_id)
                           if pid != pane_a_id and pid != pane_c_id]
            must(
                len(pane_b_id_3) == 1,
                f"Test 3b FAIL: expected exactly one sibling pane B, got {len(pane_b_id_3)}: "
                f"{[pid for pid, _, _ in workspace_panes(client, workspace_id)]}",
            )
            c_height_ratio = _wait_for_ratio(client, pane_c_id, pane_b_id_3[0], "height", min_ratio=0.60, max_ratio=0.90)
            must(
                0.60 < c_height_ratio < 0.90,
                f"Test 3b FAIL: pane C should be ~75% height, got {c_height_ratio:.2%} "
                f"(C_height={pane_extent(client, pane_c_id, 'height'):.0f}, "
                f"B_height={pane_extent(client, pane_b_id_3[0], 'height'):.0f})",
            )
            print(f"  Test 3b PASS: pane C is {c_height_ratio:.1%} of height")

            client.close_workspace(workspace_id)
            workspace_id = ""

            # --- Test 4: Same-orientation nesting (per-orientation factor) ---
            # Create a new workspace with A | (B | C) — two nested horizontal splits.
            # Without per-orientation correction, C would get 0.75 * 0.75 = 56% of
            # total width. With correction, each split gets sqrt(0.75) ≈ 0.866, so
            # C gets ~75% of total width.
            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)
            surfaces_4 = client.list_surfaces(workspace_id)
            must(bool(surfaces_4), "workspace should have at least one surface")
            surface_4a = surfaces_4[0][1]

            wait_for_surface_command_roundtrip(client, workspace_id, surface_4a)

            # First split: A | B
            surface_4b = client.new_split("right")
            wait_for(
                lambda: len(workspace_panes(client, workspace_id)) >= 2,
                timeout_s=4.0,
            )
            time.sleep(0.5)

            # Second split: A | (B | C) — split B to the right again
            client.focus_surface(surface_4b)
            time.sleep(0.3)
            surface_4c = client.new_split("right")
            wait_for(
                lambda: len(workspace_panes(client, workspace_id)) >= 3,
                timeout_s=4.0,
            )
            time.sleep(0.5)

            # Identify pane A by finding which pane contains surface_4a
            pane_4a_id = None
            for pid, _, _ in workspace_panes(client, workspace_id):
                client.focus_pane(pid)
                time.sleep(0.1)
                surfs = client.list_pane_surfaces(pid)
                for _, sid, _, _ in surfs:
                    if sid == surface_4a:
                        pane_4a_id = pid
                        break
                if pane_4a_id:
                    break
            must(pane_4a_id is not None, "Could not find pane A in test 4")

            # Focus A first, then focus C to trigger resize
            client.focus_surface(surface_4a)
            time.sleep(0.5)
            client.focus_surface(surface_4c)
            time.sleep(0.3)
            pane_4c_id = focused_pane_id(client, workspace_id)

            # C should get ~75% of total width (not 56% from compounding).
            # Measure C against the full container, not just C+A, since B also
            # takes width and C/(C+A) would mask the compounding bug.
            def _c_share_of_total() -> float:
                panes_4 = layout_panes(client)
                total_w = sum(
                    float((p.get("frame") or {}).get("width") or 0)
                    for p in panes_4
                )
                c_w = pane_extent(client, pane_4c_id, "width")
                return c_w / total_w if total_w > 0 else 0.0

            wait_for(
                lambda: _c_share_of_total() > 0.60,
                timeout_s=5.0,
            )
            c_total_ratio = _c_share_of_total()
            must(
                0.60 < c_total_ratio < 0.90,
                f"Test 4 FAIL: pane C should be ~75% of total width (per-orientation), "
                f"got {c_total_ratio:.2%} "
                f"(C={pane_extent(client, pane_4c_id, 'width'):.0f})",
            )
            print(f"  Test 4 PASS: pane C is {c_total_ratio:.1%} of total width "
                  f"(same-orientation nesting, per-orientation factor)")

            client.close_workspace(workspace_id)
            workspace_id = ""

            # --- Test 4: Same-orientation nesting (per-orientation factor) ---
            # Create a new workspace with A | (B | C) — two nested horizontal splits.
            # Without per-orientation correction, C would get 0.75 * 0.75 = 56% of
            # total width. With correction, each split gets sqrt(0.75) ≈ 0.866, so
            # C gets ~75% of total width.
            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)
            surfaces_4 = client.list_surfaces(workspace_id)
            must(bool(surfaces_4), "workspace should have at least one surface")
            surface_4a = surfaces_4[0][1]

            wait_for_surface_command_roundtrip(client, workspace_id, surface_4a)

            # First split: A | B
            surface_4b = client.new_split("right")
            wait_for(
                lambda: len(workspace_panes(client, workspace_id)) >= 2,
                timeout_s=4.0,
            )
            time.sleep(0.5)

            # Second split: A | (B | C) — split B to the right again
            client.focus_surface(surface_4b)
            time.sleep(0.3)
            surface_4c = client.new_split("right")
            wait_for(
                lambda: len(workspace_panes(client, workspace_id)) >= 3,
                timeout_s=4.0,
            )
            time.sleep(0.5)

            # Identify pane A by finding which pane contains surface_4a
            pane_4a_id = None
            for pid, _, _ in workspace_panes(client, workspace_id):
                client.focus_pane(pid)
                time.sleep(0.1)
                surfs = client.list_pane_surfaces(pid)
                for _, sid, _, _ in surfs:
                    if sid == surface_4a:
                        pane_4a_id = pid
                        break
                if pane_4a_id:
                    break
            must(pane_4a_id is not None, "Could not find pane A in test 4")

            # Focus A first, then focus C to trigger resize
            client.focus_surface(surface_4a)
            time.sleep(0.5)
            client.focus_surface(surface_4c)
            time.sleep(0.3)
            pane_4c_id = focused_pane_id(client, workspace_id)

            # C should get ~75% of total width (not 56% from compounding).
            # Measure C against the full container, not just C+A, since B also
            # takes width and C/(C+A) would mask the compounding bug.
            def _c_share_of_total() -> float:
                panes_4 = layout_panes(client)
                total_w = sum(
                    float((p.get("frame") or {}).get("width") or 0)
                    for p in panes_4
                )
                c_w = pane_extent(client, pane_4c_id, "width")
                return c_w / total_w if total_w > 0 else 0.0

            wait_for(
                lambda: _c_share_of_total() > 0.60,
                timeout_s=5.0,
            )
            c_total_ratio = _c_share_of_total()
            must(
                0.60 < c_total_ratio < 0.90,
                f"Test 4 FAIL: pane C should be ~75% of total width (per-orientation), "
                f"got {c_total_ratio:.2%} "
                f"(C={pane_extent(client, pane_4c_id, 'width'):.0f})",
            )
            print(f"  Test 4 PASS: pane C is {c_total_ratio:.1%} of total width "
                  f"(same-orientation nesting, per-orientation factor)")

            client.close_workspace(workspace_id)
            workspace_id = ""

        print("PASS: focus-resize correctly adjusts pane geometry on focus change")
        return 0

    finally:
        _disable_focus_resize()
        if workspace_id:
            try:
                with cmux(socket_path) as cleanup:
                    cleanup.close_workspace(workspace_id)
            except Exception as e:
                print(f"Cleanup failed for workspace {workspace_id}: {e}")


def main() -> int:
    """Entry point: connect to cmux via CMUX_SOCKET or default paths and run tests."""
    env_socket = os.environ.get("CMUX_SOCKET")
    if env_socket:
        return _run_once(env_socket)

    last_error: Exception | None = None
    for socket_path in DEFAULT_SOCKET_PATHS:
        try:
            return _run_once(socket_path)
        except cmuxError as exc:
            text = str(exc)
            if not any(token in text for token in ("Failed to connect", "Socket not found")):
                raise
            last_error = exc
            continue

    if last_error is not None:
        raise last_error
    raise cmuxError("No socket candidates configured")


if __name__ == "__main__":
    raise SystemExit(main())
