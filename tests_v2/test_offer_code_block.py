#!/usr/bin/env python3
"""
Regression test for surface.offer_code_block (v2).

Agents offer a copyable or runnable block to their own pane. The call must
land on the named terminal, classify shell tags as runnable, cap the pane at
three cards, reject empty text, and clear on request, all without moving focus.
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        sid = c.new_surface(panel_type="terminal")

        first = c.offer_code_block(sid, text="npm test\n", language="bash", label="Run the tests")
        if first.get("runnable") is not True or first.get("offered") != 1:
            raise cmuxError(f"bash block should be runnable and counted: {first!r}")

        json_block = c.offer_code_block(sid, text='{"a": 1}', language="json")
        if json_block.get("runnable") is not False:
            raise cmuxError(f"json block should be copy-only: {json_block!r}")

        forced = c.offer_code_block(sid, text="make", runnable=True)
        if forced.get("runnable") is not True:
            raise cmuxError(f"--run should force Run on: {forced!r}")

        capped = c.offer_code_block(sid, text="echo 4", language="sh")
        if capped.get("offered") != 3:
            raise cmuxError(f"pane should keep at most three cards: {capped!r}")

        try:
            c.offer_code_block(sid, text="   ", language="bash")
        except cmuxError:
            pass
        else:
            raise cmuxError("blank text should be rejected")

        cleared = c.offer_code_block(sid, clear=True)
        if cleared.get("offered") != 0:
            raise cmuxError(f"clear should remove every card: {cleared!r}")

    print("PASS: surface.offer_code_block offers, classifies, caps and clears")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
