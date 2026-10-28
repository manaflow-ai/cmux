#!/usr/bin/env python3
"""The Motion Inspector for agents: slow down, pause, step and list cmux's animations.

One model with Debug > Debug Windows > Motion Inspector (plans/cmux-next/motion-inspector.md), driven
through the app's `debug.motion` socket actions. It attaches to a running tagged build (a capture slot
or `CMUX_TAG=<tag>`); it never launches, quits or focuses the app.

  motion.py [--tag TAG | --socket PATH] COMMAND [ARGS]

Commands:
  start                 start inspecting (records every animation that starts from now)
  stop                  stop: every layer, clock and page back to real time; prints the last records
  scale N               play every motion path at 1, 2, 5, 10 times slower; 0 pauses
  pause | play          scale 0 | scale 1
  step [N]              pause and move every animation N display frames (default 1; negative: back)
  filter KIND|CATEGORY... | filter all
                        keep only these moving; KIND is sidebarRows, tabStrip, panes, overlays, feedback;
                        a CATEGORY is sidebar, tabs, panes, overlays, hoverCards, home, cursor, indicators,
                        feedback, web
  running [--ended]     the live list (running, or with --ended the ended ones too)
  watch [SECONDS]       print the running list every 250 ms for SECONDS (default 5)
  findings              scan the windows for animations no Motion gate made, plus the known bypasses
  state                 time scale, filter and the inspector's own overhead
  window [--close]      open (or close) the Motion Inspector window without taking the keys

--json prints the raw reply. Exit 1 on an error reply, 2 when the socket does not answer.

Example (the sidebar Cmd-N burst at 10x, rows only):
  motion.py --tag mytag filter sidebarRows && motion.py --tag mytag scale 10
  ... hold Cmd-N ...
  motion.py --tag mytag running --ended --json > rows.json; motion.py --tag mytag stop
"""
import argparse
import json
import os
import re
import socket
import sys
import time

CATEGORIES = ["sidebar", "tabs", "panes", "overlays", "hoverCards", "home", "cursor", "indicators", "feedback", "web"]
KINDS = ["sidebarRows", "tabStrip", "panes", "overlays", "feedback"]


def socket_path(opts):
    if opts.socket:
        return opts.socket
    tag = opts.tag or os.environ.get("CMUX_TAG")
    if not tag:
        sys.exit("motion.py: pass --tag TAG, --socket PATH or set CMUX_TAG")
    # scripts/cmux-debug-cli.sh's rule: lower case, each run of other characters one "-", none at the ends.
    slug = re.sub(r"[^a-z0-9]+", "-", tag.lower()).strip("-") or "agent"
    for path in (os.path.expanduser(f"~/.local/state/cmux/cmux-debug-{slug}.sock"), f"/tmp/cmux-debug-{slug}.sock"):
        if os.path.exists(path):
            return path
    sys.exit(f"motion.py: no debug socket for tag {tag!r} (looked in ~/.local/state/cmux and /tmp)")


