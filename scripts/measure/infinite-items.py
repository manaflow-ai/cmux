#!/usr/bin/env python3
"""Infinite items, time-compressed (CMUX-571).

Leo, 2026-11-14: "the bigger question is of memory and cpu staying flat on infinite chats. i obviously
dont mean infinite at once, but the dream of never ever needing to close a tab or workspace or anything.
thats the white whale." Leo, 2026-11-12: "infinite everything feels like nothing": every axis at most
1.2x empty, RAM, CPU and disk bounded over days. No real-time soak: days of life run in minutes.

For each count N it starts its own pair of daemons on scratch homes: an acpmux (the chats, on the ACP
stand-in agent cmux-tui/crates/acpmux/tests/fake_agent.py) and a headless cmux-tui (the workspaces and
tabs) pointed at it. It samples the empty pair, then opens N workspaces, each with its terminal tab and
one agent chat tab bound to a chat whose first turn is answered. ARCHIVED of the chats are archived,
WORKING keep streaming turns all day, and DRAWN is the one attached as a shown chat would be. Then it
compresses DAYS days into minutes; each simulated day is:
  - SWITCHES workspace switches and TAB_CYCLES tab open+close cycles (terminal and chat tabs);
  - turns streaming in the WORKING chats all day, and REVISITS idle chats prompted once (a chat the
    person comes back to: its hibernated agent wakes and goes again);
  - an archive and unarchive of a few chats;
  - a sleep/wake: every process of both trees stopped (SIGSTOP) for SLEEP seconds and continued;
  - the acpmux idle timer fast-forwarded (ACPMUX_IDLE_CHILD_SECS, default 2 min in the product);
then it waits for the idle agents to hibernate and samples an idle window.

Each sample is per process role (acpmux, agent, acpmux-child, cmux-tui, terminal-host, shell, other):
count, RSS, PSS, CPU seconds and context-switch wakeups over the idle window, open fds; and the disk
each home holds (acpmux home: sessions, logs; cmux-tui state and home). Output: INFINITE lines, one
PERF_ROW-style JSON line per headline, and --out JSON with every sample. Headlines per N:
  ratio_vs_empty   total PSS (and idle CPU, wakeups) at N over the empty pair's;
  per_item         (total at N - empty) / N;
  per_day          the least-squares slope over the simulated days (MB, disk MB) after creation.
Measurement only: it signals and reads only the processes it started (its two daemons' trees).

  infinite-items.py --acpmux BIN --tui BIN [--counts 10,100,1000] [--days 3] [--out result.json]
"""

import argparse
import concurrent.futures
import json
import os
import platform
import random
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

IS_LINUX = sys.platform.startswith("linux")
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FAKE_AGENT = os.path.join(ROOT, "cmux-tui/crates/acpmux/tests/fake_agent.py")
HARNESS = "bench-fake"


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, file=sys.stderr, flush=True)


# ------------------------------------------------------------------ processes


def children_map():
    kids = {}
    if IS_LINUX:
        for name in os.listdir("/proc"):
            if not name.isdigit():
                continue
            try:
                with open(f"/proc/{name}/stat", "rb") as f:
                    data = f.read()
            except OSError:
                continue
            rest = data[data.rfind(b")") + 2:].split()
            kids.setdefault(int(rest[1]), []).append(int(name))
    else:
        out = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True).stdout
        for line in out.splitlines():
            pid, ppid = (int(x) for x in line.split())
            kids.setdefault(ppid, []).append(pid)
    return kids


def cmdline(pid):
    try:
        if IS_LINUX:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                return f.read().replace(b"\0", b" ").decode(errors="replace")
        return subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
    except OSError:
        return ""


