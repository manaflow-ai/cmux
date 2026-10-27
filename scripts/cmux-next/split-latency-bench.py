#!/usr/bin/env python3
"""Daemon-side cost of Cmd+D (splitRight), in the app's request order.

Usage:
  split-latency-bench.py --socket PATH [--runs N] [--label NAME] [--jsonl FILE.jsonl] [--streams]
  split-latency-bench.py --tag TAG [--app APP] [--out DIR] [--runs N] [--streams] [--story split-latency]
  split-latency-bench.py (--socket PATH | --tag TAG) --machine ssh --ssh-host HOST [--ssh-config FILE] [--streams]

PATH is a cmux-tui daemon socket: a local daemon, or the local socket of
`cmux-tui remote connect` (then every request crosses the link). Per run:
  1. `split` {pane, dir:right, cols, rows, terminal_id} on the control
     connection; a `subscribe` (tree deltas) connection times the first
     `pane-added` and `layout-changed` after the send
  2. `list-workspaces`, the resync the app's store runs after layout-changed
  3. a warm `identify` on the control connection (one plain round trip)
  4. the new view's handshake. Today each terminal view (TerminalAttachment)
     opens a new connection with `identify` + `set-client-info` pipelined:
     one handshake round trip and three requests per view
  5. `attach-surface` {mode:bytes}: reply, then the first content
     (`vt-state` with data or the first `output`)
The run then closes the new surface. Times are milliseconds from the split
send; the summary prints p50, p95, p99 and max (scripts/perf-lab/perf_stats.py)
and `app_path_sum` (split + resync + handshake + attach, the app's critical
path without step 3).

--streams (plans/cmux-next/chrome-parity/p05-ipc.md, IPC-2) measures what the
app's own terminal view of each new terminal costs:
  app_view_connections           daemon connections the app opened for
                                 terminal views (debug.daemon.wire, the
                                 DaemonWireStats role terminal_attach,
                                 p05-ipc-004)
  app_view_attach_handshake_rtts the handshake round trips those cost: identity
                                 and capabilities are per connection and the
                                 view pipelines identify + set-client-info, so
                                 one per connection; a stream on the
                                 negotiated control connection has none
  app_view_bridge_spawns         bridge child processes the app spawned for them
  app_view_lines_written         every line the app wrote in the run: an upper
                                 bound of the view's requests (it includes the
                                 store's resync after the split)
  app_connections_per_view       the daemon's accepted connections in the run
                                 (server-stats) minus the bench's own: the same
                                 census from the daemon side, for a build
                                 without debug.daemon.wire
The report's `ipc2` block is the verdict from these alone. Only --tag on the
local machine has an app attached to the daemon the bench splits; --socket and
--machine ssh say so and give no IPC-2 verdict (the bench's ssh link is its own
`cmux remote connect`, which the launched app does not view).

The bench also opens a reference view of its own (`bench_view_*`: handshake
round trips, requests and connections, counted from what the bench sent). When
the daemon advertises `attach-streams-v1`, the control connection advertises it
back in its `set-client-info` (app-daemon-connection-DESIGN.md section 3: a
capability holds when both peers advertise it) and the reference view is a
client-minted stream on it (attach-surface with `stream`, cancel-stream after);
otherwise it is today's per-view connection with identify + set-client-info.
These rows show the protocol path, never the app's: they are not IPC-2.

--tag TAG launches today's tagged build through bench_launch.py (BenchApp:
scratch config, fresh saved state, its teardown), finds its daemon socket and
splits the pane the app shows, so the app attaches its own view of each new
terminal. report.json in --out (BenchApp's folder) holds the host, macOS
and display Hz (None where the host has none, a Linux remote host). With
--story (scripts/perf-lab/stories.d, engine none; --tag on the local machine
only) a run whose every split and attach succeeded writes each series into
--out as cmux-perf-result/v1 (BenchApp.record): split_latency.<step> (ms)
and, with --streams, split_latency.<view count> (count). A run with a
refused split or attach writes none and exits 1.

--machine ssh starts `cmux remote connect ssh://HOST --headless` (the build's
own CLI with --tag, else --cmux) on a private local socket and runs every
request over that link (bridged machines get streams on the one bridged
connection when attach-streams-v1 is there).

Run it on a fleet Mac or a remote host, never on the laptop (with --socket it
starts no daemon: point it at a scratch daemon, e.g. `cmux-tui --headless
--session bench --socket S --state DIR`, with CMUX_TUI_DEBUG_SPANS=FILE for the
daemon's own marks). plans/cmux-next/remote-state-ownership.md section 1.
"""
import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_tagged  # noqa: E402
import split_pane_bench_report as sp_report  # noqa: E402
from bench_story import story_problem  # noqa: E402
from typing_report import distribution  # noqa: E402

