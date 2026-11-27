#!/usr/bin/env python3
"""The 11-27 daemon wedge on Leo's Mac, reproduced: an acpmux daemon with ~200 peer links under CPU load, and
what a chat's inbox read costs while it lasts.

Why (2026-11-27 15:37Z, his Mac): load 187 on 15 CPUs, the daemon at 143% CPU, 2.1 GB, 143 tokio
workers and ~200 peers; `acpmux session inbox <id>` hung 60 s+; "prompt admission lease lapsed"
388x, "std mutex held long" on `remote_sessions` 1646x, ~6k peer disconnects. Leo: "mango has been
"thinking" for an inordinate amount of time. i think they're bugged and we need to fix this bug".

This harness takes the daemon binary as an argument, so the same run gives the before (a base
build) and the after (each fix branch's build):

    python3 -I scripts/cmux-next/acpmux_wedge_duress.py --acpmux target/debug/acpmux --out /tmp/wedge
    python3 -I scripts/cmux-next/acpmux_wedge_duress.py --acpmux A --out /tmp/a && \\
    python3 -I scripts/cmux-next/acpmux_wedge_duress.py --acpmux B --out /tmp/b && \\
    python3 -I scripts/cmux-next/acpmux_wedge_duress.py --compare /tmp/a /tmp/b

What runs (every process in its own process group, stopped by group at the end; no host daemon,
home or socket is touched: a private HOME, ACPMUX_HOME and socket, as acpmux_disconnect_stress.py):

- the daemon under test, with `--peers` (default 200) peers in its config.json. They are served by
  `--peer-daemons` (default 10) real acpmux daemons, each seeded with `--peer-rows` (default 20)
  sessions on disk, behind one loopback TCP proxy port per peer, so the daemon holds 200 links and
  200 x 20 remote rows (`remote_sessions`) as Leo's did;
- churn through the proxies: every `--flap` seconds one random link is cut (a peer disconnect), and
  `--stall-frac` of the ports accept and then forward nothing (the silence budget runs out, the link
  drops, it redials: the punch/redial churn Leo's log showed);
- `--sessions` (default 8) local chats on the stand-in agent (tests/fake_agent.py) and the mesh
  relay pointed at the fake hub of acpmux_disconnect_stress.py, which leases agent messages to
  them at `--hub-rate` a second: deliveries and inbox items;
- the load: `--cpu-x` (default 12, Leo's 187/15) x cores busy loops, during the `duress` phase only.

Phases: `idle` (no load, no churn), `duress` (load and churn, `--secs`), `recovered` (both lifted).
Each phase reads `acpmux --json session inbox <id>` and `acpmux session inbox <name>` (the name is
resolved fleet-wide first, as an agent types it) `--reads` times each, one at a time, each bounded at
`--read-timeout`. In `duress`, while one read runs, the daemon's threads are sampled (`sample` on
macOS; `gdb`/`eu-stack` on Linux when present, else each thread's wchan) into `stacks-N.txt`, and the
top waiting frames are tallied.

Measured per phase: inbox read p50/p95/max and timeouts; the daemon's CPU % (ps), threads and RSS;
and from its log, per minute: "prompt admission lease lapsed", "std mutex held long", peer link
drops, punch attempts and silence-budget ends. One line `WEDGE-SUMMARY {...}`, `result.json` and
`summary.md` go to `--out`.

Refuses to run outside CI (`$FAST_CHECKS_OUT` unset) unless `ACPMUX_WEDGE_HERE=1`: it loads the
host it runs on, so never a person's machine.

Exit: 0 it ran (numbers only, no gate); 4 the harness could not run.
"""

from __future__ import annotations

import argparse
import json
import os
import random
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
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import acpmux_disconnect_stress as ds  # noqa: E402  (FakeHub, make_handler, clean_env, WRAPPER)

