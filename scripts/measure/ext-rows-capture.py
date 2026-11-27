"""Read a fixture marker from pixels of the isolated NIGHTLY's own window.

Uses the supported Computer Use capture path and its existing permissions. A refusal
is terminal: no settings changes, raw screen capture or debug-RPC fallback. Ordinary
window.screenshot masks extension web panes and cannot prove their contents drew.
"""
from __future__ import annotations

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
        png = folder / f"{index}.png"
        capture = ctx.ext(["computer-use", "screenshot", "--window", bundle_id,
                           "--out", str(png)], timeout=45)
        attempt = {"capture": capture, "path": str(png)}
        receipt["captures"].append(attempt)
        if capture.get("exit") != 0 or not png.is_file():
            receipt["error"] = "Computer Use did not capture the isolated window"
            return receipt
        read = subprocess.run([str(ocr), str(png)], capture_output=True, text=True, timeout=30)
        attempt.update(ocr_exit=read.returncode, text=read.stdout, stderr=read.stderr[-2000:])
        (folder / f"{index}.txt").write_text(read.stdout)
        if read.returncode:
            receipt["error"] = "OCR failed"
            return receipt
        if marker in " ".join(read.stdout.split()):
            receipt["drawn"] = True
            return receipt
        if index < 2:
            time.sleep(1)
    return receipt
