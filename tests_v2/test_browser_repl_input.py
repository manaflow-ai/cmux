#!/usr/bin/env python3
"""E2E: `cmux browser repl --eval` can drive browser input through the JS adapter."""

from __future__ import annotations

import glob
import http.server
import json
import os
import shutil
import subprocess
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")
REPO_ROOT = Path(__file__).resolve().parents[1]
CLIENT_PATH = REPO_ROOT / "Resources" / "browser-repl" / "cmux-browser-client.mjs"
HTML = """<!doctype html>
<html>
  <head><title>cmux repl e2e</title></head>
  <body>
    <label>Name <input id="name" /></label>
    <button id="go" onclick="document.querySelector('#status').textContent = document.querySelector('#name').value + ':clicked'">Go</button>
    <div id="status">idle</div>
  </body>
</html>"""


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


class _HTMLHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        body = HTML.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        pass


def _run_cli_repl(cli: str, url: str) -> dict:
    _must(shutil.which("node") is not None, "node is required for cmux browser repl")
    _must(CLIENT_PATH.is_file(), f"Missing browser REPL client at {CLIENT_PATH}")

    script = f"""
const tab = await browser.tabs.new({{ url: {json.dumps(url)} }});
await tab.playwright.locator("#name").fill("cmux");
await tab.playwright.locator("#go").click();
const title = await tab.playwright.title();
const status = await tab.playwright.locator("#status").textContent();
const value = await tab.playwright.locator("#name").inputValue();
const shown = await cmuxBrowserClient.call("browser.cursor.get", {{ surface_id: tab.surfaceId }});
await tab.playwright.hideCursor();
const hidden = await cmuxBrowserClient.call("browser.cursor.get", {{ surface_id: tab.surfaceId }});
console.log(JSON.stringify({{
  surfaceId: tab.surfaceId,
  title,
  status,
  value,
  shown: shown.cursor,
  hidden: hidden.cursor
}}));
""".strip()

    env = dict(os.environ)
    env["CMUX_SOCKET_PATH"] = SOCKET_PATH
    env["CMUX_BROWSER_CLIENT_PATH"] = str(CLIENT_PATH)
    def parse_json_result(proc: subprocess.CompletedProcess[str], label: str) -> dict:
        if proc.returncode != 0:
            merged = f"{proc.stdout}\n{proc.stderr}".strip()
            raise cmuxError(f"{label} failed: {merged}")
        for line in reversed(proc.stdout.splitlines()):
            line = line.strip()
            if line.startswith("{") and line.endswith("}"):
                return json.loads(line)
        raise cmuxError(f"{label} did not print JSON result: {proc.stdout!r}")

    proc = subprocess.run(
        [cli, "--socket", SOCKET_PATH, "browser", "repl", "--eval", script],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=30,
    )
    result = parse_json_result(proc, "browser repl")
    surface_id = result.get("surfaceId")
    _must(isinstance(surface_id, str) and surface_id, f"browser repl did not return surface id: {result}")

    bind_script = """
const title = await page.title();
const status = await page.locator("#status").textContent();
console.log(JSON.stringify({
  boundSurfaceId: tab.surfaceId,
  boundTitle: title,
  boundStatus: status
}));
await tab.close();
""".strip()
    bind_proc = subprocess.run(
        [cli, "--socket", SOCKET_PATH, "browser", surface_id, "repl", "--eval", bind_script],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=30,
    )
    result.update(parse_json_result(bind_proc, "browser surface-bound repl"))
    return result


def main() -> int:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _HTMLHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        url = f"http://127.0.0.1:{server.server_address[1]}/"
        result = _run_cli_repl(_find_cli_binary(), url)
    finally:
        server.shutdown()
        thread.join(timeout=2)
    _must(result.get("status") == "cmux:clicked", f"Expected click handler status, got: {result}")
    _must(result.get("value") == "cmux", f"Expected filled input value, got: {result}")
    _must(result.get("title") == "cmux repl e2e", f"Expected page.title() string, got: {result}")
    _must(result.get("boundTitle") == "cmux repl e2e", f"Expected bound page.title() string, got: {result}")
    _must(result.get("boundStatus") == "cmux:clicked", f"Expected bound REPL to target existing surface, got: {result}")
    _must(result.get("boundSurfaceId") == result.get("surfaceId"), f"Expected bound REPL surface id to match, got: {result}")
    shown = result.get("shown") or {}
    hidden = result.get("hidden") or {}
    _must(shown.get("visible") is True, f"Expected cursor visible after locator input/click, got: {result}")
    _must(float(shown.get("x") or 0) > 0, f"Expected cursor x to move to element center, got: {result}")
    _must(float(shown.get("y") or 0) > 0, f"Expected cursor y to move to element center, got: {result}")
    _must(hidden.get("visible") is False, f"Expected cursor hidden after hideCursor, got: {result}")
    print("PASS: browser repl JS adapter drives fill/click and cursor state")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
