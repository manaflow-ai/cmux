#!/usr/bin/env python3
"""Row 23 verification runner (test harness only, scratch ref, never lands): the WebKit page cadence and the
palette fling, light and STRESS.

Run through the allowlisted fleet entry scripts/measure/split-spring.sh with --arg=--suite=pl-scrolling
(split-spring-terminal.py execs this file with --tag/--app/--out/--json):

  cmux-ci run --class exclusive --measurement --label measure --target-worker cmux20-bench \\
    --script scripts/measure/split-spring.sh --ref SHA --arg=--suite=pl-scrolling \\
    [--arg=--parts=cadence,cadence-stress,cadence-live,fling,fling-stress] --artifact artifacts/split-spring/report.json

Each part launches its own app (the bench scripts kill only what they start). Every part runs even when an
earlier one fails. The exit code is 0 even when a part failed (each part's exit is in the summary), because a
step returns its --artifact only when it passes.
"""
import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

PARTS = {
    "cadence": ["bench-page-cadence.py", "--runs", "6"],
    "cadence-stress": ["bench-page-cadence.py", "--runs", "4", "--stress"],
    "cadence-live": ["bench-page-cadence.py", "--runs", "2", "--live"],
    "fling": ["bench-palette-fling.py", "--runs", "3", "--flings", "4"],
    "fling-stress": ["bench-palette-fling.py", "--runs", "2", "--flings", "4", "--stress"],
}


def display():
    out = subprocess.run(["system_profiler", "SPDisplaysDataType"], capture_output=True, text=True).stdout
    return [line.strip() for line in out.splitlines()
            if "UI Looks like" in line or "Resolution" in line or "Refresh" in line or "Hz" in line]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--app")
    parser.add_argument("--out", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--parts", default="cadence,cadence-stress,cadence-live,fling,fling-stress")
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    host = subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip()
    macos = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    summary = {"host": host, "macos": macos, "head": head, "display": display(), "parts": {}}
    print(f"PL-SCROLLING-VERIFY host {host} macOS {macos} head {head} display {summary['display']}", flush=True)
    for part in [p for p in opts.parts.split(",") if p]:
        script, *args = PARTS[part]
        result = os.path.join(opts.out, f"{part}.json")
        log = os.path.join(opts.out, f"{part}.log")
        cmd = [sys.executable, os.path.join(HERE, script), "--tag", opts.tag, "--json", result, *args]
        print(f"\n===== {part}: {' '.join(cmd)}", flush=True)
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        sys.stdout.write(proc.stdout)
        sys.stdout.flush()
        with open(log, "w") as handle:
            handle.write(proc.stdout)
        data = None
        if os.path.exists(result):
            with open(result) as handle:
                data = json.load(handle)
        summary["parts"][part] = {"exit": proc.returncode, "result": data, "log_tail": proc.stdout[-6000:]}
    with open(opts.json, "w") as out:
        json.dump(summary, out, indent=1)
    print(f"\nPL-SCROLLING-VERIFY-SUMMARY {json.dumps({k: v['exit'] for k, v in summary['parts'].items()})}",
          flush=True)
    sys.exit(0)


if __name__ == "__main__":
    main()
