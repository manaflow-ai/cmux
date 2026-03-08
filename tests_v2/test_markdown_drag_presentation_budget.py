#!/usr/bin/env python3
"""Markdown drag smoke test for lifecycle-visible presentation.

Requires a Debug app socket that allows external clients, typically:

  CMUX_SOCKET=/tmp/cmux-debug-<tag>.sock
  CMUX_SOCKET_MODE=allowAll
"""

import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _document_plan(snapshot: dict, panel_id: str) -> tuple[dict, dict]:
    records = list(snapshot.get("records") or [])
    desired = dict(snapshot.get("desired") or {})
    desired_records = list(desired.get("records") or [])
    plan = dict(desired.get("documentExecutorPlan") or {})
    plan_records = list(plan.get("records") or [])
    current = next((row for row in records if row.get("panelId") == panel_id), None)
    target = next((row for row in desired_records if row.get("panelId") == panel_id), None)
    plan_record = next((row for row in plan_records if row.get("panelId") == panel_id), None)
    if current is None or target is None or plan_record is None:
        raise cmuxError(f"missing markdown lifecycle record for panel {panel_id}")
    return dict(target), dict(plan_record)


def _wait_for_visible_markdown(c: cmux, panel_id: str, timeout_s: float = 4.0) -> tuple[dict, dict]:
    start = time.time()
    last_snapshot: dict | None = None
    while time.time() - start < timeout_s:
        snapshot = c.panel_lifecycle()
        last_snapshot = snapshot
        try:
            target, plan_record = _document_plan(snapshot, panel_id)
        except cmuxError:
            time.sleep(0.05)
            continue
        if target.get("targetVisible") is True and target.get("targetResidency") == "visibleInActiveWindow":
            return target, plan_record
        time.sleep(0.05)
    raise cmuxError(f"timed out waiting for visible markdown panel {panel_id}: {last_snapshot}")


def main() -> int:
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
        f.write("# drag budget\n\n" + "\n".join(f"line {i}" for i in range(120)) + "\n")
        markdown_path = f.name

    try:
        with cmux(SOCKET_PATH) as c:
            workspace = c.current_workspace()
            result = c.markdown_open(markdown_path, workspace=workspace)
            panel_id = str(result.get("surface_id") or "")
            _must(panel_id, "markdown.open did not return surface_id")

            _wait_for_visible_markdown(c, panel_id)

            for index, direction in enumerate(["right", "down", "left"], start=1):
                started = time.time()
                c.drag_surface_to_split(panel_id, direction)
                target, plan_record = _wait_for_visible_markdown(c, panel_id)
                elapsed_ms = (time.time() - started) * 1000.0

                _must(
                    plan_record.get("action") in {"showInTree", "noop"},
                    f"unexpected markdown executor action after drag {direction}: {plan_record}",
                )
                _must(
                    target.get("targetVisible") is True and target.get("targetResidency") == "visibleInActiveWindow",
                    f"markdown panel no longer visible after drag {direction}: {target}",
                )
                _must(elapsed_ms < 4000.0, f"markdown drag convergence too slow after {direction}: {elapsed_ms:.2f}ms")

        print("PASS: markdown drag keeps lifecycle-visible presentation within the drag budget")
        return 0
    finally:
        try:
            os.unlink(markdown_path)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
