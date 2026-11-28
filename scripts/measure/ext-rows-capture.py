"""Read a fixture marker from pixels of the isolated NIGHTLY's own window.

Uses the supported Computer Use capture path and its existing permissions. A refusal
is terminal: no settings changes, raw screen capture or debug-RPC fallback. Ordinary
window.screenshot masks extension web panes and cannot prove their contents drew.
"""
from __future__ import annotations

import json
import plistlib
import subprocess
import time
from pathlib import Path


def capture_marker(ctx, name: str, marker: str) -> dict:
    if not ctx.app:
        return {"drawn": False, "error": "drawing requires the running NIGHTLY copy"}
    with (ctx.app / "Contents/Info.plist").open("rb") as stream:
        bundle_id = plistlib.load(stream)["CFBundleIdentifier"]
    folder = ctx.work / name
    folder.mkdir(parents=True, exist_ok=True)
    receipt = {"drawn": False, "bundle_id": bundle_id, "marker": marker, "captures": []}
    # A side copy may own several native windows (including helper panels).
    # Discover only its windows, then let the content-only marker identify the
    # evidence window. Never guess from frontmost order, an empty title or size.
    discovery = ctx.ext(["--json", "computer-use", "call", "list_windows", "--args",
                         json.dumps({"app_id": bundle_id})], timeout=45)
    receipt["discovery"] = discovery
    body = discovery.get("json")
    windows = body.get("windows") if isinstance(body, dict) else None
    if discovery.get("exit") != 0 or not isinstance(windows, list):
        return {**receipt, "error": "Computer Use did not list the isolated windows"}
    owned = [w for w in windows if isinstance(w, dict) and w.get("app_id") == bundle_id]
    if not owned:
        return {**receipt, "error": "No isolated app windows to capture"}
    # This is a macOS NIGHTLY harness: CGWindowIDs are positive integers.
    # Validate the complete set before capturing anything, including denials.
    ids = [str(w.get("window_id", "")) for w in owned]
    if any(w.get("denied") for w in owned):
        return {**receipt, "error": "Computer Use denied an isolated window"}
    if any(not wid.isascii() or not wid.isdecimal() or int(wid) <= 0 for wid in ids) or len(set(ids)) != len(ids):
        return {**receipt, "error": "Computer Use returned invalid or duplicate window IDs"}
    ocr = ctx.work / "fixture-ocr"
    source = Path(__file__).resolve().parents[1] / "e2e/ocr.swift"
    if not ocr.exists():
        built = subprocess.run(["xcrun", "swiftc", str(source), "-o", str(ocr)],
                               capture_output=True, text=True, timeout=120)
        if built.returncode:
            return {**receipt, "error": "OCR helper compile failed", "stderr": built.stderr[-2000:]}
    # Bounded settling for a newly opened page. Each attempt keeps its image and
    # OCR text; an error stops immediately, even when an earlier image succeeded.
    for index in range(3):
        for window_id in ids:
            png = folder / f"{index}-{window_id}.png"
            capture = ctx.ext(["computer-use", "screenshot", "--window", window_id,
                               "--out", str(png)], timeout=45)
            attempt = {"window_id": window_id, "capture": capture, "path": str(png)}
            receipt["captures"].append(attempt)
            if capture.get("exit") != 0 or not png.is_file():
                receipt["error"] = "Computer Use did not capture the isolated window"
                return receipt
            read = subprocess.run([str(ocr), str(png)], capture_output=True, text=True, timeout=30)
            attempt.update(ocr_exit=read.returncode, text=read.stdout, stderr=read.stderr[-2000:])
            png.with_suffix(".txt").write_text(read.stdout)
            if read.returncode:
                receipt["error"] = "OCR failed"
                return receipt
            if marker in " ".join(read.stdout.split()):
                receipt.update(drawn=True, window_id=window_id)
                return receipt
        if index < 2:
            time.sleep(1)
    return receipt