now = time.perf_counter
STREAMS_CAPABILITY = "attach-streams-v1"
METRICS = ["split_reply", "ev_pane_added", "ev_layout_changed", "list_workspaces", "warm_rtt",
           "attach_handshake", "attach_reply", "first_content_after_attach", "app_path_sum"]
BENCH_VIEW_METRICS = ["bench_view_attach_handshake_rtts", "bench_view_requests", "bench_view_connections"]
APP_VIEW_METRICS = ["app_view_connections", "app_view_attach_handshake_rtts", "app_view_bridge_spawns",
                    "app_view_lines_written", "app_connections_per_view"]
STREAM_METRICS = BENCH_VIEW_METRICS + APP_VIEW_METRICS
TERMINAL_ATTACH_ROLE = "terminal_attach"  # DaemonWireStats.Role.terminalAttach in debug.daemon.wire
ENGINE = "none"  # the split opens a terminal; no web page


class Conn:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self.buf = b""
        self.n = 0
        self.stash = {}

    def send(self, obj):
        self.n += 1
        self.s.sendall((json.dumps(dict(obj, id=self.n)) + "\n").encode())
        return self.n

    def line(self, timeout=30):
        self.s.settimeout(timeout)
        while b"\n" not in self.buf:
            chunk = self.s.recv(1 << 20)
            if not chunk:
                raise EOFError("daemon closed the connection")
            self.buf += chunk
        raw, self.buf = self.buf.split(b"\n", 1)
        return json.loads(raw)

    def reply(self, rid, timeout=30):
        # Replies can arrive out of order on a link; keep the others.
        if rid in self.stash:
            return self.stash.pop(rid)
        while True:
            m = self.line(timeout)
            if "ok" in m or "error" in m:
                if m.get("id") == rid:
                    return m
                self.stash[m.get("id")] = m

    def close(self):
        self.s.close()


def is_first_content(m):
    ev = m.get("event")
    return ev == "output" or (ev == "vt-state" and len(str(m.get("data") or "")) > 64)


def open_view(path, ctl, surface, stream_id, timeout=15):
    """Opens the bench's reference view of `surface`. With `stream_id` (attach-streams-v1 negotiated on `ctl`) the
    view is a stream on `ctl`; without, a new connection with today's handshake. Returns its times (perf_counter)
    and what the bench sent for it (`bench_view_*`)."""
    t0 = now()
    if stream_id is not None:
        conn, connections, rtts = ctl, 0, 0
        t_hs = t0
        sent_before = ctl.n
        aid = ctl.send({"cmd": "attach-surface", "surface": surface, "mode": "bytes", "stream": stream_id})
    else:
        conn, connections = Conn(path), 1
        sent_before = 0
        i1 = conn.send({"cmd": "identify"})
        i2 = conn.send({"cmd": "set-client-info", "name": "split-latency-bench", "kind": "bench"})
        conn.reply(i1)
        conn.reply(i2)
        rtts = 1  # both pipelined: one round trip before attach-surface may go
        t_hs = now()
        aid = conn.send({"cmd": "attach-surface", "surface": surface, "mode": "bytes"})
    t_attach = t_first = None
    refused = None
    deadline = now() + timeout
    while now() < deadline and (t_attach is None or t_first is None):
        try:
            m = conn.line(timeout=max(0.1, deadline - now()))
        except (OSError, EOFError, ValueError):
            break
        if "ok" in m or "error" in m:
            if m.get("id") != aid:
                conn.stash[m.get("id")] = m  # another request's reply on the shared control connection
                continue
            t_attach = now()
            if not m.get("ok"):
                refused = m
                break
            continue
        if stream_id is not None and m.get("stream") != stream_id:
            continue
        if t_first is None and is_first_content(m):
            t_first = now()
    requests = conn.n - sent_before
    if stream_id is not None:
        try:
            ctl.reply(ctl.send({"cmd": "cancel-stream", "stream": stream_id}), timeout=10)
        except (OSError, EOFError, ValueError):
            pass
    else:
        conn.close()
    return {"t0": t0, "t_hs": t_hs, "t_attach": t_attach, "t_first": t_first, "refused": refused,
            "bench_view_attach_handshake_rtts": rtts, "bench_view_requests": requests,
            "bench_view_connections": connections}


