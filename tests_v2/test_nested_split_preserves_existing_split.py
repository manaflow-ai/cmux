#!/usr/bin/env python3
"""Regression: splitting inside a pane must not collapse/lose existing sibling splits.

Repro (user report):
  1) Create a left/right split.
  2) Focus the right pane.
  3) Split left/right again.

Bug: the original split can "disappear" (a sibling pane collapses to ~0px or its
selected panel view detaches from the window) after the second split.

We validate using the debug-only `layout_debug` socket command:
  - The original left pane ID remains present.
  - After the second split settles, there are 3 panes.
  - No pane/panel is collapsed or hidden.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmuxterm-debug.sock")


def _layout_obj(payload: dict) -> dict:
    # layout_debug returns {"layout": {...}, "selectedPanels": [...], ...}
    # but allow passing the inner layout object directly.
    if isinstance(payload.get("layout"), dict):
        return payload["layout"]
    return payload


def _sorted_panes_by_x(payload: dict) -> list[dict]:
    layout = _layout_obj(payload)
    panes = layout.get("panes") or []
    return sorted(panes, key=lambda p: float((p.get("frame") or {}).get("x", 0.0)))


def _selected_panels_by_pane(payload: dict) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for row in payload.get("selectedPanels") or []:
        pid = row.get("paneId")
        if pid:
            out[str(pid)] = row
    return out


def _assert_stable_layout(payload: dict, *, expected_panes: int, min_wh: float = 80.0) -> None:
    panes = _sorted_panes_by_x(payload)
    if len(panes) != expected_panes:
        raise cmuxError(f"expected {expected_panes} panes, got {len(panes)}")

    selected_by_pane = _selected_panels_by_pane(payload)
    if len(selected_by_pane) < expected_panes:
        raise cmuxError(f"layout_debug missing selectedPanels (got {len(selected_by_pane)} for {expected_panes} panes)")

    for p in panes:
        pid = str(p.get("paneId"))
        frame = p.get("frame") or {}
        w = float(frame.get("width", 0.0))
        h = float(frame.get("height", 0.0))
        if w < min_wh or h < min_wh:
            raise cmuxError(f"pane collapsed: paneId={pid} frame={frame}")

        row = selected_by_pane.get(pid)
        if not row:
            raise cmuxError(f"missing selectedPanels entry for paneId={pid}")

        panel_id = row.get("panelId")
        if not panel_id:
            raise cmuxError(f"missing panelId for paneId={pid}")

        if row.get("inWindow") is not True:
            raise cmuxError(f"panel not in window: paneId={pid} panelId={panel_id} inWindow={row.get('inWindow')}")

        if row.get("hidden") is True:
            raise cmuxError(f"panel hidden: paneId={pid} panelId={panel_id}")

        view_frame = row.get("viewFrame") or {}
        vw = float(view_frame.get("width", 0.0))
        vh = float(view_frame.get("height", 0.0))
        if vw < min_wh or vh < min_wh:
            raise cmuxError(f"panel viewFrame collapsed: paneId={pid} panelId={panel_id} viewFrame={view_frame}")


def _take_screenshot(c: cmux, label: str) -> str:
    info = c.screenshot(label)
    sid = str(info.get("screenshot_id") or "").strip()
    path = str(info.get("path") or "").strip()
    return f"{sid} {path}".strip()


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        c.new_workspace()
        time.sleep(0.35)

        # First split: left/right.
        c.new_split("right")
        time.sleep(0.45)

        first = c.layout_debug()
        panes = _sorted_panes_by_x(first)
        if len(panes) < 2:
            raise cmuxError(f"expected >=2 panes after first split, got {len(panes)}")

        left_pane_id = str(panes[0].get("paneId"))
        right_pane_id = str(panes[-1].get("paneId"))

        if not left_pane_id or not right_pane_id:
            raise cmuxError(f"missing pane IDs: left={left_pane_id} right={right_pane_id}")

        # Focus the rightmost pane.
        c.focus_pane(right_pane_id)
        time.sleep(0.2)

        # Second split: split inside the right pane.
        c.new_split("right")

        # Wait for layout to settle. If the bug triggers, the original left pane will
        # often end up detached/hidden or effectively collapsed.
        last_payload = None
        last_err = None
        deadline = time.time() + 3.0
        while time.time() < deadline:
            payload = c.layout_debug()
            last_payload = payload

            panes_now = _sorted_panes_by_x(payload)
            pane_ids = {str(p.get("paneId")) for p in panes_now}
            if left_pane_id not in pane_ids:
                last_err = f"left pane disappeared: {left_pane_id} not in {pane_ids}"
                time.sleep(0.05)
                continue

            try:
                _assert_stable_layout(payload, expected_panes=3)
                # Looks good.
                print("PASS: nested split preserved existing panes")
                return 0
            except cmuxError as e:
                last_err = str(e)
                time.sleep(0.05)

        # Failure: capture a screenshot to aid debugging.
        shot = _take_screenshot(c, "nested_split_failure")
        raise cmuxError(f"nested split layout never stabilized: {last_err}; screenshot: {shot}; payload_keys={list((last_payload or {}).keys())}")


if __name__ == "__main__":
    raise SystemExit(main())
