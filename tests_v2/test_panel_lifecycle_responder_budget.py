#!/usr/bin/env python3
"""Socket-level responder budget test for panel lifecycle snapshots."""

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


def _record_by_panel(snapshot: dict, panel_id: str) -> dict:
    for row in list(snapshot.get("records") or []):
        if str(row.get("panelId") or "") == panel_id:
            return dict(row)
    raise cmuxError(f"missing lifecycle record for panel {panel_id}")


def _wait_for_records(c: cmux, panel_ids: list[str], timeout_s: float = 5.0) -> dict:
    start = time.time()
    last_snapshot: dict | None = None
    while time.time() - start < timeout_s:
        snapshot = c.panel_lifecycle()
        last_snapshot = snapshot
        try:
            for panel_id in panel_ids:
                _record_by_panel(snapshot, panel_id)
            return snapshot
        except cmuxError:
            time.sleep(0.05)
    raise cmuxError(f"timed out waiting for lifecycle records: {panel_ids} snapshot={last_snapshot}")

def main() -> int:
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
        f.write("# responder budget\n\nhello\n")
        markdown_path = f.name

    try:
        with cmux(SOCKET_PATH) as c:
            original_workspace = c.current_workspace()
            visible_browser = c.open_browser("https://example.com/visible-responder-budget")

            hidden_workspace = c.new_workspace()
            c.select_workspace(hidden_workspace)
            hidden_browser = c.open_browser("https://example.com/hidden-responder-budget")
            hidden_markdown = str(c.markdown_open(markdown_path, workspace=hidden_workspace).get("surface_id") or "")
            _must(hidden_markdown, "hidden markdown.open did not return surface_id")
            c.select_workspace(original_workspace)

            snapshot = _wait_for_records(c, [visible_browser, hidden_browser, hidden_markdown])
            counts = dict(snapshot.get("counts") or {})

            hidden_browser_record = _record_by_panel(snapshot, hidden_browser)
            hidden_markdown_record = _record_by_panel(snapshot, hidden_markdown)

            _must(
                hidden_browser_record.get("responderEligible") is False,
                f"hidden browser still responder-eligible: {hidden_browser_record}",
            )
            _must(
                hidden_markdown_record.get("responderEligible") is False,
                f"hidden markdown still responder-eligible: {hidden_markdown_record}",
            )

            responder_count = sum(
                1 for row in list(snapshot.get("records") or []) if bool(row.get("responderEligible"))
            )
            _must(
                counts.get("responderEligibleCount") == responder_count,
                f"responderEligibleCount mismatch: counts={counts} computed={responder_count}",
            )

        print("PASS: hidden panels do not contribute responder budget")
        return 0
    finally:
        try:
            os.unlink(markdown_path)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
