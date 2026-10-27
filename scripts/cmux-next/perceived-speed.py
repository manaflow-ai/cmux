#!/usr/bin/env python3
"""Perceived speed: does a surface paint its final layout on its first frame? (Leo 2026-10-14)

  perceived-speed.py analyze DIR [--trigger SECONDS] [--region X,Y,W,H] [--strip PNG]
  perceived-speed.py run (--socket SOCK | --app APP) --out DIR [--surface NAME ...] [--runs N]
                        [--engine chromium|webkit] [--story ID]
  perceived-speed.py table OUT [OUT ...]
  perceived-speed.py find-socket BUNDLE_ID --since EPOCH DIR [DIR ...]

`analyze` reads one `debug.window_record` folder (frame-NNNNN.jpg plus frames.json
{"times": [...]}, one frame per display frame) and prints JSON:

  first_frame_ms   trigger to the first frame that differs from the one before it
  settle_ms        trigger to the last frame that still changed (null: never settled)
  diff_area        share of the window that differs between the first and the settled
                   frame: 0 when the surface painted its final layout at once
  shift            sum of the area each later frame repainted (CLS-style; motion counts)
  repaints         frames after the first that changed something
  dropped          display frames missed between the first and the settled frame
                   (gaps over 1.5 frame intervals: the main thread was busy)

Frames are compared in grayscale at a quarter of their size; a pixel counts when it moved
by more than 24 of 255 (JPEG noise), a frame when more than 0.05% of the region did (a
terminal caret blink is less). A frame is settled when nothing changes for 250 ms after it.

`run` drives a running DEV build over its debug socket (a capture slot: `capture-host
launch`, then run this on the slot host), or with --app launches one itself (bench_launch.py
BenchApp, its new browser tabs in --engine): for each surface it starts `debug.window_record`,
waits, opens the surface the way a person does (a key through `debug.key` or an action),
and writes OUT/<surface>-<n>/ with meta.json (the trigger time) next to the frames, then
OUT/<surface>-<n>/metrics.json. `table` ranks every surface in the OUT folders by
diff_area, then shift (medians over runs) and prints a Markdown table. `find-socket` prints
the debug socket (cmux-debug*.sock in DIR, newer than EPOCH) whose `system.identify` names
BUNDLE_ID: newer DEV builds listen at ~/.local/state/cmux/cmux-debug--<hash>.sock, not by tag.
Medians are pct(values, 0.5) of scripts/perf-lab/perf_stats.py (or of its copy next to this file).

`run --app --story ID` also writes cmux-perf-result/v1 files into --out (BenchApp.record), one
per surface and metric (RESULT_METRICS below), every run that opened something one sample:
for example `palette.first_frame_ms`. The perf-lab story is perceived-speed
(scripts/perf-lab/stories.d). --story refuses to start without Pillow, since no run could then
be analyzed, and for a story whose stories.d engine is not --engine. A --story run that writes no
series fails.

Needs Pillow. A warning, never a gate.
"""
import argparse
import glob
import importlib.util
import json
import os
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
# perf_stats.py (it loads pinpoint_thresholds.py next to it) in the repo, or next to this file: perceived-speed-slot.sh
# copies the three files alone onto a capture-slot host. Everything but `run --app` imports nothing else of the repo.
PERF_STATS_PATHS = (os.path.join(HERE, os.pardir, "perf-lab", "perf_stats.py"), os.path.join(HERE, "perf_stats.py"))

PIXEL = 24
AREA = 0.0005
QUIET = 0.25
SCALE = 4

