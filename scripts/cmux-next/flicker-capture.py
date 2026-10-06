#!/usr/bin/env python3
"""Records scripted interactions on a capture Mac and checks each for flicker.

  scripts/cmux-next/flicker-capture.py --host ALIAS --pid PID --window WINDOW_ID \\
      --scenarios SCENARIOS.json --out DIR [--only NAME ...]

Hold a capture-host lease for HOST first. SCENARIOS.json is a list of
{"name", "seconds", "crop": [x, y, w, h] (screen points), "steps": [...]}.
Steps: {"move": [x, y]} (the real pointer, desktop points), {"click": [x, y]}
(window points), {"hotkey": ["cmd", "t"]}, {"key": "escape"},
{"type": "text"}, {"wait": seconds}.

Each scenario is one `screencapture -v` of the crop for `seconds`. The
display's refresh rate sets the frame rate, so a 60 Hz panel gives 60 fps.
The steps run through Cua Driver meanwhile, and the movie is copied back
to OUT/NAME.mov and checked with flicker-check.py. OUT/summary.json holds
every scenario's findings.
"""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DRIVER = "~/.local/bin/cua-driver"


def remote(host, command, check=True):
    return subprocess.run(["ssh", "-o", "ConnectTimeout=10", host, command], check=check,
                          capture_output=True, text=True, timeout=60)


def call(host, tool, payload):
    result = remote(host, f"{DRIVER} call {tool} {json.dumps(json.dumps(payload))}")
    if '"candidates"' in result.stdout or '"isError": true' in result.stdout:
        sys.exit(f"{tool} {payload} did not act: {result.stdout[:300]}")


def step(host, pid, window, item):
    if "move" in item:
        x, y = item["move"]
        call(host, "move_cursor", {"x": x, "y": y, "scope": "desktop"})
    elif "click" in item:
        x, y = item["click"]
        call(host, "click", {"pid": pid, "window_id": window, "x": x, "y": y})
    elif "hotkey" in item:
        call(host, "hotkey", {"pid": pid, "window_id": window, "keys": item["hotkey"]})
    elif "key" in item:
        call(host, "press_key", {"pid": pid, "window_id": window, "key": item["key"]})
    elif "type" in item:
        call(host, "type_text", {"pid": pid, "window_id": window, "text": item["type"]})
    elif "wait" in item:
        time.sleep(item["wait"])
    else:
        sys.exit(f"unknown step {item}")


def record(host, pid, window, scenario, out):
    name, seconds = scenario["name"], scenario["seconds"]
    movie = f"/tmp/flicker-{name}.mov"
    crop = scenario.get("crop")
    rect = f"-R{','.join(str(v) for v in crop)} " if crop else ""
    remote(host, f"rm -f {movie}", check=False)
    capture = subprocess.Popen(["ssh", host, f"screencapture -v -C -V {seconds} {rect}{movie}"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    time.sleep(1.0)
    for item in scenario["steps"]:
        step(host, pid, window, item)
    _, error = capture.communicate(timeout=seconds + 60)
    if capture.returncode:
        sys.exit(f"{name}: screencapture failed: {error.strip()}")
    local = out / f"{name}.mov"
    subprocess.run(["scp", "-q", f"{host}:{movie}", str(local)], check=True)
    return local


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--window", type=int, required=True)
    parser.add_argument("--scenarios", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--only", nargs="*")
    parser.add_argument("--check-args", default="", help="extra flicker-check.py arguments")
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    summary = {}
    for scenario in json.loads(args.scenarios.read_text()):
        if args.only and scenario["name"] not in args.only:
            continue
        movie = record(args.host, args.pid, args.window, scenario, args.out)
        report = args.out / f"{scenario['name']}.json"
        check = subprocess.run([sys.executable, str(HERE / "flicker-check.py"), str(movie), "--json", str(report),
                                "--frames-dir", str(args.out / f"{scenario['name']}-frames"),
                                *args.check_args.split()], capture_output=True, text=True)
        print(f"== {scenario['name']}\n{check.stdout}{check.stderr}", end="")
        summary[scenario["name"]] = json.loads(report.read_text()) if report.exists() else {"error": check.stderr}
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    found = sum(len(s.get("events", [])) for s in summary.values())
    print(f"{found} events across {len(summary)} scenarios")
    sys.exit(1 if found else 0)


if __name__ == "__main__":
    main()
