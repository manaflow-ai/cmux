#!/usr/bin/env python3
"""Extended browser.* coverage for newly added agent-browser parity families."""

import base64
import http.server
import os
import socketserver
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmuxterm-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _expect_error_contains(label: str, fn, needle: str) -> None:
    try:
        fn()
    except cmuxError as exc:
        text = str(exc)
        if needle in text:
            return
        raise cmuxError(f"{label}: expected error containing {needle!r}, got: {text}")
    raise cmuxError(f"{label}: expected error containing {needle!r}, but call succeeded")


def _wait_selector(c: cmux, surface_id: str, selector: str, timeout_s: float = 6.0) -> None:
    timeout_ms = max(1, int(timeout_s * 1000.0))
    try:
        c._call("browser.wait", {"surface_id": surface_id, "selector": selector, "timeout_ms": timeout_ms})
        return
    except cmuxError as exc:
        if "timeout" not in str(exc):
            raise

    deadline = time.time() + timeout_s
    script = f"document.querySelector({selector!r}) !== null"
    while time.time() < deadline:
        probe = c._call("browser.eval", {"surface_id": surface_id, "script": script}) or {}
        if bool(probe.get("value")):
            return
        time.sleep(0.05)
    raise cmuxError(f"Timed out waiting for selector {selector}")


def _wait_function(c: cmux, surface_id: str, expression: str, timeout_s: float = 6.0) -> None:
    timeout_ms = max(1, int(timeout_s * 1000.0))
    try:
        c._call("browser.wait", {"surface_id": surface_id, "function": expression, "timeout_ms": timeout_ms})
        return
    except cmuxError as exc:
        if "timeout" not in str(exc):
            raise

    deadline = time.time() + timeout_s
    while time.time() < deadline:
        probe = c._call("browser.eval", {"surface_id": surface_id, "script": expression}) or {}
        if bool(probe.get("value")):
            return
        time.sleep(0.05)
    raise cmuxError(f"Timed out waiting for function: {expression}")


@contextmanager
def _local_test_server() -> str:
    with tempfile.TemporaryDirectory(prefix="cmux-browser-ext-") as root:
        root_path = Path(root)

        pixel = base64.b64decode("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
        (root_path / "tiny.gif").write_bytes(pixel)

        (root_path / "frame.html").write_text(
            """<!doctype html>
<html>
  <body>
    <button id="frame-btn" onclick="window.top.frameClicks = (window.top.frameClicks || 0) + 1">Frame Button</button>
    <div id="frame-text">frame-ready</div>
  </body>
</html>
""".strip(),
            encoding="utf-8",
        )

        (root_path / "second.html").write_text(
            """<!doctype html>
<html>
  <head>
    <title>cmux-browser-extended-second</title>
  </head>
  <body>
    <div id="second">second-page</div>
    <div id="style-target">style-target-second</div>
  </body>
</html>
""".strip(),
            encoding="utf-8",
        )

        (root_path / "index.html").write_text(
            """<!doctype html>
<html>
  <head>
    <title>cmux-browser-extended</title>
    <style>
      #style-target { color: rgb(255, 0, 0); }
    </style>
  </head>
  <body>
    <label for="name">Agent Name</label>
    <input id="name" placeholder="Type name" title="name-title" data-testid="name-field" />
    <img id="hero" alt="hero image" src="/tiny.gif" />
    <button id="action-btn" role="button" onclick="window.actionCount = (window.actionCount || 0) + 1; document.querySelector('#status').textContent = 'clicked';">Submit Action</button>
    <div id="status">ready</div>

    <ul id="rows">
      <li class="row">row-1</li>
      <li class="row">row-2</li>
      <li class="row">row-3</li>
    </ul>

    <iframe id="frame-a" src="/frame.html"></iframe>

    <div id="style-target">style target</div>

    <script>
      window.actionCount = 0;
      window.frameClicks = 0;
      window.triggerDialogs = function () {
        confirm('confirm-message');
        prompt('prompt-message', 'prompt-default');
        alert('alert-message');
        return true;
      };
      window.emitConsoleAndError = function () {
        console.log('cmux-console-entry');
        setTimeout(function () {
          throw new Error('cmux-boom');
        }, 0);
        return true;
      };
    </script>
  </body>
</html>
""".strip(),
            encoding="utf-8",
        )

        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=root, **kwargs)

            def log_message(self, format: str, *args) -> None:  # noqa: A003
                return

        class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
            allow_reuse_address = True
            daemon_threads = True

        server = ThreadedTCPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_address[1]}"
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=1.0)