# How a person opens each surface. Every run starts from the same place: the base workspace (the
# bottom one, made at the start of `run`) selected, through actions (not measured). "prep" steps run
# next, unmeasured; "key" or "action" is the measured trigger; "after" closes what it opened (Settings
# and What's New open as tabs: Cmd-W). A step is a key [key, modifiers]
# or {"action": id}. Cmd-N puts a workspace at the top. workspace-switch gives that one a terminal
# so the two workspaces differ, and switches by action: Cmd-1 is a New Tab page quick action.
RESET = [{"action": "workspace.selectLast"}]
SURFACES = {
    "new-tab": {"key": ["t", ["command"]], "after": ["w", ["command"]]},
    "new-workspace": {"key": ["n", ["command"]], "after": ["w", ["command"]]},
    "settings": {"key": [",", ["command"]], "after": ["w", ["command"]]},
    "palette": {"key": ["p", ["command", "shift"]], "after": ["escape", []]},
    "terminal": {"key": ["`", ["control"]], "after": ["w", ["command"]]},
    "browser": {"key": ["l", ["command", "shift"]], "after": ["w", ["command"]]},
    "whats-new": {"action": "updates.whatsNew", "after": ["w", ["command"]]},
    "workspace-switch": {"prep": [["n", ["command"]], {"action": "newSurface"}, {"action": "workspace.selectLast"}],
                         "action": "workspace.selectFirst", "after": ["w", ["command", "shift"]]},
}
# The `analyze` values written as result-v1: (metric, unit). All are lower-is-better.
RESULT_METRICS = (("first_frame_ms", "ms"), ("settle_ms", "ms"), ("diff_area", "ratio"), ("shift", "unitless"),
                  ("repaints", "count"), ("dropped", "count"))


class SetupError(RuntimeError):
    """A file this script needs is neither in the repo nor next to it."""