def sample_proc(pid):
    """RSS, PSS, CPU seconds, wakeups (context switches over all threads), open fds."""
    out = {}
    try:
        if IS_LINUX:
            with open(f"/proc/{pid}/stat", "rb") as f:
                data = f.read()
            rest = data[data.rfind(b")") + 2:].split()
            out["cpu_s"] = (int(rest[11]) + int(rest[12])) / os.sysconf("SC_CLK_TCK")
            out["rss"] = int(rest[21]) * os.sysconf("SC_PAGE_SIZE")
            with open(f"/proc/{pid}/smaps_rollup") as f:
                for line in f:
                    if line.startswith("Pss:"):
                        out["pss"] = int(line.split()[1]) * 1024
            out["fds"] = len(os.listdir(f"/proc/{pid}/fd"))
            csw = 0
            for tid in os.listdir(f"/proc/{pid}/task"):
                try:
                    with open(f"/proc/{pid}/task/{tid}/status") as f:
                        for line in f:
                            if line.startswith(("voluntary_ctxt", "nonvoluntary_ctxt")):
                                csw += int(line.split()[1])
                except OSError:
                    pass
            out["wakeups"] = csw
        else:
            ps = subprocess.run(["ps", "-o", "rss=,time=", "-p", str(pid)], capture_output=True, text=True).stdout.split()
            out["rss"] = int(ps[0]) * 1024
            out["pss"] = out["rss"]
            parts = [float(x) for x in ps[1].replace("-", ":").split(":")]
            out["cpu_s"] = sum(v * 60 ** i for i, v in enumerate(reversed(parts)))
            out["fds"] = None
            out["wakeups"] = None
    except (OSError, ValueError, IndexError):
        return None
    return out


def role_of(pid, top, cmd):
    if pid == top["acpmux"]:
        return "acpmux"
    if pid == top["tui"]:
        return "cmux-tui"
    if "fake_agent" in cmd:
        return "agent"
    if "__terminal-host" in cmd:
        return "terminal-host"
    if "acpmux" in cmd:
        return "acpmux-child"
    if any(cmd.split(" ")[0].endswith(s) for s in ("sh", "bash", "zsh", "fish")):
        return "shell"
    return "other"


def tree_pids(roots):
    kids = children_map()
    seen, stack = [], list(roots)
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.append(pid)
        stack.extend(kids.get(pid, []))
    return seen


def snapshot(top):
    rows = {}
    for pid in tree_pids([top["acpmux"], top["tui"]]):
        s = sample_proc(pid)
        if s is None:
            continue
        s["role"] = role_of(pid, top, cmdline(pid))
        rows[pid] = s
    return rows


def du(path):
    total = 0
    for base, _, files in os.walk(path):
        for name in files:
            try:
                st = os.lstat(os.path.join(base, name))
                total += st.st_blocks * 512 if hasattr(st, "st_blocks") else st.st_size
            except OSError:
                pass
    return total


def idle_window(top, seconds, disks):
    """Per-role totals: memory at the end, CPU and wakeups over `seconds` of nothing."""
    before = snapshot(top)
    time.sleep(seconds)  # the idle window itself: nothing is sent
    after = snapshot(top)
    roles = {}
    for pid, s in after.items():
        r = roles.setdefault(s["role"], {"count": 0, "rss": 0, "pss": 0, "fds": 0, "cpu_s": 0.0, "wakeups": 0})
        r["count"] += 1
        r["rss"] += s["rss"]
        r["pss"] += s.get("pss") or s["rss"]
        r["fds"] += s.get("fds") or 0
        b = before.get(pid)
        if b:
            r["cpu_s"] += max(0.0, s["cpu_s"] - b["cpu_s"])
            if s.get("wakeups") is not None and b.get("wakeups") is not None:
                r["wakeups"] += max(0, s["wakeups"] - b["wakeups"])
    for r in roles.values():
        r["cpu_pct"] = round(100 * r.pop("cpu_s") / seconds, 3)
        r["wakeups_per_s"] = round(r.pop("wakeups") / seconds, 2)
    total = {
        "pss_mb": round(sum(r["pss"] for r in roles.values()) / 1048576, 2),
        "rss_mb": round(sum(r["rss"] for r in roles.values()) / 1048576, 2),
        "cpu_pct": round(sum(r["cpu_pct"] for r in roles.values()), 3),
        "wakeups_per_s": round(sum(r["wakeups_per_s"] for r in roles.values()), 2),
        "fds": sum(r["fds"] for r in roles.values()),
        "procs": sum(r["count"] for r in roles.values()),
    }
    disk = {name: round(du(path) / 1048576, 3) for name, path in disks.items()}
    total["disk_mb"] = round(sum(disk.values()), 3)
    for r in roles.values():
        r["pss_mb"] = round(r.pop("pss") / 1048576, 2)
        r["rss_mb"] = round(r.pop("rss") / 1048576, 2)
    return {"total": total, "roles": roles, "disk": disk}


