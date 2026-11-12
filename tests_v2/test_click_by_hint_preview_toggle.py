#!/usr/bin/env python3
"""Regression: Click by Hint is a preview anyone can turn on from the palette.

Hint mode (Cmd+J) stays opt-in, but it was reachable only through a remote
feature flag or a debug-only local override: no Settings row, no palette
entry. The command palette now finds a "Click by Hint" Beta Features toggle;
turning it on makes Cmd+J label the window's controls, and turning it off
again restores the default.

Run where the app can be frontmost (a whole capture mini or a local tagged
build), with no `window-hints-release` override, never against the user's
default socket:
  CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock python3 tests_v2/test_click_by_hint_preview_toggle.py
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError

COMMAND_ID = "palette.toggleSetting.windowHints"


def _wait_until(predicate, timeout_s=4.0, interval_s=0.05):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            if predicate():
                return True
        except cmuxError:
            pass
        time.sleep(interval_s)
    return False


def _hints(c: cmux) -> dict:
    try:
        return c._call("debug.window_hints", {}) or {}
    except cmuxError as error:
        return {"error": str(error)}


def _palette_visible(c: cmux, window_id: str) -> bool:
    return bool((c._call("debug.command_palette.visible", {"window_id": window_id}) or {}).get("visible"))


def _set_palette_visible(c: cmux, window_id: str, visible: bool) -> None:
    if _palette_visible(c, window_id) != visible:
        c._call("debug.command_palette.toggle", {"window_id": window_id})
        _wait_until(lambda: _palette_visible(c, window_id) == visible)


def _run_toggle(c: cmux, window_id: str) -> list:
    """Searches the palette for Click by Hint; runs the toggle if it is the top row. Returns the rows."""
    _set_palette_visible(c, window_id, False)
    _set_palette_visible(c, window_id, True)
    _wait_until(lambda: bool((c._call("debug.command_palette.rename_input.selection", {"window_id": window_id}) or {}).get("focused")))
    c.simulate_shortcut("cmd+a")
    c.simulate_type(">click by hint")
    _wait_until(lambda: "click by hint" in str(c.command_palette_results(window_id=window_id).get("query") or "").lower())
    time.sleep(0.3)
    rows = c.command_palette_results(window_id=window_id, limit=8).get("results") or []
    if rows and str(rows[0].get("command_id") or "") == COMMAND_ID:
        c.simulate_shortcut("enter")
        time.sleep(0.5)
    _set_palette_visible(c, window_id, False)
    return rows


def main() -> int:
    c = cmux()
    c.connect()
    if not c.ping():
        raise cmuxError("socket ping failed")
    c.activate_app()
    window_id = c.current_window()
    c.focus_window(window_id)
    time.sleep(1.0)

    results = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'} {name} {detail}".rstrip())

    check("Click by Hint is off by default", _hints(c).get("enabled") is False, str(_hints(c)))

    rows = _run_toggle(c, window_id)
    ids = [str(r.get("command_id") or "") for r in rows]
    check("the palette's top result for 'click by hint' is the preview toggle", ids[:1] == [COMMAND_ID], str(rows[:3]))
    check("the toggle turns Click by Hint on", _wait_until(lambda: _hints(c).get("enabled") is True), str(_hints(c)))

    c.focus_window(window_id)
    time.sleep(0.3)
    c.simulate_shortcut("cmd+j")
    time.sleep(0.6)
    shown = _hints(c)
    check("cmd+j then labels the window's controls", shown.get("active") is True and len(shown.get("hints") or []) > 1, str(shown)[:300])
    c.simulate_shortcut("escape")
    time.sleep(0.3)

    if ids[:1] == [COMMAND_ID]:
        _run_toggle(c, window_id)
    check("toggling again turns it back off", _wait_until(lambda: _hints(c).get("enabled") is False), str(_hints(c)))

    passed = sum(results)
    print(f"RESULT {passed}/{len(results)}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
