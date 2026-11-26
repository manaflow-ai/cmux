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

Each sample is per process role (acpmux, agent-host, agent, acpmux-child, cmux-tui, terminal-host, holder,
shell, other): count, threads, RSS, PSS, CPU seconds and context-switch wakeups over the idle window, open
fds; and the disk
each home holds (acpmux home: sessions, logs; cmux-tui state and home). Output: INFINITE lines, one
PERF_ROW-style JSON line per headline, and --out JSON with every sample. Headlines per N:
  ratio_vs_empty   total PSS (and idle CPU, wakeups) at N over the empty pair's;
  per_item         (total at N - empty) / N;
  per_day          the least-squares slope over the simulated days (MB, disk MB) after creation.
INFINITE-PERITEM lines give each role at each N: procs, threads, PSS MB and its MB per item over the empty
pair, and idle wakeups/s. INFINITE-DISKGROW lines name the files whose bytes grow most per simulated day (paths
with their ids folded to *, so a file per chat is one line), the next disk slope to bound. --terminal-host-model=hosts runs the same counts with a terminal host per terminal
process (CMUX_TUI_TERMINAL_HOST_MODEL=hosts, the default everywhere) and --terminal-host-model=holder the one holder process.
--browser-tabs adds a browser tab to each workspace: headless cmux-tui keeps only its model (the page and
its renderer are the app's), so it measures the daemon's share of a browser tab and no renderer.
Measurement only: it signals and reads only the processes it started (its two daemons' trees).

  infinite-items.py --acpmux BIN --tui BIN [--counts 10,100,1000] [--days 3] [--out result.json]
"""

import argparse
import concurrent.futures
import json
import os
import platform
import random
import re
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
    """RSS, PSS, CPU seconds, wakeups (context switches over all threads), threads, open fds."""
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
            tids = os.listdir(f"/proc/{pid}/task")
            out["threads"] = len(tids)
            per_tid = {}
            for tid in tids:
                try:
                    name, n = "?", 0
                    with open(f"/proc/{pid}/task/{tid}/status") as f:
                        for line in f:
                            if line.startswith("Name:"):
                                name = line.split(None, 1)[1].strip() if len(line.split()) > 1 else "?"
                            elif line.startswith(("voluntary_ctxt", "nonvoluntary_ctxt")):
                                n += int(line.split()[1])
                    csw += n
                    per_tid[tid] = (name, n)
                except OSError:
                    pass
            out["wakeups"] = csw
            out["tid_wakeups"] = per_tid
        else:
            ps = subprocess.run(["ps", "-o", "rss=,time=", "-p", str(pid)], capture_output=True, text=True).stdout.split()
            out["rss"] = int(ps[0]) * 1024
            out["pss"] = out["rss"]
            parts = [float(x) for x in ps[1].replace("-", ":").split(":")]
            out["cpu_s"] = sum(v * 60 ** i for i, v in enumerate(reversed(parts)))
            out["fds"] = None
            out["wakeups"] = None
            out["threads"] = len(subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True,
                                                text=True).stdout.splitlines()[1:]) or None
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
    if "__agent-host" in cmd:
        return "agent-host"  # acpmux's host per agent (agent_host/link.rs); the harness runs under it
    if "__terminal-host" in cmd:
        return "terminal-host"
    if "__holder" in cmd or os.path.basename(cmd.split(" ")[0]) == "cmux-holder":
        return "holder"  # CMUX_TUI_TERMINAL_HOST_MODEL=holder: one process holds every terminal
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
        cmd = cmdline(pid)
        s["role"] = role_of(pid, top, cmd)
        # The program and its first words, paths cut to their names: which kind of child a role's processes are.
        s["cmd"] = " ".join(os.path.basename(w) if w.startswith("/") else w for w in cmd.split()[:3])
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


# A path with its ids folded, so a file per chat, workspace or day sums into one group: hex runs of 8 or more and
# digit runs become *.
FILE_ID = re.compile(r"[0-9a-f]{8,}|[0-9]+")


def file_groups(disks):
    """{"home/path with ids as *": bytes on disk} for every file under each disk root."""
    groups = {}
    for name, path in disks.items():
        for base, _, files in os.walk(path):
            for file in files:
                full = os.path.join(base, file)
                try:
                    st = os.lstat(full)
                except OSError:
                    continue
                key = f"{name}/{FILE_ID.sub('*', os.path.relpath(full, path))}"
                groups[key] = groups.get(key, 0) + (st.st_blocks * 512 if hasattr(st, "st_blocks") else st.st_size)
    return groups


# The kernel's own mappings in a process: what smaps_kinds files as "vdso".
KERNEL_MAPPINGS = {"[vdso]", "[vvar]", "[vsyscall]", "[uprobes]"}


def smaps_kinds(pid):
    """One process's PSS in kB by mapping kind (its binary, heap, stacks, other files, anonymous), Linux only:
    where a role's per-process memory sits. Anonymous memory is split three ways: a thread's stack (the mapping
    above a guard page), a malloc arena (glibc maps each at a 64 MB boundary) and the rest."""
    kinds, name = {}, None
    prev_end, prev_guard = None, False
    try:
        exe = os.path.realpath(f"/proc/{pid}/exe")
        with open(f"/proc/{pid}/smaps") as f:
            for line in f:
                head = line.split()
                if head and "-" in head[0] and not head[0].endswith(":"):
                    path = head[5] if len(head) > 5 else ""
                    start, end = (int(x, 16) for x in head[0].split("-"))
                    anon = ("thread-stack" if prev_guard and prev_end == start else
                            "arena" if start % (64 << 20) == 0 else "anon")
                    name = ("binary" if path == exe else "heap" if path == "[heap]" else
                            "stack" if path.startswith("[stack") else anon if not path else
                            "vdso" if path in KERNEL_MAPPINGS or path.startswith("[vvar") else
                            # A named anonymous mapping (`[anon:NAME]`, prctl PR_SET_VMA_ANON_NAME): an
                            # allocator's heap, mimalloc's arenas above all, not the kernel's pages.
                            "heap:" + path[6:-1] if path.startswith("[anon:") else
                            anon if path.startswith("[") else "file:" + os.path.basename(path))
                    prev_end, prev_guard = end, not path and head[1].startswith("---")
                elif head and head[0] == "Pss:" and name:
                    kinds[name] = kinds.get(name, 0) + int(head[1])
    except (OSError, ValueError, IndexError):
        return {}
    return dict(sorted(kinds.items(), key=lambda kv: -kv[1])[:8])


def idle_window(top, seconds, disks):
    """Per-role totals: memory at the end, CPU and wakeups over `seconds` of nothing."""
    before = snapshot(top)
    time.sleep(seconds)  # sleep-ok: the idle window itself, the span CPU and wakeups are measured over
    after = snapshot(top)
    roles = {}
    for pid, s in after.items():
        r = roles.setdefault(s["role"], {"count": 0, "threads": 0, "rss": 0, "pss": 0, "fds": 0, "cpu_s": 0.0,
                                         "wakeups": 0, "cmds": {}})
        r.setdefault("by_pss", []).append((s.get("pss") or s["rss"], pid))
        r["cmds"][s["cmd"]] = r["cmds"].get(s["cmd"], 0) + 1
        named = r.setdefault("thread_names", {})
        for name, _ in (s.get("tid_wakeups") or {}).values():
            named[name] = named.get(name, 0) + 1
        r["count"] += 1
        r["threads"] += s.get("threads") or 0
        r["rss"] += s["rss"]
        r["pss"] += s.get("pss") or s["rss"]
        r["fds"] += s.get("fds") or 0
        b = before.get(pid)
        if b:
            r["cpu_s"] += max(0.0, s["cpu_s"] - b["cpu_s"])
            if s.get("wakeups") is not None and b.get("wakeups") is not None:
                r["wakeups"] += max(0, s["wakeups"] - b["wakeups"])
            # Which threads woke, by name (a daemon's 1,000 readers show as one name with a count of threads):
            # the idle wakeups' owner without perf or strace.
            names = r.setdefault("thread_wakeups", {})
            old = b.get("tid_wakeups") or {}
            for tid, (name, n) in (s.get("tid_wakeups") or {}).items():
                woke = max(0, n - old.get(tid, (name, n))[1])
                if woke:
                    names[name] = names.get(name, 0) + woke
    for r in roles.values():
        # The role's median process by PSS, where its memory sits: the first one found is the one-off (a
        # bootstrap host among a thousand per-tab hosts).
        by_pss = sorted(r.pop("by_pss"))
        if IS_LINUX:
            r["smaps_kb"] = smaps_kinds(by_pss[len(by_pss) // 2][1])
        r["cpu_pct"] = round(100 * r.pop("cpu_s") / seconds, 3)
        r["wakeups_per_s"] = round(r.pop("wakeups") / seconds, 2)
        r["thread_wakeups"] = dict(sorted(r.get("thread_wakeups", {}).items(), key=lambda kv: -kv[1])[:8])
        r["thread_names"] = dict(sorted(r.get("thread_names", {}).items(), key=lambda kv: -kv[1])[:6])
    total = {
        "pss_mb": round(sum(r["pss"] for r in roles.values()) / 1048576, 2),
        "rss_mb": round(sum(r["rss"] for r in roles.values()) / 1048576, 2),
        "cpu_pct": round(sum(r["cpu_pct"] for r in roles.values()), 3),
        "wakeups_per_s": round(sum(r["wakeups_per_s"] for r in roles.values()), 2),
        "fds": sum(r["fds"] for r in roles.values()),
        "procs": sum(r["count"] for r in roles.values()),
        "threads": sum(r["threads"] for r in roles.values()),
    }
    disk = {name: round(du(path) / 1048576, 3) for name, path in disks.items()}
    total["disk_mb"] = round(sum(disk.values()), 3)
    for r in roles.values():
        r["pss_mb"] = round(r.pop("pss") / 1048576, 2)
        r["rss_mb"] = round(r.pop("rss") / 1048576, 2)
    return {"total": total, "roles": roles, "disk": disk, "files": file_groups(disks)}


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
        # The terminal model under test, never the caller's: the product default (a host per terminal),
        # a host per terminal, or the holder.
        env.pop("CMUX_TUI_TERMINAL_HOST_MODEL", None)
        if self.args.terminal_host_model != "product":
            env["CMUX_TUI_TERMINAL_HOST_MODEL"] = self.args.terminal_host_model
        # The agent holder under test (acpmux agent_host/custody.rs), never the caller's.
        env["ACPMUX_AGENT_HOLDER"] = "1" if self.args.agent_holder == "on" else "0"
        if self.args.evict_idle_secs is not None:
            env["ACPMUX_EVICT_IDLE_SECS"] = str(self.args.evict_idle_secs)
        # The caller's cap never leaks into an arm that did not ask for one.
        env.pop("ACPMUX_RESIDENT_CAP", None)
        if self.args.resident_cap:
            env["ACPMUX_RESIDENT_CAP"] = str(self.args.resident_cap)
        return env

    def start(self):
        with open(os.path.join(self.acp_home, "config.json"), "w") as f:
            json.dump({"harnesses": {HARNESS: {"argv": [sys.executable, FAKE_AGENT]}}, "defaultHarness": HARNESS,
                       "permissionPolicy": "allow"}, f)
        os.chmod(os.path.join(self.acp_home, "config.json"), 0o600)
        ready = os.path.join(self.root, "acpmux.out")
        with open(ready, "w") as out, open(os.path.join(self.root, "acpmux.log"), "w") as err:
            acp = subprocess.Popen([self.args.acpmux, "daemon", "run", "--ready-fd", "1", "--log", self.args.acpmux_log],
                                   stdout=out, stderr=err, stdin=subprocess.DEVNULL, env=self.env(),
                                   start_new_session=True)
        self.procs.append(acp)
        self.wait_for(lambda: '"ready":true' in open(ready).read().replace(" ", ""), acp, "acpmux ready")
        with open(os.path.join(self.root, "tui.log"), "w") as log_file:
            tui = subprocess.Popen([self.args.tui, "--headless", "--session", f"inf{os.getpid()}-{self.count}",
                                    "--socket", self.tui_sock, "--state", os.path.join(self.tui_root, "state"),
                                    # The app's owner reaps a closed tab's terminal after its grace (30 s,
                                    # local_owner.rs); a bare --headless reaps nothing. Fast-forwarded here.
                                    "--terminal-reap-grace-seconds", str(self.args.reap_grace_secs)],
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
        # The daemons' own teardown ends their children: wait (5 s at most) until none of the recorded pids is left.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and any(os.path.exists(f"/proc/{pid}") for pid in own):
            time.sleep(0.05)
        for pid in own:
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        self.hibernations()
        if not self.args.keep:
            shutil.rmtree(self.root, ignore_errors=True)

    def hibernations(self):
        """At --acpmux-log info: how fast acpmux hibernated idle agents (its `hibernated` lines: count, the span
        from the first to the last, and each one's exit_ms), the rate a pass of the idle reaper reaches."""
        import re
        # The daemon logs to its stdout (log_sink.rs), so read both of its outputs; colour codes are cut.
        lines = []
        for name in ("acpmux.out", "acpmux.log"):
            try:
                with open(os.path.join(self.root, name), errors="replace") as f:
                    lines += [re.sub(r"\x1b\[[0-9;]*m", "", line) for line in f if "hibernated:" in line]
            except OSError:
                pass
        if not lines:
            return
        exits = sorted(int(m.group(1)) for line in lines if (m := re.search(r"exit_ms=(\d+)", line)))
        stamps = [m.group(1) for line in lines if (m := re.match(r"\S*?(\d\d:\d\d:\d\d(?:\.\d+)?)", line))]

        def secs(stamp):
            h, m_, s = stamp.split(":")
            return int(h) * 3600 + int(m_) * 60 + float(s)
        span = secs(stamps[-1]) - secs(stamps[0]) if len(stamps) > 1 else 0.0
        p50 = exits[len(exits) // 2] if exits else None
        print(f"INFINITE-HIBERNATE {self.count} n={len(lines)} span_s={span:.1f} "
              f"rate_per_s={(len(lines) / span) if span else 0:.1f} exit_ms_p50={p50} "
              f"exit_ms_max={exits[-1] if exits else None}", flush=True)

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
        # select-workspace takes the index in the session's list (a `workspace` id is ignored by it).
        first = len(tree.get("workspaces", [])) - len(listed)
        self.workspace_index = {w: first + i for i, w in enumerate(self.workspaces)}
        self.panes = [w["screens"][0]["panes"][0]["id"] for w in listed]
        self.browser_tabs = []
        for pane in self.panes if self.args.browser_tabs else []:
            try:
                data = tui.call("new-browser-tab", pane=pane, url="about:blank", cols=80, rows=24)
                self.browser_tabs.append(data.get("surface"))
            except (OSError, RuntimeError, ValueError) as exc:
                self.error("new-browser-tab", exc)

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
        self.park_idle()
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

    def open_probe(self, k):
        """--open-probe K: opens K idle chats as the app does (attach, newest 400 records), each on a fresh
        connection, after the last idle window so it moves no memory number. With --evict-idle-secs those
        chats are evicted rows, so this is the open of an evicted chat; without it, of a resident one."""
        picks = random.Random(self.count).sample(self.idle, min(k, len(self.idle)))
        took = []
        for sid in picks:
            try:
                c = Acp(self.acp_sock, timeout=60)
                t0 = time.monotonic()
                c.call("_acpmux/attach", {"sessionId": sid, "limit": 400})
                took.append((time.monotonic() - t0) * 1000)
                c.close()
            except (OSError, RuntimeError, ValueError) as exc:
                self.error("open probe", exc)
        if not took:
            return None
        took.sort()
        out = {"n": len(took), "p50": round(took[len(took) // 2], 2), "p95": round(took[int(len(took) * 0.95) - 1 if len(took) > 1 else 0], 2),
               "max": round(took[-1], 2)}
        # The daemon's own timing of each chat it made again (`_acpmux/status` evicted.rehydrate*): the
        # rehydrate alone, without the attach's records and the socket.
        try:
            c = Acp(self.acp_sock, timeout=60)
            ev = c.call("_acpmux/status", {}).get("evicted", {})
            c.close()
            out["rehydrate"] = {"n": ev.get("rehydrateSamples"), "p50_ms": round(ev.get("rehydrateP50Us", 0) / 1000, 3),
                                "p99_ms": round(ev.get("rehydrateP99Us", 0) / 1000, 3),
                                "evicted_now": ev.get("now"), "evictions": ev.get("evictions")}
        except (OSError, RuntimeError, ValueError) as exc:
            self.error("status", exc)
        print(f"INFINITE-OPEN {self.count} evict={self.args.evict_idle_secs} cap={self.args.resident_cap} "
              f"{json.dumps(out)}", flush=True)
        return out

    def heap_profile(self):
        """--heap-profile: a dhat-heap acpmux (ACPMUX_DHAT_OUT) writes its profile now, after the last sample, and
        answers its live bytes then and at the peak (`_acpmux/heap_profile`): a daemon stopped by a signal can be
        killed before it writes. Prints INFINITE-HEAPPROFILE."""
        try:
            c = Acp(self.acp_sock, timeout=600)
            out = c.call("_acpmux/heap_profile", {})
            c.close()
        except (OSError, RuntimeError, ValueError) as exc:
            self.error("heap profile", exc)
            return
        chats = len([x for x in getattr(self, "sessions", []) if x])
        print(f"INFINITE-HEAPPROFILE {self.count} cap={self.args.resident_cap} chats={chats} {json.dumps(out)}",
              flush=True)

    @staticmethod
    def drain(conn):
        try:
            while conn.sock.recv(1 << 20):
                pass
        except OSError:
            pass

    def park_idle(self):
        """--park-idle: what the app's freeing tier does to a hibernated workspace (CmuxNextHibernation
        WorkspaceFreeingPlanner, `workspaces.freeing.*`, off by default): `park-tabs` on every tab of the run's
        workspaces. The shells end, the tabs stay (dead, `relaunch.on_show`); non-terminal tabs are left as they
        are. Headless cmux-tui has no app, so without this no shell is ever freed here."""
        if not self.args.park_idle or not self.workspaces:
            return
        tui = Tui(self.tui_sock, timeout=300)
        try:
            ours = set(self.workspaces)
            surfaces = [tab["surface"] for w in tui.call("list-workspaces").get("workspaces", []) if w.get("id") in ours
                        for screen in w.get("screens", []) for pane in screen.get("panes", [])
                        for tab in pane.get("tabs", []) if not tab.get("dead") and tab.get("surface") is not None]
            parked = []
            for start in range(0, len(surfaces), 200):
                parked += tui.call("park-tabs", surfaces=surfaces[start:start + 200]).get("parked", [])
            self.parked = getattr(self, "parked", 0) + len(parked)
            log(f"N={self.count} park-tabs: {len(parked)} of {len(surfaces)} tabs parked")
        except (OSError, RuntimeError, ValueError) as exc:
            self.error("park-tabs", exc)
        finally:
            tui.close()

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
                    tui.call("select-workspace", index=self.workspace_index[rnd.choice(self.workspaces)])
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
        self.park_idle()
        if a.sleep > 0:
            # Sleep/wake: every process of both trees stopped, then continued (the clock moves on).
            pids = tree_pids([self.top["acpmux"], self.top["tui"]])
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGSTOP)
                except ProcessLookupError:
                    pass
            time.sleep(a.sleep)  # sleep-ok: the simulated machine sleep, its length is the scenario
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


ROWS = []  # every PERF_ROW, printed again at the end as one {"rows": [...]} report (perf-cron's Linux part reads it)


def perf_row(name, value, unit, floor=None):
    row = {"name": name, "p50": round(value, 4), "p95": round(value, 4), "unit": unit}
    if floor is not None:
        row["floor"] = floor
    ROWS.append(row)
    print("PERF_ROW " + json.dumps(row), flush=True)


# A ratio's denominator is at least its noise floor: an empty pair at 0.00 % CPU or 0 wakeups is no division by 0.
CPU_FLOOR_PCT, WAKEUPS_FLOOR = 0.1, 1.0


def settle(args, top):
    # Past the (fast-forwarded) idle and reap timers, so idle agents have hibernated and closed terminals ended.
    # sleep-ok: the product's own timers have to run out; nothing can make them fire sooner
    time.sleep(max(args.idle_child_secs, args.reap_grace_secs))
    # Then their work: the trees' processes per role (the hibernated agents gone, the reaped terminals' shells gone)
    # hold for --settle s. Bounded: past 6x --settle (at least 30 s) the window is sampled as it is, and logged.
    roles = lambda: sorted((s["role"], s["cmd"]) for s in snapshot(top).values())
    reads = max(2, int(args.settle / 0.25))
    bound = max(30.0, 6 * args.settle)
    deadline, last, same = time.monotonic() + bound, None, 0
    while True:
        now = roles()
        same = same + 1 if now == last else 1
        last = now
        if same >= reads:
            return
        if time.monotonic() >= deadline:
            log(f"settle: the process trees did not hold still for {args.settle} s within {bound:g} s; sampling anyway")
            return
        time.sleep(0.25)  # the poll interval of the process trees


def dhat_mark(day):
    """--dhat-mark-days: a dhat-heap cmux-tui (CMUX_TUI_DHAT_OUT, CMUX_TUI_DHAT_MARKS; heap_profile.rs) ends its
    heap window here: it writes the window to <out>.<n> and removes the mark once written."""
    out = os.environ.get("CMUX_TUI_DHAT_OUT")
    if not out:
        log("dhat mark: CMUX_TUI_DHAT_OUT is not set; no window ended")
        return
    mark = os.path.splitext(out)[0] + ".mark"
    open(mark, "w").close()
    deadline = time.monotonic() + 900
    while os.path.exists(mark) and time.monotonic() < deadline:
        time.sleep(1)  # the poll of the daemon's window write (bench only, bounded)
    log(f"dhat mark: day {day} window {'written' if not os.path.exists(mark) else 'NOT written in 900 s'}")


def run_count(args, count):
    run = Run(args, count)
    result = {"count": count, "samples": []}
    try:
        run.start()
        if args.heap_profile_at:
            # A dhat-heap acpmux records slowly (job 0ce0131a: 1,000 chats not open after 28 min): past the
            # deadline it writes what it holds so far rather than nothing when the job's cap kills it.
            timer = threading.Timer(max(0.0, args.heap_profile_at - time.time()), run.heap_profile)
            timer.daemon = True
            timer.start()
        settle(args, run.top)
        empty = idle_window(run.top, args.window, run.disks)
        result["empty"] = empty
        log(f"N={count} empty {json.dumps(empty['total'])}")
        t0 = time.monotonic()
        run.open_items()
        result["open_seconds"] = round(time.monotonic() - t0, 1)
        result["mix"] = {"chats": len([s for s in run.sessions if s]), "archived": len(run.archived),
                         "working": len(run.working), "drawn": len(run.drawn), "idle": len(run.idle),
                         "chat_tabs": len(run.chat_tabs), "browser_tabs": len(run.browser_tabs),
                         "workspaces": len(run.workspaces)}
        settle(args, run.top)
        day0 = idle_window(run.top, args.window, run.disks)
        day0["day"] = 0
        result["samples"].append(day0)
        log(f"N={count} opened in {result['open_seconds']} s {json.dumps(result['mix'])}: {json.dumps(day0['total'])}")
        if 0 in args.dhat_mark_days:
            dhat_mark(0)
        for number in range(1, args.days + 1):
            t0 = time.monotonic()
            turns = run.day(number)
            spent = round(time.monotonic() - t0, 1)
            settle(args, run.top)
            s = idle_window(run.top, args.window, run.disks)
            s.update(day=number, turns=turns, seconds=spent)
            result["samples"].append(s)
            log(f"N={count} day {number} ({spent} s, {turns} turns): {json.dumps(s['total'])}")
            if number in args.dhat_mark_days:
                dhat_mark(number)
        if args.open_probe > 0:
            result["open_ms"] = run.open_probe(args.open_probe)
        if args.heap_profile:
            run.heap_profile()
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
        ratio = lambda a, b, floor=0.01: a / max(b, floor)  # noqa: E731
        days = [s["day"] for s in r["samples"]]
        mb_day = slope(days, [s["total"]["pss_mb"] for s in r["samples"]])
        disk_day = slope(days, [s["total"]["disk_mb"] for s in r["samples"]])
        per_role = {}
        for role, v in last["roles"].items():
            base = r["empty"]["roles"].get(role, {}).get("pss_mb", 0)
            per_role[role] = (v["pss_mb"] - base) / n
        steep = max(per_role.items(), key=lambda kv: kv[1]) if per_role else ("-", 0)
        print(f"INFINITE {n} | {t['pss_mb']:.1f} | {ratio(t['pss_mb'], e['pss_mb']):.2f}x | "
              f"{(t['pss_mb'] - e['pss_mb']) / n:.3f} | {t['cpu_pct']:.2f} | {ratio(t['cpu_pct'], e['cpu_pct'], CPU_FLOOR_PCT):.2f}x | "
              f"{t['wakeups_per_s']:.1f} | {ratio(t['wakeups_per_s'], e['wakeups_per_s'], WAKEUPS_FLOOR):.2f}x | {t['fds']} | "
              f"{t['disk_mb']:.2f} | {mb_day:+.2f} | {disk_day:+.3f} | {steep[0]} {steep[1]:.3f}", flush=True)
        print(f"INFINITE-EMPTY {n} {json.dumps(e)}", flush=True)
        for s in r["samples"]:
            t_ = s["total"]
            print(f"INFINITE-DAY {n} day={s['day']} mb={t_['pss_mb']} cpu={t_['cpu_pct']} wk={t_['wakeups_per_s']} "
                  f"procs={t_['procs']} thr={t_.get('threads')} fds={t_['fds']} disk={json.dumps(s['disk'])}", flush=True)
            for k, v in (sorted(s["roles"].items()) if s is r["samples"][0] or s is r["samples"][-1] else []):
                top_cmds = sorted(v.get("cmds", {}).items(), key=lambda kv: -kv[1])[:2]
                print(f"INFINITE-ROLE {n} day={s['day']} {k} n={v['count']} thr={v.get('threads')} mb={v['pss_mb']} "
                      f"cpu={v['cpu_pct']} "
                      f"wk={v['wakeups_per_s']} fds={v['fds']} cmd={top_cmds} one_kb={v.get('smaps_kb', {})} "
                      f"woke={json.dumps(v.get('thread_wakeups', {}))} named={json.dumps(v.get('thread_names', {}))}",
                      flush=True)
        grown = r["samples"][1:]
        if grown:
            # The slope over the days after creation (day 0 holds what the open made), per file group.
            keys = set().union(*(s.get("files", {}) for s in grown))
            rates = {k: slope([s["day"] for s in grown], [s.get("files", {}).get(k, 0) / 1048576 for s in grown])
                     for k in keys} if len(grown) > 1 else {}
            for k, rate in sorted(rates.items(), key=lambda kv: -kv[1])[:12]:
                if rate > 0:
                    print(f"INFINITE-DISKGROW {n} {rate:+.3f} MB/day {grown[-1]['files'].get(k, 0) / 1048576:.2f} MB {k}",
                          flush=True)
        if r.get("errors"):
            print(f"INFINITE-ERRORS {n} {json.dumps(r['errors'])}", flush=True)
        # A row is never negative (perf-cron and NOW read a negative number as none): a shrinking day is 0 growth.
        perf_row(f"infinite_items.n{n}.memory_vs_empty", ratio(t["pss_mb"], e["pss_mb"]), "x", floor=0.1)
        perf_row(f"infinite_items.n{n}.mb_per_item", max(0.0, (t["pss_mb"] - e["pss_mb"]) / n), "MB", floor=0.1)
        perf_row(f"infinite_items.n{n}.cpu_idle_pct", t["cpu_pct"], "pct", floor=CPU_FLOOR_PCT)
        perf_row(f"infinite_items.n{n}.cpu_idle_vs_empty", ratio(t["cpu_pct"], e["cpu_pct"], CPU_FLOOR_PCT), "x", floor=0.5)
        perf_row(f"infinite_items.n{n}.wakeups_per_s", t["wakeups_per_s"], "count", floor=WAKEUPS_FLOOR)
        perf_row(f"infinite_items.n{n}.mb_per_day", max(0.0, mb_day), "MB", floor=1.0)
        perf_row(f"infinite_items.n{n}.disk_mb_per_day", max(0.0, disk_day), "MB", floor=0.1)
    per_item(results)
    print(json.dumps({"rows": ROWS}), flush=True)


def per_item(results):
    """Each role at each N, at the last sample: what a process kind costs per item (the process-sharing table)."""
    model = ARGS.terminal_host_model if ARGS else "-"
    print("INFINITE-PERITEM model | n | role | procs | threads | MB (PSS) | MB/item over empty | wakeups/s")
    for r in results:
        if "empty" not in r or not r["samples"]:
            continue
        n, last, empty = r["count"], r["samples"][-1]["roles"], r["empty"]["roles"]
        for role in sorted(set(last) | set(empty)):
            v, base = last.get(role, {}), empty.get(role, {})
            print(f"INFINITE-PERITEM {model} | {n} | {role} | {v.get('count', 0)} | {v.get('threads', 0)} | "
                  f"{v.get('pss_mb', 0):.2f} | {(v.get('pss_mb', 0) - base.get('pss_mb', 0)) / n:.3f} | "
                  f"{v.get('wakeups_per_s', 0):.1f}", flush=True)


ARGS = None  # the parsed arguments, for the report's labels


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
    p.add_argument("--reap-grace-secs", type=int, default=5,
                   help="cmux-tui --terminal-reap-grace-seconds (the app's owner: 30)")
    p.add_argument("--evict-idle-secs", type=int, default=None,
                   help="ACPMUX_EVICT_IDLE_SECS: evict chats idle this long to a compact row (off when unset)")
    p.add_argument("--resident-cap", type=int, default=0,
                   help="ACPMUX_RESIDENT_CAP: keep at most this many chats in memory, the least recently used "
                        "evicted past it (off when 0)")
    p.add_argument("--open-probe", type=int, default=0,
                   help="after the last day, time opening (attach) this many idle chats; prints INFINITE-OPEN")
    p.add_argument("--settle", type=float, default=5)
    p.add_argument("--window", type=float, default=10, help="idle window seconds per sample")
    p.add_argument("--sleep", type=float, default=3, help="simulated sleep a day (SIGSTOP), seconds")
    p.add_argument("--root-dir", default=None)
    p.add_argument("--keep", action="store_true")
    p.add_argument("--acpmux-log", default="warn", help="acpmux --log; at info, its hibernations are summarized")
    p.add_argument("--terminal-host-model", choices=("product", "hosts", "holder"), default="product",
                   help="product: the build's default (a host per terminal; the holder is off by default); hosts: "
                        "CMUX_TUI_TERMINAL_HOST_MODEL=hosts, a terminal host per terminal; holder: "
                        "CMUX_TUI_TERMINAL_HOST_MODEL=holder, one holder process for every terminal")
    p.add_argument("--agent-holder", choices=("off", "on"), default="on",
                   help="on (the product default): ACPMUX_AGENT_HOLDER=1, the daemon keeps a copy of each harness's stdio and "
                        "replaces a host that dies (acpmux agent_host/custody.rs)")
    p.add_argument("--browser-tabs", action="store_true", help="a browser tab in each workspace too (model only)")
    p.add_argument("--park-idle", action="store_true",
                   help="park every tab of the run's workspaces after the open and each day (park-tabs), as the app's "
                        "freeing tier does to hibernated workspaces when workspaces.freeing is on (off by default)")
    p.add_argument("--dhat-mark-days", default="",
                   help="days after whose sample a dhat-heap cmux-tui ends a heap window (comma list; heap_profile.rs)")
    p.add_argument("--heap-profile", action="store_true",
                   help="after the last sample, ask a dhat-heap acpmux to write its profile (_acpmux/heap_profile)")
    p.add_argument("--heap-profile-at", type=float, default=0.0,
                   help="a Unix time at which to ask for the heap profile even if the run has not ended (dhat is slow)")
    p.add_argument("--out")
    args = p.parse_args()
    args.dhat_mark_days = sorted({int(d) for d in args.dhat_mark_days.split(",") if d})
    global ARGS
    ARGS = args
    for path in (args.acpmux, args.tui):
        if not os.access(path, os.X_OK):
            raise SystemExit(f"infinite-items: not executable: {path}")
    # FAKE_AGENT is found from this file's own path: a copy run from elsewhere would make no chats and still report.
    if not os.path.isfile(FAKE_AGENT):
        raise SystemExit(f"infinite-items: no stand-in agent at {FAKE_AGENT}; run this script from its checkout")
    print(f"INFINITE-MACHINE host={platform.node()} platform={platform.platform()} cpus={os.cpu_count()} "
          f"counts={args.counts} days={args.days} terminal_host_model={args.terminal_host_model} agent_holder={args.agent_holder} "
          f"browser_tabs={int(args.browser_tabs)} park_idle={int(args.park_idle)}", flush=True)
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
