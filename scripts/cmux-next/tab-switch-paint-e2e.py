#!/usr/bin/env python3
"""Switching, closing and opening tabs paint the next tab at once (Leo 2026-10-12, tab rendering).

On a running tagged build, read frame after frame (`debug.new_tab` frame_strip) around:

  pane     `nextSurface` through one pane's tabs: a terminal, a WebKit page, a Chromium page and
           the New Tab page, twice round (the second round is every tab seen before);
  sidebar  `nextSidebarTab` through the window's sidebar items (workspaces), twice round;
  close    `closeTab` on the selected tab: the tab it reveals;
  newtab   Command-T: the New Tab page.

Each step reports `settled_ms` (the key or action to the first frame that stays the final one, in the
content area), `blank` (flat frames that are neither tab) and `content_intermediate` (frames that are
neither the tab before nor the one after: loading, partly drawn or reflowing). Budgets: every step
settles within --settle-ms, with no blank and no intermediate frame; --no-fail only reports.

The app runs already (a capture slot: `capture-host launch`), with its debug socket; the script never
launches or quits it.

Usage: tab-switch-paint-e2e.py --socket <path> [--phases pane,sidebar,close,newtab] [--settle-ms 50]
                               [--out DIR] [--json FILE] [--no-fail]
"""
import argparse, functools, http.server, json, os, socket, statistics, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--phases", default="pane,sidebar,close,newtab")
parser.add_argument("--settle-ms", type=float, default=50, help="budget: action to the settled frame")
parser.add_argument("--duration-ms", type=float, default=600)
parser.add_argument("--out", default="/tmp/tab-switch-paint")
parser.add_argument("--json", help="write every step's numbers here")
parser.add_argument("--no-fail", action="store_true")
# Accepted for the capture-slot harness, which passes them to every e2e.
parser.add_argument("--runs", type=int, default=1)
opts = parser.parse_args()

COLORS = ["#c0392b", "#2471a3", "#1e8449", "#b7950b", "#7d3c98", "#ca6f1e"]


def rpc(method, params=None, timeout=40):
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


def wait(check, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def run(action, args=None, target=None):
    params = {"action": action, "args": args or {}, "focus": True, "confirm": True}
    if target:
        params["target"] = target
    return rpc("action.run", params) or {}


def serve():
    """Pages that differ at a glance: a full-page color block and a large label."""
    root = tempfile.mkdtemp(prefix="tab-switch-paint-")
    for index, color in enumerate(COLORS):
        with open(os.path.join(root, f"p{index}.html"), "w") as page:
            page.write(f"<!doctype html><title>page {index}</title><body style='margin:0;background:{color};color:#fff;"
                       f"font:bold 96px -apple-system'><p style='margin:40px'>Page {index}</p>"
                       + "".join(f"<p style='margin:8px 40px;font-size:20px'>line {n}</p>" for n in range(30)) + "</body>")

    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=root))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://localhost:{server.server_address[1]}/"


def strip(label, **params):
    reply = rpc("debug.new_tab", {"action": "frame_strip", "dir": f"{opts.out}/{label}", "duration_ms": opts.duration_ms, **params}, timeout=60) or {}
    if "error" in reply:
        return {"label": label, "error": reply["error"]}
    step = {"label": label, "settled_ms": reply.get("settled_ms"), "first_change_ms": reply.get("first_change_ms"),
            "blank": int(reply.get("blank", 0)), "content_intermediate": int(reply.get("content_intermediate", 0)),
            "intermediate": int(reply.get("intermediate", 0)), "frames": reply.get("frame_count"),
            "interval_ms": round(reply.get("mean_interval_ms", 0), 1), "dir": reply.get("dir")}
    print(f"{label:28} settled {step['settled_ms']!s:>5} ms  first change {step['first_change_ms']!s:>5} ms  "
          f"blank {step['blank']}  content-intermediate {step['content_intermediate']}  outside-intermediate {step['intermediate']}", flush=True)
    time.sleep(0.4)  # test harness: let the tab settle before the next step
    return step


