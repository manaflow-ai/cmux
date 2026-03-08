#!/usr/bin/env python3
"""Browser handoff smoke test for generation-guarded lifecycle snapshots.

Requires a Debug app socket that allows external clients, typically:

  CMUX_SOCKET=/tmp/cmux-debug-<tag>.sock
  CMUX_SOCKET_MODE=allowAll
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for_browser_plan(c: cmux, panel_id: str, timeout_s: float = 4.0) -> tuple[dict, dict, dict]:
    start = time.time()
    last_snapshot: dict | None = None
    while time.time() - start < timeout_s:
        snapshot = c.panel_lifecycle()
        last_snapshot = snapshot
        desired = dict(snapshot.get("desired") or {})
        desired_records = list(desired.get("records") or [])
        plan = dict(desired.get("browserExecutorPlan") or {})
        plan_records = list(plan.get("records") or [])
        target = next((row for row in desired_records if row.get("panelId") == panel_id), None)
        plan_record = next((row for row in plan_records if row.get("panelId") == panel_id), None)
        current = next((row for row in list(snapshot.get("records") or []) if row.get("panelId") == panel_id), None)
        if current and target and plan_record:
            return dict(current), dict(target), dict(plan_record)
        time.sleep(0.05)
    raise cmuxError(f"timed out waiting for browser plan for {panel_id}: {last_snapshot}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        first_workspace = c.list_workspaces()[0][1]
        c.select_workspace(first_workspace)

        browser_panel = c.open_browser("https://example.com/handoff")
        second_workspace = c.new_workspace()
        c.move_surface(browser_panel, workspace=second_workspace, focus=False)
        c.select_workspace(second_workspace)

        current, target, plan_record = _wait_for_browser_plan(c, browser_panel)

        _must(target.get("panelType") == "browser", f"wrong target panel type: {target}")
        _must(target.get("targetVisible") is True, f"browser not visible after handoff: {target}")
        _must(
            target.get("targetResidency") == "visibleInActiveWindow",
            f"browser wrong residency after handoff: {target}",
        )
        _must(
            target.get("requiresCurrentGenerationAnchor") is True,
            f"browser handoff should require current-generation anchor: {target}",
        )
        _must(
            plan_record.get("action") in {"bindVisible", "noop"},
            f"browser handoff plan action unexpected: {plan_record}",
        )
        if plan_record.get("bindingSatisfied"):
            _must(
                plan_record.get("bindingGeneration") == plan_record.get("generation"),
                f"browser handoff satisfied with stale generation: {plan_record}",
            )
        else:
            _must(
                plan_record.get("action") == "bindVisible",
                f"unsatisfied visible browser should plan bindVisible: {plan_record}",
            )

        _must(
            current.get("activeWindowMembership") in {True, False},
            f"current browser record malformed: {current}",
        )

    print("PASS: browser lifecycle handoff requires current-generation binding satisfaction")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
