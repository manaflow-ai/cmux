#!/usr/bin/env python3
"""acpmux vs raw Claude Code / raw Codex: process lifecycle bench (spawn, footprint, idle, teardown, hibernation).

Four sides, each with N in {1,5,20} concurrent chats, one turn each, then idle:
  claude-raw     `claude -p --input-format stream-json ...` per chat (as acpmux drives it)
  codex-raw      `codex app-server` per chat, thread/start + turn/start
  acpmux+claude  one isolated acpmux daemon (own ACPMUX_HOME), session/new + session/prompt over its socket
  acpmux+codex   same, harness codex
A local stand-in model (scripts/cmux-next/acpmux-overhead-bench.py StandIn) answers at once: no creds, no
network, so every number is the client side. Measured per side and N:
  spawn          ms from the chat's start to ready (raw: handshake answered; acpmux: session/new answered)
                 and to first token; p50/p95 over >=5 runs at N=1, over the chats of the run at N>1
  footprint      processes (whole tree: harness, MCP servers, acpmux daemon and agent hosts, found by an
                 env tag every child inherits plus descendants of the roots), per chat and total
                 (acpmux daemon amortized over N), RSS and PSS MB, idle CPU % (of one core) over 30 s
  teardown       client ends the session normally (raw: stdin EOF; acpmux: session/close), and SIGKILL of
                 the client (acpmux: also SIGKILL of the daemon): ms until every session process is gone,
                 and how many are left 10 s later (orphans)
  hibernation    acpmux sides: processes/RSS left after idle hibernation (ACPMUX_IDLE_CHILD_SECS shortened
                 to --hibernate-secs; hub/idle.rs default is 120 s)
The bench's own client process is never counted. Everything it started is SIGKILLed at the end of each run.

Run (pin to CPUs 0-3; writes .build/acpmux-vs-harness/lifecycle.json and lifecycle.md):
  taskset -c 0-3 python3 scripts/measure/acpmux-vs-harness/lifecycle.py [--acpmux ~/.local/bin/acpmux]
      [--sides claude-raw,codex-raw,acpmux+claude,acpmux+codex] [--ns 1,5,20] [--idle-cpu-secs 30]
"""

from __future__ import annotations

import argparse
import importlib.util
import itertools
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
BENCH_PATH = os.path.join(ROOT, "scripts", "cmux-next", "acpmux-overhead-bench.py")
spec = importlib.util.spec_from_file_location("acpmux_overhead_bench", BENCH_PATH)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)

TAG_VAR = "LCBENCH_TAG"
SIDES = ["claude-raw", "codex-raw", "acpmux+claude", "acpmux+codex"]
CLK = os.sysconf("SC_CLK_TCK")
PAGE_KB = os.sysconf("SC_PAGE_SIZE") // 1024


# ---------------------------------------------------------------- process census


def census(tag: str, roots=()):
    """{pid: {ppid, rss_kb, cpu_ticks, comm}} for every live process carrying `tag` in its environment, or
    under one of `roots`."""
    rows = {}
    needle = f"{TAG_VAR}={tag}".encode()
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        pid = int(d)
        try:
            with open(f"/proc/{d}/stat", "rb") as f:
                st = f.read().decode(errors="replace")
        except OSError:
            continue
        rp = st.rfind(")")
        comm = st[st.find("(") + 1:rp]
        f = st[rp + 2:].split()
        state, ppid = f[0], int(f[1])
        if state in ("Z", "X"):
            continue
        tagged = False
        try:
            with open(f"/proc/{d}/environ", "rb") as e:
                tagged = needle in e.read()
        except OSError:
            pass
        rows[pid] = {"ppid": ppid, "cpu": int(f[11]) + int(f[12]), "rss_kb": int(f[21]) * PAGE_KB,
                     "comm": comm, "tagged": tagged}
    keep = {p for p, r in rows.items() if r["tagged"]} | {p for p in roots if p in rows}
    changed = True
    while changed:
        changed = False
        for p, r in rows.items():
            if p not in keep and r["ppid"] in keep:
                keep.add(p)
                changed = True
    return {p: rows[p] for p in keep}


