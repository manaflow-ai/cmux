#!/usr/bin/env python3
"""v2 regression: core browser.* parity methods with handle refs."""

import os
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_selector_with_retry(c: cmux, target: str, selector: str, timeout_s: float = 5.0) -> None:
    """
    Browser splits can transiently race panel/webview mounting right after
    open_split. Retry a few times before failing to keep the test deterministic.
    """
    last_error = None
    for _ in range(3):
        try:
            c._call(
                "browser.wait",
                {"surface_id": target, "selector": selector, "timeout_ms": int(timeout_s * 1000)},
            )
            return
        except cmuxError as exc:
            if "timeout" not in str(exc):
                raise
            last_error = exc

        deadline = time.time() + timeout_s
        while time.time() < deadline:
            probe = c._call(
                "browser.eval",
                {"surface_id": target, "script": f"document.querySelector('{selector}') !== null"},
            ) or {}
            if bool(probe.get("value")):
                return
            time.sleep(0.05)
        time.sleep(0.2)

    if last_error is not None:
        raise last_error
    raise cmuxError(f"Timed out waiting for selector {selector}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        ident = c.identify()
        focused = ident.get("focused") or {}
        _must(isinstance(focused, dict), f"identify.focused should be dict: {focused}")
        _must(bool(focused.get("workspace_id") or focused.get("workspace_ref")), f"identify should return workspace handle: {focused}")
        _must(bool(focused.get("surface_id") or focused.get("surface_ref")), f"identify should return surface handle: {focused}")

        # Open browser split and prefer ref handles to validate v2 handle parsing.
        opened = c._call("browser.open_split", {"url": "about:blank"}) or {}
        sid = opened.get("surface_id")
        sref = opened.get("surface_ref")
        _must(bool(sid), f"browser.open_split returned no surface_id: {opened}")
        target = str(sid)
        if sref:
            _ = c._call("browser.url.get", {"surface_id": str(sref)})

        html = """
<!doctype html>
<html>
  <head><title>cmux-browser-p0</title></head>
  <body>
    <input id='name' value=''>
    <button id='btn' onclick="document.querySelector('#out').textContent = document.querySelector('#name').value || 'empty';">Go</button>
    <input type='checkbox' id='chk'>
    <select id='sel'><option value='a'>A</option><option value='b'>B</option></select>
    <div id='out'>ready</div>
  </body>
</html>
""".strip()
        data_url = "data:text/html," + urllib.parse.quote(html)

        c._call("browser.navigate", {"surface_id": target, "url": data_url})
        _wait_selector_with_retry(c, target, "#btn", timeout_s=5.0)

        c._call("browser.fill", {"surface_id": target, "selector": "#name", "text": "cmux"})
        c._call("browser.click", {"surface_id": target, "selector": "#btn"})

        out = c._call("browser.get.text", {"surface_id": target, "selector": "#out"}) or {}
        _must("cmux" in str(out.get("value", "")), f"Expected #out text to include 'cmux': {out}")

        c._call("browser.check", {"surface_id": target, "selector": "#chk"})
        checked = c._call("browser.is.checked", {"surface_id": target, "selector": "#chk"}) or {}
        _must(bool(checked.get("value")) is True, f"Expected checkbox checked: {checked}")

        c._call("browser.select", {"surface_id": target, "selector": "#sel", "value": "b"})
        val = c._call("browser.get.value", {"surface_id": target, "selector": "#sel"}) or {}
        _must(str(val.get("value", "")) == "b", f"Expected select value 'b': {val}")

        eval_res = c._call("browser.eval", {"surface_id": target, "script": "document.querySelector('#name').value"}) or {}
        _must(str(eval_res.get("value", "")) == "cmux", f"Expected eval value 'cmux': {eval_res}")

        snap = c._call("browser.snapshot", {"surface_id": target}) or {}
        snapshot_text = str(snap.get("snapshot") or "")
        _must("cmux-browser-p0" in snapshot_text, f"Expected snapshot text to include page title: {snap}")
        refs = snap.get("refs") or {}
        _must(isinstance(refs, dict), f"Expected snapshot refs dict: {snap}")
        _must(any(str(key).startswith("e") for key in refs.keys()), f"Expected eN refs in snapshot: {snap}")

        # Focus and focus-state checks can be slightly asynchronous.
        c._call("browser.focus_webview", {"surface_id": target})
        deadline = time.time() + 2.0
        focused_ok = False
        while time.time() < deadline:
            is_focused = c._call("browser.is_webview_focused", {"surface_id": target}) or {}
            if bool(is_focused.get("focused")):
                focused_ok = True
                break
            time.sleep(0.05)
        _must(focused_ok, "Expected browser.is_webview_focused=true after browser.focus_webview")

        shot = c._call("browser.screenshot", {"surface_id": target}) or {}
        b64 = str(shot.get("png_base64") or "")
        _must(len(b64) > 100, f"Expected non-trivial screenshot payload: len={len(b64)}")

    print("PASS: browser.* P0 methods work on cmux webview with ref handles")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
