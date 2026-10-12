#!/usr/bin/env python3
"""Regression: a deep split chain must not pin the main thread (#10311, #16393).

Every Bonsplit pane is its own NSHostingView, so each split nests another
hosting view. While AppKit recalculates the window's default key view loop on
every subview insertion, SwiftUI answers each nested host's
acceptsFirstResponder with a fresh focus walk of the subtree below it: the
work grows exponentially with the depth. Agent teams build exactly this shape
(each teammate splits the previous pane), and at depth ~15 one split, or
switching back to that workspace, held the main thread for seconds to minutes.

The test opens a workspace holding a 16-deep chain of downward splits,
shows it, switches away and back, and checks that each step answers quickly
and the control socket keeps answering pings. Run it against a tagged build, never the user's default socket:
  CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock python3 tests_v2/test_deep_split_chain_stays_responsive.py
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError

DEPTH = 16
CREATE_LIMIT_S = 5.0
SWITCH_LIMIT_S = 2.0
MOUNT_S = 1.0


def chain(depth: int) -> dict:
    """A column of panes, each split below the last, like an agent team's teammates."""
    node: dict = {"pane": {"surfaces": [{"type": "terminal"}]}}
    for _ in range(depth):
        node = {"direction": "vertical", "split": 0.2, "children": [{"pane": {"surfaces": [{"type": "terminal"}]}}, node]}
    return node


def timed(fn, *args):
    start = time.monotonic()
    value = fn(*args)
    return value, time.monotonic() - start


def main() -> int:
    c = cmux()
    c.connect()
    if not c.ping():
        raise cmuxError("socket ping failed")

    results = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'} {name} {detail}".rstrip(), flush=True)

    home = c.current_workspace()
    # Runtime splits stop at the minimum pane size long before the chain gets
    # deep, so the workspace opens from a layout, as a restored session does.
    payload, created = timed(c._call, "workspace.create", {"title": "deep-split-chain", "layout": chain(DEPTH)})
    workspace = str((payload or {}).get("workspace_id") or "")
    if not workspace:
        raise cmuxError(f"workspace.create returned no workspace_id: {payload}")
    _, ping = timed(c.ping)
    print(f"create: {created:.2f}s ping {ping:.2f}s", flush=True)
    check(f"opening a {DEPTH}-deep chain answers within {CREATE_LIMIT_S}s", created + ping < CREATE_LIMIT_S,
          f"create={created:.2f}s ping={ping:.2f}s")

    def responsive(name: str, step) -> None:
        """Runs a step, waits for its views to mount, and checks the main actor still answers."""
        try:
            _, elapsed = timed(step)
            time.sleep(MOUNT_S)
            _, ping = timed(c.ping)
        except cmuxError as error:
            check(name, False, f"socket gave up: {error}")
            return
        print(f"{name}: {elapsed:.2f}s ping {ping:.2f}s", flush=True)
        check(name, elapsed + ping < SWITCH_LIMIT_S, f"step={elapsed:.2f}s ping={ping:.2f}s")

    responsive(f"showing the deep workspace answers within {SWITCH_LIMIT_S}s",
               lambda: c.select_workspace(workspace))
    try:
        panes = len((c._call("pane.list", {"workspace_id": workspace}) or {}).get("panes") or [])
    except cmuxError:
        panes = None
    check(f"the workspace holds all {DEPTH + 1} panes", panes == DEPTH + 1, f"panes={panes}")
    responsive(f"switching away answers within {SWITCH_LIMIT_S}s", lambda: c.select_workspace(home))
    responsive(f"switching back to the deep workspace answers within {SWITCH_LIMIT_S}s",
               lambda: c.select_workspace(workspace))

    try:
        c.select_workspace(home)
        c.close_workspace(workspace)
    except cmuxError:
        pass

    passed = sum(results)
    print(f"RESULT {passed}/{len(results)}", flush=True)
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