def main() -> int:
    with _local_test_server() as base_url:
        index_url = f"{base_url}/index.html"
        second_url = f"{base_url}/second.html"

        with cmux(SOCKET_PATH) as c:
            opened = c._call("browser.open_split", {"url": "about:blank"}) or {}
            sid = str(opened.get("surface_id") or "")
            _must(bool(sid), f"browser.open_split returned no surface_id: {opened}")

            c._call("browser.navigate", {"surface_id": sid, "url": index_url})
            _wait_selector(c, sid, "#action-btn", timeout_s=7.0)

            find_role = c._call("browser.find.role", {"surface_id": sid, "role": "button", "name": "submit"}) or {}
            role_ref = str(find_role.get("element_ref") or "")
            _must(role_ref.startswith("@e"), f"Expected element_ref from find.role: {find_role}")
            c._call("browser.click", {"surface_id": sid, "selector": role_ref})
            status = c._call("browser.get.text", {"surface_id": sid, "selector": "#status"}) or {}
            _must(str(status.get("value") or "") == "clicked", f"Expected clicked status via element ref: {status}")

            find_cases = [
                ("browser.find.text", {"text": "row-2"}),
                ("browser.find.label", {"label": "Agent Name"}),
                ("browser.find.placeholder", {"placeholder": "Type name"}),
                ("browser.find.alt", {"alt": "hero image"}),
                ("browser.find.title", {"title": "name-title"}),
                ("browser.find.testid", {"testid": "name-field"}),
                ("browser.find.first", {"selector": "li.row"}),
                ("browser.find.last", {"selector": "li.row"}),
                ("browser.find.nth", {"selector": "li.row", "index": 1}),
            ]
            for method, extra in find_cases:
                params = {"surface_id": sid}
                params.update(extra)
                payload = c._call(method, params) or {}
                ref = str(payload.get("element_ref") or "")
                _must(ref.startswith("@e"), f"Expected element_ref from {method}: {payload}")

            c._call("browser.frame.select", {"surface_id": sid, "selector": "#frame-a"})
            _wait_function(c, sid, "document.querySelector('#frame-text') !== null", timeout_s=7.0)
            frame_text = c._call("browser.get.text", {"surface_id": sid, "selector": "#frame-text"}) or {}
            _must(str(frame_text.get("value") or "") == "frame-ready", f"Expected frame text: {frame_text}")
            c._call("browser.click", {"surface_id": sid, "selector": "#frame-btn"})
            c._call("browser.frame.main", {"surface_id": sid})
            frame_clicks = c._call("browser.eval", {"surface_id": sid, "script": "window.frameClicks || 0"}) or {}
            _must(int(frame_clicks.get("value") or 0) >= 1, f"Expected frame click count >= 1: {frame_clicks}")

            c._call("browser.console.list", {"surface_id": sid})
            c._call("browser.addscript", {"surface_id": sid, "script": "window.triggerDialogs(); true;"})
            d1 = c._call("browser.dialog.accept", {"surface_id": sid, "text": "agent-text"}) or {}
            d2 = c._call("browser.dialog.dismiss", {"surface_id": sid}) or {}
            d3 = c._call("browser.dialog.accept", {"surface_id": sid}) or {}
            _must(bool(d1.get("accepted")) is True, f"Expected first dialog accepted: {d1}")
            _must(bool(d2.get("accepted")) is False, f"Expected second dialog dismissed: {d2}")
            _must(bool(d3.get("accepted")) is True, f"Expected third dialog accepted: {d3}")
            _expect_error_contains(
                "dialog queue empty",
                lambda: c._call("browser.dialog.dismiss", {"surface_id": sid}),
                "not_found",
            )

            download_path = tempfile.NamedTemporaryFile(delete=False, prefix="cmux-download-", suffix=".txt").name
            os.unlink(download_path)

            def _write_download() -> None:
                time.sleep(0.2)
                Path(download_path).write_text("downloaded", encoding="utf-8")

            t = threading.Thread(target=_write_download, daemon=True)
            t.start()
            dl = c._call("browser.download.wait", {"surface_id": sid, "path": download_path, "timeout_ms": 5000}) or {}
            _must(bool(dl.get("downloaded")) is True, f"Expected download wait success: {dl}")

            c._call(
                "browser.cookies.set",
                {
                    "surface_id": sid,
                    "name": "cmux_cookie",
                    "value": "cookie_value",
                    "url": index_url,
                },
            )
            got_cookie = c._call("browser.cookies.get", {"surface_id": sid, "name": "cmux_cookie"}) or {}
            cookies = got_cookie.get("cookies") or []
            _must(any(str(row.get("name")) == "cmux_cookie" for row in cookies), f"Expected cmux_cookie in cookies.get: {got_cookie}")
            c._call("browser.cookies.clear", {"surface_id": sid, "name": "cmux_cookie"})
            got_after_clear = c._call("browser.cookies.get", {"surface_id": sid, "name": "cmux_cookie"}) or {}
            _must(len(got_after_clear.get("cookies") or []) == 0, f"Expected cookie cleared: {got_after_clear}")

            c._call("browser.storage.set", {"surface_id": sid, "type": "local", "key": "alpha", "value": "one"})
            c._call("browser.storage.set", {"surface_id": sid, "type": "session", "key": "beta", "value": "two"})
            storage_local = c._call("browser.storage.get", {"surface_id": sid, "type": "local", "key": "alpha"}) or {}
            storage_session = c._call("browser.storage.get", {"surface_id": sid, "type": "session", "key": "beta"}) or {}
            _must(str(storage_local.get("value") or "") == "one", f"Expected local storage value: {storage_local}")
            _must(str(storage_session.get("value") or "") == "two", f"Expected session storage value: {storage_session}")
            c._call("browser.storage.clear", {"surface_id": sid, "type": "session"})
            storage_session_after = c._call("browser.storage.get", {"surface_id": sid, "type": "session", "key": "beta"}) or {}
            _must(storage_session_after.get("value") is None, f"Expected session key cleared: {storage_session_after}")

            tabs_before = c._call("browser.tab.list", {"surface_id": sid}) or {}
            before_count = len(tabs_before.get("tabs") or [])
            tab_new = c._call("browser.tab.new", {"surface_id": sid, "url": second_url}) or {}
            sid2 = str(tab_new.get("surface_id") or "")
            _must(bool(sid2), f"Expected surface_id from browser.tab.new: {tab_new}")
            _wait_selector(c, sid2, "#second", timeout_s=7.0)
            tabs_after = c._call("browser.tab.list", {"surface_id": sid2}) or {}
            ids_after = {str(item.get("id") or "") for item in (tabs_after.get("tabs") or [])}
            _must(sid2 in ids_after and len(ids_after) >= before_count + 1, f"Expected new tab in list: {tabs_after}")
            c._call("browser.tab.switch", {"surface_id": sid2, "target_surface_id": sid})
            c._call("browser.tab.close", {"surface_id": sid, "target_surface_id": sid2})

            addscript_payload = c._call("browser.addscript", {"surface_id": sid, "script": "1 + 2"}) or {}
            _must(int(addscript_payload.get("value") or 0) == 3, f"Expected addscript value=3: {addscript_payload}")

            c._call("browser.addstyle", {"surface_id": sid, "css": "#style-target { color: rgb(0, 128, 0); }"})
            style_color = c._call("browser.get.styles", {"surface_id": sid, "selector": "#style-target", "property": "color"}) or {}
            _must("0, 128, 0" in str(style_color.get("value") or ""), f"Expected updated style color: {style_color}")

            c._call("browser.addinitscript", {"surface_id": sid, "script": "window.__cmuxInitMarker = 'init-ok';"})
            c._call("browser.navigate", {"surface_id": sid, "url": second_url})
            _wait_selector(c, sid, "#second", timeout_s=7.0)
            init_value = c._call("browser.eval", {"surface_id": sid, "script": "window.__cmuxInitMarker || ''"}) or {}
            _must(str(init_value.get("value") or "") == "init-ok", f"Expected init script marker after navigation: {init_value}")

            c._call("browser.navigate", {"surface_id": sid, "url": index_url})
            _wait_selector(c, sid, "#action-btn", timeout_s=7.0)
            c._call("browser.console.list", {"surface_id": sid})
            c._call("browser.addscript", {"surface_id": sid, "script": "window.emitConsoleAndError();"})
            time.sleep(0.35)
            console_entries = c._call("browser.console.list", {"surface_id": sid}) or {}
            errors_entries = c._call("browser.errors.list", {"surface_id": sid}) or {}
            _must(int(console_entries.get("count") or 0) >= 1, f"Expected console entries: {console_entries}")
            _must(int(errors_entries.get("count") or 0) >= 1, f"Expected error entries: {errors_entries}")
            c._call("browser.console.clear", {"surface_id": sid})
            console_after = c._call("browser.console.list", {"surface_id": sid}) or {}
            _must(int(console_after.get("count") or 0) == 0, f"Expected cleared console entries: {console_after}")

            c._call("browser.highlight", {"surface_id": sid, "selector": "#action-btn"})

            state_path = tempfile.NamedTemporaryFile(delete=False, prefix="cmux-state-", suffix=".json").name
            c._call("browser.storage.set", {"surface_id": sid, "type": "local", "key": "persist", "value": "yes"})
            c._call("browser.state.save", {"surface_id": sid, "path": state_path})
            c._call("browser.storage.set", {"surface_id": sid, "type": "local", "key": "persist", "value": "no"})
            c._call("browser.state.load", {"surface_id": sid, "path": state_path})
            persisted = c._call("browser.storage.get", {"surface_id": sid, "type": "local", "key": "persist"}) or {}
            _must(str(persisted.get("value") or "") == "yes", f"Expected state.load to restore storage key: {persisted}")

    print("PASS: extended browser parity families are green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
