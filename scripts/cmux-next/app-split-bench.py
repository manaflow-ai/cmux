#!/usr/bin/env python3
"""App-level cost of Cmd+D (splitRight) in a running tagged cmux-next build.

Usage:
  app-split-bench.py --app APP [--story app-split] [--runs N] [--label NAME] [--out DIR] [--jsonl FILE.jsonl]
  app-split-bench.py --control-socket PATH --pid APP_PID --workspace WS_ID
                     [--runs N] [--label NAME] [--jsonl FILE.jsonl]

Works on a Release build (no debug.* methods): it runs `action.run
splitRight` on the workspace's first terminal pane through the control
socket, polls `snapshot.get` until the new tab shows, closes it, and reads
the app's own signposts with `log stream --signpost --process PID`.
Per run it prints the time of each signpost after the request (the daemon
marks are `daemon.step` events whose message is the mark):
`daemon.snapshot_start` (the split's round trip ended and the store resyncs),
`daemon.snapshot_end`, `stall.create_surface` (the new pane's view and Ghostty
surface: visible on the next frame), `terminal.attach_start` and
`terminal.attach_end` (first terminal frame with content). It also reports
`action_run_wait_ms` and whether the reply already listed the created tab.
The summary prints p50, p95, p99 and max (scripts/perf-lab/perf_stats.py).

--app launches the bundle through bench_launch.BenchApp (the bench env, a
fresh saved session, its teardown) and splits the workspace its window
shows. With --story (scripts/perf-lab/stories.d, engine none) a run whose
every split showed writes app_split.action_run_wait and
app_split.snapshot_has_pane (ms, one sample per run) into --out as
cmux-perf-result/v1 (BenchApp.record); a run with a failed split writes none
and exits 1. An attached app (--control-socket) has an unknown launch env:
its run keeps the printed rows and --jsonl only.

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
import sys
import tempfile
import time
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
import split_pane_bench_report as sp_report  # noqa: E402
from bench_story import story_problem  # noqa: E402

ENGINE = "none"  # a terminal split opens no web page


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


def shown_workspace(sock):
    """The workspace id the app's window shows (snapshot.get topology focus), or None."""
    topology = (rpc(sock, "snapshot.get").get("result") or {}).get("topology") or {}
    return (topology.get("focus") or {}).get("workspace")


def measure(sock, pid, workspace_id, runs, label):
    """`runs` splits of the workspace's first terminal pane; returns (rows, {signpost name: ms after each request})."""
    def workspace():
        for w in rpc(sock, "snapshot.get")["result"]["topology"]["workspaces"]:
            if w["id"] == workspace_id:
                return w
        raise SystemExit(f"workspace {workspace_id} not found")

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
                            "--process", str(pid)], stdout=open(log_path, "w"), stderr=subprocess.DEVNULL)
    rows = []
    try:
        time.sleep(2)
        prune()
        time.sleep(0.5)
        for i in range(runs):
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
            rows.append({"label": label, "run": i, "wall0": wall0, "ok": bool(r.get("ok")),
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
    return rows, agg


def summarize(rows, agg, label):
    ok = [r for r in rows if r["ok"]]
    print(f"== {label} n={len(ok)} reply listed the created tab in {sum(r['reply_listed_created'] for r in ok)}/{len(ok)} runs")
    for key in sp_report.APP_SPLIT_KEYS:
        v = [r[key] for r in ok if r[key] is not None]
        if v:
            print(f"{key:40s} p50 {sp_report.percentile(v, 0.50):7.1f}  p95 {sp_report.percentile(v, 0.95):7.1f}  "
                  f"p99 {sp_report.percentile(v, 0.99):7.1f}  max {max(v):7.1f}")
    for name, v in sorted(agg.items(), key=lambda kv: sp_report.percentile(kv[1], 0.50)):
        print(f"{name[:40]:40s} p50 {sp_report.percentile(v, 0.50):7.1f}  min {min(v):7.1f}  max {max(v):7.1f}  n={len(v)}")


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    where = ap.add_mutually_exclusive_group(required=True)
    where.add_argument("--app", help="launch this `cmux DEV <tag>.app` through BenchApp and split its shown workspace")
    where.add_argument("--control-socket", help="the control socket of an app that already runs")
    ap.add_argument("--pid", type=int, help="the running app's pid (--control-socket)")
    ap.add_argument("--workspace", help="the workspace to split (--control-socket)")
    ap.add_argument("--tag", help="the story runner's; the tag is the --app bundle's")
    ap.add_argument("--runs", type=int, default=12)
    ap.add_argument("--label", default="app-split")
    ap.add_argument("--out", help="--app: BenchApp's folder (app log, cmux-perf-result/v1)")
    ap.add_argument("--jsonl", help="also append every run as one JSON line here")
    ap.add_argument("--story", help="write the run as cmux-perf-result/v1 under this story (needs --app)")
    ap.add_argument("--session", choices=["light"], default="light", help="result-v1 session (the story runner's)")
    args = ap.parse_args(argv)
    if args.control_socket and (args.pid is None or not args.workspace):
        ap.error("--control-socket needs --pid and --workspace")
    if args.story:
        if not args.app:
            ap.error("--story needs --app: an attached app's launch env is unknown")
        problem = story_problem(args.story, ENGINE)
        if problem:
            ap.error(problem)
    return args


def main(argv=None, bench_app=None):
    """`bench_app(path, out, session)` makes the BenchApp (tests pass their own)."""
    args = parse_args(argv)
    app = None
    try:
        if args.app:
            if bench_app is None:
                from bench_launch import BenchApp
                app = BenchApp(args.app, out=args.out, perf_session=args.session)
            else:
                app = bench_app(args.app, args.out, args.session)
            app.launch()  # LaunchError (a SystemExit) carries the reason
            sock, pid = app.socket, app.process.pid
            workspace_id = shown_workspace(sock)
            if not workspace_id:
                raise SystemExit("app-split-bench: the launched app shows no workspace")
        else:
            sock, pid, workspace_id = args.control_socket, args.pid, args.workspace
        rows, agg = measure(sock, pid, workspace_id, args.runs, args.label)
    finally:
        if app:
            app.stop()  # debug.quit, then the tag's daemons (tag_teardown.py)
    summarize(rows, agg, args.label)
    if args.jsonl:
        with open(args.jsonl, "a") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")
    return record(app, args.story, rows)


def record(app, story, rows):
    """With a story: the run's series as result-v1 when every split showed; the exit code."""
    if not story:
        return 0
    failures = sp_report.app_split_failures(rows) or ([] if rows else ["no run"])
    if failures:
        print(f"RESULT-V1 none: {'; '.join(failures)}", flush=True)
        return 1
    written = sp_report.record_all(app, story, ENGINE, sp_report.app_split_series(rows))
    for metric, path in written.items():
        print(f"result-v1 {metric}: {path}", flush=True)
    if not sp_report.any_written(written):
        print("RESULT-V1 FAIL: no series was written", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
