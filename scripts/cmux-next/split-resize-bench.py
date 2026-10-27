#!/usr/bin/env python3
"""A Chromium page beside a split divider a person drags (scripts/ci/frame-pacing/split_resize.py).

Launches a tagged DEV app (bench_launch.py), splits right, opens the probe page in a Chromium tab in the
right pane and drags the divider through the real mouse path while every display frame is sampled; then
one more drag, held open, with a window snapshot every 12 moves (strip-NN.png) and one after it landed
(strip-landed.png). Writes the judge's verdict to --json and everything to --out. Report only.

On the fleet (through the allowlisted entry, which builds the app at the commit):

    cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \
      --ref <sha> --arg=--suite=split-resize --artifact artifacts/split-spring/report.json

Usage: split-resize-bench.py --app APP --out DIR [--json PATH] [--tag TAG]
"""

from __future__ import annotations

import argparse, base64, json, os, sys
from pathlib import Path

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
sys.path.insert(0, os.path.join(here, "..", "ci", "frame-pacing"))
from bench_launch import BenchApp  # noqa: E402
import golden  # noqa: E402
import split_resize  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--tag")
opts, _ = parser.parse_known_args()

out = Path(opts.out)
out.mkdir(parents=True, exist_ok=True)
app = BenchApp(opts.app, out=str(out), window=(80, 80, 1100, 720))
report: dict = {}
try:
    app.launch()
    driver = golden.Driver(app.socket, out)
    driver.call("debug.motion", {"action": "speed", "value": "fast"})
    driver.call("debug.motion", {"action": "reduce", "value": False})
    split_resize.drive(driver, out, strip=True)
    data = json.loads((out / "split_resize.json").read_text())
    refresh = next((float(d.get("refresh_ms") or 0) for d in data.get("drags") or [] if float(d.get("refresh_ms") or 0) > 0),
                   1000 / 60)
    report = split_resize.judge(data, refresh)
    report["log"] = driver.log
    # The strip goes back inside the report (the step returns one file): base64 PNGs, at most 12.
    report["strip"] = []
    for shot in (data.get("strip") or [])[:12]:
        path = out / shot["path"]
        report["strip"].append({"step": shot["step"], "error": (shot.get("result") or {}).get("error"),
                                "png": base64.b64encode(path.read_bytes()).decode() if path.is_file() else None})
    print(split_resize.markdown_row(report))
    print("SPLIT-RESIZE " + json.dumps({k: v for k, v in report.items() if k not in ("drags", "strip")}))
finally:
    app.stop()
    if opts.json:
        Path(opts.json).parent.mkdir(parents=True, exist_ok=True)
        Path(opts.json).write_text(json.dumps(report, indent=1) + "\n")
