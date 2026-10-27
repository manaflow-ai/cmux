#!/usr/bin/env python3
"""Chromium resize sync (fork API 27): how long a page's resize holds cmux's frame, and the frames it costs.

Review 2 of PL-cef-layer slice 1 (plans/cmux-next/cef-layer-hosting-DESIGN.md "Live resize"): a hosted page's resize
wait runs inside the window's Core Animation commit on the main thread, on every motion frame of a split, close or
column spring, so it must be measured as commit time and dropped frames, light and STRESS, before it is called a fix.

Modes, on one tagged build (each checked first with cef-layer-verify.py --checks hosted --tunables build, which also
checks with debug.layers that the fork really moved the page's pixels, `hosted.fork`):

  off     layer hosting off: the page is a child window. API 26 and older: Chromium's own wait (up to 500 ms per
          page resize); API 27: no wait
  on      layer hosting on, `browserResize.syncDeadline` at its default (8 ms, capped at half a display frame by
          CEFResizeSyncDeadline: 4 ms at 120 Hz)
  on0     layer hosting on, syncDeadline 0: the page never holds the commit (it shows its last frame until Chromium
          draws the new size)

Benches per mode: `light` (pane-perf-terminal.py --browser 1x2,4x2: the top-left pane is a Chromium page) and `stress`
(pane-perf-terminal.py --layouts stress --stress-selected chromium: the STRESS session, every pane a Chromium page),
actions split, close, column, drag. Per action it reports `commit_p95_ms` / `commit_max_ms` (every Core Animation
commit while debug.motion records: MotionCommitProbe, `ca.commit`, which holds Chromium's pre-commit wait), missed
frames and the display refresh (`refresh_ms`: judge drops in frames, a fleet mini may run at 60 Hz).

API 26 against API 27: run it once per build (--label names the run; summary.json records each mode's fork_api).

Run on a GUI fleet host, never a laptop:
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/cef-resize-sync-bench.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS"
Not a gate: it never fails on a number. Exit 1 when a mode is not what it says or a bench left no report.
"""
import argparse, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
HOSTING_KEY = "browserResize.layerHosting"
DEADLINE_KEY = "browserResize.syncDeadline"
MODES = {"off": ("off", None), "on": ("on", None), "on0": ("on", 0.0)}

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--label", default="", help="names this build's run in summary.json (api26, api27)")
parser.add_argument("--modes", default="off,on,on0")
parser.add_argument("--benches", default="light,stress")
parser.add_argument("--actions", default="split,close,column,drag")
parser.add_argument("--rounds", type=int, default=3)
opts = parser.parse_args()


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def set_deadline(path, value):
    """syncDeadline in the build's own tunables file (the app has quit: no writer races this); None removes it."""
    data = load(path) or {"version": 1, "values": {}}
    values = data.setdefault("values", {})
    if value is None:
        values.pop(DEADLINE_KEY, None)
    else:
        values[DEADLINE_KEY] = value
    with open(path, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)


def check_mode(mode, hosting):
    out = os.path.join(opts.out, mode, "verify")
    os.makedirs(out, exist_ok=True)
    command = [sys.executable, os.path.join(HERE, "cef-layer-verify.py"), "--app", opts.app, "--tag", opts.tag,
               "--out", out, "--mode", hosting, "--checks", "hosted", "--tunables", "build"]
    print(f"== {mode} verify: {' '.join(command)}", flush=True)
    with open(os.path.join(out, "log.txt"), "w") as log:
        code = subprocess.call(command, stdout=log, stderr=subprocess.STDOUT)
    report = load(os.path.join(out, f"verify-{hosting}.json")) or {}
    rows = report.get("rows") or []
    return code == 0 and bool(rows) and all(r.get("ok") for r in rows), {"exit": code, "rows": rows, **(report.get("facts") or {})}


def bench_command(bench, out):
    common = [sys.executable, os.path.join(HERE, "pane-perf-terminal.py"), "--app", opts.app, "--tag", opts.tag,
              "--out", out, "--actions", opts.actions, "--rounds", str(opts.rounds), "--json", os.path.join(out, "report.json")]
    if bench == "light":
        return common + ["--browser", "--layouts", "1x2,4x2"]
    if bench == "stress":
        return common + ["--layouts", "stress", "--stress-selected", "chromium"]
    raise SystemExit(f"unknown bench {bench}")


def stress_session(log_path):
    """The STRESS-SESSION line the bench printed (the shape perf-stress-session.py built), to quote with the numbers."""
    try:
        for line in open(log_path, errors="replace"):
            if line.startswith("STRESS-SESSION "):
                return json.loads(line[len("STRESS-SESSION "):])
    except (OSError, ValueError):
        pass
    return None


KEYS = ("commit_p95_ms", "commit_max_ms", "missed", "frames_p95_ms", "frames_max_ms", "layout_p95_ms", "refresh_ms")
failures = 0
summary = {"tag": opts.tag, "app": opts.app, "label": opts.label, "validity": {}, "modes": {}}
tunables_file = None
for mode in opts.modes.split(","):
    hosting, deadline = MODES[mode]
    ok, facts = check_mode(mode, hosting)
    summary["validity"][mode] = {"ok": ok, **facts}
    summary["modes"][mode] = {}
    tunables_file = facts.get("tunables_file") or tunables_file
    if not ok or not facts.get("tunables_file"):
        print(f"== {mode}: not a valid {mode} run, no benches: {json.dumps(facts)[:400]}", flush=True)
        failures += 1
        continue
    set_deadline(facts["tunables_file"], deadline)
    for bench in opts.benches.split(","):
        out = os.path.join(opts.out, mode, bench)
        os.makedirs(out, exist_ok=True)
        command = bench_command(bench, out)
        print(f"== {mode} {bench}: {' '.join(command)}", flush=True)
        with open(os.path.join(out, "log.txt"), "w") as log:
            code = subprocess.call(command, stdout=log, stderr=subprocess.STDOUT)
        report = load(os.path.join(out, "report.json")) or {}
        rows = [{"layout": r.get("layout"), "action": r.get("action"), **{k: r.get(k) for k in KEYS}}
                for r in report.get("summary") or []]
        if not rows:
            failures += 1
        summary["modes"][mode][bench] = {"exit": code, "stress_session": stress_session(os.path.join(out, "log.txt")),
                                         "macos": report.get("macos"), "host": report.get("host"),
                                         "rows": rows or {"error": "no report"}}
if tunables_file:
    data = load(tunables_file) or {}
    for key in (HOSTING_KEY, DEADLINE_KEY):
        data.setdefault("values", {}).pop(key, None)
    try:
        with open(tunables_file, "w") as f:
            json.dump(data, f, indent=2, sort_keys=True)
    except OSError:
        pass
with open(os.path.join(opts.out, "summary.json"), "w") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
for mode, benches in summary["modes"].items():
    for bench, result in benches.items():
        for r in result["rows"] if isinstance(result["rows"], list) else []:
            print(f"{opts.label or '-'} {mode:<4} {bench:<6} {r['layout']:<6} {r['action']:<13} commit p95 {r['commit_p95_ms']} "
                  f"max {r['commit_max_ms']} ms  missed {r['missed']} (refresh {r['refresh_ms']} ms)  "
                  f"frame p95 {r['frames_p95_ms']} max {r['frames_max_ms']}  layout p95 {r['layout_p95_ms']}", flush=True)
sys.exit(1 if failures else 0)
