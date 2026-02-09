#!/usr/bin/env python3
"""Regression: nested split must not temporarily detach sibling surfaces from the window.

A common visual symptom is the *existing* split briefly disappearing when creating a
nested split (e.g. right pane split right again). One plausible mechanism is that we
remove an arranged subview before inserting its replacement, causing the removed panel's
NSView to leave the window for a frame.

We attempt to catch this by polling `surface_health` at high frequency right after the
nested split.

If any of the involved terminal panels reports `in_window=false` during the polling
window, we fail.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmuxterm-debug.sock")


def _health_map(c: cmux) -> dict[str, bool]:
    out: dict[str, bool] = {}
    for row in c.surface_health():
        pid = (row.get("id") or "").lower()
        if pid:
            out[pid] = bool(row.get("in_window"))
    return out


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        c.new_workspace()
        time.sleep(0.25)

        base = c.list_surfaces()
        if not base:
            raise cmuxError("expected initial surface")
        left_panel = base[0][1]

        right_panel = c.new_split("right")
        time.sleep(0.05)
        c.focus_surface(right_panel)
        time.sleep(0.02)

        new_right_panel = c.new_split("right")

        panel_ids = [left_panel, right_panel, new_right_panel]
        panel_ids_l = [p.lower() for p in panel_ids]

        # Poll for transient detachments.
        deadline = time.time() + 1.0
        seen_detach: list[tuple[float, str]] = []
        while time.time() < deadline:
            hm = _health_map(c)
            for pid in panel_ids_l:
                if hm.get(pid) is False:
                    seen_detach.append((time.time(), pid))
            # 5ms cadence; keep it tight to catch single-frame blips.
            time.sleep(0.005)

        if seen_detach:
            # Include only first few for brevity.
            sample = ", ".join([f"{pid}" for _ts, pid in seen_detach[:5]])
            raise cmuxError(f"saw in_window=false during nested split: {sample} (count={len(seen_detach)})")

        print("PASS: nested split did not detach panels (surface_health)")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