def negotiate_streams(ctl, caps):
    """Advertises attach-streams-v1 in the control connection's set-client-info when the daemon's identify did.
    Returns (on, why). A reply that lists capabilities must list it; an ok reply without a list accepts what the
    client advertised."""
    if STREAMS_CAPABILITY not in caps:
        return False, f"{STREAMS_CAPABILITY} not advertised by the daemon: the reference view is a per-view connection"
    reply = ctl.reply(ctl.send({"cmd": "set-client-info", "name": "split-latency-bench", "kind": "bench",
                                "capabilities": [STREAMS_CAPABILITY]}))
    if not reply.get("ok"):
        return False, f"set-client-info with {STREAMS_CAPABILITY} refused: {reply.get('error')}"
    granted = (reply.get("data") or {}).get("capabilities")
    if isinstance(granted, list) and STREAMS_CAPABILITY not in granted:
        return False, f"set-client-info did not grant {STREAMS_CAPABILITY} (granted {granted})"
    return True, "on"


def wire_counts(report):
    """(terminal-view connections opened, their bridge spawns, lines written) from a debug.daemon.wire reply, or None
    when the reply is not one (an error, or a build without the method)."""
    if not isinstance(report, dict) or "error" in report or "lines_written" not in report:
        return None
    opened = ((report.get("connections") or {}).get("opened") or {}).get(TERMINAL_ATTACH_ROLE, 0)
    spawns = (report.get("bridge_spawns") or {}).get(TERMINAL_ATTACH_ROLE, 0)
    return int(opened), int(spawns), int(report["lines_written"])


def app_view_delta(before, after):
    """The app's cost of one new view: debug.daemon.wire after minus before (wire_counts tuples)."""
    connections = after[0] - before[0]
    return {"app_view_connections": connections, "app_view_attach_handshake_rtts": connections,
            "app_view_bridge_spawns": after[1] - before[1], "app_view_lines_written": after[2] - before[2]}


def ipc2_verdict(rows, why_not=None):
    """IPC-2 from the app's own counts only: no connection, no handshake round trip and no bridge spawn per new view.
    The bench's reference view never goes in."""
    def values(key):
        return [r[key] for r in rows if r.get(key) is not None]
    if values("app_view_connections"):
        source = "app debug.daemon.wire"
        keys = ("app_view_connections", "app_view_attach_handshake_rtts", "app_view_bridge_spawns")
    elif values("app_connections_per_view"):
        source, keys = "daemon server-stats census (the app has no debug.daemon.wire)", ("app_connections_per_view",)
    else:
        return {"measured": False, "reason": why_not or "no app view was measured"}
    verdict = {"measured": True, "source": source, "views": len(values(keys[0]))}
    for key in keys:
        verdict[f"{key}_max"] = max(values(key))
    verdict["pass"] = all(verdict[f"{key}_max"] == 0 for key in keys)
    if values("app_view_lines_written"):
        verdict["app_view_lines_written_max"] = max(values("app_view_lines_written"))
        verdict["requests_note"] = ("app_view_lines_written is an upper bound of the view's requests: it includes the "
                                    "store's resync after the split")
    return verdict


def accepted_connections(ctl):
    """The daemon's accepted-connection count (server-stats), or None when it does not report one."""
    try:
        reply = ctl.reply(ctl.send({"cmd": "server-stats"}), timeout=10)
    except (OSError, EOFError, ValueError):
        return None
    return (((reply.get("data") or {}).get("connections") or {}).get("accepted")) if reply.get("ok") else None


def panes_of(workspace):
    return [p["id"] for sc in workspace.get("screens", []) for p in sc.get("panes", []) if p.get("id")]


