#!/usr/bin/env python3
"""Regression: browser.cert_bypass get/set socket commands."""

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
        # get returns a bool
        result = c._call("browser.cert_bypass", {"action": "get"})
        _must(isinstance(result.get("enabled"), bool),
              f"browser.cert_bypass get should return enabled bool, got: {result}")

        initial = result["enabled"]

        try:
            # set true
            r = c._call("browser.cert_bypass", {"action": "set", "value": "true"})
            _must(r.get("enabled") is True, f"set true should return enabled=true, got: {r}")

            # get reflects the change
            r = c._call("browser.cert_bypass", {"action": "get"})
            _must(r.get("enabled") is True, f"get after set true should return true, got: {r}")

            # set false
            r = c._call("browser.cert_bypass", {"action": "set", "value": "false"})
            _must(r.get("enabled") is False, f"set false should return enabled=false, got: {r}")

            r = c._call("browser.cert_bypass", {"action": "get"})
            _must(r.get("enabled") is False, f"get after set false should return false, got: {r}")
        finally:
            # restore initial state even if assertions fail
            c._call("browser.cert_bypass", {"action": "set", "value": "true" if initial else "false"})

        print("PASS: browser.cert_bypass get/set")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
