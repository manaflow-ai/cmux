#!/usr/bin/env python3
"""cx-ww20 live proof on the GUI host: column-edge drag, strip scroll under a
still pointer, divider hover, recorded frame by frame.

  column-resize-live.py --app APP|--tag <tag> --out DIR [--story column-resize-live]

Launches the tagged app through bench_launch.BenchApp (the bench env: no activation, automation socket, an empty
cmux.json, a fresh saved session, the tag's daemons ended after), makes three columns (terminal, terminal + New Tab
page tab, New Tab page) so the strip overflows, then while `debug.window_record` records every display frame: drags
the first column edge right in paced steps (samples the edge after each step), puts the synthesized pointer on a
divider, scrolls the strip with a trackpad gesture under it, holds still, and leaves. Writes frames, samples.json and
app.log to DIR. With --story it also writes, as cmux-perf-result/v1 (resize_bench_report.py), how far the edge is
from the pointer after each step and the steps that sampled no edge.
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
from bench_launch import BenchApp  # noqa: E402
import resize_bench_report as results  # noqa: E402

WINDOW = (40, 40, 1280, 760)


def parse(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", default=os.environ.get("NX_APP"), help="the tagged app bundle (default $NX_APP)")
    parser.add_argument("--tag", help="find the app of this tag in DerivedData when --app is not given")
    parser.add_argument("--out", required=True)
    parser.add_argument("--story", help=f"write result-v1 under this story ({results.COLUMN_STORY})")
    parser.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it (BenchApp.record)")
    opts = parser.parse_args(argv)
    opts.app = results.tagged_app(opts.app, opts.tag)
    if not opts.app:
        parser.error("name the tagged app with --app (or $NX_APP), or a --tag a tagged reload built")
    problem = opts.story and results.story_problem(opts.story, "webkit", "light")
    if problem:
        parser.error(problem)
    return opts


def areas(layer):
    """Vertical divider areas (column edges and splits) as (x_mid, y_mid_top, rect), left to right."""
    height = (layer.get("frame") or [0, 0, 0, 720])[3]
    result = []
    for x, y, w, h in layer.get("divider_areas_in_window") or []:
        if h > w:
            result.append((x + w / 2, height - (y + h / 2), [x, y, w, h]))
    return sorted(result)


class NoDivider(Exception):
    """The layout had no divider area to drag."""


def measure(bench, opts, report):
    """The three columns, the drag, the hover and the scroll; fills `report` (samples.json)."""
    rpc = bench.rpc

    def layers():
        result = rpc("debug.layers")
        return ((result or {}).get("windows") or [{}])[0] if isinstance(result, dict) else {}

    def mouse(**params):
        return rpc("debug.mouse", params)

    def focused_pane():
        windows = (rpc("debug.focus") or {}).get("windows") or [{}]
        return windows[0].get("layout_focused_pane")

    def run(action):
        pane = focused_pane()
        reply = rpc("action.run", {"action": action, "focus": True, "target": f"pane:{pane}" if pane else None})
        time.sleep(1.5)  # bench script: the action's layout lands
        return {"pane": pane, "reply": reply}

    def run_on(action, pane):
        reply = rpc("action.run", {"action": action, "focus": False, "target": f"pane:{pane}"})
        time.sleep(1.0)  # bench script: the width lands
        return reply

    time.sleep(2)  # bench script: the first window settles
    report["focus_before"] = rpc("debug.focus")
    report["new_workspace"] = rpc("action.run", {"action": "newTab", "focus": True})
    time.sleep(3)  # bench script: the workspace's terminal starts
    report["focus_workspace"] = rpc("debug.focus")
    first = focused_pane()
    report["new_column_1"] = run("newColumn")
    second = focused_pane()
    report["new_tab_page_1"] = run("newTab.page")
    report["new_column_2"] = run("newColumn")
    third = focused_pane()
    report["new_tab_page_2"] = run("newTab.page")
    report["panes"] = [first, second, third]
    report["widths"] = [run_on("column.widthOneThird", first), run_on("column.widthHalf", second),
                        run_on("column.widthHalf", third)]
    # Focus the middle column (right of the edge that is dragged), as in Lawrence's recording.
    report["focus_middle"] = rpc("action.run", {"action": "column.focusLeft", "focus": True, "target": f"pane:{third}"})
    time.sleep(1.0)  # bench script: the focus lands
    report["focused_before_drag"] = focused_pane()
    time.sleep(4)  # bench script: the pages load and the strip rests
    layer = layers()
    report["layers_before"] = {k: layer.get(k) for k in ("frame", "divider_areas_in_window", "placement", "browsers")}
    edges = areas(layer)
    if not edges:
        raise NoDivider("no divider areas: " + json.dumps({k: report.get(k) for k in (
            "focus_before", "new_workspace", "focus_workspace", "new_column_1", "new_tab_page_1")})[:2500])
    frames_dir = os.path.join(opts.out, "frames")
    report["record"] = rpc("debug.window_record", {"dir": frames_dir, "seconds": 8})
    time.sleep(0.3)  # bench script: the recording starts

    # 1. Drag the first edge right, 30 paced steps of 6 pt.
    x0, y0, _ = edges[0]
    report["drag_down"] = mouse(action="down", x=x0, y=y0)
    for step in range(1, 31):
        x = x0 + step * 6
        mouse(action="drag", x=x - 6, y=y0, to_x=x, to_y=y0, steps=1, press=False, release=False)
        time.sleep(1 / 60)  # bench script: one step per 60 Hz frame
        sample = areas(layers())
        report["steps"].append({"pointer_x": x, "edges_x": [round(e[0], 1) for e in sample]})
    mouse(action="up", x=x0 + 180, y=y0)
    time.sleep(0.6)  # bench script: the drag ends

    # 2. Pointer still on a divider; the strip then scrolls under it (a focus
    #    change reveals the last column: the real scroll path, no mouse event).
    edges = areas(layers())
    if not edges:
        raise NoDivider("no divider areas after the drag")
    hover_x, hover_y, _ = edges[-1]
    report["hover_point"] = [hover_x, hover_y]
    report["hover"] = mouse(action="hover", x=hover_x, y=hover_y)
    time.sleep(0.6)  # bench script: the hover state shows
    report["snap_hovered"] = rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, "hovered.png")})
    report["reveal"] = rpc("action.run", {"action": "column.focusRight", "focus": True,
                                          "target": f"pane:{focused_pane()}"})
    time.sleep(1.5)  # bench script: the strip scrolls
    report["after_scroll_edges_x"] = [round(e[0], 1) for e in areas(layers())]
    report["snap_after_scroll"] = rpc("debug.window_snapshot", {"kind": "main",
                                                                "path": os.path.join(opts.out, "after-scroll.png")})
    time.sleep(0.5)  # bench script: the strip settles
    report["after_settle_edges_x"] = [round(e[0], 1) for e in areas(layers())]
    mouse(action="leave")
    time.sleep(3)  # bench script: the recording runs out
    report["layers_after"] = {k: layer.get(k) for k in ("divider_areas_in_window", "browsers")}


def main(argv=None):
    opts = parse(argv)
    os.makedirs(opts.out, exist_ok=True)
    bench = BenchApp(opts.app, out=opts.out, config={}, window=WINDOW, screen="last", log_name="app.log",
                     build_config=opts.build_config)
    report = {"pid": None, "steps": [], "notes": []}
    no_divider = None
    try:
        bench.launch(timeout=120)  # ready once debug.windows lists a window
        report["pid"] = bench.process.pid
        measure(bench, opts, report)
    except NoDivider as error:
        no_divider = str(error)
    finally:
        bench.stop()
        with open(os.path.join(opts.out, "samples.json"), "w") as f:
            json.dump(report, f, indent=1)
    problems = results.record(bench, results.column_resize_series(opts.story, report["steps"], bool(no_divider))) \
        if opts.story else []
    for problem in problems:
        print(f"RESULT-V1 FAIL {problem}", flush=True)
    if no_divider:
        sys.exit(no_divider)
    print(json.dumps({k: report.get(k) for k in ("record", "hover_point", "after_scroll_edges_x",
                                                 "after_settle_edges_x")})[:1500])
    print("steps:", json.dumps(report["steps"][:3]), "...", json.dumps(report["steps"][-2:]))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
