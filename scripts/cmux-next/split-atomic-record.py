#!/usr/bin/env python3
"""Record a person's Cmd-D from a New Tab page on a running tagged cmux-next build.

Lawrence 2026-10-17: "cmd d still shows new tab first before making the right
split". With `conversation-tab-split-v1` the split is one daemon commit, so no
frame may show the new page in the source pane's strip.

The script attaches to an app already running through its debug socket (it
never launches or quits it): a fresh workspace, a New Tab page in its pane
(`newTab.page`), then Cmd-D through `debug.key` (the app's key path, so the
split is a person's) while `debug.window_record` keeps one JPEG per display
frame and a second connection reads `debug.pane_chrome` as fast as the app
answers. `probe.json` holds every read (each pane's tab count as its strip
draws it); `verdict.json` says whether any read showed the source strip
holding more tabs than before the key, and when the new pane first showed.

Usage: split-atomic-record.py --socket /tmp/cmux-debug-<tag>.sock --out DIR
Exit 0 when no read shows the new tab in the source strip and the split
landed; 1 otherwise.
"""
import argparse, json, os, socket, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--seconds", type=float, default=1.5)
opts = parser.parse_args()


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
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


def action(name, **params):
    return rpc("action.run", {"action": name, **params})


def panes():
    """[(pane key, tab count drawn in its strip, strip rect)] of the first window."""
    report = rpc("debug.pane_chrome") or {}
    windows = report.get("windows") or [] if isinstance(report, dict) else []
    if not windows:
        return None
    return [(pane.get("pane"), len(pane.get("tab_slots") or []), pane.get("strip"))
            for pane in windows[0].get("panes") or []]


def wait(check, seconds, step=0.2):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


os.makedirs(opts.out, exist_ok=True)
if not wait(panes, 60):
    sys.exit("no window answered debug.pane_chrome")
action("workspace.newAtBottom")
wait(lambda: (p := panes()) and len(p) == 1 and p, 10)
time.sleep(1.0)  # test harness: the workspace settles
action("newTab.page")
# The pane shows the terminal and the New Tab page.
before = wait(lambda: (p := panes()) and len(p) == 1 and p[0][1] >= 2 and p, 10)
time.sleep(1.0)  # test harness: the page settles and takes focus
before = panes()
print("before:", before, flush=True)
if not before or len(before) != 1:
    sys.exit(f"want one pane before the split, got {before}")
source, source_tabs, _ = before[0]
with open(os.path.join(opts.out, "layout-before.json"), "w") as handle:
    json.dump(rpc("debug.pane_chrome"), handle)

samples = []
stop = threading.Event()


def probe():
    while not stop.is_set():
        read = panes()
        if read is not None:
            samples.append({"t": time.time(), "panes": read})


frames = os.path.join(opts.out, "frames")
started = rpc("debug.window_record", {"dir": frames, "seconds": opts.seconds})
print("record:", started, flush=True)
poller = threading.Thread(target=probe)
poller.start()
time.sleep(0.15)  # test harness: still frames before the key
key_at = time.time()
reply = rpc("debug.key", {"key": "d", "modifiers": ["cmd"]})
print("cmd-d:", json.dumps(reply)[:300], flush=True)
time.sleep(opts.seconds + 0.6)  # test harness: the recording stops by itself
stop.set()
poller.join()
after = panes()
print("after:", after, flush=True)
with open(os.path.join(opts.out, "layout-after.json"), "w") as handle:
    json.dump(rpc("debug.pane_chrome"), handle)

leaks = [s for s in samples if any(pane == source and count > source_tabs for pane, count, _ in s["panes"])]
split_at = next((s["t"] for s in samples if len(s["panes"]) == 2), None)
landed = bool(after) and len(after) == 2 and dict((p, c) for p, c, _ in after).get(source) == source_tabs
verdict = {
    "source": source, "source_tabs_before": source_tabs,
    "reads": len(samples), "reads_after_key": len([s for s in samples if s["t"] >= key_at]),
    "reads_with_new_tab_in_source": len(leaks),
    "first_leak_ms_after_key": round((leaks[0]["t"] - key_at) * 1000, 1) if leaks else None,
    "new_pane_ms_after_key": round((split_at - key_at) * 1000, 1) if split_at else None,
    "after": after, "landed": landed,
    "frames": len([f for f in os.listdir(frames) if f.endswith(".jpg")]) if os.path.isdir(frames) else 0,
}
with open(os.path.join(opts.out, "probe.json"), "w") as handle:
    json.dump({"key_at": key_at, "samples": samples}, handle)
with open(os.path.join(opts.out, "verdict.json"), "w") as handle:
    json.dump(verdict, handle, indent=1)
print("verdict:", json.dumps(verdict), flush=True)
sys.exit(0 if landed and not leaks else 1)
