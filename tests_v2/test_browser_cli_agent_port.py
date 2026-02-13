#!/usr/bin/env python3
"""CLI parity smoke checks for extended browser command families."""

import functools
import glob
import http.server
import json
import os
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmuxterm-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmuxterm-tests-v2/Build/Products/Debug/cmuxterm")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmuxterm"), recursive=True)
    candidates += glob.glob("/tmp/cmuxterm-*/Build/Products/Debug/cmuxterm")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmuxterm CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli_json(cli: str, args: list[str], retries: int = 4) -> dict:
    last_merged = ""
    for attempt in range(1, retries + 1):
        proc = subprocess.run(
            [cli, "--socket", SOCKET_PATH, "--json"] + args,
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0:
            try:
                return json.loads(proc.stdout or "{}")
            except Exception as exc:  # noqa: BLE001
                raise cmuxError(f"Invalid CLI JSON output for {' '.join(args)}: {proc.stdout!r} ({exc})")

        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        last_merged = merged
        if "Command timed out" in merged and attempt < retries:
            time.sleep(0.2)
            continue
        raise cmuxError(f"CLI failed ({' '.join(args)}): {merged}")

    raise cmuxError(f"CLI failed ({' '.join(args)}): {last_merged}")


def _run_cli_text(cli: str, args: list[str], retries: int = 3) -> str:
    last_merged = ""
    for attempt in range(1, retries + 1):
        proc = subprocess.run(
            [cli, "--socket", SOCKET_PATH] + args,
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0:
            return (proc.stdout or "").strip()

        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        last_merged = merged
        if "Command timed out" in merged and attempt < retries:
            time.sleep(0.2)
            continue
        raise cmuxError(f"CLI failed ({' '.join(args)}): {merged}")

    raise cmuxError(f"CLI failed ({' '.join(args)}): {last_merged}")

def _run_cli_expect_failure(cli: str, args: list[str], needles: list[str]) -> None:
    proc = subprocess.run(
        [cli, "--socket", SOCKET_PATH, "--json"] + args,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode == 0:
        raise cmuxError(f"Expected CLI failure for {' '.join(args)}, but it succeeded: {proc.stdout}")
    merged = f"{proc.stdout}\n{proc.stderr}"
    if not any(needle in merged for needle in needles):
        raise cmuxError(f"Expected CLI failure containing one of {needles!r} for {' '.join(args)}, got: {merged}")


@contextmanager
def _local_test_server() -> str:
    with tempfile.TemporaryDirectory(prefix="cmux-browser-cli-") as root:
        root_path = Path(root)
        (root_path / "index.html").write_text(
            """<!doctype html>
<html>
  <body>
    <label for=\"name\">CLI Label</label>
    <input id=\"name\" placeholder=\"cli-place\" title=\"cli-title\" data-testid=\"cli-field\" />
    <button id=\"btn\" role=\"button\">Click</button>
    <ul><li class=\"row\">row-a</li><li class=\"row\">row-b</li></ul>
    <div id=\"style-target\">style</div>
  </body>
</html>
""".strip(),
            encoding="utf-8",
        )

        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(root_path))

        class _TCP(socketserver.TCPServer):
            allow_reuse_address = True

        with _TCP(("127.0.0.1", 0), handler) as httpd:
            port = int(httpd.server_address[1])
            thread = threading.Thread(target=httpd.serve_forever, daemon=True)
            thread.start()
            try:
                yield f"http://127.0.0.1:{port}/index.html"
            finally:
                httpd.shutdown()
                thread.join(timeout=2)


def main() -> int:
    cli = _find_cli_binary()

    with _local_test_server() as page_url:
        opened = _run_cli_json(cli, ["browser", "open", page_url])
        surface = str(opened.get("surface_ref") or opened.get("surface_id") or "")
        _must(bool(surface), f"browser open returned no surface handle: {opened}")
        _must(surface.startswith("surface:"), f"Expected short surface ref from browser open, got: {opened}")

        _run_cli_json(cli, ["browser", surface, "wait", "--load-state", "complete", "--timeout-ms", "15000"])
        snapshot_text = _run_cli_text(cli, ["browser", surface, "snapshot", "--interactive"])
        _must("ref=e" in snapshot_text, f"Expected snapshot text with refs from CLI: {snapshot_text!r}")

        identify = _run_cli_json(cli, ["identify"])
        focused = identify.get("focused") or {}
        workspace = str(
            identify.get("workspace_ref")
            or identify.get("workspace_id")
            or focused.get("workspace_ref")
            or focused.get("workspace_id")
            or ""
        )
        _must(bool(workspace), f"Expected workspace handle from identify: {identify}")

        opened_routed = _run_cli_json(cli, ["browser", "open", page_url, "--workspace", workspace])
        routed_surface = str(opened_routed.get("surface_ref") or opened_routed.get("surface_id") or "")
        _must(bool(routed_surface), f"browser open --workspace returned no surface handle: {opened_routed}")
        _run_cli_json(cli, ["browser", routed_surface, "wait", "--load-state", "complete", "--timeout-ms", "15000"])
        routed_url_payload = _run_cli_json(cli, ["browser", routed_surface, "url"])
        routed_url = str(routed_url_payload.get("url") or "")
        _must(routed_url.startswith(page_url), f"Expected routed URL to start with page URL, got: {routed_url_payload}")
        _must("--workspace" not in routed_url and "--window" not in routed_url, f"Routing flags leaked into URL: {routed_url_payload}")

        find_text = _run_cli_json(cli, ["browser", surface, "find", "text", "row-b"])
        _must(str(find_text.get("element_ref") or "").startswith("@e"), f"Expected element_ref from find text: {find_text}")

        # Exercise frame command routing through expected not_found + main reset.
        _run_cli_expect_failure(cli, ["browser", surface, "frame", "#missing-frame"], ["not_found"])
        _run_cli_json(cli, ["browser", surface, "frame", "main"])

        _run_cli_json(cli, ["browser", surface, "cookies", "set", "cli_cookie", "cookie_val", "--url", "https://example.com"])
        cookies_get = _run_cli_json(cli, ["browser", surface, "cookies", "get", "--name", "cli_cookie"])
        _must(any(str(row.get("name")) == "cli_cookie" for row in (cookies_get.get("cookies") or [])), f"Expected cli_cookie via CLI: {cookies_get}")
        _run_cli_json(cli, ["browser", surface, "cookies", "clear", "--name", "cli_cookie"])

        _run_cli_json(cli, ["browser", surface, "storage", "local", "set", "alpha", "one"])
        storage_get = _run_cli_json(cli, ["browser", surface, "storage", "local", "get", "alpha"])
        _must(str(storage_get.get("value") or "") == "one", f"Expected storage value via CLI: {storage_get}")

        _run_cli_json(cli, ["browser", surface, "fill", "#name", "--text", "weather"])
        cleared = _run_cli_json(cli, ["browser", surface, "fill", "#name", "--text", "", "--snapshot-after"])
        _must(bool(cleared.get("post_action_snapshot")), f"Expected post_action_snapshot from fill --snapshot-after: {cleared}")
        cleared_val = _run_cli_json(cli, ["browser", surface, "get", "value", "#name"])
        _must(str(cleared_val.get("value") or "") == "", f"Expected fill with empty text to clear input: {cleared_val}")

        _run_cli_expect_failure(cli, ["browser", surface, "click", "#does-not-exist"], ["not_found", "snapshot"])
        _run_cli_json(cli, ["browser", surface, "storage", "local", "clear", "--key", "alpha"])

        tabs_before = _run_cli_json(cli, ["browser", surface, "tab", "list"])
        tab_new = _run_cli_json(cli, ["browser", surface, "tab", "new", "about:blank"])
        tab_surface = str(tab_new.get("surface_ref") or tab_new.get("surface_id") or "")
        _must(bool(tab_surface), f"Expected tab surface handle via CLI: {tab_new}")
        tabs_after = _run_cli_json(cli, ["browser", tab_surface, "tab", "list"])
        _must(len(tabs_after.get("tabs") or []) >= len(tabs_before.get("tabs") or []) + 1, "Expected tab count increase via CLI")
        _run_cli_json(cli, ["browser", tab_surface, "tab", "switch", surface])
        _run_cli_json(cli, ["browser", surface, "tab", "close", tab_surface])

        addscript = _run_cli_json(cli, ["browser", surface, "addscript", "1 + 2"])
        _must(int(addscript.get("value") or 0) == 3, f"Expected addscript value=3 via CLI: {addscript}")
        _run_cli_json(cli, ["browser", surface, "addinitscript", "window.__cliInit = \"ok\";"])

        _run_cli_json(cli, ["browser", surface, "addstyle", "#style-target { color: rgb(0, 128, 0); }"])
        styles = _run_cli_json(cli, ["browser", surface, "get", "styles", "#style-target", "--property", "color"])
        _must("0, 128, 0" in str(styles.get("value") or ""), f"Expected style color via CLI: {styles}")

        _run_cli_json(cli, ["browser", surface, "console", "list"])
        _run_cli_json(cli, ["browser", surface, "console", "clear"])
        _run_cli_json(cli, ["browser", surface, "errors", "list"])
        _run_cli_json(cli, ["browser", surface, "highlight", "#btn"])

        state_file = tempfile.NamedTemporaryFile(delete=False, prefix="cmux-cli-state-", suffix=".json").name
        saved = _run_cli_json(cli, ["browser", surface, "state", "save", state_file])
        _must(str(saved.get("path") or "") == state_file, f"Expected saved state path via CLI: {saved}")
        _run_cli_json(cli, ["browser", surface, "state", "load", state_file])

        _run_cli_expect_failure(cli, ["browser", surface, "viewport", "800", "600"], ["not_supported"])

        legacy_new = _run_cli_text(cli, ["new-pane", "--type", "browser", "--direction", "right", "--url", page_url])
        _must("surface:" in legacy_new, f"Expected new-pane output to prefer short surface refs, got: {legacy_new!r}")

    print("PASS: browser CLI parity commands are wired for extended families")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
