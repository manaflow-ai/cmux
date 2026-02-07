#!/usr/bin/env python3
"""
Regression: sidebar log messages must preserve tokens that start with `--`.

TerminalController.parseOptions() treats `--*` tokens as options until a `--`
separator. The log command must therefore send options before the message and
use `--` so arbitrary message contents round-trip correctly.

Run with a tagged instance to avoid unix socket conflicts:
  CMUX_TAG=<tag> python3 tests/test_sidebar_log_parsing.py
"""

from __future__ import annotations

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError  # noqa: E402


def _assert_contains(text: str, needle: str) -> None:
    if needle not in (text or ""):
        raise AssertionError(f"Expected to find: {needle}\n\nGot:\n{text}")


def main() -> int:
    try:
        with cmux() as client:
            tab_id = client.new_tab()
            client.select_tab(tab_id)
            time.sleep(0.7)

            client._send_command(f"clear_log --tab={tab_id}")

            msg1 = "hello --force mid -- --level=not-an-option end"
            client.log(msg1, level="warning", source="test", tab=tab_id)

            msg2 = "--force starts-with-dashdash"
            client.log(msg2, level="info", source="test", tab=tab_id)

            time.sleep(0.2)
            out = client._send_command(f"list_log --tab={tab_id} --limit=2")
            _assert_contains(out, f"[warning] {msg1} (source=test)")
            _assert_contains(out, f"[info] {msg2} (source=test)")

            try:
                client.close_tab(tab_id)
            except Exception:
                pass

        print("PASS: log messages preserve `--*` tokens")
        return 0

    except (cmuxError, AssertionError) as exc:
        print(f"FAIL: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

