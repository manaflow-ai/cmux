#!/usr/bin/env python3
"""A Chromium page beside a split divider a person drags (scripts/ci/frame-pacing/split_resize.py).

Launches a tagged DEV app (bench_launch.py), splits right, opens the probe page in a Chromium tab in the
right pane and drags the divider through the real mouse path while every display frame is sampled; then
one more drag, held open, with a window snapshot every 12 moves (strip-NN.png) and one after it landed
(strip-landed.png). Writes the judge's verdict to --json and everything to --out. Report only.

On the fleet (through the allowlisted entry, which builds the app at the commit):

    cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \
      --ref <sha> --arg=--suite=split-resize --artifact artifacts/split-spring/report.json

With --variants=live,hold,synced each `browserResize.dragResize` value runs in its own launch of the
same build, back to back, through a Debug Settings override file (CMUX_NEXT_DEBUG_TUNABLES_FILE).

Usage: split-resize-bench.py --app APP --out DIR [--json PATH] [--tag TAG] [--variants=live,hold,synced]
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
# `browserResize.dragResize` values to measure, each in its own launch of the same build, back to back
# (live: AsyncLiveResize, the behaviour before cmux#25842; hold; synced: AsyncLiveResize off).
parser.add_argument("--variants", default="")
opts, _ = parser.parse_known_args()
VARIANTS = ("live", "hold", "synced", "resizeSync", "live-hosted", "resizeSync-hosted")  # MEASURE-ONLY: -hosted also turns layerHosting on
variants = [v for v in opts.variants.split(",") if v] or [None]
for variant in variants:
    if variant is not None and variant not in VARIANTS:
        sys.exit(f"--variants: {variant!r} is not one of {', '.join(VARIANTS)}")

out = Path(opts.out)
out.mkdir(parents=True, exist_ok=True)


def strip_png(path: Path) -> str | None:
    """A recording frame for the report: the window snapshot scaled to 900 px wide (sips), base64."""
    if not path.is_file():
        return None
    small = path.with_suffix(".small.png")
    scaled = subprocess.run(["/usr/bin/sips", "-Z", "900", str(path), "--out", str(small)], capture_output=True)
    return base64.b64encode((small if scaled.returncode == 0 and small.is_file() else path).read_bytes()).decode()


def measure(variant: str | None, folder: Path) -> dict:
    """One launch: the harness's drags and its recording drag, judged."""
    folder.mkdir(parents=True, exist_ok=True)
    env = {}
    if variant is not None:
        tunables = folder / "debug-tunables.json"
        values = {"browserResize.dragResize": variant.removesuffix("-hosted")}
        if variant.endswith("-hosted"):
            values["browserResize.layerHosting"] = True
        tunables.write_text(json.dumps({"version": 1, "values": values}))
        env["CMUX_NEXT_DEBUG_TUNABLES_FILE"] = str(tunables)
    app = BenchApp(opts.app, out=str(folder), env=env, window=(80, 80, 1100, 720))
    report: dict = {"variant": variant}
    try:
        app.launch()
        driver = golden.Driver(app.socket, folder)
        driver.call("debug.motion", {"action": "speed", "value": "fast"})
        driver.call("debug.motion", {"action": "reduce", "value": False})
        split_resize.drive(driver, folder, strip=True)
        data = json.loads((folder / "split_resize.json").read_text())
        refresh = next((float(d.get("refresh_ms") or 0) for d in data.get("drags") or [] if float(d.get("refresh_ms") or 0) > 0),
                       1000 / 60)
        report.update(split_resize.judge(data, refresh))
        report["log"] = driver.log
        # The recording goes back inside the report (the step returns one file).
        report["strip"] = [{"step": shot["step"], "error": (shot.get("result") or {}).get("error"),
                            "png": strip_png(folder / shot["path"])} for shot in (data.get("strip") or [])[:20]]
        print(f"[{variant or 'default'}] " + split_resize.markdown_row(report))
        print("SPLIT-RESIZE " + json.dumps({k: v for k, v in report.items() if k not in ("drags", "strip", "log")}))
    except (Exception, SystemExit) as error:  # one variant's failure (BenchApp's launch error is a SystemExit) still reports the others
        report["error"] = repr(error)
        print(f"[{variant or 'default'}] failed: {error!r}")
    finally:
        app.stop()
    return report


reports = [measure(variant, out / (variant or "default")) for variant in variants]
result = reports[0] if variants == [None] else {"variants": reports}
if opts.json:
    Path(opts.json).parent.mkdir(parents=True, exist_ok=True)
    Path(opts.json).write_text(json.dumps(result, indent=1) + "\n")
# No variant measured: the step fails (its report, written above, says why).
if not any(report.get("measured") for report in reports):
    sys.exit(1)
