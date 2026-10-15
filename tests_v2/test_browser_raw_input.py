#!/usr/bin/env python3
"""browser.input_mouse and browser.input_keyboard deliver trusted events on WebKit."""

import os
import sys
import time
from pathlib import Path
from urllib.parse import quote

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")

PAGE = """<!doctype html><html><body style="margin:0">
<button id="b" style="position:absolute;left:20px;top:20px;width:120px;height:60px">target</button>
<input id="t" style="position:absolute;left:20px;top:120px;width:200px">
<script>
window.log = [];
const b = document.getElementById('b');
for (const type of ['mousedown', 'mouseup', 'click', 'dblclick', 'contextmenu']) {
  b.addEventListener(type, (e) => log.push([type, e.isTrusted, e.button, e.detail, e.shiftKey]));
}
document.addEventListener('wheel', (e) => log.push(['wheel', e.isTrusted, Math.sign(e.deltaY)]));
const t = document.getElementById('t');
t.addEventListener('keydown', (e) => log.push(['keydown', e.isTrusted, e.key, e.metaKey]));
</script></body></html>"""


def _must(condition: bool, message: str) -> None:
    if not condition:
        raise cmuxError(message)


def _eval(client: cmux, sid: str, script: str):
    return (client._call("browser.eval", {"surface_id": sid, "script": script}) or {}).get("value")


def _until(client: cmux, sid: str, script: str, predicate, label: str):
    deadline = time.monotonic() + 5
    value = None
    while time.monotonic() < deadline:
        value = _eval(client, sid, script)
        if predicate(value):
            return value
    raise cmuxError(f"{label}: {value!r}")


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        opened = client._call("browser.open_split", {"url": "data:text/html," + quote(PAGE)}) or {}
        sid = str(opened.get("surface_id") or "")
        _must(bool(sid), f"browser.open_split returned no surface_id: {opened}")
        _until(client, sid, "!!document.getElementById('b')", bool, "page never loaded")

        result = client._call("browser.input_mouse", {"surface_id": sid, "args": ["click", "60", "40", "left", "2"]}) or {}
        _must(result.get("pointer") == {"x": 60, "y": 40}, f"unexpected pointer: {result}")
        log = _until(client, sid, "log", lambda v: v and any(e[0] == "dblclick" for e in v), "no dblclick")
        clicks = [e for e in log if e[0] in ("mousedown", "mouseup", "click", "dblclick")]
        _must(all(e[1] is True for e in clicks), f"events not trusted: {clicks}")
        _must([e[0] for e in clicks] == ["mousedown", "mouseup", "click", "mousedown", "mouseup", "click", "dblclick"], f"order: {clicks}")

        _eval(client, sid, "log.length = 0; true")
        client._call("browser.input_mouse", {"surface_id": sid, "type": "mousePressed", "x": 60, "y": 40, "button": "left", "modifiers": 8})
        client._call("browser.input_mouse", {"surface_id": sid, "args": ["up"]})
        log = _until(client, sid, "log", lambda v: v and any(e[0] == "click" for e in v), "no shift click")
        _must(log[0][4] is True, f"shift modifier missing: {log}")

        _eval(client, sid, "log.length = 0; true")
        client._call("browser.input_mouse", {"surface_id": sid, "args": ["wheel", "120"]})
        _until(client, sid, "log", lambda v: v and v[0][:3] == ["wheel", True, 1], "no trusted wheel")

        # Drags are refused instead of starting a system drag session.
        client._call("browser.input_mouse", {"surface_id": sid, "args": ["down"]})
        try:
            client._call("browser.input_mouse", {"surface_id": sid, "args": ["move", "200", "200"]})
            raise cmuxError("a move with the button held was accepted")
        except cmuxError as exc:
            _must("not_supported" in str(exc), f"unexpected drag error: {exc}")
        client._call("browser.input_mouse", {"surface_id": sid, "args": ["up"]})

        client._call("browser.input_mouse", {"surface_id": sid, "args": ["click", "100", "130"]})
        _eval(client, sid, "log.length = 0; true")
        client._call("browser.input_keyboard", {"surface_id": sid, "args": ["type", "hi"]})
        client._call("browser.input_keyboard", {"surface_id": sid, "args": ["inserttext", "é!"]})
        value = _until(client, sid, "document.getElementById('t').value", lambda v: v == "hié!", "typed text")
        keys = _eval(client, sid, "log")
        _must([e[:3] for e in keys] == [["keydown", True, "h"], ["keydown", True, "i"]], f"keydowns: {keys}")

        # A key typed after inserted text lands before the reply.
        _eval(client, sid, "document.getElementById('t').value = ''; true")
        client._call("browser.input_keyboard", {"surface_id": sid, "args": ["type", "é b"]})
        typed = _eval(client, sid, "document.getElementById('t').value")
        _must(typed == "é b", f"keys after inserted text arrived late: {typed!r}")

        try:
            client._call("browser.input_mouse", {"surface_id": sid, "args": ["hover"]})
            raise cmuxError("unknown mouse command was accepted")
        except cmuxError as exc:
            _must("invalid_params" in str(exc), f"unexpected error: {exc}")

        print(f"PASS: raw input on WebKit (typed {value!r})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