def pick_pane(tree, shown=None):
    """The first pane of the workspace `shown` names (id or key), else the first pane of any workspace."""
    workspaces = tree.get("workspaces", [])
    for w in workspaces:
        if shown and shown in (w.get("id"), w.get("key")) and panes_of(w):
            return panes_of(w)[0]
    for w in workspaces:
        if panes_of(w):
            return panes_of(w)[0]
    return None


def bench(path, args, shown_workspace=None, log=print, app_wire=None, app_absent=None):
    """The runs against the daemon at `path`; returns (rows, info). `app_wire()` is the attached app's
    debug.daemon.wire reply (--tag); `app_absent` says why no app view is measured when there is no app."""
    events = []
    lock = threading.Lock()

    def subscriber():
        c = Conn(path)
        c.send({"cmd": "subscribe", "tree_events": "deltas"})
        while True:
            try:
                m = c.line(timeout=3600)
            except Exception:
                return
            if m.get("event"):
                with lock:
                    events.append((now(), m["event"]))

    ctl = Conn(path)
    caps = set((ctl.reply(ctl.send({"cmd": "identify"})).get("data") or {}).get("capabilities") or [])
    use_streams = False
    info = {"capabilities": sorted(caps), "streams": None}
    if args.streams:
        use_streams, info["streams"] = negotiate_streams(ctl, caps)
        log(f"== streams (bench reference view): {info['streams']}")
    census = args.streams and args.app_census
    wire = app_wire if args.streams else None
    if wire is not None and wire_counts(wire()) is None:
        info["app_wire"] = "debug.daemon.wire not answered: the app's view is counted by the daemon census only"
        log(f"== {info['app_wire']}")
        wire = None
    threading.Thread(target=subscriber, daemon=True).start()
    time.sleep(0.3)  # the subscription is in before the first split

    def first_pane():
        return pick_pane(ctl.reply(ctl.send({"cmd": "list-workspaces"}))["data"], shown_workspace)

    pane = first_pane()
    if pane is None:
        ctl.reply(ctl.send({"cmd": "new-workspace"}))
        time.sleep(1.0)  # the new workspace's first pane
        pane = first_pane()
    if pane is None:
        raise SystemExit("no pane to split")

    rows = []
    info["failures"] = []
    next_stream = 1
    for i in range(args.runs):
        with lock:
            events.clear()
        accepted_before = accepted_connections(ctl) if census else None
        wire_before = wire_counts(wire()) if wire else None
        t0 = now()
        req = {"cmd": "split", "pane": pane, "dir": "right", "cols": 80, "rows": 24}
        if "terminal-placement-env-v1" in caps:
            req["terminal_id"] = uuid.uuid4().hex
        r = ctl.reply(ctl.send(req))
        t_split = now()
        if not r.get("ok"):
            log(f"split refused: {r}")
            info["failures"].append(f"run {i}: split refused: {r.get('error')}")
            break
        surface = r["data"]["surface"]
        ctl.reply(ctl.send({"cmd": "list-workspaces"}))
        t_list = now()
        tq = now()
        ctl.reply(ctl.send({"cmd": "identify"}))
        rtt = (now() - tq) * 1000
        stream_id = None
        if use_streams:
            stream_id, next_stream = next_stream, next_stream % 0xFFFF + 1  # u16, 0 is the control stream
        view = open_view(path, ctl, surface, stream_id)
        if view["refused"]:
            log(f"attach refused: {view['refused']}")
            info["failures"].append(f"run {i}: attach refused: {view['refused'].get('error')}")
        with lock:
            seen = {}
            for t, name in events:
                if t >= t0 and name not in seen:
                    seen[name] = (t - t0) * 1000
        t_hs, t_attach, t_first = view["t_hs"], view["t_attach"], view["t_first"]
        row = {
            "label": args.label, "run": i,
            "split_reply": (t_split - t0) * 1000,
            "ev_pane_added": seen.get("pane-added"),
            "ev_layout_changed": seen.get("layout-changed"),
            "list_workspaces": (t_list - t_split) * 1000,
            "warm_rtt": rtt,
            "attach_handshake": (t_hs - view["t0"]) * 1000,
            "attach_reply": ((t_attach or t_hs) - t_hs) * 1000,
            "first_content_after_attach": ((t_first - t_hs) * 1000) if t_first else None,
        }
        row["app_path_sum"] = row["split_reply"] + row["list_workspaces"] + row["attach_handshake"] + row["attach_reply"]
        if args.streams:
            row.update({k: view[k] for k in BENCH_VIEW_METRICS})
            row["stream"] = stream_id
        if census or wire_before:
            time.sleep(args.settle)  # the app sees the new pane and attaches its view
        if census:
            accepted_after = accepted_connections(ctl)
            if accepted_before is not None and accepted_after is not None:
                row["app_connections_per_view"] = accepted_after - accepted_before - view["bench_view_connections"]
        if wire_before:
            wire_after = wire_counts(wire())
            if wire_after:
                row.update(app_view_delta(wire_before, wire_after))
        rows.append(row)
        log(json.dumps({k: (round(v, 1) if isinstance(v, float) else v) for k, v in row.items()}))
        ctl.reply(ctl.send({"cmd": "close-surface", "surface": surface}))
        time.sleep(0.5)  # the close settles before the next split
    ctl.close()
    if args.streams:
        info["ipc2"] = ipc2_verdict(rows, app_absent)
        log(f"== ipc2: {json.dumps(info['ipc2'])}")
    return rows, info


