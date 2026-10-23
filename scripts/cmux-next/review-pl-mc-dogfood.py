#!/usr/bin/env python3
"""Scratch GUI dogfood for the PL-motion-core review fixes (never lands).

Attaches to a running tagged app through its debug socket ($NX_APP_SOCKET) and checks, frame by frame
(`debug.motion` trace of the pane hosts and dividers on every display tick):

  A  Cmd-D, then New Column on the new (still pending) pane at once, then typing at once: 3 panes stay,
     the typed marker shows in the focused terminal.
  B  New Column twice, the first one closed before it confirms: the second stays, after the original.
  C  New Column on a one-pane screen with layout.newColumnWidth = fixed: the original pane narrows and
     never springs back toward full width on any frame.
  D  New Column, then close it: the original pane's x comes back to where it was.
  E  New Row on a split-tree screen: the row edge never jumps between two frames at the handoff.

Usage: review-pl-mc-dogfood.py --out DIR
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--out", required=True)
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = os.environ["NX_APP_SOCKET"]
ROWS = []


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def action(name, args=None, target=None):
    params = {"action": name, "args": args or {}, "focus": True, "origin": "script"}
    if target:
        params["target"] = target
    return rpc("action.run", params, timeout=60)


def wait(check, seconds, step=0.1):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)  # dogfood harness polling a live app
    return None


def row(name, ok, detail):
    ROWS.append({"check": name, "ok": bool(ok), "detail": detail})
    print(f"{'PASS' if ok else 'FAIL'} | {name} | {detail}", flush=True)


def topology():
    reply = rpc("snapshot.get")
    return (reply.get("topology") or {}) if isinstance(reply, dict) else {}


def focused_workspace():
    top = topology()
    wid = (top.get("focus") or {}).get("workspace")
    return next((w for w in top.get("workspaces") or [] if w.get("id") == wid), None)


def panes():
    ws = focused_workspace() or {}
    return [p for s in ws.get("screens") or [] for p in s.get("panes") or [] if not p.get("dock")]


def pane_ids():
    return [p.get("id") for p in panes()]


def fresh():
    before = {w.get("id") for w in topology().get("workspaces") or []}
    action("workspace.newAtBottom")
    wait(lambda: (focused_workspace() or {}).get("id") not in before, 20)
    wait(lambda: len(panes()) == 1, 10)
    time.sleep(1.0)  # dogfood harness: the shell starts


def trace(act, seconds):
    started = rpc("debug.motion", {"action": "trace_start", "targets": ["panes", "dividers"]})
    if isinstance(started, dict) and started.get("error"):
        return {"error": started["error"], "samples": []}
    time.sleep(0.1)  # a few frames at rest first
    acted = act()
    time.sleep(seconds)  # the motion runs
    result = rpc("debug.motion", {"action": "trace_stop"}) or {}
    result["acted"] = acted
    return result


def pane_width(sample, pane):
    for entry in sample.get("panes") or []:
        if entry and entry[0] == pane:
            return entry[3], entry[1]
    return None


def save(name, data):
    with open(os.path.join(opts.out, f"{name}.json"), "w") as handle:
        json.dump(data, handle)


def read_text():
    reply = rpc("surface.read_text") or {}
    return reply.get("text", "") if isinstance(reply, dict) else ""


def scenario_a():
    fresh()
    original = pane_ids()
    marker = f"/tmp/rplmc-a-{os.getpid()}-{int(time.time())}"
    command = f"touch {marker}"

    def act():
        rpc("debug.key", {"key": "d", "modifiers": ["command"]})
        action("newColumn")
        for char in command:
            rpc("debug.key", {"key": "space" if char == " " else char})
        rpc("debug.key", {"key": "return"})
        return True
    data = trace(act, 1.5)
    save("A", data)
    ok = wait(lambda: len(panes()) == 3, 10)
    ids = pane_ids()
    row("A: Cmd-D then New Column on the pending pane, both stay", ok and original[0] in ids, f"panes {ids}")
    made = wait(lambda: os.path.exists(marker), 10)
    row("A: typing at once runs the whole command in the focused terminal (no key lost)", made, f"{command!r} -> exists {bool(made)}")


def scenario_b():
    fresh()
    original = pane_ids()[0]
    action("newColumn")
    first = next((p for p in pane_ids() if p != original), None)
    action("newColumn")
    closed = action("closePane", target=f"pane:{first}") if first else {"error": "no first column"}
    time.sleep(2.0)  # dogfood harness: the creates settle
    ids = pane_ids()
    row("B: New Column twice, first closed while pending: the second stays after the original",
        len(ids) == 2 and ids[0] == original and first not in ids, f"first {first} close {closed} panes {ids}")


def scenario_c():
    fresh()
    for path, value in (("layout.newColumnWidth", "fixed"), ("layout.defaultColumnWidth", 0.5)):
        rpc("settings.set", {"path": path, "value": value})
    time.sleep(0.5)  # dogfood harness: the setting applies
    original = pane_ids()[0]
    data = trace(lambda: action("newColumn"), 1.5)
    save("C", data)
    widths = [w for w in (pane_width(s, original) for s in data.get("samples") or []) if w]
    series = [round(w[0], 1) for w in widths]
    lowest, spring_back = None, 0.0
    for width in series:
        if lowest is not None and width - lowest > spring_back:
            spring_back = width - lowest
        lowest = width if lowest is None else min(lowest, width)
    row("C: the lone column narrows and never springs back toward full width",
        len(series) > 3 and series[-1] < series[0] - 50 and spring_back < 2.0,
        f"{len(series)} frames, first {series[:1]}, last {series[-1:]}, largest rise {round(spring_back, 1)} pt")
    rpc("settings.set", {"path": "layout.newColumnWidth", "value": "matchCurrent"})


def scenario_d():
    fresh()
    action("splitRight")
    wait(lambda: len(panes()) == 2, 10)
    time.sleep(1.0)  # dogfood harness: the split rests
    original = pane_ids()[0]
    rest = rpc("debug.motion", {"action": "trace_start", "targets": ["panes"]})
    time.sleep(0.2)  # dogfood harness: frames at rest
    before = rpc("debug.motion", {"action": "trace_stop"}) or {}
    start = next((pane_width(s, original) for s in reversed(before.get("samples") or []) if pane_width(s, original)), None)
    known = set(pane_ids())
    action("newColumn")
    time.sleep(1.2)  # dogfood harness: the column opens and the camera moves
    new = next((p for p in pane_ids() if p not in known), None)
    data = trace(lambda: action("closePane", target=f"pane:{new}"), 1.5)
    save("D", data)
    end = next((pane_width(s, original) for s in reversed(data.get("samples") or []) if pane_width(s, original)), None)
    row("D: New Column then close: the camera comes back", start and end and abs(start[1] - end[1]) < 1.0,
        f"original pane x before {start and start[1]} after close {end and end[1]} (rest trace {bool(rest)})")


def scenario_e():
    fresh()
    action("splitDown")
    wait(lambda: len(panes()) == 2, 10)
    time.sleep(1.0)  # dogfood harness: the split rests
    data = trace(lambda: action("newRow"), 1.5)
    save("E", data)
    steps = []
    previous = None
    for sample in data.get("samples") or []:
        edges = sorted(d[2] for d in sample.get("dividers") or [] if d and d[4] < d[3] and str(d[0]).startswith("row"))
        if previous is not None and edges and len(edges) == len(previous):
            steps.append(max(abs(a - b) for a, b in zip(edges, previous)))
        previous = edges or previous
    travel = sum(steps)
    row("E: New Row on a split tree: no row edge jumps between two frames",
        bool(steps) and (max(steps) < max(40.0, travel * 0.34)),
        f"{len(steps)} frame steps, largest {round(max(steps), 1) if steps else None} pt of {round(travel, 1)} pt")


def main():
    if not wait(lambda: "error" not in (rpc("system.identify") or {"error": 1}), 60, step=0.5):
        sys.exit("the app's socket never answered")
    rpc("debug.window.focus", {})
    frames = rpc("debug.frames") or {}
    print("DISPLAY " + json.dumps({k: frames.get(k) for k in ("refresh_ms", "refresh", "display") if isinstance(frames, dict)}), flush=True)
    only = os.environ.get("RPLMC_ONLY", "abcde")
    for run in [f for f in (scenario_a, scenario_b, scenario_c, scenario_d, scenario_e) if f.__name__[-1] in only]:
        try:
            run()
        except Exception as error:  # report and go on to the next scenario
            row(run.__name__, False, f"{type(error).__name__}: {error}")
    save("rows", ROWS)
    sys.exit(0 if all(r["ok"] for r in ROWS) else 1)


main()
