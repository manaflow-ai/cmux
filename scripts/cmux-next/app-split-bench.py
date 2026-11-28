#!/usr/bin/env python3
"""App-level cost of Cmd+D (splitRight) in a running tagged cmux-next build.

Usage:
  app-split-bench.py --control-socket PATH --pid APP_PID --workspace WS_ID
                     [--runs N] [--label NAME] [--out FILE.jsonl]

Works on a Release build (no debug.* methods): it runs `action.run
splitRight` on the workspace's first terminal pane through the control
socket, polls `snapshot.get` until the new tab shows, closes it, and reads
the app's own `stalls` signposts with `log stream --signpost --process PID`.
Per run it prints the time of each signpost after the request:
`daemon.snapshot_start` (the split's round trip ended and the store resyncs),
`daemon.snapshot_end`, `createSurface` (the new pane's view and Ghostty
surface: visible on the next frame), `terminal.attach_start` and
`terminal.attach_end` (first terminal frame with content). It also reports
`action_run_wait_ms` and whether the reply already listed the created tab.

The workspace may be local or on an SSH or Cloud machine (`remote.newWorkspace`).
Run it where the app runs (a fleet Mac or m1max), never on the laptop.
plans/cmux-next/remote-state-ownership.md section 1.
"""
import argparse
import datetime
import json
import os
import socket
import subprocess
import tempfile
import time
from collections import defaultdict


def rpc(path, method, params=None, timeout=60):
    c = socket.socket(socket.AF_UNIX)
    c.settimeout(timeout)
    c.connect(path)
    c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = c.recv(1 << 22)
        if not chunk:
            break
        buf += chunk
    c.close()
    return json.loads(buf)


def signposts(path):
    """(epoch seconds, name) for every com.cmuxterm.app.next signpost or log line."""
    out = []
    with open(path) as f:
        for raw in f:
            try:
                m = json.loads(raw)
            except ValueError:
                continue
            if m.get("subsystem") != "com.cmuxterm.app.next":
                continue
            ts = m["timestamp"]  # 2026-10-09 05:25:10.765866-0700
            t = datetime.datetime.strptime(ts[:26], "%Y-%m-%d %H:%M:%S.%f")
            off = ts[26:]
            sign = 1 if off[0] == "+" else -1
            t -= sign * datetime.timedelta(hours=int(off[1:3]), minutes=int(off[3:5]))
            epoch = (t - datetime.datetime(1970, 1, 1)).total_seconds()
            name = (m.get("signpostName") or "") + ":" + (m.get("eventMessage") or "")[:60]
            if m.get("signpostType"):
                name += f" ({m['signpostType']})"
            out.append((epoch, name))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--control-socket", required=True)
    ap.add_argument("--pid", required=True, type=int)
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--runs", type=int, default=12)
    ap.add_argument("--label", default="app-split")
    ap.add_argument("--out")
    args = ap.parse_args()
    sock = args.control_socket

    def workspace():
        for w in rpc(sock, "snapshot.get")["result"]["topology"]["workspaces"]:
            if w["id"] == args.workspace:
                return w
        raise SystemExit(f"workspace {args.workspace} not found")

    def tabs(w):
        return {t["id"]: p["id"] for sc in w["screens"] for p in sc["panes"] for t in p["tabs"]}

    first = workspace()
    pane = next((p["id"] for sc in first["screens"] for p in sc["panes"] if any(t["kind"] == "terminal" for t in p["tabs"])), None)
    if pane is None:
        raise SystemExit("no terminal pane in the workspace")

    def prune():
        for tab, owner in tabs(workspace()).items():
            if owner != pane:
                rpc(sock, "action.run", {"action": "closeTab", "target": f"tab:{tab}", "wait": True})

    log_path = tempfile.mktemp(prefix="app-split-bench-", suffix=".ndjson")
    log = subprocess.Popen(["/usr/bin/log", "stream", "--signpost", "--level", "debug", "--style", "ndjson",
                            "--process", str(args.pid)], stdout=open(log_path, "w"), stderr=subprocess.DEVNULL)
    rows = []
    try:
        time.sleep(2)
        prune()
        time.sleep(0.5)
        for i in range(args.runs):
            before = set(tabs(workspace()))
            wall0, t0 = time.time(), time.perf_counter()
            r = rpc(sock, "action.run", {"action": "splitRight", "target": f"pane:{pane}", "wait": True})
            t1 = time.perf_counter()
            seen = None
            while time.perf_counter() - t0 < 3:
                if set(tabs(workspace())) - before:
                    seen = time.perf_counter()
                    break
                time.sleep(0.002)
            result = r.get("result") or {}
            rows.append({"label": args.label, "run": i, "wall0": wall0, "ok": bool(r.get("ok")),
                         "error": r.get("error"), "action_run_wait_ms": (t1 - t0) * 1000,
                         "snapshot_has_pane_ms": ((seen - t0) * 1000) if seen else None,
                         "reply_listed_created": bool(result.get("created"))})
            time.sleep(1.5)  # attach, first frame and shell start before the close
            prune()
            time.sleep(0.8)
        time.sleep(1)
    finally:
        log.terminate()
        log.wait()
    marks = signposts(log_path)
    os.unlink(log_path)
    agg = defaultdict(list)
    for row in rows:
        if not row["ok"]:
            continue
        row["marks"] = {}
        for epoch, name in marks:
            d = (epoch - row["wall0"]) * 1000
            if 0 <= d <= 1500 and name not in row["marks"]:
                row["marks"][name] = d
                agg[name].append(d)
        print(json.dumps({k: (round(v, 1) if isinstance(v, float) and k != "wall0" else v)
                          for k, v in row.items() if k != "marks"}), flush=True)
    if args.out:
        with open(args.out, "a") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")
    ok = [r for r in rows if r["ok"]]
    print(f"== {args.label} n={len(ok)} reply listed the created tab in {sum(r['reply_listed_created'] for r in ok)}/{len(ok)} runs")
    for key in ["action_run_wait_ms", "snapshot_has_pane_ms"]:
        v = sorted(r[key] for r in ok if r[key] is not None)
        if v:
            print(f"{key:40s} p50 {v[len(v) // 2]:7.1f}  p95 {v[min(len(v) - 1, int(0.95 * len(v)))]:7.1f}")
    for name, v in sorted(agg.items(), key=lambda kv: sorted(kv[1])[len(kv[1]) // 2]):
        v.sort()
        print(f"{name[:40]:40s} p50 {v[len(v) // 2]:7.1f}  min {v[0]:7.1f}  max {v[-1]:7.1f}  n={len(v)}")


if __name__ == "__main__":
    main()