def summarize(rows, label, log=print):
    keys = METRICS + [k for k in STREAM_METRICS if any(k in r for r in rows)]
    stats = {k: distribution([r.get(k) for r in rows], digits=3, mean=False) for k in keys}
    log(f"== {label} n={len(rows)}")
    for k in keys:
        if stats[k]:
            log(bench_tagged.summary_line(k, stats[k], width=28))
    return stats


class SshLink:
    """`cmux remote connect ssh://HOST --headless` on a private local socket; every request through it crosses the
    link (remote-group-e2e.py starts it the same way)."""

    def __init__(self, cli, host, ssh_config=None, timeout=240):
        self.work = tempfile.mkdtemp(prefix="split-bench-ssh-")
        self.socket = os.path.join(self.work, "mux.sock")
        self.log_path = os.path.join(self.work, "connect.log")
        ssh_args = ["--ssh-arg", "-F", "--ssh-arg", ssh_config] if ssh_config else []
        self.log = open(self.log_path, "w")
        self.process = subprocess.Popen(
            [cli, "remote", "connect", f"ssh://{host}", "--headless", "--json", *ssh_args,
             "--state-dir", os.path.join(self.work, "state"), "--local-socket", self.socket,
             "--session", "split-latency-bench"],
            stdout=self.log, stderr=subprocess.STDOUT, text=True, stdin=subprocess.DEVNULL)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and self.process.poll() is None:
            if '"state":"connected"' in open(self.log_path).read() and os.path.exists(self.socket):
                return
            time.sleep(0.5)  # bounded wait for the SSH bootstrap
        tail = open(self.log_path).read()[-600:]
        self.close()
        raise SystemExit(f"split-latency-bench: ssh link to {host} did not connect in {timeout} s: {tail}")

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.log.close()
        shutil.rmtree(self.work, ignore_errors=True)


def shown_workspace(app):
    """The workspace id the launched app's window shows (snapshot.get), or None."""
    snap = app.rpc("snapshot.get") or {}
    windows = (snap.get("topology") or {}).get("windows") or []
    return next((w.get("workspace") for w in windows if w.get("workspace")), None)


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    where = ap.add_mutually_exclusive_group(required=True)
    where.add_argument("--socket", help="a cmux-tui daemon socket")
    where.add_argument("--tag", help="launch today's tagged build (bench_launch.py) and use its daemon")
    ap.add_argument("--app", help="the tag's bundle (default $NX_APP, else its DerivedData build)")
    ap.add_argument("--out", "--artifacts", dest="artifacts",
                    help="BenchApp's folder: report.json and cmux-perf-result/v1 (default artifacts/split-latency-bench/TAG)")
    ap.add_argument("--runs", type=int, default=15)
    ap.add_argument("--label", default="split")
    ap.add_argument("--jsonl", help="also append every run as one JSON line here")
    ap.add_argument("--story", help="write the run as cmux-perf-result/v1 under this story (--tag, --machine local)")
    ap.add_argument("--session", choices=["light"], default="light", help="result-v1 session (the story runner's)")
    ap.add_argument("--streams", action="store_true", help="per-view handshake round trips, requests, connections")
    ap.add_argument("--settle", type=float, default=1.0, help="seconds the app gets to attach its view (--tag --streams)")
    ap.add_argument("--machine", choices=["local", "ssh"], default="local")
    ap.add_argument("--ssh-host", help="SSH alias or user@host for --machine ssh")
    ap.add_argument("--ssh-config", help="ssh -F file for --machine ssh")
    ap.add_argument("--cmux", default=shutil.which("cmux") or "cmux", help="the CLI that bridges (without --tag)")
    ap.add_argument("--connect-timeout", type=float, default=240)
    args = ap.parse_args(argv)
    if args.machine == "ssh" and not args.ssh_host:
        ap.error("--machine ssh needs --ssh-host")
    if args.app and not args.tag:
        ap.error("--app goes with --tag")
    if args.story:
        if not args.tag or args.machine != "local":
            ap.error("--story needs --tag on the local machine: only a launched app's run describes the story's build")
        problem = story_problem(args.story, ENGINE)
        if problem:
            ap.error(problem)
    # Only a launched app on the local daemon attaches views of the bench's splits.
    args.app_census = bool(args.tag) and args.machine == "local"
    return args


