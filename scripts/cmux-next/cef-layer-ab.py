#!/usr/bin/env python3
"""Chromium page window vs layer hosting (fork API 26), A/B in a real window (plans/cmux-next/cef-layer-hosting-DESIGN.md).

Runs the existing benches twice on one tagged build: once with `browserResize.layerHosting` off (the page is a child
window over its pane) and once on (the page's pixels in the cmux window's layer tree). The tunable goes into the tag's
debug-tunables.json before each launch, so every page of the run is hosted or not from its first frame.

  switch     sidebar-stress-bench.py switch_matrix at --workspaces workspaces (10 tickers): Chromium and terminal
             workspaces, click / Cmd-digit / Ctrl-Cmd-] ; input to commit (`debug.workspace_switch`), longest frame
  tabs       tab-switch-matrix.py --kinds chromium: Ctrl-Tab, Cmd-Shift-], clicks; input + apply + commit
  light      pane-perf-terminal.py --browser (the top-left pane is a Chromium page): split, close, drag, scroll
  stress     pane-perf-terminal.py --content chromium at --stress-layout (every pane a Chromium page)

Each run writes OUT/<mode>/<bench>/ (the bench's own report). OUT/summary.json holds the headline rows side by side.
Read the display refresh rate from the pane-perf reports (`refresh_hz`) and judge drops in frames.

Run on a GUI fleet host, never a laptop:
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/cef-layer-ab.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS"
Not a gate: it never fails on a number (exit 1 only when a bench could not run).
"""
import argparse, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
KEY = "browserResize.layerHosting"

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--modes", default="off,on", help="off = page child windows, on = layer hosting")
parser.add_argument("--benches", default="switch,tabs,light,stress")
parser.add_argument("--workspaces", type=int, default=60)
parser.add_argument("--stress-layout", default="4x3")
parser.add_argument("--rounds", type=int, default=3)
opts = parser.parse_args()


def write_tunable(value):
    """The tag's Debug Settings override file (DebugSettingsService.fileURL); only this tag's file."""
    directory = os.path.expanduser(f"~/Library/Application Support/cmux/{opts.tag}")
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, "debug-tunables.json")
    try:
        with open(path) as existing:
            data = json.load(existing)
    except (OSError, ValueError):
        data = {"version": 1, "values": {}}
    data.setdefault("values", {})[KEY] = value
    with open(path, "w") as out:
        json.dump(data, out, indent=2, sort_keys=True)


def bench_command(bench, out):
    common = ["--app", opts.app, "--tag", opts.tag]
    if bench == "switch":
        return [sys.executable, os.path.join(HERE, "sidebar-stress-bench.py"), *common, "--out", out,
                "--sizes", str(opts.workspaces), "--tickers", "10", "--scenarios", "switch_matrix", "--no-trace", "--stop"]
    if bench == "tabs":
        return [sys.executable, os.path.join(HERE, "tab-switch-matrix.py"), *common, "--out", out,
                "--kinds", "chromium", "--counts", "2,10", "--json", os.path.join(out, "report.json")]
    if bench == "light":
        return [sys.executable, os.path.join(HERE, "pane-perf-terminal.py"), *common, "--out", out, "--browser",
                "--layouts", "1x2,4x2", "--actions", "split,close,drag,scroll", "--rounds", str(opts.rounds),
                "--json", os.path.join(out, "report.json")]
    if bench == "stress":
        return [sys.executable, os.path.join(HERE, "pane-perf-terminal.py"), *common, "--out", out,
                "--content", "chromium", "--layouts", opts.stress_layout, "--actions", "split,close,drag",
                "--rounds", str(opts.rounds), "--json", os.path.join(out, "report.json")]
    raise SystemExit(f"unknown bench {bench}")


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def headline(bench, out):
    """The rows to compare; the full report stays in the bench's folder."""
    if bench == "switch":
        report = load(os.path.join(out, "results.json")) or {}
        rows = {}
        for size in (report.get("sizes") or {}).values() if isinstance(report.get("sizes"), dict) else []:
            for key, entry in (size.get("switch_matrix") or {}).items():
                if isinstance(entry, dict) and "input_to_idle_ms" in entry:
                    rows[key] = {k: entry.get(k) for k in ("input_to_commit_ms", "input_to_idle_ms", "longest_frame_ms")}
        return rows or report
    report = load(os.path.join(out, "report.json"))
    return report if report is not None else {"error": "no report"}


failures = 0
summary = {"tag": opts.tag, "app": opts.app, "modes": {}}
for mode in opts.modes.split(","):
    write_tunable(mode == "on")
    summary["modes"][mode] = {}
    for bench in opts.benches.split(","):
        out = os.path.join(opts.out, mode, bench)
        os.makedirs(out, exist_ok=True)
        command = bench_command(bench, out)
        print(f"== {mode} {bench}: {' '.join(command)}", flush=True)
        with open(os.path.join(out, "log.txt"), "w") as log:
            code = subprocess.call(command, stdout=log, stderr=subprocess.STDOUT)
        if code not in (0, 1):  # 1 = a bench's own budget miss; still a result
            failures += 1
        summary["modes"][mode][bench] = {"exit": code, "rows": headline(bench, out)}
write_tunable(False)
with open(os.path.join(opts.out, "summary.json"), "w") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
print(json.dumps({m: {b: v["exit"] for b, v in r.items()} for m, r in summary["modes"].items()}))
sys.exit(1 if failures else 0)
