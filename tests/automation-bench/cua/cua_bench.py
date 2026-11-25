#!/usr/bin/env python3
"""CU4 primitive bench, desktop leg (plans/cmux-next/automation-bench.md).

Drives a private Calculator instance through a cmux-cua helper socket and
writes scorer rows (tests/automation-bench/score.mjs schema) as JSONL.
Oracles are independent of the driver: the Calculator display read back
through AX, and the frontmost app from lsappinfo (the target must never
become frontmost).

  cua_bench.py --socket SOCK --driver NAME [--snapshots 20] [--trials 20]
               [--fast-detect] [--out results.jsonl]
"""
import argparse
import json
import re
import socket
import subprocess
import sys
import time

LABELS = {"clear": ["All Clear", "Clear", "AC", "C"], "7": ["7"], "8": ["8"], "add": ["Add", "+"], "eq": ["Equals", "="]}
SEQUENCE = ("clear", "7", "add", "8", "eq")


def rpc(sock_path, request, timeout=60):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path)
    s.sendall((json.dumps(request) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf)


def call(sock_path, name, args):
    started = time.perf_counter()
    reply = rpc(sock_path, {"method": "call", "name": name, "args": args, "session_id": "nx-bench"})
    return reply, (time.perf_counter() - started) * 1000


def frontmost_bundle():
    asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    out = subprocess.run(["lsappinfo", "info", "-only", "bundleid", asn], capture_output=True, text=True).stdout
    match = re.search(r'bundleID="([^"]*)"', out)
    return match.group(1) if match else ""


def find(elements, key):
    for want in LABELS[key]:
        for element in elements:
            if "element_index" in element and want in (element.get("label"), element.get("description")):
                return element["element_index"]
    return None


def display_values(elements):
    return [e.get("value") for e in elements if e.get("role") == "AXStaticText" and e.get("value")]


def shows(values, expected):
    return any(v.replace("‎", "").strip() == expected for v in values)


def trial_row(index, driver, ok, click_ms, focus_preserved, error=None):
    """One scorer row; failure categories come from score.mjs."""
    row = {
        "task_id": f"calc-7+8-{index}", "domain": "desktop", "driver": driver, "level": "primitive",
        "live": False, "ok": ok, "steps": len(SEQUENCE), "wall_ms": round(sum(click_ms)),
        "focus_preserved": focus_preserved, "latencies": {"click": [round(ms, 1) for ms in click_ms]},
    }
    if not ok:
        row["failure"] = "focus_stolen" if not focus_preserved else ("input" if error else "not_landed")
    return row


def snapshot(sock_path, pid, wid, shot):
    reply, ms = call(sock_path, "get_window_state", {"pid": pid, "window_id": wid, "include_screenshot": shot})
    result = reply.get("result", {})
    elements = (result.get("structuredContent") or {}).get("elements", [])
    has_image = any(c.get("type") == "image" for c in result.get("content", []))
    return elements, ms, has_image


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--driver", required=True)
    parser.add_argument("--snapshots", type=int, default=20)
    parser.add_argument("--trials", type=int, default=20)
    parser.add_argument("--fast-detect", action="store_true",
                        help="skip the native post-action window poll (pre-0.8 engines)")
    parser.add_argument("--out", default="results.jsonl")
    args = parser.parse_args(argv)

    reply, _ = call(args.socket, "launch_app", {"bundle_id": "com.apple.calculator", "creates_new_application_instance": True})
    launched = reply["result"]["structuredContent"]
    pid = launched["pid"]
    windows = launched.get("windows") or []
    for _ in range(20):
        if windows:
            break
        time.sleep(0.25)
        windows = (call(args.socket, "list_windows", {"pid": pid})[0]["result"].get("structuredContent") or {}).get("windows") or []
    wid = windows[0]["window_id"]
    rows = []
    try:
        ax_only, with_shot, screenshots = [], [], 0
        for _ in range(args.snapshots):
            ax_only.append(snapshot(args.socket, pid, wid, False)[1])
            _, ms, has_image = snapshot(args.socket, pid, wid, True)
            with_shot.append(ms)
            screenshots += has_image
        rows.append({"task_id": "snapshot", "domain": "desktop", "driver": args.driver, "level": "primitive",
                     "live": False, "ok": True, "steps": args.snapshots, "wall_ms": round(sum(ax_only)),
                     "focus_preserved": True,
                     "latencies": {"snapshot_ax": [round(v, 1) for v in ax_only],
                                   "snapshot_screenshot": [round(v, 1) for v in with_shot]},
                     "screenshots_returned": screenshots})
        for index in range(args.trials):
            elements, _, _ = snapshot(args.socket, pid, wid, False)
            indices = {key: find(elements, key) for key in LABELS}
            click_ms, error = [], None
            for key in SEQUENCE:
                click_args = {"pid": pid, "window_id": wid, "element_index": indices[key]}
                if args.fast_detect:
                    click_args["_codex_compat_fast_action"] = True
                result, ms = call(args.socket, "click", click_args)
                click_ms.append(ms)
                if result.get("result", {}).get("isError"):
                    error = (result["result"].get("structuredContent") or {}).get("error_code", "error")
            landed = shows(display_values(snapshot(args.socket, pid, wid, False)[0]), "15")
            focus_preserved = frontmost_bundle() != "com.apple.calculator"
            rows.append(trial_row(index, args.driver, landed and focus_preserved, click_ms, focus_preserved, error))
    finally:
        call(args.socket, "kill_app", {"pid": pid})
    with open(args.out, "a") as out:
        for row in rows:
            out.write(json.dumps(row) + "\n")
    print(f"wrote {len(rows)} rows to {args.out}")


if __name__ == "__main__":
    main(sys.argv[1:])
