#!/usr/bin/env python3
"""
End-to-end test for sidebar markdown metadata block commands.

Validates:
1) report_meta_block stores markdown payload and priority
2) metadata block list ordering follows priority
3) clear_meta_block removes block metadata
"""

from __future__ import annotations

import os
import sys
import time

# Add the directory containing cmux.py to the path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError  # noqa: E402


def _parse_sidebar_state(text: str) -> dict[str, str]:
    data: dict[str, str] = {}
    for raw in (text or "").splitlines():
        line = raw.rstrip("\n")
        if not line or line.startswith("  "):
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        data[k.strip()] = v.strip()
    return data


def _wait_for_state_field(
    client: cmux,
    key: str,
    expected: str,
    timeout: float = 8.0,
    interval: float = 0.1,
) -> dict[str, str]:
    start = time.time()
    while time.time() - start < timeout:
        state = _parse_sidebar_state(client.sidebar_state())
        if state.get(key) == expected:
            return state
        time.sleep(interval)
    raise AssertionError(f"Timed out waiting for {key}={expected!r}")


def main() -> int:
    tag = os.environ.get("CMUX_TAG") or ""
    if not tag:
        print("Tip: set CMUX_TAG=<tag> when running this test to avoid socket conflicts.")

    try:
        with cmux() as client:
            new_tab_id = client.new_tab()
            client.select_tab(new_tab_id)
            time.sleep(0.6)

            tab_id = client.current_workspace()

            summary_md = "### Agent\\n- status: in progress\\n- pr: #337"
            footer_md = "_last update: now_"

            client.report_meta_block("summary", summary_md, priority=50, tab=tab_id)
            client.report_meta_block("footer", footer_md, priority=10, tab=tab_id)
            _wait_for_state_field(client, "meta_block_count", "2")

            listed = client.list_meta_blocks(tab=tab_id).splitlines()
            if len(listed) != 2:
                raise AssertionError(f"Expected 2 metadata blocks, got {len(listed)}: {listed}")
            if not listed[0].startswith("summary="):
                raise AssertionError(f"Expected highest-priority block first. Got: {listed[0]}")
            if "priority=50" not in listed[0]:
                raise AssertionError(f"Expected summary block priority in listing. Got: {listed[0]}")

            client.clear_meta_block("summary", tab=tab_id)
            _wait_for_state_field(client, "meta_block_count", "1")

            listed = client.list_meta_blocks(tab=tab_id).splitlines()
            if any(line.startswith("summary=") for line in listed):
                raise AssertionError(f"Summary block should be cleared. Got: {listed}")

            try:
                client.close_tab(new_tab_id)
            except Exception:
                pass

        print("Sidebar markdown metadata block test passed.")
        return 0
    except (cmuxError, AssertionError) as e:
        print(f"Sidebar markdown metadata block test failed: {e}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