def perf_stats():
    """scripts/perf-lab/perf_stats.py, loaded by path once (the script runs under `python3 -I`)."""
    if "perf_stats" in sys.modules:
        return sys.modules["perf_stats"]
    path = next((p for p in PERF_STATS_PATHS if os.path.exists(p)), None)
    if path is None:
        raise SetupError(f"perceived-speed: no perf_stats.py at {' or '.join(PERF_STATS_PATHS)}: copy "
                         "scripts/perf-lab/perf_stats.py and pinpoint_thresholds.py next to this script")
    spec = importlib.util.spec_from_file_location("perf_stats", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    sys.modules["perf_stats"] = module
    return module


def bench_modules():
    """(bench_launch, bench_story) of scripts/cmux-next: only `run --app` needs the repo around this file."""
    if HERE not in sys.path:
        sys.path.insert(0, HERE)
    import bench_launch
    import bench_story

    return bench_launch, bench_story


def load(folder, region=None):
    from PIL import Image

    with open(os.path.join(folder, "frames.json")) as f:
        times = json.load(f)["times"]
    names = sorted(n for n in os.listdir(folder) if n.startswith("frame-") and n.endswith(".jpg"))
    names = names[: len(times)]
    frames = []
    for name in names:
        image = Image.open(os.path.join(folder, name))
        image.draft("L", (max(1, image.width // SCALE), max(1, image.height // SCALE)))
        image = image.convert("L")
        if region:
            x, y, w, h = region
            image = image.crop((x // SCALE, y // SCALE, (x + w) // SCALE, (y + h) // SCALE))
        frames.append(image)
    return times[: len(frames)], frames, names


def changed(a, b):
    """Share of pixels that moved by more than PIXEL between two frames."""
    from PIL import ImageChops

    if a.size != b.size:
        return 1.0
    histogram = ImageChops.difference(a, b).histogram()
    return sum(histogram[PIXEL + 1:]) / float(a.width * a.height)


def analyze(times, frames, trigger=None):
    if len(frames) < 2:
        return {"error": "fewer than two frames"}
    trigger = times[0] if trigger is None else trigger
    steps = [0.0] + [changed(frames[i - 1], frames[i]) for i in range(1, len(frames))]
    later = [i for i in range(1, len(frames)) if times[i] >= trigger and steps[i] > AREA]
    if not later:
        return {"first_frame_ms": None, "settle_ms": None, "diff_area": 0.0, "shift": 0.0, "repaints": 0,
                "dropped": 0, "frames": len(frames), "note": "nothing changed after the trigger"}
    first, last = later[0], later[-1]
    settled = times[-1] - times[last] >= QUIET
    gaps = [times[i] - times[i - 1] for i in range(1, len(times))]
    interval = perf_stats().pct(gaps, 0.5) if gaps else 1 / 60
    dropped = sum(max(0, round(gaps[i - 1] / interval) - 1) for i in range(first + 1, last + 1)
                  if gaps[i - 1] > 1.5 * interval)
    return {
        "first_frame_ms": round((times[first] - trigger) * 1000, 1),
        "settle_ms": round((times[last] - trigger) * 1000, 1) if settled else None,
        "diff_area": round(changed(frames[first], frames[last]), 5),
        "shift": round(sum(steps[first + 1: last + 1]), 5),
        "repaints": sum(1 for i in later if i > first),
        "dropped": dropped,
        "frame_interval_ms": round(interval * 1000, 2),
        "frames": len(frames),
        "first_index": first,
        "settled_index": last,
    }


def strip(folder, names, result, path):
    """Before, first, two in between and settled frames side by side, labelled."""
    from PIL import Image, ImageDraw

    first, last = result.get("first_index"), result.get("settled_index")
    if first is None:
        return
    picks = sorted({max(0, first - 1), first, first + (last - first) // 3, first + 2 * (last - first) // 3, last})
    images = [Image.open(os.path.join(folder, names[i])).convert("RGB") for i in picks]
    width = 480
    scaled = [im.resize((width, max(1, im.height * width // im.width))) for im in images]
    sheet = Image.new("RGB", (width * len(scaled), scaled[0].height + 22), "black")
    draw = ImageDraw.Draw(sheet)
    for n, (index, im) in enumerate(zip(picks, scaled)):
        sheet.paste(im, (n * width, 22))
        label = "before" if index < first else ("first" if index == first else ("settled" if index == last else f"#{index}"))
        draw.text((n * width + 6, 5), f"{label} (frame {index})", fill="white")
    sheet.save(path)


def analyze_folder(folder, trigger=None, region=None, strip_path=None):
    meta_path = os.path.join(folder, "meta.json")
    if trigger is None and os.path.exists(meta_path):
        with open(meta_path) as f:
            trigger = json.load(f).get("trigger")
    times, frames, names = load(folder, region)
    result = analyze(times, frames, trigger)
    if strip_path:
        strip(folder, names, result, strip_path)
    return result


class App:
    def __init__(self, path):
        self.path = path

    def call(self, method, params=None, timeout=30):
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(self.path)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf or b"{}")
        return reply.get("result", reply)

    def key(self, key, modifiers):
        return self.call("debug.key", {"key": key, "modifiers": modifiers})


def find_socket(bundle_id, since, dirs):
    for folder in dirs:
        for path in sorted(glob.glob(os.path.join(folder, "cmux-debug*.sock"))):
            try:
                if os.stat(path).st_mtime < since:
                    continue
                if bundle_id in json.dumps(App(path).call("system.identify", timeout=3)):
                    return path
            except (OSError, ValueError):  # a stale socket nobody listens on
                continue
    return None


def step(app, spec):
    if isinstance(spec, dict):
        # A script run changes the view only with focus: true (ActionInvocation.allowsViewChange).
        return app.call("action.run", {"id": spec["action"], "focus": True, **({"args": spec["args"]} if spec.get("args") else {})})
    return app.key(*spec)


def run_surface(app, name, spec, folder, seconds, lead):
    for prep in RESET + list(spec.get("prep") or []):
        step(app, prep)
        time.sleep(0.8)
    time.sleep(0.7)
    reply = app.call("debug.window_record", {"dir": folder, "seconds": seconds})
    if not isinstance(reply, dict) or reply.get("error"):
        return {"error": f"debug.window_record: {reply}"}
    started = time.monotonic()
    time.sleep(lead)
    trigger = time.monotonic() - started
    step(app, spec["key"] if "key" in spec else spec)
    time.sleep(seconds - lead + 0.8)
    with open(os.path.join(folder, "meta.json"), "w") as f:
        json.dump({"surface": name, "trigger": trigger, "spec": spec}, f)
    if spec.get("after"):
        app.key(*spec["after"])
        time.sleep(0.8)
    for _ in range(20):  # frames.json lands when the recorder finishes
        if os.path.exists(os.path.join(folder, "frames.json")):
            break
        time.sleep(0.25)
    try:
        result = analyze_folder(folder, strip_path=os.path.join(folder, "strip.png"))
    except ImportError:  # no Pillow on this host: `analyze` the copied folder elsewhere
        return {"recorded": folder}
    with open(os.path.join(folder, "metrics.json"), "w") as f:
        json.dump(result, f, indent=1)
    return result


def analyzed_runs(outs):
    """{surface: [metrics.json of each analyzed run]} of the run folders in the OUT folders `outs`."""
    rows = {}
    for out in outs:
        for entry in sorted(os.listdir(out)):
            path = os.path.join(out, entry, "metrics.json")
            meta = os.path.join(out, entry, "meta.json")
            if not os.path.exists(path) or not os.path.exists(meta):
                continue
            with open(path) as f:
                metrics = json.load(f)
            with open(meta) as f:
                surface = json.load(f)["surface"]
            rows.setdefault(surface, []).append(metrics)
    return rows


def table(outs):
    rows = analyzed_runs(outs)

    ranked = []
    for surface, every in rows.items():
        # A run where nothing changed opened nothing (the trigger missed): it is no evidence either way.
        missed = sum(1 for r in every if r.get("first_frame_ms") is None)
        runs = [r for r in every if r.get("first_frame_ms") is not None] or every
        unsettled = sum(1 for r in runs if r.get("settle_ms") is None and r.get("first_frame_ms") is not None)
        ranked.append((surface, len(every), *(perf_stats().pct([r.get(k) for r in runs], 0.5) for k in
                       ("diff_area", "shift", "first_frame_ms", "settle_ms", "repaints", "dropped")), unsettled, missed))
    ranked.sort(key=lambda r: (-(r[2] or 0), -(r[3] or 0)))
    lines = ["| surface | runs | frame-1 vs settled (area) | shift | first frame ms | settled ms | repaints | dropped | unsettled | no change |",
             "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for surface, runs, area, shift, first, settle, repaints, dropped, unsettled, missed in ranked:
        fmt = lambda v, p="{:.1f}": "n/a" if v is None else p.format(v)  # noqa: E731
        lines.append(f"| {surface} | {runs} | {fmt(area * 100 if area is not None else None, '{:.2f}%')} | "
                     f"{fmt(shift, '{:.3f}')} | {fmt(first, '{:.0f}')} | {fmt(settle, '{:.0f}')} | "
                     f"{fmt(repaints, '{:.0f}')} | {fmt(dropped, '{:.0f}')} | {unsettled}/{runs} | {missed}/{runs} |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    a = sub.add_parser("analyze")
    a.add_argument("folder")
    a.add_argument("--trigger", type=float)
    a.add_argument("--region", type=lambda s: [int(v) for v in s.split(",")])
    a.add_argument("--strip")
    r = sub.add_parser("run")
    target = r.add_mutually_exclusive_group(required=True)
    target.add_argument("--socket", help="the debug socket of a running DEV build")
    target.add_argument("--app", help="a tagged DEV .app to launch (bench_launch.py BenchApp) and quit after")
    r.add_argument("--tag", help="ignored: the perf-lab runner passes it, the app's name carries the tag")
    r.add_argument("--out", required=True)
    r.add_argument("--surface", action="append", choices=sorted(SURFACES))
    r.add_argument("--runs", type=int, default=3)
    r.add_argument("--seconds", type=float, default=4)
    r.add_argument("--lead", type=float, default=0.4)
    r.add_argument("--engine", choices=("chromium", "webkit"), default="chromium",
                   help="with --app: the engine of new browser tabs (browser.defaultEngine), result-v1's engine")
    r.add_argument("--story", help="with --app: also write cmux-perf-result/v1 files of this story into --out")
    t = sub.add_parser("table")
    t.add_argument("outs", nargs="+")
    f = sub.add_parser("find-socket")
    f.add_argument("bundle_id")
    f.add_argument("--since", type=float, default=0)
    f.add_argument("dirs", nargs="+")
    opts = parser.parse_args()
    if opts.command == "find-socket":
        path = find_socket(opts.bundle_id, opts.since, opts.dirs)
        if path:
            print(path)
        return 0 if path else 1
    if opts.command == "analyze":
        print(json.dumps(analyze_folder(opts.folder, opts.trigger, opts.region, opts.strip), indent=1))
        return 0
    if opts.command == "table":
        print(table(opts.outs))
        return 0
    if opts.story and not opts.app:
        parser.error("--story needs --app: result-v1 names the build and features of an app this run launched")
    if opts.story and importlib.util.find_spec("PIL") is None:
        parser.error("--story needs Pillow (PIL): without it no run is analyzed and nothing could be recorded")
    if not opts.app:
        return run_all(App(opts.socket), opts)
    bench_launch, bench_story = bench_modules()
    if opts.story and bench_story.story_problem(opts.story, opts.engine):
        parser.error(bench_story.story_problem(opts.story, opts.engine))
    launcher = bench_launch.BenchApp(opts.app, out=opts.out,
                                     config={"appearance": {"backgroundOpacity": 1},
                                             "browser": {"defaultEngine": opts.engine}})
    try:
        launcher.launch()
        status = run_all(App(launcher.socket), opts)
        if opts.story:
            written = record_results(launcher, opts.story, opts.engine, opts.out)
            if not any(path.endswith(".ndjson") for path in written.values()):
                status = 1  # a story run that recorded nothing measured nothing
    finally:
        launcher.stop()
    return status


def run_all(app, opts):
    """Every run of every surface into opts.out; prints the table. 1 when the app stopped answering."""
    app.key("n", ["command"])  # the base workspace every run starts from
    time.sleep(1.5)
    for name in opts.surface or sorted(SURFACES):
        for n in range(opts.runs):
            folder = os.path.join(os.path.abspath(opts.out), f"{name}-{n + 1}")
            os.makedirs(folder, exist_ok=True)
            try:
                result = run_surface(app, name, SURFACES[name], folder, opts.seconds, opts.lead)
            except OSError as error:  # the app quit (a DEBUG main-thread watchdog stop) or stopped answering
                print(name, n + 1, json.dumps({"error": f"app socket: {error}"}), flush=True)
                print(table([opts.out]))
                return 1
            print(name, n + 1, json.dumps(result), flush=True)
    print(table([opts.out]))
    return 0


def surface_samples(out):
    """{surface: {metric: [value per run]}} of the analyzed runs in `out`. A run where nothing changed opened
    nothing (the trigger missed) and gives no sample, as in the table; neither does an unsettled run's settle_ms."""
    samples = {}
    for surface, runs in analyzed_runs([out]).items():
        for metrics in runs:
            if metrics.get("first_frame_ms") is None:
                continue
            for metric, _ in RESULT_METRICS:
                value = metrics.get(metric)
                if isinstance(value, (int, float)):
                    samples.setdefault(surface, {}).setdefault(metric, []).append(value)
    return samples


def record_results(launcher, story, engine, out):
    """One cmux-perf-result/v1 file per surface and metric (BenchApp.record): `<surface>.<metric>`. A series the
    bench cannot describe truthfully (no build sha, no features snapshot) is not written; its reason is returned in
    its place."""
    bench_launch, _ = bench_modules()
    perf_result = bench_launch.load_by_path("perf_result", os.path.join(bench_launch.PERF_LAB, "perf_result.py"))
    units = dict(RESULT_METRICS)
    written = {}
    for surface, series in surface_samples(out).items():
        for metric, values in series.items():
            name = f"{surface}.{metric}"
            try:
                written[name] = str(launcher.record(story, name, units[metric], values, better="lower", engine=engine))
            except (bench_launch.RecordError, perf_result.ResultError) as error:
                written[name] = f"not recorded: {error}"
                print(f"result-v1 {name}: not recorded: {error}", flush=True)
    if not written:
        print("result-v1: no analyzed run opened anything; nothing recorded", flush=True)
    return written


if __name__ == "__main__":
    sys.exit(main())
