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
resizeSync is #26595's mode; a build without it reads the override as unknown and runs its default.
With --pages=probe,heavy each variant also runs once per page (split_resize.HEAVY_PAGE: a long page
whose every width is a real relayout), each in its own launch. --drag-hz=120,480 runs each of those once per
pointer event rate (events a drag sends per second), each in its own launch. Every launch also records one drag
out and back (debug.window_record JPEG frames under its folder's record/).

Usage: split-resize-bench.py --app APP --out DIR [--json PATH] [--tag TAG] [--variants=live,hold,synced,resizeSync]
                             [--pages=probe,heavy] [--drag-hz=120,480] [--cpu-load=N]

--cpu-load=N keeps N busy processes (one core each) running through every launch, the way a loaded
Mac with many agents, renderers and builds runs; they are this script's own children and end with it.
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
parser.add_argument("--pages", default="probe")
parser.add_argument("--drag-hz", default="120")
parser.add_argument("--cpu-load", type=int, default=0)
# --cpu-load-class=background runs the busy processes under `taskpolicy -b` (background QoS: what cmux could give the
# agents, daemons and builds it starts), to see whether the page keeps up when the load yields to it.
parser.add_argument("--cpu-load-class", choices=("default", "background"), default="default")
# --profile: two more drags per launch under `sample` (app and busiest renderer); the heaviest stacks go in the report.
parser.add_argument("--profile", action="store_true")
opts, _ = parser.parse_known_args()
VARIANTS = ("live", "hold", "synced", "resizeSync")
variants = [v for v in opts.variants.split(",") if v] or [None]
for variant in variants:
    if variant is not None and variant not in VARIANTS:
        sys.exit(f"--variants: {variant!r} is not one of {', '.join(VARIANTS)}")
pages = [page for page in opts.pages.split(",") if page] or ["probe"]
for page in pages:
    if page not in ("probe", "heavy"):
        sys.exit(f"--pages: {page!r} is not one of probe, heavy")
rates = [float(hz) for hz in opts.drag_hz.split(",") if hz]
if not rates or any(not 30 <= hz <= 2000 for hz in rates):
    sys.exit(f"--drag-hz: {opts.drag_hz!r} is not a list of rates from 30 to 2000")

out = Path(opts.out)
out.mkdir(parents=True, exist_ok=True)


def strip_png(path: Path) -> str | None:
    """A recording frame for the report: the window snapshot scaled to 900 px wide (sips), base64."""
    if not path.is_file():
        return None
    small = path.with_suffix(".small.png")
    scaled = subprocess.run(["/usr/bin/sips", "-Z", "900", str(path), "--out", str(small)], capture_output=True)
    return base64.b64encode((small if scaled.returncode == 0 and small.is_file() else path).read_bytes()).decode()


def recording_frames(folder: Path, count: int = 24) -> list[dict]:
    """`count` frames spread evenly over the recorded drag (record/frame-NNNNN.jpg), each scaled to 900 px wide,
    with their host time: the recording goes back inside the report too."""
    frames = sorted((folder / "record").glob("frame-*.jpg"))
    try:
        times = json.loads((folder / "record" / "frames.json").read_text()).get("times")
    except (OSError, ValueError, AttributeError):
        times = None
    picked = frames[::max(1, len(frames) // count)][:count] if frames else []
    shown = []
    for frame in picked:
        index = int(frame.stem.split("-")[-1])
        shown.append({"frame": index, "t": times[index] if isinstance(times, list) and index < len(times) else None,
                      "png": strip_png(frame)})
    return shown


def heaviest(path: Path, limit: int = 160_000) -> str | None:
    """The call graph of a `sample` report, cut to `limit` bytes (its heaviest stacks come first)."""
    if not path.is_file():
        return None
    text = path.read_text(errors="replace")
    start = text.find("Call graph:")
    return text[start if start >= 0 else 0:][:limit]


def measure(variant: str | None, folder: Path, page: str = "probe", hz: float = 120) -> dict:
    """One launch: the harness's drags and its recording drag, judged."""
    folder.mkdir(parents=True, exist_ok=True)
    env = {}
    if variant is not None:
        tunables = folder / "debug-tunables.json"
        tunables.write_text(json.dumps({"version": 1, "values": {"browserResize.dragResize": variant}}))
        env["CMUX_NEXT_DEBUG_TUNABLES_FILE"] = str(tunables)
    app = BenchApp(opts.app, out=str(folder), env=env, window=(80, 80, 1100, 720))
    report: dict = {"variant": variant, "page": page, "drag_hz": hz}
    try:
        app.launch()
        driver = golden.Driver(app.socket, folder)
        driver.call("debug.motion", {"action": "speed", "value": "fast"})
        driver.call("debug.motion", {"action": "reduce", "value": False})
        split_resize.drive(driver, folder, strip=True, page_kind=page, pid=app.process.pid if app.process else None,
                           record=True, drag_hz=hz, profile=opts.profile)
        data = json.loads((folder / "split_resize.json").read_text())
        refresh = next((float(d.get("refresh_ms") or 0) for d in data.get("drags") or [] if float(d.get("refresh_ms") or 0) > 0),
                       1000 / 60)
        report.update(split_resize.judge(data, refresh))
        if not report.get("measured"):
            # Why nothing was measured: what the split and the page open answered (the step returns one file).
            report["why"] = {key: json.dumps(data.get(key), default=str)[:1500] for key in ("error", "split", "opened")}
        report["log"] = driver.log
        # The recording goes back inside the report (the step returns one file).
        report["strip"] = [{"step": shot["step"], "error": (shot.get("result") or {}).get("error"),
                            "png": strip_png(folder / shot["path"])} for shot in (data.get("strip") or [])[:20]]
        report["recorded"] = data.get("recorded")
        report["recording"] = recording_frames(folder)
        report["profile"] = {name: heaviest(folder / f"sample-{name}.txt") for name in ("app", "renderer")}
        print(f"[{variant or 'default'} {page} {hz:g} Hz] " + split_resize.markdown_row(report))
        print("SPLIT-RESIZE " + json.dumps({k: v for k, v in report.items() if k not in ("drags", "strip", "log")}))
    except (Exception, SystemExit) as error:  # one variant's failure (BenchApp's launch error is a SystemExit) still reports the others
        report["error"] = repr(error)
        print(f"[{variant or 'default'} {page} {hz:g} Hz] failed: {error!r}")
    finally:
        app.stop()
    return report


busy = [sys.executable, "-c", "while True: pass"]
if opts.cpu_load_class == "background":
    busy = ["/usr/sbin/taskpolicy", "-b"] + busy
load = [subprocess.Popen(busy, stdin=subprocess.DEVNULL) for _ in range(max(0, opts.cpu_load))]
try:
    reports = [measure(variant, out / ((variant or "default") + ("" if page == "probe" else f"-{page}")
                                       + ("" if hz == 120 else f"-{hz:g}hz")), page, hz)
               for variant in variants for page in pages for hz in rates]
finally:
    for busy in load:
        busy.kill()
    for busy in load:
        busy.wait()
for report in reports:
    report["cpu_load"] = opts.cpu_load
    report["cpu_load_class"] = opts.cpu_load_class
result = reports[0] if len(reports) == 1 else {"variants": reports}
if opts.json:
    Path(opts.json).parent.mkdir(parents=True, exist_ok=True)
    Path(opts.json).write_text(json.dumps(result, indent=1) + "\n")
# No variant measured: the step fails (its report, written above, says why).
if not any(report.get("measured") for report in reports):
    sys.exit(1)