def record(app, story, rows, info, runs, streams, out_report, log=print):
    """The run's series as result-v1 under `story` when every split and attach succeeded; the exit code. What was
    written, or why nothing was, goes into `out_report["recorded"]`."""
    failures = list(info.get("failures") or [])
    if len(rows) < runs and not failures:
        failures.append(f"{len(rows)} of {runs} runs")
    if failures:
        out_report["recorded"] = f"none: {'; '.join(failures)}"
        log(f"RESULT-V1 {out_report['recorded']}")
        return 1
    series = sp_report.split_latency_series(rows, METRICS, STREAM_METRICS if streams else [])
    out_report["recorded"] = sp_report.record_all(app, story, ENGINE, series, log=log)
    if not sp_report.any_written(out_report["recorded"]):
        log("RESULT-V1 FAIL: no series was written")
        return 1
    return 0


def main(argv=None):
    args = parse_args(argv)
    app = link = None
    code = 0
    report = {"label": args.label, "machine": args.machine, "streams_asked": args.streams}
    try:
        shown = None
        if args.tag:
            from bench_launch import BenchApp
            bundle = bench_tagged.resolve_app(args.tag, args.app)
            artifacts = args.artifacts or os.path.join(bench_tagged.ROOT, "artifacts", "split-latency-bench", args.tag)
            app = BenchApp(bundle, out=artifacts, perf_session=args.session)
            app.launch()  # LaunchError (a SystemExit) carries the reason
            report.update(tag=app.tag, app=app.app, ready_seconds=app.ready_seconds)
            path = bench_tagged.daemon_socket(app.tag)
            shown = shown_workspace(app)
        else:
            path = args.socket
        report["host"] = bench_tagged.host_block()
        if args.machine == "ssh":
            link = SshLink(app.cli if app else args.cmux, args.ssh_host, args.ssh_config, args.connect_timeout)
            path, shown = link.socket, None
            report["ssh_host"] = args.ssh_host
        absent = None
        if not args.app_census:
            absent = ("--machine ssh: the launched app does not view the bench's bridged link" if args.machine == "ssh"
                      else "--socket: no app is attached") + "; bench_view_* is the bench's own reference view"
        app_wire = (lambda: app.rpc("debug.daemon.wire", timeout=10)) if app and args.app_census else None
        rows, info = bench(path, args, shown_workspace=shown, app_wire=app_wire, app_absent=absent)
        report.update(info)
        report["n"] = len(rows)
        report["stats"] = summarize(rows, args.label)
        if args.jsonl:
            with open(args.jsonl, "a") as f:
                for r in rows:
                    f.write(json.dumps(r) + "\n")
        if args.story:
            code = record(app, args.story, rows, info, args.runs, args.streams, report)
        if app:
            with open(os.path.join(app.out, "report.json"), "w") as f:
                json.dump({**report, "rows": rows}, f, indent=1)
            print(f"== report {os.path.join(app.out, 'report.json')}")
        h = report["host"]
        print(f"== host {h.get('host')} ({h.get('platform')}) macOS {h.get('macos')} {h.get('chip') or ''} "
              f"{h.get('display_hz')} Hz")
    finally:
        if link:
            link.close()
        if app:
            app.stop()
    return code


if __name__ == "__main__":
    sys.exit(main())
