#!/usr/bin/env python3
"""Hidden terminal budget test for panel lifecycle snapshots."""

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
        snapshot = c.panel_lifecycle()
        counts = dict(snapshot.get("counts") or {})
        hidden_records = [
            dict(row)
            for row in list(snapshot.get("records") or [])
            if str(row.get("panelType") or "") == "terminal" and not bool(row.get("selectedWorkspace"))
        ]
        _must(hidden_records, f"no hidden terminal records in snapshot: {snapshot}")

        hidden_record = hidden_records[0]
        hidden_workspace = str(hidden_record.get("workspaceId") or "")

        _must(
            hidden_record.get("activeWindowMembership") is False,
            f"hidden terminal still contributes active-window budget: {hidden_record}",
        )
        _must(
            hidden_record.get("residency") in {"parkedOffscreen", "detachedRetained"},
            f"hidden terminal not parked/detached: {hidden_record}",
        )
        _must(
            hidden_record.get("responderEligible") is False,
            f"hidden terminal still contributes responder budget: {hidden_record}",
        )
        _must(
            hidden_record.get("accessibilityParticipation") is False,
            f"hidden terminal still contributes accessibility budget: {hidden_record}",
        )

        hidden_membership = sum(
            1
            for row in list(snapshot.get("records") or [])
            if str(row.get("workspaceId") or "") == hidden_workspace and bool(row.get("activeWindowMembership"))
        )
        _must(
            hidden_membership == 0,
            f"hidden workspace still has active-window members: {hidden_workspace} count={hidden_membership}",
        )
        _must(
            counts.get("visibleInActiveWindowCount", 0) >= 1,
            f"lifecycle counts look empty after hiding workspace: {counts}",
        )

    print("PASS: hidden terminal workspace contributes no active-window, responder, or accessibility budget")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
