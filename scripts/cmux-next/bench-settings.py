#!/usr/bin/env python3
"""Settings open and typing bench (R82: Swift Settings vs the React Settings page).

Launches each tagged build the way bench-stalls.py does (no activation, windows on the last
screen, a scratch cmux.json), then measures over the control socket, per run:

  open1 / open2   `action.run openSettings` (focus) to the moment Settings answers with content:
                  the Swift model (`debug.settings`) or the React page (`debug.page cmux.settings`
                  shows a section title). open2 reopens after the tab closed (Cmd-W through the
                  app's key path). Also the longest main-thread gap while it opens (debug.hangs).
  key             each character typed into the Settings search field through the app's key path
                  (`debug.key`, after the dispatcher's find, Cmd-F) to the moment the field holds it,
                  and the longest main-thread gap per key.

The clock includes one control-socket round trip per poll (10 ms polls), the same for both builds.
Several tags run interleaved, so machine load affects before and after alike:

  scripts/cmux-next/bench-settings.py --tag before --tag after --runs 5 [--json out.json]

Kills only the apps it launched (bench-stalls.py's Run). Exit 1 when a tag never shows Settings.
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

TYPED = "fontsize"


def settings_view(run):
    """('swift'|'react', query) once Settings shows content, else None."""
    page = run.call("debug.page", {"page": "cmux.settings"}).get("result") or {}
    if isinstance(page, dict) and "error" not in page and page.get("controls", 0) > 0:
        return "react", (page.get("active") or {}).get("value", "")
    model = run.call("debug.settings").get("result") or {}
    if isinstance(model, dict) and "error" not in model and model.get("section"):
        return "swift", model.get("query", "")
    return None


def poll(predicate, seconds=20, step=0.01):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # bench poll, not app code
    return None


def timed_open(run, label):
    run.result("debug.hangs", {"clear": True})
    started = time.monotonic()
    response = run.call("action.run", {"action": "openSettings", "focus": True})
    shown = poll(lambda: settings_view(run))
    ms = round((time.monotonic() - started) * 1000, 1) if shown else None
    time.sleep(1.0)  # let the first frames settle before reading the gap
    hangs = run.result("debug.hangs")
    return {f"{label}_ms": ms, f"{label}_max_gap_ms": round(hangs.get("max_gap_ms", 0), 1),
            "ui": shown[0] if shown else None, "ok": bool(response.get("ok", True))}


def typing(run):
    run.call("debug.key", {"key": "f", "modifiers": ["cmd"]})
    time.sleep(0.3)
    latencies, gaps, typed = [], [], ""
    for character in TYPED:
        typed += character
        run.result("debug.hangs", {"clear": True})
        started = time.monotonic()
        run.call("debug.key", {"key": character})
        shown = poll(lambda: (view := settings_view(run)) and view[1].endswith(typed), seconds=5)
        latencies.append(round((time.monotonic() - started) * 1000, 1) if shown else None)
        gaps.append(round((run.result("debug.hangs") or {}).get("max_gap_ms", 0), 1))
    landed = [ms for ms in latencies if ms is not None]
    if not landed and (settings_view(run) or ("", ""))[0] == "swift":
        return swift_query_typing(run)
    return {"key_median_ms": statistics.median(landed) if landed else None, "key_max_ms": max(landed) if landed else None,
            "keys_landed": len(landed), "key_max_gap_ms": max(gaps) if gaps else None}


def swift_query_typing(run):
    """The Swift field takes no synthesized keys in a window that is never key: set the query the
    way the field's binding does (`debug.settings query`) and measure the main-thread gap of each
    re-render (reported as key_*, marked keys_via = model)."""
    gaps, latencies, typed = [], [], ""
    for character in TYPED:
        typed += character
        run.result("debug.hangs", {"clear": True})
        started = time.monotonic()
        run.call("debug.settings", {"action": "query", "text": typed})
        latencies.append(round((time.monotonic() - started) * 1000, 1))
        time.sleep(0.2)  # let the re-render frames land before reading the gap
        gaps.append(round((run.result("debug.hangs") or {}).get("max_gap_ms", 0), 1))
    return {"key_median_ms": statistics.median(latencies), "key_max_ms": max(latencies), "keys_landed": len(latencies),
            "key_max_gap_ms": max(gaps), "keys_via": "model"}


def one_run(tag, threshold_ms):
    scratch = tempfile.mkdtemp(prefix=f"bench-settings-{tag}-")
    with open(os.path.join(scratch, "cmux.json"), "w") as config:
        config.write("{}")
    run = bench.Run(tag, threshold_ms, scratch)
    run.launch()
    try:
        run.wait_launch_settled()
        metrics = {}
        first = timed_open(run, "open1")
        metrics.update(first)
        metrics.update(typing(run))
        run.call("debug.key", {"key": "escape"})
        run.call("debug.key", {"key": "w", "modifiers": ["cmd"]})
        time.sleep(1.0)
        metrics.update({k: v for k, v in timed_open(run, "open2").items() if k.startswith("open2")})
        return metrics
    finally:
        bench.stop_tag(tag, run.pid)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", action="append", required=True)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--threshold-ms", type=int, default=8)
    parser.add_argument("--json")
    opts = parser.parse_args()
    print(f"load average {os.getloadavg()}", flush=True)
    results = {tag: [] for tag in opts.tag}
    for index in range(opts.runs):
        for tag in opts.tag:
            metrics = one_run(tag, opts.threshold_ms)
            results[tag].append(metrics)
            print(f"run {index + 1} {tag}: {json.dumps(metrics)}", flush=True)
    failed = False
    for tag, runs in results.items():
        print(f"\n{tag} ({runs[0].get('ui') if runs else '?'}):")
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
