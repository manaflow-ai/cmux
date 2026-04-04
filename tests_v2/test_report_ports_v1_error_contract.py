#!/usr/bin/env python3
"""Regression: report_ports returns synchronous ERROR for invalid targets (v1 socket contract)."""

from __future__ import annotations

import os
import sys
from pathlib import Path

_REPO_TESTS = Path(__file__).resolve().parent.parent / "tests"
sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(_REPO_TESTS))

from cmux import cmux, cmuxError  # noqa: E402

SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def main() -> int:
    fake_tab = "00000000-0000-0000-0000-000000000042"
    with cmux(SOCKET_PATH) as client:
        response = client._send_command(f"report_ports 8080 --tab={fake_tab}")
        _must(
            response.startswith("ERROR:"),
            f"report_ports with non-existent tab must return ERROR synchronously, got {response!r}",
        )
        lowered = response.lower()
        _must(
            "tab" in lowered or "not found" in lowered or "no tab" in lowered,
            f"report_ports error should mention tab/not found: {response!r}",
        )

        workspace_id = client.new_workspace()
        try:
            bad_panel = "00000000-0000-0000-0000-000000000099"
            response2 = client._send_command(
                f"report_ports 9090 --tab={workspace_id} --panel={bad_panel}"
            )
            _must(
                response2.startswith("ERROR:"),
                f"report_ports with missing panel must return ERROR synchronously, got {response2!r}",
            )
            _must(
                "panel" in response2.lower(),
                f"report_ports panel error should mention panel: {response2!r}",
            )
        finally:
            client.close_workspace(workspace_id)

    print("PASS: report_ports invalid targets return ERROR on the wire")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
