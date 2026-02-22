#!/usr/bin/env python3
"""
Regression test: simulate_shortcut("ctrl+d") should close the focused split pane.

Why: if ctrl+d shortcut simulation does not deliver EOF to the focused terminal,
split panes accumulate and repeated split/close workflows become sluggish.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _wait_for_pane_count(c: cmux, expected: int, timeout_s: float) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if len(c.list_panes()) == expected:
            return
        time.sleep(0.05)
    raise cmuxError(
        f"Timed out waiting for pane count {expected}; current={len(c.list_panes())}"
    )


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        c.new_workspace()
        c.activate_app()
        time.sleep(0.2)

        # Ensure deterministic starting state in case the workspace was pre-populated.
        panes = c.list_panes()
        while len(panes) > 1:
            c.close_surface(panes[-1][0])
            time.sleep(0.05)
            panes = c.list_panes()
        if len(panes) != 1:
            raise cmuxError(f"Expected one pane before split, got {len(panes)}")

        c.simulate_shortcut("cmd+d")
        _wait_for_pane_count(c, expected=2, timeout_s=2.0)

        focused = [pane for pane in c.list_panes() if pane[3]]
        if not focused:
            raise cmuxError("No focused pane after split")
        c.focus_pane(focused[0][0])
        time.sleep(0.05)

        c.simulate_shortcut("ctrl+d")
        _wait_for_pane_count(c, expected=1, timeout_s=2.0)

    print("PASS: ctrl+d shortcut closes focused split pane")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