LOG_COUNTERS = {
    "leaseLapsed": re.compile(r"prompt admission lease lapsed"),
    # hub/held_lock.rs: "a std mutex was held long on a runtime worker lock=WHAT at=FILE:LINE held_ms=N"
    "mutexHeldLong": re.compile(r"std mutex (?:was )?held long"),
    "remoteSessionsHeldLong": re.compile(r"std mutex (?:was )?held long.*remote_sessions|remote_sessions.*std mutex (?:was )?held long"),
    "peerDrops": re.compile(r"peer disconnected|peer stopped answering|peer link (?:dropped|closed|lost)|disconnected from peer|link down", re.I),
    "punch": re.compile(r"punch", re.I),
    "silenceBudget": re.compile(r"silence budget", re.I),
    "slowRequest": re.compile(r"slow request|request took|stalled", re.I),
}


def log(*x) -> None:
    print(f"[{time.strftime('%H:%M:%S')}]", *x, flush=True)


def pct(xs: list[float], p: float) -> float | None:
    if not xs:
        return None
    s = sorted(xs)
    return round(s[min(len(s) - 1, int(round(p / 100 * (len(s) - 1))))], 1)


# Peer daemons and the proxy in front of them -----------------------------------------------------

def private(path: Path, text: str | None = None) -> None:
    if text is None:
        path.mkdir(parents=True, exist_ok=True)
        os.chmod(path, 0o700)
    else:
        path.write_text(text)
        os.chmod(path, 0o600)


def seed_rows(home: Path, rows: int, tag: int) -> None:
    """Sessions on disk a peer daemon lists (shaped as tests/daemon_memory.rs `write_peer_session`)."""
    private(home / "sessions")
    at = 1_791_000_000_000
    for i in range(rows):
        sid = f"01a15910-0000-7000-8{tag:03d}-{i:012d}"
        d = home / "sessions" / sid
        private(d)
        meta = {"schema": "acpmux.session.v1", "id": sid, "name": f"peer{tag}-chat-{i}", "harness": "claude",
                "harnessArgv": ["claude"], "cwd": "/tmp", "agentSessionId": f"agent-{sid}",
                "status": "idle" if i % 3 else "closed", "createdAt": at, "updatedAt": at + 5000,
                "lastSeq": 2, "eventCount": 2, "turnCount": 1, "title": f"Peer {tag} chat {i}",
                "lastPrompt": "x" * 200, "preview": "y" * 600}
        private(d / "session.json", json.dumps(meta))
        private(d / "events")
        ev = [{"seq": 1, "at": at, "dir": "mux", "kind": "created", "msg": {"harness": "claude"}},
              {"seq": 2, "at": at + 1, "dir": "in", "kind": "agent_message_chunk",
               "msg": {"method": "session/update", "params": {"sessionId": sid, "update": {
                   "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hello"}}}}}]
        private(d / "events" / "000001.ndjson", "".join(json.dumps(e) + "\n" for e in ev))


class Proxy:
    """One loopback port per peer, forwarding to a peer daemon's listener; cut and stall on demand."""

    def __init__(self, target: tuple[str, int], stalled: bool):
        self.target = target
        self.stalled = stalled
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(64)
        self.port = self.sock.getsockname()[1]
        self.conns: list[socket.socket] = []
        self.lock = threading.Lock()
        self.accepted = 0
        self.cuts = 0
        self.closed = False
        threading.Thread(target=self.accept_loop, daemon=True).start()

    def accept_loop(self) -> None:
        while not self.closed:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            self.accepted += 1
            with self.lock:
                self.conns.append(c)
            if self.stalled:
                continue  # accept, then nothing: the daemon's silence budget ends it
            try:
                u = socket.create_connection(self.target, timeout=5)
            except OSError:
                c.close()
                continue
            with self.lock:
                self.conns.append(u)
            for a, b in ((c, u), (u, c)):
                threading.Thread(target=self.pump, args=(a, b), daemon=True).start()

    def pump(self, a: socket.socket, b: socket.socket) -> None:
        try:
            while True:
                data = a.recv(65536)
                if not data:
                    break
                b.sendall(data)
        except OSError:
            pass
        for s in (a, b):
            try:
                s.close()
            except OSError:
                pass

    def cut(self) -> None:
        with self.lock:
            conns, self.conns = self.conns, []
        self.cuts += 1
        for s in conns:
            try:
                s.shutdown(socket.SHUT_RDWR)
                s.close()
            except OSError:
                pass

    def close(self) -> None:
        self.closed = True
        self.cut()
        self.sock.close()


