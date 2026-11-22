#!/usr/bin/env python3
"""A page beside a pane a person resizes (scripts/ci/frame-pacing/split_resize.py).

Launches a tagged DEV app (bench_launch.py), splits right, opens the page in the right pane (`--pane`: a Chromium
tab with the probe page, or an agent chat) and resizes that pane (`--gesture`: the divider dragged through the real
mouse path, the sidebar toggled, the window's corner dragged) while every display frame is sampled; then one more
divider drag, held open, with a window snapshot every 12 moves (strip-NN.png) and one after it landed
(strip-landed.png). Writes the judge's verdict to --json and everything to --out. Report only.

On the fleet (through the allowlisted entry, which builds the app at the commit):

    cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \
      --ref <sha> --arg=--suite=split-resize --arg=--pane=all --arg=--gesture=all \
      --artifact artifacts/split-spring/report.json

Each pane runs in its own launch of the same build, back to back, with every gesture in it. The
`browserResize.dragResize` variants this bench once took are gone: no tunable picks how a pane drag
resizes a page now (CEFTabContentView.paneResizeGestureDidChange, CEFLayerHosting).

Usage: split-resize-bench.py --app APP --out DIR [--json PATH] [--tag TAG] [--pane=browser,chat|all]
       [--gesture=divider,sidebar,window-edge|all]
"""

from __future__ import annotations

import argparse, base64, json, os, subprocess, sys
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
# The pages to measure, each in its own launch of the same build, back to back.
parser.add_argument("--pane", default="browser")
# The gestures that resize the page's pane, in each launch.
parser.add_argument("--gesture", default="divider")
opts, _ = parser.parse_known_args()


def pick(value: str, known: tuple[str, ...], flag: str) -> list[str]:
    """The comma-separated values of `flag` (`all`: every one of `known`), each checked."""
    picked = list(known) if value == "all" else [v for v in value.split(",") if v]
    for v in picked:
        if v not in known:
            sys.exit(f"{flag}: {v!r} is not one of {', '.join(known)} or all")
    return picked or [known[0]]


panes = pick(opts.pane, split_resize.PANES, "--pane")
gestures = pick(opts.gesture, split_resize.GESTURES, "--gesture")

out = Path(opts.out)
out.mkdir(parents=True, exist_ok=True)


def strip_png(path: Path) -> str | None:
    """A recording frame for the report: the window snapshot scaled to 900 px wide (sips), base64."""
    if not path.is_file():
        return None
    small = path.with_suffix(".small.png")
    scaled = subprocess.run(["/usr/bin/sips", "-Z", "900", str(path), "--out", str(small)], capture_output=True)
    return base64.b64encode((small if scaled.returncode == 0 and small.is_file() else path).read_bytes()).decode()


def measure(pane: str, folder: Path) -> dict:
    """One launch: the harness's gestures on `pane` and its recording drag, judged."""
    folder.mkdir(parents=True, exist_ok=True)
    app = BenchApp(opts.app, out=str(folder), window=(80, 80, 1100, 720))
    report: dict = {"pane": pane, "requested_gestures": gestures}
    try:
        app.launch()
        driver = golden.Driver(app.socket, folder)
        driver.call("debug.motion", {"action": "speed", "value": "fast"})
        driver.call("debug.motion", {"action": "reduce", "value": False})
        split_resize.drive(driver, folder, strip=True, pane=pane, gestures=gestures)
        data = json.loads((folder / "split_resize.json").read_text())
        refresh = next((float(d.get("refresh_ms") or 0) for d in data.get("drags") or [] if float(d.get("refresh_ms") or 0) > 0),
                       1000 / 60)
        report.update(split_resize.judge(data, refresh))
        report["log"] = driver.log
        # The recording goes back inside the report (the step returns one file).
        report["strip"] = [{"step": shot["step"], "error": (shot.get("result") or {}).get("error"),
                            "png": strip_png(folder / shot["path"])} for shot in (data.get("strip") or [])[:20]]
        # One row per gesture (`gestures`: the judge's summary of each), or why nothing was measured.
        for verdict in (report.get("gestures") or {}).values() if report.get("measured") else [report]:
            print(f"[{pane}] " + split_resize.markdown_row(verdict))
        print("SPLIT-RESIZE " + json.dumps({k: v for k, v in report.items() if k not in ("drags", "strip", "log")}))
    except (Exception, SystemExit) as error:  # one pane's failure (BenchApp's launch error is a SystemExit) still reports the others
        report["error"] = repr(error)
        print(f"[{pane}] failed: {error!r}")
    finally:
        app.stop()
    return report


reports = [measure(pane, out / pane) for pane in panes]
result = reports[0] if len(reports) == 1 else {"panes": reports}
if opts.json:
    Path(opts.json).parent.mkdir(parents=True, exist_ok=True)
    Path(opts.json).write_text(json.dumps(result, indent=1) + "\n")
# No pane measured: the step fails (its report, written above, says why).
if not any(report.get("measured") for report in reports):
    sys.exit(1)