# ------------------------------------------------------------------ sockets


class Lines:
    def __init__(self, path, timeout=120):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buf = b""
        self.next_id = 1

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def send(self, obj):
        self.sock.sendall((json.dumps(obj) + "\n").encode())

    def read(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise ConnectionError("socket closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)


class Tui(Lines):
    def call(self, cmd, **params):
        rid = self.next_id
        self.next_id += 1
        self.send({"id": rid, "cmd": cmd, **params})
        while True:
            msg = self.read()
            if msg.get("id") == rid and "ok" in msg:
                if not msg.get("ok"):
                    raise RuntimeError(f"{cmd}: {msg.get('error')!r}")
                return msg.get("data") or {}


class Acp(Lines):
    def call(self, method, params):
        rid = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        while True:
            msg = self.read()
            if msg.get("id") == rid and ("result" in msg or "error" in msg):
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg["result"]


# ------------------------------------------------------------------ one count


class Run:
    def __init__(self, args, count):
        self.args, self.count = args, count
        self.root = tempfile.mkdtemp(prefix=f"inf{count}-", dir=args.root_dir)
        self.acp_home = os.path.join(self.root, "acpmux")
        self.tui_root = os.path.join(self.root, "tui")
        os.makedirs(self.acp_home, mode=0o700)
        os.makedirs(os.path.join(self.tui_root, "home"))
        os.makedirs(os.path.join(self.tui_root, "state"))
        self.acp_sock = os.path.join(self.root, "a.sock")
        self.tui_sock = os.path.join(self.root, "t.sock")
        self.procs = []
        self.errors = {}
        self.stop_working = threading.Event()

    def error(self, what, exc):
        self.errors[what] = self.errors.get(what, 0) + 1
        if self.errors[what] <= 3:
            log(f"N={self.count} {what}: {exc}")

    def env(self):
        home = os.path.join(self.tui_root, "home")
        env = dict(os.environ)
        env.update(
            HOME=home,
            XDG_CONFIG_HOME=os.path.join(home, ".config"),
            XDG_STATE_HOME=os.path.join(home, ".local/state"),
            XDG_DATA_HOME=os.path.join(home, ".local/share"),
            XDG_CACHE_HOME=os.path.join(home, ".cache"),
            ACPMUX_HOME=self.acp_home,
            ACPMUX_SOCKET=self.acp_sock,
            ACPMUX_IDLE_CHILD_SECS=str(self.args.idle_child_secs),
            ACPMUX_UNUSED_EXIT_SECS="0",
            ACPMUX_SESSION_CPU_CLASS="normal",
            CMUX_TUI_CONFIG=os.path.join(self.tui_root, "config.json"),
        )
        return env

    def start(self):
        with open(os.path.join(self.acp_home, "config.json"), "w") as f:
            json.dump({"harnesses": {HARNESS: {"argv": [sys.executable, FAKE_AGENT]}}, "defaultHarness": HARNESS,
                       "permissionPolicy": "allow"}, f)
        os.chmod(os.path.join(self.acp_home, "config.json"), 0o600)
        ready = os.path.join(self.root, "acpmux.out")
        with open(ready, "w") as out, open(os.path.join(self.root, "acpmux.log"), "w") as err:
            acp = subprocess.Popen([self.args.acpmux, "daemon", "run", "--ready-fd", "1", "--log", "warn"],
                                   stdout=out, stderr=err, stdin=subprocess.DEVNULL, env=self.env(),
                                   start_new_session=True)
        self.procs.append(acp)
        self.wait_for(lambda: '"ready":true' in open(ready).read().replace(" ", ""), acp, "acpmux ready")
        with open(os.path.join(self.root, "tui.log"), "w") as log_file:
            tui = subprocess.Popen([self.args.tui, "--headless", "--session", f"inf{os.getpid()}-{self.count}",
                                    "--socket", self.tui_sock, "--state", os.path.join(self.tui_root, "state")],
                                   stdout=log_file, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                   env=self.env(), start_new_session=True)
        self.procs.append(tui)

        def tui_up():
            try:
                c = Tui(self.tui_sock, timeout=5)
                c.call("identify")
                c.close()
                return True
            except (OSError, RuntimeError, ValueError):
                return False
        self.wait_for(tui_up, tui, "cmux-tui socket")
        self.top = {"acpmux": acp.pid, "tui": tui.pid}
        self.disks = {"acpmux_home": self.acp_home, "tui_state": os.path.join(self.tui_root, "state"),
                      "tui_home": os.path.join(self.tui_root, "home")}

    def wait_for(self, check, proc, what, seconds=60):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise RuntimeError(f"{what}: exited {proc.returncode}; see {self.root}")
            if os.path.exists(self.acp_sock if "acpmux" in what else self.tui_sock) and check():
                return
            time.sleep(0.1)  # bench: waiting for a daemon it started to listen
        raise RuntimeError(f"{what}: not within {seconds} s")

    def stop(self):
        # Every process of this run's two trees, recorded before teardown: what is left of them after
        # the daemons stop is this run's own and is ended by that pid.
        own = tree_pids([p.pid for p in self.procs]) if self.procs else []
        try:
            c = Tui(self.tui_sock, timeout=120)
            ident = c.call("identify")
            c.call("shutdown-daemon", pid=ident.get("pid"),
                   generation=ident.get("generation") or ident.get("boot_generation") or "", end_terminals=True)
            c.close()
        except (OSError, RuntimeError, ValueError) as exc:
            log(f"N={self.count} shutdown-daemon: {exc}")
        for proc in reversed(self.procs):
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        for proc in self.procs:
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        time.sleep(1)  # bench: let the daemons' own teardown end their children
        for pid in own:
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        if not self.args.keep:
            shutil.rmtree(self.root, ignore_errors=True)

    # -- items

    def new_chat(self, acp, index):
        made = acp.call("session/new", {"cwd": self.root, "mcpServers": [],
                                        "_meta": {"acpmux": {"name": f"infinite {index}"}}})
        sid = made["sessionId"]
        acp.call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": self.turn_text(index, 0)}]})
        return sid

    def turn_text(self, index, turn):
        # The stand-in agent echoes the prompt: TURN_BYTES of text each way, what a turn adds to the log.
        body = f"chat {index} turn {turn}: " + ("lorem ipsum dolor sit amet " * (self.args.turn_bytes // 27 + 1))
        return body[: self.args.turn_bytes]

    def open_items(self):
        n = self.count
        tui = Tui(self.tui_sock, timeout=300)
        self.workspaces, self.panes, self.chat_tabs = [], [], []
        for i in range(n):
            data = tui.call("new-workspace", name=f"w{i}", cols=80, rows=24)
            self.workspaces.append(data.get("workspace"))
        tree = tui.call("list-workspaces")
        listed = tree.get("workspaces", [])[-n:]
        self.workspaces = [w["id"] for w in listed]
        self.panes = [w["screens"][0]["panes"][0]["id"] for w in listed]

        sessions = [None] * n

        def make(indices):
            acp = Acp(self.acp_sock, timeout=300)
            for i in indices:
                try:
                    sessions[i] = self.new_chat(acp, i)
                except (OSError, RuntimeError, ValueError) as exc:
                    self.error("session/new", exc)
            acp.close()
        workers = min(8, n)
        with concurrent.futures.ThreadPoolExecutor(workers) as pool:
            list(pool.map(make, [range(w, n, workers) for w in range(workers)]))
        self.sessions = sessions
        for i, sid in enumerate(sessions):
            if not sid:
                continue
            try:
                data = tui.call("new-conversation-tab", pane=self.panes[i], cols=80, rows=24,
                                agent_session={"host": "install:infinite-items", "session": sid, "harness": HARNESS})
                self.chat_tabs.append(data.get("surface"))
            except (OSError, RuntimeError, ValueError) as exc:
                self.error("new-conversation-tab", exc)
        tui.close()
        live = [s for s in sessions if s]
        rnd = random.Random(self.count)
        rnd.shuffle(live)
        archived_n = int(len(live) * self.args.archived)
        self.archived = live[:archived_n]
        rest = live[archived_n:]
        self.working = rest[: min(self.args.working, len(rest))]
        self.drawn = rest[len(self.working): len(self.working) + self.args.drawn]
        self.idle = rest[len(self.working) + self.args.drawn:]
        acp = Acp(self.acp_sock)
        for sid in self.archived:
            try:
                acp.call("_acpmux/archive", {"sessionId": sid, "archived": True})
            except (OSError, RuntimeError, ValueError) as exc:
                self.error("archive", exc)
        acp.close()
        # A drawn chat: a client attached to it, reading its newest page and its live updates.
        self.drawn_conns = []
        for sid in self.drawn:
            try:
                c = Acp(self.acp_sock)
                c.call("_acpmux/attach", {"sessionId": sid, "limit": 400})
                c.sock.settimeout(None)
                threading.Thread(target=self.drain, args=(c,), daemon=True).start()
                self.drawn_conns.append(c)
            except (OSError, RuntimeError, ValueError) as exc:
                self.error("attach", exc)

    @staticmethod
    def drain(conn):
        try:
            while conn.sock.recv(1 << 20):
                pass
        except OSError:
            pass

    def work(self, sid, index):
        """A working chat: turns back to back while the day runs."""
        acp = Acp(self.acp_sock, timeout=120)
        turn = 0
        while not self.stop_working.is_set():
            turn += 1
            try:
                acp.call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "slow" if turn % 4 == 0 else self.turn_text(index, turn)}]})
            except (OSError, RuntimeError, ValueError) as exc:
                self.error("working turn", exc)
                time.sleep(1)  # bench: a failed turn waits before the next
            self.turns += 1
        acp.close()

    def day(self, number):
        a, rnd = self.args, random.Random(self.count * 1000 + number)
        self.stop_working.clear()
        self.turns = 0
        workers = [threading.Thread(target=self.work, args=(sid, i), daemon=True) for i, sid in enumerate(self.working)]
        for t in workers:
            t.start()
        tui = Tui(self.tui_sock, timeout=120)
        acp = Acp(self.acp_sock, timeout=120)
        steps = max(a.switches, a.tab_cycles, a.revisits)
        for step in range(steps):
            if step < a.switches and self.workspaces:
                try:
                    tui.call("select-workspace", workspace=rnd.choice(self.workspaces))
                except (OSError, RuntimeError, ValueError) as exc:
                    self.error("select-workspace", exc)
            if step < a.tab_cycles and self.panes:
                pane = rnd.choice(self.panes)
                try:
                    data = tui.call("new-tab", pane=pane, cols=80, rows=24)
                    tui.call("close-surface", surface=data["surface"])
                except (OSError, RuntimeError, ValueError) as exc:
                    self.error("terminal tab cycle", exc)
                if self.idle:
                    try:
                        data = tui.call("new-conversation-tab", pane=pane, cols=80, rows=24, agent_session={
                            "host": "install:infinite-items", "session": rnd.choice(self.idle), "harness": HARNESS})
                        tui.call("close-surface", surface=data["surface"])
                    except (OSError, RuntimeError, ValueError) as exc:
                        self.error("chat tab cycle", exc)
            if step < a.revisits and self.idle:
                sid = rnd.choice(self.idle)
                try:
                    acp.call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": self.turn_text(step, number)}]})
                    self.turns += 1
                except (OSError, RuntimeError, ValueError) as exc:
                    self.error("revisit turn", exc)
        for sid in self.archived[:3]:
            try:
                acp.call("_acpmux/archive", {"sessionId": sid, "archived": False})
                acp.call("_acpmux/archive", {"sessionId": sid, "archived": True})
            except (OSError, RuntimeError, ValueError) as exc:
                self.error("archive cycle", exc)
        tui.close()
        acp.close()
        self.stop_working.set()
        for t in workers:
            t.join(timeout=60)
        if a.sleep > 0:
            # Sleep/wake: every process of both trees stopped, then continued (the clock moves on).
            pids = tree_pids([self.top["acpmux"], self.top["tui"]])
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGSTOP)
                except ProcessLookupError:
                    pass
            time.sleep(a.sleep)  # bench: the simulated sleep
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGCONT)
                except ProcessLookupError:
                    pass
        return self.turns


