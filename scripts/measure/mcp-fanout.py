#!/usr/bin/env python3
"""MCP tool-server fan-out of open agent chats: processes, RSS and idle CPU per kind at N chats.

Driver of scripts/measure/mcp-fanout.sh (which fetches the app and the harnesses). For each harness and
each N it starts one isolated acpmux daemon from the app under test (`Contents/Resources/bin/acpmux`, so
the chats get cmux's agent tools exactly as that build starts them: `cmux mcp serve`, acpmux's own
servers, `cmux-cua`), opens N chats at once, each with one turn, and leaves them idle with the client
attached (the chat on screen). The model is the stand-in of scripts/cmux-next/acpmux-overhead-bench.py
(answers at once, no credential, no network); the harnesses are real (Claude Code, Codex). A Claude turn
first calls one cmux tool (`--tool`, default `mcp__cmux__cmux_exec`), then answers "ok".

Then, `--settle` seconds after the last turn ended, `ps` is read every `--interval` seconds for
`--sample` seconds (phase `awake`). Only the daemon's process tree counts (the daemon, each
`hosts/<id>.json` host and harness, and everything under them). Per kind (argv-matched):
  count   processes (median over the samples)
  rss_mb  their summed RSS (median over the samples)
  cpu_pct CPU time used over the window (`ps` time, user + system) / wall time, in % of one core
With `--after-idle S` (default 150; acpmux hibernates an idle chat's agent after 2 min, hub/idle.rs),
one more read S seconds after the last turn ended (phase `idle`, count and RSS only).

Lines (stdout):
  MCP-FANOUT row harness=H n=N phase=P kind=K count=C rss_mb=R cpu_pct=X
  MCP-FANOUT-RAW harness=H n=N <ps -o pid,ppid,lstart,rss,%cpu,command line, redacted>   (at N == --raw-at)
  MCP-FANOUT-CHAIN harness=H n=N kind=K pid>ppid(comm)>...                               (at N == --raw-at)
  MCP-FANOUT-CHAT harness=H n=N opened=O failed=F tool_reqs=T open_s=S  (T: model requests after the tool call, >= chats that called it)
then one table: N, harness, kind, count, RSS MB, CPU %.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import glob
import importlib.util
import json
import os
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH_PATH = os.path.join(HERE, "..", "cmux-next", "acpmux-overhead-bench.py")
spec = importlib.util.spec_from_file_location("acpmux_overhead_bench", BENCH_PATH)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)

TOOL_MARK = "MCP_FANOUT_TOOL_TURN"
# The kinds that are MCP tool servers (the total row sums these).
TOOL_KINDS = ("cmux-mcp-serve", "cmux-cua", "acpmux-tools-mcp", "acpmux-forum-mcp", "acpmux-acpmux-mcp",
              "acpmux-subsession-mcp", "acpmux-secret-mcp", "acpmux-offer-mcp")


# ---------------------------------------------------------------- stand-in: one cmux tool call per Claude chat

def fanout_call(server, body):
    """The tool_use for a chat's first prompt (marked TOOL_MARK): the tool itself when the request offers
    it, else first `ToolSearch` selecting it (Claude Code defers MCP tools), then the tool; None (answer
    "ok") once the tool's result is back."""
    tool = getattr(server, "fanout_tool", None)
    if not tool:
        return None
    msgs = body.get("messages") or []

    def blocks_of(m):
        c = m.get("content")
        return c if isinstance(c, list) else [{"type": "text", "text": c or ""}]

    if not any(TOOL_MARK in (b.get("text") or "") for m in msgs if m.get("role") == "user"
               for b in blocks_of(m) if isinstance(b, dict)):
        return None
    called = [b.get("name") for m in msgs if m.get("role") == "assistant"
              for b in blocks_of(m) if isinstance(b, dict) and b.get("type") == "tool_use"]
    if tool in called:
        with server.lock:
            server.tool_results.append("1")
        return None
    names = [t.get("name") for t in body.get("tools") or []]
    if "Bash" not in names:  # a side request (title, summary) offers no tools
        return None
    if tool in names or "ToolSearch" in called:
        return {"__name": tool, "script": "return 1"}
    if "ToolSearch" in names:
        return {"__name": "ToolSearch", "query": f"select:{tool}", "max_results": 1}
    with server.lock:
        server.fanout_missing = sorted(n for n in names if n)[:80]
    return None


