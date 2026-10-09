#!/usr/bin/env python3
"""Terminal scale benchmark for cmux-tui (cx scale lane).

Starts one isolated headless daemon, ramps it to N terminals (idle shells
plus a fraction with steady output), and at each step records, per process
role (daemon, terminal host, child):

- memory: RSS and PSS (Linux smaps_rollup) or RSS and physical footprint
  (macOS proc_pid_rusage), plus system memory deltas (Linux /proc/meminfo:
  MemAvailable, Slab, KernelStack, PageTables);
- threads, open fds and (Linux) the fd table size (FDSize);
- CPU time and wakeups (Linux context switches summed over threads, macOS
  package-idle + interrupt wakeups) over an idle window;
- input echo latency p50/p99: time from a `send` on the control socket to
  the echoed bytes on an `attach-surface` stream of an idle terminal;
- terminal creation throughput.

It stops at the first hard failure (a creation error, a crashed daemon, a
guard limit) and records it. Teardown ends every terminal through the
daemon (`shutdown-daemon` with `end_terminals`); it never signals a
terminal host. Measurement only: it scans /proc (Linux) or libproc
(macOS) for this daemon's own process tree.

Usage:
  bench-scale.py --bin target/release/cmux-tui --counts 100,1000,5000,10000 \
      --busy-fraction 0.05 --out result.json
"""

import argparse
import base64
import concurrent.futures
import ctypes
import ctypes.util
import json
import math
import os
import platform
import random
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time

IS_LINUX = sys.platform.startswith("linux")
IS_MAC = sys.platform == "darwin"


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- socket I/O