def pss_kb(pid):
    try:
        for line in open(f"/proc/{pid}/smaps_rollup"):
            if line.startswith("Pss:"):
                return int(line.split()[1])
    except OSError:
        pass
    return 0


def kill_all(tag, roots=()):
    for _ in range(3):
        procs = census(tag, roots)
        if not procs:
            return
        for p in procs:
            try:
                os.kill(p, signal.SIGKILL)
            except OSError:
                pass
        time.sleep(0.3)


def pct(xs, q):
    return bench.pct([x for x in xs if x is not None], q)


# ---------------------------------------------------------------- the client (a child process)


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def client_raw(harness, n, scratch):
    """N raw harnesses, one turn each, then idle until "close" on stdin."""
    env = dict(os.environ)
    procs = [None] * n

    def one(i):
        cwd = os.path.join(scratch, f"work-{i}")
        os.makedirs(cwd, exist_ok=True)
        t0 = time.perf_counter()
        try:
            if harness == "claude":
                argv = ["claude", "-p", "--model", bench.MODELS["claude"], "--input-format", "stream-json",
                        "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                        "--replay-user-messages", "--permission-prompt-tool", "stdio",
                        "--session-id", str(uuid.uuid4()), "--permission-mode", "default"]
                p = procs[i] = bench.spawn(argv, env, cwd)
                io = bench.Lines(p.stdout, p.stdin)
                io.send({"type": "control_request", "request_id": "boot-1",
                         "request": {"subtype": "initialize", "hooks": {}}})
                tr, _, j = io.wait(lambda m: m.get("type") == "control_response", timeout=180)
                io.send({"type": "user", "message": {"role": "user",
                                                     "content": [{"type": "text", "text": "Reply with ok."}]}})
                tf, _, j = io.wait(lambda m: m.get("type") == "stream_event"
                                   and m.get("event", {}).get("type") == "content_block_delta", start=j, timeout=180)
                te, _, _ = io.wait(lambda m: m.get("type") == "result", start=j, timeout=180)
            else:
                p = procs[i] = bench.spawn(["codex", "app-server"], env, cwd)
                io = bench.Lines(p.stdout, p.stdin)
                io.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                         "params": {"clientInfo": {"name": "lifecycle-bench", "version": "1"}}})
                io.wait(lambda m: m.get("id") == 1, timeout=180)
                io.send({"jsonrpc": "2.0", "method": "initialized"})
                io.send({"jsonrpc": "2.0", "id": 2, "method": "thread/start", "params": {"cwd": cwd}})
                tr, m, j = io.wait(lambda m: m.get("id") == 2, timeout=180)
                if "error" in m:
                    raise RuntimeError(f"thread/start: {m['error']}")
                th = m["result"]["thread"]["id"]
                io.send({"jsonrpc": "2.0", "id": 3, "method": "turn/start",
                         "params": {"threadId": th, "input": [{"type": "text", "text": "Reply with ok."}]}})
                tf, _, j = io.wait(lambda m: m.get("method") == "item/agentMessage/delta", start=j, timeout=180)
                te, _, _ = io.wait(lambda m: m.get("method") == "turn/completed", start=j, timeout=180)
            emit({"chat": i, "ready": bench.ms(t0, tr), "first": bench.ms(t0, tf), "end": bench.ms(t0, te)})
        except Exception as e:  # noqa: BLE001: reported, the run goes on
            emit({"chat": i, "error": str(e)})

    ts = [threading.Thread(target=one, args=(i,)) for i in range(n)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    emit({"all": "idle"})
    sys.stdin.readline()
    # Normal end: the client closes each harness's stdin, as an editor closing the chat does, and waits.
    for p in procs:
        if p:
            try:
                p.stdin.close()
            except OSError:
                pass
    for p in procs:
        if p:
            try:
                p.wait(30)
            except subprocess.TimeoutExpired:
                pass
    emit({"closed": True})


def client_acpmux(harness, n, scratch, sock_path):
    s = socket.socket(socket.AF_UNIX)
    s.connect(sock_path)
    io = bench.Lines(s.makefile("rb"), bench.SockFile(s))
    ids = itertools.count(1000)
    lock = threading.Lock()
    sids = [None] * n

    def nid():
        with lock:
            return next(ids)

    def req(method, params, timeout=180):
        rid = nid()
        start = io.mark()
        with lock:
            io.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        t, m, _ = io.wait(lambda m: m.get("id") == rid, timeout, start)
        if "error" in m:
            raise RuntimeError(f"{method}: {m['error']}")
        return t, m["result"]

    def one(i):
        cwd = os.path.realpath(os.path.join(scratch, f"work-{i}"))
        os.makedirs(cwd, exist_ok=True)
        t0 = time.perf_counter()
        try:
            tr, r = req("session/new", {"cwd": cwd, "mcpServers": [],
                                        "_meta": {"acpmux": {"harness": harness, "policy": "approve-all",
                                                             "model": bench.MODELS[harness]}}})
            sid = sids[i] = r["sessionId"]
            rid = nid()
            start = io.mark()
            with lock:
                io.send({"jsonrpc": "2.0", "id": rid, "method": "session/prompt",
                         "params": {"sessionId": sid, "prompt": [{"type": "text", "text": "Reply with ok."}]}})
            tf, _, _ = io.wait(lambda m: m.get("method") == "session/update"
                               and m.get("params", {}).get("sessionId") == sid
                               and m["params"].get("update", {}).get("sessionUpdate") == "agent_message_chunk",
                               timeout=180, start=start)
            te, m, _ = io.wait(lambda m: m.get("id") == rid, timeout=180, start=start)
            if "error" in m:
                raise RuntimeError(f"session/prompt: {m['error']}")
            emit({"chat": i, "sid": sid, "ready": bench.ms(t0, tr), "first": bench.ms(t0, tf),
                  "end": bench.ms(t0, max(te, tf))})
        except Exception as e:  # noqa: BLE001
            emit({"chat": i, "error": str(e)})

    ts = [threading.Thread(target=one, args=(i,)) for i in range(n)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    emit({"all": "idle"})
    sys.stdin.readline()
    cs = [threading.Thread(target=lambda sid=sid: req("session/close", {"sessionId": sid}, 60))
          for sid in sids if sid]
    for t in cs:
        t.start()
    for t in cs:
        t.join()
    emit({"closed": True})


def client_main(args):
    harness = args.side.split("+")[-1].replace("-raw", "")
    if args.side.startswith("acpmux"):
        client_acpmux(harness, args.n, args.scratch, args.sock)
    else:
        client_raw(harness, args.n, args.scratch)


# ---------------------------------------------------------------- the orchestrator


class Run:
    """One run: N chats on one side, through a client child process (and a daemon for acpmux)."""

    def __init__(self, args, side, n, env, scratch, idle_secs=None):
        self.side, self.n, self.tag = side, n, uuid.uuid4().hex
        self.dir = tempfile.mkdtemp(prefix=f"{side[:1]}{side[-5:-4]}{n}-", dir=scratch)
        self.env = dict(env, **{TAG_VAR: self.tag})
        self.daemon = None
        self.daemon_pid = None
        self.daemon_start_ms = None
        self.seen = set()
        sock = ""
        if side.startswith("acpmux"):
            home = os.path.join(self.dir, "acpmux-home")
            os.makedirs(home)
            os.chmod(home, 0o700)  # the daemon refuses a home another user could write
            extra = {} if idle_secs is None else {"ACPMUX_IDLE_CHILD_SECS": str(idle_secs)}
            t0 = time.perf_counter()
            self.daemon = bench.Daemon(args.acpmux, self.env, home, extra)
            self.daemon_start_ms = bench.ms(t0, time.perf_counter())
            self.daemon_pid = self.daemon.p.pid
            sock = self.daemon.sock_path
        self.client = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "client", "--side", side, "-n", str(n),
             "--scratch", self.dir, "--sock", sock],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=self.env, text=True)
        self.chats, self.errors = [], []
        while True:
            line = self.client.stdout.readline()
            if not line:
                raise RuntimeError(f"{side} n={n}: client ended early")
            m = json.loads(line)
            if "chat" in m:
                (self.errors if "error" in m else self.chats).append(m)
            if m.get("all"):
                break

    def roots(self):
        return [p for p in (self.client.pid, self.daemon_pid) if p]

    def procs(self, with_daemon=True):
        """Every process of this run but the bench's client: tagged, under a root, or seen before (an agent
        host reparented away from a killed daemon carries no tag and is under no root any more)."""
        c = census(self.tag, self.roots() + sorted(self.seen))
        self.seen |= set(c)
        c.pop(self.client.pid, None)
        if not with_daemon and self.daemon_pid:
            c.pop(self.daemon_pid, None)
        return c

    def split(self, c=None):
        """(session pids, pool spare pids) of `c`, the daemon in neither. A spare is an `__agent-host` that no
        session record (`hosts/<session>.json`) names, and what runs under it: acpmux's warm next chat."""
        c = self.procs() if c is None else c
        pids = set(c) - {self.daemon_pid}
        if not self.daemon:
            return pids, set()
        named = set()
        for f in os.listdir(os.path.join(self.daemon.home, "hosts")) if os.path.isdir(
                os.path.join(self.daemon.home, "hosts")) else []:
            try:
                rec = json.load(open(os.path.join(self.daemon.home, "hosts", f)))
                named |= {rec.get("host_pid"), rec.get("harness_pid")}
            except (OSError, ValueError):
                pass
        spare = set()
        for p in pids:
            try:
                cmd = open(f"/proc/{p}/cmdline", "rb").read()
            except OSError:
                continue
            if b"__agent-host" in cmd and p not in named:
                spare.add(p)
        grew = True
        while grew:
            grew = False
            for p in pids - spare:
                if c[p]["ppid"] in spare:
                    spare.add(p)
                    grew = True
        return pids - spare, spare

    def footprint(self):
        c = self.procs()
        rss = sum(r["rss_kb"] for r in c.values()) / 1024
        pss = sum(pss_kb(p) for p in c) / 1024
        comms = {}
        for r in c.values():
            comms[r["comm"]] = comms.get(r["comm"], 0) + 1
        _, spare = self.split(c)
        cmds = {}
        for p in c:
            try:
                cmds[p] = open(f"/proc/{p}/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace")[:120]
            except OSError:
                pass
        return {"procs": len(c), "procs_per_chat": round(len(c) / self.n, 2), "rss_mb": round(rss, 1),
                "rss_mb_per_chat": round(rss / self.n, 1), "pss_mb": round(pss, 1),
                "pss_mb_per_chat": round(pss / self.n, 1), "comms": comms,
                "spare_procs": len(spare), "spare_rss_mb": round(sum(c[p]["rss_kb"] for p in spare) / 1024, 1),
                "daemon_rss_mb": round(c[self.daemon_pid]["rss_kb"] / 1024, 1) if self.daemon_pid in c else None,
                "cmdlines": cmds}

    def idle_cpu(self, secs):
        a = self.procs()
        t0 = time.monotonic()
        time.sleep(secs)  # sleep-ok: the measured idle window
        b = self.procs()
        dt = time.monotonic() - t0
        ticks = sum(b[p]["cpu"] - a[p]["cpu"] for p in b if p in a)
        return round(ticks / CLK / dt * 100, 2)

    def wait_gone(self, t0, pids, cap=10.0):
        """ms from t0 until none of `pids` (the session's processes, taken just before) is alive (None if
        some are at `cap` s), how many are alive at `cap` s (orphans), and what they are."""
        gone = None
        while time.perf_counter() - t0 < cap:
            if not (set(self.procs()) & pids):
                gone = bench.ms(t0, time.perf_counter())
                break
            time.sleep(0.02)
        if gone is None:
            time.sleep(max(0.0, cap - (time.perf_counter() - t0)))
        c = self.procs()
        left = {p: c[p] for p in pids if p in c}
        comms = {}
        for r in left.values():
            comms[r["comm"]] = comms.get(r["comm"], 0) + 1
        _, spare = self.split(c)
        return {"ms": gone, "orphans": len(left), "left": comms, "spare_kept": len(spare),
                "daemon_alive": bool(self.daemon_pid and self.daemon_pid in c)}

    def close_normal(self):
        pids, _ = self.split()
        t0 = time.perf_counter()
        self.client.stdin.write("close\n")
        self.client.stdin.flush()
        return self.wait_gone(t0, pids)

    def kill_client(self):
        pids, _ = self.split()
        t0 = time.perf_counter()
        self.client.kill()
        self.client.wait()
        return self.wait_gone(t0, pids)

    def kill_daemon(self):
        """SIGKILL of the parent: the daemon. Every process of the run but the client counts, spares included."""
        pids = set(self.procs()) - {self.daemon_pid}
        t0 = time.perf_counter()
        os.kill(self.daemon_pid, signal.SIGKILL)
        self.daemon.p.wait()
        return self.wait_gone(t0, pids)

    def cleanup(self):
        try:
            self.client.kill()
            self.client.wait(5)
        except Exception:  # noqa: BLE001
            pass
        if self.daemon:
            try:
                self.daemon.close()
            except Exception:  # noqa: BLE001
                pass
        kill_all(self.tag, self.roots() + sorted(self.seen))


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def bench_side(args, side, env, scratch):
    out = {"by_n": {}}
    is_acp = side.startswith("acpmux")
    for n in args.ns:
        r = {"spawn_runs": [], "errors": [], "teardown": {}}
        plan = ["idle+normal", "sigkill-client"] + (["sigkill-daemon"] if is_acp else [])
        if n == 1:
            plan += ["normal"] * max(0, args.runs - len(plan))
        for kind in plan:
            log(f"{side} n={n} {kind}")
            try:
                run = Run(args, side, n, env, scratch)
            except Exception as e:  # noqa: BLE001
                r["errors"].append(f"{kind}: {e}")
                log(f"  error: {e}")
                continue
            try:
                r["errors"] += [f"{kind} chat {c['chat']}: {c['error']}" for c in run.errors]
                r["spawn_runs"].extend(run.chats)
                if run.daemon_start_ms is not None:
                    r.setdefault("daemon_start_ms", []).append(run.daemon_start_ms)
                if kind == "idle+normal":
                    time.sleep(2)  # sleep-ok: settle after the turns
                    r["footprint"] = run.footprint()
                    r["idle_cpu_pct"] = run.idle_cpu(args.idle_cpu_secs)
                    r["footprint_after_idle"] = run.footprint()
                if kind in ("idle+normal", "normal"):
                    r["teardown"].setdefault("normal", []).append(run.close_normal())
                elif kind == "sigkill-client":
                    r["teardown"]["sigkill_client"] = [run.kill_client()]
                elif kind == "sigkill-daemon":
                    r["teardown"]["sigkill_daemon"] = [run.kill_daemon()]
            except Exception as e:  # noqa: BLE001
                r["errors"].append(f"{kind}: {e}")
                log(f"  error: {e}")
            finally:
                run.cleanup()
        xs = r["spawn_runs"]
        r["spawn"] = {m: {"p50": pct([c[m] for c in xs], 0.5), "p95": pct([c[m] for c in xs], 0.95),
                          "n": len(xs)} for m in ("ready", "first", "end")}
        out["by_n"][str(n)] = r
        log(f"  {side} n={n}: spawn {r['spawn']['ready']} fp {r.get('footprint', {}).get('procs')}")
    if is_acp and args.hibernate_n:
        n = args.hibernate_n
        log(f"{side} hibernate n={n} idle={args.hibernate_secs}s")
        try:
            run = Run(args, side, n, env, scratch, idle_secs=args.hibernate_secs)
        except Exception as e:  # noqa: BLE001
            out["hibernate"] = {"error": str(e)}
            return out
        try:
            time.sleep(1)  # sleep-ok: settle
            before = run.footprint()
            t0 = time.perf_counter()
            series = []
            hib_ms = None
            base = len(run.procs())
            while time.perf_counter() - t0 < args.hibernate_secs + 60:
                time.sleep(1)  # sleep-ok: sampling the hibernation as it happens
                k = len(run.procs())
                series.append((round(time.perf_counter() - t0), k))
                if hib_ms is None and k < base and k <= base - n:
                    hib_ms = bench.ms(t0, time.perf_counter())
                if hib_ms is not None and time.perf_counter() - t0 > hib_ms / 1000 + 5:
                    break
            after = run.footprint()
            log_path = os.path.join(run.daemon.home, "daemon.log")
            lines = [l for l in open(log_path, errors="replace").read().splitlines()
                     if any(k in l for k in ("hibernated", "idle harness stays up"))][-10:]
            out["hibernate"] = {"n": n, "idle_secs": args.hibernate_secs, "before": before, "after": after,
                                "hibernated_after_ms": hib_ms, "series": series, "log": lines}
        finally:
            run.cleanup()
    return out