def call(path, params, timeout=10):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(path)
            conn.sendall((json.dumps({"id": 1, "method": "debug.motion", "params": params}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
    except OSError as error:
        print(f"motion.py: {path}: {error}", file=sys.stderr)
        sys.exit(2)
    reply = json.loads(buf or b"{}")
    if not reply.get("ok", False):
        print(f"motion.py: {reply.get('error')}", file=sys.stderr)
        sys.exit(1)
    result = reply.get("result") or {}
    if isinstance(result, dict) and result.get("error"):
        print(f"motion.py: {result['error']}", file=sys.stderr)
        sys.exit(1)
    return result


def curve_text(curve):
    kind = curve.get("type")
    if kind == "spring":
        return f"spring r{curve['response'] * 1000:.0f} d{curve['damping']:.2f} ~{curve['perceived_ms']:.0f}ms"
    if kind == "timed":
        return f"{curve['name']} {curve['duration_ms']:.0f}ms"
    if kind == "loop":
        return f"loop {curve['period_ms']:.0f}ms"
    return kind or "?"


def print_records(result):
    print(f"time_scale={result.get('time_scale')} kind={result.get('kind')} categories={','.join(result.get('categories', []))} "
          f"running={result.get('running')} motion_ms={result.get('motion_ms')}")
    rows = result.get("records", [])
    for r in sorted(rows, key=lambda r: (not r.get("running"), -r.get("start_ms", 0))):
        main = r.get("main_ms_per_frame")
        print(f"{'*' if r.get('running') else ' '} {r.get('category', '-'):<10} {r['kind']:<24} x{r.get('layers', 1):<3} "
              f"{r['property']:<14} {curve_text(r.get('curve', {})):<26} start={r.get('start_ms', 0):>7.0f} "
              f"end={r.get('ended_ms', r.get('expected_end_ms', 0)) or 0:>7.0f} frames={r['frames']:<4} dropped={r['dropped_frames']:<3} "
              f"main={'-' if main is None else f'{main:.2f}ms'} runs={r['runs']:<13} {r['owner']}")
    if not rows:
        print("(no animation)")


def print_state(result):
    o = result.get("overhead", {})
    print(f"inspecting={result.get('inspecting')} time_scale={result.get('time_scale')} paused={result.get('paused')} "
          f"kind={result.get('kind')} categories={','.join(result.get('categories', []))} running={result.get('running')}")
    print(f"overhead: frame p50 {o.get('frame_p50_ms')} ms, p95 {o.get('frame_p95_ms')} ms, max {o.get('frame_max_ms')} ms over "
          f"{o.get('frames')} frames; {o.get('starts')} starts at {o.get('start_mean_ms')} ms mean; last scan {o.get('scan_ms')} ms "
          f"over {o.get('scanned_layers')} layers")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag")
    parser.add_argument("--socket")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("command")
    parser.add_argument("args", nargs="*")
    parser.add_argument("--ended", action="store_true")
    parser.add_argument("--close", action="store_true")
    opts = parser.parse_args()
    path = socket_path(opts)
    command, args = opts.command, opts.args

    if command == "start":
        params = {"action": "inspect_start"}
    elif command == "stop":
        params = {"action": "inspect_stop"}
    elif command in ("scale", "pause", "play"):
        value = {"pause": 0, "play": 1}.get(command, float(args[0]) if args else None)
        if value not in (0, 1, 2, 5, 10):
            sys.exit("motion.py: scale takes 1, 2, 5, 10 or 0 (paused)")
        params = {"action": "time_scale", "value": value}
    elif command == "step":
        params = {"action": "step", "frames": int(args[0]) if args else 1}
    elif command == "filter":
        if not args or args == ["all"]:
            params = {"action": "filter", "categories": None}
        elif len(args) == 1 and args[0] in KINDS:
            params = {"action": "filter", "kind": args[0]}
        else:
            unknown = [a for a in args if a not in CATEGORIES]
            if unknown:
                sys.exit(f"motion.py: unknown {unknown}; kinds {KINDS}, categories {CATEGORIES}")
            params = {"action": "filter", "categories": args}
    elif command == "running":
        params = {"action": "running", "ended": opts.ended}
    elif command == "watch":
        seconds = float(args[0]) if args else 5
        deadline = time.time() + seconds
        while time.time() < deadline:
            result = call(path, {"action": "running"})
            if opts.json:
                print(json.dumps(result), flush=True)
            else:
                print_records(result)
                print()
            time.sleep(0.25)  # a CLI's own sampling of a live app, not cmux runtime
        return
    elif command == "findings":
        params = {"action": "findings"}
    elif command == "state":
        params = {"action": "inspector"}
    elif command == "window":
        params = {"action": "window", "open": not opts.close}
    else:
        sys.exit(f"motion.py: unknown command {command!r} (see --help)")

    result = call(path, params)
    if opts.json:
        print(json.dumps(result, indent=2))
    elif command in ("running", "stop"):
        print_records(result)
    elif command == "findings":
        for f in result.get("findings", []):
            print(f"ungated  {f['owner_type']:<28} {f['property']:<16} {f['class']:<22} {f['duration_ms']:>6.0f}ms"
                  f"{'  repeats' if f['repeats'] else ''}{'  (AppKit)' if f['appkit_owned'] else ''}  key={f['key']}")
        if not result.get("findings"):
            print("no ungated animation on screen")
        for f in result.get("static_findings", []):
            print(f"known    {f['site']}: {f['note']}")
    else:
        print_state(result)
        if "step" in result:
            s = result["step"]
            print(f"step: {s['seconds'] * 1000:.2f} ms on {s['layers']} root layers, {s['clock_frames']} CPU-spring frames")


if __name__ == "__main__":
    main()
