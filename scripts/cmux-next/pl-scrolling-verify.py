#!/usr/bin/env python3
"""Row 23 verification runner (test harness only): the WebKit page cadence and the palette fling, light and STRESS.

Run through the allowlisted fleet entry scripts/measure/split-spring.sh with --arg=--suite=pl-scrolling
(split-spring-terminal.py execs this file with --tag/--app/--out/--json):

  cmux-ci run --class exclusive --measurement --label measure --target-worker cmux20-bench \\
    --script scripts/measure/split-spring.sh --ref SHA --arg=--suite=pl-scrolling \\
    [--arg=--parts=cadence,cadence-stress,fling,fling-stress] --artifact artifacts/split-spring/report.json

Each part launches its own app (the bench scripts kill only what they start). Every part runs even when an
earlier one fails. The exit code is 0 even when a part failed (each part's exit is in the summary), because a
step returns its --artifact only when it passes; the fling captures ride in the report, base64, shrunk by sips.
"""
import base64
import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

PARTS = {
    "cadence": ["bench-page-cadence.py", "--runs", "3"],
    "cadence-stress": ["bench-page-cadence.py", "--runs", "2", "--stress"],
    "fling": ["bench-palette-fling.py", "--flings", "6"],
    "fling-stress": ["bench-palette-fling.py", "--flings", "6", "--stress"],
}


def display():
    out = subprocess.run(["system_profiler", "SPDisplaysDataType"], capture_output=True, text=True).stdout
    return [line.strip() for line in out.splitlines() if "UI Looks like" in line or "Resolution" in line]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--app")
    parser.add_argument("--out", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--parts", default="cadence,cadence-stress,fling,fling-stress")
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    host = subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip()
    macos = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    summary = {"host": host, "macos": macos, "display": display(), "parts": {}}
    print(f"PL-SCROLLING-VERIFY host {host} macOS {macos} display {summary['display']}", flush=True)
    failed = False
    for part in [p for p in opts.parts.split(",") if p]:
        script, *args = PARTS[part]
        result = os.path.join(opts.out, f"{part}.json")
        cmd = [sys.executable, os.path.join(HERE, script), "--tag", opts.tag, "--json", result, *args]
        if script == "bench-palette-fling.py":
            cmd += ["--out", os.path.join(opts.out, f"{part}-captures")]
        print(f"\n===== {part}: {' '.join(cmd)}", flush=True)
        code = subprocess.run(cmd).returncode
        failed = failed or code != 0
        data = None
        if os.path.exists(result):
            with open(result) as handle:
                data = json.load(handle)
        summary["parts"][part] = {"exit": code, "result": data}
        captures = os.path.join(opts.out, f"{part}-captures")
        if os.path.isdir(captures):
            images = {}
            for name in sorted(os.listdir(captures)):
                if not name.endswith(".png"):
                    continue
                small = os.path.join(captures, "small-" + name)
                subprocess.run(["sips", "-Z", "700", os.path.join(captures, name), "--out", small], capture_output=True)
                if os.path.exists(small):
                    with open(small, "rb") as handle:
                        images[name] = base64.b64encode(handle.read()).decode()
            summary["parts"][part]["captures_png_b64"] = images
    with open(opts.json, "w") as out:
        json.dump(summary, out, indent=1)
    print(f"\nPL-SCROLLING-VERIFY-SUMMARY {json.dumps({k: v['exit'] for k, v in summary['parts'].items()})}", flush=True)
    print(f"PL-SCROLLING-VERIFY-FAILED {failed}", flush=True)
    sys.exit(0)


if __name__ == "__main__":
    main()
