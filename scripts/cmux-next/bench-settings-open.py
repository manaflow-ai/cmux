#!/usr/bin/env python3
"""Settings open bench: Cmd-, to the Settings tab and to the Settings page shown, per display frame.

Each run launches the tagged build the way bench-stalls.py does (no activation, windows on the last
screen, a scratch cmux.json, no saved state: bench-startup.py's reset_state), waits for launch to settle, then presses Cmd-, through the app's key
path `--opens` times (`debug.new_tab {action: "bench_settings"}`, DebugNewTabBench.settings), then
closes the tab with Cmd-W (`debug.key`). The first open of a run is the cold one (no Settings page this launch);
the others are reopens; an open of a Settings tab still open (`already_open`) is left out. Per open it reports `tab_ms` (the strip selects Settings), `visible_ms` (the
pane shows the painted Settings page) and `gap_ms` between them. Several tags run interleaved, so
machine load affects before and after alike:

  scripts/cmux-next/bench-settings-open.py --tag before --tag after --runs 5 [--settle 6] [--json out.json]

Runs on a GUI fleet host (cmux-lawrence-2), never on the person's Mac. Kills only the apps it launched.
"""
import argparse
import importlib.util
import json
import os
import statistics
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bench_stalls", os.path.join(HERE, "bench-stalls.py"))
bench = importlib.util.module_from_spec(spec)
sys.argv, argv = sys.argv[:1], sys.argv
spec.loader.exec_module(bench)
startup_spec = importlib.util.spec_from_file_location("bench_startup", os.path.join(HERE, "bench-startup.py"))
startup = importlib.util.module_from_spec(startup_spec)
sys.argv = argv[:1]
startup_spec.loader.exec_module(startup)
sys.argv = argv


def one_run(tag, opts):
    scratch = tempfile.mkdtemp(prefix=f"bench-settings-open-{tag}-")
    with open(os.path.join(scratch, "cmux.json"), "w") as config:
        config.write(opts.config)
    run = bench.Run(tag, opts.threshold_ms, scratch)
    # A first launch every run: no saved workspaces, so no Settings tab an earlier run left (it would show on Cmd-W).
    startup.reset_state(tag)
    run.launch()
    try:
        run.wait_launch_settled()
        time.sleep(opts.settle)  # idle warmups (page host pool, Chromium) run as they would for a person
        opens = []
        for _ in range(opts.opens):
            opened = run.result("debug.new_tab", {"action": "bench_settings"})
            run.result("debug.key", {"key": "w", "modifiers": ["command"]})
            tab, shown = opened.get("tab_ms"), opened.get("visible_ms")
            opened.setdefault("gap_ms", shown - tab if isinstance(tab, (int, float)) and isinstance(shown, (int, float)) else None)
            opens.append(opened)
            time.sleep(1.0)  # the closed tab's teardown and any rebuilt spare settle before the next open
        return opens
    finally:
        bench.stop_tag(tag, run.pid)


def split_opens(runs):
    """(cold, warm, refocused): the first open of each run is cold, the others warm; an open of a Settings
    tab already open (`already_open`: a Cmd-W that closed another tab) is neither, only reported. A build
    without the field counts every open."""
    cold, warm, refocused = [], [], []
    for run in runs:
        for index, result in enumerate(run):
            if result.get("already_open"):
                refocused.append(result)
            else:
                (warm if index else cold).append(result)
    return cold, warm, refocused


def summary(values):
    values = [v for v in values if isinstance(v, (int, float))]
    if not values:
        return "n/a"
    return f"median {statistics.median(values):7.1f}  min {min(values):7.1f}  max {max(values):7.1f}  (n={len(values)})"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", action="append", required=True)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--opens", type=int, default=4, help="opens per launch; the first is cold")
    parser.add_argument("--settle", type=float, default=6.0, help="seconds of idle after launch before the first open")
    parser.add_argument("--threshold-ms", type=int, default=8)
    parser.add_argument("--config", default="{}", help="the scratch cmux.json text")
    parser.add_argument("--json")
    opts = parser.parse_args()
    print(f"load average {os.getloadavg()}", flush=True)
    results = {tag: [] for tag in opts.tag}
    for index in range(opts.runs):
        for tag in opts.tag:
            opens = one_run(tag, opts)
            results[tag].append(opens)
            brief = [{k: o.get(k) for k in ("tab_ms", "visible_ms", "engine", "spare", "claim", "key_ms", "already_open")} for o in opens]
            print(f"run {index + 1} {tag}: {json.dumps(brief)}", flush=True)
    failed = False
    for tag, runs in results.items():
        cold, warm, refocused = split_opens(runs)
        print(f"\n{tag}:")
        if refocused:
            print(f"  {len(refocused)} open(s) left out: Settings was still open (Cmd-W closed another tab)")
        for label, group in (("cold", cold), ("warm", warm)):
            for key in ("tab_ms", "visible_ms", "gap_ms"):
                print(f"  {label} {key:11} {summary([o.get(key) for o in group])}")
        if any(o.get("visible_ms") is None for o in cold + warm):
            failed = True
    if opts.json:
        with open(opts.json, "w") as out:
            json.dump(results, out, indent=1)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
