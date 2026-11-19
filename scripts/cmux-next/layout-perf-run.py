#!/usr/bin/env python3
"""Workspace-layout speed set (in-tree Chromium pages baseline, 2026-11-18): one build, one host, one display, every
layout scenario, optionally interleaved over Debug Settings variants (OFF, IN, OFF, IN, ...).

Run through the allowlisted fleet entry (split-spring.sh builds the tagged app at the ref and holds the virtual display
around this whole run):

  cmux-ci run --class exclusive --measurement --label measure --display --script scripts/measure/split-spring.sh \
    --ref SHA --timeout 14400 --artifact artifacts/split-spring/report.json \
    --arg=--suite=layout-perf --arg=--vdisplay=120 --arg=--vdisplay-hold=14400 --arg=--app-cache \
    [--arg=--parts=signposts,pane-light,pane-stress,divider,ws-switch,tab-switch,palette] \
    [--arg=--variants=off:7b7d,in:<hex of {"browser.inTreePages":true}>] [--arg=--ab-rounds=2]

Parts (each runs an existing bench against the step's app, with --tag/--app/--out of this run):
  signposts    every-action-sweep.py --only <layout actions> --repeat N, light and STRESS: the always-on
               action.perform / action.commit signposts (input to committed frame), frames missed per action
  pane-light   pane-perf-terminal.py --browser --layouts 1x2,4x2 --actions split,close,column,drag: missed frames,
               commit and frame-interval percentiles per action, the top-left pane a Chromium page
  pane-stress  pane-perf-terminal.py --layouts stress --stress-selected chromium (perf-stress-session.py), same actions
  divider      split-resize-bench.py --pane browser --gesture divider: a Chromium page beside a dragged divider,
               page layout lag and app frames dropped per drag
  ws-switch    sidebar-stress-profiles.py --scenarios switch_matrix (profiles 1x and scale): workspace switch to a
               Chromium workspace and a terminal one, click, Cmd-digit, next/prev, input to idle and longest frame
  tab-switch   tab-switch-matrix.py --kinds chromium --counts 2,10: debug.tab_switch input/apply/commit, late vsyncs
  palette      palette-open-stages.py --no-gate: Cmd-Shift-P and Cmd-P from a terminal, a Chromium page, ...: key-down
               to the committed first frame

Variants: NAME:HEXJSON, comma-separated. HEXJSON is the hex of a JSON object of Debug Settings overrides, written to the
tag's own debug-tunables.json (bench_launch.tag_state_roots: the file every bench launch keeps and the app reads)
before each part; NAME alone (or NAME:-) removes the file, so the build's defaults apply. Hex, because a step's
arguments pass through the controller and the shell. Default: one variant `base` with the defaults.
--ab-rounds N runs the variant list N times, interleaved per part (part 1 OFF, part 1 IN, part 1 OFF, ...).

Writes --json (the step's artifact): {parts: {VARIANT/ROUND/PART: {cmd, exit, seconds, report}}, host, macos, ...}.
Exits 0 once that report is written, whatever the parts did (the controller returns an artifact only from a passing
step; each part's exit is in the report). A summary line per part: `LAYOUT-PERF {json}`.
"""
import argparse, json, os, platform, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import tag_state_roots  # noqa: E402

SIGNPOST_ACTIONS = ("splitRight,closePane,newColumn,goToWorkspace,selectWorkspaceByNumber,nextSurface,prevSurface,"
                    "commandPalette,palette.open")
PARTS = ("signposts", "pane-light", "pane-stress", "divider", "ws-switch", "tab-switch", "palette")

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json", required=True)
parser.add_argument("--parts", default=",".join(PARTS))
parser.add_argument("--variants", default="base")
parser.add_argument("--ab-rounds", type=int, default=1)
parser.add_argument("--repeat", type=int, default=10, help="signposts: runs per action and session")
parser.add_argument("--rounds", type=int, default=3, help="pane-perf rounds per action")
parser.add_argument("--part-timeout", type=int, default=3600)
opts, _unknown = parser.parse_known_args()


def variants(spec):
    out = []
    for item in [v for v in spec.split(",") if v]:
        name, _, hexjson = item.partition(":")
        tunables = None
        if hexjson and hexjson != "-":
            tunables = json.loads(bytes.fromhex(hexjson).decode())
            if not isinstance(tunables, dict):
                sys.exit(f"layout-perf: variant {name}: the tunables must be a JSON object")
        out.append((name, tunables))
    return out


