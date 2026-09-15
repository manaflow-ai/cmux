#!/usr/bin/env python3
"""Extended browser.* coverage for newly added agent-browser parity families."""

import base64
import http.server
import json
import os
import socketserver
import sys
import tempfile
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


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


def _wait_for(pred, timeout_s: float = 6.0, step_s: float = 0.05) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if pred():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


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
def _local_test_server(download_filename: str) -> str:
    with tempfile.TemporaryDirectory(prefix="cmux-browser-ext-") as root:
        root_path = Path(root)

        pixel = base64.b64decode("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
        (root_path / "tiny.gif").write_bytes(pixel)
        (root_path / "download.bin").write_bytes(b"cmux browser download history\n")

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

        index_html = """<!doctype html>
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
    <a id="download-link" href="/download.bin">Download fixture</a>

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
""".strip()
        (root_path / "index.html").write_text(index_html, encoding="utf-8")

        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=root, **kwargs)

            def do_GET(self) -> None:  # noqa: N802
                if self.path.split("?", 1)[0] == "/download.bin":
                    body = (root_path / "download.bin").read_bytes()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Disposition", f'attachment; filename="{download_filename}"')
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                super().do_GET()

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
    download_filename = f"cmux-browser-history-{uuid.uuid4().hex}.bin"
    with _local_test_server(download_filename) as base_url:
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

            c._call("browser.click", {"surface_id": sid, "selector": "#download-link"})
            actual_download_path = ""
            listed_before_wait: dict = {}
            deadline = time.time() + 10.0
            while time.time() < deadline:
                listed_before_wait = c._call(
                    "browser.download.list",
                    {"surface_id": sid, "limit": 25},
                ) or {}
                rows = listed_before_wait.get("downloads") or []
                if any(
                    str(row.get("filename") or "") == download_filename
                    and str(row.get("status") or "") == "saved"
                    for row in rows
                ):
                    break
                time.sleep(0.05)
            rows_before_wait = listed_before_wait.get("downloads") or []
            downloaded_before_wait = next(
                (row for row in rows_before_wait if str(row.get("filename") or "") == download_filename),
                None,
            )
            _must(downloaded_before_wait is not None, f"Download was not discoverable without a waiter: {listed_before_wait}")
            _must(str(downloaded_before_wait.get("status") or "") == "saved", f"Download did not finish: {downloaded_before_wait}")
            actual_download_path = str(downloaded_before_wait.get("path") or "")
            _must(bool(actual_download_path) and Path(actual_download_path).is_file(), f"Download path was not real: {downloaded_before_wait}")

            waited = c._call("browser.download.wait", {"surface_id": sid, "timeout_ms": 10000}) or {}
            waited_event = waited.get("download") or {}
            _must(str(waited_event.get("download_id") or "") == str(downloaded_before_wait.get("download_id") or ""), f"Wait consumed a different download: {waited}")
            listed_after_wait = c._call("browser.download.list", {"surface_id": sid}) or {}
            listed_again = c._call("browser.download.list", {"surface_id": sid}) or {}
            _must(listed_after_wait == listed_again, f"Repeated download listings changed history: {listed_after_wait} vs {listed_again}")
            _must(any(str(row.get("path") or "") == actual_download_path for row in (listed_after_wait.get("downloads") or [])), f"Wait consumption lost download history: {listed_after_wait}")
            os.unlink(actual_download_path)
            listed_after_delete = c._call("browser.download.list", {"surface_id": sid}) or {}
            deleted_row = next(
                (row for row in (listed_after_delete.get("downloads") or []) if str(row.get("path") or "") == actual_download_path),
                None,
            )
            _must(deleted_row is not None and deleted_row.get("path_exists") is False, f"Deleted download path was not reported explicitly: {listed_after_delete}")

            second_opened = c._call("browser.open_split", {"url": "about:blank", "focus": False}) or {}
            second_sid = str(second_opened.get("surface_id") or "")
            _must(bool(second_sid), f"Second browser surface did not open: {second_opened}")
            second_history = c._call("browser.download.list", {"surface_id": second_sid}) or {}
            _must(not (second_history.get("downloads") or []), f"Download history leaked across surfaces: {second_history}")

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
            try:
                os.unlink(download_path)
            except Exception:
                pass
            try:
                if actual_download_path.startswith(str(Path.home() / "Downloads")):
                    os.unlink(actual_download_path)
            except Exception:
                pass

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

            http_only_name = "cmux_cookie_http_only"
            c._call(
                "browser.cookies.set",
                {
                    "surface_id": sid,
                    "name": http_only_name,
                    "value": "secret_cookie_value",
                    "url": index_url,
                    "httpOnly": True,
                },
            )
            got_http_only = c._call("browser.cookies.get", {"surface_id": sid, "name": http_only_name}) or {}
            http_only_rows = got_http_only.get("cookies") or []
            http_only_row = next(
                (row for row in http_only_rows if str(row.get("name")) == http_only_name),
                None,
            )
            _must(http_only_row is not None, f"Expected HttpOnly cookie in cookies.get: {got_http_only}")
            _must(bool(http_only_row.get("httpOnly")) is True, f"Expected httpOnly=true in cookies.get: {got_http_only}")
            _must(bool(http_only_row.get("hostOnly")) is True, f"Expected hostOnly=true in cookies.get: {got_http_only}")
            filtered_http_only = c._call(
                "browser.cookies.get",
                {"surface_id": sid, "httpOnly": True},
            ) or {}
            filtered_names = {str(row.get("name")) for row in (filtered_http_only.get("cookies") or [])}
            _must(http_only_name in filtered_names, f"Expected httpOnly filter to retain cookie: {filtered_http_only}")
            filtered_non_http_only = c._call(
                "browser.cookies.get",
                {"surface_id": sid, "httpOnly": False},
            ) or {}
            non_http_only_names = {str(row.get("name")) for row in (filtered_non_http_only.get("cookies") or [])}
            _must("cmux_cookie" in non_http_only_names, f"Expected non-HttpOnly cookie in filter=false result: {filtered_non_http_only}")
            _must(http_only_name not in non_http_only_names, f"Expected httpOnly filter=false to exclude cookie: {filtered_non_http_only}")
            document_cookie = c._call(
                "browser.eval",
                {"surface_id": sid, "script": "document.cookie"},
            ) or {}
            _must(
                http_only_name not in str(document_cookie.get("value") or ""),
                f"HttpOnly cookie leaked to document.cookie: {document_cookie}",
            )

            c._call("browser.cookies.clear", {"surface_id": sid, "name": "cmux_cookie"})
            c._call("browser.cookies.clear", {"surface_id": sid, "name": http_only_name})
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

            def _console_ready() -> bool:
                entries = c._call("browser.console.list", {"surface_id": sid}) or {}
                return int(entries.get("count") or 0) >= 1

            def _errors_ready() -> bool:
                entries = c._call("browser.errors.list", {"surface_id": sid}) or {}
                return int(entries.get("count") or 0) >= 1

            _wait_for(_console_ready, timeout_s=7.0)
            _wait_for(_errors_ready, timeout_s=7.0)
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
            state_cookie_name = "cmux_state_host_only"
            other_state_cookie_name = "cmux_state_other_host"
            domain_state_cookie_name = "cmux_state_domain"
            c._call(
                "browser.cookies.set",
                {
                    "surface_id": sid,
                    "name": state_cookie_name,
                    "value": "state-secret",
                    "url": index_url,
                    "httpOnly": True,
                },
            )
            c._call(
                "browser.cookies.set",
                {
                    "surface_id": sid,
                    "name": other_state_cookie_name,
                    "value": "other-state-secret",
                    "url": index_url.replace("127.0.0.1", "localhost"),
                    "httpOnly": True,
                },
            )
            c._call(
                "browser.cookies.set",
                {
                    "surface_id": sid,
                    "name": domain_state_cookie_name,
                    "value": "domain-state-secret",
                    "url": "https://example.test/",
                    "domain": ".example.test",
                    "secure": True,
                    "httpOnly": True,
                },
            )
            c._call("browser.state.save", {"surface_id": sid, "path": state_path})
            state_snapshot = json.loads(Path(state_path).read_text(encoding="utf-8"))
            saved_state_rows = state_snapshot.get("cookies") or []
            saved_state_names = {str(row.get("name")) for row in saved_state_rows}
            _must(
                {state_cookie_name, other_state_cookie_name, domain_state_cookie_name} <= saved_state_names,
                f"Expected both host-only cookies in state snapshot: {state_snapshot}",
            )
            for saved_row in saved_state_rows:
                if str(saved_row.get("name")) in {state_cookie_name, other_state_cookie_name}:
                    _must(bool(saved_row.get("hostOnly")) is True, f"Expected hostOnly state row: {saved_row}")
                if str(saved_row.get("name")) == domain_state_cookie_name:
                    _must(bool(saved_row.get("hostOnly")) is False, f"Expected domain-scoped state row: {saved_row}")
            c._call("browser.storage.set", {"surface_id": sid, "type": "local", "key": "persist", "value": "no"})
            c._call("browser.cookies.clear", {"surface_id": sid, "name": state_cookie_name})
            c._call("browser.cookies.clear", {"surface_id": sid, "name": other_state_cookie_name})
            c._call("browser.cookies.clear", {"surface_id": sid, "name": domain_state_cookie_name})
            c._call("browser.state.load", {"surface_id": sid, "path": state_path})
            persisted = c._call("browser.storage.get", {"surface_id": sid, "type": "local", "key": "persist"}) or {}
            _must(str(persisted.get("value") or "") == "yes", f"Expected state.load to restore storage key: {persisted}")
            restored_state_cookie = c._call(
                "browser.cookies.get", {"surface_id": sid, "name": state_cookie_name}
            ) or {}
            restored_state_rows = restored_state_cookie.get("cookies") or []
            restored_state_row = next(
                (row for row in restored_state_rows if str(row.get("name")) == state_cookie_name),
                None,
            )
            _must(restored_state_row is not None, f"Expected state.load to restore cookie: {restored_state_cookie}")
            _must(bool(restored_state_row.get("hostOnly")) is True, f"Expected restored hostOnly cookie: {restored_state_cookie}")
            _must(bool(restored_state_row.get("httpOnly")) is True, f"Expected restored HttpOnly cookie: {restored_state_cookie}")
            restored_other_cookie = c._call(
                "browser.cookies.get", {"surface_id": sid, "name": other_state_cookie_name}
            ) or {}
            restored_other_rows = restored_other_cookie.get("cookies") or []
            restored_other_row = next(
                (row for row in restored_other_rows if str(row.get("name")) == other_state_cookie_name),
                None,
            )
            _must(restored_other_row is not None, f"Expected second state cookie: {restored_other_cookie}")
            _must(bool(restored_other_row.get("hostOnly")) is True, f"Expected second hostOnly cookie: {restored_other_cookie}")
            _must(
                "localhost" in str(restored_other_row.get("domain") or "").lower(),
                f"Expected second cookie to retain localhost scope: {restored_other_cookie}",
            )
            restored_domain_cookie = c._call(
                "browser.cookies.get", {"surface_id": sid, "name": domain_state_cookie_name}
            ) or {}
            restored_domain_rows = restored_domain_cookie.get("cookies") or []
            restored_domain_row = next(
                (row for row in restored_domain_rows if str(row.get("name")) == domain_state_cookie_name),
                None,
            )
            _must(restored_domain_row is not None, f"Expected domain-scoped state cookie: {restored_domain_cookie}")
            _must(bool(restored_domain_row.get("hostOnly")) is False, f"Expected domain scope after restore: {restored_domain_cookie}")
            _must(bool(restored_domain_row.get("httpOnly")) is True, f"Expected domain HttpOnly after restore: {restored_domain_cookie}")
            _must(
                str(restored_domain_row.get("domain") or "").lstrip(".").lower() == "example.test",
                f"Expected domain cookie to retain example.test scope: {restored_domain_cookie}",
            )
            try:
                os.unlink(state_path)
            except Exception:
                pass

    print("PASS: extended browser parity families are green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
