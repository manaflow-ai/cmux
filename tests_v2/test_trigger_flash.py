#!/usr/bin/env python3
"""
Regression test for surface.trigger_flash (v2).

This is intended for LLM/agent workflows where the agent can visually indicate
which surface it's operating on without relying on unstable indexes.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        sid = c.new_surface(panel_type="terminal")
        c.focus_surface(sid)

        c.reset_flash_counts()
        base = c.flash_count(sid)

        c.trigger_flash(sid)
        time.sleep(0.05)

        after = c.flash_count(sid)
        if after <= base:
            raise cmuxError(f"Expected flash count to increase (base={base}, after={after})")

    print("PASS: surface.trigger_flash increments flash counter")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

