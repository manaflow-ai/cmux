#!/usr/bin/env python3
"""Browser residency smoke test for panel lifecycle snapshots.

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


def _browser_record_by_panel(snapshot: dict, panel_id: str) -> tuple[dict, dict]:
    records = list(snapshot.get("records") or [])
    desired = dict(snapshot.get("desired") or {})
    desired_records = list(desired.get("records") or [])
    current = next((row for row in records if row.get("panelId") == panel_id), None)
    target = next((row for row in desired_records if row.get("panelId") == panel_id), None)
    if current is None or target is None:
        raise cmuxError(f"missing browser lifecycle record for panel {panel_id}: {snapshot}")
    return dict(current), dict(target)


def _wait_for_panel_snapshot(c: cmux, panel_id: str, timeout_s: float = 4.0) -> tuple[dict, dict]:
    start = time.time()
    last_snapshot: dict | None = None
    while time.time() - start < timeout_s:
        snapshot = c.panel_lifecycle()
        last_snapshot = snapshot
        try:
            return _browser_record_by_panel(snapshot, panel_id)
        except cmuxError:
            time.sleep(0.05)
    raise cmuxError(f"timed out waiting for browser panel {panel_id} in snapshot: {last_snapshot}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        first_workspace = c.list_workspaces()[0][1]
        c.select_workspace(first_workspace)

        visible_browser = c.open_browser("https://example.com")
        hidden_workspace = c.new_workspace()
        c.select_workspace(hidden_workspace)
        hidden_browser = c.open_browser("https://example.com/hidden")
        c.select_workspace(first_workspace)

        visible_current, visible_target = _wait_for_panel_snapshot(c, visible_browser)
        hidden_current, hidden_target = _wait_for_panel_snapshot(c, hidden_browser)

        _must(visible_current.get("panelType") == "browser", f"visible browser wrong type: {visible_current}")
        _must(hidden_current.get("panelType") == "browser", f"hidden browser wrong type: {hidden_current}")

        _must(visible_target.get("targetVisible") is True, f"visible browser not target-visible: {visible_target}")
        _must(
            visible_target.get("targetResidency") == "visibleInActiveWindow",
            f"visible browser wrong residency: {visible_target}",
        )
        _must(
            visible_target.get("requiresCurrentGenerationAnchor") is True,
            f"visible browser should require current-generation anchor: {visible_target}",
        )

        _must(hidden_target.get("targetVisible") is False, f"hidden browser still target-visible: {hidden_target}")
        _must(
            hidden_target.get("targetResidency") != "visibleInActiveWindow",
            f"hidden browser still visible residency: {hidden_target}",
        )
        _must(
            hidden_current.get("activeWindowMembership") is False,
            f"hidden browser still active in current snapshot: {hidden_current}",
        )

        plan = dict((c.panel_lifecycle().get("desired") or {}).get("browserExecutorPlan") or {})
        counts = dict(plan.get("counts") or {})
        records = list(plan.get("records") or [])
        _must(records, f"browser executor plan missing records: {plan}")
        _must(
            counts.get("panelCount", 0) >= 2,
            f"browser executor plan should include both browser panels: {counts}",
        )

        hidden_plan = next((row for row in records if row.get("panelId") == hidden_browser), None)
        visible_plan = next((row for row in records if row.get("panelId") == visible_browser), None)
        _must(hidden_plan is not None, f"missing hidden browser executor record: {plan}")
        _must(visible_plan is not None, f"missing visible browser executor record: {plan}")
        _must(
            hidden_plan.get("action") in {"moveToDetachedRetained", "moveToParkedOffscreen", "noop"},
            f"hidden browser executor action unexpected: {hidden_plan}",
        )
        _must(
            visible_plan.get("action") in {"bindVisible", "noop"},
            f"visible browser executor action unexpected: {visible_plan}",
        )

    print("PASS: browser lifecycle residency distinguishes visible and hidden browser panels")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