_orig_events = bench.tool_use_events


def fanout_events(model, usage, call):
    name = call.pop("__name", "Bash")
    events = _orig_events(model, usage, call)
    for _, data in events:
        block = data.get("content_block") if isinstance(data, dict) else None
        if block and block.get("type") == "tool_use":
            block["name"] = name
    return events


bench.build_call = fanout_call
bench.tool_use_events = fanout_events


# ---------------------------------------------------------------- daemon client (thread-safe)

class Client:
    def __init__(self, daemon):
        self.d = daemon
        self.lock = threading.Lock()
        self.next = 1000

    def send(self, msg):
        with self.lock:
            self.d.io.send(msg)

    def rid(self):
        with self.lock:
            self.next += 1
            return self.next

    def request(self, method, params, timeout=120.0):
        rid = self.rid()
        start = self.d.io.mark()
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        _, m, _ = self.d.io.wait(lambda m: m.get("id") == rid, timeout, start)
        if "error" in m:
            raise RuntimeError(f"{method}: {m['error']}")
        return m["result"]

    def turn(self, sid, text, timeout=300.0):
        rid = self.rid()
        start = self.d.io.mark()
        self.send({"jsonrpc": "2.0", "id": rid, "method": "session/prompt",
                   "params": {"sessionId": sid, "prompt": [{"type": "text", "text": text}]}})
        _, m, _ = self.d.io.wait(lambda m: m.get("id") == rid, timeout, start)
        if "error" in m:
            raise RuntimeError(f"session/prompt: {m['error']}")


# ---------------------------------------------------------------- ps

def cpu_seconds(s):
    days = 0
    if "-" in s:
        d, s = s.split("-", 1)
        days = int(d)
    parts = [float(p) for p in s.split(":")]
    secs = 0.0
    for p in parts:
        secs = secs * 60 + p
    return days * 86400 + secs


def ps_table():
    """{pid: (ppid, rss_kb, cpu_s, argv string)} of every process."""
    out = subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,rss=,time=,command="], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        f = line.split(None, 4)
        if len(f) < 5 or not f[0].isdigit():
            continue
        try:
            rows[int(f[0])] = (int(f[1]), int(f[2]), cpu_seconds(f[3]), f[4])
        except ValueError:
            continue
    return rows


def roots_of(daemon):
    roots = [daemon.p.pid]
    for path in glob.glob(os.path.join(daemon.home, "hosts", "*.json")):
        try:
            rec = json.load(open(path))
        except (OSError, ValueError):
            continue
        roots += [p for p in (rec.get("host_pid"), rec.get("harness_pid")) if isinstance(p, int)]
    return list(dict.fromkeys(roots))


def tree(rows, roots):
    kids = {}
    for pid, r in rows.items():
        kids.setdefault(r[0], []).append(pid)
    seen, stack = [], [p for p in roots if p in rows]
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.append(p)
        stack.extend(kids.get(p, []))
    return seen


def kind_of(argv: str) -> str:
    toks = argv.split()
    base = os.path.basename(toks[0]) if toks else "?"
    rest = toks[1:]
    if "__agent-host" in rest:
        return "agent-host"
    if "__bg-run" in rest:
        return "bg-run"
    if base == "acpmux" or base.startswith("acpmux"):
        sub = next((t for t in rest if not t.startswith("-")), "")
        if sub.endswith("-mcp"):
            return "acpmux-" + sub
        if sub == "daemon":
            return "acpmux-daemon"
        return "acpmux-" + (sub or "other")
    if base.endswith("-mcp"):
        return base
    if base == "cmux-cua" or "cua-mcp" in toks:
        return "cmux-cua"
    if base in ("cmux", "cmux-tui") and "mcp" in rest and "serve" in rest:
        return "cmux-mcp-serve"
    if base in ("cmux", "cmux-tui"):
        return "cmux-" + next((t for t in rest if not t.startswith("-")), "other")
    if base == "claude" or re.search(r"/claude(-code)?/cli\.js|/\.bin/claude\b|claude-code", argv):
        return "claude"
    if base == "codex" or "/codex" in toks[0] or "@openai/codex" in argv:
        return "codex"
    if base in ("node", "bun") and len(toks) > 1:
        return base + ":" + os.path.basename(toks[1])
    return "other:" + base