def fmt(v, unit=""):
    return "n/a" if v is None else f"{v}{unit}"


def render_md(res, args):
    sides = [s for s in SIDES if s in res]
    rows = []

    def get(side, n, *path):
        v = res[side]["by_n"].get(str(n), {})
        for p in path:
            if v is None:
                return None
            v = v.get(p) if isinstance(v, dict) else (v[p] if isinstance(v, list) and len(v) > p else None)
        return v

    def td(side, n, key):
        xs = get(side, n, "teardown", key)
        if not xs:
            return "not run" if key != "sigkill_daemon" or side.startswith("acpmux") else "n/a (no daemon)"
        mss = [x["ms"] for x in xs]
        orph = max(x["orphans"] for x in xs)
        msv = pct(mss, 0.5) if all(m is not None for m in mss) else None
        left = {}
        for x in xs:
            for k, v in x["left"].items():
                left[k] = max(left.get(k, 0), v)
        s = f"{msv} ms" if msv is not None else ">10 s"
        s += f", {orph} left at 10 s"
        if left:
            s += " (" + ", ".join(f"{k}x{v}" for k, v in sorted(left.items())) + ")"
        spare = max(x.get("spare_kept", 0) for x in xs)
        if spare and key != "sigkill_daemon":
            s += f"; +{spare} pool-spare procs kept"
        return s

    for n in args.ns:
        rows.append((f"**N={n}**", [""] * len(sides)))
        sp = "p50/p95, %d runs" % args.runs if n == 1 else "p50/p95 over %d chats" % n
        rows.append((f"spawn to ready ms ({sp})",
                     [f"{fmt(get(s, n, 'spawn', 'ready', 'p50'))} / {fmt(get(s, n, 'spawn', 'ready', 'p95'))}" for s in sides]))
        rows.append((f"spawn to first token ms ({sp})",
                     [f"{fmt(get(s, n, 'spawn', 'first', 'p50'))} / {fmt(get(s, n, 'spawn', 'first', 'p95'))}" for s in sides]))
        rows.append(("processes total (per chat)",
                     [f"{fmt(get(s, n, 'footprint', 'procs'))} ({fmt(get(s, n, 'footprint', 'procs_per_chat'))})" for s in sides]))
        rows.append(("of which acpmux pool spare (procs / RSS MB)",
                     [f"{get(s, n, 'footprint', 'spare_procs')} / {get(s, n, 'footprint', 'spare_rss_mb')}"
                      if s.startswith("acpmux") and get(s, n, 'footprint') else "n/a" for s in sides]))
        rows.append(("RSS MB total (per chat)",
                     [f"{fmt(get(s, n, 'footprint', 'rss_mb'))} ({fmt(get(s, n, 'footprint', 'rss_mb_per_chat'))})" for s in sides]))
        rows.append(("PSS MB total (per chat)",
                     [f"{fmt(get(s, n, 'footprint', 'pss_mb'))} ({fmt(get(s, n, 'footprint', 'pss_mb_per_chat'))})" for s in sides]))
        rows.append((f"idle CPU % of one core over {args.idle_cpu_secs} s",
                     [fmt(get(s, n, 'idle_cpu_pct')) for s in sides]))
        rows.append(("teardown, normal close", [td(s, n, "normal") for s in sides]))
        rows.append(("teardown, SIGKILL client", [td(s, n, "sigkill_client") for s in sides]))
        rows.append(("teardown, SIGKILL acpmux daemon", [td(s, n, "sigkill_daemon") for s in sides]))
        errs = [len(get(s, n, "errors") or []) for s in sides]
        if any(errs):
            rows.append(("errors (see json)", [str(e) for e in errs]))
    hib = []
    for s in sides:
        h = res[s].get("hibernate")
        if not h:
            hib.append("n/a (no hibernation: the harness lives as long as its client)")
        elif "error" in h:
            hib.append(f"error: {h['error'][:80]}")
        else:
            hib.append(f"{h['before']['procs']} procs / {h['before']['rss_mb']} MB -> {h['after']['procs']} procs / "
                       f"{h['after']['rss_mb']} MB after {fmt(h['hibernated_after_ms'], ' ms') if h['hibernated_after_ms'] else 'no hibernation in window'}")
    hn = args.hibernate_n
    rows.append((f"**after idle hibernation (N={hn}, ACPMUX_IDLE_CHILD_SECS={args.hibernate_secs})**", hib))
    ds = [pct(get(s, args.ns[0], "daemon_start_ms") or [], 0.5) if s.startswith("acpmux") else None for s in sides]
    rows.append(("acpmux daemon cold start ms (p50, not in spawn)", [fmt(d) if s.startswith("acpmux") else "n/a" for s, d in zip(sides, ds)]))
    meta = res["_meta"]
    out = [f"# Process lifecycle: raw harness vs acpmux ({meta['host']}, {meta['started']})", "",
           f"Pinned to CPUs {meta['affinity']}; host load {meta['load_start']} at start, {meta['load_end']} at end "
           f"(16 cores, other benches running: p50 is the number to read, p95 is noisy). "
           f"acpmux {meta['versions']['acpmux']}, claude {meta['versions']['claude']}, codex {meta['versions']['codex']}. "
           "Stand-in model answers at once (no network). Processes and RSS include the acpmux daemon and agent hosts, "
           "amortized per chat; the bench's own client is not counted. RSS double-counts shared pages; PSS does not.", "",
           "| metric | " + " | ".join(sides) + " |", "|---|" + "---|" * len(sides)]
    for name, cells in rows:
        out.append(f"| {name} | " + " | ".join(cells) + " |")
    return "\n".join(out) + "\n"


