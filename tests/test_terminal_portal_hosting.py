#!/usr/bin/env python3
"""Regression: terminal views should be portal-hosted near the window root.

This catches regressions where terminal NSViews are reattached deep inside the SwiftUI
hierarchy, which increases Core Animation commit traversal depth and input latency.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _wait_portal_terminals(c: cmux, expected: int = 2, timeout: float = 8.0):
    """Poll surface_health until the terminals settle into their portal-hosted state.

    Returns the settled list of terminal rows once there are >= `expected`
    terminals and every one reports in_window=true and portal=true, which is
    the async AppKit layout/attachment state the assertions below check. Raises
    cmuxError with the last-seen snapshot if it never settles within `timeout`.
    """
    start = time.time()
    terminals: list = []
    while time.time() - start < timeout:
        health = c.surface_health()
        terminals = [row for row in health if row.get("type") == "terminal"]
        if len(terminals) >= expected and all(
            row.get("in_window", False) and row.get("portal") is True
            for row in terminals
        ):
            return terminals
        time.sleep(0.2)
    raise cmuxError(
        f"terminals did not become portal-hosted within {timeout}s: {terminals}"
    )


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        c.activate_app()

        c.new_workspace()
        c.new_split("right")

        terminals = _wait_portal_terminals(c, expected=2)

        for row in terminals:
            if not row.get("in_window", False):
                raise cmuxError(f"terminal not attached to window: {row}")
            if row.get("portal") is not True:
                raise cmuxError(f"terminal is not portal-hosted: {row}")
            depth = row.get("view_depth")
            if not isinstance(depth, int):
                raise cmuxError(f"missing view_depth in surface_health: {row}")
            if depth > 8:
                raise cmuxError(f"terminal view depth too deep ({depth}): {row}")

        print("PASS: terminal surfaces are portal-hosted with shallow view depth")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
