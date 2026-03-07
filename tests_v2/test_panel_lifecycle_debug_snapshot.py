#!/usr/bin/env python3
"""Smoke test for the DEBUG panel lifecycle shadow snapshot.

Requires a Debug app socket that allows external clients, typically:

  CMUX_SOCKET=/tmp/cmux-debug-<tag>.sock
  CMUX_SOCKET_MODE=allowAll

This is intentionally narrow. It validates the transport and basic invariants
of the shadow snapshot without depending on a fragile workspace topology.
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


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        caps = c.capabilities() or {}
        methods = set(caps.get("methods") or [])
        _must(
            "debug.panel_lifecycle" in methods,
            f"Missing debug.panel_lifecycle capability: {sorted(methods)[:40]}",
        )

        snapshot = c.panel_lifecycle()
        counts = dict(snapshot.get("counts") or {})
        records = list(snapshot.get("records") or [])
        _must(records, f"panel_lifecycle returned no records: {snapshot}")

        _must(
            counts.get("panelCount") == len(records),
            f"panelCount mismatch: counts={counts} records={len(records)}",
        )

        visible_count = sum(1 for row in records if row.get("activeWindowMembership"))
        responder_count = sum(1 for row in records if row.get("responderEligible"))
        accessibility_count = sum(1 for row in records if row.get("accessibilityParticipation"))

        _must(
            counts.get("visibleInActiveWindowCount") == visible_count,
            f"visibleInActiveWindowCount mismatch: counts={counts} visible={visible_count}",
        )
        _must(
            counts.get("responderEligibleCount") == responder_count,
            f"responderEligibleCount mismatch: counts={counts} responder={responder_count}",
        )
        _must(
            counts.get("accessibilityParticipationCount") == accessibility_count,
            f"accessibilityParticipationCount mismatch: counts={counts} accessibility={accessibility_count}",
        )

        selected_workspace_id = snapshot.get("selectedWorkspaceId")
        _must(bool(selected_workspace_id), f"selectedWorkspaceId missing: {snapshot}")
        _must(
            any(row.get("workspaceId") == selected_workspace_id for row in records),
            f"selectedWorkspaceId not present in records: {selected_workspace_id}",
        )

        for row in records:
            if row.get("activeWindowMembership"):
                _must(
                    row.get("desiredVisible"),
                    f"activeWindowMembership without desiredVisible: {row}",
                )
            if row.get("responderEligible"):
                _must(
                    row.get("activeWindowMembership") and row.get("desiredActive"),
                    f"responderEligible invariant failed: {row}",
                )
            if row.get("accessibilityParticipation"):
                _must(
                    row.get("activeWindowMembership"),
                    f"accessibilityParticipation invariant failed: {row}",
                )

    print(
        "PASS: panel lifecycle snapshot transport works and aggregate invariants hold "
        f"(records={len(records)} visible={visible_count} responder={responder_count})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
