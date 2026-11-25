#!/usr/bin/env python3
"""Records scripted interactions on a capture Mac and checks each for flicker.

  scripts/cmux-next/flicker-capture.py --host ALIAS --pid PID --window WINDOW_ID \\
      --scenarios SCENARIOS.json --out DIR [--only NAME ...]

Hold a capture-host lease for HOST first. SCENARIOS.json is a list of
{"name", "crop": [x, y, w, h] (screen points), "steps": [...]}.
Steps: {"move": [x, y]} (the real pointer, desktop points), {"click": [x, y]}
(window points), {"hotkey": ["cmd", "t"]}, {"key": "escape"},
{"type": "text"}, {"wait": seconds}, {"mark": "label"}.

Each scenario is one display recording by Cua Driver's recorder
(ScreenCaptureKit, which holds the Screen Recording grant; `screencapture`
over SSH has none). The recorder lives as long as its client, so one MCP
session on the Mac starts it, runs the steps and stops it. It captures at
up to 30 fps, so a single 60 Hz frame can fall between captures: anything
lasting two frames or more shows. The movie lands in OUT/NAME.mp4 with the
step marks in OUT/NAME.steps.txt, and flicker-check.py checks the crop.
OUT/summary.json holds every scenario's findings.
"""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Runs on the Mac: one Cua Driver MCP session records the display while the steps run.
RUNNER = r'''
import json, os, subprocess, sys, time
steps = json.load(open(sys.argv[1])); out = os.path.expanduser(sys.argv[2])
driver = subprocess.Popen([os.path.expanduser("~/.local/bin/cua-driver"), "mcp"],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
ids = iter(range(1, 1 << 30))
def rpc(method, params=None, notify=False):
    message = {"jsonrpc": "2.0", "method": method, **({"params": params} if params is not None else {})}
    if not notify: message["id"] = next(ids)
    driver.stdin.write(json.dumps(message) + "\n"); driver.stdin.flush()
    while not notify:
        line = driver.stdout.readline()
        if not line: sys.exit("cua-driver mcp closed")
        reply = json.loads(line)
        if reply.get("id") == message["id"]:
            if "error" in reply or reply.get("result", {}).get("isError"):
                sys.exit(f"{params}: {json.dumps(reply)[:300]}")
            return reply
rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "flicker", "version": "1"}})
rpc("notifications/initialized", notify=True)
# The agent cursor overlay glides to each click: it would read as app motion.
rpc("tools/call", {"name": "set_agent_cursor_enabled", "arguments": {"enabled": False}})
rpc("tools/call", {"name": "start_recording", "arguments": {"output_dir": out, "record_video": True}})
start = time.time()
for step in steps:
    if "mark" in step: print("%s %.3f" % (step["mark"], time.time() - start), flush=True)
    elif "wait" in step: time.sleep(step["wait"])
    else: rpc("tools/call", {"name": step["tool"], "arguments": step["args"]})
rpc("tools/call", {"name": "stop_recording", "arguments": {}})
'''


def tool_steps(pid, window, steps):
    """Scenario steps as Cua Driver tool calls."""
    calls = []
    for item in steps:
        target = {"pid": pid, "window_id": window}
        if "move" in item:
            calls.append({"tool": "move_cursor", "args": {"x": item["move"][0], "y": item["move"][1], "scope": "desktop"}})
        elif "click" in item:
            calls.append({"tool": "click", "args": {**target, "x": item["click"][0], "y": item["click"][1]}})
        elif "hotkey" in item:
            calls.append({"tool": "hotkey", "args": {**target, "keys": item["hotkey"]}})
        elif "key" in item:
            calls.append({"tool": "press_key", "args": {**target, "key": item["key"]}})
        elif "type" in item:
            calls.append({"tool": "type_text", "args": {**target, "text": item["type"]}})
        elif "wait" in item or "mark" in item:
            calls.append(item)
        else:
            sys.exit(f"unknown step {item}")
    return calls


def record(host, pid, window, scenario, out):
    name = scenario["name"]
    remote_dir = f"~/flicker-capture/{name}"
    with tempfile.TemporaryDirectory() as scratch:
        runner, steps = Path(scratch, "runner.py"), Path(scratch, "steps.json")
        runner.write_text(RUNNER)
        steps.write_text(json.dumps(tool_steps(pid, window, scenario["steps"])))
        subprocess.run(["scp", "-q", str(runner), str(steps), f"{host}:/tmp/"], check=True)
    run = subprocess.run(["ssh", host, f"rm -rf {remote_dir} && python3 /tmp/runner.py /tmp/steps.json {remote_dir}"],
                         capture_output=True, text=True, timeout=600)
    if run.returncode:
        sys.exit(f"{name}: {run.stderr.strip() or run.stdout.strip()}")
    (out / f"{name}.steps.txt").write_text(run.stdout)
    local = out / f"{name}.mp4"
    subprocess.run(["scp", "-q", f"{host}:{remote_dir}/recording.mp4", str(local)], check=True)
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
        crop = ["--crop", ",".join(str(v) for v in scenario["crop"])] if scenario.get("crop") else []
        check = subprocess.run([sys.executable, str(HERE / "flicker-check.py"), str(movie), *crop, "--json", str(report),
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