SECRET = re.compile(r"((?:token|key|secret|password|auth)[A-Za-z_]*[=:\s]+)\S+", re.I)
LONG = re.compile(r"\b[A-Za-z0-9_\-]{32,}\b")


def redact(s: str) -> str:
    s = SECRET.sub(r"\1<redacted>", s)
    s = LONG.sub("<redacted>", s)
    return s if len(s) <= 400 else s[:400] + "..."


# ---------------------------------------------------------------- one run

def open_chats(client, harness, n, scratch, parallel):
    out = {"opened": 0, "failed": 0, "errors": [], "sids": []}
    lock = threading.Lock()

    def one(k):
        cwd = os.path.realpath(os.path.join(scratch, f"chat-{harness}-{k}"))
        os.makedirs(cwd, exist_ok=True)
        r = client.request("session/new", {"cwd": cwd, "mcpServers": [],
                                           "_meta": {"acpmux": {"harness": harness, "policy": "approve-all",
                                                                "model": bench.MODELS[harness]}}}, timeout=300)
        sid = r["sessionId"]
        with lock:
            out["sids"].append(sid)
        client.turn(sid, f"{TOOL_MARK}: call the cmux tool once, then reply with ok.")
        return sid

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(parallel, n))) as ex:
        for fut in [ex.submit(one, k) for k in range(n)]:
            try:
                fut.result()
                out["opened"] += 1
            except Exception as e:  # a chat that did not open is counted, not fatal
                out["failed"] += 1
                out["errors"].append(str(e)[:300])
    return out


def measure(daemon, settle, sample, interval):
    time.sleep(settle)
    samples = []
    t_end = time.monotonic() + sample
    while True:
        rows = ps_table()
        pids = tree(rows, roots_of(daemon))
        samples.append((time.monotonic(), {p: rows[p] for p in pids}))
        if time.monotonic() >= t_end:
            break
        time.sleep(min(interval, max(0.0, t_end - time.monotonic())))
    t0, first = samples[0]
    t1, last = samples[-1]
    wall = max(t1 - t0, 1e-6)
    seen_first = {}
    for _, snap in samples:
        for p, r in snap.items():
            seen_first.setdefault(p, r[2])
    kinds = {}
    for _, snap in samples:
        per = {}
        for p, r in snap.items():
            k = kind_of(r[3])
            c, rss = per.get(k, (0, 0))
            per[k] = (c + 1, rss + r[1])
        for k in set(per) | set(kinds):
            kinds.setdefault(k, {"counts": [], "rss": []})
            c, rss = per.get(k, (0, 0))
            kinds[k]["counts"].append(c)
            kinds[k]["rss"].append(rss)
    cpu = {}
    for p, r in last.items():
        k = kind_of(r[3])
        cpu[k] = cpu.get(k, 0.0) + max(0.0, r[2] - seen_first.get(p, r[2]))
    result = {}
    for k, v in kinds.items():
        result[k] = {"count": statistics.median(v["counts"]), "rss_mb": round(statistics.median(v["rss"]) / 1024, 1),
                     "cpu_pct": round(100.0 * cpu.get(k, 0.0) / wall, 2)}
    return result, last, wall


