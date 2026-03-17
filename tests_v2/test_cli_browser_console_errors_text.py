#!/usr/bin/env python3
"""Regression: CLI browser console/errors commands should print entries in text mode."""

from __future__ import annotations

import glob
import http.server
import os
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"), recursive=True)
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli(cli: str, args: list[str]) -> str:
    proc = subprocess.run(
        [cli, "--socket", SOCKET_PATH, *args],
        capture_output=True,
        text=True,
        check=False,
        env=dict(os.environ),
    )
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(args)}): {merged}")
    return proc.stdout.strip()


def _wait_for(pred, timeout_s: float = 6.0, step_s: float = 0.05) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if pred():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


def _wait_selector(c: cmux, surface_id: str, selector: str, timeout_s: float = 6.0) -> None:
    timeout_ms = max(1, int(timeout_s * 1000.0))
    c._call("browser.wait", {"surface_id": surface_id, "selector": selector, "timeout_ms": timeout_ms})


def _open_server() -> tuple[str, socketserver.TCPServer, threading.Thread, tempfile.TemporaryDirectory[str]]:
    root = tempfile.TemporaryDirectory(prefix="cmux-browser-cli-logs-")
    root_path = Path(root.name)
    (root_path / "index.html").write_text(
        """<!doctype html>
<html>
  <body>
    <div id="ready">ready</div>
    <script>
      window.emitLogs = function () {
        console.log('cmux-console-entry');
        setTimeout(function () { throw new Error('cmux-browser-boom'); }, 0);
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
            super().__init__(*args, directory=root.name, **kwargs)

        def log_message(self, format: str, *args) -> None:  # noqa: A003
            return

    class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
        allow_reuse_address = True
        daemon_threads = True

    server = ThreadedTCPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base_url = f"http://127.0.0.1:{server.server_address[1]}"
    return base_url, server, thread, root


def main() -> int:
    cli = _find_cli_binary()
    base_url, server, thread, root = _open_server()
    workspace_id = ""
    try:
        with cmux(SOCKET_PATH) as c:
            opened = c._call("browser.open_split", {"url": f"{base_url}/index.html"}) or {}
            workspace_id = str(opened.get("workspace_id") or "")
            surface_id = str(opened.get("surface_id") or "")
            _must(bool(surface_id), f"browser.open_split returned no surface_id: {opened}")

            _wait_selector(c, surface_id, "#ready", timeout_s=7.0)
            c._call("browser.eval", {"surface_id": surface_id, "script": "window.emitLogs()"})

            def console_ready() -> bool:
                payload = c._call("browser.console.list", {"surface_id": surface_id}) or {}
                return int(payload.get("count") or 0) >= 1

            def errors_ready() -> bool:
                payload = c._call("browser.errors.list", {"surface_id": surface_id}) or {}
                return int(payload.get("count") or 0) >= 1

            _wait_for(console_ready, timeout_s=7.0)
            _wait_for(errors_ready, timeout_s=7.0)

            console_output = _run_cli(cli, ["browser", surface_id, "console"])
            _must("cmux-console-entry" in console_output, f"browser console text mode should print entries: {console_output!r}")
            _must(console_output != "OK", f"browser console text mode should not collapse to OK: {console_output!r}")

            errors_output = _run_cli(cli, ["browser", surface_id, "errors"])
            _must("cmux-browser-boom" in errors_output, f"browser errors text mode should print entries: {errors_output!r}")
            _must(errors_output != "OK", f"browser errors text mode should not collapse to OK: {errors_output!r}")
    finally:
        try:
            server.shutdown()
            server.server_close()
            thread.join(timeout=1.0)
        except Exception:
            pass
        root.cleanup()
        if workspace_id:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass

    print("PASS: browser console/errors text mode prints returned entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
