#!/usr/bin/env python3
"""Regression: hint mode (Cmd+J) works with no flag override (cx-zjtn.7).

Hint mode shipped off behind `window-hints-release` until its labels were
styled. Turning it on by default means Cmd+J labels the window's controls in a
build with no local override and no remote flag value. Run it against a build
without `cmux.flags.override.window-hints-release` written, where the app can be
frontmost (a whole capture mini or a local tagged build), never against the
user's default socket:
  CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock python3 tests_v2/test_window_hints_on_by_default.py
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


def _hints(c: cmux) -> dict:
    for _ in range(20):
        try:
            return c._call("debug.window_hints", {}) or {}
        except cmuxError as error:
            if "rate_limited" not in str(error):
                return {"error": str(error)}
            time.sleep(0.3)
    return {}


def main() -> int:
    c = cmux()
    c.connect()
    if not c.ping():
        raise cmuxError("socket ping failed")
    c.activate_app()
    c.focus_window(c.current_window())
    time.sleep(1.0)

    results = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'} {name} {detail}".rstrip())

    before = _hints(c)
    check("hint mode is enabled with no override", before.get("enabled") is True, str(before))
    c.simulate_shortcut("cmd+j")
    time.sleep(0.5)
    shown = _hints(c)
    check("cmd+j shows labels", shown.get("active") is True and len(shown.get("hints") or []) > 1, str(shown)[:400])
    c.simulate_shortcut("escape")
    time.sleep(0.3)
    check("escape hides the labels", _hints(c).get("active") is False)

    passed = sum(results)
    print(f"RESULT {passed}/{len(results)}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
