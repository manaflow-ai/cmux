#!/usr/bin/env python3
"""Regression: nested splits must not transiently drop NSSplitView arrangedSubviews below 2.

User repro (visual):
  1) Create a left/right split.
  2) Focus the right pane.
  3) Split left/right again.

Observed: the original split can briefly disappear/collapse during the second split.

We detect the underlying cause: a structural update that removes an arranged subview
from the existing NSSplitView (arrangedSubviews count < 2), which AppKit can render
as a full collapse/flash of the sibling pane.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmuxterm-debug.sock")


def _take_screenshot(c: cmux, label: str) -> str:
    info = c.screenshot(label)
    sid = str(info.get("screenshot_id") or "").strip()
    path = str(info.get("path") or "").strip()
    return f"{sid} {path}".strip()


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        c.new_workspace()
        time.sleep(0.25)

        # First split: create two panes.
        c.new_split("right")
        time.sleep(0.35)

        panes = c.list_panes()
        if len(panes) < 2:
            raise cmuxError(f"expected >=2 panes after first split, got {len(panes)}: {panes}")

        # Focus the right pane, matching the user scenario.
        right_pane_id = panes[-1][1]
        c.focus_pane(right_pane_id)
        time.sleep(0.1)

        # Only measure underflow during the nested split.
        c.reset_bonsplit_underflow_count()

        # Second split: nested split inside the right pane.
        c.new_split("right")
        time.sleep(0.2)

        underflows = c.bonsplit_underflow_count()
        if underflows != 0:
            shot = _take_screenshot(c, "nested_split_underflow")
            raise cmuxError(f"bonsplit arranged-subview underflow observed ({underflows}); screenshot: {shot}")

        print("PASS: nested split did not underflow arrangedSubviews")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