def topology():
    return ((rpc("snapshot.get") or {}).get("topology")) or {}


def focused_pane_tabs():
    top = topology()
    pane = (top.get("focus") or {}).get("pane")
    for workspace in top.get("workspaces", []):
        for screen in workspace.get("screens", []):
            for candidate in screen.get("panes", []):
                if candidate.get("id") == pane:
                    return candidate.get("tabs", [])
    return []


def main():
    if not wait(lambda: "error" not in (rpc("system.identify", timeout=5) or {"error": 1}), 90):
        sys.exit("FAIL the app does not answer on its socket")
    time.sleep(3.0)  # test harness: first window settles
    phases = set(opts.phases.split(","))
    url = serve()
    steps = []

    if "pane" in phases or "close" in phases:
        # One pane: a terminal, a WebKit page, a Chromium page, the New Tab page (from launch, or Command-T).
        run("tab new-terminal")
        run("openBrowser", {"url": url + "p0.html", "engine": "webkit"})
        run("openBrowser", {"url": url + "p1.html", "engine": "cef"})
        run("tab new")
        tabs = wait(lambda: (lambda t: t if len(t) >= 4 else None)(focused_pane_tabs()), 30) or []
        print(f"pane tabs: {[(t.get('kind'), t.get('title')) for t in tabs]}", flush=True)
        time.sleep(2.0)  # test harness: pages load
        if "pane" in phases:
            for lap in (1, 2):
                for index in range(len(tabs)):
                    steps.append(strip(f"pane-lap{lap}-{index}", action="nextSurface"))
        if "close" in phases:
            for index in range(max(0, len(tabs) - 1)):
                steps.append(strip(f"close-{index}", action="closeTab"))

    if "sidebar" in phases:
        for index in range(3):
            run("workspace new", {"name": f"switch-{index}"})
            run("openBrowser", {"url": url + f"p{2 + index}.html", "engine": "webkit" if index % 2 else "cef"})
        time.sleep(2.0)  # test harness: pages load
        items = len(topology().get("workspaces", []))
        for lap in (1, 2):
            for index in range(items):
                steps.append(strip(f"sidebar-lap{lap}-{index}", action="nextSidebarTab", region="workspace"))

    if "newtab" in phases:
        for index in range(3):
            steps.append(strip(f"newtab-{index}", key="t"))

    failures = []
    for step in steps:
        if "error" in step:
            failures.append(f"{step['label']}: {step['error']}")
            continue
        settled = step["settled_ms"]
        if settled is None or settled > opts.settle_ms:
            failures.append(f"{step['label']}: settled {settled} ms > {opts.settle_ms:.0f} ms")
        if step["blank"]:
            failures.append(f"{step['label']}: {step['blank']} blank frames")
        if step["content_intermediate"]:
            failures.append(f"{step['label']}: {step['content_intermediate']} intermediate frames")
    for phase in ("pane", "sidebar", "close", "newtab"):
        settled = [s["settled_ms"] for s in steps if s["label"].startswith(phase) and s.get("settled_ms") is not None]
        if settled:
            print(f"{phase:8} settled p50 {statistics.median(settled):.0f} ms max {max(settled):.0f} ms  "
                  f"blank {sum(s['blank'] for s in steps if s['label'].startswith(phase))}  "
                  f"intermediate {sum(s['content_intermediate'] for s in steps if s['label'].startswith(phase))}  ({len(settled)} steps)")
    if opts.json:
        with open(opts.json, "w") as file:
            json.dump(steps, file, indent=1)
    if failures:
        print("FAIL " + "; ".join(failures))
        if not opts.no_fail:
            sys.exit(1)
    else:
        print("PASS every switch, close and New Tab paints within budget")


main()