# The daemon's own numbers --------------------------------------------------------------------------

def ps_row(pid: int) -> dict:
    """CPU %, RSS (KB) and threads of PID, from ps (macOS and Linux)."""
    out: dict = {}
    r = subprocess.run(["ps", "-o", "%cpu=,rss=", "-p", str(pid)], capture_output=True, text=True)
    parts = r.stdout.split()
    if len(parts) >= 2:
        out["cpuPct"] = float(parts[0])
        out["rssMB"] = round(int(parts[1]) / 1024, 1)
    if sys.platform == "darwin":
        r = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True)
        out["threads"] = max(0, len(r.stdout.splitlines()) - 1)
    else:
        try:
            out["threads"] = len(os.listdir(f"/proc/{pid}/task"))
        except OSError:
            pass
    return out


def cpu_seconds(pid: int) -> float | None:
    """The daemon's user+system CPU seconds: /proc (Linux, clock ticks) or ps (whole seconds)."""
    try:
        f = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return (int(f[11]) + int(f[12])) / os.sysconf("SC_CLK_TCK")
    except (OSError, IndexError, ValueError):
        pass
    r = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True)
    t = r.stdout.strip()
    if not t:
        return None
    days = 0
    if "-" in t:
        d, t = t.split("-", 1)
        days = int(d)
    secs = 0.0
    for part in t.split(":"):
        secs = secs * 60 + float(part)
    return days * 86400 + secs


def sample_stacks(pid: int, out: Path) -> str:
    """The daemon's threads, now: `sample` (macOS), gdb or eu-stack (Linux), else wchan per thread."""
    if sys.platform == "darwin" and shutil.which("sample"):
        subprocess.run(["sample", str(pid), "3", "-mayDie", "-file", str(out)], capture_output=True, timeout=60)
        return "sample"
    if shutil.which("gdb"):
        r = subprocess.run(["gdb", "-batch", "-p", str(pid), "-ex", "thread apply all bt 40"],
                           capture_output=True, text=True, timeout=120)
        out.write_text(r.stdout + r.stderr)
        return "gdb"
    if shutil.which("eu-stack"):
        r = subprocess.run(["eu-stack", "-p", str(pid)], capture_output=True, text=True, timeout=120)
        out.write_text(r.stdout + r.stderr)
        return "eu-stack"
    rows = []
    for tid in sorted(os.listdir(f"/proc/{pid}/task")) if Path(f"/proc/{pid}/task").exists() else []:
        try:
            name = Path(f"/proc/{pid}/task/{tid}/comm").read_text().strip()
            wchan = Path(f"/proc/{pid}/task/{tid}/wchan").read_text().strip()
        except OSError:
            continue
        rows.append(f"{tid} {name} {wchan}")
    out.write_text("\n".join(rows) + "\n")
    return "wchan"


FRAME = re.compile(r"((?:acpmux|tokio|std|parking_lot|cmux_[a-z_]+)::[A-Za-z0-9_:<>{}\[\] ,&'*]+)")
WAIT = re.compile(r"futex|__psynch_mutexwait|__psynch_cvwait|_pthread_mutex|Mutex.*lock|RwLock.*(?:read|write)"
                  r"|lock_contended|parking_lot::raw_|semaphore_wait|kevent|epoll_wait", re.I)


def tally_stacks(files: list[Path], top: int = 12) -> list[dict]:
    """Each sampled thread's first acpmux frame above a wait (lock, futex, condvar), counted."""
    counts: dict[str, int] = {}
    for f in files:
        text = f.read_text(errors="replace")
        # gdb: "Thread N (...)" blocks; sample: indented call graph per "Thread_" block; wchan: lines.
        blocks = re.split(r"\n(?=Thread \d|\s*\d+ Thread_)", text)
        for b in blocks:
            if not WAIT.search(b):
                continue
            frames = [m.group(1) for m in FRAME.finditer(b) if m.group(1).startswith("acpmux::")]
            key = frames[0].strip()[:160] if frames else (WAIT.search(b).group(0) + " (no acpmux frame)")
            counts[key] = counts.get(key, 0) + 1
    return [{"frame": k, "threads": v} for k, v in sorted(counts.items(), key=lambda kv: -kv[1])[:top]]


