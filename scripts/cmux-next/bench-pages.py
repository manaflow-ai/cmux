#!/usr/bin/env python3
"""App Store and CodeRouter page bench: open, reopen and typing stalls, Swift page vs React page.

The same method as bench-settings.py (it reuses bench-stalls.py's Run): each run launches the tagged
build with no activation, windows on the last screen and a scratch cmux.json, sets the page's Debug
Settings switch in the tag's debug-tunables.json (native or web), then measures over the socket:

  open1 / open2   `action.run` of the page's show action (focus) until the page answers: the React
                  page through `debug.page <id>` (controls > 0); the Swift page when the action
                  returns (reported as ui = swift, so compare the main-thread gaps, not the clocks).
                  open2 reopens after Cmd-W closed the tab. Also the longest main-thread gap.
  key             (App Store, React only) each character typed into the search field through the
                  app's key path (`debug.key` after the dispatcher's find, Cmd-F) until the field
                  holds it, and the longest main-thread gap per key.

Runs on a GUI fleet host (cmux-lawrence-2), never on the laptop:

  scripts/cmux-next/bench-pages.py --tag <tag> --page apps --variant native --variant web --runs 5

Kills only the apps it launched. Exit 1 when a variant never shows its page.
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
sys.argv = argv

PAGES = {
    "apps": {"page": "cmux.apps", "tunable": "apps.store.surface", "action": "appStore.show", "args": {}, "typed": "awake"},
    "coderouter": {"page": "cmux.coderouter", "tunable": "coderouter.surface", "action": "app.open",
                   "args": {"app": "cmux/coderouter"}, "typed": None},
}


def write_tunable(tag, key, value):
    """The tag's Debug Settings override file (DebugSettingsService); only this bench tag's file."""
    directory = os.path.expanduser(f"~/Library/Application Support/cmux/{tag}")
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, "debug-tunables.json")
    try:
        with open(path) as existing:
            data = json.load(existing)
    except (OSError, ValueError):
        data = {"version": 1, "values": {}}
    data.setdefault("values", {})[key] = value
    with open(path, "w") as out:
        json.dump(data, out, indent=2, sort_keys=True)


def poll(predicate, seconds=20, step=0.01):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # bench poll, not app code
    return None


def react_view(run, page):
    state = run.call("debug.page", {"page": page}).get("result") or {}
    if isinstance(state, dict) and "error" not in state and state.get("controls", 0) > 0:
        return "react", (state.get("active") or {}).get("value", "")
    return None


def timed_open(run, spec, variant, label):
    run.result("debug.hangs", {"clear": True})
    started = time.monotonic()
    params = {"action": spec["action"], "focus": True}
    if spec["args"]:
        params["args"] = spec["args"]
    response = run.call("action.run", params)
    shown = poll(lambda: react_view(run, spec["page"])) if variant == "web" else ("swift", "")
    ms = round((time.monotonic() - started) * 1000, 1) if shown else None
    time.sleep(1.0)  # let the first frames settle before reading the gap
    hangs = run.result("debug.hangs")
    return {f"{label}_ms": ms, f"{label}_max_gap_ms": round(hangs.get("max_gap_ms", 0), 1),
            "ui": shown[0] if shown else None, "ok": bool(response.get("ok", True))}


def typing(run, spec):
    run.call("debug.key", {"key": "f", "modifiers": ["cmd"]})
    time.sleep(0.3)
    latencies, gaps, typed = [], [], ""
    for character in spec["typed"]:
        typed += character
        run.result("debug.hangs", {"clear": True})
        started = time.monotonic()
        run.call("debug.key", {"key": character})
        shown = poll(lambda: (view := react_view(run, spec["page"])) and view[1].endswith(typed), seconds=5)
        latencies.append(round((time.monotonic() - started) * 1000, 1) if shown else None)
        gaps.append(round((run.result("debug.hangs") or {}).get("max_gap_ms", 0), 1))
    landed = [ms for ms in latencies if ms is not None]
    return {"key_median_ms": statistics.median(landed) if landed else None, "key_max_ms": max(landed) if landed else None,
            "keys_landed": len(landed), "key_max_gap_ms": max(gaps) if gaps else None}


def one_run(tag, spec, variant, threshold_ms):
    write_tunable(tag, spec["tunable"], variant)
    scratch = tempfile.mkdtemp(prefix=f"bench-pages-{tag}-")
    with open(os.path.join(scratch, "cmux.json"), "w") as config:
        config.write("{}")
    run = bench.Run(tag, threshold_ms, scratch)
    run.launch()
    try:
        run.wait_launch_settled()
        metrics = timed_open(run, spec, variant, "open1")
        if variant == "web" and spec["typed"]:
            metrics.update(typing(run, spec))
            run.call("debug.key", {"key": "escape"})
        run.call("debug.key", {"key": "w", "modifiers": ["cmd"]})
        time.sleep(1.0)
        metrics.update({k: v for k, v in timed_open(run, spec, variant, "open2").items() if k.startswith("open2")})
        return metrics
    finally:
        bench.stop_tag(tag, run.pid)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--page", choices=sorted(PAGES), required=True)
    parser.add_argument("--variant", action="append", choices=["native", "web"], required=True)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--threshold-ms", type=int, default=8)
    parser.add_argument("--json")
    opts = parser.parse_args()
    spec = PAGES[opts.page]
    print(f"load average {os.getloadavg()}", flush=True)
    results = {variant: [] for variant in opts.variant}
    for index in range(opts.runs):
        for variant in opts.variant:  # interleaved, so machine load affects both alike
            metrics = one_run(opts.tag, spec, variant, opts.threshold_ms)
            results[variant].append(metrics)
            print(f"run {index + 1} {variant}: {json.dumps(metrics)}", flush=True)
    failed = False
    for variant, runs in results.items():
        print(f"\n{opts.page} {variant}:")
        for key in sorted({k for r in runs for k in r if k.endswith("_ms")}):
            values = [r[key] for r in runs if isinstance(r.get(key), (int, float))]
            if values:
                print(f"  {key:22} median {statistics.median(values):8.1f}  min {min(values):8.1f}  max {max(values):8.1f}")
        if not any(r.get("ui") for r in runs):
            failed = True
    if opts.json:
        with open(opts.json, "w") as out:
            json.dump(results, out, indent=1)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
