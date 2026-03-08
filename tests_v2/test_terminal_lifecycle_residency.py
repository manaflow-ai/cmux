#!/usr/bin/env python3
"""Terminal residency smoke test for panel lifecycle snapshots.

Requires a Debug app socket that allows external clients, typically:

  CMUX_SOCKET=/tmp/cmux-debug-<tag>.sock
  CMUX_SOCKET_MODE=allowAll
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _terminal_rows(snapshot: dict, desired: bool = False) -> list[dict]:
    container = dict(snapshot.get("desired") or {}) if desired else snapshot
    rows = list(container.get("records") or [])
    return [dict(row) for row in rows if str(row.get("panelType") or "") == "terminal"]


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        snapshot = c.panel_lifecycle()

    current_rows = _terminal_rows(snapshot)
    desired_rows = _terminal_rows(snapshot, desired=True)

    visible_record = next(
        (
            row
            for row in current_rows
            if bool(row.get("selectedWorkspace")) and bool(row.get("activeWindowMembership"))
        ),
        None,
    )
    hidden_record = next(
        (
            row
            for row in current_rows
            if not bool(row.get("selectedWorkspace")) and not bool(row.get("activeWindowMembership"))
        ),
        None,
    )
    visible_target_record = next((row for row in desired_rows if bool(row.get("targetVisible"))), None)
    hidden_target_record = next((row for row in desired_rows if not bool(row.get("targetVisible"))), None)

    _must(visible_record is not None, f"missing visible terminal record: {snapshot}")
    _must(hidden_record is not None, f"missing hidden terminal record: {snapshot}")
    _must(visible_target_record is not None, f"missing visible desired terminal record: {snapshot}")
    _must(hidden_target_record is not None, f"missing hidden desired terminal record: {snapshot}")

    _must(visible_target_record.get("targetVisible") is True, f"visible terminal not target-visible: {visible_target_record}")
    _must(
        visible_target_record.get("targetResidency") == "visibleInActiveWindow",
        f"visible terminal wrong residency: {visible_target_record}",
    )
    _must(
        visible_target_record.get("requiresCurrentGenerationAnchor") is True,
        f"visible terminal should require current-generation anchor: {visible_target_record}",
    )

    _must(hidden_target_record.get("targetVisible") is False, f"hidden terminal still target-visible: {hidden_target_record}")
    _must(
        hidden_target_record.get("targetResidency") != "visibleInActiveWindow",
        f"hidden terminal still visible residency: {hidden_target_record}",
    )
    _must(
        hidden_record.get("activeWindowMembership") is False,
        f"hidden terminal still active in current snapshot: {hidden_record}",
    )

    plan = dict((snapshot.get("desired") or {}).get("terminalExecutorPlan") or {})
    counts = dict(plan.get("counts") or {})
    records = list(plan.get("records") or [])
    _must(records, f"terminal executor plan missing records: {plan}")
    _must(
        counts.get("panelCount", 0) >= 1,
        f"terminal executor plan should include terminal panels: {counts}",
    )

    hidden_plan = next(
        (
            row
            for row in records
            if not bool(row.get("targetVisible"))
        ),
        None,
    )
    visible_plan = next(
        (
            row
            for row in records
            if bool(row.get("targetVisible"))
        ),
        None,
    )
    _must(hidden_plan is not None, f"missing hidden terminal executor record: {plan}")
    _must(visible_plan is not None, f"missing visible terminal executor record: {plan}")
    _must(
        hidden_plan.get("action") in {"moveToDetachedRetained", "moveToParkedOffscreen", "noop"},
        f"hidden terminal executor action unexpected: {hidden_plan}",
    )
    _must(
        visible_plan.get("action") in {"bindVisible", "noop"},
        f"visible terminal executor action unexpected: {visible_plan}",
    )

    print("PASS: terminal lifecycle residency distinguishes visible and hidden terminal states")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
