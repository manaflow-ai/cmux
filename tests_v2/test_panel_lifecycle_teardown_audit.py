#!/usr/bin/env python3
"""Check DEBUG lifecycle teardown audit for heavy-view leaks."""

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


def _audit_is_clean(snapshot: dict) -> bool:
    audit = dict(snapshot.get("audit") or {})
    for executor_name in ("terminal", "browser"):
        executor = dict(audit.get(executor_name) or {})
        totals = dict(executor.get("totals") or {})
        if int(totals.get("orphanHostedSubviewCount") or 0) != 0:
            return False
        if int(totals.get("detachedMappedObjectCount") or 0) != 0:
            return False
        for portal in list(executor.get("portals") or []):
            if int(portal.get("orphanHostedSubviewCount") or 0) != 0:
                return False
    return True


def _wait_for_clean_audit(c: cmux, timeout_s: float = 8.0) -> dict:
    start = time.time()
    last_snapshot: dict | None = None
    while time.time() - start < timeout_s:
        snapshot = c.panel_lifecycle()
        last_snapshot = snapshot
        if _audit_is_clean(snapshot):
            return snapshot
        time.sleep(0.05)
    raise cmuxError(f"teardown audit did not converge cleanly: {last_snapshot}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        original_workspace = c.current_workspace()
        hidden_workspace = c.new_workspace()
        c.select_workspace(original_workspace)

        snapshot = _wait_for_clean_audit(c)
        audit = dict(snapshot.get("audit") or {})

        for executor_name in ("terminal", "browser"):
            executor = dict(audit.get(executor_name) or {})
            totals = dict(executor.get("totals") or {})
            _must(executor, f"missing executor audit for {executor_name}: {audit}")
            _must(
                int(totals.get("orphanHostedSubviewCount") or 0) == 0,
                f"{executor_name} orphanHostedSubviewCount leaked: {executor}",
            )
            _must(
                int(totals.get("detachedMappedObjectCount") or 0) == 0,
                f"{executor_name} detachedMappedObjectCount leaked: {executor}",
            )
            for portal in list(executor.get("portals") or []):
                _must(
                    int(portal.get("orphanHostedSubviewCount") or 0) == 0,
                    f"{executor_name} portal orphanHostedSubviewCount leaked: {portal}",
                )

        c.select_workspace(hidden_workspace)
        c.close_workspace(hidden_workspace)
        c.select_workspace(original_workspace)
        _wait_for_clean_audit(c)

    print("PASS: lifecycle teardown audit reports no heavy-view leaks after workspace hide/close churn")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
