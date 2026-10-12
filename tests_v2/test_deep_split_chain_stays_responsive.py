#!/usr/bin/env python3
"""Regression: a deep split chain must not pin the main thread (#10311, #16393).

Bonsplit used to host each split level in its own NSHostingView, so a chain
nested one hosting view per level. Rebuilding the window's key view loop asks
every nested host for its focusable items, and the work roughly doubled with
each level: a 16-deep chain held the main thread for about 30 s the first time it was shown.
Agent teams build exactly this shape (each teammate splits the previous pane).

The test opens a workspace holding a 16-deep chain of downward splits, shows
it, and times how long a main-actor request (`pane.list`) waits afterwards.
`ping` is answered off the main actor, so it cannot detect the stall. Run it
against a tagged build, never the user's default socket:
  CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock python3 tests_v2/test_deep_split_chain_stays_responsive.py
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError

DEPTH = 16
STALL_LIMIT_S = 1.0
GIVE_UP_S = 120.0


def chain(depth: int) -> dict:
    """A column of panes, each split below the last, like an agent team's teammates."""
    node: dict = {"pane": {"surfaces": [{"type": "terminal"}]}}
    for _ in range(depth):
        node = {"direction": "vertical", "split": 0.2, "children": [{"pane": {"surfaces": [{"type": "terminal"}]}}, node]}
    return node


def is_timeout(error: cmuxError) -> bool:
    """True for a request that timed out, on the client or at the main-actor deadline."""
    text = str(error)
    return text.startswith("timeout:") or text == "Timed out waiting for response"


def main_actor_stall(c: cmux, workspace: str):
    """Seconds until a main-actor request on the workspace answers, or None after GIVE_UP_S.

    Only timeouts are retried; any other error is a real failure and is raised.
    """
    start = time.monotonic()
    while time.monotonic() - start < GIVE_UP_S:
        try:
            panes = (c._call("pane.list", {"workspace_id": workspace}) or {}).get("panes") or []
            return time.monotonic() - start, len(panes)
        except cmuxError as error:
            if not is_timeout(error):
                raise
            # A late reply to the timed-out request would answer the next one.
            c.close()
            c.connect()
    return None, 0


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
    payload = c._call("workspace.create", {"title": "deep-split-chain", "layout": chain(DEPTH)}) or {}
    workspace = str(payload.get("workspace_id") or "")
    if not workspace:
        raise cmuxError(f"workspace.create returned no workspace_id: {payload}")

    for step, target in (("showing the deep workspace", workspace), ("switching away", home),
                         ("switching back to the deep workspace", workspace)):
        try:
            c.select_workspace(target)
        except cmuxError:
            pass
        time.sleep(1.0)
        stall, panes = main_actor_stall(c, workspace)
        detail = f"stall={'>%ds' % GIVE_UP_S if stall is None else '%.2fs' % stall} panes={panes}"
        check(f"{step} leaves the main actor answering within {STALL_LIMIT_S}s",
              stall is not None and stall < STALL_LIMIT_S, detail)

    check(f"the workspace holds all {DEPTH + 1} panes", panes == DEPTH + 1, f"panes={panes}")

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