def version(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout.strip().splitlines()[0]
    except Exception as e:  # noqa: BLE001
        return f"? ({e})"


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "client":
        ap = argparse.ArgumentParser()
        ap.add_argument("client")
        ap.add_argument("--side")
        ap.add_argument("-n", type=int)
        ap.add_argument("--scratch")
        ap.add_argument("--sock")
        return client_main(ap.parse_args())
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--acpmux", default=os.path.expanduser("~/.local/bin/acpmux"))
    ap.add_argument("--sides", default=",".join(SIDES))
    ap.add_argument("--ns", default="1,5,20")
    ap.add_argument("--runs", type=int, default=5, help="runs at N=1 (spawn percentiles)")
    ap.add_argument("--idle-cpu-secs", type=int, default=30)
    ap.add_argument("--hibernate-n", type=int, default=5)
    ap.add_argument("--hibernate-secs", type=int, default=20)
    ap.add_argument("--out", default=os.path.join(ROOT, ".build", "acpmux-vs-harness"))
    args = ap.parse_args()
    args.ns = [int(x) for x in args.ns.split(",")]
    os.makedirs(args.out, exist_ok=True)
    stand = bench.StandIn()
    threading.Thread(target=stand.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{stand.server_address[1]}"
    # Short: the daemon socket path must fit sun_path (108 bytes); $TMPDIR here can be long.
    scratch = tempfile.mkdtemp(prefix="lc-", dir="/tmp")
    env = bench.env_for(url, scratch)
    res = {"_meta": {"host": socket.gethostname(), "started": time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime()),
                     "affinity": sorted(os.sched_getaffinity(0)), "load_start": round(os.getloadavg()[0], 1),
                     "versions": {"acpmux": version([args.acpmux, "--version"]),
                                  "claude": version(["claude", "--version"]),
                                  "codex": version(["codex", "--version"])}}}
    json_path = os.path.join(args.out, "lifecycle.json")
    try:
        for side in args.sides.split(","):
            res[side] = bench_side(args, side, env, scratch)
            with open(json_path, "w") as f:
                json.dump(res, f, indent=1)
    finally:
        res["_meta"]["load_end"] = round(os.getloadavg()[0], 1)
        res["_meta"]["stand_in_hits"] = stand.hits
        with open(json_path, "w") as f:
            json.dump(res, f, indent=1)
        md = render_md(res, args)
        with open(os.path.join(args.out, "lifecycle.md"), "w") as f:
            f.write(md)
        print(md)
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    main()