def slope(xs, ys):
    if len(xs) < 2:
        return 0.0
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    den = sum((x - mx) ** 2 for x in xs)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den if den else 0.0


def perf_row(name, value, unit):
    print("PERF_ROW " + json.dumps({"name": name, "p50": round(value, 4), "p95": round(value, 4), "unit": unit}), flush=True)


def settle(args):
    # Past the (fast-forwarded) idle timer, so idle agents have hibernated.
    time.sleep(args.idle_child_secs + args.settle)  # bench: waiting out the idle timer


def run_count(args, count):
    run = Run(args, count)
    result = {"count": count, "samples": []}
    try:
        run.start()
        settle(args)
        empty = idle_window(run.top, args.window, run.disks)
        result["empty"] = empty
        log(f"N={count} empty {json.dumps(empty['total'])}")
        t0 = time.monotonic()
        run.open_items()
        result["open_seconds"] = round(time.monotonic() - t0, 1)
        result["mix"] = {"chats": len([s for s in run.sessions if s]), "archived": len(run.archived),
                         "working": len(run.working), "drawn": len(run.drawn), "idle": len(run.idle),
                         "chat_tabs": len(run.chat_tabs), "workspaces": len(run.workspaces)}
        settle(args)
        day0 = idle_window(run.top, args.window, run.disks)
        day0["day"] = 0
        result["samples"].append(day0)
        log(f"N={count} opened in {result['open_seconds']} s {json.dumps(result['mix'])}: {json.dumps(day0['total'])}")
        for number in range(1, args.days + 1):
            t0 = time.monotonic()
            turns = run.day(number)
            spent = round(time.monotonic() - t0, 1)
            settle(args)
            s = idle_window(run.top, args.window, run.disks)
            s.update(day=number, turns=turns, seconds=spent)
            result["samples"].append(s)
            log(f"N={count} day {number} ({spent} s, {turns} turns): {json.dumps(s['total'])}")
    finally:
        result["errors"] = run.errors
        run.stop()
    return result