def snapshot_counts(daemon):
    rows = ps_table()
    snap = {p: rows[p] for p in tree(rows, roots_of(daemon))}
    result = {}
    for p, r in snap.items():
        k = kind_of(r[3])
        e = result.setdefault(k, {"count": 0, "rss_mb": 0.0, "cpu_pct": None})
        e["count"] += 1
        e["rss_mb"] = round(e["rss_mb"] + r[1] / 1024, 1)
    return result


def add_total(result):
    tot = {"count": 0, "rss_mb": 0.0, "cpu_pct": 0.0}
    for k in TOOL_KINDS:
        if k in result:
            tot["count"] += result[k]["count"]
            tot["rss_mb"] = round(tot["rss_mb"] + result[k]["rss_mb"], 1)
            if result[k]["cpu_pct"] is not None:
                tot["cpu_pct"] = round(tot["cpu_pct"] + result[k]["cpu_pct"], 2)
            else:
                tot["cpu_pct"] = None
    result["TOTAL-tool-servers"] = tot
    return result


def emit_raw(harness, n, snap, stop_at):
    pids = [p for p, r in snap.items() if kind_of(r[3]) in TOOL_KINDS]
    if not pids:
        print(f"MCP-FANOUT-RAW harness={harness} n={n} (no tool-server process)")
        return
    out = subprocess.run(["ps", "-ww", "-o", "pid,ppid,lstart,rss,%cpu,command", "-p", ",".join(map(str, pids))],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        print(f"MCP-FANOUT-RAW harness={harness} n={n} {redact(line)}")
    rows = ps_table()
    for p in sorted(pids):
        chain, cur = [], p
        for _ in range(12):
            r = rows.get(cur)
            if not r:
                chain.append(f"{cur}(gone)")
                break
            toks = r[3].split()
            label = os.path.basename(toks[0]) + (" " + toks[1] if len(toks) > 1 and not toks[1].startswith("-") else "")
            chain.append(f"{cur}({label})")
            if cur <= 1 or cur == stop_at:
                break
            cur = r[0]
        print(f"MCP-FANOUT-CHAIN harness={harness} n={n} kind={kind_of(rows[p][3]) if p in rows else '?'} "
              + " > ".join(chain))


def cleanup(client, daemon, sids, known):
    for sid in sids:
        try:
            client.request("session/close", {"sessionId": sid}, timeout=20)
        except Exception:
            pass
    daemon.close()
    time.sleep(2)
    # Anything of this run's tree that outlived the daemon: ended by pid (they are ours).
    rows = ps_table()
    left = [p for p in known if p in rows and p != os.getpid()]
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for p in left:
            try:
                os.kill(p, sig)
            except OSError:
                pass
        if not left:
            break
        time.sleep(3)
        rows = ps_table()
        left = [p for p in left if p in rows]
    if left:
        print(f"MCP-FANOUT-LEFT {left}", file=sys.stderr)


def run_one(args, harness, n, stand, url):
    # Short: the daemon socket lives under it (104 bytes on macOS, 108 on Linux).
    scratch = tempfile.mkdtemp(prefix="mcpf-", dir="/tmp")
    env = bench.env_for(url, scratch)
    home = os.path.join(scratch, "acpmux-home")
    os.makedirs(home, mode=0o700)
    os.chmod(home, 0o700)  # acpmux refuses a home another user may write (a umask of 002)
    extra = {}
    if args.idle_child_secs:
        extra["ACPMUX_IDLE_CHILD_SECS"] = str(args.idle_child_secs)
    try:
        daemon = bench.Daemon(os.path.abspath(args.acpmux), env, home, extra)
    except Exception:
        print(open(os.path.join(home, "daemon.log"), errors="replace").read()[-2000:], file=sys.stderr)
        shutil.rmtree(scratch, ignore_errors=True)
        raise
    client = Client(daemon)
    known = set()
    sids = []
    try:
        with stand.lock:
            stand.tool_results.clear()
        t0 = time.monotonic()
        o = open_chats(client, harness, n, scratch, args.parallel)
        sids = o["sids"]
        t_last = time.monotonic()
        with stand.lock:
            tools = len(stand.tool_results)
        print(f"MCP-FANOUT-CHAT harness={harness} n={n} opened={o['opened']} failed={o['failed']} tool_reqs={tools} "
              f"open_s={t_last - t0:.1f}" + (f" first_error={o['errors'][0]!r}" if o["errors"] else ""), flush=True)
        if harness == "claude" and tools == 0 and getattr(stand, "fanout_missing", None) is not None:
            print(f"MCP-FANOUT-NOTE tool {args.tool} not offered; tools offered: {stand.fanout_missing}", flush=True)
        res, last, wall = measure(daemon, args.settle, args.sample, args.interval)
        known |= set(last)
        res = add_total(res)
        for k in sorted(res):
            r = res[k]
            print(f"MCP-FANOUT row harness={harness} n={n} phase=awake kind={k} count={r['count']} rss_mb={r['rss_mb']} "
                  f"cpu_pct={r['cpu_pct']} window_s={wall:.0f}", flush=True)
        if n == args.raw_at:
            emit_raw(harness, n, last, daemon.p.pid)
        idle = None
        if args.after_idle:
            wait = args.after_idle - (time.monotonic() - t_last)
            if wait > 0:
                time.sleep(wait)
            rows = ps_table()
            known |= set(tree(rows, roots_of(daemon)))
            idle = add_total(snapshot_counts(daemon))
            for k in sorted(idle):
                r = idle[k]
                print(f"MCP-FANOUT row harness={harness} n={n} phase=idle{args.after_idle} kind={k} count={r['count']} "
                      f"rss_mb={r['rss_mb']} cpu_pct=None", flush=True)
        return {"awake": res, "idle": idle, "chat": {k: v for k, v in o.items() if k != "sids"}}
    finally:
        rows = ps_table()
        known |= set(tree(rows, roots_of(daemon)))
        cleanup(client, daemon, sids, known)
        shutil.rmtree(scratch, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--acpmux", required=True, help="the app's Contents/Resources/bin/acpmux")
    ap.add_argument("--harness", default="claude,codex")
    ap.add_argument("--counts", default="1,5,15,30")
    ap.add_argument("--settle", type=int, default=15)
    ap.add_argument("--sample", type=int, default=60)
    ap.add_argument("--interval", type=float, default=5.0)
    ap.add_argument("--after-idle", type=int, default=150)
    ap.add_argument("--idle-child-secs", type=int, default=0, help="ACPMUX_IDLE_CHILD_SECS for the daemon (0: its default)")
    ap.add_argument("--parallel", type=int, default=8, help="chats opened at once")
    ap.add_argument("--raw-at", type=int, default=5)
    ap.add_argument("--tool", default="mcp__cmux__cmux_exec", help="the tool each Claude chat calls once ('' for none)")
    ap.add_argument("--json")
    args = ap.parse_args()

    stand = bench.StandIn()
    stand.fanout_tool = args.tool or None
    threading.Thread(target=stand.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{stand.server_address[1]}"
    results = {}
    for h in args.harness.split(","):
        for n in [int(x) for x in args.counts.split(",")]:
            print(f"MCP-FANOUT-START harness={h} n={n} load={os.getloadavg()[0]:.2f}", file=sys.stderr, flush=True)
            results[f"{h}/{n}"] = run_one(args, h, n, stand, url)
    if args.json:
        with open(args.json, "w") as f:
            json.dump(results, f, indent=1)
    print()
    print("| N | harness | phase | kind | count | RSS MB | CPU % |")
    print("|---|---|---|---|---|---|---|")
    for key, r in results.items():
        h, n = key.split("/")
        for phase in ("awake", "idle"):
            res = r.get(phase)
            if not res:
                continue
            for k in sorted(res, key=lambda k: (k != "TOTAL-tool-servers", k not in TOOL_KINDS, k)):
                v = res[k]
                print(f"| {n} | {h} | {phase} | {k} | {v['count']} | {v['rss_mb']} | {v['cpu_pct'] if v['cpu_pct'] is not None else '-'} |")


if __name__ == "__main__":
    main()