class Conn:
    """One JSON-lines control connection."""

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

    def send_line(self, obj):
        self.sock.sendall((json.dumps(obj) + "\n").encode())

    def read_line(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise ConnectionError("control socket closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def call(self, cmd, **params):
        rid = self.next_id
        self.next_id += 1
        self.send_line({"id": rid, "cmd": cmd, **params})
        while True:
            msg = self.read_line()
            if msg.get("id") == rid and "ok" in msg:
                return msg


def must(resp, what):
    if not resp.get("ok"):
        raise RuntimeError(f"{what} failed: {resp.get('error')!r} {resp.get('error_code', '')}")
    return resp.get("data") or {}


# ---------------------------------------------------------- process sampling


class LinuxProcs:
    clk = os.sysconf("SC_CLK_TCK")
    page = os.sysconf("SC_PAGE_SIZE")

    @staticmethod
    def children_map():
        kids = {}
        for name in os.listdir("/proc"):
            if not name.isdigit():
                continue
            try:
                with open(f"/proc/{name}/stat", "rb") as f:
                    data = f.read()
            except OSError:
                continue
            rest = data[data.rfind(b")") + 2 :].split()
            kids.setdefault(int(rest[1]), []).append(int(name))
        return kids

    def sample(self, pid, detail):
        out = {}
        try:
            with open(f"/proc/{pid}/stat", "rb") as f:
                data = f.read()
            rest = data[data.rfind(b")") + 2 :].split()
            out["cpu_s"] = (int(rest[11]) + int(rest[12])) / self.clk
            out["threads"] = int(rest[17])
            out["rss"] = int(rest[21]) * self.page
            with open(f"/proc/{pid}/status") as f:
                for line in f:
                    if line.startswith("FDSize:"):
                        out["fdsize"] = int(line.split()[1])
            out["fds"] = len(os.listdir(f"/proc/{pid}/fd"))
            if detail:
                with open(f"/proc/{pid}/smaps_rollup") as f:
                    for line in f:
                        if line.startswith("Pss:"):
                            out["pss"] = int(line.split()[1]) * 1024
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
        except (OSError, ValueError, IndexError):
            return None
        return out

    @staticmethod
    def system():
        info = {}
        with open("/proc/meminfo") as f:
            for line in f:
                key, value = line.split(":", 1)
                if key in ("MemTotal", "MemAvailable", "Slab", "SUnreclaim", "KernelStack", "PageTables", "Shmem"):
                    info[key] = int(value.split()[0]) * 1024
        return info

    @staticmethod
    def limits():
        out = {}
        for key, path in [
            ("pty_max", "/proc/sys/kernel/pty/max"),
            ("pty_nr", "/proc/sys/kernel/pty/nr"),
            ("pid_max", "/proc/sys/kernel/pid_max"),
            ("threads_max", "/proc/sys/kernel/threads-max"),
            ("file_max", "/proc/sys/fs/file-max"),
            ("max_map_count", "/proc/sys/vm/max_map_count"),
        ]:
            try:
                out[key] = int(open(path).read().split()[0])
            except OSError:
                pass
        return out


class MacProcs:
    PROC_PIDTASKINFO = 4
    PROC_PIDLISTFDS = 1

    class TaskInfo(ctypes.Structure):
        _fields_ = [
            ("virtual_size", ctypes.c_uint64),
            ("resident_size", ctypes.c_uint64),
            ("total_user", ctypes.c_uint64),
            ("total_system", ctypes.c_uint64),
            ("threads_user", ctypes.c_uint64),
            ("threads_system", ctypes.c_uint64),
            ("policy", ctypes.c_int32),
            ("faults", ctypes.c_int32),
            ("pageins", ctypes.c_int32),
            ("cow_faults", ctypes.c_int32),
            ("messages_sent", ctypes.c_int32),
            ("messages_received", ctypes.c_int32),
            ("syscalls_mach", ctypes.c_int32),
            ("syscalls_unix", ctypes.c_int32),
            ("csw", ctypes.c_int32),
            ("threadnum", ctypes.c_int32),
            ("numrunning", ctypes.c_int32),
            ("priority", ctypes.c_int32),
        ]

    class RUsageV2(ctypes.Structure):
        _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
            (name, ctypes.c_uint64)
            for name in (
                "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups",
                "pageins", "wired_size", "resident_size", "phys_footprint",
                "proc_start_abstime", "proc_exit_abstime", "child_user_time",
                "child_system_time", "child_pkg_idle_wkups", "child_interrupt_wkups",
                "child_pageins", "child_elapsed_abstime", "diskio_bytesread",
                "diskio_byteswritten",
            )
        ]

    class Timebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

    def __init__(self):
        self.lib = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib", use_errno=True)
        libc = ctypes.CDLL(None)
        tb = self.Timebase()
        libc.mach_timebase_info(ctypes.byref(tb))
        self.ns_per_tick = tb.numer / tb.denom

    def children(self, pid):
        buf = (ctypes.c_int * 65536)()
        n = self.lib.proc_listchildpids(pid, buf, ctypes.sizeof(buf))
        if n <= 0:
            return []
        # Returns a count of pids on current macOS (bytes on some older ones).
        count = n if n <= 65536 else n // ctypes.sizeof(ctypes.c_int)
        return [buf[i] for i in range(count) if buf[i] > 0]

    def sample(self, pid, detail):
        ti = self.TaskInfo()
        if self.lib.proc_pidinfo(pid, self.PROC_PIDTASKINFO, 0, ctypes.byref(ti), ctypes.sizeof(ti)) <= 0:
            return None
        ru = self.RUsageV2()
        if self.lib.proc_pid_rusage(pid, 2, ctypes.byref(ru)) != 0:
            return None
        fd_bytes = self.lib.proc_pidinfo(pid, self.PROC_PIDLISTFDS, 0, None, 0)
        fds = None
        if fd_bytes > 0:
            buf = ctypes.create_string_buffer(fd_bytes + 8 * 64)
            used = self.lib.proc_pidinfo(pid, self.PROC_PIDLISTFDS, 0, buf, len(buf))
            fds = used // 8 if used > 0 else None
        return {
            "cpu_s": (ru.user_time + ru.system_time) * self.ns_per_tick / 1e9,
            "threads": ti.threadnum,
            "rss": ru.resident_size,
            "pss": ru.phys_footprint,  # macOS footprint, the Activity Monitor figure
            "fds": fds,
            "wakeups": ru.pkg_idle_wkups + ru.interrupt_wkups,
        }

    @staticmethod
    def sysctl(name):
        try:
            return int(subprocess.check_output(["sysctl", "-n", name], text=True).strip())
        except (subprocess.CalledProcessError, ValueError):
            return None

    def system(self):
        out = subprocess.check_output(["vm_stat"], text=True)
        page = 16384
        info = {}
        for line in out.splitlines():
            if "page size of" in line:
                page = int(line.split("page size of")[1].split()[0])
            elif ":" in line:
                key, value = line.split(":", 1)
                value = value.strip().rstrip(".")
                if value.isdigit():
                    info[key.strip()] = int(value) * page
        return {
            "free": info.get("Pages free", 0),
            "wired": info.get("Pages wired down", 0),
            "compressor": info.get("Pages occupied by compressor", 0),
        }

    def limits(self):
        return {
            "ptmx_max": self.sysctl("kern.tty.ptmx_max"),
            "maxproc": self.sysctl("kern.maxproc"),
            "maxprocperuid": self.sysctl("kern.maxprocperuid"),
            "maxfiles": self.sysctl("kern.maxfiles"),
            "maxfilesperproc": self.sysctl("kern.maxfilesperproc"),
        }


def user_process_count():
    out = subprocess.check_output(["ps", "-U", str(os.getuid()), "-o", "pid="], text=True)
    return len(out.split())


def pty_in_use_mac():
    return len([n for n in os.listdir("/dev") if n.startswith("ttys") and n[4:].isdigit()])


# ------------------------------------------------------------------ benchmark


class Bench:
    def __init__(self, args):
        self.args = args
        self.procs = LinuxProcs() if IS_LINUX else MacProcs()
        self.root = tempfile.mkdtemp(prefix="cxs-", dir=args.root_dir)
        self.sock_path = os.path.join(self.root, "s.sock")
        self.session = f"scale{os.getpid()}"
        self.daemon = None
        self.terminals = []  # list of dicts: surface, busy
        self.workspaces = []
        self.result = {
            "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "platform": platform.platform(),
            "machine": platform.machine(),
            "cpus": os.cpu_count(),
            "args": vars(args),
            "limits_before": self.procs.limits(),
            "rlimit_nofile": None,
            "steps": [],
            "stopped": None,
        }
        try:
            import resource

            self.result["rlimit_nofile"] = resource.getrlimit(resource.RLIMIT_NOFILE)
            self.result["rlimit_nproc"] = resource.getrlimit(resource.RLIMIT_NPROC)
        except Exception:
            pass

    # -- daemon lifecycle

    def start(self):
        home = os.path.join(self.root, "home")
        state = os.path.join(self.root, "state")
        os.makedirs(home, exist_ok=True)
        os.makedirs(state, exist_ok=True)
        env = dict(os.environ)
        env.update(
            HOME=home,
            XDG_CONFIG_HOME=os.path.join(home, ".config"),
            XDG_STATE_HOME=os.path.join(home, ".local/state"),
            XDG_DATA_HOME=os.path.join(home, ".local/share"),
            XDG_CACHE_HOME=os.path.join(home, ".cache"),
            CMUX_TUI_CONFIG=os.path.join(self.root, "config.json"),
        )
        argv = [self.args.bin, "--headless", "--session", self.session, "--socket", self.sock_path]
        if self.args.mode == "ephemeral":
            argv.append("--ephemeral")
        else:
            argv += ["--state", state]
        self.daemon_log = open(os.path.join(self.root, "daemon.log"), "a")
        self.daemon = subprocess.Popen(argv, stdout=self.daemon_log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        deadline = time.time() + 30
        while time.time() < deadline:
            if self.daemon.poll() is not None:
                raise RuntimeError(f"daemon exited {self.daemon.returncode}: {self.tail_log()}")
            if os.path.exists(self.sock_path):
                try:
                    c = Conn(self.sock_path)
                    self.ident = must(c.call("identify"), "identify")
                    c.close()
                    break
                except OSError:
                    pass
            time.sleep(0.1)
        else:
            raise RuntimeError("daemon socket never appeared: " + self.tail_log())
        self.result["daemon"] = {"pid": self.daemon.pid, "version": self.ident.get("version"), "protocol": self.ident.get("protocol")}
        log("daemon up pid", self.daemon.pid, self.ident.get("version"))

    def tail_log(self):
        try:
            self.daemon_log.flush()
            with open(os.path.join(self.root, "daemon.log")) as f:
                return f.read()[-3000:]
        except OSError:
            return ""

    def stop(self):
        if not self.daemon:
            return
        if self.daemon.poll() is not None and self.args.mode == "durable":
            # The daemon died; its durable hosts outlive it. A replacement
            # daemon on the same state adopts them, then ends them below.
            log("daemon exited", self.daemon.returncode, "- starting a replacement to end its terminals")
            self.result["daemon_exit"] = {"returncode": self.daemon.returncode, "log_tail": self.tail_log()[-1500:]}
            try:
                if os.path.exists(self.sock_path):
                    os.unlink(self.sock_path)
                self.start()
                time.sleep(5)
            except Exception as e:  # noqa: BLE001
                self.result["teardown"] = {"ok": False, "error": f"replacement daemon: {e!r}"}
                return
        log("teardown: shutdown-daemon end_terminals")
        t0 = time.time()
        try:
            c = Conn(self.sock_path, timeout=max(600, len(self.terminals) / 5))
            ident = must(c.call("identify"), "identify")
            resp = c.call(
                "shutdown-daemon",
                pid=ident["pid"],
                generation=ident.get("generation") or ident.get("boot_generation") or "",
                end_terminals=True,
            )
            self.result["teardown"] = {"ok": resp.get("ok"), "error": resp.get("error"), "data": resp.get("data"), "seconds": None}
            c.close()
        except Exception as e:  # noqa: BLE001
            self.result["teardown"] = {"ok": False, "error": repr(e)}
        try:
            self.daemon.wait(timeout=max(120, len(self.terminals) / 20))
        except subprocess.TimeoutExpired:
            self.result["teardown"]["daemon_still_running"] = True
            log("WARNING daemon still running after shutdown; pid", self.daemon.pid)
        self.result["teardown"]["seconds"] = round(time.time() - t0, 2)
        left = self.tree()
        self.result["teardown"]["leftover_hosts"] = len(left["hosts"])
        log("teardown done", self.result["teardown"])

    # -- process tree

    def tree(self):
        """daemon pid, its terminal hosts (or none in ephemeral mode), children."""
        dpid = self.daemon.pid
        if IS_LINUX:
            kids = LinuxProcs.children_map()
            children = lambda p: kids.get(p, [])  # noqa: E731
        else:
            children = self.procs.children
        hosts, shells = [], []
        for c in children(dpid):
            grand = children(c)
            if self.args.mode == "ephemeral":
                shells.append(c)
            elif self.is_host(c):
                hosts.append(c)
                shells.extend(grand)
            else:
                shells.append(c)  # e.g. helper processes
        return {"daemon": [dpid], "hosts": hosts, "shells": shells}

    def is_host(self, pid):
        if IS_LINUX:
            try:
                return b"__terminal-host" in open(f"/proc/{pid}/cmdline", "rb").read()
            except OSError:
                return False
        try:
            out = subprocess.check_output(["ps", "-o", "command=", "-p", str(pid)], text=True)
            return "__terminal-host" in out
        except subprocess.CalledProcessError:
            return False

    def snapshot(self, detail=True):
        tree = self.tree()
        busy_shells = set()
        snap = {}
        for role, pids in tree.items():
            rows = []
            for pid in pids:
                s = self.procs.sample(pid, detail)
                if s:
                    s["pid"] = pid
                    rows.append(s)
            snap[role] = rows
        return snap

    @staticmethod
    def totals(rows):
        keys = ("rss", "pss", "threads", "fds", "fdsize", "cpu_s", "wakeups")
        out = {"count": len(rows)}
        for k in keys:
            vals = [r[k] for r in rows if r.get(k) is not None]
            if vals:
                out[k] = sum(vals)
                if k in ("rss", "pss", "threads", "fds", "fdsize"):
                    out[k + "_per"] = sum(vals) / len(vals)
                    out[k + "_max"] = max(vals)
        return out

    # -- creation

    def setup_workspaces(self, total):
        per = self.args.per_workspace
        want = max(1, math.ceil(total / per))
        c = Conn(self.sock_path)
        for i in range(want):
            data = must(c.call("new-workspace", name=f"w{i}", cols=80, rows=24), "new-workspace")
            self.terminals.append({"surface": data["surface"], "busy": False})
        tree = must(c.call("list-workspaces"), "list-workspaces")
        c.close()
        self.workspaces = [w["id"] for w in tree["workspaces"]][-want:]
        log("workspaces", len(self.workspaces))

    def busy_argv(self):
        rate = self.args.busy_rate
        line = "x" * max(1, self.args.busy_line_bytes - 20)
        return [
            "perl",
            "-e",
            f'$|=1; my $n=0; while (1) {{ print "busy ", $n++, " {line}\\n"; select(undef,undef,undef,{1.0 / rate:.4f}); }}',
        ]

    def raw_stats(self):
        """server-stats with the resource projection section, or None."""
        try:
            c = Conn(self.sock_path, timeout=30)
            st = c.call("server-stats", include=["resource_projection"])
            c.close()
            return st.get("data") if st.get("ok") else None
        except Exception:  # noqa: BLE001
            return None

    @staticmethod
    def stats_window(pre, post):
        """Per-window means from two cumulative server-stats reads: each
        projection span and each registry hold site, as count and mean."""
        if not pre or not post:
            return None

        def delta(a, b):
            a, b = a or {}, b or {}
            n = (b.get("count") or 0) - (a.get("count") or 0)
            total = (b.get("count") or 0) * (b.get("mean") or 0) - (a.get("count") or 0) * (a.get("mean") or 0)
            return {"count": n, "mean": round(total / n, 1) if n > 0 else None, "max_cumulative": b.get("max")}

        out = {}
        rp0, rp1 = pre.get("resource_projection") or {}, post.get("resource_projection") or {}
        for key, value in rp1.items():
            if isinstance(value, dict):
                out[key] = delta(rp0.get(key), value)
        sites0 = {s["site"]: s for s in (pre.get("registry_lock") or {}).get("top_sites") or []}
        holds = []
        for site in (post.get("registry_lock") or {}).get("top_sites") or []:
            before = sites0.get(site["site"], {})
            n = site.get("acquisitions", 0) - before.get("acquisitions", 0)
            total = site.get("hold_total_us", 0) - before.get("hold_total_us", 0)
            if n > 0:
                holds.append({"site": site["site"], "holds": n, "hold_total_us": total, "hold_mean_us": round(total / n, 1)})
        out["registry_holds"] = sorted(holds, key=lambda x: -x["hold_total_us"])[:8]
        wl0 = (pre.get("registry_lock") or {}).get("wait_us")
        out["registry_wait"] = delta(wl0, (post.get("registry_lock") or {}).get("wait_us"))
        return out

    def create_terminals(self, count):
        """Create `count` terminals; returns (created, error)."""
        if count <= 0:
            return 0, None
        busy_every = int(round(1 / self.args.busy_fraction)) if self.args.busy_fraction > 0 else 0
        base = len(self.terminals)
        lock = threading.Lock()
        error = []
        created = []
        idx_iter = iter(range(base, base + count))

        def worker():
            try:
                c = Conn(self.sock_path, timeout=120)
            except OSError as e:
                error.append(f"connect: {e}")
                return
            while not error:
                with lock:
                    i = next(idx_iter, None)
                if i is None:
                    break
                busy = busy_every > 0 and i % busy_every == 0
                argv = self.busy_argv() if busy else list(self.args.shell)
                ws = self.workspaces[i % len(self.workspaces)]
                try:
                    resp = c.call("create-terminal", workspace=ws, argv=argv, cols=80, rows=24)
                except Exception as e:  # noqa: BLE001
                    error.append(f"terminal {i}: {e!r}")
                    break
                if not resp.get("ok"):
                    error.append(f"terminal {i}: {resp.get('error')!r} {resp.get('error_code', '')}")
                    break
                with lock:
                    created.append({"surface": resp["data"].get("surface"), "busy": busy})
            c.close()

        threads = [threading.Thread(target=worker) for _ in range(self.args.create_concurrency)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.terminals.extend(created)
        return len(created), (error[0] if error else None)

    # -- latency

    def echo_latency(self, samples):
        idle = [t["surface"] for t in self.terminals if not t["busy"] and t["surface"] is not None]
        if not idle:
            return None
        random.seed(len(idle))
        chosen = random.sample(idle, min(len(idle), self.args.latency_terminals))
        ctl = Conn(self.sock_path)
        lat = []
        errors = 0
        per = max(1, samples // len(chosen))
        for surface in chosen:
            att = Conn(self.sock_path, timeout=10)
            try:
                att.send_line({"id": 1, "cmd": "attach-surface", "surface": surface, "cols": 80, "rows": 24})
                # Drain until the response; vt-state arrives first.
                while True:
                    m = att.read_line()
                    if m.get("id") == 1:
                        if not m.get("ok"):
                            raise RuntimeError(m.get("error"))
                        break
                for k in range(per):
                    marker = f"q{random.randrange(10**8, 10**9)}"
                    t0 = time.perf_counter()
                    must(ctl.call("send", surface=surface, text=marker), "send")
                    got = b""
                    deadline = time.time() + 5
                    while time.time() < deadline:
                        m = att.read_line()
                        if m.get("event") == "output" and m.get("surface") == surface:
                            got += base64.b64decode(m.get("data", ""))
                            if marker.encode() in got:
                                lat.append((time.perf_counter() - t0) * 1000)
                                break
                    else:
                        errors += 1
                    ctl.call("send", surface=surface, text="\x15")  # Ctrl-U clears the line
                    time.sleep(0.02)
            except Exception as e:  # noqa: BLE001
                errors += 1
                log("latency sample error", surface, repr(e))
            finally:
                att.close()
        ctl.close()
        if not lat:
            return {"samples": 0, "errors": errors}
        lat.sort()
        q = lambda p: lat[min(len(lat) - 1, int(p * len(lat)))]  # noqa: E731
        return {"samples": len(lat), "errors": errors, "p50_ms": round(q(0.50), 3), "p90_ms": round(q(0.90), 3), "p99_ms": round(q(0.99), 3), "max_ms": round(lat[-1], 3)}

    # -- guard

    def guard(self, target):
        """Refuse a step that would exhaust shared per-user or system limits (macOS)."""
        if not IS_MAC:
            return None
        lim = self.result["limits_before"]
        add = target - len(self.terminals)
        procs_per = 1 if self.args.mode == "ephemeral" else 2
        users = user_process_count()
        if lim.get("maxprocperuid") and users + add * procs_per + 300 > lim["maxprocperuid"] * 0.8:
            return f"guard: {users} user processes + {add * procs_per} new would pass 80% of kern.maxprocperuid={lim['maxprocperuid']}"
        if lim.get("ptmx_max"):
            used = pty_in_use_mac()
            if used + add + 64 > lim["ptmx_max"]:
                return f"guard: {used} ptys in use + {add} new would pass kern.tty.ptmx_max={lim['ptmx_max']} (minus 64 margin)"
        return None

    # -- run

    def run(self):
        counts = sorted(int(x) for x in self.args.counts.split(","))
        sys0 = self.procs.system()
        self.result["system_baseline"] = sys0
        self.start()
        time.sleep(1)
        base_snap = self.snapshot()
        self.result["daemon_baseline"] = self.totals(base_snap["daemon"])
        self.setup_workspaces(counts[-1])
        for target in counts:
            why = self.guard(target)
            if why:
                self.result["stopped"] = {"at": target, "reason": why}
                log(why)
                break
            need = target - len(self.terminals)
            log(f"step {target}: creating {need}")
            pre = self.raw_stats()
            t0 = time.time()
            made, err = self.create_terminals(need)
            create_s = time.time() - t0
            step = {"target": target, "created": made, "create_seconds": round(create_s, 2), "create_rate_per_s": round(made / create_s, 1) if create_s > 0 else None, "terminals": len(self.terminals)}
            step["create_window"] = self.stats_window(pre, self.raw_stats())
            if err:
                step["error"] = err
                log("creation stopped:", err)
            if self.daemon.poll() is not None:
                step["error"] = f"daemon exited {self.daemon.returncode}: {self.tail_log()[-800:]}"
            # Settle: wait until host count reaches the terminal count (durable mode).
            settle_deadline = time.time() + self.args.settle_seconds
            while time.time() < settle_deadline:
                tr = self.tree()
                if self.args.mode == "ephemeral" or len(tr["hosts"]) >= len(self.terminals):
                    break
                time.sleep(1)
            time.sleep(self.args.settle_seconds_min)
            a = self.snapshot(detail=True)
            sa = self.procs.system()
            ta = time.time()
            time.sleep(self.args.idle_seconds)
            b = self.snapshot(detail=True)
            tb = time.time()
            window = tb - ta
            busy_shells = set()
            # Per-role totals, at the end of the window.
            roles = {role: self.totals(rows) for role, rows in b.items()}
            # CPU% and wakeups/s over the window, matched by pid.
            for role in b:
                before = {r["pid"]: r for r in a[role]}
                cpu = sum(r["cpu_s"] - before[r["pid"]]["cpu_s"] for r in b[role] if r["pid"] in before)
                wk = sum((r.get("wakeups") or 0) - (before[r["pid"]].get("wakeups") or 0) for r in b[role] if r["pid"] in before)
                roles[role]["cpu_pct_window"] = round(100 * cpu / window, 3)
                roles[role]["wakeups_per_s"] = round(wk / window, 1)
            step["roles"] = roles
            step["system"] = self.procs.system()
            step["system_delta_vs_baseline"] = {k: step["system"][k] - sys0.get(k, 0) for k in step["system"]}
            if IS_LINUX:
                step["limits"] = LinuxProcs.limits()
            step["latency"] = self.echo_latency(self.args.latency_samples)
            try:
                c = Conn(self.sock_path, timeout=30)
                st = c.call("server-stats", include=["resource_projection"])
                c.close()
                if st.get("ok"):
                    d = st["data"]
                    rl = d.get("registry_lock") or {}
                    step["server_stats"] = {
                        "registry_wait_us": rl.get("wait_us"),
                        "registry_hold_us": rl.get("hold_us"),
                        "registry_stalls": rl.get("stalls"),
                        "registry_top_sites": sorted(rl.get("top_sites") or [], key=lambda x: -x.get("hold_total_us", 0))[:12],
                        "journal_writer": d.get("journal_writer"),
                        "resource_projection": d.get("resource_projection"),
                    }
            except Exception as e:  # noqa: BLE001
                step["server_stats"] = {"error": repr(e)}
            self.result["steps"].append(step)
            log(json.dumps({k: step[k] for k in ("target", "terminals", "create_rate_per_s", "latency")}))
            for role, t in roles.items():
                log(f"  {role}: n={t['count']} rss/each={t.get('rss_per', 0) / 1e6:.2f}MB pss/each={t.get('pss_per', 0) / 1e6:.2f}MB threads={t.get('threads')} fds={t.get('fds')} fdsize/each={t.get('fdsize_per')} cpu%={t['cpu_pct_window']} wk/s={t['wakeups_per_s']}")
            self.flush()
            if step.get("error"):
                self.result["stopped"] = {"at": target, "reason": step["error"]}
                break

    def flush(self):
        if self.args.out:
            with open(self.args.out, "w") as f:
                json.dump(self.result, f, indent=1)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--bin", required=True)
    p.add_argument("--counts", default="100,1000")
    p.add_argument("--mode", choices=["durable", "ephemeral"], default="durable")
    p.add_argument("--shell", nargs="+", default=["/bin/sh"])
    p.add_argument("--busy-fraction", type=float, default=0.05)
    p.add_argument("--busy-rate", type=float, default=10.0, help="lines per second per busy terminal")
    p.add_argument("--busy-line-bytes", type=int, default=80)
    p.add_argument("--per-workspace", type=int, default=200)
    p.add_argument("--create-concurrency", type=int, default=8)
    p.add_argument("--settle-seconds", type=float, default=120)
    p.add_argument("--settle-seconds-min", type=float, default=5)
    p.add_argument("--idle-seconds", type=float, default=20)
    p.add_argument("--latency-terminals", type=int, default=20)
    p.add_argument("--latency-samples", type=int, default=100)
    p.add_argument("--out")
    p.add_argument("--root-dir", default="/tmp", help="parent of the daemon state, home and socket (tmpfs removes fsync cost)")
    p.add_argument("--keep-root", action="store_true")
    args = p.parse_args()
    bench = Bench(args)
    try:
        bench.run()
    except Exception as e:  # noqa: BLE001
        bench.result["stopped"] = {"reason": f"harness error: {e!r}", "daemon_log": bench.tail_log() if bench.daemon else ""}
        log("harness error", repr(e))
    finally:
        try:
            bench.stop()
        finally:
            bench.result["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            bench.flush()
            if not args.keep_root:
                shutil.rmtree(bench.root, ignore_errors=True)
    print(json.dumps({"stopped": bench.result.get("stopped"), "steps": len(bench.result["steps"])}))


if __name__ == "__main__":
    main()
