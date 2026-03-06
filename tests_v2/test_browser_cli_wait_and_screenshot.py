#!/usr/bin/env python3
"""Regression: browser wait/snapshot and screenshot CLI return usable file locations."""

import glob
import json
import os
import subprocess
import sys
import tempfile
import urllib.parse
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

    fixed = os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux"
    )
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(
        os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"),
        recursive=True,
    )
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli(cli: str, *args: str) -> subprocess.CompletedProcess[str]:
    cmd = [cli, "--socket", SOCKET_PATH, *args]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc


def main() -> int:
    cli = _find_cli_binary()

    with cmux(SOCKET_PATH) as c:
        opened = c._call("browser.open_split", {"url": "about:blank"}) or {}
        target = str(opened.get("surface_id") or opened.get("surface_ref") or "")
        _must(target != "", f"browser.open_split returned no surface handle: {opened}")

        html = """
<!doctype html>
<html>
  <head><title>cmux-browser-cli-regression</title></head>
  <body>
    <main>
      <h1>browser cli regression</h1>
      <p id="status">ready</p>
    </main>
  </body>
</html>
""".strip()
        data_url = "data:text/html;charset=utf-8," + urllib.parse.quote(html)
        c._call("browser.navigate", {"surface_id": target, "url": data_url})

        wait_proc = _run_cli(
            cli,
            "browser",
            target,
            "wait",
            "--load-state",
            "interactive",
            "--timeout-ms",
            "5000",
        )
        _must(wait_proc.stdout.strip() == "OK", f"Expected browser wait OK output: {wait_proc.stdout!r}")

        snapshot_payload = c._call("browser.snapshot", {"surface_id": target}) or {}
        refs = snapshot_payload.get("refs") or {}
        _must(isinstance(refs, dict) and len(refs) > 0, f"Expected snapshot refs for ref-based wait coverage: {snapshot_payload}")
        ref_selector = str(next(iter(refs.keys())))
        ref_wait_proc = _run_cli(
            cli,
            "browser",
            target,
            "wait",
            "--selector",
            ref_selector,
            "--timeout-ms",
            "2000",
        )
        _must(ref_wait_proc.stdout.strip() == "OK", f"Expected browser wait to resolve snapshot refs: {ref_wait_proc.stdout!r}")

        snapshot_proc = _run_cli(cli, "browser", target, "snapshot", "--compact")
        _must(
            snapshot_proc.stdout.strip().startswith("- document"),
            f"Expected snapshot command to succeed with structured output: {snapshot_proc.stdout!r}",
        )

        screenshot_json_proc = _run_cli(cli, "browser", target, "screenshot", "--json")
        screenshot_json_text = screenshot_json_proc.stdout.strip()
        payload = json.loads(screenshot_json_text or "{}")

        _must("\\/" not in screenshot_json_text, f"Expected screenshot JSON without escaped slashes: {screenshot_json_text!r}")
        _must("png_base64" not in payload, f"Expected screenshot JSON to omit png_base64 when file location is available: {payload}")

        screenshot_path = str(payload.get("path") or "")
        screenshot_url = str(payload.get("url") or "")
        _must(screenshot_path.startswith("/"), f"Expected screenshot path in JSON payload: {payload}")
        _must(screenshot_url.startswith("file://"), f"Expected screenshot file URL in JSON payload: {payload}")
        _must(Path(screenshot_path).is_file(), f"Expected screenshot file to exist: {payload}")

        out_dir = Path(tempfile.mkdtemp(prefix="cmux-browser-screenshot-cli-")) / "nested" / "dir"
        out_path = out_dir / "capture.png"
        screenshot_out_proc = _run_cli(
            cli,
            "browser",
            target,
            "screenshot",
            "--out",
            str(out_path),
        )
        _must(screenshot_out_proc.stdout.strip() == f"OK {out_path}", f"Expected --out to print the requested path: {screenshot_out_proc.stdout!r}")
        _must("file://" not in screenshot_out_proc.stdout, f"Expected --out to print a path, not a file URL: {screenshot_out_proc.stdout!r}")
        _must(out_path.is_file(), f"Expected --out screenshot file to exist: {out_path}")

    print("PASS: browser CLI wait/snapshot and screenshot output work end-to-end")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
