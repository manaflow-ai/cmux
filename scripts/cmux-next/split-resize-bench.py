#!/usr/bin/env python3
"""A page beside a pane a person resizes (scripts/ci/frame-pacing/split_resize.py).

Launches a tagged DEV app (bench_launch.py), splits right, opens the page in the right pane (`--pane`: a Chromium
tab with the probe page, an agent chat, or a terminal showing a long wrapped transcript, the stand-in for Claude Code
in a terminal) and resizes that pane (`--gesture`: the divider dragged through the real
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

Usage: split-resize-bench.py --app APP --out DIR [--json PATH] [--tag TAG] [--pane=browser,chat,terminal|all]
       [--gesture=divider,divider-pause,sidebar,window-edge|all] [--seed=ROWS]
"""

from __future__ import annotations

import argparse, base64, json, os, subprocess, sys, time
from pathlib import Path

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
sys.path.insert(0, os.path.join(here, "..", "ci", "frame-pacing"))
from bench_launch import BenchApp  # noqa: E402
import golden  # noqa: E402
import in_tree_mode  # noqa: E402
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
# Rows seeded into the chat before its gestures (`--pane=chat`): 2800 is about a 700-turn chat. With
# `--pane=terminal`: the transcript's turns are a quarter of it (the same chat; 0: split_resize.TRANSCRIPT_TURNS, 700).
parser.add_argument("--seed", type=int, default=0)
# In-tree pages on or off for every launch (in_tree_mode.py): the same build, no rebuild.
in_tree_mode.add_argument(parser)
opts, _ = parser.parse_known_args()
in_tree_mode.apply(opts.in_tree)


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


def drag_sample(path: Path) -> dict | None:
    """The main thread's part of a `sample` report: its call tree's first 120 lines and the top-of-stack counts."""
    if not path.is_file():
        return None
    lines = path.read_text(errors="replace").splitlines()
    tree = next((i for i, line in enumerate(lines) if line.startswith("Call graph:")), None)
    top = next((i for i, line in enumerate(lines) if line.startswith("Sort by top of stack")), None)
    return {"main_thread": lines[tree + 1:tree + 121] if tree is not None else None,
            "top_of_stack": lines[top + 1:top + 41] if top is not None else None}


# The run's display-awake assertion (`caffeinate`), started at most once; it ends on its own timeout.
AWAKE: list = []


def sight(driver) -> dict:
    """Whether the app's windows can get display frames now: the app active, and each main window shown, on screen and
    not covered. A window out of sight (FrameScheduler.windowIsOutOfSight: the app inactive and the window covered,
    minimized or ordered out) gets no frame ticks, and a divider drag's moves wait for one (DividerDrag.waitForFrame):
    the still dividers of steps d315c76a and bee050aa (2026-11-20) were not that but the gesture's trace ending early
    (split_resize.from_point); the sight is still recorded with each drag."""
    focus = driver.call("debug.focus", {}, timeout=10)
    windows = driver.call("debug.window_list", {}, timeout=10).get("windows") or []
    return {"app_active": focus.get("app_active"),
            "windows": [{key: w.get(key) for key in ("id", "visible", "key", "occluded", "miniaturized")}
                        for w in windows if w.get("kind") == "main"]}


def bring_into_sight(driver, app_path: str) -> dict:
    """Wakes the display and brings the app to the front when its window is out of sight. A fleet bench Mac has no
    person on it; the launch lets the app activate (no CMUX_NEXT_NO_ACTIVATE), so a drag beside the chat gets its frames
    as on a person's Mac."""
    before = sight(driver)
    covered = before.get("app_active") is not True or any(w.get("occluded") or not w.get("visible")
                                                         for w in before["windows"])
    if not covered:
        return {"before": before, "acted": False}
    # A user-activity assertion wakes a sleeping display and holds it on for the run's length (one per run).
    if not AWAKE:
        AWAKE.append(subprocess.Popen(["/usr/bin/caffeinate", "-u", "-d", "-t", "900"], stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL))
    subprocess.run(["/usr/bin/open", "-a", app_path], capture_output=True, timeout=30)
    time.sleep(2.0)  # test harness: activation and WindowServer's occlusion report arrive
    return {"before": before, "acted": True, "after": sight(driver)}


def measure(pane: str, folder: Path) -> dict:
    """One launch: the harness's gestures on `pane` and its recording drag, judged."""
    folder.mkdir(parents=True, exist_ok=True)
    # The app may activate: its window is key and in front, as a person's is while they drag beside the chat. Only a
    # fleet GUI host runs it (bench_launch refuses a person's Mac for a launch that activates).
    app = BenchApp(opts.app, out=str(folder), window=(80, 80, 1100, 720), env={"CMUX_NEXT_NO_ACTIVATE": None})
    report: dict = {"pane": pane, "requested_gestures": gestures}
    try:
        app.launch()
        status = in_tree_mode.read(app.rpc)
        report.update(in_tree_mode.record(opts.in_tree, status))
        problem = in_tree_mode.mismatch(opts.in_tree, status)
        if problem:
            raise SystemExit(problem)
        driver = golden.Driver(app.socket, folder)
        report["sight"] = {"launched": bring_into_sight(driver, opts.app)}
        driver.call("debug.motion", {"action": "speed", "value": "fast"})
        driver.call("debug.motion", {"action": "reduce", "value": False})
        sample_path = folder / "drag-sample.txt"

        def profile():
            """macOS `sample` of the app through the first divider drag (2 s, 1 ms): where a slow drag frame goes."""
            sampler = subprocess.Popen(["/usr/bin/sample", str(app.process.pid), "2", "1", "-mayDie", "-file",
                                        str(sample_path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(0.3)  # sample attaches before the drag begins
            return lambda: sampler.wait(timeout=30)

        split_resize.drive(driver, folder, strip=True, pane=pane, gestures=gestures,
                           seed=opts.seed if pane in ("chat", "terminal") else 0, profile=profile,
                           sight=lambda: bring_into_sight(driver, opts.app))
        report["drag_sample"] = drag_sample(sample_path)
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
    # What the harness did, in the report the step returns (the folder stays on the worker): the split, the pane it
    # opened, and each drag's mouse replies and first and last divider samples. A drag that moved nothing says why.
    try:
        data = json.loads((folder / "split_resize.json").read_text())
        report["harness"] = {
            "split": data.get("split"), "opened": data.get("opened"), "chat_pane": data.get("chat_pane"),
            "error": data.get("error"), "rest": data.get("rest"),
            "drags": [{"gesture": d.get("gesture"), "acted": d.get("acted"), "sight": d.get("sight"),
                       "first": (d.get("samples") or [None])[0], "last": (d.get("samples") or [None])[-1],
                       # Each frame's divider x positions: whether the divider followed the pointer through the drag,
                       # or only moved after the release (the 2026-11-19 runs: first and last the same, moved after).
                       "divider_x": [[round(float(row[1])) for row in s.get("dividers") or []]
                                     for s in d.get("samples") or []]}
                      for d in (data.get("drags") or [])[:3]]}
    except (OSError, ValueError) as error:
        report["harness"] = {"unread": repr(error)}
    return report


reports = [measure(pane, out / pane) for pane in panes]
result = reports[0] if len(reports) == 1 else {"panes": reports}
if opts.json:
    Path(opts.json).parent.mkdir(parents=True, exist_ok=True)
    Path(opts.json).write_text(json.dumps(result, indent=1) + "\n")
# No pane measured: the step fails (its report, written above, says why).
if not any(report.get("measured") for report in reports):
    sys.exit(1)
