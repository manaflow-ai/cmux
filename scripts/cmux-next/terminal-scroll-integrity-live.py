#!/usr/bin/env python3
"""Check a dedicated NEXT terminal's native viewport during output.

Run on a fleet capture host against an owned, already running tagged app:
  --tag scroll-integrity --tab TAB --transport local --out REPORT.json

Repeat for a terminal connected through SSH or Cloud, naming that transport.
The terminal must be at an idle shell with python3 available. Configure enough
scrollback on this test app and its remote daemon to retain the producer's rows;
this probe does not change retention settings. Rust's scroll_stress tests check
every retained row; this check exercises the native mirror and user actions.
--producer yes runs the requested yes/date/head pipeline after the numbered
anchor rows. The producer has a 60-second lifetime bound and never receives
input while the probe is checking its held viewport.
"""

import argparse
import base64
import json
import pathlib
import shlex
import socket
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--tab", required=True)
    parser.add_argument("--transport", choices=("local", "ssh", "cloud"), required=True)
    parser.add_argument("--producer", choices=("numbered", "yes"), default="numbered")
    parser.add_argument("--out", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if not args.tag or any(c not in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in args.tag):
        parser.error("--tag must name a dedicated lowercase tagged app")
    endpoint = f"/tmp/cmux-debug-{args.tag}.sock"
    token = "scroll-probe-" + uuid.uuid4().hex
    report = {"tag": args.tag, "tab": args.tab, "transport": args.transport,
              "producer": args.producer, "token": token, "samples": [], "passed": False}

    def rpc(method, params):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(10)
            conn.connect(endpoint)
            conn.sendall((json.dumps({"id": token, "method": method, "params": params}) + "\n").encode())
            with conn.makefile("rb") as stream:
                answer = json.loads(stream.readline(16 << 20))
        if not answer.get("ok"):
            raise RuntimeError(f"{method}: {answer.get('error')}")
        return answer["result"]

    def pane():
        value = rpc("debug.surfaces", {"text": True})
        for window in value.get("windows", []):
            for item in window.get("panes", []):
                if item.get("selected_tab") == args.tab:
                    if "scrollbar" not in item or "terminal_title" not in item:
                        raise RuntimeError("build lacks native scroll integrity diagnostics")
                    return item
        raise RuntimeError("the owned terminal must remain visible throughout the probe")

    def action(name, **extra):
        return rpc("action.run", {"action": name, "target": {"kind": "tab", "id": args.tab},
                                  "origin": "script", **extra})

    def wait_for(predicate, description, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = pane()
            if predicate(value):
                return value
            time.sleep(0.025)  # bounded native-state observation, not CI status polling
        raise RuntimeError(f"timed out waiting for {description}")

    # The pause is a controlled mid-stream observation window. If the app
    # cannot scroll before it ends, fail instead of claiming a flood check.
    producer = f'''
import signal, subprocess, sys, time
signal.alarm(60)
def title(stage):
    sys.stdout.write("\\x1b]2;{token}-" + stage + "\\x07")
    sys.stdout.flush()
def rows(start, end):
    for first in range(start, end + 1, 500):
        sys.stdout.write("".join(f"\\x1b[3{{i % 8}}mrow-{{i:06}} 界宽\\x1b[0m\\n"
                                 for i in range(first, min(first + 500, end + 1))))
        sys.stdout.flush()
rows(1, 2000)
title("ready")
time.sleep(5)
title("flood")
if {args.producer == 'yes'!r}:
    subprocess.run('yes "$(date)" | head -500000', shell=True, check=True, timeout=40)
else:
    rows(2001, 200000)
sys.stdout.write("\\n{token}-complete\\n")
title("done")
time.sleep(10)
sys.stdout.write("\\n{token}-follow\\n")
sys.stdout.flush()
'''
    encoded = base64.b64encode(producer.encode()).decode()
    command = "python3 -c " + shlex.quote("import base64;exec(base64.b64decode(" + repr(encoded) + "))")
    try:
        report["before"] = pane()
        action("terminal.sendText", args={"text": command + "\r"})
        ready = wait_for(lambda p: p["terminal_title"] == token + "-ready", "anchor rows", 15)
        action("terminal.scrollPageUp")
        held = wait_for(lambda p: p["scrollbar"]["offset_rows"] <
                        p["scrollbar"]["total_rows"] - p["scrollbar"]["visible_rows"],
                        "native scroll up", 3)
        if held["terminal_title"] != token + "-ready" or "row-" not in held.get("text", ""):
            raise RuntimeError("missed the controlled mid-stream scroll window")
        report["ready"] = ready
        report["held"] = held
        deadline = time.monotonic() + 50
        while True:
            sample = pane()
            report["samples"].append({"at": time.monotonic(), "scrollbar": sample["scrollbar"],
                                      "snapshots": sample.get("snapshots"),
                                      "title": sample["terminal_title"]})
            if sample.get("text") != held.get("text"):
                report["changed_viewport"] = sample
                raise RuntimeError("output changed or blanked the held native viewport")
            if sample["scrollbar"]["offset_rows"] != held["scrollbar"]["offset_rows"]:
                raise RuntimeError("output moved the native scroll offset")
            if sample["terminal_title"] == token + "-done":
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("producer did not finish within its observation deadline")
            time.sleep(0.025)
        action("terminal.scrollToBottom")
        report["bottom"] = wait_for(
            lambda p: token + "-complete" in p.get("text", "") and
            p["scrollbar"]["offset_rows"] == p["scrollbar"]["total_rows"] - p["scrollbar"]["visible_rows"],
            "bottom output", 5)
        # Further output arrives without any input that could itself force
        # scroll-to-bottom and conceal a broken follow transition.
        report["follow"] = wait_for(lambda p: token + "-follow" in p.get("text", "") and
                                   p["scrollbar"]["offset_rows"] ==
                                   p["scrollbar"]["total_rows"] - p["scrollbar"]["visible_rows"],
                                   "following subsequent output", 15)
        report["passed"] = True
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"passed": report["passed"], "report": str(args.out),
                          "error": report.get("error")}))


if __name__ == "__main__":
    main()
