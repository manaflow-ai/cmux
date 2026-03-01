#!/usr/bin/env python3
"""
End-to-end test for sidebar pull-request metadata.

Validates:
1) report_pr writes sidebar PR state
2) state transition open -> merged is reflected
3) provider labels can be set via report_review/report_pr --label
4) clear_pr removes PR metadata
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

    pr_number = 123
    pr_url = f"https://github.com/manaflow-ai/cmux/pull/{pr_number}"

    try:
        with cmux() as client:
            new_tab_id = client.new_tab()
            client.select_tab(new_tab_id)
            time.sleep(0.6)

            tab_id = client.current_workspace()
            surfaces = client.list_surfaces()
            if not surfaces:
                raise AssertionError("No surfaces found in selected workspace")
            panel_id = surfaces[0][1]

            client.report_pr(pr_number, pr_url, state="open", tab=tab_id, panel=panel_id)
            _wait_for_state_field(client, "pr", f"#{pr_number} open {pr_url}")
            _wait_for_state_field(client, "pr_label", "PR")

            client.report_review(pr_number, pr_url, label="MR", state="open", tab=tab_id, panel=panel_id)
            _wait_for_state_field(client, "pr", f"#{pr_number} open {pr_url}")
            _wait_for_state_field(client, "pr_label", "MR")

            client.report_pr(pr_number, pr_url, state="merged", tab=tab_id, panel=panel_id)
            _wait_for_state_field(client, "pr", f"#{pr_number} merged {pr_url}")
            _wait_for_state_field(client, "pr_label", "PR")

            client.clear_pr(tab=tab_id, panel=panel_id)
            _wait_for_state_field(client, "pr", "none")
            _wait_for_state_field(client, "pr_label", "none")

            try:
                client.close_tab(new_tab_id)
            except Exception:
                pass

        print("Sidebar PR metadata test passed.")
        return 0
    except (cmuxError, AssertionError) as e:
        print(f"Sidebar PR metadata test failed: {e}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