def set_tunables(tunables):
    """Write (or remove) the tag's debug-tunables.json in every state root the launch may read."""
    written = []
    for root in tag_state_roots(opts.tag):
        path = os.path.join(root, "debug-tunables.json")
        if tunables is None:
            if os.path.isfile(path):
                os.remove(path)
            continue
        os.makedirs(root, exist_ok=True)
        with open(path, "w") as f:
            json.dump(tunables, f)
        written.append(path)
    return written


def command(part, out, report):
    py = [sys.executable]
    common = ["--app", opts.app, "--tag", opts.tag, "--out", out]
    if part == "signposts":
        return py + [os.path.join(HERE, "every-action-sweep.py"), *common, "--json", report,
                     "--sessions", "light,stress", "--repeat", str(opts.repeat), "--only", SIGNPOST_ACTIONS,
                     "--no-interactions"]
    if part == "pane-light":
        return py + [os.path.join(HERE, "pane-perf-terminal.py"), *common, "--json", report, "--browser",
                     "--layouts", "1x2,4x2", "--actions", "split,close,column,drag", "--rounds", str(opts.rounds)]
    if part == "pane-stress":
        return py + [os.path.join(HERE, "pane-perf-terminal.py"), *common, "--json", report,
                     "--layouts", "stress", "--stress-selected", "chromium", "--actions", "split,close,column,drag",
                     "--rounds", str(opts.rounds)]
    if part == "divider":
        return py + [os.path.join(HERE, "split-resize-bench.py"), *common, "--json", report,
                     "--pane", "browser", "--gesture", "divider"]
    if part == "ws-switch":
        return py + [os.path.join(HERE, "sidebar-stress-profiles.py"), *common, "--json", report,
                     "--profiles", "1x,scale", "--scenarios", "switch_matrix"]
    if part == "tab-switch":
        return py + [os.path.join(HERE, "tab-switch-matrix.py"), *common, "--json", report,
                     "--kinds", "chromium", "--counts", "2,10"]
    if part == "palette":
        return py + [os.path.join(HERE, "palette-open-stages.py"), *common, "--json", report, "--no-gate"]
    raise SystemExit(f"layout-perf: unknown part {part!r} (known: {', '.join(PARTS)})")


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        return {"error": f"no report: {e}"}


def write(result):
    with open(opts.json, "w") as f:
        json.dump(result, f, indent=1, default=str)


def main():
    parts = [p for p in opts.parts.split(",") if p]
    for p in parts:
        if p not in PARTS:
            sys.exit(f"layout-perf: unknown part {p!r} (known: {', '.join(PARTS)})")
    vs = variants(opts.variants)
    result = {"suite": "layout-perf", "host": platform.node(), "app": opts.app, "tag": opts.tag,
              "macos": platform.mac_ver()[0], "machine": platform.machine(),
              "variants": {n: t for n, t in vs}, "ab_rounds": opts.ab_rounds, "parts_asked": parts,
              "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "parts": {}}
    try:
        result["hw_model"] = subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip()
    except OSError:
        pass
    write(result)
    for rnd in range(1, opts.ab_rounds + 1):
        for part in parts:
            for name, tunables in vs:
                key = f"{name}/r{rnd}/{part}"
                out = os.path.join(opts.out, "layout-perf", name, f"r{rnd}", part)
                shutil.rmtree(out, ignore_errors=True)
                os.makedirs(out, exist_ok=True)
                report = os.path.join(out, "report.json")
                written = set_tunables(tunables)
                cmd = command(part, out, report)
                print(f"layout-perf: {key}: {' '.join(cmd[1:])}", flush=True)
                start = time.monotonic()
                try:
                    code = subprocess.call(cmd, timeout=opts.part_timeout)
                except subprocess.TimeoutExpired:
                    code = 124
                seconds = round(time.monotonic() - start, 1)
                entry = {"cmd": cmd[1:], "exit": code, "seconds": seconds, "tunables": tunables,
                         "tunables_files": written, "report": load(report)}
                result["parts"][key] = entry
                print("LAYOUT-PERF " + json.dumps({"part": key, "exit": code, "seconds": seconds}), flush=True)
                write(result)
    set_tunables(None)
    result["ended"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    write(result)
    print(f"layout-perf: wrote {opts.json} ({os.path.getsize(opts.json)} bytes)", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
