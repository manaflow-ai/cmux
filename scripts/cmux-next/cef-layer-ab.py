#!/usr/bin/env python3
"""Chromium page window vs layer hosting (fork API 26), A/B in a real window (plans/cmux-next/cef-layer-hosting-DESIGN.md).

Runs the existing benches twice on one tagged build: once with `browserResize.layerHosting` off (the page is a child
window over its pane) and once on (the page's pixels in the cmux window's layer tree). Before each mode's benches,
cef-layer-verify.py --checks hosted --tunables build launches the build the way the benches do, sets the tunable in
the build's own debug-tunables.json (the path the app reports, which every bench launch reads) and checks that the
mode is real: the page is Chromium (no `unavailable`, no `fallback`), fork_api >= 26 in mode on, and
tracker.hosted_pages > 0 in mode on, == 0 in mode off, and debug.layers' CALayerHost counts show the fork moved the
page's pixels out of its page window in mode on and left them there in mode off (`hosted.fork`: in mode on the hosted
context holds Chromium's CALayerHost; the app-side count alone says only that cmux made its view), and a page shown
again after a workspace switch shows its last frame at once (`show.again`). A mode that fails runs no benches and fails the run, so two
"off" runs are never labelled off/on. summary.json records those values per mode.

  switch     sidebar-stress-bench.py switch_matrix at --workspaces workspaces (10 tickers): Chromium and terminal
             workspaces, click / Cmd-digit / Ctrl-Cmd-] ; input to commit (`debug.workspace_switch`), longest frame
  tabs       tab-switch-matrix.py --kinds chromium: Ctrl-Tab, Cmd-Shift-], clicks; input + apply + commit
  light      pane-perf-terminal.py --browser (the top-left pane is a Chromium page): split, close, drag, scroll
  stress     pane-perf-terminal.py --layouts stress --stress-selected chromium: the STRESS session
             (perf-stress-session.py: 60 workspaces, 4x3 + nested splits, every pane showing a Chromium page)

Each run writes OUT/<mode>/<bench>/ (the bench's own report). OUT/summary.json holds the headline rows side by side.
Read the display refresh rate from the pane-perf reports (`refresh_hz`) and judge drops in frames.

Run on a GUI fleet host, never a laptop:
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/cef-layer-ab.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS"
Not a gate: it never fails on a number. Exit 1 when a mode is not what it says, or a bench left no report (a
launch failure or a crash exits 1 too, so the exit code alone does not tell a budget miss from no result).
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
parser.add_argument("--rounds", type=int, default=3)
opts = parser.parse_args()


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def check_mode(mode):
    """cef-layer-verify.py's valid, hosted, hosted.fork and show.again rows for `mode`, in the build's own tunables file; (ok, facts)."""
    out = os.path.join(opts.out, mode, "verify")
    os.makedirs(out, exist_ok=True)
    command = [sys.executable, os.path.join(HERE, "cef-layer-verify.py"), "--app", opts.app, "--tag", opts.tag,
               "--out", out, "--mode", mode, "--checks", "hosted", "--tunables", "build"]
    print(f"== {mode} verify: {' '.join(command)}", flush=True)
    with open(os.path.join(out, "log.txt"), "w") as log:
        code = subprocess.call(command, stdout=log, stderr=subprocess.STDOUT)
    report = load(os.path.join(out, f"verify-{mode}.json")) or {}
    rows = report.get("rows") or []
    ok = code == 0 and bool(rows) and all(r.get("ok") for r in rows)
    return ok, {"exit": code, "rows": rows, **(report.get("facts") or {})}


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
                "--layouts", "stress", "--stress-selected", "chromium", "--actions", "split,close,drag,scroll",
                "--rounds", str(opts.rounds), "--json", os.path.join(out, "report.json")]
    raise SystemExit(f"unknown bench {bench}")


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
    return load(os.path.join(out, "report.json"))


failures = 0
summary = {"tag": opts.tag, "app": opts.app, "modes": {}, "validity": {}}
tunables_file = None
for mode in opts.modes.split(","):
    ok, facts = check_mode(mode)
    summary["validity"][mode] = {"ok": ok, **facts}
    tunables_file = facts.get("tunables_file") or tunables_file
    summary["modes"][mode] = {}
    if not ok:
        print(f"== {mode}: not a valid {mode} run, no benches: {json.dumps(facts)[:400]}", flush=True)
        failures += 1
        continue
    for bench in opts.benches.split(","):
        out = os.path.join(opts.out, mode, bench)
        os.makedirs(out, exist_ok=True)
        command = bench_command(bench, out)
        print(f"== {mode} {bench}: {' '.join(command)}", flush=True)
        with open(os.path.join(out, "log.txt"), "w") as log:
            code = subprocess.call(command, stdout=log, stderr=subprocess.STDOUT)
        rows = headline(bench, out)
        # A report is the result (exit 1 with one is the bench's own budget miss). No report is no result,
        # whatever the exit code: the app never came up, or the bench crashed.
        if not rows:
            failures += 1
        summary["modes"][mode][bench] = {"exit": code, "rows": rows if rows else {"error": "no report"}}
if tunables_file:
    try:
        with open(tunables_file) as f:
            data = json.load(f)
        data.setdefault("values", {}).pop(KEY, None)
        with open(tunables_file, "w") as f:
            json.dump(data, f, indent=2, sort_keys=True)
    except (OSError, ValueError):
        pass
with open(os.path.join(opts.out, "summary.json"), "w") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
print(json.dumps({"validity": {m: v["ok"] for m, v in summary["validity"].items()},
                  "exit": {m: {b: v["exit"] for b, v in r.items()} for m, r in summary["modes"].items()}}))
sys.exit(1 if failures else 0)