ANSI = re.compile(r"\x1b\[[0-9;]*m")
HELD_SITE = re.compile(r"std mutex (?:was )?held long.*?lock=(\S+).*?at=(\S+).*?held_ms=(\d+)")
LAPSE_STAGE = re.compile(r"prompt admission lease lapsed.*?stage=\"?([A-Za-z_-]+)")


def count_log(path: Path, start: int, end: int) -> dict:
    with path.open("rb") as f:
        f.seek(start)
        text = ANSI.sub("", f.read(max(0, end - start)).decode(errors="replace"))
    out: dict = {k: len(rx.findall(text)) for k, rx in LOG_COUNTERS.items()}
    sites: dict = {}
    for lock, at, ms in HELD_SITE.findall(text):
        s = sites.setdefault(f"{lock} @ {at}", {"n": 0, "maxMs": 0})
        s["n"] += 1
        s["maxMs"] = max(s["maxMs"], int(ms))
    out["heldSites"] = dict(sorted(sites.items(), key=lambda kv: -kv[1]["n"])[:8])
    stages: dict = {}
    for st in LAPSE_STAGE.findall(text):
        stages[st] = stages.get(st, 0) + 1
    out["lapseStages"] = stages
    return out


# The run ---------------------------------------------------------------------------------------

class Wedge:
    def __init__(self, a: argparse.Namespace, out: Path):
        self.a = a
        self.out = out
        self.acpmux = str(Path(a.acpmux).resolve())
        self.peer_acpmux = str(Path(a.peer_acpmux or a.acpmux).resolve())
        self.state = Path(tempfile.mkdtemp(prefix="acpmux-wedge-"))
        self.env = ds.clean_env(out, self.state, self.acpmux)
        if not a.lazy_peers:
            # Saved peers wait to be used before they dial (peer_demand.rs); Leo's daemon had its
            # ~200 links up (chats in use, deliveries, wants). Dial them all, as that state.
            self.env["ACPMUX_PEER_DIAL_AT_START"] = "1"
        self.procs: list[subprocess.Popen] = []
        self.proxies: list[Proxy] = []
        self.hub = ds.FakeHub(out / "hub.ndjson", random.Random(a.seed + 1))
        self.rng = random.Random(a.seed)
        self.stop = threading.Event()
        self.churn_on = threading.Event()
        self.burners: list[subprocess.Popen] = []
        self.daemon: subprocess.Popen | None = None
        self.daemon_log = out / "daemon.log"
        self.sessions: list[tuple[str, str]] = []  # (name, id)

    def spawn(self, argv: list[str], env: dict, log_to: Path, **kw) -> subprocess.Popen:
        p = subprocess.Popen(argv, env=env, stdout=log_to.open("w"), stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL, start_new_session=True, **kw)
        self.procs.append(p)
        return p

    def run(self, argv: list[str], timeout: float = 60) -> subprocess.CompletedProcess:
        return subprocess.run(argv, env=self.env, capture_output=True, text=True, timeout=timeout,
                              stdin=subprocess.DEVNULL)

    def start_peer_daemon(self, i: int) -> tuple[int, str, str] | None:
        st = self.state / f"peer-{i}"
        home = st / "acpmux-home"
        private(st)
        for d in ("home", "run", "tmp"):
            private(st / d)
        private(home)
        private(home / "run")
        seed_rows(home, self.a.peer_rows, i)
        env = dict(self.env, HOME=str(st / "home"), ACPMUX_HOME=str(home), TMPDIR=str(st / "tmp"),
                   XDG_RUNTIME_DIR=str(st / "run"), ACPMUX_SOCKET=str(st / "run" / "acpmux.sock"),
                   ACPMUX_AGENT_LAUNCH="deny")
        p = subprocess.Popen([self.peer_acpmux, "daemon", "run", "--ready-fd", "1", "--listen", "127.0.0.1:0",
                              "--log", "warn"], env=env, stdout=subprocess.PIPE,
                             stderr=(self.out / f"peer-{i}.log").open("w"), stdin=subprocess.DEVNULL,
                             start_new_session=True, text=True)
        self.procs.append(p)
        deadline = time.time() + 60
        while time.time() < deadline:
            line = p.stdout.readline()
            if not line:
                break
            try:
                v = json.loads(line)
            except ValueError:
                continue
            if v.get("ready") is True and v.get("listen"):
                host, port = v["listen"].rsplit(":", 1)
                token = json.loads((home / "config.json").read_text())["websocket"]["token"]
                peer_token = (home / "run" / "peer.token").read_text().strip()
                return int(port), token, peer_token
        log(f"peer daemon {i} gave no ready line; see peer-{i}.log")
        return None

    def start_daemon(self) -> bool:
        r, w = os.pipe()
        self.daemon = subprocess.Popen([self.acpmux, "daemon", "run", "--take-over", "--ready-fd", str(w),
                                        "--log", self.a.log], env=self.env,
                                       stdout=self.daemon_log.open("w"), stderr=subprocess.STDOUT,
                                       stdin=subprocess.DEVNULL, pass_fds=(w,), start_new_session=True)
        os.close(w)
        self.procs.append(self.daemon)
        got = {"line": ""}

        def read():
            with os.fdopen(r) as f:
                got["line"] = f.readline()

        t = threading.Thread(target=read, daemon=True)
        t.start()
        t.join(120)
        return bool(got["line"].strip())

    def new_session(self, k: int) -> tuple[str, str] | None:
        name = f"recv-{k}"
        self.spawn([self.acpmux, "new", "-n", name, "-m", "fake", "--policy", "approve-all", "-d",
                    "--cwd", str(self.state / "work"), "hello"], self.env, self.out / f"new-{name}.log")
        for _ in range(120):
            r = self.run([self.acpmux, "--json", "session", "info", name], 20)
            if r.returncode == 0 and r.stdout.strip():
                try:
                    v = json.loads(r.stdout)
                    sid = v.get("id") or v.get("sessionId") or (v.get("session") or {}).get("id")
                except ValueError:
                    sid = None
                if sid:
                    return name, sid
            time.sleep(0.5)
        return None

    # load ---------------------------------------------------------------------------------------

    def hub_sender(self) -> None:
        gap = 1.0 / max(0.01, self.a.hub_rate)
        n = 0
        while not self.stop.wait(gap):
            n += 1
            name, _ = self.sessions[self.rng.randrange(len(self.sessions))]
            sender = f"sender-{self.rng.randrange(40)}"
            self.hub.enqueue({"messageId": f"hub-{n}", "kind": "prompt", "mode": "turn-end", "to": {"name": name},
                              "from": {"name": sender, "host": f"remote-{sender}", "daemonId": f"inst_{sender}",
                                       "sessionId": str(uuid.uuid5(uuid.NAMESPACE_DNS, sender))},
                              "body": f"HUB-{n} from {sender}: status update for {name}", "attempt": 1})

    def churner(self) -> None:
        while not self.stop.is_set():
            if self.churn_on.wait(0.5) and not self.stop.is_set():
                self.rng.choice(self.proxies).cut()
                self.stop.wait(self.a.flap)

    def reaper(self) -> None:
        while not self.stop.wait(0.5):
            self.hub.reap()

    def burn(self, on: bool) -> None:
        if on:
            n = (os.cpu_count() or 4) * self.a.cpu_x
            cap = str(int(self.a.secs) + 120)
            killer = ["timeout", "-s", "KILL", cap] if shutil.which("timeout") else []
            for _ in range(n):
                self.burners.append(subprocess.Popen(
                    [*killer, sys.executable, "-c", "while True: pass"], start_new_session=True,
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            log(f"load: {n} busy loops ({self.a.cpu_x} x {os.cpu_count()} cores)")
        else:
            for p in self.burners:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except OSError:
                    pass
            for p in self.burners:
                p.wait()
            self.burners = []

    # measure --------------------------------------------------------------------------------------

    def read_inbox(self, target: str) -> dict:
        t = time.monotonic()
        try:
            r = self.run([self.acpmux, "--json", "session", "inbox", target], self.a.read_timeout)
            ms = (time.monotonic() - t) * 1000
            return {"ms": round(ms, 1), "ok": r.returncode == 0,
                    "err": None if r.returncode == 0 else (r.stderr.strip()[-200:] or f"exit {r.returncode}")}
        except subprocess.TimeoutExpired:
            return {"ms": self.a.read_timeout * 1000.0, "ok": False, "err": "timeout"}

    def phase(self, name: str, secs: float) -> dict:
        pid = self.daemon.pid
        log_start = self.daemon_log.stat().st_size
        cpu0, t0 = cpu_seconds(pid), time.monotonic()
        ps_rows: list[dict] = []
        reads: dict[str, list[dict]] = {"byId": [], "byName": []}
        stack_files: list[Path] = []
        tool = None
        deadline = time.monotonic() + secs
        gap = secs / max(1, self.a.reads)  # reads spread over the phase, not bunched at its start
        i = 0
        while i < self.a.reads or time.monotonic() < deadline:
            t_read = time.monotonic()
            name_, sid = self.sessions[i % len(self.sessions)]
            sampler = None
            if name == "duress" and len(stack_files) < self.a.samples and i % 3 == 1:
                f = self.out / f"stacks-{len(stack_files)}.txt"
                stack_files.append(f)
                box: dict = {}
                sampler = threading.Thread(target=lambda f=f, box=box: box.update(tool=sample_stacks(pid, f)))
                sampler.start()
            reads["byId"].append(self.read_inbox(sid))
            reads["byName"].append(self.read_inbox(name_))
            if sampler:
                sampler.join()
                tool = box.get("tool")
            ps_rows.append(ps_row(pid))
            i += 1
            if i >= self.a.reads and time.monotonic() >= deadline:
                break
            if i >= self.a.reads * 4:
                break
            rest = gap - (time.monotonic() - t_read)
            if rest > 0 and time.monotonic() + rest < deadline:
                time.sleep(rest)
        dt = time.monotonic() - t0
        cpu1 = cpu_seconds(pid)
        logc = count_log(self.daemon_log, log_start, self.daemon_log.stat().st_size)
        mins = max(dt / 60, 1e-6)
        row = {"phase": name, "secs": round(dt, 1), "reads": i,
               "daemonCpuPct": round(100 * (cpu1 - cpu0) / dt, 1) if cpu0 is not None and cpu1 is not None else None,
               "threadsMax": max((r.get("threads", 0) for r in ps_rows), default=None),
               "rssMBMax": max((r.get("rssMB", 0) for r in ps_rows), default=None),
               "log": logc, "logPerMin": {k: round(v / mins, 1) for k, v in logc.items() if isinstance(v, int)},
               "linksUp": self.links_up(),
               "proxyAccepts": sum(p.accepted for p in self.proxies), "proxyCuts": sum(p.cuts for p in self.proxies),
               "hub": dict(self.hub.counts)}
        for k, rs in reads.items():
            ms = [r["ms"] for r in rs]
            row[k] = {"p50": pct(ms, 50), "p95": pct(ms, 95), "max": max(ms) if ms else None, "n": len(ms),
                      "timeouts": sum(1 for r in rs if r["err"] == "timeout"),
                      "errors": sum(1 for r in rs if not r["ok"] and r["err"] != "timeout"),
                      "firstError": next((r["err"] for r in rs if not r["ok"]), None)}
        if stack_files:
            row["stackTool"] = tool
            row["topWaits"] = tally_stacks([f for f in stack_files if f.exists()])
        log(f"phase {name}: inbox byId p50/p95/max {row['byId']['p50']}/{row['byId']['p95']}/{row['byId']['max']} ms, "
            f"byName {row['byName']['p50']}/{row['byName']['p95']}/{row['byName']['max']} ms, "
            f"cpu {row['daemonCpuPct']}%, log/min {row['logPerMin']}")
        return row

    def links_up(self) -> dict:
        """Peer link states as the daemon reports them (`acpmux --json machine ls`), counted."""
        try:
            r = self.run([self.acpmux, "--json", "machine", "ls"], 30)
            v = json.loads(r.stdout)
        except (subprocess.TimeoutExpired, ValueError):
            return {"error": "peers did not answer"}
        rows = v if isinstance(v, list) else v.get("peers", [])
        counts: dict = {}
        for p in rows:
            st = str(p.get("state") or p.get("connection") or p.get("status") or p.get("link") or "?")
            counts[st] = counts.get(st, 0) + 1
        return counts

    def go(self) -> int:
        a = self.a
        srv = ds.http.server.ThreadingHTTPServer(("127.0.0.1", 0), ds.make_handler(self.hub))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        port = srv.server_address[1]
        targets = []
        for i in range(a.peer_daemons):
            t = self.start_peer_daemon(i)
            if t is None:
                return 4
            targets.append(t)
        peers = {}
        n_stall = int(round(a.peers * a.stall_frac))
        for j in range(a.peers):
            tport, token, peer_token = targets[j % len(targets)]
            px = Proxy(("127.0.0.1", tport), stalled=j < n_stall)
            self.proxies.append(px)
            peers[f"p{j:03d}"] = {"url": f"ws://127.0.0.1:{px.port}", "token": token, "peerToken": peer_token}
        cfg = {
            "harnesses": {"fake": {"argv": ["python3", str(self.out / "agent-wrapper.py")], "family": "codex"}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all",
            "meshRelay": {"url": f"http://127.0.0.1:{port}", "tokenCommand": [shutil.which("echo") or "/bin/echo", "t"]},
            "peers": peers,
        }
        (self.out / "agent-wrapper.py").write_text(ds.WRAPPER)
        private(self.state / "acpmux-home" / "config.json", json.dumps(cfg, indent=1))
        version = self.run([self.acpmux, "--version"]).stdout.strip()
        log("acpmux", version, f"{a.peers} peers ({n_stall} stalled) over {a.peer_daemons} peer daemons")
        if not self.start_daemon():
            log("daemon did not report ready; see daemon.log")
            return 4
        for k in range(a.sessions):
            s = self.new_session(k)
            if s is None:
                log(f"session recv-{k} did not start; see new-recv-{k}.log")
                return 4
            self.sessions.append(s)
        for f in (self.hub_sender, self.churner, self.reaper):
            threading.Thread(target=f, daemon=True).start()
        self.stop.wait(a.settle)
        res = {"schema": "acpmux.wedge-duress.v1", "acpmux": self.acpmux, "version": version,
               "host": socket.gethostname(), "platform": sys.platform, "cores": os.cpu_count(),
               "args": vars(a), "phases": []}
        res["phases"].append(self.phase("idle", a.idle_secs))
        self.churn_on.set()
        self.burn(True)
        try:
            res["phases"].append(self.phase("duress", a.secs))
        finally:
            self.burn(False)
            self.churn_on.clear()
        res["phases"].append(self.phase("recovered", a.idle_secs))
        (self.out / "result.json").write_text(json.dumps(res, indent=1))
        (self.out / "summary.md").write_text(summary_md(res))
        print("WEDGE-SUMMARY " + json.dumps(brief(res)), flush=True)
        return 0

    def cleanup(self) -> None:
        self.stop.set()
        self.burn(False)
        for px in self.proxies:
            px.close()
        for p in reversed(self.procs):
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except OSError:
                pass
        time.sleep(1)
        for p in self.procs:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        for i in range(self.a.peer_daemons):
            pl = self.state / f"peer-{i}" / "acpmux-home" / "daemon.log"
            if pl.exists():
                shutil.copy(pl, self.out / f"peer-{i}-home-daemon.log")
        shutil.rmtree(self.state, ignore_errors=True)


def brief(res: dict) -> dict:
    out = {"version": res.get("version"), "host": res.get("host")}
    for ph in res["phases"]:
        out[ph["phase"]] = {"inboxIdP95": ph["byId"]["p95"], "inboxIdMax": ph["byId"]["max"],
                            "inboxNameP95": ph["byName"]["p95"], "inboxNameMax": ph["byName"]["max"],
                            "timeouts": ph["byId"]["timeouts"] + ph["byName"]["timeouts"],
                            "cpuPct": ph["daemonCpuPct"], "threads": ph["threadsMax"],
                            **{f"{k}PerMin": v for k, v in ph["logPerMin"].items()}}
    return out


def summary_md(res: dict) -> str:
    lines = [f"# acpmux wedge duress: {res.get('version')} on {res.get('host')} ({res.get('cores')} cores)", "",
             "| phase | inbox id p50/p95/max ms | inbox name p50/p95/max ms | timeouts | daemon CPU % | threads | RSS MB |"
             " lease lapsed/min | mutex held long/min | peer drops/min | punch/min | silence/min |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for ph in res["phases"]:
        i, n, m = ph["byId"], ph["byName"], ph["logPerMin"]
        lines.append(f"| {ph['phase']} | {i['p50']}/{i['p95']}/{i['max']} | {n['p50']}/{n['p95']}/{n['max']} | "
                     f"{i['timeouts'] + n['timeouts']} | {ph['daemonCpuPct']} | {ph['threadsMax']} | {ph['rssMBMax']} | "
                     f"{m['leaseLapsed']} | {m['mutexHeldLong']} | {m['peerDrops']} | {m['punch']} | {m['silenceBudget']} |")
    for ph in res["phases"]:
        if ph.get("topWaits"):
            lines += ["", f"## Top waiting frames during `{ph['phase']}` ({ph.get('stackTool')})", "",
                      "| threads | first acpmux frame above the wait |", "|---|---|"]
            lines += [f"| {w['threads']} | `{w['frame']}` |" for w in ph["topWaits"]]
    for ph in res["phases"]:
        if ph["log"].get("heldSites"):
            lines += ["", f"## Std mutexes held long during `{ph['phase']}` (hub/held_lock.rs)", "",
                      "| holds | max ms | lock @ site |", "|---|---|---|"]
            lines += [f"| {v['n']} | {v['maxMs']} | `{k}` |" for k, v in ph["log"]["heldSites"].items()]
        if ph["log"].get("lapseStages"):
            lines += ["", f"Lease lapses by stage during `{ph['phase']}`: {ph['log']['lapseStages']}"]
    return "\n".join(lines) + "\n"


def compare(dirs: list[str]) -> int:
    rows = [json.loads((Path(d) / "result.json").read_text()) for d in dirs]
    for d, r in zip(dirs, rows):
        print(f"== {d}")
        print(summary_md(r))
    return 0


def main() -> int:
    os.umask(0o077)
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--acpmux", help="the daemon binary under test")
    ap.add_argument("--peer-acpmux", help="the peer daemons' binary (default: --acpmux)")
    ap.add_argument("--out", help="output folder")
    ap.add_argument("--compare", nargs="+", metavar="DIR", help="print the summaries of earlier runs side by side")
    ap.add_argument("--peers", type=int, default=200)
    ap.add_argument("--peer-daemons", type=int, default=10)
    ap.add_argument("--peer-rows", type=int, default=20)
    ap.add_argument("--stall-frac", type=float, default=0.1)
    ap.add_argument("--flap", type=float, default=0.5, help="seconds between link cuts in duress")
    ap.add_argument("--sessions", type=int, default=8)
    ap.add_argument("--hub-rate", type=float, default=5.0)
    ap.add_argument("--cpu-x", type=int, default=12)
    ap.add_argument("--secs", type=float, default=180, help="the duress phase's length")
    ap.add_argument("--idle-secs", type=float, default=20)
    ap.add_argument("--settle", type=float, default=30, help="seconds after start for the peers to list")
    ap.add_argument("--reads", type=int, default=20, help="inbox reads per phase and form (at least)")
    ap.add_argument("--read-timeout", type=float, default=90)
    ap.add_argument("--samples", type=int, default=3)
    ap.add_argument("--log", default="info")
    ap.add_argument("--lazy-peers", action="store_true",
                    help="leave saved peers parked until used (the default dials all, as Leo's daemon had them up)")
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    if a.compare:
        return compare(a.compare)
    if not a.acpmux or not a.out:
        ap.error("--acpmux and --out are required")
    if not os.environ.get("FAST_CHECKS_OUT") and os.environ.get("ACPMUX_WEDGE_HERE") != "1":
        print("refused: this loads the host it runs on (CPU x cores, 200 links), so it runs in CI "
              "(cmux-ci test) or where ACPMUX_WEDGE_HERE=1 says this host may take it; never a person's Mac",
              file=sys.stderr)
        return 4
    out = Path(a.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    w = Wedge(a, out)
    try:
        return w.go()
    finally:
        w.cleanup()


if __name__ == "__main__":
    sys.exit(main())