def report(results):
    print("INFINITE n | MB (PSS) | ratio | MB/item | cpu % idle | ratio | wakeups/s | ratio | fds | disk MB | "
          "MB/day | disk MB/day | steepest role (MB/item)")
    for r in results:
        if "empty" not in r or not r["samples"]:
            continue
        e, d0, last = r["empty"]["total"], r["samples"][0], r["samples"][-1]
        n = r["count"]
        t = last["total"]
        ratio = lambda a, b: a / b if b else float("inf")  # noqa: E731
        days = [s["day"] for s in r["samples"]]
        mb_day = slope(days, [s["total"]["pss_mb"] for s in r["samples"]])
        disk_day = slope(days, [s["total"]["disk_mb"] for s in r["samples"]])
        per_role = {}
        for role, v in last["roles"].items():
            base = r["empty"]["roles"].get(role, {}).get("pss_mb", 0)
            per_role[role] = (v["pss_mb"] - base) / n
        steep = max(per_role.items(), key=lambda kv: kv[1]) if per_role else ("-", 0)
        print(f"INFINITE {n} | {t['pss_mb']:.1f} | {ratio(t['pss_mb'], e['pss_mb']):.2f}x | "
              f"{(t['pss_mb'] - e['pss_mb']) / n:.3f} | {t['cpu_pct']:.2f} | {ratio(t['cpu_pct'], e['cpu_pct']):.2f}x | "
              f"{t['wakeups_per_s']:.1f} | {ratio(t['wakeups_per_s'], e['wakeups_per_s']):.2f}x | {t['fds']} | "
              f"{t['disk_mb']:.2f} | {mb_day:+.2f} | {disk_day:+.3f} | {steep[0]} {steep[1]:.3f}", flush=True)
        print(f"INFINITE-EMPTY {n} {json.dumps(e)}", flush=True)
        for s in r["samples"]:
            roles = {k: {"n": v["count"], "mb": v["pss_mb"], "cpu": v["cpu_pct"], "wk": v["wakeups_per_s"], "fds": v["fds"]}
                     for k, v in sorted(s["roles"].items())}
            print(f"INFINITE-DAY {n} day={s['day']} {json.dumps(s['total'])} disk={json.dumps(s['disk'])} roles={json.dumps(roles)}", flush=True)
        if r.get("errors"):
            print(f"INFINITE-ERRORS {n} {json.dumps(r['errors'])}", flush=True)
        perf_row(f"infinite_items.n{n}.memory_vs_empty", ratio(t["pss_mb"], e["pss_mb"]), "ratio")
        perf_row(f"infinite_items.n{n}.mb_per_item", (t["pss_mb"] - e["pss_mb"]) / n, "MB")
        perf_row(f"infinite_items.n{n}.cpu_idle_pct", t["cpu_pct"], "pct")
        perf_row(f"infinite_items.n{n}.cpu_idle_vs_empty", ratio(t["cpu_pct"], e["cpu_pct"]), "ratio")
        perf_row(f"infinite_items.n{n}.wakeups_per_s", t["wakeups_per_s"], "count")
        perf_row(f"infinite_items.n{n}.mb_per_day", mb_day, "MB")
        perf_row(f"infinite_items.n{n}.disk_mb_per_day", disk_day, "MB")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--acpmux", required=True)
    p.add_argument("--tui", required=True)
    p.add_argument("--counts", default="10,100,1000")
    p.add_argument("--days", type=int, default=3)
    p.add_argument("--switches", type=int, default=200, help="workspace switches a simulated day")
    p.add_argument("--tab-cycles", type=int, default=60, help="terminal and chat tab open+close cycles a day")
    p.add_argument("--revisits", type=int, default=20, help="idle chats prompted once a day")
    p.add_argument("--working", type=int, default=3, help="chats streaming turns all day")
    p.add_argument("--drawn", type=int, default=1, help="chats attached as shown")
    p.add_argument("--archived", type=float, default=0.2, help="share of chats archived")
    p.add_argument("--turn-bytes", type=int, default=2048)
    p.add_argument("--idle-child-secs", type=int, default=5, help="ACPMUX_IDLE_CHILD_SECS (product: 120)")
    p.add_argument("--settle", type=float, default=5)
    p.add_argument("--window", type=float, default=10, help="idle window seconds per sample")
    p.add_argument("--sleep", type=float, default=3, help="simulated sleep a day (SIGSTOP), seconds")
    p.add_argument("--root-dir", default=None)
    p.add_argument("--keep", action="store_true")
    p.add_argument("--out")
    args = p.parse_args()
    for path in (args.acpmux, args.tui):
        if not os.access(path, os.X_OK):
            raise SystemExit(f"infinite-items: not executable: {path}")
    print(f"INFINITE-MACHINE host={platform.node()} platform={platform.platform()} cpus={os.cpu_count()} "
          f"counts={args.counts} days={args.days}", flush=True)
    results = []
    for count in (int(c) for c in args.counts.split(",")):
        try:
            results.append(run_count(args, count))
        except Exception as exc:  # noqa: BLE001 - one count's failure is reported, the rest still run
            log(f"N={count} failed: {exc!r}")
            results.append({"count": count, "failed": repr(exc), "samples": []})
    report(results)
    if args.out:
        with open(args.out, "w") as f:
            json.dump({"args": vars(args), "results": results}, f, indent=1)
    return 0 if all(r.get("samples") for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
